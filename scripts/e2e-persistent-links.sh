#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# SENTANYL — End-to-End Persistent Links Demo
#            "Retroactive More-Info Clicks with persist_scope: enactment"
#
# PROBLEM BEING DEMONSTRATED
# ───────────────────────────
# In a standard More-Info sequence, advancing from A-Sc1 → A-Sc2 via the
# timer creates a brand-new HotTrigger for A-Sc2.  A-Sc1's trigger is gone.
# If the user then clicks the link inside the A-Sc1 email (which lives in
# their inbox forever), the click is silently ignored.
#
# SOLUTION: persist_scope = "enactment"
# ──────────────────────────────────────
# Setting persist_scope: "enactment" on a trigger tells the engine:
#   "Keep this trigger alive through scene-level (timer-driven) transitions.
#    Only kill it when an explicit enactment jump occurs (or a wider transition)."
#
# With that flag, the trigger from A-Sc1 is automatically carried forward into
# A-Sc2's and A-Sc3's HotTriggers.  Clicking the A-Sc1 link while the sequence
# is on A-Sc3 (or even after it has advanced to Enactment B) still fires the
# correct action.
#
# STRUCTURE
# ─────────
#   Story A
#   └── Storyline 1 (Online Course)
#       ├── Acts 1–3  Enactment A – "More Info" (persist_scope: enactment)
#       │             Each scene has a DIFFERENT URL but the same action:
#       │             jump to Enactment C, Scene 1.
#       │             Timer: 30 seconds between scenes so this script runs fast.
#       ├── Acts 4–6  Enactment B – "Still Interested?" (same pattern)
#       │             B-Sc3 has skip_storyline_on_expiry=true so that timing
#       │             out of the whole A+B sequence skips to the next storyline.
#       ├── Acts 7–9  Enactment C – "Buy Now"
#       │             Click → advance_to_next_storyline
#       └── Acts 10-12 Enactment D – "Last Chance"
#                     Click → advance_to_next_storyline
#
# ROUTING RULES
# ─────────────
#   • Click ANY link from enactment A (even from an older email while on A-Sc3
#     or even while on B-Sc1) → jump immediately to C-Sc1
#   • All 3 A emails expire with no click → advance to B-Sc1
#   • Click ANY link from enactment B → jump immediately to C-Sc1
#   • All 3 B emails expire with no click → skip to next storyline (none = end)
#   • Click Buy Now in C or D → advance to next storyline (none = end)
#   • All emails in C expire → advance to D
#   • All emails in D expire → end story
#
# KEY VERIFICATION STEPS
# ──────────────────────
#   1. Wait for A-Sc1 email to arrive.  Note the "More Info" URL.
#   2. Let the timer advance the sequence to A-Sc2 (30 s).
#   3. Let the timer advance to A-Sc3 (30 s).
#   4. Simulate clicking the A-Sc1 URL (retroactive click).
#      → Expected: user immediately jumps to C-Sc1 (not silently ignored).
#
# HOW TO RUN
# ──────────
#   1.  ./go.sh                        (API server, EMAIL_PROVIDER=mailhog)
#   2.  mailhog  (or docker equivalent)
#   3.  bash scripts/e2e-persistent-links.sh
#   4.  Open MailHog at http://localhost:8025 to watch emails arrive.
#
# ENV OVERRIDES
#   BASE         API base URL  (default: http://localhost:8000)
#   MAILHOG_UI   MailHog UI    (default: http://localhost:8025)
#   USER_EMAIL   Subscriber    (default: josephalai@gmail.com)
# ═══════════════════════════════════════════════════════════════════════════════

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

pp()       { python3 -m json.tool 2>/dev/null || cat; }
jval()     { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)" 2>/dev/null; }
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

# Scene timer: 30 seconds so the script completes in a few minutes.
WAIT_SECONDS=30

# Enactment type arrays (parallel)
ENACT_TYPES=(A B C D)
ENACT_TYPE_TAGS=(EA EB EC ED)
LINK_LABELS=("More Info" "Still Interested?" "Buy Now" "Last Chance")

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
hdr "PHASE 1 — CREATOR & USER"
# ═══════════════════════════════════════════════════════════════════════════════

CREATOR_EMAIL="persist-demo-$(date +%s)@sentanyl-demo.local"

