#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# SENTANYL — End-to-End: Outbound Webhooks (Feature 6)
#            "Real-Time Event Delivery to External Systems"
#
# WHAT THIS DEMO SHOWS:
#   Sentanyl can notify external systems in real time by POSTing JSON payloads
#   to registered webhook URLs when internal events occur.  This demo:
#   1. Starts a local Python webhook receiver on port 19876.
#   2. Registers the receiver as an outbound webhook with specific event types.
#   3. Runs a complete story flow (enroll user, click link) while the receiver
#      captures every incoming webhook POST.
#   4. Demonstrates the full CRUD API: create, list, get, update, delete.
#   5. Shows the actual JSON payloads received for each event type.
#
# WHY IT MATTERS:
#   Before: external CRMs, analytics tools, and payment systems had no visibility
#           into Sentanyl state changes.  They couldn't react to story starts,
#           badge grants, or trigger firings in real time.
#   After:  any system that can receive an HTTP POST can subscribe to Sentanyl
#           events.  No polling, no custom integrations, no code changes needed.
#
# HOW IT WORKS:
#   • OutboundWebhook records store a URL, event_types list, and active flag.
#   • outbound_webhook.go FireOutboundWebhook() is called from entity_god.go
#     whenever an internal event occurs (story start, badge add, trigger fire…)
#   • FireOutboundWebhook() queries for active webhooks matching the event type
#     and subscriber_id, then POSTs an outboundWebhookPayload JSON to each URL.
#   • The receiver returns HTTP 200; Sentanyl logs "delivered <event> to <url>".
#
# BEFORE vs AFTER:
#   BEFORE: No outbound notifications.  External systems were unaware of engine
#           state and had to poll MongoDB or the REST API to discover changes.
#   AFTER:  External systems subscribe to specific events and receive push
#           notifications with user/story context within milliseconds.
#
# EVENTS DEMONSTRATED:
#   StoryStarted       — user joins a story
#   BadgeAdded         — a badge is added to a user
#   TriggerTriggered   — a trigger fires after a click event
#   StorylineStarted   — a new storyline becomes active for a user
#
# HOW TO RUN:
#   1.  ./go.sh  (API server + MailHog)
#   2.  bash scripts/e2e-outbound-webhooks.sh
#   3.  Watch the script output for captured webhook payloads
#   The Python webhook receiver runs in the background on port 19876.
#
# ENV OVERRIDES:
#   BASE             API base URL       (default: http://localhost:8000)
#   MAILHOG_UI       MailHog UI         (default: http://localhost:8025)
#   WEBHOOK_PORT     Local webhook port (default: 19876)
# ═══════════════════════════════════════════════════════════════════════════════

set -uo pipefail

BASE="${BASE:-http://localhost:8000}"
MAILHOG_UI="${MAILHOG_UI:-http://localhost:8025}"
WEBHOOK_PORT="${WEBHOOK_PORT:-19876}"
# The webhook receiver runs on the host machine, but FireOutboundWebhook()
# POSTs from inside the Docker container.  On macOS Docker Desktop, containers
# reach the host via the special DNS name "host.docker.internal" (resolves to
# 192.168.65.254 inside the container — Docker Desktop's vpnkit gateway).
# We verify it resolves; fall back to the raw IP if DNS is unavailable.
DOCKER_HOST_IP=$(docker exec api getent ahosts host.docker.internal 2>/dev/null \
    | awk 'NR==1{print $1}')
DOCKER_HOST_IP="${DOCKER_HOST_IP:-192.168.65.254}"
WEBHOOK_URL="http://${DOCKER_HOST_IP}:${WEBHOOK_PORT}/hook"
CT="Content-Type: application/json"

WEBHOOK_LOG="/tmp/sentanyl-webhooks-$$.log"
WEBHOOK_SERVER_PID=""

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

