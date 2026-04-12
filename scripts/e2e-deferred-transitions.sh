#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# SENTANYL — End-to-End MailHog Deferred Transitions
#            "Buy All Three Manifesting Workshops"
#
# SCRIPT 2 OF 3 — DEFERRED TRANSITION MODE
# ─────────────────────────────────────────
# This script is structurally identical to e2e-mailhog-full-sequence.sh
# (Script 1) but uses DEFERRED transitions for all click triggers.
#
# Difference vs Script 1:
#   Script 1 (instant):  Click → cursor moves → email sends IMMEDIATELY
#   Script 2 (deferred): Click → cursor moves → email is SCHEDULED for ~1 min later
#
# This models a more natural email marketing cadence: clicking a link does not
# immediately bombard the user with the next email.  Instead the cursor (and new
# triggers) are installed at once, but the first email of the next
# enactment/storyline arrives after the WaitUntil delay (1 minute).
#
# Implementation: every click trigger's then_do_this_action carries
#   "send_immediate": false
# which causes ExecuteAction → NextEnactmentWithDelay /
# AdvanceToNextStorylineWithDelay instead of the instant path.
#
# Story A has 3 Storylines (one per workshop), each with 4 Enactment types:
#   A  Soft Intrigue   — "Get More Info"
#   B  Hard Intrigue   — "Are you sure you don't want more info?!"
#   C  Soft Sell       — "Buy Now"
#   D  Hard Sell       — "You're missing out! Last chance!"
#
# Each enactment type has 3 scenes (emails), 1 minute apart.
#
# ROUTING RULES (per storyline):
#   • Click link in A        → kill A, DEFERRED jump to C-Sc1 (~1 min)
#   • No click in A (all 3)  → auto-advance sequentially to B-Sc1
#   • Click link in B        → kill B, DEFERRED jump to C-Sc1 (~1 min)
#   • No click in B (all 3)  → skip to next STORYLINE (B-Sc3 has skip_storyline_on_expiry=true)
#   • Click link in C        → kill C, DEFERRED jump to next STORYLINE (~1 min)
#   • No click in C (all 3)  → auto-advance sequentially to D-Sc1
#   • Click link in D        → kill D, DEFERRED jump to next STORYLINE (~1 min)
#   • No click in D (all 3)  → advance to next STORYLINE (D is last in storyline)
#
# STRUCTURE SUMMARY:
#   3 storylines × (4 enactment types × 3 scenes each) = 36 API-level enactments
#   Each API-level enactment = one scheduled email.
#
#   Story A
#   ├── Storyline 1 (Manifesting Workshop 1)
#   │   ├── Acts 1–3  : Enactment A scenes 1-2-3  (Soft Intrigue)
#   │   ├── Acts 4–6  : Enactment B scenes 1-2-3  (Hard Intrigue, B-Sc3 skip_storyline=true)
#   │   ├── Acts 7–9  : Enactment C scenes 1-2-3  (Soft Sell, click→deferred next storyline)
#   │   └── Acts 10-12: Enactment D scenes 1-2-3  (Hard Sell, click→deferred next storyline)
#   ├── Storyline 2 (Manifesting Workshop 2)   [same pattern]
#   └── Storyline 3 (Manifesting Workshop 3)   [same pattern, final]
#
# EMAIL SUBJECT FORMAT:
#   [S1-SL1-EA-Sc1] Manifesting Workshop 1 — Want to learn more?
#
# HOW TO RUN:
#   1.  ./go.sh                        (API server in DEBUG mode, EMAIL_PROVIDER=mailhog)
#   2.  mailhog  (or docker equivalent)
#   3.  bash scripts/e2e-deferred-transitions.sh
#   4.  Open MailHog at http://localhost:8025 — first email arrives in seconds
#   5.  Click links to navigate; the NEXT email arrives after ~1 minute (deferred)
#
# ENV OVERRIDES:
#   BASE         API base URL  (default: http://localhost:8000)
#   MAILHOG_UI   MailHog UI    (default: http://localhost:8025)
#   USER_EMAIL   Subscriber    (default: josephalai@gmail.com)
# ═══════════════════════════════════════════════════════════════════════════════

# Note: -e is intentionally omitted so that must_ok() controls which failures are
# fatal. Adding -e would cause python3 expression failures inside $() substitutions
# to exit unexpectedly before must_ok() can print a helpful message.
set -uo pipefail

