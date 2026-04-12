#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# SENTANYL — Multi-Link Click Tracking Demo
#
# This script builds a complete email marketing sequence where a single email
# contains MULTIPLE tracked links.  Each link, when clicked, triggers a
# different action:
#
#   Link 1 → https://example.com/buy      → Gives the user a "Buyer" badge
#   Link 2 → https://example.com/learn    → Advances user to next enactment
#   Link 3 → https://example.com/unsubscribe → Marks the story as complete
#   (You can add as many links as you like following the same pattern)
#
# HOW TO USE:
#   1. Start the server:  ./go.sh
#   2. Run this script:   bash scripts/link-tracking-demo.sh
#   3. Open your email client and look for the email from the demo creator.
#   4. Click each link — come back to the terminal to watch the effects.
#
# Everything is API-only. No seed functions.
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

BASE="${BASE:-http://localhost:8000}"
CT="Content-Type: application/json"

# ── helpers ─────────────────────────────────────────────────────────────────
pp()  { python3 -m json.tool 2>/dev/null || cat; }
jf()  { python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null; }
hdr() { echo -e "\n\033[1;36m═══ $* ═══\033[0m"; }
ok()  { echo -e "  \033[1;32m✓\033[0m $*"; }
err() { echo -e "  \033[1;31m✗\033[0m $*"; }

hdr "PHASE 1 — CREATOR REGISTRATION"

echo ">>> Creating creator account..."
CREATOR_RAW=$(curl -s -X POST "$BASE/api/register" \
  -H "$CT" \
  -d '{
    "first_name":  "Demo",
    "last_name":   "Creator",
    "email":       "demo-creator@example.com",
    "reply_to":    "demo-creator@example.com",
    "password":    "SecretPass123!",
    "list_name":   "Link Tracking Demo List"
  }')
echo "$CREATOR_RAW" | pp
SUBSCRIBER_ID=$(echo "$CREATOR_RAW" | jf "['creator']['public_id']")
ok "creator subscriber_id = $SUBSCRIBER_ID"

# ── Phase 2: Register subscriber ─────────────────────────────────────────────
hdr "PHASE 2 — SUBSCRIBER REGISTRATION"

echo ">>> Registering subscriber (update the email to YOUR real address)..."
USER_RAW=$(curl -s -X POST "$BASE/api/register/user" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"email\":         \"you@example.com\",
    \"first_name\":    \"Test\",
    \"last_name\":     \"Subscriber\"
  }")
echo "$USER_RAW" | pp
USER_PID=$(echo "$USER_RAW" | jf "['user']['public_id']")
ok "user public_id = $USER_PID"

# ── Phase 3: Create badges ────────────────────────────────────────────────────
hdr "PHASE 3 — BADGES"

echo ">>> Creating 'Buyer' badge..."
BUYER_BADGE_RAW=$(curl -s -X POST "$BASE/api/badge/" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"name\":          \"Buyer\",
    \"description\":   \"Clicked the buy link\"
  }")
echo "$BUYER_BADGE_RAW" | pp
BUYER_BADGE_PID=$(echo "$BUYER_BADGE_RAW" | jf "['badge']['public_id']")
ok "buyer badge public_id = $BUYER_BADGE_PID"

echo ">>> Creating 'Learner' badge..."
LEARNER_BADGE_RAW=$(curl -s -X POST "$BASE/api/badge/" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"name\":          \"Learner\",
    \"description\":   \"Clicked the learn link\"
  }")
echo "$LEARNER_BADGE_RAW" | pp
LEARNER_BADGE_PID=$(echo "$LEARNER_BADGE_RAW" | jf "['badge']['public_id']")
ok "learner badge public_id = $LEARNER_BADGE_PID"

# ── Phase 4: Create actions ───────────────────────────────────────────────────
hdr "PHASE 4 — ACTIONS"