# ── Cleanup on exit ────────────────────────────────────────────────────────────
cleanup() {
    if [ -n "$WEBHOOK_SERVER_PID" ] && kill -0 "$WEBHOOK_SERVER_PID" 2>/dev/null; then
        echo ""
        info "Stopping webhook receiver (PID $WEBHOOK_SERVER_PID)..."
        kill "$WEBHOOK_SERVER_PID" 2>/dev/null || true
        wait "$WEBHOOK_SERVER_PID" 2>/dev/null || true
        ok "Webhook receiver stopped"
    fi
    rm -f "$WEBHOOK_LOG"
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
hdr "PRE-FLIGHT CHECK"

echo "Checking server at $BASE ..."
if ! curl -s "$BASE/" > /dev/null 2>&1; then
    err "Server not reachable at $BASE"
    err "Start the server first (./go.sh), then re-run."
    exit 1
fi
ok "Server is up"

echo "Checking Python3 availability..."
if ! python3 --version > /dev/null 2>&1; then
    err "Python3 is required for the webhook receiver"
    exit 1
fi
ok "Python3 is available"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 0 — RESET DATABASE"
# ═══════════════════════════════════════════════════════════════════════════════

echo ">>> Clearing all previous demo data..."
curl -s -X POST "$BASE/api/admin/reset" -H "$CT" | pp
ok "Database cleared"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 1 — CREATOR & USER"
# ═══════════════════════════════════════════════════════════════════════════════

CREATOR_EMAIL="webhook-demo-$(date +%s)@sentanyl-demo.local"

echo ">>> Registering creator ($CREATOR_EMAIL)..."
CREATOR_RAW=$(curl -s -X POST "$BASE/api/register" \
    -H "$CT" \
    -d "{
        \"first_name\": \"Webhook\",
        \"last_name\":  \"Demo\",
        \"email\":      \"$CREATOR_EMAIL\",
        \"reply_to\":   \"$CREATOR_EMAIL\",
        \"password\":   \"WebhookDemo123!\",
        \"list_name\":  \"Webhook Demo List\"
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
        \"email\":         \"webhook-user@demo.local\",
        \"first_name\":    \"Webhook\",
        \"last_name\":     \"User\"
    }")
echo "$USER_RAW" | pp
USER_PID=$(must_ok "User registration" "$USER_RAW" "d['user']['public_id']")
ok "user public_id = $USER_PID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 2 — START WEBHOOK RECEIVER (Python HTTP server on port $WEBHOOK_PORT)"
# ═══════════════════════════════════════════════════════════════════════════════
# Prefer the standalone scripts/webhook-receiver.py when it is already running
# on WEBHOOK_PORT (started separately in another terminal).  If the port is
# free, fall back to launching the standalone script in the background so the
# script remains self-contained.
#
# To run the standalone receiver manually before this script:
#   WEBHOOK_PORT=19876 WEBHOOK_LOG=/tmp/sentanyl-webhooks.log \
#       python3 scripts/webhook-receiver.py

STANDALONE_SCRIPT="$(dirname "$0")/webhook-receiver.py"

_port_in_use() {
    # Returns 0 (true) if something is already listening on the port.
    curl -s -o /dev/null -w "%{http_code}" \
        --max-time 1 -X POST "http://localhost:${WEBHOOK_PORT}/hook" \
        -H "$CT" -d '{"event_type":"probe"}' 2>/dev/null | grep -q "200"
}

echo ">>> Checking if webhook receiver is already running on port $WEBHOOK_PORT..."

if _port_in_use; then
    ok "Standalone webhook receiver already running on port $WEBHOOK_PORT — using it."
    info "Received webhooks will be logged to: $WEBHOOK_LOG"
    WEBHOOK_SERVER_PID=""
else
    echo ">>> Starting webhook receiver on port $WEBHOOK_PORT..."
    if [ -f "$STANDALONE_SCRIPT" ]; then
        WEBHOOK_PORT="$WEBHOOK_PORT" WEBHOOK_LOG="$WEBHOOK_LOG" \
            python3 "$STANDALONE_SCRIPT" > /dev/null 2>&1 &
        WEBHOOK_SERVER_PID=$!
        info "Launched scripts/webhook-receiver.py (PID=$WEBHOOK_SERVER_PID)"
    else
        # Inline fallback — kept for portability if the script file is missing.
        python3 -c "
import http.server, sys, json, datetime, os, signal

LOG_FILE = '${WEBHOOK_LOG}'

class WebhookHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        raw = self.rfile.read(length)
        self.send_response(200)
        self.end_headers()
        try:
            body = json.loads(raw)
            event_type = body.get('event_type', 'unknown')
            ts = datetime.datetime.now().strftime('%H:%M:%S')
            line = f'[{ts}] EVENT={event_type} PAYLOAD={json.dumps(body)}'
        except Exception:
            line = f'RAW={raw.decode(\"utf-8\",errors=\"replace\")}'
        with open(LOG_FILE, 'a') as f:
            f.write(line + '\n')
        print(line, flush=True)
    def log_message(self, *a):
        pass

server = http.server.HTTPServer(('0.0.0.0', ${WEBHOOK_PORT}), WebhookHandler)
signal.signal(signal.SIGTERM, lambda s,f: sys.exit(0))
server.serve_forever()
" > /dev/null 2>&1 &
        WEBHOOK_SERVER_PID=$!
    fi

    echo ">>> Waiting 2 seconds for server to start..."
    sleep 2

    if ! kill -0 "$WEBHOOK_SERVER_PID" 2>/dev/null; then
        err "Webhook receiver failed to start (port $WEBHOOK_PORT may be in use)"
        err "Try: WEBHOOK_PORT=19877 bash scripts/e2e-outbound-webhooks.sh"
        exit 1
    fi
    ok "Webhook receiver running (PID=$WEBHOOK_SERVER_PID, URL=$WEBHOOK_URL)"
    info "Received webhooks will be logged to: $WEBHOOK_LOG"
fi

# Test the receiver
TEST_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$WEBHOOK_URL" \
    -H "$CT" \
    -d '{"event_type":"test","message":"receiver is working"}')
if [ "$TEST_RESPONSE" = "200" ]; then
    ok "Webhook receiver test: HTTP 200 — receiver is working"
else
    warn "Receiver test returned HTTP $TEST_RESPONSE (expected 200)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 3 — REGISTER OUTBOUND WEBHOOK (CRUD: Create)"
# ═══════════════════════════════════════════════════════════════════════════════
# Register the local Python receiver as an outbound webhook.
# event_types lists which events should trigger this webhook.
# Sentanyl checks this list in FireOutboundWebhook() before POSTing.

echo ">>> Registering outbound webhook with event subscriptions..."
info "Events: StoryStarted, BadgeAdded, TriggerTriggered, StorylineStarted"
WEBHOOK_RAW=$(curl -s -X POST "$BASE/api/outbound-webhook/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"Demo External System\",
        \"url\":           \"$WEBHOOK_URL\",
        \"event_types\":   [
            \"StoryStarted\",
            \"BadgeAdded\",
            \"TriggerTriggered\",
            \"StorylineStarted\",
            \"StoryCompleted\"
        ],
        \"active\": true
    }")
