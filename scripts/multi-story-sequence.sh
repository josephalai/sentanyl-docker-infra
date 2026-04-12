#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# SENTANYL — Multi-Step Sequential Story Demo
#
# This script builds a complete 3-step onboarding story:
#
#   Enactment 1: Welcome Email
#     • User clicks "I'm ready" → advances to Enactment 2
#
#   Enactment 2: Product Showcase
#     • User clicks "Show me the offer" → advances to Enactment 3
#     • User clicks "Not interested"    → ends story (mark failed)
#
#   Enactment 3: Final Offer
#     • User clicks "I'll take it"  → gives "Customer" badge + marks complete
#     • User clicks "Maybe later"   → unsubscribes user
#
# Everything is wired up via API — no seed functions.
# Each enactment sends a different email and waits for the right link click.
#
# HOW TO USE:
#   1. Start the server:  ./go.sh
#   2. Run: bash scripts/multi-story-sequence.sh
#   3. Update email addresses in phases 2/4/6 to match real addresses.
#   4. Click the links in the emails to advance through the story!
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

BASE="${BASE:-http://localhost:8000}"
CT="Content-Type: application/json"

pp()  { python3 -m json.tool 2>/dev/null || cat; }
jf()  { python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null; }
hdr() { echo -e "\n\033[1;36m═══ $* ═══\033[0m"; }
ok()  { echo -e "  \033[1;32m✓\033[0m $*"; }

# ─── Phase 1: Creator ─────────────────────────────────────────────────────────
hdr "PHASE 1 — CREATOR"

CREATOR_RAW=$(curl -s -X POST "$BASE/api/register" \
  -H "$CT" \
  -d '{
    "first_name":  "Sequence",
    "last_name":   "Demo",
    "email":       "sequence-demo@example.com",
    "reply_to":    "sequence-demo@example.com",
    "password":    "SeqPass123!",
    "list_name":   "Multi-Step Onboarding"
  }')
echo "$CREATOR_RAW" | pp
SUBSCRIBER_ID=$(echo "$CREATOR_RAW" | jf "['creator']['public_id']")
ok "subscriber_id = $SUBSCRIBER_ID"

# ─── Phase 2: User ────────────────────────────────────────────────────────────
hdr "PHASE 2 — SUBSCRIBER"

USER_RAW=$(curl -s -X POST "$BASE/api/register/user" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"email\":         \"onboarding-user@example.com\",
    \"first_name\":    \"Alex\",
    \"last_name\":     \"Subscriber\"
  }")
echo "$USER_RAW" | pp
USER_PID=$(echo "$USER_RAW" | jf "['user']['public_id']")
ok "user public_id = $USER_PID"

# ─── Phase 3: Badges ──────────────────────────────────────────────────────────
hdr "PHASE 3 — BADGES"

BADGE_CUSTOMER_RAW=$(curl -s -X POST "$BASE/api/badge/" \
  -H "$CT" \
  -d "{\"subscriber_id\":\"$SUBSCRIBER_ID\",\"name\":\"Customer\",\"description\":\"Accepted the offer\"}")
BADGE_CUSTOMER_PID=$(echo "$BADGE_CUSTOMER_RAW" | jf "['badge']['public_id']")
ok "Customer badge = $BADGE_CUSTOMER_PID"

BADGE_ENGAGED_RAW=$(curl -s -X POST "$BASE/api/badge/" \
  -H "$CT" \
  -d "{\"subscriber_id\":\"$SUBSCRIBER_ID\",\"name\":\"Engaged\",\"description\":\"Opened the product showcase\"}")
BADGE_ENGAGED_PID=$(echo "$BADGE_ENGAGED_RAW" | jf "['badge']['public_id']")
ok "Engaged badge = $BADGE_ENGAGED_PID"

# ─── Phase 4: Templates ───────────────────────────────────────────────────────
hdr "PHASE 4 — EMAIL TEMPLATES"

echo ">>> Template 1: Welcome"
TMPL_1_RAW=$(curl -s -X POST "$BASE/api/template/" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"name\":          \"Step 1 - Welcome\",
    \"html\":          \"<html><body><h1>Welcome {{ first_name }}!</h1><p>We're excited to have you. Ready to see what we've built?</p><p><a href='https://example.com/step2'>Yes, show me!</a></p></body></html>\"
  }")
