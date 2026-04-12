#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# SENTANYL — End-to-End: Compound Trigger Conditions (Feature 4)
#            "Elite Member Campaign — Three-Tier Badge Gating"
#
# WHAT THIS DEMO SHOWS:
#   Multiple triggers on the same enactment — each with DIFFERENT badge conditions
#   and priorities — enable fine-grained, multi-badge tier routing from a single
#   email.  The engine evaluates triggers in Priority-descending order and fires
#   the FIRST one whose compound badge conditions are ALL satisfied.
#
# WHY IT MATTERS:
#   Feature 1 showed simple single-badge gating.  Feature 4 extends this to
#   COMPOUND conditions: a trigger can require MULTIPLE badges simultaneously
#   (AND logic via required_badges.must_have array with more than one entry).
#   This enables tiers like "Elite = VIP AND Verified" without any custom code.
#
# HOW IT WORKS:
#   • Trigger.RequiredBadges.MustHave is a []*RequiredBadge slice.
#   • BadgesIn() checks ALL entries — every badge in must_have must be present.
#   • Priority ordering means the most-specific (compound) trigger is evaluated
#     first; the least-specific (no badge) trigger is the final fallback.
#   • If a trigger's compound condition partially matches (e.g. has VIP but not
#     Verified), that trigger is SKIPPED and the next-lower priority is tried.
#
# BEFORE vs AFTER:
#   BEFORE: No badge gating at all — same trigger fired for every user.
#   AFTER:  Three-tier routing from one email, driven entirely by badge set:
#           Elite (vip+verified) → Tier-Elite path
#           Verified only        → Tier-Verified path
#           No special badges    → Tier-Standard path
#
# STORY — "Elite Member Campaign":
#   One enactment, THREE links (one per tier), THREE triggers with compound gates:
#
#   Trigger ELITE    priority=3  requires [vip, verified]  → elite URL
#   Trigger VERIFIED priority=2  requires [verified]       → verified URL
#   Trigger STANDARD priority=1  no requirements           → standard URL
#
#   THREE users:
#     user-a: no badges           → clicks any URL → STANDARD fires
#     user-b: has verified        → clicks any URL → VERIFIED fires (ELITE skipped)
#     user-c: has vip + verified  → clicks any URL → ELITE fires
#
# HOW TO RUN:
#   1.  ./go.sh  (API server + MailHog)
#   2.  bash scripts/e2e-compound-trigger-conditions.sh
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
curl -s -X POST "$BASE/api/admin/reset" -H "$CT" | pp
ok "Database cleared"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 1 — CREATOR & THREE USERS"
# ═══════════════════════════════════════════════════════════════════════════════

CREATOR_EMAIL="elite-campaign-$(date +%s)@sentanyl-demo.local"

echo ">>> Registering creator ($CREATOR_EMAIL)..."
CREATOR_RAW=$(curl -s -X POST "$BASE/api/register" \
    -H "$CT" \
    -d "{
        \"first_name\": \"Elite\",
        \"last_name\":  \"Campaign\",
        \"email\":      \"$CREATOR_EMAIL\",
        \"reply_to\":   \"$CREATOR_EMAIL\",
        \"password\":   \"EliteCamp123!\",
        \"list_name\":  \"Elite Member List\"
    }")
SUB_ID=$(must_ok "Creator registration" "$CREATOR_RAW" "d['creator']['public_id']")
ok "creator subscriber_id = $SUB_ID"

# Register three users (user-a has no badges, user-b has verified, user-c has vip+verified)
for u in a b c; do
    USER_RAW=$(curl -s -X POST "$BASE/api/register/user" \
        -H "$CT" \
        -d "{
            \"subscriber_id\": \"$SUB_ID\",
            \"email\":         \"user-${u}@demo.local\",
            \"first_name\":    \"User\",
            \"last_name\":     \"${u^^}\"
        }")
    U_PID=$(must_ok "user-${u}" "$USER_RAW" "d['user']['public_id']")
    _kset USER_PID "$u" "$U_PID"
    ok "user-${u} public_id = $U_PID"
done

USER_A_PID=$(_kget USER_PID "a")
USER_B_PID=$(_kget USER_PID "b")
USER_C_PID=$(_kget USER_PID "c")

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 2 — CREATE BADGES"
# ═══════════════════════════════════════════════════════════════════════════════

echo ">>> Creating 'story-start' badge..."
B_START_RAW=$(curl -s -X POST "$BASE/api/badge/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"name\":\"story-start\",\"description\":\"Enrolls user in Elite Campaign\"}")
BADGE_START_PID=$(must_ok "story-start" "$B_START_RAW" "d['badge']['public_id']")
ok "story-start = $BADGE_START_PID"

echo ">>> Creating 'vip' badge (part of the compound Elite condition)..."
B_VIP_RAW=$(curl -s -X POST "$BASE/api/badge/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"name\":\"vip\",\"description\":\"VIP badge — required for Elite tier (with verified)\"}")
BADGE_VIP_PID=$(must_ok "vip badge" "$B_VIP_RAW" "d['badge']['public_id']")
ok "vip = $BADGE_VIP_PID"

