#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# SENTANYL — End-to-End: Story Priority / Interruption (Feature 3)
#            "Cart Abandonment Interrupts Newsletter"
#
# WHAT THIS DEMO SHOWS:
#   Stories carry Priority and AllowInterruption flags.  When a user is in an
#   active (allow_interruption=true) lower-priority story and they receive a badge
#   that starts a higher-priority story, the engine PAUSES the current story,
#   stores its position in user.interrupted_stories, and starts the new story.
#   When the higher-priority story ends, the engine RESUMES the paused story
#   from exactly where the user left off.
#
# WHY IT MATTERS:
#   Before: a user's position in a running story could not be interrupted.
#           A "cart abandonment" campaign had no way to pre-empt a newsletter.
#   After:  transactional / urgent stories (cart, flash sale, OTP) can interrupt
#           lower-priority sequences and then seamlessly hand control back.
#
# HOW IT WORKS:
#   1. Story.Priority (int) and Story.AllowInterruption (bool) are set at creation.
#   2. entity_god.go AddBadgeToUser() checks: if a new story has higher priority
#      AND the current story has AllowInterruption=true, it calls
#      user.StoreInterruptedStory() (saves CurrentStory/Storyline/Enactment to
#      user.InterruptedStories slice) and starts the new story.
#   3. When the high-priority story ends (EndStory), ResumeInterruptedStory() pops
#      the last entry from user.InterruptedStories and restores the cursor,
#      re-installs the HotTrigger, and sends the next enactment's email.
#
# BEFORE vs AFTER:
#   BEFORE: Starting a story while one was active would either fail or clobber
#           the user's current position.
#   AFTER:  The user's position is saved, the high-priority story runs to
#           completion, and the original story resumes automatically.
#
# STORY:
#   LOW-PRIORITY:  "Monthly Newsletter" (priority=1, allow_interruption=true)
#                  3 enactments (Newsletter #1, #2, #3)
#                  Trigger: "newsletter-subscriber" badge
#
#   HIGH-PRIORITY: "Cart Abandonment Recovery" (priority=10, allow_interruption=false)
#                  1 enactment with a "Complete Purchase" click link
#                  Trigger: "cart-abandoned" badge
#                  Completing the purchase (clicking link) ends the cart story
#                  → engine resumes newsletter from where it was interrupted,
#                    advancing past the already-received enactment
#
# FLOW:
#   1. User joins newsletter (story_status = InProgress)
#   2. Newsletter #1 arrives
#   3. User "abandons cart" (gets cart-abandoned badge mid-sequence)
#   4. Cart recovery story INTERRUPTS newsletter (interrupted_stories has 1 entry)
#   5. Cart recovery email arrives
#   6. User clicks "Complete Purchase" → cart story ends
#   7. Newsletter RESUMES → Newsletter #3 arrives (skips already-received #2)
#
# HOW TO RUN:
#   1.  ./go.sh  (API server + MailHog, DEBUG mode recommended)
#   2.  bash scripts/e2e-story-interruption.sh
#   3.  Open MailHog to watch emails arrive; watch server logs for
#       "interrupting story" and "ResumeInterruptedStory" messages
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

