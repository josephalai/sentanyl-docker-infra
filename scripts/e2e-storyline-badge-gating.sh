#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# SENTANYL — End-to-End: Storyline-Level Badge Gating (Feature 5)
#            "Adaptive Learning Path — Skip Gated Modules"
#
# WHAT THIS DEMO SHOWS:
#   Individual storylines can carry RequiredUserBadges gate conditions.
#   When AdvanceToNextStoryline() would move a user into a gated storyline,
#   canEnterStoryline() checks whether the user satisfies the gate.  If not,
#   the engine SKIPS that storyline and tries the next one in sequence.
#
# WHY IT MATTERS:
#   Before: all users in a story traveled through ALL storylines, regardless of
#           their qualifications or progress level.
#   After:  a single story can serve multiple audience segments; beginners skip
#           advanced modules automatically, and advanced users skip beginner ones.
#
# HOW IT WORKS:
#   • Storyline.RequiredUserBadges.MustHave / MustNotHave gates the storyline.
#   • entity_god.go canEnterStoryline() checks whether user satisfies the gate.
#   • AdvanceToNextStoryline() calls canEnterStoryline() on each candidate and
#     skips storylines whose conditions are not met, logging each skip.
#   • If the gated storyline is skipped, the engine continues to the next
#     sequential storyline until one is found that the user can enter.
#
# BEFORE vs AFTER:
#   BEFORE: Badge gating only existed at the Story level (start_trigger).
#           Once inside a story, users moved through every storyline.
#   AFTER:  Each storyline is independently gateable.  A user can be in the same
#           story as another but travel a completely different path of storylines.
#
# STORY — "Adaptive Learning Path":
#   SL1:  "Introduction"     — no requirements (everyone starts here)
#   SL2:  "Advanced Module"  — requires "advanced-learner" badge (GATED)
#   SL3:  "Conclusion"       — no requirements (everyone finishes here)
#
#   TWO users:
#     user-basic:    no advanced-learner badge  → SL1 → SKIP SL2 → SL3
#     user-advanced: has advanced-learner badge → SL1 → SL2    → SL3
#
# VERIFICATION:
#   The SL2 and SL3 enactments have DISTINCT email subjects.
#   After SL1 completion:
#     user-basic    → SL3 email arrives (SL2 was skipped)
#     user-advanced → SL2 email arrives (SL2 was entered)
#   Watch MailHog for the subjects to confirm correct routing.
#
# HOW TO RUN:
#   1.  ./go.sh  (API server + MailHog)
#   2.  bash scripts/e2e-storyline-badge-gating.sh
#   3.  Open MailHog at http://localhost:8025 to confirm email subjects
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
hdr "PHASE 1 — CREATOR & TWO USERS"
# ═══════════════════════════════════════════════════════════════════════════════

CREATOR_EMAIL="learning-gate-$(date +%s)@sentanyl-demo.local"

echo ">>> Registering creator ($CREATOR_EMAIL)..."
CREATOR_RAW=$(curl -s -X POST "$BASE/api/register" \
    -H "$CT" \
    -d "{
        \"first_name\": \"Adaptive\",
        \"last_name\":  \"Learning\",
        \"email\":      \"$CREATOR_EMAIL\",
        \"reply_to\":   \"$CREATOR_EMAIL\",
        \"password\":   \"AdaptLearn123!\",
        \"list_name\":  \"Adaptive Learning List\"
    }")
echo "$CREATOR_RAW" | pp
SUB_ID=$(must_ok "Creator registration" "$CREATOR_RAW" "d['creator']['public_id']")
ok "creator subscriber_id = $SUB_ID"

echo
echo ">>> Registering user-basic (will skip the Advanced Module)..."
USER_BASIC_RAW=$(curl -s -X POST "$BASE/api/register/user" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"email\":         \"user-basic@demo.local\",
        \"first_name\":    \"Basic\",
        \"last_name\":     \"Learner\"
    }")
