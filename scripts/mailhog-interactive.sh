#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# SENTANYL — Conditional Email Sequence Demo (MailHog)
#
# SEQUENCE:
#   Email 1 has three links.  What you receive next depends on which link(s)
#   you clicked and in what ORDER:
#
#   Link 1 (standard path)   → Email 2  (unless Link 3 was clicked FIRST)
#   Link 2 (standard path)   → Email 3  (unless Link 3 was clicked FIRST)
#   Link 3 (early-bird path) → Email 1b (EarlyBird upgrade notice)
#
#   If Link 3 was clicked FIRST, then …
#     Link 1 → Email 4   (early-bird version of Email 2)
#     Link 2 → Email 5   (early-bird version of Email 3)
#
# HOW IT WORKS (server-side):
#   • Story A is started for the user.  Its Act-1 triggers are loaded into the
#     user's HotTrigger.
#   • Clicking Link 1 gives badge "Link1".  Badge "Link1" has Story R1 attached
#     → Story R1 starts → Email 2 is auto-sent.
#   • Clicking Link 3 gives badge "EarlyBird".  Badge "EarlyBird" has Story B
#     attached → Story B starts → its Act-1 triggers REPLACE Story A's triggers
#     in the user's HotTrigger → Email 1b is auto-sent.
#   • After Story B's triggers are loaded, Link 1 now gives badge "Link1Early"
#     (instead of "Link1") → Story R4 starts → Email 4 is auto-sent.
#
# HOW TO RUN:
#   1.  mailhog                                  (or docker equivalent)
#   2.  ./go.sh                                  (API server, DEBUG mode)
#   3.  bash scripts/mailhog-interactive.sh
#   4.  Open MailHog → http://localhost:8025
#   5.  Click links in Email 1 to drive the sequence.
#
# ENV OVERRIDES:
#   BASE       API base URL  (default: http://localhost:8000)
#   MAILHOG_UI MailHog UI    (default: http://localhost:8025)
#   USER_EMAIL Subscriber    (default: josephalai@gmail.com)
# ═══════════════════════════════════════════════════════════════════════════════

set -uo pipefail

BASE="${BASE:-http://localhost:8000}"
MAILHOG_UI="${MAILHOG_UI:-http://localhost:8025}"
USER_EMAIL="${USER_EMAIL:-josephalai@gmail.com}"
CT="Content-Type: application/json"

# ── colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[1;36m'
BLD='\033[1m'; RST='\033[0m'

hdr()  { echo -e "\n${CYN}${BLD}╔══ $* ══╗${RST}"; }
ok()   { echo -e "  ${GRN}✓${RST} $*"; }
warn() { echo -e "  ${YLW}⚠${RST} $*"; }
fail() { echo -e "  ${RED}✗${RST} $*" >&2; }
info() { echo -e "  ${YLW}ℹ${RST} $*"; }

pp()   { python3 -m json.tool 2>/dev/null || cat; }

jval() {
    python3 -c "import sys,json; d=json.load(sys.stdin); print($1)" 2>/dev/null
}

# Build a server-side click-tracking URL.
# Server encodeTrackingToken: base64url( originalURL + "|" + userPublicId )
tracking_url() {
    local url="$1" pid="$2"
    local raw="${url}|${pid}"
    local token
    token=$(printf '%s' "$raw" | base64 | tr -d '\n' | tr '+' '-' | tr '/' '_')
    echo "${BASE}/api/track/click/${token}"
}