echo "$WEBHOOK_RAW" | pp
WEBHOOK_PID=$(must_ok "Outbound webhook" "$WEBHOOK_RAW" "d['outbound_webhook']['public_id']")
ok "Outbound webhook registered: public_id = $WEBHOOK_PID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 4 — VERIFY WEBHOOK CREATED (CRUD: List and Get)"
# ═══════════════════════════════════════════════════════════════════════════════

echo ">>> Listing all outbound webhooks for this subscriber..."
LIST_RAW=$(curl -s -X GET "$BASE/api/outbound-webhook/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}")
echo "$LIST_RAW" | pp
WEBHOOK_COUNT=$(echo "$LIST_RAW" | jval "len(d.get('outbound_webhooks',[]))" 2>/dev/null || echo "?")
ok "Outbound webhooks registered: $WEBHOOK_COUNT"

echo
echo ">>> Getting specific webhook by public_id..."
GET_RAW=$(curl -s -X GET "$BASE/api/outbound-webhook/$WEBHOOK_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}")
echo "$GET_RAW" | pp
ok "GET by public_id confirmed: $WEBHOOK_PID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 5 — CREATE STORY INFRASTRUCTURE"
# ═══════════════════════════════════════════════════════════════════════════════

echo ">>> Creating badge 'story-start'..."
BADGE_START_RAW=$(curl -s -X POST "$BASE/api/badge/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"name\":\"story-start\",\"description\":\"Starts the webhook demo story\"}")
BADGE_START_PID=$(must_ok "story-start badge" "$BADGE_START_RAW" "d['badge']['public_id']")
ok "story-start = $BADGE_START_PID"

