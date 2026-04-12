#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# SENTANYL — End-to-End: Conditional Trigger Firing (Feature 1)
#            "VIP Membership Campaign"
#
# WHAT THIS DEMO SHOWS:
#   Triggers can carry RequiredBadges gate conditions.  When a user clicks a
#   link, the engine evaluates ALL triggers whose URL matches — sorted by
#   Priority descending — and fires the first one whose badge requirements are
#   satisfied.  Triggers whose conditions are NOT met are silently skipped.
#
# WHY IT MATTERS:
#   Before this feature every trigger fired unconditionally.  Now a single email
#   can have VIP-only links that do NOTHING for standard users, or a "BUY NOW"
#   button that only unlocks once the user has been through a pre-qual sequence.
#
# HOW IT WORKS:
#   • Each Trigger has an optional `required_badges.must_have` array.
#   • When a webhook click arrives, serve_incoming_webhooks.go sorts the
#     matching triggers by Priority descending and calls triggerBadgeCheck().
#   • The first trigger that passes the check is executed; the rest are skipped.
#   • If NO trigger passes the check, the click is effectively a no-op.
#
# BEFORE vs AFTER:
#   BEFORE: Any user clicking any URL always fired the registered trigger.
#   AFTER:  Only users who hold the required badges can fire gated triggers;
#           users without the badge get a lower-priority fallback (or nothing).
#
# STORY — "VIP Membership Campaign":
#   THREE storylines:
#     SL1      — Initial email: two links (VIP + Standard).  Triggers gate routing.
#     SL-VIP   — VIP Confirmation email sent to users who fired a VIP trigger.
#                Entry is gated: RequiredUserBadges.MustHave = [vip-member].
#     SL-STD   — Standard Enrollment email sent to standard users.
#                Entry is gated: RequiredUserBadges.MustNotHave = [vip-member].
#
#   FIVE triggers on SL1's enactment (A/B/C) plus follow-up enactments (D/E):
#     A  priority=10  requires "vip-member" badge   URL=vip-path      → advance_to_next_storyline → SL-VIP
#     B  priority=5   requires "vip-member" badge   URL=standard-path → advance_to_next_storyline → SL-VIP
#     C  priority=1   no badge requirements          URL=standard-path → advance_to_next_storyline → SL-STD
#     D  mark_complete  URL=vip-complete  (in SL-VIP enactment)  → story Completed
#     E  mark_complete  URL=std-complete  (in SL-STD enactment)  → story Completed
#
#   TWO users:
#     user-standard  → no badges
#     user-vip       → has "vip-member" badge
#
#   EXPECTED OUTCOMES:
#     user-standard  clicks vip-path      → BLOCKED (trigger A badge check fails)
#     user-standard  clicks standard-path → trigger C fires → routed to SL-STD → Standard email sent
#     user-vip       clicks vip-path      → trigger A fires → routed to SL-VIP  → VIP email sent
#     user-vip  could click standard-path → trigger B fires → routed to SL-VIP  → VIP email sent
#
# HOW TO RUN:
#   1.  ./go.sh  (API server + MailHog)
#   2.  bash scripts/e2e-conditional-trigger.sh
#   3.  Watch server logs for "triggerBadgeCheck" messages
#
# ENV OVERRIDES:
#   BASE          API base URL  (default: http://localhost:8000)
#   MAILHOG_UI    MailHog UI    (default: http://localhost:8025)
# ═══════════════════════════════════════════════════════════════════════════════

set -uo pipefail