TMPL_1_PID=$(echo "$TMPL_1_RAW" | jf "['template']['public_id']")
ok "template 1 = $TMPL_1_PID"

echo ">>> Template 2: Product Showcase"
TMPL_2_RAW=$(curl -s -X POST "$BASE/api/template/" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"name\":          \"Step 2 - Product Showcase\",
    \"html\":          \"<html><body><h1>{{ first_name }}, here's what we have for you!</h1><p>Our product solves X, Y and Z for people like you.</p><p><a href='https://example.com/offer'>Show me the offer!</a></p><p><a href='https://example.com/notinterested'>Not interested</a></p></body></html>\"
  }")
TMPL_2_PID=$(echo "$TMPL_2_RAW" | jf "['template']['public_id']")
ok "template 2 = $TMPL_2_PID"

echo ">>> Template 3: Final Offer"
TMPL_3_RAW=$(curl -s -X POST "$BASE/api/template/" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"name\":          \"Step 3 - Final Offer\",
    \"html\":          \"<html><body><h1>Special offer for you, {{ first_name }}!</h1><p>Join now and get 30% off. This offer expires in 24 hours.</p><p><a href='https://example.com/buynow'>I'll take it!</a></p><p><a href='https://example.com/maybelater'>Maybe later (unsubscribe)</a></p></body></html>\"
  }")
TMPL_3_PID=$(echo "$TMPL_3_RAW" | jf "['template']['public_id']")
ok "template 3 = $TMPL_3_PID"

# ─── Phase 5: Scenes ──────────────────────────────────────────────────────────
hdr "PHASE 5 — SCENES"

SCENE_1_RAW=$(curl -s -X POST "$BASE/api/scene/" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"name\":          \"Welcome Scene\",
    \"message\": {
      \"content\": {
        \"subject\":    \"Welcome aboard, {{ first_name }}!\",
        \"from_email\": \"sequence-demo@example.com\",
        \"from_name\":  \"Sequence Demo\",
        \"reply_to\":   \"sequence-demo@example.com\",
        \"body\":       \"<a href='https://example.com/step2'>Yes, show me!</a>\"
      }
    }
  }")
SCENE_1_PID=$(echo "$SCENE_1_RAW" | jf "['scene']['public_id']")
ok "scene 1 = $SCENE_1_PID"

SCENE_2_RAW=$(curl -s -X POST "$BASE/api/scene/" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"name\":          \"Showcase Scene\",
    \"message\": {
      \"content\": {
        \"subject\":    \"Here's what we have for you!\",
        \"from_email\": \"sequence-demo@example.com\",
        \"from_name\":  \"Sequence Demo\",
        \"reply_to\":   \"sequence-demo@example.com\",
        \"body\":       \"<a href='https://example.com/offer'>Show me the offer</a> | <a href='https://example.com/notinterested'>Not interested</a>\"
      }
    }
  }")
SCENE_2_PID=$(echo "$SCENE_2_RAW" | jf "['scene']['public_id']")
ok "scene 2 = $SCENE_2_PID"

SCENE_3_RAW=$(curl -s -X POST "$BASE/api/scene/" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"name\":          \"Final Offer Scene\",
    \"message\": {
      \"content\": {
        \"subject\":    \"Special offer — 24 hours only!\",
        \"from_email\": \"sequence-demo@example.com\",
        \"from_name\":  \"Sequence Demo\",
        \"reply_to\":   \"sequence-demo@example.com\",
        \"body\":       \"<a href='https://example.com/buynow'>I'll take it!</a> | <a href='https://example.com/maybelater'>Maybe later</a>\"
      }
    }
  }")
SCENE_3_PID=$(echo "$SCENE_3_RAW" | jf "['scene']['public_id']")
ok "scene 3 = $SCENE_3_PID"

# ─── Phase 6: Enactments with triggers ───────────────────────────────────────
hdr "PHASE 6 — ENACTMENTS WITH PER-LINK TRIGGERS"