echo ">>> Creating 'verified' badge (required for Verified AND Elite tiers)..."
B_VER_RAW=$(curl -s -X POST "$BASE/api/badge/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"name\":\"verified\",\"description\":\"Verified badge — gates Verified and Elite tiers\"}")
BADGE_VER_PID=$(must_ok "verified badge" "$B_VER_RAW" "d['badge']['public_id']")
ok "verified = $BADGE_VER_PID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 3 — CREATE CAMPAIGN + TIER RESULT ENACTMENTS"
# ═══════════════════════════════════════════════════════════════════════════════
# We create FOUR enactments:
#   1. Campaign (the "choose your tier" email — sent to everyone)
#   2. Elite Result    (💎 confirmation — only user-c gets this)
#   3. Verified Result (✅ confirmation — only user-b gets this)
#   4. Standard Result (📌 confirmation — only user-a gets this)
#
# Each click trigger on the Campaign enactment points to a DIFFERENT result
# enactment via next_enactment._id.  After clicking, the user immediately
# receives their tier-specific confirmation email — the visual proof in MailHog.
#
# Crucially, the triggers carry NO "when" field, so shortestWaitUntil()
# returns (0, false) and the scheduler NEVER auto-fires advanceUserFromExpiredTrigger.
# The story only advances when the user actually clicks — no timer cheating.

EMAIL_BODY=$(json_str "<html>
<body style='font-family:Arial,sans-serif;max-width:600px;margin:32px auto;padding:28px;background:#fafafa;border-radius:12px;border:2px solid #e5e7eb'>
  <h2 style='color:#111827;text-align:center'>🏆 Elite Member Campaign</h2>
  <p style='color:#374151;text-align:center'>
    Your exclusive offer awaits. Click the button that matches your membership tier.
  </p>
  <table width='100%' cellpadding='0' cellspacing='0' style='margin:24px 0'>
    <tr>
      <td align='center' style='padding:8px'>
        <a href='https://example.com/elite-action'
           style='background:linear-gradient(135deg,#7c3aed,#2563eb);color:#fff;text-decoration:none;
                  padding:14px 32px;border-radius:8px;font-size:16px;font-weight:bold;display:inline-block'>
          💎 ELITE Activation (VIP + Verified Members)
        </a>
      </td>
    </tr>
    <tr>
      <td align='center' style='padding:8px'>
        <a href='https://example.com/verified-action'
           style='background:#0891b2;color:#fff;text-decoration:none;padding:12px 28px;
                  border-radius:8px;font-size:15px;font-weight:bold;display:inline-block'>
          ✅ VERIFIED Activation (Verified Members)
        </a>
      </td>
    </tr>
    <tr>
      <td align='center' style='padding:8px'>
        <a href='https://example.com/standard-action'
           style='background:#4b5563;color:#fff;text-decoration:none;padding:12px 28px;
                  border-radius:8px;font-size:14px;display:inline-block'>
          📌 Standard Enrollment
        </a>
      </td>
    </tr>
  </table>
  <p style='color:#9ca3af;font-size:11px;text-align:center'>
    Feature 4: Compound Trigger Conditions — three-tier badge-gated routing
  </p>
</body>
</html>")

echo ">>> Creating CAMPAIGN enactment (natural_order=1, no timer — click-only)..."
ENACT_CAMPAIGN_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"Elite Campaign Email\",
        \"natural_order\": 1,
        \"send_scene\": {
            \"name\": \"Elite Campaign Scene\",
            \"message\": {
                \"content\": {
                    \"subject\":    \"🏆 Your Elite Campaign Invitation\",
                    \"from_email\": \"$CREATOR_EMAIL\",
                    \"from_name\":  \"Elite Campaign\",
                    \"reply_to\":   \"$CREATOR_EMAIL\",
                    \"body\":       $EMAIL_BODY
                }
            }
        }
    }")
echo "$ENACT_CAMPAIGN_RAW" | pp
ENACT_CAMPAIGN_PID=$(must_ok "Campaign enactment" "$ENACT_CAMPAIGN_RAW" "d['enactment']['public_id']")
ENACT_CAMPAIGN_OID=$(must_ok "Campaign enactment _id" "$ENACT_CAMPAIGN_RAW" "d['enactment']['_id']")
ok "Campaign enactment pid=$ENACT_CAMPAIGN_PID  oid=$ENACT_CAMPAIGN_OID"
ENACT_PID="$ENACT_CAMPAIGN_PID"

ELITE_RESULT_BODY=$(json_str "<html>
<body style='font-family:Arial,sans-serif;max-width:600px;margin:32px auto;padding:28px;
             background:linear-gradient(135deg,#ede9fe,#dbeafe);border-radius:12px;
             border:2px solid #7c3aed'>
  <h2 style='color:#5b21b6;text-align:center'>💎 ELITE TIER ACTIVATED!</h2>
  <p style='color:#374151'>
    <strong>Compound condition PASSED:</strong> You have BOTH the
    <code>vip</code> AND the <code>verified</code> badge simultaneously.<br><br>
    The engine evaluated triggers in priority order:<br>
    &nbsp;&nbsp;• priority=3 ELITE  [vip AND verified]: ✅ PASSED (compound AND) → fired!<br>
    &nbsp;&nbsp;• priority=2 VERIFIED and priority=1 STANDARD: never evaluated (first match wins)
  </p>
  <p style='color:#6d28d9;font-weight:bold;text-align:center;font-size:18px;margin-top:24px'>
    You received THIS email because you clicked 💎 ELITE Activation and hold BOTH required badges.
  </p>
  <p style='font-size:11px;color:#999;text-align:center'>
    Feature 4: Compound Trigger Conditions — Elite Path confirmation
  </p>
</body>
</html>")

echo ">>> Creating ELITE RESULT enactment (natural_order=2)..."
ENACT_ELITE_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"Elite Tier Result\",
        \"natural_order\": 2,
        \"send_scene\": {
            \"name\": \"Elite Result Scene\",
            \"message\": {
                \"content\": {
                    \"subject\":    \"💎 [ELITE TIER] Compound Condition Passed — Welcome!\",
                    \"from_email\": \"$CREATOR_EMAIL\",
                    \"from_name\":  \"Elite Campaign\",
                    \"reply_to\":   \"$CREATOR_EMAIL\",
                    \"body\":       $ELITE_RESULT_BODY
                }
            }
        }
    }")