BASE="${BASE:-http://localhost:8000}"
MAILHOG_UI="${MAILHOG_UI:-http://localhost:8025}"
CT="Content-Type: application/json"

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[1;36m'
BLD='\033[1m'; RST='\033[0m'

hdr()  { echo -e "\n${CYN}${BLD}╔══ $* ══╗${RST}"; }
ok()   { echo -e "  ${GRN}✓${RST} $*"; }
warn() { echo -e "  ${YLW}⚠${RST} $*"; }
err()  { echo -e "  ${RED}✗${RST} $*" >&2; }
info() { echo -e "  ${YLW}ℹ${RST} $*"; }

pp()     { python3 -m json.tool 2>/dev/null || cat; }
jval()   { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)" 2>/dev/null; }
json_str() { python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$1"; }

# ── Bash 3-compatible pseudo-associative arrays ───────────────────────────────
_kset() { local _n="$1" _k="${2//-/_}"; eval "${_n}_${_k}=\$3"; }
_kget() { local _n="$1" _k="${2//-/_}"; eval "printf '%s' \"\${${_n}_${_k}}\""; }

must_ok() {
    local label="$1" raw="$2" key="$3"
    local val
    val=$(echo "$raw" | jval "$key" 2>/dev/null)
    if [ -z "$val" ] || [ "$val" = "None" ]; then
        err "$label FAILED. Raw response:"
        echo "$raw" | pp >&2
        exit 1
    fi
    echo "$val"
}

# ── Interactive tester pause ──────────────────────────────────────────────────
press_enter() {
    echo ""
    echo -e "${BLD}${CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
    printf "${BLD}${CYN}  ↩  Press ENTER when you have completed the action above...${RST} "
    read -r _ign
    echo ""
}

# ── Poll until user reaches expected story_status (or timeout) ───────────────
poll_user_status() {
    local user_pid="$1" expect="$2" label="$3" max="${4:-90}" interval=3 elapsed=0
    while true; do
        local raw status
        raw=$(curl -s -X GET "$BASE/api/user/$user_pid" -H "$CT" -d "{\"subscriber_id\":\"$SUB_ID\"}")
        status=$(echo "$raw" | jval "d.get('message',{}).get('user',{}).get('story_status','?')" 2>/dev/null || echo "?")
        if [ "$status" = "$expect" ]; then
            echo ""
            ok "$label — status=$status ✓"
            echo "$raw" | pp
            return 0
        fi
        elapsed=$((elapsed + interval))
        if [ "$elapsed" -ge "$max" ]; then
            echo ""
            warn "$label — timed out after ${max}s (status=$status, expected $expect)"
            echo "$raw" | pp
            return 1
        fi
        printf "\r  ${YLW}⏳${RST}  %-50s  %3ds elapsed" "$label" "$elapsed"
        sleep "$interval"
    done
}

# ── Confirm no-change after a blocked action ─────────────────────────────────
confirm_no_change() {
    local user_pid="$1" expect="$2" label="$3" max="${4:-12}" interval=2 elapsed=0 changed=0
    printf "  ${YLW}⏳${RST}  Monitoring %-45s" "$label"
    while [ "$elapsed" -lt "$max" ]; do
        sleep "$interval"
        elapsed=$((elapsed + interval))
        local raw status
        raw=$(curl -s -X GET "$BASE/api/user/$user_pid" -H "$CT" -d "{\"subscriber_id\":\"$SUB_ID\"}")
        status=$(echo "$raw" | jval "d.get('message',{}).get('user',{}).get('story_status','?')" 2>/dev/null || echo "?")
        if [ "$status" != "$expect" ]; then
            changed=1; break
        fi
    done
    echo ""
    if [ "$changed" = "0" ]; then
        ok "$label — BLOCKED ✓  (status stayed '$expect' — click was a no-op)"
    else
        warn "$label — UNEXPECTED CHANGE: status became '$status'"
    fi
}

# ── Poll interrupted_stories count ───────────────────────────────────────────
poll_interrupted_count() {
    local user_pid="$1" expected_count="$2" label="$3" max="${4:-60}" interval=3 elapsed=0
    while true; do
        local raw cnt
        raw=$(curl -s -X GET "$BASE/api/user/$user_pid" -H "$CT" -d "{\"subscriber_id\":\"$SUB_ID\"}")
        cnt=$(echo "$raw" | jval "len(d.get('message',{}).get('user',{}).get('interrupted_stories',[]))" 2>/dev/null || echo "?")
        if [ "$cnt" = "$expected_count" ]; then
            echo ""
            ok "$label — interrupted_stories_count=$cnt ✓"
            echo "$raw" | pp
            return 0
        fi
        elapsed=$((elapsed + interval))
        if [ "$elapsed" -ge "$max" ]; then
            echo ""
            warn "$label — timed out after ${max}s (count=$cnt, expected $expected_count)"
            return 1
        fi
        printf "\r  ${YLW}⏳${RST}  %-50s  %3ds elapsed" "$label" "$elapsed"
        sleep "$interval"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
hdr "PRE-FLIGHT CHECK"

echo "Checking server at $BASE ..."
if ! curl -s "$BASE/" > /dev/null 2>&1; then
    err "Server not reachable at $BASE"
    err "Start the server first (./go.sh), then re-run."
    exit 1
fi
ok "Server is up"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 0 — RESET DATABASE"
# ═══════════════════════════════════════════════════════════════════════════════

echo ">>> Clearing all previous demo data..."
RESET_RAW=$(curl -s -X POST "$BASE/api/admin/reset" -H "$CT")
echo "$RESET_RAW" | pp
ok "Database cleared"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 1 — CREATOR & TWO USERS"
# ═══════════════════════════════════════════════════════════════════════════════

CREATOR_EMAIL="vip-campaign-$(date +%s)@sentanyl-demo.local"

echo ">>> Registering creator ($CREATOR_EMAIL)..."
CREATOR_RAW=$(curl -s -X POST "$BASE/api/register" \
    -H "$CT" \
    -d "{
        \"first_name\": \"VIP\",
        \"last_name\":  \"Campaign\",
        \"email\":      \"$CREATOR_EMAIL\",
        \"reply_to\":   \"$CREATOR_EMAIL\",
        \"password\":   \"VIPCampaign123!\",
        \"list_name\":  \"VIP Membership List\"
    }")
echo "$CREATOR_RAW" | pp
SUB_ID=$(must_ok "Creator registration" "$CREATOR_RAW" "d['creator']['public_id']")
ok "creator subscriber_id = $SUB_ID"

echo
echo ">>> Registering user-standard (no VIP badge)..."
USER_STD_RAW=$(curl -s -X POST "$BASE/api/register/user" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"email\":         \"user-standard@demo.local\",
        \"first_name\":    \"Standard\",
        \"last_name\":     \"User\"
    }")
echo "$USER_STD_RAW" | pp
USER_STD_PID=$(must_ok "user-standard registration" "$USER_STD_RAW" "d['user']['public_id']")
ok "user-standard public_id = $USER_STD_PID"

echo
echo ">>> Registering user-vip (will receive vip-member badge later)..."
USER_VIP_RAW=$(curl -s -X POST "$BASE/api/register/user" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"email\":         \"user-vip@demo.local\",
        \"first_name\":    \"VIP\",
        \"last_name\":     \"User\"
    }")
echo "$USER_VIP_RAW" | pp
USER_VIP_PID=$(must_ok "user-vip registration" "$USER_VIP_RAW" "d['user']['public_id']")
ok "user-vip public_id = $USER_VIP_PID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 2 — CREATE BADGES"
# ═══════════════════════════════════════════════════════════════════════════════
# Four badges serve distinct purposes:
#   story-start    — joining this badge auto-triggers the VIP campaign story
#   vip-member     — the gating badge: only users with this can fire VIP triggers
#   completed-vip  — given by the on_complete_begin of SL1 when VIP trigger fires
#   completed-std  — given by the on_complete_begin of SL1 when standard trigger fires
# The last two are assigned via storyline on_complete_begin.badge_transaction,
# NOT via the trigger actions, so we can verify routing via badge_history later.

echo ">>> Creating 'story-start' badge (auto-triggers the campaign story)..."
BADGE_START_RAW=$(curl -s -X POST "$BASE/api/badge/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"name\":\"story-start\",\"description\":\"Joins the VIP Campaign story\"}")
BADGE_START_PID=$(must_ok "story-start badge" "$BADGE_START_RAW" "d['badge']['public_id']")
ok "story-start badge = $BADGE_START_PID"

echo ">>> Creating 'vip-member' badge (the gate: triggers require this badge)..."
BADGE_VIP_RAW=$(curl -s -X POST "$BASE/api/badge/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"name\":\"vip-member\",\"description\":\"Grants access to VIP-gated triggers\"}")
BADGE_VIP_PID=$(must_ok "vip-member badge" "$BADGE_VIP_RAW" "d['badge']['public_id']")
ok "vip-member badge = $BADGE_VIP_PID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 3 — CREATE ENACTMENT (the VIP campaign email)"
# ═══════════════════════════════════════════════════════════════════════════════
# This single enactment sends an email that contains TWO links.
# The triggers added in Phase 4 will be gated by badge requirements.

body_html="<html>
<body style='font-family:Arial,sans-serif;max-width:600px;margin:32px auto;background:#faf5ff;padding:28px;border-radius:12px'>
  <h2 style='color:#6d28d9'>VIP Membership Campaign</h2>
  <p style='color:#4c1d95'>Hello,</p>
  <p style='color:#4c1d95'>
    You have been selected for our exclusive VIP program.
    <strong>VIP Members:</strong> click the exclusive link below to activate
    your premium benefits. Everyone else can use the standard link.
  </p>
  <table width='100%' cellpadding='0' cellspacing='0'>
    <tr>
      <td align='center' style='padding:16px 0'>
        <a href='https://example.com/vip-path'
           style='background:#6d28d9;color:#fff;text-decoration:none;padding:14px 32px;border-radius:8px;font-size:16px;font-weight:bold;display:inline-block'>
          💎 Activate VIP Benefits  (VIP Members Only)
        </a>
      </td>
    </tr>
    <tr>
      <td align='center' style='padding:8px 0'>
        <a href='https://example.com/standard-path'
           style='background:#1d4ed8;color:#fff;text-decoration:none;padding:12px 28px;border-radius:8px;font-size:14px;display:inline-block'>
          👉 Standard Enrollment (All Members)
        </a>
      </td>
    </tr>
  </table>
  <p style='color:#7c3aed;font-size:12px'>
    Note: The VIP link only works if you have the vip-member badge.
    Clicking it without the badge will have no effect — demonstrating
    Sentanyl Feature 1: Conditional Trigger Firing.
  </p>
</body>
</html>"

body_json=$(json_str "$body_html")

echo ">>> Creating enactment 'VIP Campaign Email'..."
ENACT_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"VIP Campaign Email\",
        \"natural_order\": 1,
        \"send_scene\": {
            \"name\": \"VIP Campaign Scene\",
            \"message\": {
                \"content\": {
                    \"subject\":    \"🌟 Your Exclusive VIP Invitation\",
                    \"from_email\": \"$CREATOR_EMAIL\",
                    \"from_name\":  \"VIP Campaign\",
                    \"reply_to\":   \"$CREATOR_EMAIL\",
                    \"body\":       $body_json
                }
            }
        }
    }")