echo ">>> Enactment 1: Welcome (send email, advance on click)..."
ENACT_1_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"name\":          \"Step 1 - Welcome Email\",
    \"level\":         1,
    \"natural_order\": 1
  }")
ENACT_1_PID=$(echo "$ENACT_1_RAW" | jf "['enactment']['public_id']")
ok "enactment 1 = $ENACT_1_PID"

echo "  → Trigger: 'step2' link click → give Engaged badge + mark complete"
curl -s -X POST "$BASE/api/enactment/$ENACT_1_PID/trigger" \
  -H "$CT" \
  -d "{
    \"subscriber_id\":      \"$SUBSCRIBER_ID\",
    \"name\":               \"Ready Click\",
    \"trigger_type\":       \"OnWebhook\",
    \"user_action_type\":   \"OnClick\",
    \"user_action_value\":  \"https://example.com/step2\",
    \"priority\":           1,
    \"mark_complete\":      true,
    \"then_do_this_action\": {
      \"action_name\":       \"Give Engaged Badge\",
      \"badge_transaction\": {
        \"give_badges\": [{\"public_id\": \"$BADGE_ENGAGED_PID\"}]
      }
    }
  }" | pp

echo ">>> Enactment 2: Product Showcase..."
ENACT_2_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"name\":          \"Step 2 - Product Showcase\",
    \"level\":         1,
    \"natural_order\": 2
  }")
ENACT_2_PID=$(echo "$ENACT_2_RAW" | jf "['enactment']['public_id']")
ok "enactment 2 = $ENACT_2_PID"

echo "  → Trigger A: 'offer' click → advance (mark complete)"
curl -s -X POST "$BASE/api/enactment/$ENACT_2_PID/trigger" \
  -H "$CT" \
  -d "{
    \"subscriber_id\":      \"$SUBSCRIBER_ID\",
    \"name\":               \"Show Offer Click\",
    \"trigger_type\":       \"OnWebhook\",
    \"user_action_type\":   \"OnClick\",
    \"user_action_value\":  \"https://example.com/offer\",
    \"priority\":           1,
    \"mark_complete\":      true,
    \"then_do_this_action\": {\"action_name\": \"Advance to Offer\"}
  }" | pp

echo "  → Trigger B: 'not interested' click → end story (mark failed)"
curl -s -X POST "$BASE/api/enactment/$ENACT_2_PID/trigger" \
  -H "$CT" \
  -d "{
    \"subscriber_id\":      \"$SUBSCRIBER_ID\",
    \"name\":               \"Not Interested Click\",
    \"trigger_type\":       \"OnWebhook\",
    \"user_action_type\":   \"OnClick\",
    \"user_action_value\":  \"https://example.com/notinterested\",
    \"priority\":           1,
    \"mark_failed\":        true,
    \"then_do_this_action\": {\"action_name\": \"End Story\", \"end_story\": true}
  }" | pp

echo ">>> Enactment 3: Final Offer..."
ENACT_3_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
  -H "$CT" \
  -d "{
    \"subscriber_id\": \"$SUBSCRIBER_ID\",
    \"name\":          \"Step 3 - Final Offer\",
    \"level\":         1,
    \"natural_order\": 3
  }")
ENACT_3_PID=$(echo "$ENACT_3_RAW" | jf "['enactment']['public_id']")
ok "enactment 3 = $ENACT_3_PID"

echo "  → Trigger A: 'buy now' click → give Customer badge + mark complete"
curl -s -X POST "$BASE/api/enactment/$ENACT_3_PID/trigger" \
  -H "$CT" \
  -d "{
    \"subscriber_id\":      \"$SUBSCRIBER_ID\",
    \"name\":               \"Buy Now Click\",
    \"trigger_type\":       \"OnWebhook\",
    \"user_action_type\":   \"OnClick\",
    \"user_action_value\":  \"https://example.com/buynow\",
    \"priority\":           1,
    \"mark_complete\":      true,
    \"then_do_this_action\": {
      \"action_name\":       \"Give Customer Badge\",
      \"badge_transaction\": {
        \"give_badges\": [{\"public_id\": \"$BADGE_CUSTOMER_PID\"}]
      }
    }
  }" | pp