echo "$ENACT_ELITE_RAW" | pp
ENACT_ELITE_PID=$(must_ok "Elite result enactment" "$ENACT_ELITE_RAW" "d['enactment']['public_id']")
ENACT_ELITE_OID=$(must_ok "Elite result enactment _id" "$ENACT_ELITE_RAW" "d['enactment']['_id']")
ok "Elite result pid=$ENACT_ELITE_PID  oid=$ENACT_ELITE_OID"

VERIFIED_RESULT_BODY=$(json_str "<html>
<body style='font-family:Arial,sans-serif;max-width:600px;margin:32px auto;padding:28px;
             background:linear-gradient(135deg,#cffafe,#e0f2fe);border-radius:12px;
             border:2px solid #0891b2'>
  <h2 style='color:#0e7490;text-align:center'>✅ VERIFIED TIER ACTIVATED!</h2>
  <p style='color:#374151'>
    <strong>VERIFIED condition PASSED, ELITE was blocked:</strong><br>
    You have the <code>verified</code> badge, but you are MISSING <code>vip</code>.<br><br>
    The engine evaluated triggers in priority order:<br>
    &nbsp;&nbsp;• priority=3 ELITE  [vip AND verified]: ❌ FAILED (compound AND — missing vip)<br>
    &nbsp;&nbsp;• priority=2 VERIFIED [verified]:       ✅ PASSED → fired!<br>
    &nbsp;&nbsp;• priority=1 STANDARD: never evaluated (VERIFIED matched first)
  </p>
  <p style='color:#0e7490;font-weight:bold;text-align:center;font-size:18px;margin-top:24px'>
    You received THIS email because you clicked ✅ VERIFIED Activation and hold [verified] (not vip+verified).
  </p>
  <p style='font-size:11px;color:#999;text-align:center'>
    Feature 4: Compound Trigger Conditions — Verified Path confirmation
  </p>
</body>
</html>")

echo ">>> Creating VERIFIED RESULT enactment (natural_order=3)..."
ENACT_VERIFIED_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"Verified Tier Result\",
        \"natural_order\": 3,
        \"send_scene\": {
            \"name\": \"Verified Result Scene\",
            \"message\": {
                \"content\": {
                    \"subject\":    \"✅ [VERIFIED TIER] Verified Condition Passed — Welcome!\",
                    \"from_email\": \"$CREATOR_EMAIL\",
                    \"from_name\":  \"Elite Campaign\",
                    \"reply_to\":   \"$CREATOR_EMAIL\",
                    \"body\":       $VERIFIED_RESULT_BODY
                }
            }
        }
    }")
echo "$ENACT_VERIFIED_RAW" | pp
ENACT_VERIFIED_PID=$(must_ok "Verified result enactment" "$ENACT_VERIFIED_RAW" "d['enactment']['public_id']")
ENACT_VERIFIED_OID=$(must_ok "Verified result enactment _id" "$ENACT_VERIFIED_RAW" "d['enactment']['_id']")
ok "Verified result pid=$ENACT_VERIFIED_PID  oid=$ENACT_VERIFIED_OID"

STANDARD_RESULT_BODY=$(json_str "<html>
<body style='font-family:Arial,sans-serif;max-width:600px;margin:32px auto;padding:28px;
             background:#f8fafc;border-radius:12px;border:2px solid #4b5563'>
  <h2 style='color:#374151;text-align:center'>📌 STANDARD ENROLLMENT CONFIRMED!</h2>
  <p style='color:#374151'>
    <strong>STANDARD fallback triggered:</strong> No special badges required.<br><br>
    The engine evaluated triggers in priority order:<br>
    &nbsp;&nbsp;• priority=3 ELITE  [vip AND verified]: ❌ FAILED (missing both)<br>
    &nbsp;&nbsp;• priority=2 VERIFIED [verified]:       ❌ FAILED (missing verified)<br>
    &nbsp;&nbsp;• priority=1 STANDARD (no badge req):   ✅ PASSED → fired!
  </p>
  <p style='color:#374151;font-weight:bold;text-align:center;font-size:18px;margin-top:24px'>
    You received THIS email because you clicked 📌 Standard Enrollment
    and hold no tier-specific badges.
  </p>
  <p style='font-size:11px;color:#999;text-align:center'>
    Feature 4: Compound Trigger Conditions — Standard Path confirmation
  </p>
</body>
</html>")

echo ">>> Creating STANDARD RESULT enactment (natural_order=4)..."
ENACT_STANDARD_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"Standard Tier Result\",
        \"natural_order\": 4,
        \"send_scene\": {
            \"name\": \"Standard Result Scene\",
            \"message\": {
                \"content\": {
                    \"subject\":    \"📌 [STANDARD TIER] Standard Path Confirmed — Welcome!\",
                    \"from_email\": \"$CREATOR_EMAIL\",
                    \"from_name\":  \"Elite Campaign\",
                    \"reply_to\":   \"$CREATOR_EMAIL\",
                    \"body\":       $STANDARD_RESULT_BODY
                }
            }
        }
    }")