echo ">>> Creating enactment with a click trigger..."
EMAIL_BODY=$(python3 -c "
import json
body = '''<html><body style=\"font-family:Arial;padding:28px;background:#f8fafc\">
<h2 style=\"color:#1e293b\">🪝 Outbound Webhook Demo</h2>
<p>When you click the button below, Sentanyl will:</p>
<ol>
  <li>Detect the click via /api/webhooks/email/clicked</li>
  <li>Fire the TriggerTriggered outbound webhook</li>
  <li>Call advance_to_next_storyline</li>
  <li>Fire StoryCompleted outbound webhook</li>
</ol>
<p>All of these events will be captured by our local Python receiver.</p>
<a href=\"https://example.com/webhook-click\"
   style=\"background:#0f172a;color:#fff;text-decoration:none;padding:12px 24px;border-radius:6px;display:inline-block;margin-top:12px\">
  🪝 Click to Fire Webhook Events
</a>
</body></html>'''
print(json.dumps(body))
")

ENACT_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"Webhook Demo Email\",
        \"natural_order\": 1,
        \"send_scene\": {
            \"name\": \"Webhook Demo Scene\",
            \"message\": {
                \"content\": {
                    \"subject\":    \"🪝 Webhook Demo — Click to Fire Events\",
                    \"from_email\": \"$CREATOR_EMAIL\",
                    \"from_name\":  \"Webhook Demo\",
                    \"reply_to\":   \"$CREATOR_EMAIL\",
                    \"body\":       $EMAIL_BODY
                }
            }
        }
    }")
echo "$ENACT_RAW" | pp
ENACT_PID=$(must_ok "Enactment" "$ENACT_RAW" "d['enactment']['public_id']")
ok "Enactment pid = $ENACT_PID"

echo ">>> Adding click trigger to enactment..."
TRIG_RAW=$(curl -s -X POST "$BASE/api/enactment/$ENACT_PID/trigger" \
    -H "$CT" \
    -d "{
        \"subscriber_id\":     \"$SUB_ID\",
        \"name\":              \"Webhook Demo Click\",
        \"trigger_type\":      \"OnWebhook\",
        \"user_action_type\":  \"OnClick\",
        \"user_action_value\": \"https://example.com/webhook-click\",
        \"priority\":          1,
        \"then_do_this_action\": {
            \"action_name\": \"Advance Storyline (fires TriggerTriggered + StoryCompleted)\",
            \"advance_to_next_storyline\": true
        }
    }")
echo "$TRIG_RAW" | pp
ok "Click trigger added: https://example.com/webhook-click"

echo ">>> Creating storyline and story..."
SL_RAW=$(curl -s -X POST "$BASE/api/storyline/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"name\":\"Webhook Demo Storyline\",\"natural_order\":1}")
SL_PID=$(must_ok "Storyline" "$SL_RAW" "d['storyline']['public_id']")
curl -s -X POST "$BASE/api/storyline/$SL_PID/enactments" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"enactment_id\":\"$ENACT_PID\"}" | pp

STORY_RAW=$(curl -s -X POST "$BASE/api/story/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"Webhook Demo Story\",
        \"priority\":      1,
        \"allow_interruption\": false,
        \"start_trigger\": {\"badge\": {\"public_id\": \"$BADGE_START_PID\"}}
    }")
STORY_PID=$(must_ok "Story" "$STORY_RAW" "d['story']['public_id']")
curl -s -X POST "$BASE/api/story/$STORY_PID/storylines/$SL_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}" | pp
ok "Story and storyline created: story_pid=$STORY_PID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 6 — ENROLL USER (fires StoryStarted + BadgeAdded webhooks)"
# ═══════════════════════════════════════════════════════════════════════════════
# Adding the story-start badge fires TWO outbound webhook events:
#   1. BadgeAdded     — fired by AddBadgeToUser() in entity_god.go
#   2. StoryStarted   — fired when JoinStory succeeds in entity_god.go
#   3. StorylineStarted — fired when the first storyline begins