USER_BASIC_PID=$(must_ok "user-basic" "$USER_BASIC_RAW" "d['user']['public_id']")
ok "user-basic public_id = $USER_BASIC_PID"

echo
echo ">>> Registering user-advanced (will enter the Advanced Module)..."
USER_ADV_RAW=$(curl -s -X POST "$BASE/api/register/user" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"email\":         \"user-advanced@demo.local\",
        \"first_name\":    \"Advanced\",
        \"last_name\":     \"Learner\"
    }")
USER_ADV_PID=$(must_ok "user-advanced" "$USER_ADV_RAW" "d['user']['public_id']")
ok "user-advanced public_id = $USER_ADV_PID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 2 — CREATE BADGES"
# ═══════════════════════════════════════════════════════════════════════════════

echo ">>> Creating 'story-start' badge (enrolls users in the learning path story)..."
B_START_RAW=$(curl -s -X POST "$BASE/api/badge/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"name\":\"story-start\",\"description\":\"Starts the Adaptive Learning Path story\"}")
BADGE_START_PID=$(must_ok "story-start badge" "$B_START_RAW" "d['badge']['public_id']")
ok "story-start = $BADGE_START_PID"

echo ">>> Creating 'advanced-learner' badge (gates SL2 Advanced Module)..."
B_ADV_RAW=$(curl -s -X POST "$BASE/api/badge/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"name\":\"advanced-learner\",\"description\":\"Required to enter the Advanced Module storyline (SL2)\"}")
BADGE_ADV_PID=$(must_ok "advanced-learner badge" "$B_ADV_RAW" "d['badge']['public_id']")
ok "advanced-learner = $BADGE_ADV_PID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 3 — CREATE ENACTMENTS FOR ALL THREE STORYLINES"
# ═══════════════════════════════════════════════════════════════════════════════
# Each enactment has a UNIQUE and clearly labelled email subject so that the
# tester can verify routing by looking at emails in MailHog.

echo ">>> Creating SL1 — Introduction enactment..."
SL1_BODY=$(json_str "<html><body style='background:#f0fdf4;font-family:Arial;padding:28px'>
<h2 style='color:#065f46'>📖 Introduction to Adaptive Learning</h2>
<p>Everyone starts with this introduction.  When you click the completion link,
Sentanyl will check your badge profile and route you to either:</p>
<ul>
  <li><strong>Advanced Module (SL2)</strong> — if you have the advanced-learner badge</li>
  <li><strong>Conclusion (SL3)</strong> — if you do NOT have the advanced-learner badge
      (SL2 is SKIPPED)</li>
</ul>
<p>This demonstrates Feature 5: Storyline-Level Badge Gating.</p>
<a href='https://example.com/complete-sl1'
   style='background:#065f46;color:#fff;text-decoration:none;padding:12px 24px;border-radius:6px;display:inline-block;margin-top:16px'>
  ✅ Complete Introduction
</a>
<p style='font-size:11px;color:#999;margin-top:16px'>SL1 Introduction — Feature 5 Demo</p>
</body></html>")

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
                    \"subject\":    \"[SL1] Introduction to the Adaptive Learning Path\",
                    \"from_email\": \"$CREATOR_EMAIL\",
                    \"from_name\":  \"Adaptive Learning\",
                    \"reply_to\":   \"$CREATOR_EMAIL\",
                    \"body\":       $SL1_BODY
                }
            }
        }
    }")
echo "$ENACT_SL1_RAW" | pp
ENACT_SL1_PID=$(must_ok "SL1 enactment" "$ENACT_SL1_RAW" "d['enactment']['public_id']")
ok "SL1 enactment pid = $ENACT_SL1_PID"