# JSON-encode a multi-line string for embedding inside a JSON object.
json_str() { python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$1"; }

pause() {
    echo
    echo -e "${BLD}>>> Press Enter to continue...${RST}"
    read -r
}

# ─────────────────────────────────────────────────────────────────────────────
hdr "PRE-FLIGHT CHECK"

echo "Checking server at $BASE ..."
if ! curl -s "$BASE/" > /dev/null 2>&1; then
    fail "Server not reachable at $BASE"
    fail "Start the server first (./go.sh), then re-run."
    exit 1
fi
ok "Server is up"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 0 — CLEAR PREVIOUS DEMO DATA"
# ═══════════════════════════════════════════════════════════════════════════════

echo ">>> Clearing all previous demo data from the database..."
RESET_RAW=$(curl -s -X POST "$BASE/api/admin/reset" -H "$CT")
echo "$RESET_RAW" | pp
ok "Database cleared"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 1 — CREATOR & SUBSCRIBER REGISTRATION"
# ═══════════════════════════════════════════════════════════════════════════════

CREATOR_EMAIL="creator-$(date +%s)@sentanyl-demo.local"

echo ">>> Registering creator ($CREATOR_EMAIL)..."
CREATOR_RAW=$(curl -s -X POST "$BASE/api/register" \
    -H "$CT" \
    -d "{
        \"first_name\": \"Sentanyl\",
        \"last_name\":  \"Demo\",
        \"email\":      \"$CREATOR_EMAIL\",
        \"reply_to\":   \"$CREATOR_EMAIL\",
        \"password\":   \"DemoPass123!\",
        \"list_name\":  \"Demo List\"
    }") || { fail "Creator registration failed — is the server up?"; exit 1; }
echo "$CREATOR_RAW" | pp
SUB_ID=$(echo "$CREATOR_RAW" | jval "d['creator']['public_id']")
ok "creator subscriber_id = $SUB_ID"

echo
echo ">>> Registering $USER_EMAIL as subscriber..."
USER_RAW=$(curl -s -X POST "$BASE/api/register/user" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"email\":         \"$USER_EMAIL\",
        \"first_name\":    \"Joseph\",
        \"last_name\":     \"Alai\"
    }")
echo "$USER_RAW" | pp
USER_PID=$(echo "$USER_RAW" | jval "d['user']['public_id']")
ok "user public_id = $USER_PID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 2 — CREATE BADGES"
# ═══════════════════════════════════════════════════════════════════════════════
# Five badges — one per "branch decision":
#   Link1      : user clicked Link 1 on the standard path
#   Link2      : user clicked Link 2 on the standard path
#   EarlyBird  : user clicked Link 3 (early-bird path activated)
#   Link1Early : user clicked Link 1 AFTER getting EarlyBird
#   Link2Early : user clicked Link 2 AFTER getting EarlyBird
# ═══════════════════════════════════════════════════════════════════════════════

create_badge() {
    local name="$1" desc="$2"
    local raw
    raw=$(curl -s -X POST "$BASE/api/badge/" \
        -H "$CT" \
        -d "{
            \"subscriber_id\": \"$SUB_ID\",
            \"name\":          \"$name\",
            \"description\":   \"$desc\"
        }")
    echo "$raw" | jval "d['badge']['public_id']"
}

BADGE_LINK1_PID=$(create_badge     "Link1"      "Clicked Link 1 (standard path)")
BADGE_LINK2_PID=$(create_badge     "Link2"      "Clicked Link 2 (standard path)")
BADGE_EARLYBIRD_PID=$(create_badge "EarlyBird"  "Clicked Link 3 — early-bird path")
BADGE_LINK1E_PID=$(create_badge    "Link1Early" "Clicked Link 1 after EarlyBird")
BADGE_LINK2E_PID=$(create_badge    "Link2Early" "Clicked Link 2 after EarlyBird")

ok "Link1      public_id=$BADGE_LINK1_PID"
ok "Link2      public_id=$BADGE_LINK2_PID"
ok "EarlyBird  public_id=$BADGE_EARLYBIRD_PID"
ok "Link1Early public_id=$BADGE_LINK1E_PID"
ok "Link2Early public_id=$BADGE_LINK2E_PID"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 3 — DESTINATION URLS"
# ═══════════════════════════════════════════════════════════════════════════════
# These are the "real" destination URLs embedded in email links.  The server
# decodes the tracking token, fires the matching HotTrigger action, then
# redirects the browser to these URLs.  A 404 response there is fine for demo.

URL_LINK1="http://sentanyl-demo.local/link1"
URL_LINK2="http://sentanyl-demo.local/link2"
URL_LINK3="http://sentanyl-demo.local/link3"

ok "URL_LINK1 = $URL_LINK1"
ok "URL_LINK2 = $URL_LINK2"
ok "URL_LINK3 = $URL_LINK3"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 4 — STORY A (main, started immediately)"
# ═══════════════════════════════════════════════════════════════════════════════
# Story A has one act (Email 1).  Three triggers are registered on that act:
#   URL_LINK1 → give Link1 badge
#   URL_LINK2 → give Link2 badge
#   URL_LINK3 → give EarlyBird badge
#
# Badge Link1      → starts Story R1 → sends Email 2
# Badge Link2      → starts Story R2 → sends Email 3
# Badge EarlyBird  → starts Story B  → sends Email 1b  (and replaces act-1
#                    triggers so future Link1/Link2 clicks give *Early badges)

echo ">>> Creating Story A — Act 1 enactment (no email content; Email 1 sent manually)..."
EA1_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"Story A — Act 1\",
        \"level\":         1,
        \"natural_order\": 1
    }")