check_user_state() {
    local label="$1" user_pid="$2"
    local state status interrupted
    state=$(curl -s -X GET "$BASE/api/user/$user_pid" \
        -H "$CT" -d "{\"subscriber_id\":\"$SUB_ID\"}")
    status=$(echo "$state" | jval "d.get('message',{}).get('user',{}).get('story_status','?')" 2>/dev/null || echo "?")
    interrupted=$(echo "$state" | jval "len(d.get('message',{}).get('user',{}).get('interrupted_stories',[]))" 2>/dev/null || echo "0")
    echo "$state" | pp
    info "$label: story_status=$status  interrupted_stories_count=$interrupted"
    echo "$status"
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
hdr "PHASE 1 — CREATOR & ONE USER"
# ═══════════════════════════════════════════════════════════════════════════════

CREATOR_EMAIL="interruption-demo-$(date +%s)@sentanyl-demo.local"

echo ">>> Registering creator ($CREATOR_EMAIL)..."
CREATOR_RAW=$(curl -s -X POST "$BASE/api/register" \
    -H "$CT" \
    -d "{
        \"first_name\": \"Interruption\",
        \"last_name\":  \"Demo\",
        \"email\":      \"$CREATOR_EMAIL\",
        \"reply_to\":   \"$CREATOR_EMAIL\",
        \"password\":   \"DemoPass123!\",
        \"list_name\":  \"Interruption Demo List\"
    }")
echo "$CREATOR_RAW" | pp
SUB_ID=$(must_ok "Creator registration" "$CREATOR_RAW" "d['creator']['public_id']")
ok "creator subscriber_id = $SUB_ID"

echo
echo ">>> Registering demo user..."
USER_RAW=$(curl -s -X POST "$BASE/api/register/user" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"email\":         \"demo-user@demo.local\",
        \"first_name\":    \"Demo\",
        \"last_name\":     \"User\"
    }")
echo "$USER_RAW" | pp
USER_PID=$(must_ok "User registration" "$USER_RAW" "d['user']['public_id']")
ok "user public_id = $USER_PID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 2 — CREATE BADGES"
# ═══════════════════════════════════════════════════════════════════════════════

echo ">>> Creating 'newsletter-subscriber' badge (starts low-priority story)..."
BADGE_NEWS_RAW=$(curl -s -X POST "$BASE/api/badge/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"name\":\"newsletter-subscriber\",\"description\":\"Joins the monthly newsletter sequence\"}")
BADGE_NEWS_PID=$(must_ok "newsletter-subscriber badge" "$BADGE_NEWS_RAW" "d['badge']['public_id']")
ok "newsletter-subscriber = $BADGE_NEWS_PID"

echo ">>> Creating 'cart-abandoned' badge (triggers high-priority interruption)..."
BADGE_CART_RAW=$(curl -s -X POST "$BASE/api/badge/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"name\":\"cart-abandoned\",\"description\":\"User abandoned a cart — triggers high-priority recovery story\"}")
BADGE_CART_PID=$(must_ok "cart-abandoned badge" "$BADGE_CART_RAW" "d['badge']['public_id']")
ok "cart-abandoned = $BADGE_CART_PID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 3 — CREATE NEWSLETTER ENACTMENTS (low-priority story)"
# ═══════════════════════════════════════════════════════════════════════════════
# Three newsletter emails.  wait_until=1 minute between each so the scheduler
# auto-advances after each one (if the user doesn't click anything).
# The INTERRUPTION demo will fire BEFORE newsletter-2 arrives.

for n in 1 2 3; do
    NEWS_BODY=$(json_str "<html><body style='background:#f0f9ff;font-family:Arial;padding:28px'>
<h2 style='color:#0369a1'>📰 Monthly Newsletter #${n}</h2>
<p>This is newsletter email <strong>#${n} of 3</strong> in the low-priority story.</p>
$([ "$n" = "1" ] && echo "<p style='background:#fef3c7;padding:12px;border-radius:8px'>
<strong>🚨 DEMO NOTE:</strong> After you see this email, run Phase 8 to simulate
a cart abandonment. The cart recovery story will INTERRUPT this newsletter mid-sequence.
After the cart recovery completes, newsletter #2 will resume automatically.
</p>" || echo "")
<p style='font-size:11px;color:#999'>Feature 3: Story Priority / Interruption — Low-Priority Story | Email #${n}</p>
</body></html>")

    echo ">>> Creating Newsletter #${n} enactment..."
    ENACT_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
        -H "$CT" \
        -d "{
            \"subscriber_id\": \"$SUB_ID\",
            \"name\":          \"Newsletter #${n}\",
            \"natural_order\": $n,
            \"send_scene\": {
                \"name\": \"Newsletter Scene ${n}\",
                \"message\": {
                    \"content\": {
                        \"subject\":    \"[NEWSLETTER #${n}/3] Your Monthly Update\",
                        \"from_email\": \"$CREATOR_EMAIL\",
                        \"from_name\":  \"Monthly Newsletter\",
                        \"reply_to\":   \"$CREATOR_EMAIL\",
                        \"body\":       $NEWS_BODY
                    }
                }
            }
        }")
    N_PID=$(must_ok "Newsletter #${n}" "$ENACT_RAW" "d['enactment']['public_id']")
    _kset NEWS_PID "$n" "$N_PID"
    ok "Newsletter #${n} enactment pid = $N_PID"

    # Add auto-advance trigger (wait 1 minute, then advance to next enactment)
    TRIG_RAW=$(curl -s -X POST "$BASE/api/enactment/$N_PID/trigger" \
        -H "$CT" \
        -d "{
            \"subscriber_id\":     \"$SUB_ID\",
            \"name\":              \"Newsletter #${n} Auto-Advance\",
            \"trigger_type\":      \"OnWebhook\",
            \"user_action_type\":  \"OnClick\",
            \"user_action_value\": \"https://example.com/newsletter-${n}-advance\",
            \"priority\":          1,
            \"then_do_this_action\": {
                \"action_name\": \"Newsletter #${n} Completed\",
                \"advance_to_next_storyline\": false,
                \"when\": {\"wait_until\": {\"wait_until\": 1, \"time_unit\": \"minutes\"}}
            }
        }")
    ok "  Newsletter #${n} advance trigger added"
