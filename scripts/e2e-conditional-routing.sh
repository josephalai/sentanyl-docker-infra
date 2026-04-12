#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# SENTANYL — End-to-End: Conditional OnComplete Routing (Feature 2)
#            "Premium Learning Path"
#
# WHAT THIS DEMO SHOWS:
#   Storylines can declare ConditionalRoutes on their on_complete_begin block.
#   When a user completes a storyline (via advance_to_next_storyline), the
#   engine evaluates ConditionalRoutes in Priority-descending order and sends
#   the user to the FIRST route whose RequiredBadges conditions are satisfied.
#   If no conditional route matches, the system falls back to sequential order.
#
# WHY IT MATTERS:
#   Before: on_complete had ONE NextStoryline — all users followed the same path.
#   After:  a single email funnel can branch into separate VIP and standard tracks
#   based entirely on the user's badge set, without any custom code.
#
# HOW IT WORKS:
#   • Storyline.OnComplete.ConditionalRoutes is a []*ConditionalRoute array.
#   • Each ConditionalRoute carries RequiredBadges and a NextStoryline pointer.
#   • selectConditionalRoute() sorts routes by Priority desc and evaluates
#     BadgesIn/BadgesNotIn for each route in order.
#   • The winning route's NextStoryline overrides any static next-storyline logic.
#   • The inline NextStoryline pointer format is: {"_id": "<storyline ObjectId>"}
#     (Hydrate() resolves this to the full storyline from MongoDB.)
#
# BEFORE vs AFTER:
#   BEFORE: on_complete_begin.next_storyline pointed to ONE fixed storyline.
#           All users followed the same path regardless of badges.
#   AFTER:  on_complete_begin.conditional_routes evaluates badge conditions per
#           user, routing them to different storylines dynamically.
#
# STORY — "Premium Learning Path":
#   SL1: Introduction (everyone gets this)
#     on_complete_begin.conditional_routes:
#       Route 1 (priority=10, requires "premium-member") → SL-PREMIUM
#       Route 2 (priority=1,  no requirements)           → SL-STANDARD
#   SL-PREMIUM: Premium Module (only for premium-member badge holders)
#   SL-STANDARD: Standard Module (everyone else)
#
#   TWO users:
#     user-standard  → no badge          → SL1 → SL-STANDARD
#     user-premium   → has premium-member → SL1 → SL-PREMIUM
#
# HOW TO RUN:
#   1.  ./go.sh  (API server + MailHog)
#   2.  bash scripts/e2e-conditional-routing.sh
#   3.  Open MailHog at http://localhost:8025 — watch subjects to confirm routing
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
RESET_RAW=$(curl -s -X POST "$BASE/api/admin/reset" -H "$CT")
echo "$RESET_RAW" | pp
ok "Database cleared"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 1 — CREATOR & TWO USERS"
# ═══════════════════════════════════════════════════════════════════════════════

CREATOR_EMAIL="learning-path-$(date +%s)@sentanyl-demo.local"

echo ">>> Registering creator ($CREATOR_EMAIL)..."
CREATOR_RAW=$(curl -s -X POST "$BASE/api/register" \
    -H "$CT" \
    -d "{
        \"first_name\": \"Learning\",
        \"last_name\":  \"Platform\",
        \"email\":      \"$CREATOR_EMAIL\",
        \"reply_to\":   \"$CREATOR_EMAIL\",
        \"password\":   \"LearnPass123!\",
        \"list_name\":  \"Premium Learning List\"
    }")
echo "$CREATOR_RAW" | pp
SUB_ID=$(must_ok "Creator registration" "$CREATOR_RAW" "d['creator']['public_id']")
ok "creator subscriber_id = $SUB_ID"

echo
echo ">>> Registering user-standard (will follow the standard learning path)..."
USER_STD_RAW=$(curl -s -X POST "$BASE/api/register/user" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"email\":         \"user-standard@demo.local\",
        \"first_name\":    \"Standard\",
        \"last_name\":     \"Learner\"
    }")