EA1_PID=$(echo "$EA1_RAW" | jval "d['enactment']['public_id']")
ok "Story A Act 1 = $EA1_PID"

# Triggers on Act 1
add_trigger() {
    local enact_pid="$1" url="$2" name="$3" badge_pid="$4" badge_name="$5" badge_desc="$6"
    curl -s -X POST "$BASE/api/enactment/$enact_pid/trigger" \
        -H "$CT" \
        -d "{
            \"subscriber_id\":    \"$SUB_ID\",
            \"name\":             \"$name\",
            \"trigger_type\":     \"OnWebhook\",
            \"user_action_type\": \"OnClick\",
            \"user_action_value\":\"$url\",
            \"priority\":         1,
            \"mark_complete\":    false,
            \"mark_failed\":      false,
            \"then_do_this_action\": {
                \"action_name\": \"$name Action\",
                \"badge_transaction\": {
                    \"give_badges\": [
                        {\"public_id\":\"$badge_pid\",
                         \"name\":\"$badge_name\",
                         \"description\":\"$badge_desc\"}
                    ]
                }
            }
        }" > /dev/null
    ok "  trigger: $name → $url"
}

add_trigger "$EA1_PID" "$URL_LINK1" "Link1 clicked"     "$BADGE_LINK1_PID"     "Link1"     "Clicked Link 1 (standard)"
add_trigger "$EA1_PID" "$URL_LINK2" "Link2 clicked"     "$BADGE_LINK2_PID"     "Link2"     "Clicked Link 2 (standard)"
add_trigger "$EA1_PID" "$URL_LINK3" "Link3 EarlyBird"   "$BADGE_EARLYBIRD_PID" "EarlyBird" "Clicked Link 3"

echo ">>> Creating Storyline A and Story A..."
SLA_RAW=$(curl -s -X POST "$BASE/api/storyline/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"name\":\"Storyline A\",\"natural_order\":1}")
SLA_PID=$(echo "$SLA_RAW" | jval "d['storyline']['public_id']")
ok "Storyline A = $SLA_PID"

curl -s -X POST "$BASE/api/storyline/$SLA_PID/enactments" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"enactment_id\":\"$EA1_PID\"}" > /dev/null
ok "Enactment A1 linked to Storyline A"

SA_RAW=$(curl -s -X POST "$BASE/api/story/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"name\":\"Story A — Main\"}")
SA_PID=$(echo "$SA_RAW" | jval "d['story']['public_id']")
ok "Story A = $SA_PID"

curl -s -X POST "$BASE/api/story/$SA_PID/storylines/$SLA_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}" > /dev/null
ok "Storyline A linked to Story A"

echo ">>> Starting Story A for user $USER_PID ..."
START_RAW=$(curl -s -X PUT "$BASE/api/story/$SA_PID/start" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"user_id\":\"$USER_PID\"}")
echo "$START_RAW" | pp
ok "Story A started — HotTrigger loaded with Act-1 triggers"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 5 — STORY B (EarlyBird, triggered by EarlyBird badge)"
# ═══════════════════════════════════════════════════════════════════════════════
# When EarlyBird badge is given, getStoriesFromBadge() finds Story B via
# start_trigger.badge.public_id.  Story B Act 1's triggers use the SAME
# URL_LINK1 / URL_LINK2 as Story A, but give *Link1Early* / *Link2Early* badges
# instead.  setTriggersFromEnactment(scrapCurrent=true) replaces Story A's
# Act-1 triggers in the HotTrigger, so subsequent clicks on the same URLs now
# give the EarlyBird-path badges.

# Build Email-1b HTML now so we can embed it in the enactment send_scene.
# (We need USER_PID here for tracking URLs — Story A was just started above.)
T_LINK1=$(tracking_url "$URL_LINK1" "$USER_PID")
T_LINK2=$(tracking_url "$URL_LINK2" "$USER_PID")
T_LINK3=$(tracking_url "$URL_LINK3" "$USER_PID")