done

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 4 — CREATE CART RECOVERY ENACTMENT (high-priority story)"
# ═══════════════════════════════════════════════════════════════════════════════
# A single cart recovery email.  Clicking "Complete Purchase" fires
# advance_to_next_storyline → cart story ends → newsletter RESUMES.

CART_BODY=$(json_str "<html><body style='background:#fff7ed;font-family:Arial;padding:28px'>
<h2 style='color:#c2410c'>🛒 Don't Forget Your Cart!</h2>
<p style='color:#7c2d12'>
  <strong>IMPORTANT:</strong> This email INTERRUPTED your newsletter sequence.
  Your newsletter is paused and waiting.
</p>
<p style='color:#7c2d12'>
  You left items in your cart!  Complete your purchase now and we'll
  get you right back to your regular newsletter content.
</p>
<table width='100%' cellpadding='0' cellspacing='0'>
  <tr>
    <td align='center' style='padding:20px 0'>
      <a href='https://example.com/complete-purchase'
         style='background:#c2410c;color:#fff;text-decoration:none;padding:14px 32px;
                border-radius:8px;font-size:16px;font-weight:bold;display:inline-block'>
        ✅ Complete My Purchase (Resumes Newsletter)
      </a>
    </td>
  </tr>
</table>
<p style='color:#7c2d12;font-size:12px'>
  Clicking this button ends the Cart Recovery story.
  Sentanyl will automatically resume your newsletter sequence.
</p>
<p style='font-size:11px;color:#999'>Feature 3: Story Priority / Interruption — High-Priority Story</p>
</body></html>")

echo ">>> Creating cart recovery enactment..."
ENACT_CART_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"Cart Recovery Email\",
        \"natural_order\": 1,
        \"send_scene\": {
            \"name\": \"Cart Recovery Scene\",
            \"message\": {
                \"content\": {
                    \"subject\":    \"🛒 [CART RECOVERY — INTERRUPTING NEWSLETTER] Don't forget your cart!\",
                    \"from_email\": \"$CREATOR_EMAIL\",
                    \"from_name\":  \"Cart Recovery\",
                    \"reply_to\":   \"$CREATOR_EMAIL\",
                    \"body\":       $CART_BODY
                }
            }
        }
    }")
echo "$ENACT_CART_RAW" | pp
ENACT_CART_PID=$(must_ok "Cart recovery enactment" "$ENACT_CART_RAW" "d['enactment']['public_id']")
ok "Cart recovery enactment pid = $ENACT_CART_PID"

echo ">>> Adding 'Complete Purchase' trigger to cart recovery enactment..."
info "Clicking 'complete-purchase' → advance_to_next_storyline → cart story ends → newsletter resumes"
TRIG_CART_RAW=$(curl -s -X POST "$BASE/api/enactment/$ENACT_CART_PID/trigger" \
    -H "$CT" \
    -d "{
        \"subscriber_id\":     \"$SUB_ID\",
        \"name\":              \"Complete Purchase\",
        \"trigger_type\":      \"OnWebhook\",
        \"user_action_type\":  \"OnClick\",
        \"user_action_value\": \"https://example.com/complete-purchase\",
        \"priority\":          1,
        \"then_do_this_action\": {
            \"action_name\": \"Purchase Completed — End Cart Story, Resume Newsletter\",
            \"advance_to_next_storyline\": true
        }
    }")
echo "$TRIG_CART_RAW" | pp
ok "Cart recovery trigger added: https://example.com/complete-purchase"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 5 — CREATE STORYLINES AND STORIES"
# ═══════════════════════════════════════════════════════════════════════════════

echo ">>> Creating Newsletter storyline..."
SL_NEWS_RAW=$(curl -s -X POST "$BASE/api/storyline/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"name\":\"Newsletter Storyline\",\"natural_order\":1}")
SL_NEWS_PID=$(must_ok "Newsletter storyline" "$SL_NEWS_RAW" "d['storyline']['public_id']")
ok "Newsletter storyline pid = $SL_NEWS_PID"