BASE="${BASE:-http://localhost:8000}"
MAILHOG_UI="${MAILHOG_UI:-http://localhost:8025}"
USER_EMAIL="${USER_EMAIL:-josephalai@gmail.com}"
CT="Content-Type: application/json"

# ── Colour helpers ────────────────────────────────────────────────────────────
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
# macOS ships bash 3.2 which lacks `declare -A` (associative arrays) and the
# `${var,,}` lowercase operator.  We simulate keyed storage with eval, encoding
# hyphens in the key as underscores so the variable name is always valid.
#   _kset ARRAY_NAME  "key-with-hyphens"  "value"
#   val=$(_kget ARRAY_NAME  "key-with-hyphens")
_kset() { local _n="$1" _k="${2//-/_}"; eval "${_n}_${_k}=\$3"; }
_kget() { local _n="$1" _k="${2//-/_}"; eval "printf '%s' \"\${${_n}_${_k}}\""; }

# Die with message on non-2xx HTTP response or missing required key
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

echo ">>> Clearing all previous demo data from the database..."
RESET_RAW=$(curl -s -X POST "$BASE/api/admin/reset" -H "$CT")
echo "$RESET_RAW" | pp
ok "Database cleared"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 1 — CREATOR & USER REGISTRATION"
# ═══════════════════════════════════════════════════════════════════════════════

CREATOR_EMAIL="workshops-$(date +%s)@sentanyl-demo.local"

echo ">>> Registering creator ($CREATOR_EMAIL)..."
CREATOR_RAW=$(curl -s -X POST "$BASE/api/register" \
    -H "$CT" \
    -d "{
        \"first_name\": \"Manifesting\",
        \"last_name\":  \"Workshops\",
        \"email\":      \"$CREATOR_EMAIL\",
        \"reply_to\":   \"$CREATOR_EMAIL\",
        \"password\":   \"WorkshopPass123!\",
        \"list_name\":  \"Manifesting Workshops List\"
    }")
echo "$CREATOR_RAW" | pp
SUB_ID=$(must_ok "Creator registration" "$CREATOR_RAW" "d['creator']['public_id']")
ok "creator subscriber_id = $SUB_ID"

echo
echo ">>> Registering user ($USER_EMAIL) as subscriber..."
USER_RAW=$(curl -s -X POST "$BASE/api/register/user" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"email\":         \"$USER_EMAIL\",
        \"first_name\":    \"Joseph\",
        \"last_name\":     \"Alai\"
    }")
echo "$USER_RAW" | pp
USER_PID=$(must_ok "User registration" "$USER_RAW" "d['user']['public_id']")
ok "user public_id = $USER_PID"

# Workshop names referenced across multiple phases — declare once here.
WORKSHOP_NAMES=(
    ""                          # index 0 unused
    "Manifesting Workshop 1"
    "Manifesting Workshop 2"
    "Manifesting Workshop 3"
)

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 2 — CREATE BADGES"
# ═══════════════════════════════════════════════════════════════════════════════
# Badges serve two purposes:
#  1. story-start badge  — assigning it to the user auto-triggers Story A
#  2. per-storyline completion/failure badges — given by the engine whenever a
#     storyline ends so we always have a permanent record of the outcome.
#
# Completion badge  (sl{n}-purchased)      → user clicked BUY NOW in Enactment C/D
# Failure    badge  (sl{n}-not-purchased)  → user ran out of scenes without buying

echo ">>> Creating 'start_story_a' badge..."
BADGE_RAW=$(curl -s -X POST "$BASE/api/badge/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"start_story_a\",
        \"description\":   \"Triggers Story A: Buy All Three Manifesting Workshops\"
    }")
echo "$BADGE_RAW" | pp
BADGE_START_PID=$(must_ok "Badge creation" "$BADGE_RAW" "d['badge']['public_id']")
ok "start_story_a badge public_id = $BADGE_START_PID"

# Arrays: index 1=SL1, 2=SL2, 3=SL3
BADGE_COMPLETE_PID=()   # sl{n}-purchased
BADGE_FAILED_PID=()     # sl{n}-not-purchased