echo ">>> ENROLLING user — this will fire BadgeAdded + StoryStarted + StorylineStarted webhooks!"
echo ""
echo -e "${BLD}${YLW}🪝 Watch the webhook receiver output below for incoming events...${RST}"
echo ""

curl -s -X PUT "$BASE/api/user_badge/user/$USER_PID/badge/$BADGE_START_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}" | pp

echo
echo ">>> Waiting 5 seconds for webhook events to arrive..."
sleep 5

echo
echo ">>> WEBHOOK EVENTS RECEIVED SO FAR (from log file):"
echo -e "${CYN}─────────────────────────────────────────────────────────────────────${RST}"
if [ -f "$WEBHOOK_LOG" ]; then
    while IFS= read -r line; do
        EVENT=$(echo "$line" | python3 -c "import sys,json,re; m=re.search(r'EVENT=(\S+)',sys.stdin.read()); print(m.group(1) if m else '?')" 2>/dev/null || echo "?")
        echo -e "  ${GRN}●${RST} $line"
        ok "Event captured: $EVENT"
    done < "$WEBHOOK_LOG"
    EVENT_COUNT=$(wc -l < "$WEBHOOK_LOG" 2>/dev/null || echo 0)
    info "Total events captured so far: $EVENT_COUNT (test ping counted)"
else
    warn "No webhook log yet — events may still be in flight"
fi
echo -e "${CYN}─────────────────────────────────────────────────────────────────────${RST}"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 7 — USER CLICKS LINK (fires TriggerTriggered + StoryCompleted webhooks)"
# ═══════════════════════════════════════════════════════════════════════════════
# Clicking the link fires:
#   1. TriggerTriggered — fired by ExecuteAction() in entity_god.go
#   2. StoryCompleted   — fired by MarkStoryComplete → EndStory in entity_god.go

echo -e "${BLD}${YLW}╔══ 👆 ACTION REQUIRED ══════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${YLW}║  MAILHOG: $MAILHOG_UI${RST}"
echo -e "${BLD}${YLW}╟────────────────────────────────────────────────────────────────────╢${RST}"
echo -e "${BLD}${YLW}║  The user should have received an email:${RST}"
echo -e "${BLD}${YLW}║    Subject: '🪝 Webhook Demo — Click to Fire Events'${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  YOUR ACTION:${RST}"
echo -e "${BLD}${YLW}║    • Open MailHog → find the email for: webhook-user@demo.local${RST}"
echo -e "${BLD}${YLW}║    • Click the '🪝 Click to Fire Webhook Events' button${RST}"
echo -e "${BLD}${YLW}║      (clicking fires the webhook automatically)${RST}"
echo -e "${BLD}${YLW}║    • This will IMMEDIATELY fire outbound webhooks to: $WEBHOOK_URL${RST}"
echo -e "${BLD}${YLW}║        → TriggerTriggered  (ExecuteAction fires)${RST}"
echo -e "${BLD}${YLW}║        → StoryCompleted    (EndStory after advance_to_next_storyline)${RST}"
echo -e "${BLD}${YLW}║${RST}"
echo -e "${BLD}${YLW}║  Watch the terminal running the webhook receiver (if in a split pane).${RST}"
echo -e "${BLD}${YLW}║  After clicking the link, return here and press Enter.${RST}"
echo -e "${BLD}${YLW}╚════════════════════════════════════════════════════════════════════╝${RST}"
press_enter
echo ">>> Waiting 5 seconds for webhook delivery..."
sleep 5

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 8 — SHOW ALL RECEIVED WEBHOOK PAYLOADS"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BLD}${CYN}╔════════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${CYN}║     ALL RECEIVED OUTBOUND WEBHOOK EVENTS                   ║${RST}"
echo -e "${BLD}${CYN}╚════════════════════════════════════════════════════════════╝${RST}"
echo ""