EMAIL_1B_BODY=$(cat << HTML
<html>
<head><meta charset="UTF-8"></head>
<body style="font-family:Arial,sans-serif;max-width:600px;margin:32px auto;background:#eff6ff;padding:24px;border-radius:12px">
  <h1 style="color:#1e3a8a">🐦 You are an Early Bird!</h1>
  <p style="color:#1e40af">Hi Joseph,</p>
  <p style="color:#1e40af">
    Because you clicked <strong>Link 3</strong> first, your path has been
    upgraded to the <strong>EarlyBird</strong> track.  Your next steps below
    now lead to the premium versions (Email&nbsp;4 or Email&nbsp;5) instead of
    the standard ones.
  </p>
  <hr style="border:1px solid #bfdbfe;margin:24px 0">

  <table width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:12px">
    <tr>
      <td style="background:#1d4ed8;border-radius:8px;padding:16px;text-align:center">
        <a href="$T_LINK1" style="color:#fff;font-weight:bold;font-size:17px;text-decoration:none">
          1️⃣  Link 1 — Premium path A
        </a>
        <p style="color:#bfdbfe;font-size:12px;margin:6px 0 0">
          Server action → give <strong>Link1Early</strong> badge → send <strong>Email 4</strong>
        </p>
      </td>
    </tr>
  </table>

  <table width="100%" cellpadding="0" cellspacing="0">
    <tr>
      <td style="background:#7c3aed;border-radius:8px;padding:16px;text-align:center">
        <a href="$T_LINK2" style="color:#fff;font-weight:bold;font-size:17px;text-decoration:none">
          2️⃣  Link 2 — Premium path B
        </a>
        <p style="color:#ddd6fe;font-size:12px;margin:6px 0 0">
          Server action → give <strong>Link2Early</strong> badge → send <strong>Email 5</strong>
        </p>
      </td>
    </tr>
  </table>

  <p style="color:#93c5fd;font-size:11px;margin-top:32px">
    Sentanyl Demo · subscriber_id: $SUB_ID · user_id: $USER_PID
  </p>
</body>
</html>
HTML
)

EMAIL_1B_JSON=$(json_str "$EMAIL_1B_BODY")

echo ">>> Creating Story B — Act 1 enactment (with inline Email-1b content)..."
EB1_RAW=$(curl -s -X POST "$BASE/api/enactment/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"Story B — Act 1 (EarlyBird)\",
        \"level\":         1,
        \"natural_order\": 1,
        \"send_scene\": {
            \"name\":    \"EarlyBird Scene\",
            \"message\": {
                \"content\": {
                    \"subject\":    \"[EarlyBird 🐦] You unlocked the premium track!\",
                    \"from_email\": \"$CREATOR_EMAIL\",
                    \"from_name\":  \"Sentanyl Demo\",
                    \"reply_to\":   \"$CREATOR_EMAIL\",
                    \"body\":       $EMAIL_1B_JSON
                }
            }
        }
    }")
EB1_PID=$(echo "$EB1_RAW" | jval "d['enactment']['public_id']")
ok "Story B Act 1 = $EB1_PID"

# Story B triggers use the SAME destination URLs as Story A,
# but give the *Early badge variants.
add_trigger "$EB1_PID" "$URL_LINK1" "Link1 (EarlyBird path)" "$BADGE_LINK1E_PID" "Link1Early" "Clicked Link 1 after EarlyBird"
add_trigger "$EB1_PID" "$URL_LINK2" "Link2 (EarlyBird path)" "$BADGE_LINK2E_PID" "Link2Early" "Clicked Link 2 after EarlyBird"

echo ">>> Creating Storyline B and Story B..."
SLB_RAW=$(curl -s -X POST "$BASE/api/storyline/" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"name\":\"Storyline B\",\"natural_order\":1}")
SLB_PID=$(echo "$SLB_RAW" | jval "d['storyline']['public_id']")
ok "Storyline B = $SLB_PID"

curl -s -X POST "$BASE/api/storyline/$SLB_PID/enactments" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\",\"enactment_id\":\"$EB1_PID\"}" > /dev/null
ok "Enactment B1 linked to Storyline B"

# Story B is found by getStoriesFromBadge() when EarlyBird badge is given.
SB_RAW=$(curl -s -X POST "$BASE/api/story/" \
    -H "$CT" \
    -d "{
        \"subscriber_id\": \"$SUB_ID\",
        \"name\":          \"Story B — EarlyBird Path\",
        \"start_trigger\": {
            \"badge\": {
                \"public_id\": \"$BADGE_EARLYBIRD_PID\"
            }
        }
    }")