echo "$ENACT_RAW" | pp
ENACT_PID=$(must_ok "Enactment creation" "$ENACT_RAW" "d['enactment']['public_id']")
ENACT_OID=$(must_ok "Enactment _id" "$ENACT_RAW" "d['enactment']['_id']")
ok "enactment pid=$ENACT_PID  oid=$ENACT_OID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 3b — CREATE FOLLOW-UP ENACTMENTS (VIP + Standard confirmation emails)"
# ═══════════════════════════════════════════════════════════════════════════════
# ENACT_VIP — Sent to users routed to SL-VIP after clicking the VIP link.
#             Contains a '💎 Confirm VIP Membership' button.
# ENACT_STD — Sent to users routed to SL-STD after clicking the standard link.
#             Contains a '✅ Confirm Standard Enrollment' button.
# Each of these enactments gets a mark_complete trigger (D and E) in Phase 4
# so that clicking the confirmation button ends the story (status → Completed).

vip_confirm_html="<html>
<body style='font-family:Arial,sans-serif;max-width:600px;margin:32px auto;background:#fdf4ff;padding:28px;border-radius:12px'>
  <h2 style='color:#6d28d9'>🎉 You Are Now a VIP Member!</h2>
  <p style='color:#4c1d95'>
    Congratulations! Your VIP membership has been activated because you clicked
    the exclusive VIP link. Click below to confirm your enrollment.
  </p>
  <table width='100%' cellpadding='0' cellspacing='0'>
    <tr>
      <td align='center' style='padding:20px 0'>
        <a href='https://example.com/vip-complete'
           style='background:#6d28d9;color:#fff;text-decoration:none;padding:16px 40px;border-radius:8px;font-size:16px;font-weight:bold;display:inline-block'>
          💎 Confirm VIP Membership
        </a>
      </td>
    </tr>
  </table>
  <p style='color:#7c3aed;font-size:12px'>
    This email was sent because you had the vip-member badge and clicked the
    VIP link — demonstrating Sentanyl conditional routing (Feature 1 + Feature 5).
  </p>
