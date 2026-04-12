#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# SENTANYL — Live Manifesting Sequence (Story Hierarchy Test)
# 
# Structure:
# - 1 Story (Manifesting Workshops Bundle)
#   - 3 Storylines (Product 1, Product 2, Product 3)
#     - 4 Enactments per Storyline (A: Soft Info, B: Hard Info, C: Soft Sell, D: Hard Sell)
#       - 3 Scenes (Emails) per Enactment (1-minute timeouts)
# ═══════════════════════════════════════════════════════════════════════════════

set -uo pipefail

BASE="${BASE:-http://localhost:8000}"
MAILHOG_UI="${MAILHOG_UI:-http://localhost:8025}"
USER_EMAIL="${USER_EMAIL:-buyer@demo.local}"
CT="Content-Type: application/json"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[1;36m'; BLD='\033[1m'; RST='\033[0m'
jval() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

echo -e "\n${CYN}${BLD}╔══ PRE-FLIGHT CHECK ══╗${RST}"
if ! curl -s "$BASE/" > /dev/null 2>&1; then
    echo -e "${RED}✗ Server not reachable at $BASE. Start ./go.sh first.${RST}"
    exit 1
fi
echo -e "${GRN}✓ Server is up!${RST}"

# ── 1. CLEAR DATA & SETUP ────────────────────────────────────────────────────
curl -s -X POST "$BASE/api/admin/reset" -H "$CT" >/dev/null

CREATOR_RAW=$(curl -s -X POST "$BASE/api/register" -H "$CT" -d "{\"first_name\": \"Manifesting\", \"last_name\": \"Coach\", \"email\": \"coach@demo.local\", \"password\": \"DemoPass123!\"}")
CREATOR_ID=$(echo "$CREATOR_RAW" | jval "d.get('creator',{}).get('public_id','')")

USER_RAW=$(curl -s -X POST "$BASE/api/register/user" -H "$CT" -d "{\"subscriber_id\": \"${CREATOR_ID}\", \"email\": \"${USER_EMAIL}\", \"first_name\": \"Alice\"}")
USER_ID=$(echo "$USER_RAW" | jval "d.get('user',{}).get('public_id','')")
echo -e "${GRN}✓ Test Account & User registered.${RST}"

# ── 2. GENERATE AND LOAD MASSIVE STORY JSON ──────────────────────────────────
echo -e "${CYN}→ Building 36-Scene Story Payload...${RST}"

PAYLOAD=$(python3 -c "
import json

story = {
    \"subscriber_id\": \"$CREATOR_ID\",
    \"name\": \"Manifesting Workshops Complete Bundle\",
    \"storylines\": []
}

products = [\"Manifesting 101\", \"Advanced Attraction\", \"Quantum Wealth\"]

for i, prod in enumerate(products):
    acts = []
    act_idx = 1

    def add_enactment(en_name, phase, cta_text, link_url):
        global act_idx
        for scene_num in range(1, 4):
            acts.append({
                \"name\": f\"{prod} - {en_name} - Scene {scene_num}\",
                \"natural_order\": act_idx,
                \"send_scene\": {
                    \"name\": f\"{en_name} Scene {scene_num}\",
                    \"message\": {
                        \"content\": {
                            \"subject\": f\"[{prod}] {phase} (Email {scene_num}/3)\",
                            \"from_email\": \"coach@demo.com\",
                            \"from_name\": \"Manifesting Coach\",
                            \"reply_to\": \"coach@demo.com\",
                            \"body\": f\"<h1>{prod} - {en_name}</h1><p>Email {scene_num} of 3. {phase}</p><br><a href='{link_url}'>{cta_text}</a>\"
                        }
                    }
                },
                \"trigger\": {
                    \"OnWebhook\": [{
                        \"name\": \"Click Trigger\",
                        \"trigger_type\": \"OnWebhook\",
                        \"user_action_type\": \"OnClick\",
                        \"user_action_value\": link_url,
                        \"mark_complete\": True,
                        \"priority\": 1,
                        \"then_do_this_action\": {
                            \"when\": { \"wait_until\": { \"wait_until\": 1, \"time_unit\": \"minutes\" } }
                        }
                    }]
                }
            })
            act_idx += 1

    # Enactment A: Soft Intrigue
    add_enactment(\"Enactment A\", \"Soft Intrigue\", \"Click for More Info\", \"https://example.com/more-info-a\")
    # Enactment B: Hard Intrigue
    add_enactment(\"Enactment B\", \"Are you sure you dont want more info!?\", \"Get Info Now\", \"https://example.com/more-info-b\")
    # Enactment C: Soft Sell
    add_enactment(\"Enactment C\", \"Here is the offer.\", \"Buy Now (Soft)\", \"https://example.com/buy-now-soft\")
    # Enactment D: Hard Sell
    add_enactment(\"Enactment D\", \"You are missing out bro. Buy now dude.\", \"BUY NOW\", \"https://example.com/buy-now-hard\")

    story[\"storylines\"].append({
        \"name\": f\"Storyline: {prod}\",
        \"natural_order\": i + 1,
        \"acts\": acts
    })

print(json.dumps(story))
")

STORY_RAW=$(curl -s -X POST "$BASE/api/story/" -H "$CT" -d "$PAYLOAD")
STORY_ID=$(echo "$STORY_RAW" | jval "d.get('story',{}).get('public_id','')")
echo -e "${GRN}✓ Story Sequence Created: $STORY_ID${RST}"

# ── 3. START THE ENGINE ──────────────────────────────────────────────────────
echo -e "\n${GRN}${BLD}🚀 STARTING LIVE SEQUENCE...${RST}"
curl -s -X PUT "$BASE/api/story/${STORY_ID}/start" -H "$CT" -d "{\"subscriber_id\": \"${CREATOR_ID}\", \"user_id\": \"${USER_ID}\"}" > /dev/null

echo -e "\n${YLW}Open MailHog right now: ${BLD}$MAILHOG_UI${RST}"
echo -e "You will start receiving the 'Manifesting 101 - Soft Intrigue' emails."
echo -e "Because the Sentanyl worker polls every 1 minute, you can:"
echo -e "  1. Sit back and watch it automatically advance to Scene 2 and Scene 3."
echo -e "  2. Physically click the links inside the email to instantly advance the Enactment.\n"

# ── 4. LIVE POLLING LOOP ─────────────────────────────────────────────────────
check_email() { curl -s "$MAILHOG_UI/api/v2/messages" | grep -q "\"Subject\":\"$1\""; }

LAST_DETECTED=""
while true; do
  LATEST=$(curl -s "$MAILHOG_UI/api/v2/messages" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('items',[{}])[0].get('Content',{}).get('Headers',{}).get('Subject',[''])[0] if len(d.get('items',[]))>0 else '')" 2>/dev/null)
  
  if [ "$LATEST" != "" ] && [ "$LATEST" != "$LAST_DETECTED" ]; then
      echo -e "📧 ${CYN}New Email Arrived in Inbox: ${BLD}$LATEST${RST}"
      LAST_DETECTED="$LATEST"
  fi
  sleep 3
done