for sl in 1 2 3; do
    wkshp="${WORKSHOP_NAMES[$sl]}"

    echo ">>> Creating completion badge for Storyline ${sl}..."
    BC_RAW=$(curl -s -X POST "$BASE/api/badge/" \
        -H "$CT" \
        -d "{
            \"subscriber_id\": \"$SUB_ID\",
            \"name\":          \"sl${sl}-purchased\",
            \"description\":   \"User purchased ${wkshp} (clicked BUY NOW in Enactment C or D)\"
        }")
    BADGE_COMPLETE_PID[$sl]=$(must_ok "SL${sl} completion badge" "$BC_RAW" "d['badge']['public_id']")
    ok "  SL${sl} completion badge: ${BADGE_COMPLETE_PID[$sl]}"

    echo ">>> Creating failure badge for Storyline ${sl}..."
    BF_RAW=$(curl -s -X POST "$BASE/api/badge/" \
        -H "$CT" \
        -d "{
            \"subscriber_id\": \"$SUB_ID\",
            \"name\":          \"sl${sl}-not-purchased\",
            \"description\":   \"User did not purchase ${wkshp} (ran out of scenes without clicking)\"
        }")
    BADGE_FAILED_PID[$sl]=$(must_ok "SL${sl} failure badge" "$BF_RAW" "d['badge']['public_id']")
    ok "  SL${sl} failure    badge: ${BADGE_FAILED_PID[$sl]}"
done

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 3 — CREATE ALL 36 ENACTMENTS (3 storylines × 4 enactments × 3 scenes)"
# ═══════════════════════════════════════════════════════════════════════════════
#
# Each enactment includes an inline send_scene with a fully-labelled email.
# We store both the public_id (for API linking) and the _id (MongoDB ObjectId,
# needed to reference the Enactment C scene-1 in click-triggers for A and B).
#
# Naming: ENACT_PID_<sl>_<type>_<scene> and ENACT_OID_<sl>_<type>_<scene>
# (stored via _kset/kget helpers; keys like "1-A-1" have hyphens mapped to _)
#   e.g. _kset ENACT_PID "1-A-1" "$pid"   →  ENACT_PID_1_A_1=...
#        _kget ENACT_PID "1-A-1"           →  prints the stored value

# Enactment type metadata
ENACT_TYPES=(A B C D)
ENACT_TYPE_NAMES=("Soft Intrigue" "Hard Intrigue" "Soft Sell" "Hard Sell")
ENACT_TYPE_TAGS=("EA" "EB" "EC" "ED")
LINK_LABELS=("Get More Info" "Get More Info" "BUY NOW" "BUY NOW")
LINK_COLORS=("#1d4ed8" "#7c3aed" "#047857" "#b91c1c")
BG_COLORS=("#eff6ff" "#faf5ff" "#f0fdf4" "#fff1f2")
TEXT_COLORS=("#1e40af" "#6d28d9" "#065f46" "#9f1239")

for sl in 1 2 3; do
    for ti in 0 1 2 3; do
        et="${ENACT_TYPES[$ti]}"
        et_name="${ENACT_TYPE_NAMES[$ti]}"
        et_tag="${ENACT_TYPE_TAGS[$ti]}"
        link_label="${LINK_LABELS[$ti]}"
        link_color="${LINK_COLORS[$ti]}"
        bg_color="${BG_COLORS[$ti]}"
        text_color="${TEXT_COLORS[$ti]}"
        et_lower=$(echo "$et" | tr 'A-Z' 'a-z')
        url_slug="s1-sl${sl}-e${et_lower}"  # e.g. s1-sl1-ea

        for sc in 1 2 3; do
            enact_key="${sl}-${et}-${sc}"
            scene_name="[S1-SL${sl}-${et_tag}-Sc${sc}]"
            wkshp="${WORKSHOP_NAMES[$sl]}"

            # Subject line
            case "$et" in
                A) subj="${scene_name} ${wkshp} — Want to learn more? (${sc} of 3)" ;;
                B) subj="${scene_name} ${wkshp} — Are you SURE? (${sc} of 3)" ;;
                C) subj="${scene_name} ${wkshp} — Ready to buy? 🛒 (${sc} of 3)" ;;
                D) subj="${scene_name} ${wkshp} — LAST CHANCE ⏰ (${sc} of 3)" ;;
            esac

            # Link URL — unique per scene so each trigger matches only its own email.
            link_url="https://example.com/${url_slug}-${sc}"

            # Email body — direct string assignment, no heredocs (bash 3 compatible)
            body="<html>