# Link all 3 newsletter enactments to the newsletter storyline
for n in 1 2 3; do
    n_pid=$(_kget NEWS_PID "$n")
    curl -s -X POST "$BASE/api/storyline/$SL_NEWS_PID/enactments" \
        -H "$CT" \
        -d "{\"subscriber_id\":\"$SUB_ID\",\"enactment_id\":\"$n_pid\"}" > /dev/null
    ok "  Newsletter #${n} linked to Newsletter storyline"
done

echo ">>> Creating Cart Recovery storyline..."
SL_CART_RAW=$(curl -s -X POST "$BASE/api/storyline/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"name\":\"Cart Recovery Storyline\",\"natural_order\":1}")
SL_CART_PID=$(must_ok "Cart Recovery storyline" "$SL_CART_RAW" "d['storyline']['public_id']")
ok "Cart Recovery storyline pid = $SL_CART_PID"

curl -s -X POST "$BASE/api/storyline/$SL_CART_PID/enactments" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"enactment_id\":\"$ENACT_CART_PID\"}" | pp
ok "Cart Recovery enactment linked to Cart Recovery storyline"

echo ">>> Creating LOW-PRIORITY Newsletter Story (priority=1, allow_interruption=TRUE)..."
info "AllowInterruption=true means a higher-priority story CAN pause this one"
STORY_NEWS_RAW=$(curl -s -X POST "$BASE/api/story/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\":    \"$SUB_ID\",
        \"name\":             \"Monthly Newsletter\",
        \"priority\":         1,
        \"allow_interruption\": true,
        \"start_trigger\": {
            \"badge\": {\"public_id\": \"$BADGE_NEWS_PID\"}
        }
    }")
echo "$STORY_NEWS_RAW" | pp
STORY_NEWS_PID=$(must_ok "Newsletter Story" "$STORY_NEWS_RAW" "d['story']['public_id']")
ok "Newsletter Story pid = $STORY_NEWS_PID  (priority=1, allow_interruption=true)"

curl -s -X POST "$BASE/api/story/$STORY_NEWS_PID/storylines/$SL_NEWS_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}" | pp
ok "Newsletter storyline linked to Newsletter story"

echo ">>> Creating HIGH-PRIORITY Cart Recovery Story (priority=10, allow_interruption=FALSE)..."
info "Priority=10 > 1, so this will interrupt the newsletter when cart-abandoned badge is added"
info "AllowInterruption=false means NOTHING can interrupt this cart recovery"
STORY_CART_RAW=$(curl -s -X POST "$BASE/api/story/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\":    \"$SUB_ID\",
        \"name\":             \"Cart Abandonment Recovery\",
        \"priority\":         10,
        \"allow_interruption\": false,
        \"start_trigger\": {
            \"badge\": {\"public_id\": \"$BADGE_CART_PID\"}
        }
    }")
echo "$STORY_CART_RAW" | pp
STORY_CART_PID=$(must_ok "Cart Recovery Story" "$STORY_CART_RAW" "d['story']['public_id']")
ok "Cart Recovery Story pid = $STORY_CART_PID  (priority=10, allow_interruption=false)"

curl -s -X POST "$BASE/api/story/$STORY_CART_PID/storylines/$SL_CART_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}" | pp
ok "Cart Recovery storyline linked to Cart Recovery story"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 6 — ENROLL USER IN NEWSLETTER (start low-priority story)"
# ═══════════════════════════════════════════════════════════════════════════════
# Adding the newsletter-subscriber badge auto-joins the newsletter story.
# The user's current_story = Newsletter, story_status = InProgress.

echo ">>> Adding 'newsletter-subscriber' badge to user..."
info "This triggers JoinStory for the Newsletter (priority=1) story"
curl -s -X PUT "$BASE/api/user_badge/user/$USER_PID/badge/$BADGE_NEWS_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}" | pp
ok "User joined Newsletter story — Newsletter #1 email scheduled"

echo
echo ">>> Waiting 10 seconds for Newsletter #1 email to arrive..."
sleep 10
echo ">>> Checking user state (should be in Newsletter, InProgress)..."
STATE_BEFORE=$(curl -s -X GET "$BASE/api/user/$USER_PID" \
    -H "$CT" -d "{\"subscriber_id\":\"$SUB_ID\"}")