USER_STD_PID=$(must_ok "user-standard" "$USER_STD_RAW" "d['user']['public_id']")
ok "user-standard public_id = $USER_STD_PID"

echo
echo ">>> Registering user-premium (will be routed to premium module)..."
USER_PREM_RAW=$(curl -s -X POST "$BASE/api/register/user" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"email\":         \"user-premium@demo.local\",
        \"first_name\":    \"Premium\",
        \"last_name\":     \"Learner\"
    }")
USER_PREM_PID=$(must_ok "user-premium" "$USER_PREM_RAW" "d['user']['public_id']")
ok "user-premium public_id = $USER_PREM_PID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 2 — CREATE BADGES"
# ═══════════════════════════════════════════════════════════════════════════════

echo ">>> Creating 'story-start' badge..."
BADGE_START_RAW=$(curl -s -X POST "$BASE/api/badge/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"name\":\"story-start\",\"description\":\"Starts the learning path story\"}")
BADGE_START_PID=$(must_ok "story-start badge" "$BADGE_START_RAW" "d['badge']['public_id']")
ok "story-start = $BADGE_START_PID"

echo ">>> Creating 'premium-member' badge (route gate)..."
BADGE_PREM_RAW=$(curl -s -X POST "$BASE/api/badge/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"name\":\"premium-member\",\"description\":\"Routes user to premium learning module\"}")
BADGE_PREM_PID=$(must_ok "premium-member badge" "$BADGE_PREM_RAW" "d['badge']['public_id']")
ok "premium-member = $BADGE_PREM_PID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 3 — CREATE DESTINATION ENACTMENTS (for premium and standard paths)"
# ═══════════════════════════════════════════════════════════════════════════════
# Each destination storyline needs at least one enactment.
# The EMAIL SUBJECT uniquely identifies which path the user landed on —
# the tester confirms routing by checking MailHog for these subjects.

echo ">>> Creating enactment for SL-PREMIUM ('PREMIUM PATH — Advanced Module')..."
PREM_BODY_JSON=$(json_str "<html><body style='background:#fef3c7;font-family:Arial;padding:28px'>
<h2 style='color:#92400e'>🌟 Welcome to the PREMIUM Module!</h2>
<p>You've been routed here because you hold the <strong>premium-member</strong> badge.</p>
<p>This confirms that Sentanyl's ConditionalRoute selected the priority-10 route
(requires premium-member badge) over the priority-1 fallback route.</p>
<p style='font-size:11px;color:#999'>Feature 2: Conditional OnComplete Routing — Premium Path</p>
</body></html>")

ENACT_PREM_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"SL-PREMIUM Enactment\",
        \"natural_order\": 1,
        \"send_scene\": {
            \"name\": \"Premium Module Welcome\",
            \"message\": {
                \"content\": {
                    \"subject\":    \"✅ [PREMIUM PATH] Welcome to the Advanced Module!\",
                    \"from_email\": \"$CREATOR_EMAIL\",
                    \"from_name\":  \"Learning Platform\",
                    \"reply_to\":   \"$CREATOR_EMAIL\",
                    \"body\":       $PREM_BODY_JSON
                }
            }
        }
    }")
echo "$ENACT_PREM_RAW" | pp
ENACT_PREM_PID=$(must_ok "Premium enactment" "$ENACT_PREM_RAW" "d['enactment']['public_id']")
ok "Premium enactment pid = $ENACT_PREM_PID"