echo "  → Trigger B: 'maybe later' click → unsubscribe"
curl -s -X POST "$BASE/api/enactment/$ENACT_3_PID/trigger" \
  -H "$CT" \
  -d "{
    \"subscriber_id\":      \"$SUBSCRIBER_ID\",
    \"name\":               \"Maybe Later Click\",
    \"trigger_type\":       \"OnWebhook\",
    \"user_action_type\":   \"OnClick\",
    \"user_action_value\":  \"https://example.com/maybelater\",
    \"priority\":           1,
    \"then_do_this_action\": {\"action_name\":\"Unsubscribe\",\"unsubscribe\":true}
  }" | pp

# ─── Phase 7: Storyline ───────────────────────────────────────────────────────
hdr "PHASE 7 — STORYLINE (3 enactments in order)"

SL_RAW=$(curl -s -X POST "$BASE/api/storyline/" \
  -H "$CT" \
  -d "{\"subscriber_id\":\"$SUBSCRIBER_ID\",\"name\":\"3-Step Onboarding\"}")
echo "$SL_RAW" | pp
SL_PID=$(echo "$SL_RAW" | jf "['storyline']['public_id']")
ok "storyline = $SL_PID"

echo ">>> Linking enactments to storyline..."
for ENACT_PID in "$ENACT_1_PID" "$ENACT_2_PID" "$ENACT_3_PID"; do
  curl -s -X POST "$BASE/api/storyline/$SL_PID/enactments" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUBSCRIBER_ID\",\"enactment_id\":\"$ENACT_PID\"}" | pp
done
ok "enactments linked"

# ─── Phase 8: Story ───────────────────────────────────────────────────────────
hdr "PHASE 8 — STORY"

STORY_RAW=$(curl -s -X POST "$BASE/api/story/" \
  -H "$CT" \
  -d "{\"subscriber_id\":\"$SUBSCRIBER_ID\",\"name\":\"3-Step Onboarding Story\"}")
echo "$STORY_RAW" | pp
STORY_PID=$(echo "$STORY_RAW" | jf "['story']['public_id']")
ok "story = $STORY_PID"

echo ">>> Linking storyline to story..."
curl -s -X POST "$BASE/api/story/$STORY_PID/storylines/$SL_PID" \
  -H "$CT" \
  -d "{\"subscriber_id\":\"$SUBSCRIBER_ID\"}" | pp

# ─── Phase 9: Enroll user ─────────────────────────────────────────────────────
hdr "PHASE 9 — ENROLL USER"

echo ">>> Enrolling user in story (sends step 1 email)..."
START_RAW=$(curl -s -X PUT "$BASE/api/story/$STORY_PID/start" \
  -H "$CT" \
  -d "{\"subscriber_id\":\"$SUBSCRIBER_ID\",\"user_id\":\"$USER_PID\"}")
echo "$START_RAW" | pp
ok "user enrolled"

# ─── Phase 10: Register per-user link triggers ───────────────────────────────
hdr "PHASE 10 — REGISTER PER-USER LINK TRIGGERS"
echo "Registering all link triggers directly on the user's live HotTrigger..."

curl -s -X POST "$BASE/api/user/$USER_PID/link-trigger" \
  -H "$CT" \
  -d "{
    \"subscriber_id\":      \"$SUBSCRIBER_ID\",
    \"name\":               \"Step 2 Ready\",
    \"user_action_value\":  \"https://example.com/step2\",
    \"priority\":           1,
    \"mark_complete\":      true,
    \"then_do_this_action\": {
      \"action_name\":       \"Give Engaged Badge\",
      \"badge_transaction\": {\"give_badges\": [{\"public_id\": \"$BADGE_ENGAGED_PID\"}]}
    }
  }" | pp

curl -s -X POST "$BASE/api/user/$USER_PID/link-trigger" \
  -H "$CT" \
  -d "{
    \"subscriber_id\":      \"$SUBSCRIBER_ID\",
    \"name\":               \"Show Offer\",
    \"user_action_value\":  \"https://example.com/offer\",
    \"priority\":           1,
    \"mark_complete\":      true,
    \"then_do_this_action\": {\"action_name\":\"Advance\"}
  }" | pp