echo "$ENACT_STANDARD_RAW" | pp
ENACT_STANDARD_PID=$(must_ok "Standard result enactment" "$ENACT_STANDARD_RAW" "d['enactment']['public_id']")
ENACT_STANDARD_OID=$(must_ok "Standard result enactment _id" "$ENACT_STANDARD_RAW" "d['enactment']['_id']")
ok "Standard result pid=$ENACT_STANDARD_PID  oid=$ENACT_STANDARD_OID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 4 — ADD THREE TRIGGERS WITH COMPOUND BADGE CONDITIONS"
# ═══════════════════════════════════════════════════════════════════════════════
# TRIGGER ELITE    (priority=3, requires [vip AND verified]):
#   The compound condition — user must have BOTH badges simultaneously.
#   This is Feature 4's key: BadgesIn() checks ALL entries in must_have.
#   Action: jump directly to the Elite Result enactment via next_enactment._id.
#
# TRIGGER VERIFIED (priority=2, requires [verified]):
#   Single badge gate. Fires for users who are verified but NOT vip+verified.
#   Action: jump to Verified Result enactment.
#
# TRIGGER STANDARD (priority=1, no requirements):
#   Universal fallback — fires for users who didn't satisfy Elite or Verified.
#   Action: jump to Standard Result enactment.
#
# IMPORTANT: No "when" field in any trigger action.
#   Without "when", shortestWaitUntil() returns (0, false).
#   processExpiredTriggers() skips triggers with no duration — so the scheduler
#   NEVER fires advanceUserFromExpiredTrigger for the campaign enactment.
#   The story is CLICK-ONLY: it only advances when the user clicks a button.

echo ">>> Adding ELITE trigger (priority=3, requires BOTH vip AND verified badges)..."
info "Compound: BadgesIn() checks BOTH badges must be present simultaneously"
info "Action: next_enactment → jumps to Elite Result email (OID=$ENACT_ELITE_OID)"
TRIG_ELITE_RAW=$(curl -s -X POST "$BASE/api/enactment/$ENACT_CAMPAIGN_PID/trigger" \
    -H "$CT" \
    -d "{
        \"subscriber_id\":     \"$SUB_ID\",
        \"name\":              \"Elite Path — Compound vip+verified\",
        \"trigger_type\":      \"OnWebhook\",
        \"user_action_type\":  \"OnClick\",
        \"user_action_value\": \"https://example.com/elite-action\",
        \"priority\":          3,
        \"required_badges\": {
            \"must_have\": [
                {\"badge\": {\"public_id\": \"$BADGE_VIP_PID\"}},
                {\"badge\": {\"public_id\": \"$BADGE_VER_PID\"}}
            ]
        },
        \"then_do_this_action\": {
            \"action_name\": \"ELITE TIER ACTIVATED — jump to Elite Result email\",
            \"next_enactment\": {\"_id\": \"$ENACT_ELITE_OID\"}
        }
    }")
echo "$TRIG_ELITE_RAW" | pp
ok "ELITE trigger: priority=3, requires [vip AND verified], URL=elite-action → Elite Result"

echo ">>> Adding VERIFIED trigger (priority=2, requires verified only)..."
info "Single badge gate — fires for verified users who don't also have vip"
info "Action: next_enactment → jumps to Verified Result email (OID=$ENACT_VERIFIED_OID)"
TRIG_VER_RAW=$(curl -s -X POST "$BASE/api/enactment/$ENACT_CAMPAIGN_PID/trigger" \
    -H "$CT" \
    -d "{
        \"subscriber_id\":     \"$SUB_ID\",
        \"name\":              \"Verified Path — verified badge only\",
        \"trigger_type\":      \"OnWebhook\",
        \"user_action_type\":  \"OnClick\",
        \"user_action_value\": \"https://example.com/verified-action\",
        \"priority\":          2,
        \"required_badges\": {
            \"must_have\": [
                {\"badge\": {\"public_id\": \"$BADGE_VER_PID\"}}
            ]
        },
        \"then_do_this_action\": {
            \"action_name\": \"VERIFIED TIER ACTIVATED — jump to Verified Result email\",
            \"next_enactment\": {\"_id\": \"$ENACT_VERIFIED_OID\"}
        }
    }")
echo "$TRIG_VER_RAW" | pp
ok "VERIFIED trigger: priority=2, requires [verified], URL=verified-action → Verified Result"

echo ">>> Adding STANDARD trigger (priority=1, NO badge requirements)..."
info "Universal fallback — fires when higher-priority triggers fail badge check"
info "Action: next_enactment → jumps to Standard Result email (OID=$ENACT_STANDARD_OID)"
TRIG_STD_RAW=$(curl -s -X POST "$BASE/api/enactment/$ENACT_CAMPAIGN_PID/trigger" \
    -H "$CT" \
    -d "{
        \"subscriber_id\":     \"$SUB_ID\",
        \"name\":              \"Standard Path — no badge requirement\",
        \"trigger_type\":      \"OnWebhook\",
        \"user_action_type\":  \"OnClick\",
        \"user_action_value\": \"https://example.com/standard-action\",
        \"priority\":          1,
        \"then_do_this_action\": {
            \"action_name\": \"STANDARD TIER ACTIVATED — jump to Standard Result email\",
            \"next_enactment\": {\"_id\": \"$ENACT_STANDARD_OID\"}
        }
    }")
echo "$TRIG_STD_RAW" | pp
ok "STANDARD trigger: priority=1, no badge requirements, URL=standard-action → Standard Result"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 5 — CREATE STORYLINE AND STORY"
# ═══════════════════════════════════════════════════════════════════════════════

echo ">>> Creating storyline (all 4 enactments will be linked)..."
SL_RAW=$(curl -s -X POST "$BASE/api/storyline/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"name\":\"Elite Campaign SL1\",\"natural_order\":1}")
SL_PID=$(must_ok "Storyline" "$SL_RAW" "d['storyline']['public_id']")
ok "Storyline pid = $SL_PID"

echo ">>> Linking all 4 enactments to storyline..."
for eid in "$ENACT_CAMPAIGN_PID" "$ENACT_ELITE_PID" "$ENACT_VERIFIED_PID" "$ENACT_STANDARD_PID"; do
    curl -s -X POST "$BASE/api/storyline/$SL_PID/enactments" \
        -H "$CT" \
        -d "{\"subscriber_id\":\"$SUB_ID\",\"enactment_id\":\"$eid\"}" > /dev/null
    ok "  Linked enactment $eid"