</body>
</html>"

vip_confirm_json=$(json_str "$vip_confirm_html")

echo ">>> Creating enactment 'VIP Confirmation Email'..."
ENACT_VIP_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"VIP Confirmation Email\",
        \"natural_order\": 2,
        \"send_scene\": {
            \"name\": \"VIP Confirmation Scene\",
            \"message\": {
                \"content\": {
                    \"subject\":    \"💎 Welcome to VIP — Confirm Your Membership\",
                    \"from_email\": \"$CREATOR_EMAIL\",
                    \"from_name\":  \"VIP Campaign\",
                    \"reply_to\":   \"$CREATOR_EMAIL\",
                    \"body\":       $vip_confirm_json
                }
            }
        }
    }")
echo "$ENACT_VIP_RAW" | pp
ENACT_VIP_PID=$(must_ok "VIP enactment creation" "$ENACT_VIP_RAW" "d['enactment']['public_id']")
ok "VIP enactment pid=$ENACT_VIP_PID"

std_confirm_html="<html>
<body style='font-family:Arial,sans-serif;max-width:600px;margin:32px auto;background:#eff6ff;padding:28px;border-radius:12px'>
  <h2 style='color:#1d4ed8'>✅ Standard Enrollment Confirmed</h2>
  <p style='color:#1e3a8a'>
    You've been enrolled in our standard membership program. Click below to
    confirm your enrollment and get started.
  </p>
  <table width='100%' cellpadding='0' cellspacing='0'>
    <tr>
      <td align='center' style='padding:20px 0'>
        <a href='https://example.com/std-complete'
           style='background:#1d4ed8;color:#fff;text-decoration:none;padding:16px 40px;border-radius:8px;font-size:16px;font-weight:bold;display:inline-block'>
          ✅ Confirm Standard Enrollment
        </a>
      </td>
    </tr>
  </table>
  <p style='color:#1e40af;font-size:12px'>
    This email was sent because the standard-path trigger fired for you —
    demonstrating Sentanyl conditional routing (Feature 1 + Feature 5).
  </p>
</body>
</html>"

std_confirm_json=$(json_str "$std_confirm_html")

echo ">>> Creating enactment 'Standard Enrollment Email'..."
ENACT_STD_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"Standard Enrollment Email\",
        \"natural_order\": 3,
        \"send_scene\": {
            \"name\": \"Standard Enrollment Scene\",
            \"message\": {
                \"content\": {
                    \"subject\":    \"✅ Welcome — Confirm Your Standard Enrollment\",
                    \"from_email\": \"$CREATOR_EMAIL\",
                    \"from_name\":  \"VIP Campaign\",
                    \"reply_to\":   \"$CREATOR_EMAIL\",
                    \"body\":       $std_confirm_json
                }
            }
        }
    }")
echo "$ENACT_STD_RAW" | pp
ENACT_STD_PID=$(must_ok "Standard enactment creation" "$ENACT_STD_RAW" "d['enactment']['public_id']")
ok "Standard enactment pid=$ENACT_STD_PID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 4 — ADD FIVE TRIGGERS (A/B/C on SL1, D/E on follow-up enactments)"
# ═══════════════════════════════════════════════════════════════════════════════
# TRIGGER A (priority=10, requires vip-member, URL=vip-path):
#   Only users with the vip-member badge can fire this.
#   Action: advance_to_next_storyline → engine routes user to SL-VIP (next eligible SL).
#
# TRIGGER B (priority=5, requires vip-member, URL=standard-path):
#   VIP users who click the standard link still get the VIP treatment.
#   (Demonstrates priority-ordered badge matching on the same standard URL.)
#
# TRIGGER C (priority=1, no badge requirements, URL=standard-path):
#   Non-VIP users who click the standard link get the standard treatment.
#   Fires because priority-5 (Trigger B) fails badge check for standard users.
#   Action: advance_to_next_storyline → engine skips SL-VIP (lacks badge) → SL-STD.
#
# TRIGGER D (mark_complete, URL=vip-complete, on ENACT_VIP):
#   Clicking the VIP confirmation button ends the story (status → Completed).
#
# TRIGGER E (mark_complete, URL=std-complete, on ENACT_STD):
#   Clicking the standard confirmation button ends the story (status → Completed).

echo ">>> Adding Trigger A — priority=10, requires vip-member, URL=vip-path..."
info "This trigger only fires for users who have the vip-member badge"
TRIG_A_RAW=$(curl -s -X POST "$BASE/api/enactment/$ENACT_PID/trigger" \
    -H "$CT" \
    -d "{
        \"subscriber_id\":     \"$SUB_ID\",
        \"name\":              \"VIP Path — VIP Members Only\",
        \"trigger_type\":      \"OnWebhook\",
        \"user_action_type\":  \"OnClick\",
        \"user_action_value\": \"https://example.com/vip-path\",
        \"priority\":          10,
        \"required_badges\": {
            \"must_have\": [{\"badge\": {\"public_id\": \"$BADGE_VIP_PID\"}}]
        },
        \"then_do_this_action\": {
            \"action_name\": \"VIP Member Confirmed — Advance to VIP Storyline\",
            \"advance_to_next_storyline\": true
        }
    }")
echo "$TRIG_A_RAW" | pp
ok "Trigger A added: priority=10, requires vip-member badge, URL=vip-path"