echo ">>> Creating enactment for SL-STANDARD ('STANDARD PATH — Standard Module')..."
STD_BODY_JSON=$(json_str "<html><body style='background:#eff6ff;font-family:Arial;padding:28px'>
<h2 style='color:#1e40af'>📚 Welcome to the STANDARD Module!</h2>
<p>You've been routed here via the <strong>default fallback route</strong> (no badge required).</p>
<p>Users with the premium-member badge would have been sent to the Premium Module instead.
This confirms that Sentanyl's ConditionalRoute selected the priority-1 fallback
because no higher-priority route's badge conditions were met.</p>
<p style='font-size:11px;color:#999'>Feature 2: Conditional OnComplete Routing — Standard Path</p>
</body></html>")

ENACT_STD_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"SL-STANDARD Enactment\",
        \"natural_order\": 1,
        \"send_scene\": {
            \"name\": \"Standard Module Welcome\",
            \"message\": {
                \"content\": {
                    \"subject\":    \"📚 [STANDARD PATH] Welcome to the Standard Module!\",
                    \"from_email\": \"$CREATOR_EMAIL\",
                    \"from_name\":  \"Learning Platform\",
                    \"reply_to\":   \"$CREATOR_EMAIL\",
                    \"body\":       $STD_BODY_JSON
                }
            }
        }
    }")
echo "$ENACT_STD_RAW" | pp
ENACT_STD_PID=$(must_ok "Standard enactment" "$ENACT_STD_RAW" "d['enactment']['public_id']")
ok "Standard enactment pid = $ENACT_STD_PID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 4 — CREATE DESTINATION STORYLINES (SL-PREMIUM and SL-STANDARD)"
# ═══════════════════════════════════════════════════════════════════════════════
# These are the TARGET storylines that the ConditionalRoutes on SL1 point to.
# We store their _ids because conditional_routes uses {"_id": "$SL_OID"} format.

echo ">>> Creating SL-PREMIUM storyline..."
SL_PREM_RAW=$(curl -s -X POST "$BASE/api/storyline/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"SL-PREMIUM — Advanced Module\",
        \"natural_order\": 2
    }")
echo "$SL_PREM_RAW" | pp
SL_PREM_PID=$(must_ok "SL-PREMIUM" "$SL_PREM_RAW" "d['storyline']['public_id']")
SL_PREM_OID=$(must_ok "SL-PREMIUM _id" "$SL_PREM_RAW" "d['storyline']['_id']")
ok "SL-PREMIUM pid=$SL_PREM_PID  oid=$SL_PREM_OID"

echo ">>> Linking premium enactment to SL-PREMIUM..."
curl -s -X POST "$BASE/api/storyline/$SL_PREM_PID/enactments" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"enactment_id\":\"$ENACT_PREM_PID\"}" | pp
ok "Premium enactment linked to SL-PREMIUM"

echo ">>> Creating SL-STANDARD storyline..."
SL_STD_RAW=$(curl -s -X POST "$BASE/api/storyline/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"SL-STANDARD — Standard Module\",
        \"natural_order\": 3
    }")
echo "$SL_STD_RAW" | pp
SL_STD_PID=$(must_ok "SL-STANDARD" "$SL_STD_RAW" "d['storyline']['public_id']")
SL_STD_OID=$(must_ok "SL-STANDARD _id" "$SL_STD_RAW" "d['storyline']['_id']")
ok "SL-STANDARD pid=$SL_STD_PID  oid=$SL_STD_OID"

echo ">>> Linking standard enactment to SL-STANDARD..."
curl -s -X POST "$BASE/api/storyline/$SL_STD_PID/enactments" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"enactment_id\":\"$ENACT_STD_PID\"}" | pp
ok "Standard enactment linked to SL-STANDARD"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 5 — CREATE SL1 INTRO ENACTMENT + TRIGGER (advance_to_next_storyline)"
# ═══════════════════════════════════════════════════════════════════════════════
# SL1 is the intro everyone sees. It has ONE enactment with a completion link.
# Clicking the link fires advance_to_next_storyline on SL1, which triggers
# the ConditionalRoute evaluation and routes the user to the right next storyline.