echo ">>> Action 1: Give Buyer badge..."
ACTION_BUY_RAW=$(curl -s -X POST "$BASE/api/action/" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"action_name\":   \"Give Buyer Badge\",
    \"badge_transaction\": {
      \"give_badges\": [ {\"public_id\": \"$BUYER_BADGE_PID\"} ]
    }
  }")
echo "$ACTION_BUY_RAW" | pp
ACTION_BUY_PID=$(echo "$ACTION_BUY_RAW" | jf "['action']['public_id']")
ok "buy action public_id = $ACTION_BUY_PID"

echo ">>> Action 2: Give Learner badge + mark enactment complete..."
ACTION_LEARN_RAW=$(curl -s -X POST "$BASE/api/action/" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"action_name\":   \"Give Learner Badge\",
    \"badge_transaction\": {
      \"give_badges\": [ {\"public_id\": \"$LEARNER_BADGE_PID\"} ]
    }
  }")
echo "$ACTION_LEARN_RAW" | pp
ACTION_LEARN_PID=$(echo "$ACTION_LEARN_RAW" | jf "['action']['public_id']")
ok "learn action public_id = $ACTION_LEARN_PID"

echo ">>> Action 3: Unsubscribe user..."
ACTION_UNSUB_RAW=$(curl -s -X POST "$BASE/api/action/" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"action_name\":   \"Unsubscribe\",
    \"unsubscribe\":   true
  }")
echo "$ACTION_UNSUB_RAW" | pp
ACTION_UNSUB_PID=$(echo "$ACTION_UNSUB_RAW" | jf "['action']['public_id']")
ok "unsub action public_id = $ACTION_UNSUB_PID"

# ── Phase 5: Create the email template ───────────────────────────────────────
hdr "PHASE 5 — EMAIL TEMPLATE (with 3 tracked links)"

echo ">>> Creating template with 3 links..."
TMPL_RAW=$(curl -s -X POST "$BASE/api/template/" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"name\":          \"Multi-Link Email\",
    \"html\": \"<html><body>
<h1>Hello {{ first_name }}!</h1>
<p>Click the link that matches what you want to do:</p>
<p><a href='https://example.com/buy'>I want to buy</a></p>
<p><a href='https://example.com/learn'>I want to learn more</a></p>
<p><a href='https://example.com/unsubscribe'>Unsubscribe me</a></p>
</body></html>\"
  }")
echo "$TMPL_RAW" | pp
TMPL_PID=$(echo "$TMPL_RAW" | jf "['template']['public_id']")
ok "template public_id = $TMPL_PID"

# ── Phase 6: Build story structure ───────────────────────────────────────────
hdr "PHASE 6 — STORY STRUCTURE"

echo ">>> Creating scene (email + template)..."
SCENE_RAW=$(curl -s -X POST "$BASE/api/scene/" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"name\":          \"Multi-Link Scene\",
    \"message\": {
      \"content\": {
        \"subject\":    \"Choose your path!\",
        \"from_email\": \"demo-creator@example.com\",
        \"from_name\":  \"Demo Creator\",
        \"reply_to\":   \"demo-creator@example.com\",
        \"body\":       \"<a href='https://example.com/buy'>Buy</a> | <a href='https://example.com/learn'>Learn</a> | <a href='https://example.com/unsubscribe'>Unsub</a>\",
        \"template\":   {\"public_id\": \"$TMPL_PID\"}
      }
    }
  }")
echo "$SCENE_RAW" | pp
SCENE_PID=$(echo "$SCENE_RAW" | jf "['scene']['public_id']")
ok "scene public_id = $SCENE_PID"

echo ">>> Creating enactment..."
ENACTMENT_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"name\":          \"Choose Your Path Enactment\",
    \"level\":         1,
    \"natural_order\": 1
  }")
echo "$ENACTMENT_RAW" | pp
ENACTMENT_PID=$(echo "$ENACTMENT_RAW" | jf "['enactment']['public_id']")
ok "enactment public_id = $ENACTMENT_PID"

echo ">>> Registering per-link click triggers on the enactment..."