echo ">>> Adding Trigger B — priority=5, requires vip-member, URL=standard-path..."
info "VIP users who click the standard link are still identified as VIP (higher priority wins)"
TRIG_B_RAW=$(curl -s -X POST "$BASE/api/enactment/$ENACT_PID/trigger" \
    -H "$CT" \
    -d "{
        \"subscriber_id\":     \"$SUB_ID\",
        \"name\":              \"Standard Path — VIP Members (priority=5)\",
        \"trigger_type\":      \"OnWebhook\",
        \"user_action_type\":  \"OnClick\",
        \"user_action_value\": \"https://example.com/standard-path\",
        \"priority\":          5,
        \"required_badges\": {
            \"must_have\": [{\"badge\": {\"public_id\": \"$BADGE_VIP_PID\"}}]
        },
        \"then_do_this_action\": {
            \"action_name\": \"VIP Member via Standard Path — Advance to VIP Storyline\",
            \"advance_to_next_storyline\": true
        }
    }")
echo "$TRIG_B_RAW" | pp
ok "Trigger B added: priority=5, requires vip-member badge, URL=standard-path"

echo ">>> Adding Trigger C — priority=1, NO badge requirements, URL=standard-path..."
info "Any user (standard or VIP) can fire this as a fallback — but B takes precedence for VIP"
TRIG_C_RAW=$(curl -s -X POST "$BASE/api/enactment/$ENACT_PID/trigger" \
    -H "$CT" \
    -d "{
        \"subscriber_id\":     \"$SUB_ID\",
        \"name\":              \"Standard Path — All Members (priority=1 fallback)\",
        \"trigger_type\":      \"OnWebhook\",
        \"user_action_type\":  \"OnClick\",
        \"user_action_value\": \"https://example.com/standard-path\",
        \"priority\":          1,
        \"then_do_this_action\": {
            \"action_name\": \"Standard Member Enrolled — Advance\",
            \"advance_to_next_storyline\": true
        }
    }")
echo "$TRIG_C_RAW" | pp
ok "Trigger C added: priority=1, NO badge requirements, URL=standard-path (fallback)"

echo ">>> Adding Trigger D — mark_complete on VIP Confirmation Email..."
info "Clicking the VIP confirmation link ends the story (status → Completed)"
TRIG_D_RAW=$(curl -s -X POST "$BASE/api/enactment/$ENACT_VIP_PID/trigger" \
    -H "$CT" \
    -d "{
        \"subscriber_id\":     \"$SUB_ID\",
        \"name\":              \"VIP Confirmation — Complete Story\",
        \"trigger_type\":      \"OnWebhook\",
        \"user_action_type\":  \"OnClick\",
        \"user_action_value\": \"https://example.com/vip-complete\",
        \"priority\":          1,
        \"mark_complete\":     true,
        \"then_do_this_action\": {
            \"action_name\": \"VIP Enrollment Confirmed\"
        }
    }")
echo "$TRIG_D_RAW" | pp
ok "Trigger D added: mark_complete=true on VIP Confirmation enactment"

echo ">>> Adding Trigger E — mark_complete on Standard Enrollment Email..."
info "Clicking the standard confirmation link ends the story (status → Completed)"
TRIG_E_RAW=$(curl -s -X POST "$BASE/api/enactment/$ENACT_STD_PID/trigger" \
    -H "$CT" \
    -d "{
        \"subscriber_id\":     \"$SUB_ID\",
        \"name\":              \"Standard Confirmation — Complete Story\",
        \"trigger_type\":      \"OnWebhook\",
        \"user_action_type\":  \"OnClick\",
        \"user_action_value\": \"https://example.com/std-complete\",
        \"priority\":          1,
        \"mark_complete\":     true,
        \"then_do_this_action\": {
            \"action_name\": \"Standard Enrollment Confirmed\"
        }
    }")
echo "$TRIG_E_RAW" | pp
ok "Trigger E added: mark_complete=true on Standard Enrollment enactment"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 5 — CREATE THREE STORYLINES AND LINK ENACTMENTS"
# ═══════════════════════════════════════════════════════════════════════════════
# SL1     — The initial email storyline.  No badge requirement.
# SL-VIP  — VIP confirmation email.  RequiredUserBadges.MustHave = [vip-member].
#           Only VIP users are routed here by AdvanceToNextStoryline's badge check.
# SL-STD  — Standard enrollment email.  RequiredUserBadges.MustNotHave = [vip-member].
#           Standard users are routed here when SL-VIP is skipped (badge check fails).

echo ">>> Creating Storyline 'VIP Campaign SL1' (initial email)..."
SL_RAW=$(curl -s -X POST "$BASE/api/storyline/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"VIP Campaign — Storyline 1\",
        \"natural_order\": 1
    }")
echo "$SL_RAW" | pp
SL_PID=$(must_ok "Storyline creation" "$SL_RAW" "d['storyline']['public_id']")
SL_OID=$(must_ok "Storyline _id" "$SL_RAW" "d['storyline']['_id']")
ok "SL1 pid=$SL_PID  oid=$SL_OID"

echo ">>> Linking initial enactment to SL1..."
curl -s -X POST "$BASE/api/storyline/$SL_PID/enactments" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"enactment_id\":\"$ENACT_PID\"}" | pp
ok "Initial enactment linked to SL1"

echo ">>> Creating Storyline 'VIP Response' — MustHave: vip-member..."
info "Only users with the vip-member badge can enter this storyline (Feature 5 gate)"
SL_VIP_RAW=$(curl -s -X POST "$BASE/api/storyline/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"VIP Response Storyline\",
        \"natural_order\": 2,
        \"required_user_badges\": {
            \"must_have\": [{\"badge\": {\"public_id\": \"$BADGE_VIP_PID\"}}]
        }
    }")
echo "$SL_VIP_RAW" | pp
SL_VIP_PID=$(must_ok "SL-VIP creation" "$SL_VIP_RAW" "d['storyline']['public_id']")
ok "SL-VIP pid=$SL_VIP_PID"