INTRO_BODY_JSON=$(json_str "<html><body style='background:#f0fdf4;font-family:Arial;padding:28px'>
<h2 style='color:#065f46'>📖 Introduction to the Learning Path</h2>
<p>Everyone starts here.  When you click the button below, Sentanyl will evaluate
your badge profile and automatically route you to either:</p>
<ul>
  <li><strong>Premium Module</strong> — if you hold the premium-member badge</li>
  <li><strong>Standard Module</strong> — everyone else (default fallback route)</li>
</ul>
<p>This is Sentanyl Feature 2: Conditional OnComplete Routing.</p>
<table width='100%' cellpadding='0' cellspacing='0'>
  <tr>
    <td align='center' style='padding:20px 0'>
      <a href='https://example.com/complete-intro'
         style='background:#047857;color:#fff;text-decoration:none;padding:14px 32px;
                border-radius:8px;font-size:16px;font-weight:bold;display:inline-block'>
        ✅ I've Completed the Introduction — Route Me!
      </a>
    </td>
  </tr>
</table>
</body></html>")

echo ">>> Creating SL1 intro enactment..."
ENACT_SL1_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"SL1 — Introduction\",
        \"natural_order\": 1,
        \"send_scene\": {
            \"name\": \"Introduction Scene\",
            \"message\": {
                \"content\": {
                    \"subject\":    \"[SL1] Your Learning Path Introduction\",
                    \"from_email\": \"$CREATOR_EMAIL\",
                    \"from_name\":  \"Learning Platform\",
                    \"reply_to\":   \"$CREATOR_EMAIL\",
                    \"body\":       $INTRO_BODY_JSON
                }
            }
        }
    }")
echo "$ENACT_SL1_RAW" | pp
ENACT_SL1_PID=$(must_ok "SL1 enactment" "$ENACT_SL1_RAW" "d['enactment']['public_id']")
ok "SL1 intro enactment pid = $ENACT_SL1_PID"

echo ">>> Adding completion trigger to SL1 enactment..."
info "Clicking 'complete-intro' → advance_to_next_storyline → ConditionalRoute is evaluated"
TRIG_SL1_RAW=$(curl -s -X POST "$BASE/api/enactment/$ENACT_SL1_PID/trigger" \
    -H "$CT" \
    -d "{
        \"subscriber_id\":     \"$SUB_ID\",
        \"name\":              \"Complete Introduction\",
        \"trigger_type\":      \"OnWebhook\",
        \"user_action_type\":  \"OnClick\",
        \"user_action_value\": \"https://example.com/complete-intro\",
        \"priority\":          1,
        \"then_do_this_action\": {
            \"action_name\": \"User Completed Intro — Evaluate Conditional Routes\",
            \"advance_to_next_storyline\": true
        }
    }")
echo "$TRIG_SL1_RAW" | pp
ok "SL1 completion trigger added → URL: https://example.com/complete-intro"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 6 — CREATE SL1 WITH CONDITIONAL_ROUTES"
# ═══════════════════════════════════════════════════════════════════════════════
# THIS IS THE CORE OF FEATURE 2.
#
# SL1.on_complete_begin.conditional_routes contains two routes:
#   Route 1 (priority=10, requires premium-member) → SL-PREMIUM
#   Route 2 (priority=1,  no requirements)         → SL-STANDARD
#
# The key JSON format for the next_storyline reference:
#   "next_storyline": {"_id": "<MongoDB ObjectId string>"}
#
# entity_story.go Hydrate() resolves this inline reference by fetching the full
# Storyline from MongoDB when cr.NextStoryline.Id.Valid() and Acts is empty.

echo ">>> Creating SL1 storyline WITH conditional_routes..."
info "Route priority=10: requires premium-member → goes to SL-PREMIUM (oid=$SL_PREM_OID)"
info "Route priority=1:  no requirements         → goes to SL-STANDARD (oid=$SL_STD_OID)"