echo ">>> Adding completion trigger to SL1 enactment (advance_to_next_storyline)..."
TRIG_SL1_RAW=$(curl -s -X POST "$BASE/api/enactment/$ENACT_SL1_PID/trigger" \
    -H "$CT" \
    -d "{
        \"subscriber_id\":     \"$SUB_ID\",
        \"name\":              \"Complete Introduction\",
        \"trigger_type\":      \"OnWebhook\",
        \"user_action_type\":  \"OnClick\",
        \"user_action_value\": \"https://example.com/complete-sl1\",
        \"priority\":          1,
        \"then_do_this_action\": {
            \"action_name\": \"SL1 Complete — Evaluate RequiredUserBadges on next storyline\",
            \"advance_to_next_storyline\": true
        }
    }")
echo "$TRIG_SL1_RAW" | pp
ok "SL1 completion trigger: https://example.com/complete-sl1"

echo
echo ">>> Creating SL2 — Advanced Module enactment..."
SL2_BODY=$(json_str "<html><body style='background:#eff6ff;font-family:Arial;padding:28px'>
<h2 style='color:#1e40af'>🎓 Advanced Module — You Qualified!</h2>
<p><strong>You're seeing this email because you have the advanced-learner badge.</strong></p>
<p>Sentanyl's AdvanceToNextStoryline() checked your RequiredUserBadges when leaving SL1
and found you qualify for SL2 (required: advanced-learner badge ✓).</p>
<p>Users WITHOUT the advanced-learner badge were routed directly to SL3 (Conclusion),
completely skipping this Advanced Module.</p>
<p style='font-size:11px;color:#999'>SL2 Advanced Module — Feature 5 Demo</p>
</body></html>")

ENACT_SL2_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"SL2 — Advanced Module\",
        \"natural_order\": 1,
        \"send_scene\": {
            \"name\": \"Advanced Module Scene\",
            \"message\": {
                \"content\": {
                    \"subject\":    \"[SL2 — ADVANCED] You Qualified for the Advanced Module!\",
                    \"from_email\": \"$CREATOR_EMAIL\",
                    \"from_name\":  \"Adaptive Learning\",
                    \"reply_to\":   \"$CREATOR_EMAIL\",
                    \"body\":       $SL2_BODY
                }
            }
        }
    }")
echo "$ENACT_SL2_RAW" | pp
ENACT_SL2_PID=$(must_ok "SL2 enactment" "$ENACT_SL2_RAW" "d['enactment']['public_id']")
ok "SL2 enactment pid = $ENACT_SL2_PID"

echo
echo ">>> Creating SL3 — Conclusion enactment..."
SL3_BODY=$(json_str "<html><body style='background:#fdf4ff;font-family:Arial;padding:28px'>
<h2 style='color:#7e22ce'>🏁 Conclusion — Course Complete!</h2>
<p>You've reached the final module!</p>
<p style='background:#fef3c7;padding:12px;border-radius:8px'>
<strong>If you're user-basic:</strong> You were routed directly from SL1 to SL3,
bypassing the Advanced Module entirely (SL2 RequiredUserBadges gate was not met).
</p>
<p style='background:#dcfce7;padding:12px;border-radius:8px'>
<strong>If you're user-advanced:</strong> You completed SL1 → SL2 → SL3 (full path).
</p>
<p style='font-size:11px;color:#999'>SL3 Conclusion — Feature 5 Demo</p>
</body></html>")

echo ">>> Creating SL3 — Conclusion enactment..."
ENACT_SL3_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"SL3 — Conclusion\",
        \"natural_order\": 1,
        \"send_scene\": {
            \"name\": \"Conclusion Scene\",
            \"message\": {
                \"content\": {
                    \"subject\":    \"[SL3 — CONCLUSION] Course Complete!\",
                    \"from_email\": \"$CREATOR_EMAIL\",
                    \"from_name\":  \"Adaptive Learning\",
                    \"reply_to\":   \"$CREATOR_EMAIL\",
                    \"body\":       $SL3_BODY
                }
            }
        }
    }")
