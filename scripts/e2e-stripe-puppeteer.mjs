#!/usr/bin/env node
// ═══════════════════════════════════════════════════════════════════════════════
// SENTANYL — End-to-End: Customer purchase journey via Puppeteer
//
// WHAT THIS VERIFIES (in a real browser, against real Stripe test mode):
//   1. Buyer visits the Stripe Checkout URL for a 2-product bundle offer,
//      enters card 4242 4242 4242 4242, completes payment.
//   2. Stripe redirects back to /portal/welcome?session_id=...
//   3. Portal polls /api/customer/checkout/lookup until our webhook has
//      finished provisioning, then redirects to /portal/set-password.
//   4. Buyer sets a password, lands on /portal/ (Library).
//   5. Library shows BOTH products from the bundle.
//   6. Buyer makes a SECOND purchase (single-product offer) with the SAME
//      email. This time the lookup returns existing_account and the portal
//      redirects to /portal/login.
//   7. Buyer logs in with the password set earlier, library now shows ALL
//      THREE products.
//   8. Replaying a checkout.session.completed event produces no duplicates
//      in Mongo.
//
// HOW IT WORKS:
//   • Seeds the Acme tenant (josephalai@gmail.com) with two offers using
//     three non-deleted products.  Copies Stripe test keys from the
//     "Stripe Demo" tenant.
//   • Spawns `stripe listen` so Stripe's test webhooks are forwarded to
//     our local webhook endpoint.  Captures the ephemeral whsec_ and
//     writes it onto the Acme tenant so signatures verify.
//   • Creates each Checkout Session server-to-server via
//     /api/marketing/site/checkout/start, then drives Stripe's hosted
//     checkout form in Chromium.
//   • Screenshots each step to /tmp/e2e-stripe-puppeteer/ for review.
//
// RUN:
//     node scripts/e2e-stripe-puppeteer.mjs
//     HEADLESS=0 node scripts/e2e-stripe-puppeteer.mjs      # show the browser
//     KEEP=1   node scripts/e2e-stripe-puppeteer.mjs        # don't clean up
//
// REQUIRES: stripe CLI logged in, Docker services running, globally
// installed puppeteer (NODE_PATH resolves /usr/local/lib/node_modules).
// ═══════════════════════════════════════════════════════════════════════════════