STATUS_BEFORE=$(echo "$STATE_BEFORE" | jval "d.get('message',{}).get('user',{}).get('story_status','?')" 2>/dev/null || echo "?")
INTERRUPTED_BEFORE=$(echo "$STATE_BEFORE" | jval "len(d.get('message',{}).get('user',{}).get('interrupted_stories',[]))" 2>/dev/null || echo "0")
echo "$STATE_BEFORE" | pp
info "BEFORE INTERRUPTION: story_status=$STATUS_BEFORE  interrupted_stories_count=$INTERRUPTED_BEFORE"
ok "Setup: Newsletter #1 email should be visible in MailHog"
echo ""
echo -e "${BLD}${YLW}╔══ 👆 ACTION REQUIRED ══════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${YLW}║  Open MailHog at: $MAILHOG_UI${RST}"
echo -e "${BLD}${YLW}║  Confirm you can see the '[NEWSLETTER #1/3] Your Monthly Update' email.${RST}"
echo -e "${BLD}${YLW}║  This proves the newsletter story is running.${RST}"
echo -e "${BLD}${YLW}║  Press Enter to continue to the cart abandonment phase.${RST}"
echo -e "${BLD}${YLW}╚════════════════════════════════════════════════════════════════════╝${RST}"
press_enter

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 7 — SIMULATE CART ABANDONMENT (trigger interruption)"
# ═══════════════════════════════════════════════════════════════════════════════
# Adding the 'cart-abandoned' badge fires AddBadgeToUser → getStoriesFromBadge
# → finds Cart Recovery story → checks: new priority(10) > current priority(1)
# AND current story AllowInterruption=true → StoreInterruptedStory()
# → user.InterruptedStories now has 1 entry (Newsletter position saved)
# → JoinStory(CartRecovery) → cart recovery email sent immediately

echo ""
echo -e "${BLD}${RED}🛒 CART ABANDONMENT PHASE${RST}"
echo ""
info "Engine will (once you run the command below):"
info "  1. Check: Cart Recovery priority(10) > Newsletter priority(1) ✓"
info "  2. Check: Newsletter AllowInterruption = true ✓"
info "  3. Call user.StoreInterruptedStory() — saves newsletter position"
info "  4. Switch user to Cart Recovery story"
info "  5. Send cart recovery email"
echo ""
echo -e "${BLD}${YLW}╔══ 👆 ACTION REQUIRED ══════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${YLW}║  CART ABANDONMENT — PLEASE RUN THIS COMMAND IN A SEPARATE TERMINAL:${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║    curl -s -X PUT $BASE/api/user_badge/user/$USER_PID/badge/$BADGE_CART_PID \\${RST}"
echo -e "${BLD}${YLW}║      -H 'Content-Type: application/json' \\${RST}"
echo -e "${BLD}${YLW}║      -d '{\"subscriber_id\":\"$SUB_ID\"}' | python3 -m json.tool${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  This simulates the cart system firing a webhook that adds the${RST}"
echo -e "${BLD}${YLW}║  'cart-abandoned' badge.  In a real deployment, your e-commerce${RST}"
echo -e "${BLD}${YLW}║  platform would call this endpoint automatically.${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  After running the command above, return here and press Enter.${RST}"
echo -e "${BLD}${YLW}╚════════════════════════════════════════════════════════════════════╝${RST}"
press_enter
poll_interrupted_count "$USER_PID" "1" "Newsletter interrupted by Cart Recovery" 60
poll_user_status "$USER_PID" "InProgress" "User in Cart Recovery story" 30
echo ""
ok "Check MailHog for '[CART RECOVERY — INTERRUPTING NEWSLETTER]' email"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 8 — USER COMPLETES PURCHASE (cart story ends → newsletter resumes)"
# ═══════════════════════════════════════════════════════════════════════════════
# Clicking the "Complete Purchase" link fires advance_to_next_storyline on the
# cart recovery storyline.  With no more cart storylines, EndStory() is called.
# EndStory → ResumeInterruptedStory() → pops the saved newsletter position,
# restores the cursor (CurrentStory, CurrentStoryline, CurrentEnactment),
# re-installs the HotTrigger, and sends Newsletter #2 immediately.