SL1_RAW=$(curl -s -X POST "$BASE/api/storyline/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"SL1 — Introduction\",
        \"natural_order\": 1,
        \"on_complete_begin\": {
            \"conditional_routes\": [
                {
                    \"priority\": 10,
                    \"required_badges\": {
                        \"must_have\": [
                            {\"badge\": {\"public_id\": \"$BADGE_PREM_PID\"}}
                        ]
                    },
                    \"next_storyline\": {\"_id\": \"$SL_PREM_OID\"}
                },
                {
                    \"priority\": 1,
                    \"next_storyline\": {\"_id\": \"$SL_STD_OID\"}
                }
            ]
        }
    }")
echo "$SL1_RAW" | pp
SL1_PID=$(must_ok "SL1 storyline" "$SL1_RAW" "d['storyline']['public_id']")
SL1_OID=$(must_ok "SL1 storyline _id" "$SL1_RAW" "d['storyline']['_id']")
ok "SL1 pid=$SL1_PID  oid=$SL1_OID"

echo ">>> Linking SL1 intro enactment to SL1 storyline..."
curl -s -X POST "$BASE/api/storyline/$SL1_PID/enactments" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"enactment_id\":\"$ENACT_SL1_PID\"}" | pp
ok "SL1 intro enactment linked to SL1"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 7 — CREATE STORY AND LINK ALL STORYLINES"
# ═══════════════════════════════════════════════════════════════════════════════
# Story order: [SL1, SL-PREMIUM, SL-STANDARD]
# SL1's ConditionalRoutes will override the sequential order and send users
# directly to either SL-PREMIUM or SL-STANDARD when SL1 completes.

echo ">>> Creating story 'Premium Learning Path'..."
STORY_RAW=$(curl -s -X POST "$BASE/api/story/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"Premium Learning Path\",
        \"priority\":      1,
        \"allow_interruption\": false,
        \"start_trigger\": {
            \"badge\": {\"public_id\": \"$BADGE_START_PID\"}
        }
    }")
echo "$STORY_RAW" | pp
STORY_PID=$(must_ok "Story creation" "$STORY_RAW" "d['story']['public_id']")
ok "Story public_id = $STORY_PID"

echo ">>> Linking SL1 to story (first — everyone starts here)..."
curl -s -X POST "$BASE/api/story/$STORY_PID/storylines/$SL1_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}" | pp
ok "SL1 linked"

echo ">>> Linking SL-PREMIUM to story (target for premium users)..."
curl -s -X POST "$BASE/api/story/$STORY_PID/storylines/$SL_PREM_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}" | pp
ok "SL-PREMIUM linked"

echo ">>> Linking SL-STANDARD to story (default fallback)..."
curl -s -X POST "$BASE/api/story/$STORY_PID/storylines/$SL_STD_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}" | pp
ok "SL-STANDARD linked"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 8 — ENROLL BOTH USERS"
# ═══════════════════════════════════════════════════════════════════════════════

echo ">>> Enrolling user-standard (adding story-start badge)..."
curl -s -X PUT "$BASE/api/user_badge/user/$USER_STD_PID/badge/$BADGE_START_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}" | pp
ok "user-standard enrolled → intro email scheduled"

echo
echo ">>> Enrolling user-premium (adding story-start badge)..."
curl -s -X PUT "$BASE/api/user_badge/user/$USER_PREM_PID/badge/$BADGE_START_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}" | pp
ok "user-premium enrolled → intro email scheduled"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 9 — ADD 'premium-member' BADGE TO user-premium ONLY"
# ═══════════════════════════════════════════════════════════════════════════════
# After this step, user-premium satisfies Route 1's RequiredBadges.
# When they complete SL1, selectConditionalRoute() returns SL-PREMIUM.
# user-standard gets Route 2 (the fallback with no badge requirements).