echo "$ENACT_SL3_RAW" | pp
ENACT_SL3_PID=$(must_ok "SL3 enactment" "$ENACT_SL3_RAW" "d['enactment']['public_id']")
ok "SL3 enactment pid = $ENACT_SL3_PID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 4 — CREATE STORYLINES WITH BADGE GATING"
# ═══════════════════════════════════════════════════════════════════════════════
# THIS IS THE CORE OF FEATURE 5.
#
# SL1: natural_order=1, NO required_user_badges (everyone enters)
# SL2: natural_order=2, required_user_badges.must_have=[{badge:{public_id:advanced-learner}}]
#      → canEnterStoryline() will return false for user-basic → SKIPPED
# SL3: natural_order=3, NO required_user_badges (everyone enters eventually)

echo ">>> Creating SL1 storyline (no badge gate — everyone enters)..."
SL1_SL_RAW=$(curl -s -X POST "$BASE/api/storyline/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"SL1 — Introduction\",
        \"natural_order\": 1
    }")
echo "$SL1_SL_RAW" | pp
SL1_PID=$(must_ok "SL1 storyline" "$SL1_SL_RAW" "d['storyline']['public_id']")
ok "SL1 pid = $SL1_PID  (natural_order=1, no badge gate)"

curl -s -X POST "$BASE/api/storyline/$SL1_PID/enactments" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"enactment_id\":\"$ENACT_SL1_PID\"}" | pp
ok "SL1 Introduction enactment linked"

echo
echo ">>> Creating SL2 storyline WITH required_user_badges gate..."
info "This is Feature 5's key: storyline-level badge gating via required_user_badges"
info "Users without advanced-learner badge will be SKIPPED by canEnterStoryline()"

SL2_SL_RAW=$(curl -s -X POST "$BASE/api/storyline/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"SL2 — Advanced Module\",
        \"natural_order\": 2,
        \"required_user_badges\": {
            \"must_have\": [
                {\"badge\": {\"public_id\": \"$BADGE_ADV_PID\"}}
            ]
        }
    }")
echo "$SL2_SL_RAW" | pp
SL2_PID=$(must_ok "SL2 storyline" "$SL2_SL_RAW" "d['storyline']['public_id']")
ok "SL2 pid = $SL2_PID  (natural_order=2, GATED: requires advanced-learner)"

curl -s -X POST "$BASE/api/storyline/$SL2_PID/enactments" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"enactment_id\":\"$ENACT_SL2_PID\"}" | pp
ok "SL2 Advanced Module enactment linked"

echo
echo ">>> Creating SL3 storyline (no badge gate — everyone reaches this)..."
SL3_SL_RAW=$(curl -s -X POST "$BASE/api/storyline/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"SL3 — Conclusion\",
        \"natural_order\": 3
    }")
echo "$SL3_SL_RAW" | pp
SL3_PID=$(must_ok "SL3 storyline" "$SL3_SL_RAW" "d['storyline']['public_id']")
ok "SL3 pid = $SL3_PID  (natural_order=3, no badge gate)"

curl -s -X POST "$BASE/api/storyline/$SL3_PID/enactments" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"enactment_id\":\"$ENACT_SL3_PID\"}" | pp
ok "SL3 Conclusion enactment linked"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 5 — CREATE STORY AND LINK ALL THREE STORYLINES"
# ═══════════════════════════════════════════════════════════════════════════════

echo ">>> Creating story 'Adaptive Learning Path'..."
STORY_RAW=$(curl -s -X POST "$BASE/api/story/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"Adaptive Learning Path\",
        \"priority\":      1,
        \"allow_interruption\": false,
        \"start_trigger\": {
            \"badge\": {\"public_id\": \"$BADGE_START_PID\"}
        }
    }")
echo "$STORY_RAW" | pp
STORY_PID=$(must_ok "Story" "$STORY_RAW" "d['story']['public_id']")
ok "Story pid = $STORY_PID"