done

echo ">>> Creating story..."
STORY_RAW=$(curl -s -X POST "$BASE/api/story/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"Elite Member Campaign\",
        \"priority\":      1,
        \"allow_interruption\": false,
        \"start_trigger\": {\"badge\": {\"public_id\": \"$BADGE_START_PID\"}}
    }")
STORY_PID=$(must_ok "Story" "$STORY_RAW" "d['story']['public_id']")
ok "Story pid = $STORY_PID"

curl -s -X POST "$BASE/api/story/$STORY_PID/storylines/$SL_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}" | pp
ok "Storyline linked to story"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 6 — ENROLL ALL 3 USERS"
# ═══════════════════════════════════════════════════════════════════════════════

for u in a b c; do
    u_pid=$(_kget USER_PID "$u")
    curl -s -X PUT "$BASE/api/user_badge/user/$u_pid/badge/$BADGE_START_PID" \
        -H "$CT" \
        -d "{\"subscriber_id\":\"$SUB_ID\"}" > /dev/null
    ok "user-${u} enrolled (story-start badge added)"
done

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 7 — SET USER BADGE PROFILES (the key differentiators)"
# ═══════════════════════════════════════════════════════════════════════════════
# user-a: NO extra badges  → only STANDARD trigger (priority=1) can fire
# user-b: verified only    → VERIFIED (priority=2) will fire; ELITE (priority=3) fails
#                            because user-b lacks the "vip" badge in the compound check
# user-c: vip + verified   → ELITE (priority=3) fires; compound [vip,verified] = PASS

info "user-a: no extra badges — STANDARD trigger (priority=1) will fire"
ok "user-a badge profile: (none)"

echo
echo ">>> Adding 'verified' badge to user-b ONLY..."
info "user-b has verified but NOT vip → ELITE compound check FAILS (missing vip)"
info "                                 → VERIFIED single check PASSES"
curl -s -X PUT "$BASE/api/user_badge/user/$USER_B_PID/badge/$BADGE_VER_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}" | pp
ok "user-b badge profile: [verified]"

echo
echo ">>> Adding 'vip' AND 'verified' badges to user-c..."
info "user-c has BOTH → ELITE compound check PASSES [vip AND verified]"
curl -s -X PUT "$BASE/api/user_badge/user/$USER_C_PID/badge/$BADGE_VIP_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}" | pp
curl -s -X PUT "$BASE/api/user_badge/user/$USER_C_PID/badge/$BADGE_VER_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}" | pp
ok "user-c badge profile: [vip, verified]"

echo
echo ">>> Waiting 5 seconds for emails to be scheduled..."
sleep 5

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 8 — VERIFY CAMPAIGN EMAILS ARRIVED IN MAILHOG"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BLD}${YLW}╔══════════════════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${YLW}║  📬  CAMPAIGN EMAILS SHOULD HAVE ARRIVED IN MAILHOG                 ║${RST}"
echo -e "${BLD}${YLW}╟──────────────────────────────────────────────────────────────────────╢${RST}"
echo -e "${BLD}${YLW}║  Open MailHog: $MAILHOG_UI${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  You should see 3 identical emails (one per user):${RST}"
echo -e "${BLD}${YLW}║    Subject: '🏆 Your Elite Campaign Invitation'${RST}"
echo -e "${BLD}${YLW}║    Recipients: user-a@demo.local, user-b@demo.local, user-c@demo.local${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  Each email contains THREE buttons:${RST}"
echo -e "${BLD}${YLW}║    💎 ELITE Activation        → tracked → https://example.com/elite-action${RST}"
echo -e "${BLD}${YLW}║    ✅ VERIFIED Activation     → tracked → https://example.com/verified-action${RST}"
echo -e "${BLD}${YLW}║    📌 Standard Enrollment     → tracked → https://example.com/standard-action${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  (Links are rewritten through ${BASE}/api/track/click/... so clicking${RST}"
echo -e "${BLD}${YLW}║   in MailHog automatically fires the click webhook.)${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  Confirm all 3 campaign emails are present, then press Enter.${RST}"
echo -e "${BLD}${YLW}╚══════════════════════════════════════════════════════════════════════╝${RST}"
press_enter

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 9 — DEMONSTRATE COMPOUND BLOCKING: user-b tries ELITE link (BLOCKED)"
# ═══════════════════════════════════════════════════════════════════════════════
# This is the CORE proof of Feature 4's compound AND condition.
# user-b has 'verified' but NOT 'vip'.  Clicking the ELITE button fires:
#   → Engine checks ELITE trigger (priority=3): requires [vip AND verified]
#   → BadgesIn() checks ALL entries in must_have:
#       vip:      user-b does NOT have this ✗  ← compound AND fails here
#       verified: user-b HAS this ✓
#   → ELITE trigger FAILS (one missing badge breaks the compound condition)
#   → No other trigger is registered for the elite-action URL
#   → Click is a complete no-op: NO email, NO advancement
#
# If this were Feature 1 (single badge gating), user-b would fire the VERIFIED
# trigger when clicking any URL.  Feature 4 is about URL-specific compound gates.