curl -s -X POST "$BASE/api/user/$USER_PID/link-trigger" \
  -H "$CT" \
  -d "{
    \"subscriber_id\":      \"$SUBSCRIBER_ID\",
    \"name\":               \"Not Interested\",
    \"user_action_value\":  \"https://example.com/notinterested\",
    \"priority\":           1,
    \"mark_failed\":        true,
    \"then_do_this_action\": {\"action_name\":\"End Story\",\"end_story\":true}
  }" | pp

curl -s -X POST "$BASE/api/user/$USER_PID/link-trigger" \
  -H "$CT" \
  -d "{
    \"subscriber_id\":      \"$SUBSCRIBER_ID\",
    \"name\":               \"Buy Now\",
    \"user_action_value\":  \"https://example.com/buynow\",
    \"priority\":           1,
    \"mark_complete\":      true,
    \"then_do_this_action\": {
      \"action_name\":       \"Give Customer Badge\",
      \"badge_transaction\": {\"give_badges\": [{\"public_id\": \"$BADGE_CUSTOMER_PID\"}]}
    }
  }" | pp

curl -s -X POST "$BASE/api/user/$USER_PID/link-trigger" \
  -H "$CT" \
  -d "{
    \"subscriber_id\":      \"$SUBSCRIBER_ID\",
    \"name\":               \"Maybe Later\",
    \"user_action_value\":  \"https://example.com/maybelater\",
    \"priority\":           1,
    \"then_do_this_action\": {\"action_name\":\"Unsubscribe\",\"unsubscribe\":true}
  }" | pp

# ─── Phase 11: Interactive simulation ────────────────────────────────────────
hdr "PHASE 11 — INTERACTIVE SIMULATION"
echo ""
echo "The story is running. The user received Step 1 email."
echo ""
echo "You can now simulate link clicks interactively:"
echo ""
echo "  Step 1 click (advance to step 2):"
echo "    curl -s -X POST $BASE/api/webhooks/email/clicked \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"subscriber_id\":\"$SUBSCRIBER_ID\",\"email_address\":\"onboarding-user@example.com\",\"link\":{\"url\":\"https://example.com/step2\"}}'"
echo ""
echo "  Step 2 click — show offer (advance to step 3):"
echo "    curl -s -X POST $BASE/api/webhooks/email/clicked \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"subscriber_id\":\"$SUBSCRIBER_ID\",\"email_address\":\"onboarding-user@example.com\",\"link\":{\"url\":\"https://example.com/offer\"}}'"
echo ""
echo "  Step 2 click — NOT interested (end story):"
echo "    curl -s -X POST $BASE/api/webhooks/email/clicked \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"subscriber_id\":\"$SUBSCRIBER_ID\",\"email_address\":\"onboarding-user@example.com\",\"link\":{\"url\":\"https://example.com/notinterested\"}}'"
echo ""
echo "  Step 3 click — buy now (give Customer badge + complete):"
echo "    curl -s -X POST $BASE/api/webhooks/email/clicked \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"subscriber_id\":\"$SUBSCRIBER_ID\",\"email_address\":\"onboarding-user@example.com\",\"link\":{\"url\":\"https://example.com/buynow\"}}'"
echo ""
echo "  Step 3 click — maybe later (unsubscribe):"
echo "    curl -s -X POST $BASE/api/webhooks/email/clicked \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"subscriber_id\":\"$SUBSCRIBER_ID\",\"email_address\":\"onboarding-user@example.com\",\"link\":{\"url\":\"https://example.com/maybelater\"}}'"
echo ""
echo "  Check user state at any time:"
echo "    curl -s -X GET $BASE/api/user/$USER_PID \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"subscriber_id\":\"$SUBSCRIBER_ID\"}'"
echo ""
echo "  View link click stats:"
echo "    curl -s $BASE/api/stats/link -H 'Content-Type: application/json' -d '{\"subscriber_id\":\"$SUBSCRIBER_ID\"}'"
echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "  DEMO IDs (save these for follow-up testing):"
echo "  SUBSCRIBER_ID  = $SUBSCRIBER_ID"
echo "  USER_PID       = $USER_PID"
echo "  STORY_PID      = $STORY_PID"
echo "═══════════════════════════════════════════════════════════════════════"