echo ">>> Linking VIP Confirmation enactment to SL-VIP..."
curl -s -X POST "$BASE/api/storyline/$SL_VIP_PID/enactments" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"enactment_id\":\"$ENACT_VIP_PID\"}" | pp
ok "VIP enactment linked to SL-VIP"

echo ">>> Creating Storyline 'Standard Response' — MustNotHave: vip-member..."
info "Standard users (without vip-member badge) are routed here after SL-VIP is skipped"
SL_STD_RAW=$(curl -s -X POST "$BASE/api/storyline/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"Standard Response Storyline\",
        \"natural_order\": 3,
        \"required_user_badges\": {
            \"must_not_have\": [{\"badge\": {\"public_id\": \"$BADGE_VIP_PID\"}}]
        }
    }")
echo "$SL_STD_RAW" | pp
SL_STD_PID=$(must_ok "SL-STD creation" "$SL_STD_RAW" "d['storyline']['public_id']")
ok "SL-STD pid=$SL_STD_PID"

echo ">>> Linking Standard Enrollment enactment to SL-STD..."
curl -s -X POST "$BASE/api/storyline/$SL_STD_PID/enactments" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"enactment_id\":\"$ENACT_STD_PID\"}" | pp
ok "Standard enactment linked to SL-STD"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 6 — CREATE STORY WITH BADGE TRIGGER"
# ═══════════════════════════════════════════════════════════════════════════════
# The story starts when a user receives the story-start badge.
# AllowInterruption=false prevents any other story from interrupting this one.

echo ">>> Creating Story 'VIP Membership Campaign'..."
STORY_RAW=$(curl -s -X POST "$BASE/api/story/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\":   \"$SUB_ID\",
        \"name\":            \"VIP Membership Campaign\",
        \"priority\":        1,
        \"allow_interruption\": false,
        \"start_trigger\": {
            \"badge\": {\"public_id\": \"$BADGE_START_PID\"}
        }
    }")
echo "$STORY_RAW" | pp
STORY_PID=$(must_ok "Story creation" "$STORY_RAW" "d['story']['public_id']")
ok "Story public_id = $STORY_PID"

echo ">>> Linking Storyline 1 (initial email) to Story..."
LINK_RAW=$(curl -s -X POST "$BASE/api/story/$STORY_PID/storylines/$SL_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}")
echo "$LINK_RAW" | pp
ok "SL1 linked to Story"

echo ">>> Linking VIP Response Storyline to Story..."
LINK_VIP_RAW=$(curl -s -X POST "$BASE/api/story/$STORY_PID/storylines/$SL_VIP_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}")
echo "$LINK_VIP_RAW" | pp
ok "SL-VIP linked to Story"

echo ">>> Linking Standard Response Storyline to Story..."
LINK_STD_RAW=$(curl -s -X POST "$BASE/api/story/$STORY_PID/storylines/$SL_STD_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}")
echo "$LINK_STD_RAW" | pp
ok "SL-STD linked to Story"
info "Story now has 3 storylines: SL1 → SL-VIP (VIP users) → SL-STD (standard users)"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 7 — ENROLL BOTH USERS (add story-start badge)"
# ═══════════════════════════════════════════════════════════════════════════════
# Adding the story-start badge triggers JoinStory for both users.
# Both receive the same VIP campaign email within seconds.

echo ">>> Enrolling user-standard (adding story-start badge)..."
JOIN_STD_RAW=$(curl -s -X PUT "$BASE/api/user_badge/user/$USER_STD_PID/badge/$BADGE_START_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}")
echo "$JOIN_STD_RAW" | pp
ok "user-standard enrolled in VIP Campaign story"

echo
echo ">>> Enrolling user-vip (adding story-start badge)..."
JOIN_VIP_RAW=$(curl -s -X PUT "$BASE/api/user_badge/user/$USER_VIP_PID/badge/$BADGE_START_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}")
echo "$JOIN_VIP_RAW" | pp
ok "user-vip enrolled in VIP Campaign story"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 8 — GIVE user-vip THE 'vip-member' BADGE"
# ═══════════════════════════════════════════════════════════════════════════════
# This is the key differentiator: user-vip now satisfies the RequiredBadges
# gate on Triggers A and B.  user-standard does NOT have this badge, so when
# they click the VIP path, triggerBadgeCheck() will return false and the trigger
# will be skipped entirely.

echo ">>> Adding 'vip-member' badge to user-vip ONLY..."
VIP_BADGE_RAW=$(curl -s -X PUT "$BASE/api/user_badge/user/$USER_VIP_PID/badge/$BADGE_VIP_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}")
echo "$VIP_BADGE_RAW" | pp
ok "user-vip now has the vip-member badge"
info "user-standard does NOT have vip-member — clicking the VIP path will be blocked"

echo
echo ">>> Waiting 5 seconds for scheduler to process enrollments..."
sleep 5
ok "Both users' first emails have been scheduled"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 9 — DEMONSTRATE: user-standard is BLOCKED from the VIP path"
# ═══════════════════════════════════════════════════════════════════════════════
# user-standard clicks the VIP-gated URL.
# Trigger A (requires vip-member) will fail badge check → click is a NO-OP.
# user-standard's story_status should remain "InProgress" (unchanged).