<head><meta charset=\"UTF-8\"></head>
<body style=\"font-family:Arial,sans-serif;max-width:600px;margin:32px auto;background:${bg_color};padding:28px;border-radius:12px\">
  <p style=\"color:${text_color};font-size:11px;font-weight:bold;letter-spacing:1px;margin-bottom:4px\">
    STORY 1 &nbsp;|&nbsp; STORYLINE ${sl} — ${wkshp} &nbsp;|&nbsp; ENACTMENT ${et} (${et_name}) &nbsp;|&nbsp; SCENE ${sc} OF 3
  </p>
  <h2 style=\"color:${link_color};margin-top:0\">${subj}</h2>"

            case "$et" in
                A)
                    body="${body}
  <p style=\"color:${text_color}\">Hi Joseph,</p>
  <p style=\"color:${text_color}\">
    Have you heard about our <strong>${wkshp}</strong>?
    It's a transformational program designed to help you manifest your deepest desires
    using proven techniques. Scene ${sc} of 3 — you still have time to learn more!
  </p>
  <table width=\"100%\" cellpadding=\"0\" cellspacing=\"0\">
    <tr>
      <td align=\"center\" style=\"padding:20px 0\">
        <a href=\"${link_url}\"
           style=\"background:${link_color};color:#fff;text-decoration:none;padding:14px 32px;border-radius:8px;font-size:16px;font-weight:bold;display:inline-block\">
          👉 ${link_label}
        </a>
      </td>
    </tr>
  </table>
  <p style=\"color:${text_color};font-size:12px\">
    (If you don't click, the next scene arrives in ~1 minute.)
  </p>"
                ;;
                B)
                    body="${body}
  <p style=\"color:${text_color}\">Hi Joseph,</p>
  <p style=\"color:${text_color}\">
    We noticed you haven't checked out <strong>${wkshp}</strong> yet.
    We're concerned you might be missing a life-changing opportunity!
    This is our <em>hard intrigue</em> follow-up — Scene ${sc} of 3.
  </p>
  <table width=\"100%\" cellpadding=\"0\" cellspacing=\"0\">
    <tr>
      <td align=\"center\" style=\"padding:20px 0\">
        <a href=\"${link_url}\"
           style=\"background:${link_color};color:#fff;text-decoration:none;padding:14px 32px;border-radius:8px;font-size:16px;font-weight:bold;display:inline-block\">
          👉 ${link_label}
        </a>
      </td>
    </tr>
  </table>
  <p style=\"color:${text_color};font-size:12px\">
    Still not interested? No worries — we'll move on. (Scene ${sc} of 3.)
  </p>"
                ;;
                C)
                    body="${body}
  <p style=\"color:${text_color}\">Hi Joseph,</p>
  <p style=\"color:${text_color}\">
    Great news — <strong>${wkshp}</strong> is available for purchase right now!
    Join thousands of students who have already transformed their lives with this program.
    This is our <em>soft sell</em> — Scene ${sc} of 3. Don't miss this opportunity!
  </p>
  <table width=\"100%\" cellpadding=\"0\" cellspacing=\"0\">
    <tr>
      <td align=\"center\" style=\"padding:20px 0\">
        <a href=\"${link_url}\"
           style=\"background:${link_color};color:#fff;text-decoration:none;padding:14px 32px;border-radius:8px;font-size:18px;font-weight:bold;display:inline-block\">
          💳 ${link_label}
        </a>
      </td>
    </tr>
  </table>
  <p style=\"color:${text_color};font-size:12px\">
    (Scene ${sc} of 3 — clicking BUY NOW moves cursor to next storyline after ~1 min.)
  </p>"
                ;;
                D)
                    body="${body}
  <p style=\"color:${text_color}\">Hi Joseph,</p>
  <p style=\"color:${text_color}\">
    ⚠️  <strong>FINAL REMINDER for ${wkshp}!</strong><br>
    You are running out of time. Spots are filling up fast and the price
    goes up tonight at midnight. This is scene ${sc} of 3 — our last attempt
    to bring you this incredible workshop at the current price.
  </p>
  <table width=\"100%\" cellpadding=\"0\" cellspacing=\"0\">
    <tr>
      <td align=\"center\" style=\"padding:20px 0\">
        <a href=\"${link_url}\"
           style=\"background:${link_color};color:#fff;text-decoration:none;padding:14px 32px;border-radius:8px;font-size:18px;font-weight:bold;display:inline-block\">
          🔥 ${link_label} — FINAL CHANCE
        </a>
      </td>
    </tr>
  </table>
  <p style=\"color:${text_color};font-size:12px\">
    (Scene ${sc} of 3 — this is the last email for Workshop ${sl}.)
  </p>"
                ;;
            esac

            body+="
  <p style=\"color:#999;font-size:10px;margin-top:24px\">
    Debug: Story 1 | Storyline ${sl} | Enactment ${et} (${et_name}) | Scene ${sc} of 3<br>
    subscriber_id: ${SUB_ID} | user: ${USER_PID}
  </p>