SB_PID=$(echo "$SB_RAW" | jval "d['story']['public_id']")
ok "Story B = $SB_PID"

curl -s -X POST "$BASE/api/story/$SB_PID/storylines/$SLB_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\":\"$SUB_ID\"}" > /dev/null
ok "Storyline B linked to Story B"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 6 — RESPONSE STORIES (R1 · R2 · R4 · R5)"
# ═══════════════════════════════════════════════════════════════════════════════
# Each response story has one act whose send_scene holds the email to send.
# The story is auto-started (and the email auto-sent) when AddBadgeToUser()
# gives the matching badge.

make_response_story() {
    local name="$1" badge_pid="$2" subject="$3" html_body="$4"
    local html_json
    html_json=$(json_str "$html_body")

    # Create enactment with inline email content
    local enact_raw
    enact_raw=$(curl -s -X POST "$BASE/api/enactment/" \
        -H "$CT" \
        -d "{
            \"subscriber_id\": \"$SUB_ID\",
            \"name\":          \"$name — Act 1\",
            \"level\":         1,
            \"natural_order\": 1,
            \"send_scene\": {
                \"name\": \"$name Scene\",
                \"message\": {
                    \"content\": {
                        \"subject\":    \"$subject\",
                        \"from_email\": \"$CREATOR_EMAIL\",
                        \"from_name\":  \"Sentanyl Demo\",
                        \"reply_to\":   \"$CREATOR_EMAIL\",
                        \"body\":       $html_json
                    }
                }
            }
        }")
    local enact_pid
    enact_pid=$(echo "$enact_raw" | jval "d['enactment']['public_id']")

    # Storyline
    local sl_raw sl_pid
    sl_raw=$(curl -s -X POST "$BASE/api/storyline/" \
        -H "$CT" \
        -d "{\"subscriber_id\":\"$SUB_ID\",\"name\":\"$name Storyline\",\"natural_order\":1}")
    sl_pid=$(echo "$sl_raw" | jval "d['storyline']['public_id']")

    curl -s -X POST "$BASE/api/storyline/$sl_pid/enactments" \
        -H "$CT" \
        -d "{\"subscriber_id\":\"$SUB_ID\",\"enactment_id\":\"$enact_pid\"}" > /dev/null

    # Story with start_trigger pointing to the badge
    local story_raw story_pid
    story_raw=$(curl -s -X POST "$BASE/api/story/" \
        -H "$CT" \
        -d "{
            \"subscriber_id\": \"$SUB_ID\",
            \"name\":          \"$name\",
            \"start_trigger\": {
                \"badge\": {
                    \"public_id\": \"$badge_pid\"
                }
            }
        }")
    story_pid=$(echo "$story_raw" | jval "d['story']['public_id']")

    curl -s -X POST "$BASE/api/story/$story_pid/storylines/$sl_pid" \
        -H "$CT" \
        -d "{\"subscriber_id\":\"$SUB_ID\"}" > /dev/null

    ok "  $name  (story=$story_pid, trigger badge=$badge_pid)"
    echo "$story_pid"
}

echo ">>> Creating Story R1 (Email 2 — Link 1, standard path)..."
make_response_story \
    "Story R1" "$BADGE_LINK1_PID" \
    "[Email 2] You clicked Link 1 — Standard Path" \
    "<html><body style='font-family:Arial,sans-serif;max-width:600px;margin:32px auto;background:#f0fdf4;padding:24px;border-radius:12px'>
<h1 style='color:#14532d'>📧 Email 2 — Standard Path (Link 1)</h1>
<p style='color:#166534'>Hi Joseph,</p>
<p style='color:#166534'>
  You clicked <strong>Link 1</strong> on the standard path (without the EarlyBird upgrade).
  This is <strong>Email 2</strong>.
</p>
<p style='color:#166534'>You received this because you clicked Link 1 before Link 3.</p>
<p style='color:#86efac;font-size:11px'>Sentanyl Demo · subscriber_id: $SUB_ID</p>
</body></html>" > /dev/null

echo ">>> Creating Story R2 (Email 3 — Link 2, standard path)..."
make_response_story \
    "Story R2" "$BADGE_LINK2_PID" \
    "[Email 3] You clicked Link 2 — Standard Path" \
    "<html><body style='font-family:Arial,sans-serif;max-width:600px;margin:32px auto;background:#fefce8;padding:24px;border-radius:12px'>