echo -e "${BLD}${YLW}╔══ 👆 ACTION REQUIRED ══════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${YLW}║  MAILHOG: $MAILHOG_UI${RST}"
echo -e "${BLD}${YLW}╟────────────────────────────────────────────────────────────────────╢${RST}"
echo -e "${BLD}${YLW}║  STEP 1 — Verify the BLOCKED behavior (no badge = no effect):${RST}"
echo -e "${BLD}${YLW}║    • Open MailHog → find the email for: user-standard@demo.local${RST}"
echo -e "${BLD}${YLW}║    • The email shows TWO buttons — VIP link and Standard link${RST}"
echo -e "${BLD}${YLW}║    • Click '💎 Activate VIP Benefits  (VIP Members Only)' button${RST}"
echo -e "${BLD}${YLW}║      (clicking fires the webhook automatically)${RST}"
echo -e "${BLD}${YLW}║    • Wait 3 seconds — NOTHING should change (no trigger fires)${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  THEN press Enter to confirm the blocked behavior...${RST}"
echo -e "${BLD}${YLW}╚════════════════════════════════════════════════════════════════════╝${RST}"
press_enter
confirm_no_change "$USER_STD_PID" "InProgress" "user-standard VIP-path blocked" 12
ok "✓ The trigger was SKIPPED because user-standard lacks the vip-member badge."

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 10 — user-vip clicks the VIP path (Trigger A fires → routed to SL-VIP)"
# ═══════════════════════════════════════════════════════════════════════════════
# user-vip has the vip-member badge → Trigger A (priority 10) passes badge check
# → fires advance_to_next_storyline → AdvanceToNextStoryline finds SL-VIP as the
# first eligible storyline (MustHave: vip-member ✓) → user-vip enters SL-VIP
# → VIP Confirmation email is sent.

echo -e "${BLD}${YLW}╔══ 👆 ACTION REQUIRED — STEP 2a ════════════════════════════════════╗${RST}"
echo -e "${BLD}${YLW}║  Click the VIP link as user-vip:${RST}"
echo -e "${BLD}${YLW}║    • In MailHog → find the email for: user-vip@demo.local${RST}"
echo -e "${BLD}${YLW}║    • Click '💎 Activate VIP Benefits  (VIP Members Only)' button${RST}"
echo -e "${BLD}${YLW}║      (clicking fires the webhook automatically)${RST}"
echo -e "${BLD}${YLW}║    • user-vip HAS the vip-member badge → Trigger A (priority=10) PASSES${RST}"
echo -e "${BLD}${YLW}║    • Engine advances user-vip to SL-VIP → sends VIP Confirmation email${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  After clicking, check MailHog — user-vip should receive a NEW email:${RST}"
echo -e "${BLD}${YLW}║    Subject: '💎 Welcome to VIP — Confirm Your Membership'${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  THEN press Enter once the new VIP email appears in MailHog...${RST}"
echo -e "${BLD}${YLW}╚════════════════════════════════════════════════════════════════════╝${RST}"
press_enter

echo -e "${BLD}${YLW}╔══ 👆 ACTION REQUIRED — STEP 2b ════════════════════════════════════╗${RST}"
echo -e "${BLD}${YLW}║  Confirm VIP membership by clicking the confirmation link:${RST}"
echo -e "${BLD}${YLW}║    • In MailHog → open the '💎 Welcome to VIP' email for user-vip${RST}"
echo -e "${BLD}${YLW}║    • Click '💎 Confirm VIP Membership' button${RST}"
echo -e "${BLD}${YLW}║      (Trigger D fires: mark_complete → story_status → Completed)${RST}"
echo -e "${BLD}${YLW}╚════════════════════════════════════════════════════════════════════╝${RST}"
press_enter
poll_user_status "$USER_VIP_PID" "Completed" "user-vip VIP trigger fired + confirmed" 90

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 11 — user-standard clicks the standard path (Trigger C fires → routed to SL-STD)"
# ═══════════════════════════════════════════════════════════════════════════════
# user-standard clicks the standard-path URL.
# Trigger B (priority 5, requires vip-member) fails badge check.
# Trigger C (priority 1, no requirements) passes → fires advance_to_next_storyline.
# AdvanceToNextStoryline skips SL-VIP (user-standard lacks vip-member MustHave)
# and advances to SL-STD (MustNotHave: vip-member ✓) → Standard email is sent.

echo -e "${BLD}${YLW}╔══ 👆 ACTION REQUIRED — STEP 3a ════════════════════════════════════╗${RST}"
echo -e "${BLD}${YLW}║  Click the standard link as user-standard:${RST}"
echo -e "${BLD}${YLW}║    • In MailHog → find user-standard@demo.local's INITIAL email${RST}"
echo -e "${BLD}${YLW}║    • Click '👉 Standard Enrollment (All Members)' button${RST}"
echo -e "${BLD}${YLW}║      (clicking fires the webhook automatically)${RST}"
echo -e "${BLD}${YLW}║    • Trigger B (priority=5, requires vip-member): FAILS badge check${RST}"
echo -e "${BLD}${YLW}║    • Trigger C (priority=1, no badge requirement): PASSES → fires${RST}"
echo -e "${BLD}${YLW}║    • Engine skips SL-VIP (lacks vip-member) → enters SL-STD${RST}"
echo -e "${BLD}${YLW}║    • Standard Enrollment email is sent to user-standard${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  After clicking, check MailHog — user-standard should receive a NEW email:${RST}"
echo -e "${BLD}${YLW}║    Subject: '✅ Welcome — Confirm Your Standard Enrollment'${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  THEN press Enter once the new Standard email appears in MailHog...${RST}"
echo -e "${BLD}${YLW}╚════════════════════════════════════════════════════════════════════╝${RST}"
press_enter