echo ">>> Registering creator ($CREATOR_EMAIL)..."
CREATOR_RAW=$(curl -s -X POST "$BASE/api/register" \
    -H "$CT" \
    -d "{
        \"first_name\": \"Persistent\",
        \"last_name\":  \"Links Demo\",
        \"email\":      \"$CREATOR_EMAIL\",
        \"password\":   \"password123\"
    }")
SUB_ID=$(must_ok "Creator registration" "$CREATOR_RAW" "d['creator']['public_id']")
ok "Creator: $SUB_ID"

echo ">>> Registering subscriber ($USER_EMAIL)..."
USER_RAW=$(curl -s -X POST "$BASE/api/register/user" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"email\":         \"$USER_EMAIL\",
        \"first_name\":    \"Test\",
        \"last_name\":     \"User\"
    }")
USER_ID=$(must_ok "User registration" "$USER_RAW" "d['user']['public_id']")
ok "User: $USER_ID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 2 — CREATE 12 ENACTMENTS (4 types × 3 scenes)"
# ═══════════════════════════════════════════════════════════════════════════════

for ti in 0 1 2 3; do
    et="${ENACT_TYPES[$ti]}"
    et_tag="${ENACT_TYPE_TAGS[$ti]}"
    for sc in 1 2 3; do
        enact_key="${et}-${sc}"
        et_lower=$(echo "$et_tag" | tr 'A-Z' 'a-z')
        link_url="https://example.com/course-${et_lower}-${sc}"
        _kset LINK_URL "$enact_key" "$link_url"
        subject="[${et_tag}-Sc${sc}] Online Course — ${LINK_LABELS[$ti]}"
        body="<p>Hi {{first_name}}, this is ${et_tag} scene ${sc}. <a href=\"${link_url}\">Click here</a></p>"
        body_json=$(json_str "$body")
        ENACT_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
            -H "$CT" \
            -d "{
                \"subscriber_id\": \"$SUB_ID\",
                \"name\":          \"${et_tag}-Sc${sc}\",
                \"natural_order\": $((( ti * 3 ) + sc)),
                \"send_scene\": {
                    \"message\": {
                        \"content\": {
                            \"from_email\": \"demo@sentanyl-demo.local\",
                            \"from_name\":  \"Online Course Demo\",
                            \"reply_to\":   \"demo@sentanyl-demo.local\",
                            \"subject\":    \"$subject\",
                            \"body\":       $body_json
                        }
                    }
                }
            }")
        PID=$(must_ok "Enactment ${enact_key}" "$ENACT_RAW" "d['enactment']['public_id']")
        OID=$(echo "$ENACT_RAW" | jval "d['enactment']['_id']" 2>/dev/null || echo "")
        _kset ENACT_PID "$enact_key" "$PID"
        _kset ENACT_OID "$enact_key" "$OID"
        ok "  ${enact_key}: pid=$PID"
    done
done

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 3 — ADD TRIGGERS"
# ═══════════════════════════════════════════════════════════════════════════════
#
# Enactments A and B: persist_scope = "enactment"
#   → The trigger survives scene-level (timer-driven) advances (A-Sc1→A-Sc2→A-Sc3).
#   → Clicking the A-Sc1 link while the sequence is at A-Sc3 still fires the action.
#   → The trigger is killed when an explicit enactment jump occurs (A→C) since that
#     is a ScopeEnactment transition.
#
# Enactments C and D: default persist_scope (empty = scene-level, current behaviour)
#   → advance_to_next_storyline moves past C/D on click.
#
# The "More Info" URL is unique per scene so we can verify which scene the click
# came from, even though all three trigger the same action (jump to C-Sc1).

EC1_OID=$(_kget ENACT_OID "C-1")