</body>
</html>"

            body_json=$(json_str "$body")

            # Enactment B-Sc3 (the last Hard Intrigue scene) is the end of the
            # "no-click" path for Enactment B.  When its WaitUntil timer fires
            # with no click, the user should jump straight to the next storyline
            # (skip C and D) rather than continuing sequentially.
            SKIP_STORYLINE_FLAG="false"
            if [ "$et" = "B" ] && [ "$sc" = "3" ]; then
                SKIP_STORYLINE_FLAG="true"
            fi

            echo ">>> Creating enactment ${enact_key} (${scene_name})..."
            ENACT_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
                -H "$CT" \
                -d "{
                    \"subscriber_id\":            \"$SUB_ID\",
                    \"name\":                     \"SL${sl}-${et_tag}-Sc${sc} — ${et_name} Scene ${sc}\",
                    \"level\":                    1,
                    \"natural_order\":            $((ti * 3 + sc)),
                    \"skip_storyline_on_expiry\": $SKIP_STORYLINE_FLAG,
                    \"send_scene\": {
                        \"name\": \"Scene ${scene_name}\",
                        \"message\": {
                            \"content\": {
                                \"subject\":    \"$subj\",
                                \"from_email\": \"$CREATOR_EMAIL\",
                                \"from_name\":  \"$wkshp\",
                                \"reply_to\":   \"$CREATOR_EMAIL\",
                                \"body\":       $body_json
                            }
                        }
                    }
                }")

            pid=$(must_ok "Enactment ${enact_key}" "$ENACT_RAW" "d['enactment']['public_id']")
            oid=$(must_ok "Enactment ${enact_key} _id" "$ENACT_RAW" "d['enactment']['_id']")
            _kset ENACT_PID "$enact_key" "$pid"
            _kset ENACT_OID "$enact_key" "$oid"
            ok "  ${enact_key}: pid=$pid  oid=$oid"
        done
    done
done

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 4 — ADD TRIGGERS TO ALL 36 ENACTMENTS (DEFERRED mode)"
# ═══════════════════════════════════════════════════════════════════════════════
#
# KEY DIFFERENCE vs Script 1: every then_do_this_action carries
#   "send_immediate": false
# so that clicking a link moves the cursor and installs triggers immediately,
# but the FIRST EMAIL of the new enactment/storyline is scheduled to arrive
# after the WaitUntil delay (~1 minute) rather than being sent right away.
#
# Enactment types A and B: clicking "More Info" → DEFERRED jump to EC-Sc1
# Enactment types C and D: clicking "BUY NOW"   → DEFERRED advance to next storyline

