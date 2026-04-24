#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# SENTANYL — End-to-End: Stripe webhook, multi-product + second-purchase dispatch
#
# WHAT THIS VERIFIES:
#   After two separate Stripe checkouts (one bundle offer with 2 products,
#   one single-product offer) by the same buyer:
#     • Exactly 2 Subscription rows exist for that buyer
#     • Exactly 3 CourseEnrollment rows exist across both purchases
#     • The buyer's User.Badges contains every badge both offers granted
#     • Replaying the same webhook event produces no duplicates
#
# WHY IT MATTERS:
#   The loop in serve_stripe_webhook.go:217-221 that iterates
#   offer.IncludedProducts has never run with more than one entry in this
#   database.  This exercises it end-to-end and also checks the second-
#   purchase merge into the same contact.
#
# HOW IT WORKS:
#   • Seeds Acme tenant (josephalai@gmail.com) with a bundle offer and a
#     single-product offer using existing Acme products.
#   • Copies real Stripe test credentials from the "Stripe Demo" tenant so the
#     webhook signature can be verified.
#   • POSTs two synthetic checkout.session.completed events signed with Acme's
#     StripeWebhookSecret to http://localhost/api/marketing/stripe/webhook.
#   • Queries MongoDB for Subscriptions, CourseEnrollments, Badges, and prints
#     PASS/FAIL per assertion.
#   • Replays event 1 to prove idempotency.
#   • Optionally cleans up (set KEEP=1 to leave data in place for inspection).
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

MONGO_CONTAINER="${MONGO_CONTAINER:-sntl-mongo}"
MONGO_DB="${MONGO_DB:-sentanyl_db}"
MARKETING_URL="${MARKETING_URL:-http://localhost/api/marketing}"

ACME_TENANT="69e109222d12500001b38e2b"                 # josephalai@gmail.com
SOURCE_TENANT="69eae0e22b38610001312b93"               # Stripe Demo (has test keys)
# Acme's three live (non-soft-deleted) products. The "Webinar Course"
# product 69e138da305ccd0001330460 is soft-deleted and would make
# /internal/enroll return 404, which the webhook silently swallows — not
# useful for this test.
PRODUCT_COACHING_A="69e138da305ccd0001330461"  # 1-on-1 Coaching (original)
PRODUCT_BRIDGE="69e26e12936aab00012a73ef"      # Bridge of Events
PRODUCT_COACHING_B="69e29a71c06b060001267af9"  # 1-on-1 Coaching (duplicate, distinct id)
BUYER_EMAIL="${BUYER_EMAIL:-e2e-multi-$(date +%s)@example.com}"

GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
pass() { echo "${GREEN}✓${RESET} $*"; }
fail() { echo "${RED}✗${RESET} $*"; FAILS=$((FAILS+1)); }
info() { echo "${DIM}·${RESET} $*"; }
step() { echo; echo "${BOLD}${YELLOW}── $* ──${RESET}"; }
FAILS=0

mongo() { docker exec -i "$MONGO_CONTAINER" mongosh --quiet "$MONGO_DB" "$@"; }

# Unique IDs so reruns don't collide with each other.
RUN_TAG="$(date +%s)"
OFFER_A_ID="$(printf 'e2ea%020x' "$RUN_TAG")"
OFFER_B_ID="$(printf 'e2eb%020x' "$RUN_TAG")"

# ─── 1. Seed tenant + offers ───────────────────────────────────────────────────
step "1. Seeding Stripe credentials + two offers on Acme"

mongo --eval "
  var src = db.tenants.findOne({_id: ObjectId('$SOURCE_TENANT')});
  if (!src || !src.stripe_webhook_secret) {
    throw new Error('source tenant has no Stripe creds to copy');
  }
  db.tenants.updateOne(
    {_id: ObjectId('$ACME_TENANT')},
    {\$set: {
      stripe_secret_key:     src.stripe_secret_key,
      stripe_public_key:     src.stripe_public_key,
      stripe_webhook_secret: src.stripe_webhook_secret,
      'timestamps.updated_at': new Date()
    }}
  );
  print('[ok] copied stripe creds from Stripe Demo -> Acme');
" > /dev/null
pass "Copied Stripe test credentials to Acme"

# Fetch the webhook secret back for local signing.
WHSEC=$(mongo --eval "print(db.tenants.findOne({_id:ObjectId('$ACME_TENANT')}).stripe_webhook_secret)" | tr -d '\r\n ')
if [[ -z "$WHSEC" || "$WHSEC" == "undefined" ]]; then
  fail "could not read back webhook secret"; exit 1
fi
info "webhook secret loaded (prefix=${WHSEC:0:10}…)"