<h1 style='color:#713f12'>📧 Email 3 — Standard Path (Link 2)</h1>
<p style='color:#92400e'>Hi Joseph,</p>
<p style='color:#92400e'>
  You clicked <strong>Link 2</strong> on the standard path (without the EarlyBird upgrade).
  This is <strong>Email 3</strong>.
</p>
<p style='color:#92400e'>You received this because you clicked Link 2 before Link 3.</p>
<p style='color:#fde68a;font-size:11px'>Sentanyl Demo · subscriber_id: $SUB_ID</p>
</body></html>" > /dev/null

echo ">>> Creating Story R4 (Email 4 — Link 1, EarlyBird path)..."
make_response_story \
    "Story R4" "$BADGE_LINK1E_PID" \
    "[Email 4] You clicked Link 1 — EarlyBird Path 🐦" \
    "<html><body style='font-family:Arial,sans-serif;max-width:600px;margin:32px auto;background:#f0f9ff;padding:24px;border-radius:12px'>
<h1 style='color:#0c4a6e'>🐦 Email 4 — EarlyBird Path (Link 1)</h1>
<p style='color:#075985'>Hi Joseph,</p>
<p style='color:#075985'>
  You clicked <strong>Link 1</strong> AFTER activating the EarlyBird upgrade.
  This is <strong>Email 4</strong> — the premium version of Email 2.
</p>
<p style='color:#075985'>Your EarlyBird status unlocked this exclusive content!</p>
<p style='color:#7dd3fc;font-size:11px'>Sentanyl Demo · subscriber_id: $SUB_ID</p>
</body></html>" > /dev/null

echo ">>> Creating Story R5 (Email 5 — Link 2, EarlyBird path)..."
make_response_story \
    "Story R5" "$BADGE_LINK2E_PID" \
    "[Email 5] You clicked Link 2 — EarlyBird Path 🐦" \
    "<html><body style='font-family:Arial,sans-serif;max-width:600px;margin:32px auto;background:#fdf4ff;padding:24px;border-radius:12px'>
<h1 style='color:#581c87'>🐦 Email 5 — EarlyBird Path (Link 2)</h1>
<p style='color:#7e22ce'>Hi Joseph,</p>
<p style='color:#7e22ce'>
  You clicked <strong>Link 2</strong> AFTER activating the EarlyBird upgrade.
  This is <strong>Email 5</strong> — the premium version of Email 3.
</p>
<p style='color:#7e22ce'>Your EarlyBird status unlocked this exclusive content!</p>
<p style='color:#d8b4fe;font-size:11px'>Sentanyl Demo · subscriber_id: $SUB_ID</p>
</body></html>" > /dev/null

ok "All response stories created"

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 7 — BUILD AND SEND EMAIL 1"
# ═══════════════════════════════════════════════════════════════════════════════
# Email 1 is sent directly.  Follow-up emails (1b, 2, 3, 4, 5) are auto-sent
# by the server when the respective badge triggers a story.

echo ">>> Building tracking URLs for Email 1 links..."
T_LINK1=$(tracking_url "$URL_LINK1" "$USER_PID")
T_LINK2=$(tracking_url "$URL_LINK2" "$USER_PID")
T_LINK3=$(tracking_url "$URL_LINK3" "$USER_PID")

info "  Link 1 (standard → Email 2)     : $T_LINK1"
info "  Link 2 (standard → Email 3)     : $T_LINK2"
info "  Link 3 (EarlyBird → upgrades 1&2): $T_LINK3"