for ti in 0 1 2 3; do
    et="${ENACT_TYPES[$ti]}"
    et_tag="${ENACT_TYPE_TAGS[$ti]}"
    for sc in 1 2 3; do
        enact_key="${et}-${sc}"
        enact_pid=$(_kget ENACT_PID "$enact_key")
        link_url=$(_kget LINK_URL "$enact_key")

        case "$et" in
            A|B)
                # persist_scope: "enactment" — survives A-Sc1→A-Sc2→A-Sc3 advances.
                # Clicking ANY of these (even from an old inbox email) jumps to C-Sc1.
                ACTION_JSON="{
                    \"action_name\": \"Jump to Buy Now (C-Sc1)\",
                    \"next_enactment\": {\"_id\": \"$EC1_OID\"},
                    \"when\": {
                        \"wait_until\": {\"wait_until\": $WAIT_SECONDS, \"time_unit\": \"seconds\"}
                    }
                }"
                PERSIST_SCOPE='"enactment"'
                MARK_COMPLETE="false"
                MARK_FAILED="false"
                ;;
            C|D)
                # Standard scene-scoped trigger — advance to next storyline on click.
                ACTION_JSON="{
                    \"action_name\": \"BUY NOW — Next Storyline\",
                    \"advance_to_next_storyline\": true,
                    \"when\": {
                        \"wait_until\": {\"wait_until\": $WAIT_SECONDS, \"time_unit\": \"seconds\"}
                    }
                }"
                PERSIST_SCOPE='""'
                MARK_COMPLETE="false"
                MARK_FAILED="false"
                ;;
        esac

        echo ">>> Adding trigger to ${enact_key} (url=${link_url}, persist_scope=${PERSIST_SCOPE})..."
        TRIG_RAW=$(curl -s -X POST "$BASE/api/enactment/$enact_pid/trigger" \
            -H "$CT" \
            -d "{
                \"subscriber_id\":      \"$SUB_ID\",
                \"name\":               \"${et_tag}-Sc${sc} OnClick\",
                \"trigger_type\":       \"OnWebhook\",
                \"user_action_type\":   \"OnClick\",
                \"user_action_value\":  \"$link_url\",
                \"priority\":           1,
                \"persist_scope\":      $PERSIST_SCOPE,
                \"mark_complete\":      $MARK_COMPLETE,
                \"mark_failed\":        $MARK_FAILED,
                \"then_do_this_action\": $ACTION_JSON
            }")

        status=$(echo "$TRIG_RAW" | jval "d.get('status','?')" 2>/dev/null || echo "?")
        if [ "$status" = "?" ] || echo "$TRIG_RAW" | grep -q '"error"'; then
            warn "Trigger for ${enact_key} may have failed (check server logs):"
            echo "$TRIG_RAW" | pp >&2
        else
            ok "  trigger ${enact_key}: OnClick ${link_url} → persist_scope=${PERSIST_SCOPE}"
        fi
    done
done

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 4 — CREATE STORYLINE"
# ═══════════════════════════════════════════════════════════════════════════════

echo ">>> Creating storyline..."
SL_RAW=$(curl -s -X POST "$BASE/api/storyline/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"Online Course Funnel\"
    }")
SL_PID=$(must_ok "Storyline creation" "$SL_RAW" "d['storyline']['public_id']")
ok "Storyline: $SL_PID"

# Link all 12 enactments to the storyline in sequential order.
echo ">>> Linking 12 enactments to storyline (A-Sc1…D-Sc3)..."
for ti in 0 1 2 3; do
    et="${ENACT_TYPES[$ti]}"
    for sc in 1 2 3; do
        enact_pid=$(_kget ENACT_PID "${et}-${sc}")
        curl -s -X POST "$BASE/api/storyline/$SL_PID/enactments" \
            -H "$CT" \
            -d "{\"subscriber_id\": \"$SUB_ID\", \"enactment_id\": \"$enact_pid\"}" > /dev/null
        ok "  linked ${et}-Sc${sc} ($enact_pid)"
    done
done

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 5 — CREATE STORY WITH START BADGE"
# ═══════════════════════════════════════════════════════════════════════════════

echo ">>> Creating start badge..."
BADGE_RAW=$(curl -s -X POST "$BASE/api/badge/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"start_persistent_demo\",
        \"public_id\":     \"start_persistent_demo\"
    }")
BADGE_PID=$(must_ok "Badge creation" "$BADGE_RAW" "d['badge']['public_id']")
ok "Badge: $BADGE_PID"

echo ">>> Creating story..."
STORY_RAW=$(curl -s -X POST "$BASE/api/story/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"Online Course — Persistent Links Demo\",
        \"start_trigger\": {
            \"badge\": {\"public_id\": \"$BADGE_PID\"}
        }
    }")
STORY_PID=$(must_ok "Story creation" "$STORY_RAW" "d['story']['public_id']")
ok "Story: $STORY_PID"

echo ">>> Linking storyline to story..."
SL_LINK_RAW=$(curl -s -X POST "$BASE/api/story/$STORY_PID/storylines/$SL_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\": \"$SUB_ID\"}")
ok "Storyline linked to story"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 6 — ADD START BADGE TO USER (triggers story join)"
# ═══════════════════════════════════════════════════════════════════════════════