echo ">>> Linking storylines to story in order [SL1, SL2, SL3]..."
for sl_pid in "$SL1_PID" "$SL2_PID" "$SL3_PID"; do
    curl -s -X POST "$BASE/api/story/$STORY_PID/storylines/$sl_pid" \
        -H "$CT" \
        -d "{\"subscriber_id\":\"$SUB_ID\"}" | pp
    ok "  Storyline $sl_pid linked"
done

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 6 — ENROLL BOTH USERS"
# ═══════════════════════════════════════════════════════════════════════════════

echo ">>> Enrolling user-basic (adding story-start badge)..."
curl -s -X PUT "$BASE/api/user_badge/user/$USER_BASIC_PID/badge/$BADGE_START_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}" | pp
ok "user-basic enrolled — SL1 Introduction email scheduled"

echo
echo ">>> Enrolling user-advanced (adding story-start badge)..."
curl -s -X PUT "$BASE/api/user_badge/user/$USER_ADV_PID/badge/$BADGE_START_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}" | pp
ok "user-advanced enrolled — SL1 Introduction email scheduled"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 7 — ADD 'advanced-learner' BADGE TO user-advanced ONLY"
# ═══════════════════════════════════════════════════════════════════════════════
# This is the key differentiator for SL2 routing.
# user-basic:    does NOT have advanced-learner → canEnterStoryline(SL2) = false → SKIP
# user-advanced: HAS advanced-learner           → canEnterStoryline(SL2) = true  → ENTER

echo ">>> Adding 'advanced-learner' badge to user-advanced ONLY..."
info "user-basic will NOT have this badge — SL2 will be skipped for them"
curl -s -X PUT "$BASE/api/user_badge/user/$USER_ADV_PID/badge/$BADGE_ADV_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}" | pp
ok "user-advanced now has advanced-learner badge"
info "user-basic still has NO advanced-learner badge"

echo
echo ">>> Waiting 5 seconds for Introduction emails to arrive..."
sleep 5
ok "Check MailHog — both users should have '[SL1] Introduction' email"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 8 — BOTH USERS COMPLETE SL1 (triggers storyline gating check)"
# ═══════════════════════════════════════════════════════════════════════════════
# When advance_to_next_storyline fires, entity_god.go:
#   1. Marks SL1 as Complete
#   2. Calls AdvanceToNextStoryline()
#   3. Tries SL2 (natural_order=2)
#   4. Calls canEnterStoryline(user, SL2)
#      - user-basic:    SL2.RequiredUserBadges.MustHave=[advanced-learner], user doesn't have it → false → SKIP
#      - user-advanced: SL2.RequiredUserBadges.MustHave=[advanced-learner], user HAS it → true → ENTER
#   5. user-basic falls through to SL3 (no gate) → SL3 entered
#   6. user-advanced enters SL2 → SL2 email sent

echo -e "${BLD}${YLW}╔══ 👆 ACTION REQUIRED ══════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${YLW}║  MAILHOG: $MAILHOG_UI${RST}"
echo -e "${BLD}${YLW}╟────────────────────────────────────────────────────────────────────╢${RST}"
echo -e "${BLD}${YLW}║  STEP 1 — user-basic (NO advanced-learner badge) completes SL1:${RST}"
echo -e "${BLD}${YLW}║    • Find the email for: user-basic@demo.local${RST}"
echo -e "${BLD}${YLW}║    • Subject: '[SL1] Introduction to the Adaptive Learning Path'${RST}"
echo -e "${BLD}${YLW}║    • Click '✅ Complete Introduction' button${RST}"
echo -e "${BLD}${YLW}║      (clicking fires the webhook automatically)${RST}"
echo -e "${BLD}${YLW}║    • AdvanceToNextStoryline tries SL2:${RST}"
echo -e "${BLD}${YLW}║        canEnterStoryline(user-basic, SL2) = FALSE (lacks advanced-learner)${RST}"
echo -e "${BLD}${YLW}║        SL2 SKIPPED → user-basic falls through to SL3${RST}"
echo -e "${BLD}${YLW}║    • Watch for email: '[SL3 — CONCLUSION] Course Complete!'${RST}"
echo -e "${BLD}${YLW}╚════════════════════════════════════════════════════════════════════╝${RST}"
press_enter
echo ">>> Waiting 5 seconds for routing to complete..."
sleep 5
echo ">>> Checking user-basic state..."
BASIC_STATE_8=$(curl -s -X GET "$BASE/api/user/$USER_BASIC_PID" \
    -H "$CT" -d "{\"subscriber_id\":\"$SUB_ID\"}")