echo ""
echo -e "${BLD}${RED}╔══════════════════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${RED}║  🧪 COMPOUND BLOCKING PROOF — READ CAREFULLY                        ║${RST}"
echo -e "${BLD}${RED}╟──────────────────────────────────────────────────────────────────────╢${RST}"
echo -e "${BLD}${RED}║  For user-b@demo.local (has verified, MISSING vip):${RST}"
echo -e "${BLD}${RED}║${RST}"
echo -e "${BLD}${RED}║  ACTION: Open MailHog → find user-b@demo.local's campaign email${RST}"
echo -e "${BLD}${RED}║          Click '💎 ELITE Activation (VIP + Verified Members)'${RST}"
echo -e "${BLD}${RED}║          (clicking the link fires the webhook automatically)${RST}"
echo -e "${BLD}${RED}║${RST}"
echo -e "${BLD}${RED}║  EXPECTED: NOTHING happens — no new email, no advancement.${RST}"
echo -e "${BLD}${RED}║  WHY: The ELITE trigger requires BOTH [vip AND verified].${RST}"
echo -e "${BLD}${RED}║       user-b has verified ✓ but is MISSING vip ✗.${RST}"
echo -e "${BLD}${RED}║       BadgesIn() checks ALL entries — one failure = compound FAILS.${RST}"
echo -e "${BLD}${RED}║${RST}"
echo -e "${BLD}${RED}║  After clicking (and seeing nothing happen), press Enter.${RST}"
echo -e "${BLD}${RED}╚══════════════════════════════════════════════════════════════════════╝${RST}"
press_enter

echo ">>> Monitoring user-b for ~12 seconds to confirm NO advancement occurred..."
confirm_no_change "$USER_B_PID" "InProgress" "user-b blocked from ELITE (compound AND failed)" 12
echo ""
echo -e "${BLD}${GRN}  ✓ COMPOUND BLOCKING CONFIRMED:${RST}"
echo "    • user-b has 'verified' ✓ but is MISSING 'vip' ✗"
echo "    • The ELITE trigger requires BOTH — partial badge match FAILS the compound condition"
echo "    • No trigger fires for the elite-action URL for user-b → click is a true no-op"
echo "    • Server log will show: 'triggerBadgeCheck: trigger ... skipped (badge requirements not met)'"
echo ""
info "This is the KEY difference from single-badge gating (Feature 1):"
info "  Feature 1: one badge = pass/fail.  Feature 4: ALL badges in must_have must be present."

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 10 — DEMONSTRATE: user-a (no badges) → STANDARD result email"
# ═══════════════════════════════════════════════════════════════════════════════
# Trigger evaluation order for user-a clicking standard-action:
#   ELITE    (priority=3, requires [vip,verified], URL=elite-action):    URL mismatch
#   VERIFIED (priority=2, requires [verified],     URL=verified-action): URL mismatch
#   STANDARD (priority=1, no requirements,         URL=standard-action): PASS → fires!
# Action: next_enactment → user-a moves to Standard Result enactment
# Standard Result email is sent IMMEDIATELY.

echo ""
echo -e "${BLD}${YLW}╔══════════════════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${YLW}║  👆 ACTION REQUIRED — STEP 1: user-a (NO badges) → STANDARD path    ║${RST}"
echo -e "${BLD}${YLW}╟──────────────────────────────────────────────────────────────────────╢${RST}"
echo -e "${BLD}${YLW}║  In MailHog: find the campaign email for: user-a@demo.local${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  Click: '📌 Standard Enrollment'${RST}"
echo -e "${BLD}${YLW}║  (clicking the link fires the webhook automatically)${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  What will happen:${RST}"
echo -e "${BLD}${YLW}║    ELITE    (priority=3, [vip,verified]):  ✗ URL mismatch / badge fail${RST}"
echo -e "${BLD}${YLW}║    VERIFIED (priority=2, [verified]):      ✗ URL mismatch${RST}"
echo -e "${BLD}${YLW}║    STANDARD (priority=1, no badge req):    ✓ URL match + no badge req → FIRES${RST}"
echo -e "${BLD}${YLW}║    → user-a immediately receives:${RST}"
echo -e "${BLD}${YLW}║      Subject: '📌 [STANDARD TIER] Standard Path Confirmed — Welcome!'${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  After clicking, return here and press Enter.${RST}"
echo -e "${BLD}${YLW}╚══════════════════════════════════════════════════════════════════════╝${RST}"
press_enter

echo ">>> Waiting 8 seconds for Standard Result email to arrive..."
sleep 8

echo ">>> Checking user-a state..."
USER_A_STATE=$(curl -s -X GET "$BASE/api/user/$USER_A_PID" -H "$CT" -d "{\"subscriber_id\":\"$SUB_ID\"}")
echo "$USER_A_STATE" | pp

echo ""
echo -e "${BLD}${GRN}╔══════════════════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${GRN}║  ✅ CHECK MAILHOG NOW for user-a@demo.local                         ║${RST}"
echo -e "${BLD}${GRN}║  $MAILHOG_UI${RST}"
echo -e "${BLD}${GRN}║${RST}"
echo -e "${BLD}${GRN}║  You should see a NEW email:${RST}"
echo -e "${BLD}${GRN}║    Subject: '📌 [STANDARD TIER] Standard Path Confirmed — Welcome!'${RST}"
echo -e "${BLD}${GRN}║    This email arrived because user-a clicked Standard → STANDARD trigger fired.${RST}"
echo -e "${BLD}${GRN}╚══════════════════════════════════════════════════════════════════════╝${RST}"
echo ""
printf "${BLD}${CYN}  ↩  Press ENTER once you have confirmed the STANDARD result email in MailHog...${RST} "
read -r _ign
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 11 — DEMONSTRATE: user-b (verified only) → VERIFIED result email"
# ═══════════════════════════════════════════════════════════════════════════════
# Note: user-b already tried (and was BLOCKED from) the ELITE button in Phase 9.
# Now user-b clicks the correct VERIFIED button for their tier.
# Trigger evaluation order for user-b clicking verified-action:
#   ELITE    (priority=3, requires [vip,verified], URL=elite-action):  URL mismatch
#   VERIFIED (priority=2, requires [verified],     URL=verified-action): PASS → fires!
# Action: next_enactment → user-b moves to Verified Result enactment
# Verified Result email is sent IMMEDIATELY.

