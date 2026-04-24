#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# SENTANYL — E2E: webhook surfaces enrollment failures instead of swallowing them
#
# WHAT THIS VERIFIES:
#   When an offer's included_products contains a soft-deleted product, the
#   lms-service /internal/enroll endpoint returns 404 for it. Before the fix,
#   the Stripe webhook logged the error and returned 200 — the buyer ended up
#   partially enrolled with no visible error on Stripe's side. After the fix,
#   the webhook returns a non-2xx so Stripe retries and the failure shows up
#   in the Stripe dashboard's webhook log.
#
# HOW IT WORKS:
#   • Seeds Acme tenant with ONE offer whose included_products contains both
#     a live product AND a soft-deleted one (69e138da...0001330460 —
#     "Webinar Course", confirmed soft-deleted).
#   • Fires a signed checkout.session.completed event.
#   • Asserts the HTTP response is non-200 and the live product IS still
#     enrolled (so the loop tries every product).
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

MONGO_CONTAINER="${MONGO_CONTAINER:-sntl-mongo}"
MONGO_DB="${MONGO_DB:-sentanyl_db}"
MARKETING_URL="${MARKETING_URL:-http://localhost/api/marketing}"

ACME_TENANT="69e109222d12500001b38e2b"
SOURCE_TENANT="69eae0e22b38610001312b93"
PRODUCT_LIVE="69e26e12936aab00012a73ef"        # Bridge of Events (live)
PRODUCT_DEAD="69e138da305ccd0001330460"        # Webinar Course (soft-deleted)
BUYER_EMAIL="${BUYER_EMAIL:-enroll-fail-$(date +%s)@example.com}"

GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
pass() { echo "${GREEN}✓${RESET} $*"; }
fail() { echo "${RED}✗${RESET} $*"; FAILS=$((FAILS+1)); }
info() { echo "${DIM}·${RESET} $*"; }
step() { echo; echo "${BOLD}${YELLOW}── $* ──${RESET}"; }
FAILS=0
mongo() { docker exec -i "$MONGO_CONTAINER" mongosh --quiet "$MONGO_DB" "$@"; }

RUN_TAG=$(date +%s)
OFFER_ID="$(printf 'deaddead%016x' "$RUN_TAG")"

step "1. Seed Stripe creds + offer (one live product + one soft-deleted)"
mongo --eval "
  var src = db.tenants.findOne({_id: ObjectId('$SOURCE_TENANT')});
  if (!src || !src.stripe_webhook_secret) throw new Error('source has no creds');
  db.tenants.updateOne({_id: ObjectId('$ACME_TENANT')},
    {\$set:{
      stripe_secret_key: src.stripe_secret_key,
      stripe_public_key: src.stripe_public_key,
      stripe_webhook_secret: src.stripe_webhook_secret
    }});
  var now = new Date();
  db.offers.replaceOne({_id: ObjectId('$OFFER_ID')}, {
    _id: ObjectId('$OFFER_ID'),
    public_id: 'enroll-fail-$RUN_TAG',
    tenant_id: ObjectId('$ACME_TENANT'),
    title: 'Enroll Failure Test',
    pricing_model: 'one_time', amount: 1000, currency: 'usd',
    included_products: [ObjectId('$PRODUCT_LIVE'), ObjectId('$PRODUCT_DEAD')],
    granted_badges: ['enroll_fail_test'],
    timestamps: {created_at: now, updated_at: now}
  }, {upsert: true});
  // Confirm the soft-deleted product is still soft-deleted.
  var dead = db.products.findOne({_id:ObjectId('$PRODUCT_DEAD')});
  if (!dead.timestamps || !dead.timestamps.deleted_at) {
    throw new Error('test precondition failed: $PRODUCT_DEAD is not soft-deleted');
  }
  print('ok');
" > /dev/null
pass "Seeded offer with live product + soft-deleted product"

WHSEC=$(mongo --eval "print(db.tenants.findOne({_id:ObjectId('$ACME_TENANT')}).stripe_webhook_secret)" | tr -d '\r\n ')