info "Engine will (once you click the link):"
info "  1. advance_to_next_storyline on Cart Recovery → no more storylines → EndStory()"
info "  2. EndStory → ResumeInterruptedStory()"
info "  3. Pop newsletter position from interrupted_stories"
info "  4. Restore user.CurrentStory/Storyline/Enactment to Newsletter #2"
info "  5. AdvanceToNextEnactment → advances cursor to Newsletter #3 (skips re-sending #2)"
echo ""
echo -e "${BLD}${YLW}╔══ 👆 ACTION REQUIRED ══════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${YLW}║  PURCHASE COMPLETION — Open MailHog at: $MAILHOG_UI${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  You should now see an email:${RST}"
echo -e "${BLD}${YLW}║    '[CART RECOVERY — INTERRUPTING NEWSLETTER] Don't forget your cart!'${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  Click the '✅ Complete My Purchase (Resumes Newsletter)' button.${RST}"
echo -e "${BLD}${YLW}║  (clicking fires the webhook automatically)${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  This will:${RST}"
echo -e "${BLD}${YLW}║    1. Fire advance_to_next_storyline on Cart Recovery → EndStory()${RST}"
echo -e "${BLD}${YLW}║    2. EndStory → ResumeInterruptedStory() → restores newsletter cursor${RST}"
echo -e "${BLD}${YLW}║    3. AdvanceToNextEnactment → Newsletter #3 email arrives immediately${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  After clicking, return here and press Enter.${RST}"
echo -e "${BLD}${YLW}╚════════════════════════════════════════════════════════════════════╝${RST}"
press_enter
poll_interrupted_count "$USER_PID" "0" "Newsletter resumed (interrupted_stories cleared)" 90

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 9 — INSTRUCTIONS FOR THE TESTER"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BLD}${GRN}════════════════════════════════════════════════════════════════${RST}"
echo -e "${BLD}${GRN}  ✅  STORY INTERRUPTION DEMO COMPLETE!${RST}"
echo -e "${BLD}${GRN}════════════════════════════════════════════════════════════════${RST}"
echo ""
echo -e "${BLD}${CYN}OPEN MAILHOG:${RST}  $MAILHOG_UI"
echo ""
echo -e "${BLD}${YLW}EXPECTED EMAIL SEQUENCE IN MAILHOG:${RST}"
echo "  1. [NEWSLETTER #1/3] Your Monthly Update"
echo "     → Newsletter story started, user is in Newsletter #1 enactment"
echo ""
echo "  2. [CART RECOVERY — INTERRUPTING NEWSLETTER] Don't forget your cart!"
echo "     → cart-abandoned badge added, high-priority story INTERRUPTED newsletter"
echo "     → user.interrupted_stories had 1 entry (Newsletter #2 position saved)"
echo ""
echo "  3. [NEWSLETTER #3/3] Your Monthly Update"
echo "     → User clicked 'Complete Purchase', cart story ended"
echo "     → ResumeInterruptedStory() restored the newsletter cursor to Newsletter #2"
echo "     → AdvanceToNextEnactment() advanced past #2 (already received) to Newsletter #3"
echo ""
echo -e "${BLD}${YLW}SERVER LOG EVIDENCE (look for these messages):${RST}"
echo "  'AddBadgeToUser: interrupting story ... (priority 1) for story ... (priority 10)'"
echo "  'StoreInterruptedStory: ...'"
echo "  'ResumeInterruptedStory: user ... resumed interrupted story ...'"
echo ""
echo -e "${BLD}${YLW}KEY STORY CREATION FLAGS:${RST}"
echo "  Newsletter story:     priority=1,  allow_interruption=TRUE"
echo "  Cart Recovery story:  priority=10, allow_interruption=FALSE"
echo "  (The interruption logic: new.Priority > current.Priority AND current.AllowInterruption)"
echo ""
echo -e "${BLD}${YLW}WHAT HAPPENS WITHOUT allow_interruption:${RST}"
echo "  If the Newsletter had allow_interruption=false, the cart-abandoned badge"
echo "  would still be added but the cart recovery story would NOT interrupt."
echo "  The user would finish the newsletter first, then start cart recovery."
echo ""
echo -e "${BLD}${YLW}DEMO IDs:${RST}"
echo "  SUBSCRIBER_ID    = $SUB_ID"
echo "  USER_PID         = $USER_PID"
echo "  BADGE_NEWS_PID   = $BADGE_NEWS_PID"
echo "  BADGE_CART_PID   = $BADGE_CART_PID"
echo "  STORY_NEWS_PID   = $STORY_NEWS_PID  (priority=1,  allow_interruption=true)"
echo "  STORY_CART_PID   = $STORY_CART_PID  (priority=10, allow_interruption=false)"
echo ""
echo -e "${BLD}${CYN}════════════════════════════════════════════════════════════════${RST}"
echo -e "${BLD}${CYN}  Feature 3 demonstrated: story priority + interruption! 🔄${RST}"
echo -e "${BLD}${CYN}════════════════════════════════════════════════════════════════${RST}"
echo ""