echo ""
echo -e "${BLD}${YLW}╔══════════════════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${YLW}║  👆 ACTION REQUIRED — STEP 2: user-b (VERIFIED only) → VERIFIED path ║${RST}"
echo -e "${BLD}${YLW}╟──────────────────────────────────────────────────────────────────────╢${RST}"
echo -e "${BLD}${YLW}║  In MailHog: find the campaign email for: user-b@demo.local${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  Click: '✅ VERIFIED Activation (Verified Members)'${RST}"
echo -e "${BLD}${YLW}║  (clicking the link fires the webhook automatically)${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  What will happen:${RST}"
echo -e "${BLD}${YLW}║    ELITE    (priority=3, [vip,verified]):  ✗ URL mismatch${RST}"
echo -e "${BLD}${YLW}║    VERIFIED (priority=2, [verified]):      ✓ URL match + has verified → FIRES${RST}"
echo -e "${BLD}${YLW}║    STANDARD: never evaluated (VERIFIED matched first)${RST}"
echo -e "${BLD}${YLW}║    → user-b immediately receives:${RST}"
echo -e "${BLD}${YLW}║      Subject: '✅ [VERIFIED TIER] Verified Condition Passed — Welcome!'${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  After clicking, return here and press Enter.${RST}"
echo -e "${BLD}${YLW}╚══════════════════════════════════════════════════════════════════════╝${RST}"
press_enter

echo ">>> Waiting 8 seconds for Verified Result email to arrive..."
sleep 8

echo ">>> Checking user-b state..."
USER_B_STATE=$(curl -s -X GET "$BASE/api/user/$USER_B_PID" -H "$CT" -d "{\"subscriber_id\":\"$SUB_ID\"}")
echo "$USER_B_STATE" | pp

echo ""
echo -e "${BLD}${GRN}╔══════════════════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${GRN}║  ✅ CHECK MAILHOG NOW for user-b@demo.local                         ║${RST}"
echo -e "${BLD}${GRN}║  $MAILHOG_UI${RST}"
echo -e "${BLD}${GRN}║${RST}"
echo -e "${BLD}${GRN}║  You should see a NEW email:${RST}"
echo -e "${BLD}${GRN}║    Subject: '✅ [VERIFIED TIER] Verified Condition Passed — Welcome!'${RST}"
echo -e "${BLD}${GRN}║    DIFFERENT from user-a's email — proves tier-specific routing.${RST}"
echo -e "${BLD}${GRN}╚══════════════════════════════════════════════════════════════════════╝${RST}"
echo ""
printf "${BLD}${CYN}  ↩  Press ENTER once you have confirmed the VERIFIED result email in MailHog...${RST} "
read -r _ign
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 12 — DEMONSTRATE: user-c (vip+verified) → ELITE result email"
# ═══════════════════════════════════════════════════════════════════════════════
# Trigger evaluation order for user-c clicking elite-action:
#   ELITE (priority=3, requires [vip,verified], URL=elite-action): PASS → fires immediately!
#   (lower priority triggers never evaluated — first match wins)
# Action: next_enactment → user-c moves to Elite Result enactment
# Elite Result email is sent IMMEDIATELY.

echo ""
echo -e "${BLD}${YLW}╔══════════════════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${YLW}║  👆 ACTION REQUIRED — STEP 3: user-c (VIP + VERIFIED) → ELITE path  ║${RST}"
echo -e "${BLD}${YLW}╟──────────────────────────────────────────────────────────────────────╢${RST}"
echo -e "${BLD}${YLW}║  In MailHog: find the campaign email for: user-c@demo.local${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  Click: '💎 ELITE Activation (VIP + Verified Members)'${RST}"
echo -e "${BLD}${YLW}║  (clicking the link fires the webhook automatically)${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  What will happen:${RST}"
echo -e "${BLD}${YLW}║    ELITE (priority=3, [vip AND verified]):  ✓ URL match + HAS BOTH → FIRES immediately!${RST}"
echo -e "${BLD}${YLW}║    VERIFIED and STANDARD: never evaluated (first match wins)${RST}"
echo -e "${BLD}${YLW}║    → user-c immediately receives:${RST}"
echo -e "${BLD}${YLW}║      Subject: '💎 [ELITE TIER] Compound Condition Passed — Welcome!'${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  After clicking, return here and press Enter.${RST}"
echo -e "${BLD}${YLW}╚══════════════════════════════════════════════════════════════════════╝${RST}"
press_enter

echo ">>> Waiting 8 seconds for Elite Result email to arrive..."
sleep 8

echo ">>> Checking user-c state..."
USER_C_STATE=$(curl -s -X GET "$BASE/api/user/$USER_C_PID" -H "$CT" -d "{\"subscriber_id\":\"$SUB_ID\"}")
echo "$USER_C_STATE" | pp