# Create Offer A (bundle) and Offer B (single), plus associated Mongo docs.
mongo --eval "
  var acme = ObjectId('$ACME_TENANT');
  var now = new Date();
  db.offers.replaceOne(
    {_id: ObjectId('$OFFER_A_ID')},
    {
      _id: ObjectId('$OFFER_A_ID'),
      public_id: 'e2e-bundle-$RUN_TAG',
      tenant_id: acme,
      title: 'E2E Bundle: Webinar + Coaching',
      pricing_model: 'one_time',
      amount: 9900, currency: 'usd',
      included_products: [ObjectId('$PRODUCT_COACHING_A'), ObjectId('$PRODUCT_BRIDGE')],
      granted_badges: ['e2e_bundle_access', 'e2e_bundle_vip'],
      timestamps: {created_at: now, updated_at: now}
    },
    {upsert: true}
  );
  db.offers.replaceOne(
    {_id: ObjectId('$OFFER_B_ID')},
    {
      _id: ObjectId('$OFFER_B_ID'),
      public_id: 'e2e-single-$RUN_TAG',
      tenant_id: acme,
      title: 'E2E Single: Bridge of Events',
      pricing_model: 'one_time',
      amount: 4900, currency: 'usd',
      included_products: [ObjectId('$PRODUCT_COACHING_B')],
      granted_badges: ['e2e_bridge_access'],
      timestamps: {created_at: now, updated_at: now}
    },
    {upsert: true}
  );
  print('[ok] seeded offers');
" > /dev/null
pass "Seeded Offer A (bundle, 2 products) and Offer B (single, 1 product)"
info "Offer A = $OFFER_A_ID   [Coaching-A + Bridge]   badges: e2e_bundle_access, e2e_bundle_vip"
info "Offer B = $OFFER_B_ID   [Coaching-B]            badges: e2e_bridge_access"
info "Buyer   = $BUYER_EMAIL"

# ─── 2. Build + sign + POST webhook events ─────────────────────────────────────
sign_and_post() {
  local evt_id="$1" offer_id="$2" session_id="$3"
  local body
  body=$(cat <<JSON
{"id":"$evt_id","type":"checkout.session.completed","data":{"object":{
  "id":"$session_id","mode":"payment",
  "customer_email":"$BUYER_EMAIL",
  "customer_details":{"email":"$BUYER_EMAIL","name":"E2E Buyer"},
  "metadata":{"offer_id":"$offer_id","tenant_id":"$ACME_TENANT","domain":"acme.local"}
}}}
JSON
)
  local ts; ts=$(date +%s)
  # Stripe signature = hex(HMAC-SHA256(secret, "ts.body"))
  local payload="${ts}.${body}"
  local sig
  sig=$(printf '%s' "$payload" | openssl dgst -sha256 -hmac "$WHSEC" -hex | awk '{print $2}')
  local header="t=${ts},v1=${sig}"

  local resp_code
  resp_code=$(curl -sS -o /tmp/e2e_stripe_resp.json -w '%{http_code}' \
    -X POST "$MARKETING_URL/stripe/webhook?tenant_id=$ACME_TENANT" \
    -H "Content-Type: application/json" \
    -H "Stripe-Signature: $header" \
    --data-binary "$body")
  echo "$resp_code  $(cat /tmp/e2e_stripe_resp.json)"
}

step "2. Purchase 1 — Offer A (bundle: 2 products)"
R1=$(sign_and_post "evt_e2e_a_$RUN_TAG" "$OFFER_A_ID" "cs_e2e_a_$RUN_TAG")
echo "  → $R1"
[[ "$R1" =~ ^200 ]] && pass "Offer A webhook accepted" || fail "Offer A webhook rejected: $R1"

step "3. Purchase 2 — Offer B (single product), same buyer"
R2=$(sign_and_post "evt_e2e_b_$RUN_TAG" "$OFFER_B_ID" "cs_e2e_b_$RUN_TAG")
echo "  → $R2"
[[ "$R2" =~ ^200 ]] && pass "Offer B webhook accepted" || fail "Offer B webhook rejected: $R2"

# ─── 4. Verify DB state ────────────────────────────────────────────────────────
step "4. Verifying DB state"

REPORT=$(mongo --eval "
  var acme = ObjectId('$ACME_TENANT');
  var email = '$BUYER_EMAIL';
  var u = db.users.findOne({tenant_id:acme, email:email});
  if (!u) { print('JSON={\"found\":false}'); quit(); }

  // Resolve badge names from ObjectId references.
  var badgeDocs = db.badges.find({_id:{\$in: u.badges || []}},{name:1}).toArray();
  var badgeNames = badgeDocs.map(function(b){return b.name;}).sort();

  var subs = db.subscriptions.find({tenant_id:acme, contact_id:u._id}).toArray();
  var subOfferIds = subs.map(function(s){return s.offer_id.toString();}).sort();

  var enrolls = db.course_enrollments.find({tenant_id:acme, contact_id:u._id}).toArray();
  var enrollProductIds = enrolls.map(function(e){return e.product_id.toString();}).sort();

  print('JSON=' + JSON.stringify({
    found: true,
    contact_id: u._id.toString(),
    has_reset_token: !!u.password_reset_token,
    badges: badgeNames,
    subscription_count: subs.length,
    subscription_offers: subOfferIds,
    enrollment_count: enrolls.length,
    enrolled_products: enrollProductIds
  }));
" | grep '^JSON=' | sed 's/^JSON=//')

echo "$REPORT" | python3 -m json.tool 2>/dev/null || echo "$REPORT"

# Extract fields via jq-less python.
py() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get(sys.argv[2]) if '.' not in sys.argv[2] else eval('d'+''.join('[\"'+p+'\"]' for p in sys.argv[2].split('.'))))" "$REPORT" "$1"; }