echo "  → Link 1: buy → give Buyer badge"
curl -s -X POST "$BASE/api/enactment/$ENACTMENT_PID/trigger" \
  -H "$CT" \
  -d "{
    \"subscriber_id\":      \"$SUBSCRIBER_ID\",
    \"name\":               \"Buy Link Click\",
    \"trigger_type\":       \"OnWebhook\",
    \"user_action_type\":   \"OnClick\",
    \"user_action_value\":  \"https://example.com/buy\",
    \"priority\":           1,
    \"then_do_this_action\": {
      \"action_name\":       \"Give Buyer Badge\",
      \"badge_transaction\": {
        \"give_badges\": [ {\"public_id\": \"$BUYER_BADGE_PID\"} ]
      }
    }
  }" | pp

echo "  → Link 2: learn → give Learner badge"
curl -s -X POST "$BASE/api/enactment/$ENACTMENT_PID/trigger" \
  -H "$CT" \
  -d "{
    \"subscriber_id\":      \"$SUBSCRIBER_ID\",
    \"name\":               \"Learn Link Click\",
    \"trigger_type\":       \"OnWebhook\",
    \"user_action_type\":   \"OnClick\",
    \"user_action_value\":  \"https://example.com/learn\",
    \"priority\":           1,
    \"then_do_this_action\": {
      \"action_name\":       \"Give Learner Badge\",
      \"badge_transaction\": {
        \"give_badges\": [ {\"public_id\": \"$LEARNER_BADGE_PID\"} ]
      }
    }
  }" | pp

echo "  → Link 3: unsubscribe → unsubscribe user"
curl -s -X POST "$BASE/api/enactment/$ENACTMENT_PID/trigger" \
  -H "$CT" \
  -d "{
    \"subscriber_id\":      \"$SUBSCRIBER_ID\",
    \"name\":               \"Unsub Link Click\",
    \"trigger_type\":       \"OnWebhook\",
    \"user_action_type\":   \"OnClick\",
    \"user_action_value\":  \"https://example.com/unsubscribe\",
    \"priority\":           1,
    \"then_do_this_action\": {
      \"action_name\": \"Unsubscribe\",
      \"unsubscribe\":  true
    }
  }" | pp

echo ">>> Creating storyline..."
STORYLINE_RAW=$(curl -s -X POST "$BASE/api/storyline/" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"name\":          \"Multi-Link Storyline\"
  }")
echo "$STORYLINE_RAW" | pp
STORYLINE_PID=$(echo "$STORYLINE_RAW" | jf "['storyline']['public_id']")
ok "storyline public_id = $STORYLINE_PID"

echo ">>> Adding enactment to storyline..."
curl -s -X POST "$BASE/api/storyline/$STORYLINE_PID/enactments" \
  -H "$CT" \
  -d "{\"subscriber_id\": \"$SUBSCRIBER_ID\", \"enactment_id\": \"$ENACTMENT_PID\"}" | pp

echo ">>> Creating story..."
STORY_RAW=$(curl -s -X POST "$BASE/api/story/" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"name\":          \"Multi-Link Story\"
  }")
echo "$STORY_RAW" | pp
STORY_PID=$(echo "$STORY_RAW" | jf "['story']['public_id']")
ok "story public_id = $STORY_PID"

echo ">>> Adding storyline to story..."
curl -s -X POST "$BASE/api/story/$STORY_PID/storylines/$STORYLINE_PID" \
  -H "$CT" \
  -d "{\"subscriber_id\": \"$SUBSCRIBER_ID\"}" | pp

# ── Phase 7: Enroll user in story ────────────────────────────────────────────
hdr "PHASE 7 — ENROLL USER IN STORY"

echo ">>> Starting story for user (enrolls, sets up hot triggers, sends email)..."
START_RAW=$(curl -s -X PUT "$BASE/api/story/$STORY_PID/start" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"user_id\":       \"$USER_PID\"
  }")
echo "$START_RAW" | pp
ok "User enrolled in story"