EMAIL1_HTML=$(cat << HTML
<html>
<head><meta charset="UTF-8"></head>
<body style="font-family:Arial,sans-serif;max-width:600px;margin:32px auto;background:#f9fafb;padding:24px;border-radius:12px">
  <h1 style="color:#1e293b">🌟 Email 1 — Choose Your Path</h1>
  <p style="color:#475569">Hi Joseph,</p>
  <p style="color:#475569">
    Every link below fires a different server-side action.
    <strong>The order you click them matters!</strong>
  </p>
  <blockquote style="background:#f1f5f9;border-left:4px solid #64748b;padding:12px;border-radius:4px;color:#475569;font-size:13px">
    <strong>Conditional sequence:</strong><br>
    • Click <em>Link&nbsp;1</em> first → receive <strong>Email&nbsp;2</strong> (standard)<br>
    • Click <em>Link&nbsp;2</em> first → receive <strong>Email&nbsp;3</strong> (standard)<br>
    • Click <em>Link&nbsp;3</em> first → receive <strong>Email&nbsp;1b</strong> (EarlyBird upgrade)<br>
    &nbsp;&nbsp;Then Link&nbsp;1 → <strong>Email&nbsp;4</strong> · Link&nbsp;2 → <strong>Email&nbsp;5</strong>
  </blockquote>
  <hr style="border:1px solid #e2e8f0;margin:24px 0">

  <table width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:12px">
    <tr>
      <td style="background:#16a34a;border-radius:8px;padding:16px;text-align:center">
        <a href="$T_LINK1" style="color:#fff;font-weight:bold;font-size:17px;text-decoration:none">
          1️⃣  Link 1 — Standard path A
        </a>
        <p style="color:#dcfce7;font-size:12px;margin:6px 0 0">
          Without EarlyBird → <strong>Email 2</strong> ·
          After EarlyBird → <strong>Email 4</strong>
        </p>
      </td>
    </tr>
  </table>

  <table width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:12px">
    <tr>
      <td style="background:#d97706;border-radius:8px;padding:16px;text-align:center">
        <a href="$T_LINK2" style="color:#fff;font-weight:bold;font-size:17px;text-decoration:none">
          2️⃣  Link 2 — Standard path B
        </a>
        <p style="color:#fef3c7;font-size:12px;margin:6px 0 0">
          Without EarlyBird → <strong>Email 3</strong> ·
          After EarlyBird → <strong>Email 5</strong>
        </p>
      </td>
    </tr>
  </table>

  <table width="100%" cellpadding="0" cellspacing="0">
    <tr>
      <td style="background:#7c3aed;border-radius:8px;padding:16px;text-align:center">
        <a href="$T_LINK3" style="color:#fff;font-weight:bold;font-size:17px;text-decoration:none">
          3️⃣  Link 3 — Activate EarlyBird upgrade 🐦
        </a>
        <p style="color:#ede9fe;font-size:12px;margin:6px 0 0">
          Gives <strong>EarlyBird</strong> badge → sends <strong>Email 1b</strong>
          → upgrades Link&nbsp;1 / Link&nbsp;2 paths
        </p>
      </td>
    </tr>
  </table>

  <p style="color:#94a3b8;font-size:11px;margin-top:32px">
    Sentanyl Demo · subscriber_id: $SUB_ID · user_id: $USER_PID
  </p>
</body>
</html>
HTML
)

echo ">>> Sending Email 1 to MailHog..."
EMAIL1_JSON=$(json_str "$EMAIL1_HTML")
E1_RESULT=$(curl -s -X POST "$BASE/api/email" \
    -H "$CT" \
    -d "{
        \"from\":         \"$CREATOR_EMAIL\",
        \"to\":           \"$USER_EMAIL\",
        \"subject_line\": \"[DEMO Email 1] Choose Your Path — Order Matters!\",
        \"html\":         $EMAIL1_JSON,
        \"reply_to\":     \"$CREATOR_EMAIL\"
    }")
echo "$E1_RESULT" | pp
ok "Email 1 queued. Scheduler will deliver it within a few seconds."

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 8 — INSTRUCTIONS"
# ═══════════════════════════════════════════════════════════════════════════════