if [ -f "$WEBHOOK_LOG" ] && [ -s "$WEBHOOK_LOG" ]; then
    EVENT_NUM=0
    while IFS= read -r line; do
        EVENT_NUM=$((EVENT_NUM + 1))
        EVENT=$(echo "$line" | python3 -c "
import sys, re, json
line = sys.stdin.read()
m = re.search(r'PAYLOAD=(\{.*\})\s*$', line)
if m:
    try:
        d = json.loads(m.group(1))
        et = d.get('event_type','?')
        payload = json.dumps(d.get('payload',{}), indent=4)
        print(f'event_type: {et}')
        print(f'payload:')
        print(payload)
    except:
        print(line)
" 2>/dev/null || echo "$line")
        echo -e "  ${GRN}Event #${EVENT_NUM}${RST}"
        echo "$EVENT" | while IFS= read -r eline; do
            echo "    $eline"
        done
        echo ""
    done < "$WEBHOOK_LOG"
    info "Total events captured: $EVENT_NUM"
else
    warn "No webhook events captured in log file."
    warn "This may happen if MongoDB is not running or FireOutboundWebhook had an error."
    warn "Check server logs for 'FireOutboundWebhook:' messages."
fi

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 9 — DEMONSTRATE CRUD: Update Webhook (toggle active status)"
# ═══════════════════════════════════════════════════════════════════════════════
# Inactive webhooks are NOT called by FireOutboundWebhook() (active=false filter).
# This is useful for temporarily pausing a webhook without deleting it.

echo ">>> Updating webhook — setting active=false (pause delivery)..."
UPDATE_RAW=$(curl -s -X PUT "$BASE/api/outbound-webhook/$WEBHOOK_PID" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"outbound_webhook\": {
            \"name\":        \"Demo External System (PAUSED)\",
            \"url\":         \"$WEBHOOK_URL\",
            \"event_types\": [\"StoryStarted\",\"BadgeAdded\",\"TriggerTriggered\",\"StorylineStarted\",\"StoryCompleted\"],
            \"active\":      false
        }
    }")
echo "$UPDATE_RAW" | pp
ok "Webhook paused (active=false) — further events will NOT be delivered"

echo
echo ">>> Re-activating webhook..."
REACTIVATE_RAW=$(curl -s -X PUT "$BASE/api/outbound-webhook/$WEBHOOK_PID" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"outbound_webhook\": {
            \"name\":        \"Demo External System\",
            \"url\":         \"$WEBHOOK_URL\",
            \"event_types\": [\"StoryStarted\",\"BadgeAdded\",\"TriggerTriggered\",\"StorylineStarted\",\"StoryCompleted\"],
            \"active\":      true
        }
    }")
echo "$REACTIVATE_RAW" | pp
ok "Webhook re-activated (active=true)"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 10 — DEMONSTRATE CRUD: Add a Second Webhook and Delete It"
# ═══════════════════════════════════════════════════════════════════════════════

echo ">>> Creating a second webhook (for a different external system)..."
WEBHOOK2_RAW=$(curl -s -X POST "$BASE/api/outbound-webhook/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"Analytics System (will be deleted)\",
        \"url\":           \"https://analytics.example.com/sentanyl-events\",
        \"event_types\":   [\"TriggerTriggered\",\"StoryCompleted\"],
        \"active\":        true
    }")
echo "$WEBHOOK2_RAW" | pp
WEBHOOK2_PID=$(must_ok "Second webhook" "$WEBHOOK2_RAW" "d['outbound_webhook']['public_id']")
ok "Second webhook created: public_id = $WEBHOOK2_PID"

echo
echo ">>> Listing all webhooks (should show 2 now)..."
LIST2_RAW=$(curl -s -X GET "$BASE/api/outbound-webhook/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}")
echo "$LIST2_RAW" | pp
COUNT2=$(echo "$LIST2_RAW" | jval "len(d.get('outbound_webhooks',[]))" 2>/dev/null || echo "?")
ok "Webhook count after adding second: $COUNT2"

echo
echo ">>> Deleting the second webhook (soft delete — marks deleted_at)..."
DELETE_RAW=$(curl -s -X DELETE "$BASE/api/outbound-webhook/$WEBHOOK2_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}")
echo "$DELETE_RAW" | pp
ok "Second webhook soft-deleted (active=false, timestamps.deleted_at set)"