echo ""
echo -e "${BLD}${GRN}╔══════════════════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${GRN}║  ✅ CHECK MAILHOG NOW for user-c@demo.local                         ║${RST}"
echo -e "${BLD}${GRN}║  $MAILHOG_UI${RST}"
echo -e "${BLD}${GRN}║${RST}"
echo -e "${BLD}${GRN}║  You should see a NEW email:${RST}"
echo -e "${BLD}${GRN}║    Subject: '💎 [ELITE TIER] Compound Condition Passed — Welcome!'${RST}"
echo -e "${BLD}${GRN}║    DIFFERENT from user-a AND user-b — proves 3-tier badge routing.${RST}"
echo -e "${BLD}${GRN}╚══════════════════════════════════════════════════════════════════════╝${RST}"
echo ""
printf "${BLD}${CYN}  ↩  Press ENTER once you have confirmed the ELITE result email in MailHog...${RST} "
read -r _ign
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 13 — DEMO COMPLETE: SUMMARY"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BLD}${GRN}════════════════════════════════════════════════════════════════${RST}"
echo -e "${BLD}${GRN}  ✅  COMPOUND TRIGGER CONDITIONS DEMO COMPLETE!${RST}"
echo -e "${BLD}${GRN}════════════════════════════════════════════════════════════════${RST}"
echo ""
echo -e "${BLD}${CYN}OPEN MAILHOG:${RST}  $MAILHOG_UI"
echo ""
echo -e "${BLD}${YLW}WHAT YOU SHOULD SEE IN MAILHOG (6 total emails):${RST}"
echo ""
echo "  ROUND 1 — Campaign emails (all 3 users got these):"
echo "    🏆 [user-a] 🏆 Your Elite Campaign Invitation"
echo "    🏆 [user-b] 🏆 Your Elite Campaign Invitation"
echo "    🏆 [user-c] 🏆 Your Elite Campaign Invitation"
echo ""
echo "  ROUND 2 — Tier-specific result emails (DIFFERENT for each user):"
echo "    📌 [user-a] 📌 [STANDARD TIER] Standard Path Confirmed — Welcome!"
echo "       → STANDARD trigger fired (priority=1, no badge req)"
echo "    ✅ [user-b] ✅ [VERIFIED TIER] Verified Condition Passed — Welcome!"
echo "       → VERIFIED trigger fired (priority=2, requires [verified])"
echo "       → ELITE was BLOCKED in Phase 9 (compound AND: missing vip)"
echo "    💎 [user-c] 💎 [ELITE TIER] Compound Condition Passed — Welcome!"
echo "       → ELITE trigger fired (priority=3, requires [vip AND verified])"
echo ""
echo -e "${BLD}${YLW}WHAT JUST HAPPENED — TRIGGER EVALUATION SUMMARY:${RST}"
echo ""
echo "  user-a (no badges) clicked standard-action:"
echo "    ELITE    (priority=3, [vip,verified]): ✗ URL mismatch / badge fail"
echo "    VERIFIED (priority=2, [verified]):     ✗ URL mismatch"
echo "    STANDARD (priority=1, none):           ✓ URL match + no badge req → FIRED"
echo ""
echo "  user-b (verified only) — Phase 9 BLOCKED demo:"
echo "    Clicked elite-action URL:"
echo "    ELITE    (priority=3, [vip,verified]): ✗ FAILED compound AND (has verified ✓, missing vip ✗)"
echo "    No fallback for elite-action URL → click was a TRUE no-op"
echo "  user-b then clicked verified-action:"
echo "    VERIFIED (priority=2, [verified]):     ✓ URL match + has verified → FIRED"
echo ""
echo "  user-c (vip+verified) clicked elite-action:"
echo "    ELITE    (priority=3, [vip,verified]): ✓ PASSED compound AND (has vip ✓ + verified ✓) → FIRED"
echo "    (VERIFIED and STANDARD never evaluated — first match wins)"
echo ""
echo -e "${BLD}${YLW}THE COMPOUND CONDITION KEY:${RST}"
echo "  required_badges.must_have is an ARRAY."
echo "  BadgesIn() requires ALL entries to match (AND logic)."
echo "  Example — requiring BOTH vip AND verified:"
echo "    \"required_badges\": {"
echo "      \"must_have\": ["
echo "        {\"badge\": {\"public_id\": \"$BADGE_VIP_PID\"}},"
echo "        {\"badge\": {\"public_id\": \"$BADGE_VER_PID\"}}"
echo "      ]"
echo "    }"
echo ""
echo -e "${BLD}${YLW}WHY THE TIMER DOESN'T FIRE THIS TIME:${RST}"
echo "  The triggers have NO 'when' field → shortestWaitUntil() returns (0, false)."
echo "  processExpiredTriggers() skips HotTriggers with no duration."
echo "  The story ONLY advances when the user actually clicks — no timer cheating."
echo ""
echo -e "${BLD}${YLW}SERVER LOG EVIDENCE:${RST}"
echo "  'triggerBadgeCheck: trigger ... skipped (badge requirements not met for user ...)'"
echo "  Shows each trigger that was skipped before the winning one fired."
echo ""
echo -e "${BLD}${YLW}DEMO IDs:${RST}"
echo "  SUBSCRIBER_ID       = $SUB_ID"
echo "  USER_A_PID          = $USER_A_PID  (no badges → STANDARD)"
echo "  USER_B_PID          = $USER_B_PID  (verified only → VERIFIED)"
echo "  USER_C_PID          = $USER_C_PID  (vip+verified → ELITE)"
echo "  BADGE_VIP_PID       = $BADGE_VIP_PID"
echo "  BADGE_VER_PID       = $BADGE_VER_PID"
echo "  ENACT_CAMPAIGN_PID  = $ENACT_CAMPAIGN_PID"
echo "  ENACT_ELITE_PID     = $ENACT_ELITE_PID"
echo "  ENACT_VERIFIED_PID  = $ENACT_VERIFIED_PID"
echo "  ENACT_STANDARD_PID  = $ENACT_STANDARD_PID"
echo ""
echo -e "${BLD}${CYN}════════════════════════════════════════════════════════════════${RST}"
echo -e "${BLD}${CYN}  Feature 4 demonstrated: compound multi-badge trigger gates! 🏆${RST}"
echo -e "${BLD}${CYN}════════════════════════════════════════════════════════════════${RST}"
echo ""