echo ">>> Adding 'premium-member' badge to user-premium ONLY..."
curl -s -X PUT "$BASE/api/user_badge/user/$USER_PREM_PID/badge/$BADGE_PREM_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}" | pp
ok "user-premium now has premium-member badge"
info "user-standard does NOT have premium-member badge"

echo
echo ">>> Waiting 5 seconds for scheduler to send intro emails..."
sleep 5
ok "Intro emails should be visible in MailHog at $MAILHOG_UI"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 10 — user-standard completes SL1 (routed to SL-STANDARD)"
# ═══════════════════════════════════════════════════════════════════════════════
# user-standard clicks the intro completion URL.
# advance_to_next_storyline fires → SL1 marked Complete → ConditionalRoutes evaluated:
#   Route 1 (priority=10, requires premium-member) → FAILS (no badge) → skip
#   Route 2 (priority=1, no requirements) → PASSES → user goes to SL-STANDARD
# A new email with subject "[STANDARD PATH] Welcome to the Standard Module!" arrives.

echo -e "${BLD}${YLW}╔══ 👆 ACTION REQUIRED ══════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${YLW}║  MAILHOG: $MAILHOG_UI${RST}"
echo -e "${BLD}${YLW}╟────────────────────────────────────────────────────────────────────╢${RST}"
echo -e "${BLD}${YLW}║  STEP 1 — Route user-standard (no premium badge → STANDARD MODULE):${RST}"
echo -e "${BLD}${YLW}║    • Open MailHog → find email for: user-standard@demo.local${RST}"
echo -e "${BLD}${YLW}║    • Subject: '[SL1] Your Learning Path Introduction'${RST}"
echo -e "${BLD}${YLW}║    • Click '✅ I've Completed the Introduction — Route Me!' button${RST}"
echo -e "${BLD}${YLW}║      (clicking fires the webhook automatically)${RST}"
echo -e "${BLD}${YLW}║    • Route 1 (priority=10, requires premium-member): FAILS — no badge${RST}"
echo -e "${BLD}${YLW}║    • Route 2 (priority=1, no requirements): PASSES → user-standard → SL-STANDARD${RST}"
echo -e "${BLD}${YLW}║    • Watch MailHog for a new email: '📚 [STANDARD PATH] Welcome...'${RST}"
echo -e "${BLD}${YLW}╚════════════════════════════════════════════════════════════════════╝${RST}"
press_enter
echo ">>> Waiting 8 seconds for routing to complete..."
sleep 8
echo ">>> Checking user-standard state after SL1 completion..."
STD_STATE=$(curl -s -X GET "$BASE/api/user/$USER_STD_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}")
echo "$STD_STATE" | pp
ok "user-standard routed — verify '[STANDARD PATH]' email arrived in MailHog"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 11 — user-premium completes SL1 (routed to SL-PREMIUM)"
# ═══════════════════════════════════════════════════════════════════════════════
# user-premium clicks the intro completion URL.
# advance_to_next_storyline fires → SL1 marked Complete → ConditionalRoutes evaluated:
#   Route 1 (priority=10, requires premium-member) → PASSES (has badge) → user goes to SL-PREMIUM
#   Route 2 is never checked (Route 1 matched first).
# A new email with subject "[PREMIUM PATH] Welcome to the Advanced Module!" arrives.