for sl in 1 2 3; do
    # We need the MongoDB ObjectId of this storyline's EC-Sc1 for jump targets.
    EC1_OID=$(_kget ENACT_OID "${sl}-C-1")
    EC1_PID=$(_kget ENACT_PID "${sl}-C-1")

    for ti in 0 1 2 3; do
        et="${ENACT_TYPES[$ti]}"
        et_tag="${ENACT_TYPE_TAGS[$ti]}"
        link_label="${LINK_LABELS[$ti]}"
        et_lower=$(echo "$et" | tr 'A-Z' 'a-z')
        url_slug="s1-sl${sl}-e${et_lower}"

        for sc in 1 2 3; do
            enact_key="${sl}-${et}-${sc}"
            enact_pid=$(_kget ENACT_PID "$enact_key")
            link_url="https://example.com/${url_slug}-${sc}"

            trigger_name="SL${sl}-${et_tag}-Sc${sc} OnClick ${link_label}"

            case "$et" in
                A|B)
                    # Click → DEFERRED jump to Soft Sell (EC-Sc1) of this storyline.
                    # send_immediate:false means cursor+triggers install now, but the
                    # EC-Sc1 email is scheduled for ~1 minute in the future.
                    ACTION_JSON="{
                        \"action_name\": \"Jump to Soft Sell (EC-Sc1) — DEFERRED\",
                        \"next_enactment\": {\"_id\": \"$EC1_OID\"},
                        \"send_immediate\": false,
                        \"when\": {
                            \"wait_until\": {\"wait_until\": 1, \"time_unit\": \"minutes\"}
                        }
                    }"
                    MARK_COMPLETE="false"
                    MARK_FAILED="false"
                    ;;
                C|D)
                    # Click "BUY NOW" → DEFERRED advance to next storyline.
                    # send_immediate:false means the first email of the next storyline
                    # is scheduled for ~1 minute rather than sent immediately.
                    ACTION_JSON="{
                        \"action_name\": \"BUY NOW — Advance to Next Storyline (DEFERRED)\",
                        \"advance_to_next_storyline\": true,
                        \"send_immediate\": false,
                        \"when\": {
                            \"wait_until\": {\"wait_until\": 1, \"time_unit\": \"minutes\"}
                        }
                    }"
                    MARK_COMPLETE="false"
                    MARK_FAILED="false"
                    ;;
            esac

            echo ">>> Adding trigger to ${enact_key} (url=${link_url})..."
            TRIG_RAW=$(curl -s -X POST "$BASE/api/enactment/$enact_pid/trigger" \
                -H "$CT" \
                -d "{
                    \"subscriber_id\":      \"$SUB_ID\",
                    \"name\":               \"$trigger_name\",
                    \"trigger_type\":       \"OnWebhook\",
                    \"user_action_type\":   \"OnClick\",
                    \"user_action_value\":  \"$link_url\",
                    \"priority\":           1,
                    \"mark_complete\":      $MARK_COMPLETE,
                    \"mark_failed\":        $MARK_FAILED,
                    \"then_do_this_action\": $ACTION_JSON
                }")

            # Verify the trigger was accepted (201 or 200)
            status=$(echo "$TRIG_RAW" | jval "d.get('status','?')" 2>/dev/null || echo "?")
            if [ "$status" = "?" ] || echo "$TRIG_RAW" | grep -q '"error"'; then
                err "Trigger for ${enact_key} may have failed:"
                echo "$TRIG_RAW" | pp >&2
            else
                ok "  trigger ${enact_key}: OnClick ${link_url} → DEFERRED ${et} action"
            fi
        done
    done
done

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 5 — CREATE 3 STORYLINES"
# ═══════════════════════════════════════════════════════════════════════════════
#
# Each storyline carries badge transactions on its OnComplete and OnFail paths:
#   on_complete_begin.badge_transaction.give_badges  →  sl{n}-purchased badge
#   on_fail_begin.badge_transaction.give_badges       →  sl{n}-not-purchased badge
#
# These badges are stored as inline embedded documents (just public_id is set).
# BadgeTransaction.Hydrate() preserves inline badges when GiveBadgesIds is nil,
# so AdvanceToNextStoryline correctly calls AddBadgeToUser with the inline badge
# object, which then resolves the full badge from BadgeCollection by public_id.
#
# NextStorylineId is NOT set here: BsonCollectionId.Id has json:"-" so the id
# field is silently ignored.  Sequential SL1 → SL2 → SL3 ordering is driven by
# the StorylineIds list assembled in Phase 8.

SL_PID=()
SL_OID=()

for sl in 1 2 3; do
    wkshp="${WORKSHOP_NAMES[$sl]}"
    bc_pid="${BADGE_COMPLETE_PID[$sl]}"
    bf_pid="${BADGE_FAILED_PID[$sl]}"

    echo ">>> Creating Storyline ${sl}: ${wkshp}..."

    SL_RAW=$(curl -s -X POST "$BASE/api/storyline/" \
        -H "$CT" \
        -d "{
            \"subscriber_id\": \"$SUB_ID\",
            \"name\":          \"Storyline ${sl} \u2014 ${wkshp}\",
            \"natural_order\": $sl,
            \"on_complete_begin\": {
                \"badge_transaction\": {
                    \"give_badges\": [{\"public_id\": \"$bc_pid\"}]
                }
            },
            \"on_fail_begin\": {
                \"badge_transaction\": {
                    \"give_badges\": [{\"public_id\": \"$bf_pid\"}]
                }
            }
        }")

    echo "$SL_RAW" | pp
    sl_pid=$(must_ok "Storyline ${sl}" "$SL_RAW" "d['storyline']['public_id']")
    sl_oid=$(must_ok "Storyline ${sl} _id" "$SL_RAW" "d['storyline']['_id']")
    SL_PID[$sl]="$sl_pid"
    SL_OID[$sl]="$sl_oid"
    ok "Storyline ${sl}: pid=${sl_pid}  oid=${sl_oid}"
    ok "  completion badge: ${bc_pid}  |  failure badge: ${bf_pid}"