echo
echo -e "${BLD}  MailHog UI:${RST}  $MAILHOG_UI"
echo -e "${BLD}  Inbox:${RST}       $USER_EMAIL"
echo
echo -e "${BLD}  User public_id:   ${GRN}$USER_PID${RST}"
echo -e "${BLD}  Creator sub_id:   ${GRN}$SUB_ID${RST}"
echo
echo -e "${CYN}${BLD}  WHAT EACH LINK DOES${RST}"
echo "  ═══════════════════════════════════════════════════════════"
echo
echo "  Email 1 (in your MailHog inbox now):"
echo "    Link 1: gives 'Link1' badge"
echo "       → starts Story R1 → auto-sends Email 2 (standard)"
echo "       UNLESS Link 3 was clicked first: gives 'Link1Early' badge"
echo "       → starts Story R4 → auto-sends Email 4 (EarlyBird)"
echo
echo "    Link 2: gives 'Link2' badge"
echo "       → starts Story R2 → auto-sends Email 3 (standard)"
echo "       UNLESS Link 3 was clicked first: gives 'Link2Early' badge"
echo "       → starts Story R5 → auto-sends Email 5 (EarlyBird)"
echo
echo "    Link 3: gives 'EarlyBird' badge"
echo "       → starts Story B → auto-sends Email 1b"
echo "       → REPLACES Link 1/Link 2 triggers with EarlyBird variants"
echo
echo -e "${CYN}${BLD}  EXPERIMENTS${RST}"
echo "  ═══════════════════════════════════════════════════════════"
echo
echo "  Standard path:"
echo "    Click Link 1 → get Email 2"
echo "    Click Link 2 → get Email 3"
echo
echo "  EarlyBird path:"
echo "    Click Link 3 first → get Email 1b"
echo "    Then click Link 1  → get Email 4 (premium Email 2)"
echo "    Then click Link 2  → get Email 5 (premium Email 3)"
echo
echo -e "${CYN}${BLD}  SIMULATE CLICKS WITHOUT MAILHOG${RST}"
echo "  ═══════════════════════════════════════════════════════════"
echo
echo "  # Simulate clicking Link 1:"
printf '  curl -s -X POST %s/api/webhooks/email/clicked \\\n    -H %q \\\n    -d %q\n\n' \
    "$BASE" "$CT" \
    "{\"subscriber_id\":\"$SUB_ID\",\"email_address\":\"$USER_EMAIL\",\"link\":{\"url\":\"$URL_LINK1\"}}"
echo "  # Simulate clicking Link 3 (EarlyBird) first:"
printf '  curl -s -X POST %s/api/webhooks/email/clicked \\\n    -H %q \\\n    -d %q\n\n' \
    "$BASE" "$CT" \
    "{\"subscriber_id\":\"$SUB_ID\",\"email_address\":\"$USER_EMAIL\",\"link\":{\"url\":\"$URL_LINK3\"}}"
echo "  # Then simulate clicking Link 1 (now gives EarlyBird response):"
printf '  curl -s -X POST %s/api/webhooks/email/clicked \\\n    -H %q \\\n    -d %q\n\n' \
    "$BASE" "$CT" \
    "{\"subscriber_id\":\"$SUB_ID\",\"email_address\":\"$USER_EMAIL\",\"link\":{\"url\":\"$URL_LINK1\"}}"
echo "  # Check user state:"
printf '  curl -s -X GET %s/api/user/%s \\\n    -H %q \\\n    -d %q | python3 -m json.tool\n\n' \
    "$BASE" "$USER_PID" "$CT" "{\"subscriber_id\":\"$SUB_ID\"}"
echo "  # Check click stats:"
printf '  curl -s -X GET %s/api/stats/link \\\n    -H %q \\\n    -d %q | python3 -m json.tool\n\n' \
    "$BASE" "$CT" "{\"subscriber_id\":\"$SUB_ID\"}"

echo
echo -e "${BLD}Open MailHog now at: $MAILHOG_UI${RST}"
echo -e "Click links in Email 1. Follow-up emails appear automatically."
echo -e "Press Enter when you're ready to see the live user state."
pause

# ═══════════════════════════════════════════════════════════════════════════════
hdr "PHASE 9 — LIVE STATE AFTER YOUR INTERACTIONS"
# ═══════════════════════════════════════════════════════════════════════════════

echo ">>> Fetching current user state..."
curl -s -X GET "$BASE/api/user/$USER_PID" \
    -H "$CT" \
    -d "{\"subscriber_id\": \"$SUB_ID\"}" | pp

echo
echo ">>> Link-click statistics:"
curl -s -X GET "$BASE/api/stats/link" \
    -H "$CT" \
    -d "{\"subscriber_id\": \"$SUB_ID\"}" | pp

echo
echo ">>> Badge statistics:"
curl -s -X GET "$BASE/api/stats/badge" \
    -H "$CT" \
    -d "{\"subscriber_id\": \"$SUB_ID\"}" | pp

echo "════════════════════════════════════════════════════════════════════════"
echo -e "${BLD}  DEMO COMPLETE${RST}"
echo ""
echo "  Re-run the script to start a fresh experiment."
echo "  The database is cleared automatically at the start of each run."
echo ""
echo -e "  ${BLD}MailHog:${RST}  $MAILHOG_UI"
echo -e "  ${BLD}User:${RST}     $USER_EMAIL  (public_id: $USER_PID)"
echo -e "  ${BLD}Creator:${RST}  $CREATOR_EMAIL"
echo "════════════════════════════════════════════════════════════════════════"