echo
echo ">>> Listing webhooks after deletion (should show 1 active webhook)..."
LIST3_RAW=$(curl -s -X GET "$BASE/api/outbound-webhook/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}")
echo "$LIST3_RAW" | pp
COUNT3=$(echo "$LIST3_RAW" | jval "len(d.get('outbound_webhooks',[]))" 2>/dev/null || echo "?")
ok "Active webhook count after deletion: $COUNT3"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 11 — INSTRUCTIONS FOR THE TESTER"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BLD}${GRN}════════════════════════════════════════════════════════════════${RST}"
echo -e "${BLD}${GRN}  ✅  OUTBOUND WEBHOOKS DEMO COMPLETE!${RST}"
echo -e "${BLD}${GRN}════════════════════════════════════════════════════════════════${RST}"
echo ""
echo -e "${BLD}${YLW}WHAT EVENTS WERE DELIVERED:${RST}"
echo ""
echo "  1. BadgeAdded       — user received 'story-start' badge"
echo "     Payload: {event_type:'BadgeAdded',    payload:{user_id, badge_id, badge}}"
echo ""
echo "  2. StoryStarted     — user joined the story"
echo "     Payload: {event_type:'StoryStarted',  payload:{user_id, story_id}}"
echo ""
echo "  3. StorylineStarted — first storyline began"
echo "     Payload: {event_type:'StorylineStarted', payload:{user_id, storyline_id, story_id}}"
echo ""
echo "  4. TriggerTriggered — user clicked the webhook-click URL"
echo "     Payload: {event_type:'TriggerTriggered', payload:{user_id, trigger_id, action}}"
echo ""
echo "  5. StoryCompleted   — advance_to_next_storyline ended the story"
echo "     Payload: {event_type:'StoryCompleted', payload:{user_id, story_id}}"
echo ""
echo -e "${BLD}${YLW}AVAILABLE EVENT TYPES (serve_incoming_webhooks.go):${RST}"
echo "  StoryStarted       StorylineFailed    BadgeAdded"
echo "  StoryStopped       StorylineCompleted BadgeRemoved"
echo "  StoryCompleted     StoryActive        TriggerTriggered"
echo "  StoryFailed        StoryInactive"
echo "  StorylineStarted"
echo ""
echo -e "${BLD}${YLW}OUTBOUND WEBHOOK CRUD ENDPOINTS:${RST}"
echo "  POST   /api/outbound-webhook/         — create"
echo "  GET    /api/outbound-webhook/         — list (body: {subscriber_id})"
echo "  GET    /api/outbound-webhook/:id      — get one"
echo "  PUT    /api/outbound-webhook/:id      — update (body: {subscriber_id, outbound_webhook:{...}})"
echo "  DELETE /api/outbound-webhook/:id      — soft delete (body: {subscriber_id})"
echo ""
echo -e "${BLD}${YLW}SERVER LOG EVIDENCE:${RST}"
echo "  'FireOutboundWebhook: delivered <event> event to <url> → HTTP 200'"
echo ""
echo -e "${BLD}${YLW}USING OUTBOUND WEBHOOKS IN PRODUCTION:${RST}"
echo "  1. Replace '$WEBHOOK_URL' with your real endpoint URL."
echo "  2. Set active=true and specify only the event_types you need."
echo "  3. Your endpoint receives a JSON POST with {event_type, payload} body."
echo "  4. Return HTTP 2xx to acknowledge — Sentanyl logs success."
echo "  5. Use the update endpoint to add/remove event_types without recreating."
echo ""
echo -e "${BLD}${YLW}DEMO IDs:${RST}"
echo "  SUBSCRIBER_ID   = $SUB_ID"
echo "  USER_PID        = $USER_PID"
echo "  WEBHOOK_PID     = $WEBHOOK_PID"
echo "  STORY_PID       = $STORY_PID"
echo "  WEBHOOK_LOG     = $WEBHOOK_LOG  (will be cleaned up on exit)"
echo ""
echo -e "${BLD}${CYN}════════════════════════════════════════════════════════════════${RST}"
echo -e "${BLD}${CYN}  Feature 6 demonstrated: real-time outbound webhook delivery! 🪝${RST}"
echo -e "${BLD}${CYN}════════════════════════════════════════════════════════════════${RST}"
echo ""