FOUND=$(py found)
if [[ "$FOUND" != "True" ]]; then
  fail "Buyer contact not created"; exit 1
fi
pass "Buyer contact created"

SUB_COUNT=$(py subscription_count)
if [[ "$SUB_COUNT" == "2" ]]; then pass "2 Subscription rows (one per purchase)"
else fail "Expected 2 Subscriptions, got $SUB_COUNT"; fi

ENROLL_COUNT=$(py enrollment_count)
if [[ "$ENROLL_COUNT" == "3" ]]; then pass "3 CourseEnrollment rows (2 from bundle + 1 from single)"
else fail "Expected 3 CourseEnrollments, got $ENROLL_COUNT"; fi

# Check each product is enrolled.
for pid in "$PRODUCT_COACHING_A" "$PRODUCT_BRIDGE" "$PRODUCT_COACHING_B"; do
  if echo "$REPORT" | grep -q "\"$pid\""; then
    pass "Enrolled in product $pid"
  else
    fail "Missing enrollment for product $pid"
  fi
done

# Check badges.
for b in e2e_bundle_access e2e_bundle_vip e2e_bridge_access; do
  if echo "$REPORT" | grep -q "\"$b\""; then
    pass "Badge granted: $b"
  else
    fail "Badge missing: $b"
  fi
done

# ─── 5. Idempotency (replay Offer A) ───────────────────────────────────────────
step "5. Idempotency — replay Offer A webhook"
R3=$(sign_and_post "evt_e2e_a_$RUN_TAG" "$OFFER_A_ID" "cs_e2e_a_$RUN_TAG")
echo "  → $R3"
[[ "$R3" =~ ^200 ]] && pass "Replay accepted (200)" || fail "Replay not accepted: $R3"

REPLAY=$(mongo --eval "
  var acme = ObjectId('$ACME_TENANT');
  var u = db.users.findOne({tenant_id:acme, email:'$BUYER_EMAIL'});
  var subs = db.subscriptions.find({tenant_id:acme, contact_id:u._id}).count();
  var enrolls = db.course_enrollments.find({tenant_id:acme, contact_id:u._id}).count();
  print('sub='+subs+' enroll='+enrolls);
")
echo "  post-replay: $REPLAY"
if echo "$REPLAY" | grep -q "sub=2 enroll=3"; then
  pass "No duplicate Subscriptions or Enrollments after replay"
else
  fail "Replay produced duplicates: $REPLAY"
fi

# ─── 6. Summary ────────────────────────────────────────────────────────────────
step "Summary"
CONTACT_ID=$(py contact_id)
echo "Tenant  : Acme ($ACME_TENANT)"
echo "Buyer   : $BUYER_EMAIL"
echo "Contact : $CONTACT_ID"
echo
if [[ "$FAILS" -eq 0 ]]; then
  echo "${GREEN}${BOLD}ALL PASS${RESET}"
else
  echo "${RED}${BOLD}$FAILS ASSERTION(S) FAILED${RESET}"
fi

if [[ "${KEEP:-0}" == "1" ]]; then
  echo
  info "KEEP=1 — leaving Mongo data in place for inspection."
  info "To remove later:"
  echo "    docker exec sntl-mongo mongosh --quiet sentanyl_db --eval '"
  echo "      db.offers.deleteMany({_id:{\$in:[ObjectId(\"$OFFER_A_ID\"),ObjectId(\"$OFFER_B_ID\")]}});"
  echo "      db.subscriptions.deleteMany({contact_id:ObjectId(\"$CONTACT_ID\")});"
  echo "      db.course_enrollments.deleteMany({contact_id:ObjectId(\"$CONTACT_ID\")});"
  echo "      db.users.deleteOne({_id:ObjectId(\"$CONTACT_ID\")});"
  echo "    '"
else
  step "Cleanup"
  mongo --eval "
    db.offers.deleteMany({_id:{\$in:[ObjectId('$OFFER_A_ID'),ObjectId('$OFFER_B_ID')]}});
    db.subscriptions.deleteMany({contact_id:ObjectId('$CONTACT_ID')});
    db.course_enrollments.deleteMany({contact_id:ObjectId('$CONTACT_ID')});
    db.users.deleteOne({_id:ObjectId('$CONTACT_ID')});
    print('[ok] cleaned up');
  " > /dev/null
  pass "Cleaned up seed data (set KEEP=1 to skip)"
fi

exit "$FAILS"