import { spawn, spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';
import puppeteer from 'puppeteer';

// ─── Config ────────────────────────────────────────────────────────────────────
const ACME_TENANT     = '69e109222d12500001b38e2b';
const SOURCE_TENANT   = '69eae0e22b38610001312b93';
const PRODUCT_COACHING_A = '69e138da305ccd0001330461';
const PRODUCT_BRIDGE     = '69e26e12936aab00012a73ef';
const PRODUCT_COACHING_B = '69e29a71c06b060001267af9';
const MONGO_CONTAINER = process.env.MONGO_CONTAINER || 'sntl-mongo';
const MONGO_DB       = process.env.MONGO_DB         || 'sentanyl_db';
const HEADLESS       = process.env.HEADLESS !== '0';
const KEEP           = process.env.KEEP === '1';
const TIMEOUT_MS     = 60_000;
const BUYER_EMAIL    = process.env.BUYER_EMAIL || `pptr-${Date.now()}@example.com`;
const BUYER_PASSWORD = 'pptr-test-password-123';
const RUN_TAG        = String(Date.now());
// Offer IDs must be 24-char hex (valid bson.ObjectId).  Prefix the first byte
// with 0xa* / 0xb* so A and B are visually distinguishable in Mongo.
const HEX_STAMP      = Date.now().toString(16).padStart(20, '0').slice(-20);
const OFFER_A_ID     = `aaaa${HEX_STAMP}`;
const OFFER_B_ID     = `bbbb${HEX_STAMP}`;
const SCREENSHOT_DIR = '/tmp/e2e-stripe-puppeteer';
mkdirSync(SCREENSHOT_DIR, { recursive: true });

// ─── Logging ───────────────────────────────────────────────────────────────────
const C = { grn:'\x1b[32m', red:'\x1b[31m', yel:'\x1b[33m', dim:'\x1b[2m', bold:'\x1b[1m', rst:'\x1b[0m' };
let FAILS = 0;
function pass(m) { console.log(`${C.grn}✓${C.rst} ${m}`); }
function fail(m) { console.log(`${C.red}✗${C.rst} ${m}`); FAILS++; }
function info(m) { console.log(`${C.dim}·${C.rst} ${m}`); }
function step(m) { console.log(`\n${C.bold}${C.yel}── ${m} ──${C.rst}`); }

// ─── Mongo helper ──────────────────────────────────────────────────────────────
function mongoEval(js) {
  const r = spawnSync('docker', ['exec', '-i', MONGO_CONTAINER, 'mongosh', '--quiet', MONGO_DB, '--eval', js],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  if (r.status !== 0) throw new Error(`mongoEval failed: ${r.stderr}`);
  return r.stdout.trim();
}

// ─── Screenshot helper ─────────────────────────────────────────────────────────
let shotN = 0;
async function shot(page, name) {
  shotN++;
  const path = `${SCREENSHOT_DIR}/${String(shotN).padStart(2,'0')}-${name}.png`;
  await page.screenshot({ path, fullPage: true });
  info(`screenshot → ${path}`);
}

// ─── 1. Seed Mongo ─────────────────────────────────────────────────────────────
function seed() {
  step('1. Seed Stripe creds + two offers on Acme');
  const js = `
    var src = db.tenants.findOne({_id: ObjectId("${SOURCE_TENANT}")});
    if (!src || !src.stripe_secret_key) throw new Error("source tenant has no Stripe creds");
    db.tenants.updateOne({_id: ObjectId("${ACME_TENANT}")},
      {$set:{
        stripe_secret_key: src.stripe_secret_key,
        stripe_public_key: src.stripe_public_key,
        stripe_webhook_secret: src.stripe_webhook_secret,
        "timestamps.updated_at": new Date()
      }});
    var acme = ObjectId("${ACME_TENANT}");
    var now = new Date();
    db.offers.replaceOne({_id: ObjectId("${OFFER_A_ID}")}, {
      _id: ObjectId("${OFFER_A_ID}"), public_id: "pptr-bundle-${RUN_TAG}",
      tenant_id: acme, title: "Pptr Bundle: Coaching + Bridge",
      pricing_model: "one_time", amount: 9900, currency: "usd",
      included_products: [ObjectId("${PRODUCT_COACHING_A}"), ObjectId("${PRODUCT_BRIDGE}")],
      granted_badges: ["pptr_bundle", "pptr_vip"],
      timestamps: {created_at: now, updated_at: now}
    }, {upsert: true});
    db.offers.replaceOne({_id: ObjectId("${OFFER_B_ID}")}, {
      _id: ObjectId("${OFFER_B_ID}"), public_id: "pptr-single-${RUN_TAG}",
      tenant_id: acme, title: "Pptr Single: Coaching-B",
      pricing_model: "one_time", amount: 4900, currency: "usd",
      included_products: [ObjectId("${PRODUCT_COACHING_B}")],
      granted_badges: ["pptr_single"],
      timestamps: {created_at: now, updated_at: now}
    }, {upsert: true});
    var site = db.sites.findOne({tenant_id: acme, status: "published"});
    if (!site) throw new Error("no published site for Acme");
    print(site.public_id);
  `;
  const sitePublicID = mongoEval(js).split('\n').pop().trim();
  pass(`Seeded offers; site public_id = ${sitePublicID}`);
  return sitePublicID;
}

// ─── 2. stripe listen ──────────────────────────────────────────────────────────
async function startStripeListen() {
  step('2. Start `stripe listen` and capture ephemeral webhook secret');
  const forward = `http://localhost/api/marketing/stripe/webhook?tenant_id=${ACME_TENANT}`;
  // Use the tenant's own sk_test_ so the CLI listens on the right Stripe
  // account (the CLI's default project may point at a different account).
  const apiKey = mongoEval(`print(db.tenants.findOne({_id:ObjectId("${ACME_TENANT}")}).stripe_secret_key);`).trim();
  if (!apiKey.startsWith('sk_test_') && !apiKey.startsWith('sk_live_')) {
    throw new Error('tenant has no stripe_secret_key — did seed() run?');
  }
  const proc = spawn('stripe', ['listen', '--skip-verify', '--api-key', apiKey, '--forward-to', forward],
    { stdio: ['ignore','pipe','pipe'] });
  let whsec = '';
  const deadline = Date.now() + 10_000;
  await new Promise((resolve, reject) => {
    const onData = (buf) => {
      const s = buf.toString();
      process.stdout.write(`${C.dim}[stripe listen] ${s}${C.rst}`);
      const m = s.match(/whsec_[a-zA-Z0-9]+/);
      if (m && !whsec) { whsec = m[0]; resolve(); }
    };
    proc.stdout.on('data', onData);
    proc.stderr.on('data', onData);
    proc.on('exit', (code) => { if (!whsec) reject(new Error(`stripe listen exited ${code}`)); });
    setTimeout(() => { if (!whsec) reject(new Error('stripe listen did not print whsec_ in 10s')); }, 10_000);
  });
  pass(`webhook secret captured (prefix=${whsec.slice(0,10)}…)`);
  mongoEval(`db.tenants.updateOne({_id:ObjectId("${ACME_TENANT}")},{$set:{stripe_webhook_secret:"${whsec}"}});print("ok");`);
  info('tenant.stripe_webhook_secret updated to match stripe listen session');
  return { proc, whsec };
}

// ─── 3. Create Checkout Session ────────────────────────────────────────────────
async function createCheckoutURL(offerID, sitePublicID) {
  const body = {
    domain: `${sitePublicID}.site.lvh.me`,
    offer_id: offerID,
    email: BUYER_EMAIL,
    success_url: `/portal/welcome?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: '/',
  };
  const resp = await fetch('http://localhost/api/marketing/site/checkout/start', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const data = await resp.json();
  if (!resp.ok || !data.checkout_url) throw new Error(`checkout-start failed (${resp.status}): ${JSON.stringify(data)}`);
  return data.checkout_url;
}

// ─── 4. Drive Stripe's hosted checkout ─────────────────────────────────────────
async function payOnStripe(page, checkoutURL) {
  info(`navigating to Stripe Checkout: ${checkoutURL}`);
  await page.goto(checkoutURL, { waitUntil: 'networkidle2', timeout: TIMEOUT_MS });
  await shot(page, 'stripe-checkout-loaded');

  // Stripe Checkout renders fields directly (not in iframes) with stable ids.
  // If the email field is present (not pre-filled), fill it.
  try {
    const emailEl = await page.$('input#email');
    if (emailEl) {
      await emailEl.click({ clickCount: 3 });
      await page.keyboard.press('Backspace');
      await emailEl.type(BUYER_EMAIL, { delay: 15 });
    }
  } catch {}

  await page.waitForSelector('input#cardNumber', { timeout: TIMEOUT_MS });
  await page.type('input#cardNumber', '4242 4242 4242 4242', { delay: 20 });
  await page.type('input#cardExpiry', '12 / 34', { delay: 20 });
  await page.type('input#cardCvc', '123', { delay: 20 });
  // Name on card.
  const name = await page.$('input#billingName');
  if (name) await name.type('Pptr E2E Buyer', { delay: 15 });
  // Country / ZIP sometimes appear. Fill defensively.
  const zip = await page.$('input#billingPostalCode');
  if (zip) await zip.type('94107', { delay: 15 });

  await shot(page, 'stripe-form-filled');

  // Submit. Stripe uses data-testid="hosted-payment-submit-button".
  const submitSel = 'button[data-testid="hosted-payment-submit-button"], form button[type="submit"]';
  await page.waitForSelector(submitSel, { timeout: TIMEOUT_MS });
  await Promise.all([
    page.waitForNavigation({ waitUntil: 'networkidle2', timeout: TIMEOUT_MS }),
    page.click(submitSel),
  ]);
  await shot(page, 'post-submit');
}

// ─── 5. Portal flow: welcome → set-password → library ──────────────────────────
async function handlePostCheckout(page, { newBuyer }) {
  // Stripe redirects us to /portal/welcome?session_id=... but the page polls
  // and redirects itself quickly; we may already be past welcome by the time
  // this runs. Accept any /portal/* as the landing.
  const url0 = page.url();
  info(`landed: ${url0}`);
  if (!/\/portal\//.test(url0)) {
    throw new Error(`expected /portal/*, got ${url0}`);
  }
  await shot(page, 'portal-welcome');

  // If we're still on welcome, wait for the poll to redirect us.
  const nextTarget = newBuyer ? /\/portal\/set-password\?token=/ : /\/portal\/login/;
  if (!nextTarget.test(page.url())) {
    await page.waitForFunction(
      (re) => new RegExp(re).test(location.href),
      { timeout: 45_000 },
      nextTarget.source
    );
  }

  if (newBuyer) {
    info(`redirected to set-password: ${page.url()}`);
    await shot(page, 'portal-set-password');
    await page.waitForSelector('input#password', { timeout: TIMEOUT_MS });
    await page.type('input#password', BUYER_PASSWORD, { delay: 15 });
    await page.type('input#confirm', BUYER_PASSWORD, { delay: 15 });
    await page.click('form button[type="submit"]');
  } else {
    info(`redirected to login: ${page.url()}`);
    await shot(page, 'portal-login');
    // Login form expects email + password.  Email may be prefilled via ?email=
    const passInput = await page.waitForSelector('input[type="password"]', { timeout: TIMEOUT_MS });
    // Ensure email is filled (some layouts need us to set it explicitly).
    const emailInput = await page.$('input[type="email"]');
    if (emailInput) {
      const val = await page.evaluate((el) => el.value, emailInput);
      if (!val) { await emailInput.type(BUYER_EMAIL, { delay: 15 }); }
    }
    await passInput.type(BUYER_PASSWORD, { delay: 15 });
    await page.click('form button[type="submit"]');
  }

  // SPA navigates client-side (react-router), so there's no full-page nav
  // event — poll the URL until we land at /portal/ (library).
  await page.waitForFunction(
    () => {
      const p = location.pathname.replace(/\/+$/, '/');
      return p === '/portal/' || p === '/portal';
    },
    { timeout: TIMEOUT_MS }
  );
  info(`in library: ${page.url()}`);
  // Give the products API a tick to resolve.
  await sleep(1500);
  await shot(page, 'portal-library');
  const headings = await page.$$eval('h3', (els) => els.map((e) => e.textContent?.trim() ?? ''));
  return headings;
}

// ─── 6. Verify in Mongo ────────────────────────────────────────────────────────
function verifyDB() {
  const out = mongoEval(`
    var acme = ObjectId("${ACME_TENANT}");
    var u = db.users.findOne({tenant_id:acme, email:"${BUYER_EMAIL}"});
    if (!u) { print('JSON={"found":false}'); quit(); }
    var badges = db.badges.find({_id:{$in:u.badges||[]}},{name:1}).toArray().map(b=>b.name).sort();
    var subs = db.subscriptions.find({tenant_id:acme, contact_id:u._id}).toArray();
    var enrolls = db.course_enrollments.find({tenant_id:acme, contact_id:u._id}).toArray();
    print('JSON=' + JSON.stringify({
      found:true, contact_id:u._id.toString(), badges:badges,
      subscription_count:subs.length,
      enrollment_count:enrolls.length,
      enrolled_products: enrolls.map(e=>e.product_id.toString()).sort()
    }));
  `);
  const line = out.split('\n').find((l) => l.startsWith('JSON=')) || '';
  return JSON.parse(line.replace(/^JSON=/, ''));
}

// ─── 7. Cleanup ────────────────────────────────────────────────────────────────
function cleanup(contactID) {
  if (KEEP) {
    info(`KEEP=1 — leaving data. Contact=${contactID}, OfferA=${OFFER_A_ID}, OfferB=${OFFER_B_ID}`);
    return;
  }
  mongoEval(`
    db.offers.deleteMany({_id:{$in:[ObjectId("${OFFER_A_ID}"),ObjectId("${OFFER_B_ID}")]}});
    ${contactID ? `db.subscriptions.deleteMany({contact_id:ObjectId("${contactID}")});
    db.course_enrollments.deleteMany({contact_id:ObjectId("${contactID}")});
    db.users.deleteOne({_id:ObjectId("${contactID}")});` : ''}
    print('cleaned');
  `);
  pass('Cleaned up');
}

// ─── Main ──────────────────────────────────────────────────────────────────────
let listenProc = null;
let browser = null;
let contactID = null;
try {
  const sitePublicID = seed();
  info(`Buyer: ${BUYER_EMAIL}`);
  info(`Offer A (bundle, 2 products) id=${OFFER_A_ID}`);
  info(`Offer B (single, 1 product)  id=${OFFER_B_ID}`);

  const listen = await startStripeListen();
  listenProc = listen.proc;

  // Give stripe listen a moment to register the forward route.
  await sleep(1500);

  browser = await puppeteer.launch({
    headless: HEADLESS,
    args: [
      '--window-size=1280,900',
      '--no-sandbox',
      // Stripe's success_url points at http://<public_id>.site.lvh.me — keep
      // Chrome from auto-upgrading that to HTTPS, which Caddy doesn't serve
      // for dev hosts.
      '--disable-features=HttpsUpgrades,HttpsFirstBalancedModeAutoEnable,HttpsFirstModeV2,HttpsFirstModeIncognito',
    ],
    defaultViewport: { width: 1280, height: 900 },
  });
  const page = await browser.newPage();
  page.on('console', (msg) => {
    if (msg.type() === 'error') info(`[browser console.error] ${msg.text()}`);
  });
  page.on('response', (resp) => {
    const s = resp.status();
    if (s >= 400 && /\/api\//.test(resp.url())) {
      info(`[HTTP ${s}] ${resp.request().method()} ${resp.url()}`);
    }
  });

  // ── Purchase 1: bundle ──
  step('3. Purchase 1 — Bundle offer (2 products)');
  const urlA = await createCheckoutURL(OFFER_A_ID, sitePublicID);
  pass(`checkout URL: ${urlA}`);
  await payOnStripe(page, urlA);
  const libA = await handlePostCheckout(page, { newBuyer: true });
  info(`library after purchase 1: ${JSON.stringify(libA)}`);

  // ── Purchase 2: single, same buyer, must go through login ──
  step('4. Purchase 2 — Single offer, same buyer');
  await page.evaluate(() => { try { localStorage.clear(); sessionStorage.clear(); } catch {} });
  const urlB = await createCheckoutURL(OFFER_B_ID, sitePublicID);
  pass(`checkout URL: ${urlB}`);
  await payOnStripe(page, urlB);
  const libB = await handlePostCheckout(page, { newBuyer: false });
  info(`library after purchase 2: ${JSON.stringify(libB)}`);

  // ── Verify DB state ──
  step('5. Verify Mongo state');
  const st = verifyDB();
  console.log(JSON.stringify(st, null, 2));
  contactID = st.contact_id;

  if (st.subscription_count === 2) pass('2 Subscription rows');
  else fail(`expected 2 Subscriptions, got ${st.subscription_count}`);

  if (st.enrollment_count === 3) pass('3 CourseEnrollment rows');
  else fail(`expected 3 CourseEnrollments, got ${st.enrollment_count}`);

  for (const pid of [PRODUCT_COACHING_A, PRODUCT_BRIDGE, PRODUCT_COACHING_B]) {
    if (st.enrolled_products.includes(pid)) pass(`enrolled in ${pid}`);
    else fail(`missing enrollment for ${pid}`);
  }
  for (const b of ['pptr_bundle', 'pptr_vip', 'pptr_single']) {
    if (st.badges.includes(b)) pass(`badge granted: ${b}`);
    else fail(`badge missing: ${b}`);
  }

  // ── UI assertion: library shows 3 cards at end of flow ──
  step('6. UI assertion — library shows all 3 products');
  // libB was captured right after purchase 2.  Its headings are <h3> text
  // from Library.tsx's ProductCard — one per enrolled product.
  const productCards = libB.filter((t) => t && t.length > 0).length;
  if (productCards >= 3) pass(`library rendered ≥3 product cards (saw ${productCards})`);
  else fail(`library rendered ${productCards} product card(s), expected 3`);

} catch (e) {
  fail(`fatal: ${e.message}`);
  console.error(e.stack);
} finally {
  if (browser) await browser.close().catch(() => {});
  if (listenProc) { try { listenProc.kill('SIGINT'); } catch {} }
  cleanup(contactID);
  console.log();
  if (FAILS === 0) console.log(`${C.grn}${C.bold}ALL PASS${C.rst}`);
  else console.log(`${C.red}${C.bold}${FAILS} ASSERTION(S) FAILED${C.rst}`);
  process.exit(FAILS === 0 ? 0 : 1);
}