echo "$BASIC_STATE_8" | pp
ok "user-basic SL1 completed — verify '[SL3 — CONCLUSION]' email in MailHog"

echo ""
echo -e "${BLD}${YLW}╔══ 👆 ACTION REQUIRED ══════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${YLW}║  STEP 2 — user-advanced (HAS advanced-learner badge) completes SL1:${RST}"
echo -e "${BLD}${YLW}║    • Find the email for: user-advanced@demo.local${RST}"
echo -e "${BLD}${YLW}║    • Subject: '[SL1] Introduction to the Adaptive Learning Path'${RST}"
echo -e "${BLD}${YLW}║    • Click '✅ Complete Introduction' button${RST}"
echo -e "${BLD}${YLW}║      (clicking fires the webhook automatically)${RST}"
echo -e "${BLD}${YLW}║    • AdvanceToNextStoryline tries SL2:${RST}"
echo -e "${BLD}${YLW}║        canEnterStoryline(user-advanced, SL2) = TRUE (has advanced-learner)${RST}"
echo -e "${BLD}${YLW}║        SL2 ENTERED → user-advanced gets the advanced module${RST}"
echo -e "${BLD}${YLW}║    • Watch for email: '[SL2 — ADVANCED] You Qualified...'${RST}"
echo -e "${BLD}${YLW}╚════════════════════════════════════════════════════════════════════╝${RST}"
press_enter
echo ">>> Waiting 5 seconds for routing to complete..."
sleep 5
echo ">>> Checking user-advanced state..."
ADV_STATE_8=$(curl -s -X GET "$BASE/api/user/$USER_ADV_PID" \
    -H "$CT" -d "{\"subscriber_id\":\"$SUB_ID\"}")
echo "$ADV_STATE_8" | pp
ok "user-advanced SL1 completed — verify '[SL2 — ADVANCED]' email in MailHog"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 9 — VERIFY USER STATES"
# ═══════════════════════════════════════════════════════════════════════════════

echo ">>> Checking user-basic state..."
BASIC_STATE=$(curl -s -X GET "$BASE/api/user/$USER_BASIC_PID" \
    -H "$CT" -d "{\"subscriber_id\":\"$SUB_ID\"}")
BASIC_STATUS=$(echo "$BASIC_STATE" | jval "d.get('message',{}).get('user',{}).get('story_status','?')" 2>/dev/null || echo "?")
echo "$BASIC_STATE" | pp
info "user-basic story_status = $BASIC_STATUS (should be InProgress in SL3)"

echo
echo ">>> Checking user-advanced state..."
ADV_STATE=$(curl -s -X GET "$BASE/api/user/$USER_ADV_PID" \
    -H "$CT" -d "{\"subscriber_id\":\"$SUB_ID\"}")