# ── Phase 8: Register per-user link triggers ─────────────────────────────────
hdr "PHASE 8 — REGISTER PER-USER LINK TRIGGERS"
echo ">>> Registering link triggers directly on the user's live HotTrigger..."

echo "  → Buy link"
curl -s -X POST "$BASE/api/user/$USER_PID/link-trigger" \
  -H "$CT" \
  -d "{
    \"subscriber_id\":      \"$SUBSCRIBER_ID\",
    \"name\":               \"Buy Link\",
    \"user_action_value\":  \"https://example.com/buy\",
    \"priority\":           1,
    \"then_do_this_action\": {
      \"action_name\":       \"Give Buyer Badge\",
      \"badge_transaction\": {
        \"give_badges\": [ {\"public_id\": \"$BUYER_BADGE_PID\"} ]
      }
    }
  }" | pp

echo "  → Learn link"
curl -s -X POST "$BASE/api/user/$USER_PID/link-trigger" \
  -H "$CT" \
  -d "{
    \"subscriber_id\":      \"$SUBSCRIBER_ID\",
    \"name\":               \"Learn Link\",
    \"user_action_value\":  \"https://example.com/learn\",
    \"priority\":           1,
    \"then_do_this_action\": {
      \"action_name\":       \"Give Learner Badge\",
      \"badge_transaction\": {
        \"give_badges\": [ {\"public_id\": \"$LEARNER_BADGE_PID\"} ]
      }
    }
  }" | pp

echo "  → Unsubscribe link"
curl -s -X POST "$BASE/api/user/$USER_PID/link-trigger" \
  -H "$CT" \
  -d "{
    \"subscriber_id\":      \"$SUBSCRIBER_ID\",
    \"name\":               \"Unsub Link\",
    \"user_action_value\":  \"https://example.com/unsubscribe\",
    \"priority\":           1,
    \"then_do_this_action\": {
      \"action_name\": \"Unsubscribe\",
      \"unsubscribe\":  true
    }
  }" | pp

# ── Phase 9: Simulate clicks ─────────────────────────────────────────────────
hdr "PHASE 9 — SIMULATE LINK CLICKS"
echo ">>> In a real scenario you would click the links in your email."
echo "    We can also simulate the webhook directly:"
echo ""

echo "  Simulating 'buy' link click..."
curl -s -X POST "$BASE/api/webhooks/email/clicked" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"email_address\":  \"you@example.com\",
    \"link\": { \"url\": \"https://example.com/buy\" }
  }" | pp

echo ""
echo "  Checking user's badges after buy click..."
curl -s -X GET "$BASE/api/user/$USER_PID" \
  -H "$CT" \
  -d "{\"subscriber_id\": \"$SUBSCRIBER_ID\"}" | pp

echo ""
echo "  Simulating 'learn' link click..."
curl -s -X POST "$BASE/api/webhooks/email/clicked" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"email_address\":  \"you@example.com\",
    \"link\": { \"url\": \"https://example.com/learn\" }
  }" | pp

echo ""
echo "  Checking user's badges after learn click..."
curl -s -X GET "$BASE/api/user/$USER_PID" \
  -H "$CT" \
  -d "{\"subscriber_id\": \"$SUBSCRIBER_ID\"}" | pp

# ── Phase 10: Stats ───────────────────────────────────────────────────────────
hdr "PHASE 10 — LINK CLICK STATS"
echo ">>> Fetching all tracked link click events..."
curl -s -X GET "$BASE/api/stats/link" \
  -H "$CT" \
  -d "{\"subscriber_id\": \"$SUBSCRIBER_ID\"}" | pp

echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "  DONE! Check your email inbox for the tracked links."
echo "  When you click a link the server will:"
echo "    1. Record the click in webhooks_raw_received"
echo "    2. Find matching OnClick trigger in the user's HotTrigger"
echo "    3. Execute the configured action (badge, unsubscribe, etc.)"
echo "    4. Redirect you to the real destination URL"
echo "═══════════════════════════════════════════════════════════════════════"