step "2. POST signed checkout.session.completed"
BODY='{"id":"evt_enroll_fail_'"$RUN_TAG"'","type":"checkout.session.completed","data":{"object":{
"id":"cs_enroll_fail_'"$RUN_TAG"'","mode":"payment",
"customer_email":"'"$BUYER_EMAIL"'",
"customer_details":{"email":"'"$BUYER_EMAIL"'","name":"Enroll Fail Test"},
"metadata":{"offer_id":"'"$OFFER_ID"'","tenant_id":"'"$ACME_TENANT"'","domain":"acme.local"}
}}}'
TS=$(date +%s)
SIG=$(printf '%s' "${TS}.${BODY}" | openssl dgst -sha256 -hmac "$WHSEC" -hex | awk '{print $2}')

HTTP_CODE=$(curl -sS -o /tmp/enroll_fail_resp.json -w '%{http_code}' \
  -X POST "$MARKETING_URL/stripe/webhook?tenant_id=$ACME_TENANT" \
  -H "Content-Type: application/json" \
  -H "Stripe-Signature: t=${TS},v1=${SIG}" \
  --data-binary "$BODY")
info "response: $HTTP_CODE $(cat /tmp/enroll_fail_resp.json)"

if [[ "$HTTP_CODE" =~ ^5 ]]; then
  pass "Webhook returned $HTTP_CODE (non-2xx) — Stripe will retry and log the failure"
else
  fail "Expected 5xx response, got $HTTP_CODE"
fi

RESP_BODY=$(cat /tmp/enroll_fail_resp.json)
if echo "$RESP_BODY" | grep -q "enrollment failed"; then
  pass "Response body names the failure: $RESP_BODY"
else
  fail "Response body doesn't mention enrollment failure: $RESP_BODY"
fi

step "3. Verify the LIVE product was still enrolled (no short-circuit)"
ENROLLED=$(mongo --eval "
  var u = db.users.findOne({tenant_id:ObjectId('$ACME_TENANT'), email:'$BUYER_EMAIL'});
  if (!u) { print('NO_CONTACT'); quit(); }
  var n = db.course_enrollments.find({tenant_id:ObjectId('$ACME_TENANT'), contact_id:u._id, product_id:ObjectId('$PRODUCT_LIVE')}).count();
  print('contact='+u._id+' live_enrolled='+n);
")
info "$ENROLLED"
if echo "$ENROLLED" | grep -q "live_enrolled=1"; then
  pass "Live product enrolled despite sibling failure (loop tries all products)"
else
  fail "Live product was NOT enrolled: $ENROLLED"
fi

step "4. Verify the soft-deleted product was NOT enrolled"
DEAD_N=$(mongo --eval "
  var u = db.users.findOne({tenant_id:ObjectId('$ACME_TENANT'), email:'$BUYER_EMAIL'});
  if (!u) { print(0); quit(); }
  print(db.course_enrollments.find({tenant_id:ObjectId('$ACME_TENANT'), contact_id:u._id, product_id:ObjectId('$PRODUCT_DEAD')}).count());
" | tr -d '\r\n ')
if [[ "$DEAD_N" == "0" ]]; then
  pass "Soft-deleted product correctly has no enrollment"
else
  fail "Soft-deleted product got $DEAD_N enrollment(s) (expected 0)"
fi

step "Cleanup"
CONTACT_ID=$(mongo --eval "
  var u = db.users.findOne({tenant_id:ObjectId('$ACME_TENANT'), email:'$BUYER_EMAIL'});
  print(u ? u._id.toString() : '');
" | tr -d '\r\n ')
CLEAN="db.offers.deleteOne({_id:ObjectId('$OFFER_ID')});"
if [[ -n "$CONTACT_ID" ]]; then
  CLEAN+="
    db.subscriptions.deleteMany({contact_id:ObjectId('$CONTACT_ID')});
    db.course_enrollments.deleteMany({contact_id:ObjectId('$CONTACT_ID')});
    db.users.deleteOne({_id:ObjectId('$CONTACT_ID')});"
fi
mongo --eval "$CLEAN print('cleaned');" > /dev/null
pass "Cleaned up"

echo
if [[ "$FAILS" -eq 0 ]]; then echo "${GREEN}${BOLD}ALL PASS${RESET}"
else echo "${RED}${BOLD}$FAILS FAILED${RESET}"; fi
exit "$FAILS"