ADV_STATUS=$(echo "$ADV_STATE" | jval "d.get('message',{}).get('user',{}).get('story_status','?')" 2>/dev/null || echo "?")
echo "$ADV_STATE" | pp
info "user-advanced story_status = $ADV_STATUS (should be InProgress in SL2)"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 10 — INSTRUCTIONS FOR THE TESTER"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BLD}${GRN}════════════════════════════════════════════════════════════════${RST}"
echo -e "${BLD}${GRN}  ✅  STORYLINE BADGE GATING DEMO COMPLETE!${RST}"
echo -e "${BLD}${GRN}════════════════════════════════════════════════════════════════${RST}"
echo ""
echo -e "${BLD}${CYN}OPEN MAILHOG:${RST}  $MAILHOG_UI"
echo ""
echo -e "${BLD}${YLW}EXPECTED EMAILS FOR user-basic@demo.local:${RST}"
echo "  1. [SL1] Introduction to the Adaptive Learning Path"
echo "     → Both users get this (no gate on SL1)"
echo "  2. [SL3 — CONCLUSION] Course Complete!"
echo "     → SL2 was SKIPPED — user-basic lacks advanced-learner badge"
echo ""
echo -e "${BLD}${YLW}EXPECTED EMAILS FOR user-advanced@demo.local:${RST}"
echo "  1. [SL1] Introduction to the Adaptive Learning Path"
echo "     → Both users get this (no gate on SL1)"
echo "  2. [SL2 — ADVANCED] You Qualified for the Advanced Module!"
echo "     → SL2 gate MET — user-advanced has advanced-learner badge"
echo "  (SL3 will arrive after user-advanced completes SL2)"
echo ""
echo -e "${BLD}${YLW}SERVER LOG EVIDENCE:${RST}"
echo "  'AdvanceToNextStoryline: user ... does not meet badge requirements for storyline'"
echo "  '  ... skipping'"
echo "  'AdvanceToNextStoryline: user ... does not meet badge requirements for storyline'"
echo "  '  ... scanning sequential fallback'"
echo "  These log lines show canEnterStoryline() returning false for user-basic + SL2."
echo ""
echo -e "${BLD}${YLW}KEY API PATTERN — BADGE-GATED STORYLINE:${RST}"
echo "  POST /api/storyline/"
echo "  {"
echo "    \"subscriber_id\": \"...\","
echo "    \"name\": \"SL2 — Advanced Module\","
echo "    \"natural_order\": 2,"
echo "    \"required_user_badges\": {"
echo "      \"must_have\": ["
echo "        {\"badge\": {\"public_id\": \"$BADGE_ADV_PID\"}}"
echo "      ]"
echo "    }"
echo "  }"
echo ""
echo -e "${BLD}${YLW}YOU CAN ALSO USE must_not_have TO SKIP A MODULE FOR EXPERT USERS:${RST}"
echo "  \"required_user_badges\": {"
echo "    \"must_not_have\": [{\"badge\": {\"public_id\": \"expert-badge-pid\"}}]"
echo "  }"
echo "  → Experts (who already have the expert badge) skip the beginner module."
echo ""
echo -e "${BLD}${YLW}DEMO IDs:${RST}"
echo "  SUBSCRIBER_ID  = $SUB_ID"
echo "  USER_BASIC_PID = $USER_BASIC_PID  (no advanced-learner badge → skips SL2)"
echo "  USER_ADV_PID   = $USER_ADV_PID    (has advanced-learner badge → enters SL2)"
echo "  BADGE_ADV_PID  = $BADGE_ADV_PID"
echo "  SL1_PID        = $SL1_PID  (natural_order=1, no gate)"
echo "  SL2_PID        = $SL2_PID  (natural_order=2, gated)"
echo "  SL3_PID        = $SL3_PID  (natural_order=3, no gate)"
echo "  STORY_PID      = $STORY_PID"
echo ""
echo -e "${BLD}${CYN}════════════════════════════════════════════════════════════════${RST}"
echo -e "${BLD}${CYN}  Feature 5 demonstrated: storyline-level badge gating! 🎓${RST}"
echo -e "${BLD}${CYN}════════════════════════════════════════════════════════════════${RST}"
echo ""