echo -e "${BLD}${YLW}╔══ 👆 ACTION REQUIRED ══════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${YLW}║  STEP 2 — Route user-premium (HAS premium badge → PREMIUM MODULE):${RST}"
echo -e "${BLD}${YLW}║    • In MailHog → find email for: user-premium@demo.local${RST}"
echo -e "${BLD}${YLW}║    • Subject: '[SL1] Your Learning Path Introduction'${RST}"
echo -e "${BLD}${YLW}║    • Click '✅ I've Completed the Introduction — Route Me!' button${RST}"
echo -e "${BLD}${YLW}║      (clicking fires the webhook automatically)${RST}"
echo -e "${BLD}${YLW}║    • Route 1 (priority=10, requires premium-member): PASSES → SL-PREMIUM${RST}"
echo -e "${BLD}${YLW}║    • Watch MailHog for a new email: '✅ [PREMIUM PATH] Welcome...'${RST}"
echo -e "${BLD}${YLW}╚════════════════════════════════════════════════════════════════════╝${RST}"
press_enter
echo ">>> Waiting 8 seconds for routing to complete..."
sleep 8
echo ">>> Checking user-premium state after SL1 completion..."
PREM_STATE=$(curl -s -X GET "$BASE/api/user/$USER_PREM_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}")
echo "$PREM_STATE" | pp
ok "user-premium routed — verify '[PREMIUM PATH]' email arrived in MailHog"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 12 — INSTRUCTIONS FOR THE TESTER"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BLD}${GRN}════════════════════════════════════════════════════════════════${RST}"
echo -e "${BLD}${GRN}  ✅  CONDITIONAL ROUTING DEMO COMPLETE!${RST}"
echo -e "${BLD}${GRN}════════════════════════════════════════════════════════════════${RST}"
echo ""
echo -e "${BLD}${CYN}OPEN MAILHOG:${RST}  $MAILHOG_UI"
echo ""
echo -e "${BLD}${YLW}WHAT JUST HAPPENED:${RST}"
echo "  user-standard@demo.local should have received TWO emails:"
echo "    1. '[SL1] Your Learning Path Introduction' (everyone gets this)"
echo "    2. '📚 [STANDARD PATH] Welcome to the Standard Module!' (routed here)"
echo ""
echo "  user-premium@demo.local should have received TWO emails:"
echo "    1. '[SL1] Your Learning Path Introduction' (everyone gets this)"
echo "    2. '✅ [PREMIUM PATH] Welcome to the Advanced Module!' (routed here)"
echo ""
echo -e "${BLD}${YLW}THE KEY ROUTING MECHANISM:${RST}"
echo "  SL1 was created with on_complete_begin.conditional_routes:"
echo "    [{priority:10, required_badges:{must_have:[premium-member]}, next_storyline:{_id:$SL_PREM_OID}},"
echo "     {priority:1,  (no badge requirement),                       next_storyline:{_id:$SL_STD_OID}}]"
echo ""
echo "  When advance_to_next_storyline fires, entity_god.go's AdvanceToNextStoryline():"
echo "    1. Calls selectConditionalRoute(user, SL1.OnComplete.ConditionalRoutes)"
echo "    2. Sorts routes by Priority DESC"
echo "    3. Evaluates each route's RequiredBadges against user's badge set"
echo "    4. Returns the first route that passes → overrides sequential ordering"
echo ""
echo -e "${BLD}${YLW}SERVER LOG EVIDENCE:${RST}"
echo "  Look for: 'AdvanceToNextStoryline: user ... storyline ...'"
echo "  And:      'selectConditionalRoute: route priority=10 ...'"
echo ""
echo -e "${BLD}${YLW}DEMO IDs:${RST}"
echo "  SUBSCRIBER_ID  = $SUB_ID"
echo "  USER_STD_PID   = $USER_STD_PID"
echo "  USER_PREM_PID  = $USER_PREM_PID"
echo "  BADGE_PREM_PID = $BADGE_PREM_PID"
echo "  SL1_PID        = $SL1_PID    (SL-PREM_OID=$SL_PREM_OID)"
echo "  SL_PREM_PID    = $SL_PREM_PID (SL-STD_OID=$SL_STD_OID)"
echo "  STORY_PID      = $STORY_PID"
echo ""
echo -e "${BLD}${CYN}════════════════════════════════════════════════════════════════${RST}"
echo -e "${BLD}${CYN}  Feature 2 demonstrated: conditional on-complete routing! 🗺️${RST}"
echo -e "${BLD}${CYN}════════════════════════════════════════════════════════════════${RST}"
echo ""