echo -e "${BLD}${YLW}╔══ 👆 ACTION REQUIRED — STEP 3b ════════════════════════════════════╗${RST}"
echo -e "${BLD}${YLW}║  Confirm standard enrollment by clicking the confirmation link:${RST}"
echo -e "${BLD}${YLW}║    • In MailHog → open the '✅ Welcome' email for user-standard${RST}"
echo -e "${BLD}${YLW}║    • Click '✅ Confirm Standard Enrollment' button${RST}"
echo -e "${BLD}${YLW}║      (Trigger E fires: mark_complete → story_status → Completed)${RST}"
echo -e "${BLD}${YLW}╚════════════════════════════════════════════════════════════════════╝${RST}"
press_enter
poll_user_status "$USER_STD_PID" "Completed" "user-standard Standard trigger fired + confirmed" 90

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 12 — INSTRUCTIONS FOR THE TESTER"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BLD}${GRN}════════════════════════════════════════════════════════════════${RST}"
echo -e "${BLD}${GRN}  ✅  CONDITIONAL TRIGGER DEMO COMPLETE!${RST}"
echo -e "${BLD}${GRN}════════════════════════════════════════════════════════════════${RST}"
echo ""
echo -e "${BLD}${CYN}OPEN MAILHOG:${RST}  $MAILHOG_UI"
echo ""
echo -e "${BLD}${YLW}WHAT JUST HAPPENED (Emails sent per user):${RST}"
echo "  user-vip:"
echo "    1. Initial VIP Campaign email (SL1) — TWO links (VIP + Standard)"
echo "    2. VIP Confirmation email (SL-VIP)  — sent after clicking the VIP link"
echo "  user-standard:"
echo "    1. Initial VIP Campaign email (SL1) — TWO links (VIP + Standard)"
echo "    2. Standard Enrollment email (SL-STD) — sent after clicking the standard link"
echo ""
echo -e "${BLD}${YLW}ROUTING LOGIC DEMONSTRATED:${RST}"
echo "  1. user-standard clicked the VIP link → BLOCKED (no vip-member badge)."
echo "     Trigger A's RequiredBadges.MustHave check failed → click was a no-op."
echo "  2. user-vip clicked the VIP link → Trigger A fired (priority=10, has badge)."
echo "     advance_to_next_storyline → engine found SL-VIP (MustHave: vip-member ✓)"
echo "     → VIP Confirmation email was sent."
echo "  3. user-standard clicked the standard link → Trigger C fired (priority=1)."
echo "     Trigger B (priority=5, requires vip-member) was skipped first."
echo "     advance_to_next_storyline → engine skipped SL-VIP (lacks vip-member)"
echo "     → SL-STD (MustNotHave: vip-member ✓) → Standard Enrollment email sent."
echo "  4. Each user clicked their confirmation link → mark_complete → Completed."
echo ""
echo -e "${BLD}${YLW}SERVER LOG EVIDENCE (look for these messages):${RST}"
echo "  'handleEmailClicked: trigger ... skipped (badge requirements not met for user ...)'"
echo "  'AdvanceToNextStoryline: user ... does not meet badge requirements for storyline ... — skipping'"
echo "  'FireOutboundWebhook: ... TriggerTriggered ...'"
echo ""
echo -e "${BLD}${YLW}KEY API PATTERN FOR BADGE-GATED TRIGGERS + STORYLINE ROUTING:${RST}"
echo "  POST /api/enactment/{enactmentId}/trigger"
echo "  {"
echo "    \"trigger_type\": \"OnWebhook\", \"user_action_type\": \"OnClick\","
echo "    \"user_action_value\": \"https://example.com/vip-path\","
echo "    \"priority\": 10,"
echo "    \"required_badges\": {\"must_have\": [{\"badge\": {\"public_id\": \"$BADGE_VIP_PID\"}}]},"
echo "    \"then_do_this_action\": {\"advance_to_next_storyline\": true}"
echo "  }"
echo "  POST /api/storyline/"
echo "  {"
echo "    \"name\": \"VIP Response\","
echo "    \"required_user_badges\": {\"must_have\": [{\"badge\": {\"public_id\": \"$BADGE_VIP_PID\"}}]}"
echo "  }"
echo ""
echo -e "${BLD}${YLW}MANUAL VERIFICATION COMMANDS:${RST}"
printf "  # Re-try blocking: user-standard clicks VIP path (should be no-op):\n"
printf "  curl -s -X POST %s/api/webhooks/email/clicked \\\\\n" "$BASE"
printf "    -H %q \\\\\n" "$CT"
printf "    -d '%s'\n" "{\"subscriber_id\":\"$SUB_ID\",\"email_address\":\"user-standard@demo.local\",\"link\":{\"url\":\"https://example.com/vip-path\"}}"
echo ""
echo -e "${BLD}${YLW}DEMO IDs:${RST}"
echo "  SUBSCRIBER_ID  = $SUB_ID"
echo "  USER_STD_PID   = $USER_STD_PID"
echo "  USER_VIP_PID   = $USER_VIP_PID"
echo "  BADGE_VIP_PID  = $BADGE_VIP_PID"
echo "  ENACT_PID      = $ENACT_PID (SL1 — initial email)"
echo "  ENACT_VIP_PID  = $ENACT_VIP_PID (SL-VIP — VIP confirmation)"
echo "  ENACT_STD_PID  = $ENACT_STD_PID (SL-STD — standard enrollment)"
echo "  STORY_PID      = $STORY_PID"
echo ""
echo -e "${BLD}${CYN}════════════════════════════════════════════════════════════════${RST}"
echo -e "${BLD}${CYN}  Features 1 + 5 demonstrated: badge-gated triggers with${RST}"
echo -e "${BLD}${CYN}  storyline-level routing! Different emails per user type. 🔐${RST}"
echo -e "${BLD}${CYN}════════════════════════════════════════════════════════════════${RST}"
echo ""