done

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 6 — LINK 12 ENACTMENTS TO EACH STORYLINE (in sequence order)"
# ═══════════════════════════════════════════════════════════════════════════════
# Act order within each storyline: A1 A2 A3  B1 B2 B3  C1 C2 C3  D1 D2 D3

for sl in 1 2 3; do
    sl_pid="${SL_PID[$sl]}"
    echo ">>> Linking enactments to Storyline ${sl}..."
    for ti in 0 1 2 3; do
        et="${ENACT_TYPES[$ti]}"
        for sc in 1 2 3; do
            enact_key="${sl}-${et}-${sc}"
            enact_pid=$(_kget ENACT_PID "$enact_key")
            curl -s -X POST "$BASE/api/storyline/$sl_pid/enactments" \
                -H "$CT" \
                -d "{\"subscriber_id\":\"$SUB_ID\",\"enactment_id\":\"$enact_pid\"}" > /dev/null
            ok "  SL${sl} ← Enactment ${enact_key} (${enact_pid})"
        done
    done
done

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 7 — CREATE STORY A WITH START TRIGGER"
# ═══════════════════════════════════════════════════════════════════════════════
# The story has start_trigger.badge.public_id = "start_story_a" so that adding
# the badge to the user automatically triggers AddBadgeToUser → JoinStory.

echo ">>> Creating Story A..."
STORY_RAW=$(curl -s -X POST "$BASE/api/story/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"Buy All Three Manifesting Workshops\",
        \"start_trigger\": {
            \"badge\": {
                \"public_id\": \"$BADGE_START_PID\"
            }
        }
    }")
echo "$STORY_RAW" | pp
STORY_PID=$(must_ok "Story creation" "$STORY_RAW" "d['story']['public_id']")
ok "Story A public_id = $STORY_PID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 8 — LINK STORYLINES TO STORY (in order: SL1 → SL2 → SL3)"
# ═══════════════════════════════════════════════════════════════════════════════

for sl in 1 2 3; do
    sl_pid="${SL_PID[$sl]}"
    echo ">>> Linking Storyline ${sl} (${sl_pid}) to Story A..."
    LINK_RAW=$(curl -s -X POST "$BASE/api/story/$STORY_PID/storylines/$sl_pid" \
        -H "$CT" \
        -d "{\"subscriber_id\":\"$SUB_ID\"}")
    echo "$LINK_RAW" | pp
    ok "Storyline ${sl} linked to Story A"
done

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 9 — ADD 'start_story_a' BADGE TO USER (triggers story join)"
# ═══════════════════════════════════════════════════════════════════════════════
# PUT /api/user_badge/user/:userId/badge/:badgeId
# → AddBadgeToUser → getStoriesFromBadge → JoinStory → setTriggersFromEnactment
# → compiles first email (SL1-EA-Sc1) → inserts into scheduled_emails
# → email scheduler picks it up and delivers via MailHog