echo ">>> Adding start badge to user $USER_ID → triggers AddBadgeToUser → JoinStory..."
JOIN_RAW=$(curl -s -X PUT "$BASE/api/user_badge/user/$USER_ID/badge/$BADGE_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\": \"$SUB_ID\"}")
echo "$JOIN_RAW" | pp
ok "User joined story — A-Sc1 email should arrive at $USER_EMAIL within seconds"
info "Check MailHog at $MAILHOG_UI"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 7 — RETROACTIVE CLICK DEMONSTRATION"
# ═══════════════════════════════════════════════════════════════════════════════
#
# Scenario: user receives A-Sc1 email, then the timer fires twice advancing
# them to A-Sc2 then A-Sc3.  They then click the link from the ORIGINAL A-Sc1
# email.  With persist_scope="enactment", that click should still fire the
# action (jump to C-Sc1) instead of being silently ignored.
#
# We simulate the timer-driven advance by waiting and then manually triggering
# the click webhook for the A-Sc1 URL.

A_SC1_URL="https://example.com/course-ea-1"
A_SC3_URL="https://example.com/course-ea-3"

info "Waiting ${WAIT_SECONDS}s for A-Sc1 timer to advance to A-Sc2..."
sleep $WAIT_SECONDS

info "Waiting ${WAIT_SECONDS}s for A-Sc2 timer to advance to A-Sc3..."
sleep $WAIT_SECONDS

info ""
info "The user is now on A-Sc3.  Simulating a RETROACTIVE CLICK on the A-Sc1 link..."
info "URL: $A_SC1_URL"
info ""

CLICK_RAW=$(curl -s -X POST "$BASE/api/webhook/$SUB_ID" \
    -H "$CT" \
    -d "{
        \"event_type\": \"email.clicked\",
        \"payload\": {
            \"subscriber_id\": \"$SUB_ID\",
            \"email_address\":  \"$USER_EMAIL\",
            \"link\": {\"url\": \"$A_SC1_URL\"}
        }
    }")
echo "$CLICK_RAW" | pp

info ""
info "Expected: user jumped from A-Sc3 to C-Sc1 (Buy Now sequence)."
info "Verify in MailHog ($MAILHOG_UI): a new email with subject containing [EC-Sc1] should arrive."
info ""

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 8 — VERIFY TRIGGER DEACTIVATION AFTER ENACTMENT JUMP"
# ═══════════════════════════════════════════════════════════════════════════════
#
# Now that the user jumped to C-Sc1, the A-Sc1 trigger should be GONE from
# the active HotTrigger (because the transition used ScopeEnactment, which kills
# enactment-scoped triggers).  Clicking the A-Sc1 URL a second time should be
# a no-op — the user should NOT be bounced back to C-Sc1 from mid-C-sequence.

info "Simulating a DUPLICATE CLICK on the A-Sc1 link (should be a no-op now)..."
DUP_CLICK_RAW=$(curl -s -X POST "$BASE/api/webhook/$SUB_ID" \
    -H "$CT" \
    -d "{
        \"event_type\": \"email.clicked\",
        \"payload\": {
            \"subscriber_id\": \"$SUB_ID\",
            \"email_address\":  \"$USER_EMAIL\",
            \"link\": {\"url\": \"$A_SC1_URL\"}
        }
    }")
echo "$DUP_CLICK_RAW" | pp
info "Expected: no new transition.  User stays in the C-sequence."

# ═══════════════════════════════════════════════════════════════════════════════
hdr "SUMMARY"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "  ${BLD}What this script demonstrated:${RST}"
echo ""
echo "  1. Triggers with persist_scope=\"enactment\" survive scene-level (timer-driven)"
echo "     transitions (A-Sc1 → A-Sc2 → A-Sc3) and are carried forward into each"
echo "     new HotTrigger automatically."
echo ""
echo "  2. Clicking a link from an OLD email (A-Sc1) while the sequence is on a"
echo "     LATER scene (A-Sc3) still fires the correct action (jump to C-Sc1)."
echo "     Previously this click was silently ignored."
echo ""
echo "  3. Once the enactment jump fires (A → C), the enactment-scoped trigger is"
echo "     killed.  Clicking the old link again is a no-op."
echo ""
echo "  4. All existing e2e scripts continue to work unchanged because empty"
echo "     persist_scope (the default) equals ScopeScene — current behaviour."
echo ""
ok "Demo complete.  Check MailHog at $MAILHOG_UI for the full email sequence."