echo ">>> Adding start_story_a badge to user ${USER_PID}..."
JOIN_RAW=$(curl -s -X PUT "$BASE/api/user_badge/user/$USER_PID/badge/$BADGE_START_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}")
echo "$JOIN_RAW" | pp
ok "Badge added — user has joined Story A"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 10 — INSTRUCTIONS FOR THE TESTER"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BLD}${GRN}════════════════════════════════════════════════════════════════${RST}"
echo -e "${BLD}${GRN}  ✅  SETUP COMPLETE — Story A is running! (DEFERRED mode)${RST}"
echo -e "${BLD}${GRN}════════════════════════════════════════════════════════════════${RST}"
echo ""
echo -e "${BLD}${CYN}OPEN MAILHOG:${RST}  $MAILHOG_UI"
echo ""
echo -e "${BLD}${YLW}WHAT TO EXPECT:${RST}"
echo "  The FIRST email should arrive within seconds."
echo "  Subject: [S1-SL1-EA-Sc1] Manifesting Workshop 1 — Want to learn more? (1 of 3)"
echo ""
echo -e "${BLD}${YLW}DEFERRED TRANSITION MODE (KEY DIFFERENCE FROM SCRIPT 1):${RST}"
echo "  Unlike Script 1, clicking a link does NOT immediately send the next email."
echo "  Instead, the cursor moves and the email is scheduled to arrive after ~1 minute."
echo "  This tests the deferred transition mode (send_immediate: false)."
echo ""
echo -e "${BLD}${YLW}SCENE PROGRESSION (auto, no clicks needed):${RST}"
echo "  Every 1 minute a new scene arrives if you don't click."
echo "  Full no-click path: 36 scenes × 1 min ≈ 36+ min to complete all 3 workshops."
echo ""
echo -e "${BLD}${YLW}WHAT CLICKING DOES (DEFERRED):${RST}"
echo "  • Click 'Get More Info' in Enactment A or B → cursor moves to C-Sc1 NOW,"
echo "    but C-Sc1 email arrives ~1 minute later"
echo "  • Click 'BUY NOW'       in Enactment C or D → cursor moves to NEXT STORYLINE NOW,"
echo "    but first email of new storyline arrives ~1 minute later"
echo "  • Not clicking anything                      → auto-advances every ~1 minute"
echo ""
echo -e "${BLD}${YLW}SCENE PROGRESSION (no-click path, per storyline):${RST}"
echo "  A-Sc1 →(1min)→ A-Sc2 →(1min)→ A-Sc3 →(1min)→ B-Sc1 →(1min)→ B-Sc2 →(1min)→ B-Sc3"
echo "  B-Sc3 →(1min, B expired, no click)→ NEXT STORYLINE  [skip_storyline_on_expiry]"
echo "  If reached C: C-Sc1 →(1min)→ C-Sc2 →(1min)→ C-Sc3 →(1min)→ D-Sc1 →(1min)→ D-Sc2 →(1min)→ D-Sc3"
echo "  D-Sc3 →(1min, D expired, no click)→ NEXT STORYLINE  [storyline exhausted]"
echo ""
echo -e "${BLD}${YLW}EMAIL LABEL FORMAT:${RST}"
echo "  [S1-SL{sl}-E{type}-Sc{scene}]"
echo "  Example: [S1-SL1-EA-Sc1] = Story1 / Storyline1 / Enactment-A / Scene-1"
echo "  Types:   EA=Soft Intrigue, EB=Hard Intrigue, EC=Soft Sell, ED=Hard Sell"
echo ""
echo -e "${BLD}${YLW}FULL STORYLINE FLOW:${RST}"
echo "  A→B→NextSL (no clicks): SL1: EA1→EA2→EA3→EB1→EB2→EB3→[skip to SL2]"
echo "  A clicked→C (deferred): SL1: EA1→(click)→[~1min]→EC1→EC2→EC3→ED1→ED2→ED3→[SL2]"
echo "  SL2, SL3: same pattern → story ends after SL3"
echo ""
echo -e "${BLD}${YLW}DEMO IDs:${RST}"
echo "  SUBSCRIBER_ID  = $SUB_ID"
echo "  USER_PID       = $USER_PID"
echo "  STORY_PID      = $STORY_PID"
echo "  BADGE_START    = $BADGE_START_PID"
echo ""
echo -e "${BLD}${YLW}MANUALLY SIMULATE A LINK CLICK (curl):${RST}"
echo "  # Simulate clicking the 'More Info' link from SL1-EA-Sc1:"
printf "  curl -s -X POST %s/api/webhooks/email/clicked \\\\\n" "$BASE"
printf "    -H %q \\\\\n" "$CT"
printf "    -d '%s'\n" "{\"subscriber_id\":\"$SUB_ID\",\"email_address\":\"$USER_EMAIL\",\"link\":{\"url\":\"https://example.com/s1-sl1-ea-1\"}}"
echo ""
echo "  # Check user's current state:"
printf "  curl -s %s/api/user/%s \\\\\n" "$BASE" "$USER_PID"
printf "    -H %q \\\\\n" "$CT"
printf "    -d '%s'\n" "{\"subscriber_id\":\"$SUB_ID\"}"
echo ""
echo "  # View link click stats:"
printf "  curl -s %s/api/stats/link -H %q -d '%s'\n" "$BASE" "$CT" "{\"subscriber_id\":\"$SUB_ID\"}"
echo ""
echo -e "${BLD}${CYN}════════════════════════════════════════════════════════════════${RST}"
echo -e "${BLD}${CYN}  Happy testing! Watch the deferred emails roll in via MailHog. 🚀${RST}"
echo -e "${BLD}${CYN}════════════════════════════════════════════════════════════════${RST}"
echo ""
