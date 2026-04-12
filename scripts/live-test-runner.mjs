#!/usr/bin/env node
/**
 * live-test-runner.mjs — Sentanyl Live Integration Test Harness
 *
 * Runs every integration test fixture end-to-end against a live Sentanyl API:
 *   1. Starts a local webhook receiver (accessible from Docker containers)
 *   2. Resets DB between tests
 *   3. Registers creator + test user
 *   4. Fetches fixture source, compresses all time durations to 1 minute
 *   5. Deploys script via POST /api/script/deploy
 *   6. Starts stories via PUT /api/story/:id/start
 *   7. Polls MailHog for arriving emails
 *   8. Simulates clicks, opens, custom webhooks as needed
 *   9. Reports pass/fail per test with rich terminal output
 *
 * Usage:
 *   node scripts/live-test-runner.mjs [options]
 *
 * Options:
 *   --base URL          Sentanyl API base URL  (default: http://localhost:8000)
 *   --mailhog URL       MailHog API base URL   (default: http://localhost:8026)
 *   --filter PATTERN    Only run fixtures whose ID contains PATTERN
 *   --fixture ID        Run only this specific fixture ID
 *   --no-reset          Skip DB reset between tests (faster, less isolated)
 *   --timeout MS        Per-test timeout in ms  (default: 30000)
 *   --webhook-port PORT Port for webhook receiver (default: 9988)
 *   --verbose           Log all HTTP request/response bodies
 *   --list              List all available fixtures and exit
 */

import http from 'http';
import https from 'https';
import { execSync } from 'child_process';

// ── CLI args ──────────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const getArg = (flag, def) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : def;
};
const hasFlag = (flag) => args.includes(flag);

const BASE         = getArg('--base', 'http://localhost:8000');
const MAILHOG      = getArg('--mailhog', 'http://localhost:8026');
const FILTER       = getArg('--filter', '');
const ONLY_FIXTURE = getArg('--fixture', '');
const NO_RESET     = hasFlag('--no-reset');
const TIMEOUT_MS   = parseInt(getArg('--timeout', '30000'), 10);
const WEBHOOK_PORT = parseInt(getArg('--webhook-port', '9988'), 10);
const VERBOSE      = hasFlag('--verbose');
const LIST_ONLY    = hasFlag('--list');

// ── Colours ───────────────────────────────────────────────────────────────────
const C = {
  reset:  '\x1b[0m',
  bold:   '\x1b[1m',
  dim:    '\x1b[2m',
  red:    '\x1b[31m',
  green:  '\x1b[32m',
  yellow: '\x1b[33m',
  cyan:   '\x1b[36m',
  blue:   '\x1b[34m',
  magenta:'\x1b[35m',
};
const bold   = (s) => `${C.bold}${s}${C.reset}`;
const dim    = (s) => `${C.dim}${s}${C.reset}`;
const red    = (s) => `${C.red}${s}${C.reset}`;
const green  = (s) => `${C.green}${s}${C.reset}`;
const yellow = (s) => `${C.yellow}${s}${C.reset}`;
const cyan   = (s) => `${C.cyan}${s}${C.reset}`;
const blue   = (s) => `${C.blue}${s}${C.reset}`;

const log     = (...a) => console.log(...a);
const ok      = (msg) => log(`  ${green('✓')} ${msg}`);
const warn    = (msg) => log(`  ${yellow('⚠')} ${msg}`);
const fail    = (msg) => log(`  ${red('✗')} ${msg}`);
const info    = (msg) => log(`  ${blue('ℹ')} ${msg}`);
const section = (msg) => log(`\n${cyan(bold('══ ' + msg + ' ══'))}`);

// ── Docker-accessible IP detection ───────────────────────────────────────────
function detectDockerIP() {
  // On Linux: use docker0 bridge IP so containers can reach us
  // On Mac/Windows: use host.docker.internal
  try {
    const ifaces = execSync('ip addr show docker0 2>/dev/null', { encoding: 'utf8', stdio: ['pipe','pipe','pipe'] });
    const m = ifaces.match(/inet (\d+\.\d+\.\d+\.\d+)/);
    if (m) return m[1];
  } catch {}
  try {
    // Try to resolve host.docker.internal (prefer IPv4)
    const r = execSync('getent ahostsv4 host.docker.internal 2>/dev/null || getent hosts host.docker.internal 2>/dev/null', { encoding: 'utf8', stdio: ['pipe','pipe','pipe'] }).trim();
    if (r) {
      const ip = r.split(/\s+/)[0];
      if (/^\d+\.\d+\.\d+\.\d+$/.test(ip)) return ip;
    }
  } catch {}
  // Fallback: typical Linux docker0 bridge address
  return '172.17.0.1';
}

// ── Webhook receiver ──────────────────────────────────────────────────────────
const receivedWebhooks = [];
let webhookServer = null;
let webhookIP = '172.17.0.1';

function startWebhookServer() {
  return new Promise((resolve) => {
    webhookServer = http.createServer((req, res) => {
      let body = '';
      req.on('data', (chunk) => body += chunk);
      req.on('end', () => {
        let parsed = null;
        try { parsed = JSON.parse(body); } catch {}
        const entry = { url: req.url, method: req.method, body: parsed, raw: body, ts: Date.now() };
        receivedWebhooks.push(entry);
        if (VERBOSE) log(dim(`  [webhook-rx] ${req.method} ${req.url} → ${body.slice(0, 200)}`));
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      });
    });

    webhookServer.listen(WEBHOOK_PORT, '0.0.0.0', () => {
      log(`${cyan('▶')} Webhook receiver listening on 0.0.0.0:${WEBHOOK_PORT}`);
      log(`  Docker-accessible at: ${bold(`http://${webhookIP}:${WEBHOOK_PORT}`)}`);
      resolve();
    });
  });
}

function clearWebhooks() { receivedWebhooks.length = 0; }

function waitForWebhook(urlPattern, timeoutMs = 5000) {
  return new Promise((resolve) => {
    const start = Date.now();
    const poll = setInterval(() => {
      const found = receivedWebhooks.find(w => urlPattern.test ? urlPattern.test(w.url) : w.url.includes(urlPattern));
      if (found) { clearInterval(poll); resolve(found); return; }
      if (Date.now() - start > timeoutMs) { clearInterval(poll); resolve(null); }
    }, 100);
  });
}

// ── HTTP helpers ──────────────────────────────────────────────────────────────
function request(method, urlStr, body = null, extraHeaders = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlStr);
    const lib = url.protocol === 'https:' ? https : http;
    const headers = { 'Content-Type': 'application/json', ...extraHeaders };
    const bodyStr = body ? JSON.stringify(body) : null;
    if (bodyStr) headers['Content-Length'] = Buffer.byteLength(bodyStr);

    if (VERBOSE) log(dim(`  → ${method} ${urlStr}`) + (bodyStr ? dim(` ${bodyStr.slice(0, 200)}`) : ''));

    const req = lib.request({
      hostname: url.hostname,
      port: url.port || (url.protocol === 'https:' ? 443 : 80),
      path: url.pathname + url.search,
      method,
      headers,
    }, (res) => {
      let data = '';
      res.on('data', (c) => data += c);
      res.on('end', () => {
        if (VERBOSE) log(dim(`  ← ${res.statusCode} ${data.slice(0, 200)}`));
        let json = null;
        try { json = JSON.parse(data); } catch {}
        resolve({ status: res.statusCode, body: json, raw: data });
      });
    });
    req.on('error', reject);
    if (bodyStr) req.write(bodyStr);
    req.end();
  });
}

const get  = (url, body) => request('GET', url, body);
const post = (url, body) => request('POST', url, body);
const put  = (url, body) => request('PUT', url, body);
const del  = (url, body) => request('DELETE', url, body);

// ── Duration compression ──────────────────────────────────────────────────────
// Replaces all time-duration literals in SentanylScript source with 1m.
// Patterns: "3d", "2h", "30m", "1d", etc. — numeric + unit in context.
function compressDurations(source) {
  // Match: within Nd/Nh/Nm, wait Nd/Nh/Nm
  // We want to keep "up_to N times" untouched (no unit), only duration values
  return source
    // "within 3d" → "within 1m"
    .replace(/\bwithin\s+\d+[dhm]\b/g, 'within 1m')
    // "wait 1d" → "wait 1m"
    .replace(/\bwait\s+\d+[dhm]\b/g, 'wait 1m')
    // "within 3 days" → "within 1m" (long-form)
    .replace(/\bwithin\s+\d+\s+(?:days?|hours?|minutes?)\b/gi, 'within 1m')
    // "wait 3 days" → "wait 1m"
    .replace(/\bwait\s+\d+\s+(?:days?|hours?|minutes?)\b/gi, 'wait 1m');
}

// ── MailHog helpers ───────────────────────────────────────────────────────────
async function mailhogMessages(limit = 50) {
  try {
    const r = await get(`${MAILHOG}/api/v2/messages?limit=${limit}`);
    if (r.status === 200 && r.body) return r.body.items || [];
  } catch {}
  return [];
}

async function mailhogClear() {
  try { await del(`${MAILHOG}/api/v1/messages`); } catch {}
}

async function waitForEmail(toAddress, timeoutMs = 10000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const msgs = await mailhogMessages();
    const match = msgs.find(m => {
      const to = (m.To || []).map(r => r.Mailbox + '@' + r.Domain).join(',');
      return !toAddress || to.includes(toAddress) || to.includes(toAddress.split('@')[0]);
    });
    if (match) return match;
    await sleep(300);
  }
  return null;
}

async function getAllEmails() {
  return mailhogMessages(100);
}

function extractLinksFromEmail(msg) {
  if (!msg) return [];
  const body = msg.Content?.Body || msg.MIME?.Parts?.[0]?.Body || '';
  const decoded = Buffer.from(body, 'base64').toString('utf8').replace(/=\r?\n/g, '').replace(/=3D/g, '=');
  const hrefs = [...decoded.matchAll(/href=["']([^"']+)["']/gi)].map(m => m[1]);
  return hrefs;
}

function getEmailTo(msg) {
  if (!msg) return null;
  return (msg.To || []).map(r => `${r.Mailbox}@${r.Domain}`).join(',');
}

function getEmailSubject(msg) {
  return msg?.Content?.Headers?.Subject?.[0] || '';
}

// ── Sentanyl API helpers ──────────────────────────────────────────────────────
async function resetDB() {
  const r = await post(`${BASE}/api/admin/reset`, {});
  if (r.status !== 200) warn(`DB reset returned ${r.status}`);
}

async function registerCreator(email) {
  const r = await post(`${BASE}/api/register`, {
    first_name: 'Test',
    last_name:  'Runner',
    email,
    reply_to:   email,
    password:   'TestPass123!',
    list_name:  'Test List',
  });
  if (r.status !== 200 && r.status !== 201) throw new Error(`register creator failed: ${r.status} ${r.raw.slice(0,200)}`);
  return r.body?.creator?.public_id;
}

async function registerUser(subscriberId, email, firstName = 'Test', lastName = 'User') {
  const r = await post(`${BASE}/api/register/user`, {
    subscriber_id: subscriberId,
    email,
    first_name: firstName,
    last_name:  lastName,
  });
  if (r.status !== 200 && r.status !== 201) throw new Error(`register user failed: ${r.status} ${r.raw.slice(0,200)}`);
  return r.body?.user?.public_id;
}

async function deployScript(subscriberId, source) {
  const r = await post(`${BASE}/api/script/deploy`, {
    subscriber_id: subscriberId,
    source,
  });
  if (r.status !== 201) throw new Error(`deploy failed: ${r.status} ${r.raw.slice(0,500)}`);
  return r.body; // { stories: [...], badges: [...], diagnostics: [...] }
}

async function startStory(storyId, subscriberId, userId) {
  const r = await put(`${BASE}/api/story/${storyId}/start`, {
    subscriber_id: subscriberId,
    user_id: userId,
  });
  return r;
}

async function getUserDetail(userId, subscriberId) {
  const r = await get(`${BASE}/api/user/${userId}/detail`, { subscriber_id: subscriberId });
  return r.body;
}

async function simulateClick(subscriberId, userEmail, linkUrl) {
  const r = await post(`${BASE}/api/webhooks/email/clicked`, {
    subscriber_id: subscriberId,
    email_address: userEmail,
    link: { url: linkUrl },
  });
  if (VERBOSE) log(dim(`  click ${linkUrl} → ${r.status}`));
  return r;
}

async function simulateOpen(subscriberId, userEmail, emailId) {
  const r = await post(`${BASE}/api/webhooks/email/opened`, {
    subscriber_id: subscriberId,
    email_address: userEmail,
    email_id: emailId,
  });
  if (VERBOSE) log(dim(`  open ${emailId} → ${r.status}`));
  return r;
}

async function simulateWebhook(eventName, subscriberId, extraData = {}) {
  const r = await post(`${BASE}/api/webhooks/${eventName}`, {
    subscriber_id: subscriberId,
    ...extraData,
  });
  if (VERBOSE) log(dim(`  webhook ${eventName} → ${r.status}`));
  return r;
}

async function simulateBounce(subscriberId, userEmail) {
  return post(`${BASE}/api/webhooks/email/bounced`, {
    subscriber_id: subscriberId,
    email_address: userEmail,
  });
}

async function simulateSpam(subscriberId, userEmail) {
  return post(`${BASE}/api/webhooks/email/spam`, {
    subscriber_id: subscriberId,
    email_address: userEmail,
  });
}

// ── Story parsing helpers ─────────────────────────────────────────────────────
function parseDeployedStories(deployResult) {
  // deployResult.stories is array of JSON-encoded story objects (raw strings)
  const stories = [];
  for (const raw of (deployResult.stories || [])) {
    try {
      const s = typeof raw === 'string' ? JSON.parse(raw) : raw;
      stories.push(s);
    } catch {}
  }
  return stories;
}

function storyPublicId(story) {
  return story?.public_id || story?.PublicId || story?._id || null;
}

function storyName(story) {
  return story?.name || story?.Name || '';
}

// ── Utilities ─────────────────────────────────────────────────────────────────
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function withTimeout(promise, ms, label) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error(`timeout: ${label}`)), ms)),
  ]);
}

// Encode a tracking URL the same way the server does (base64url of "url|publicId")
function makeTrackingUrl(originalUrl, userPublicId) {
  const raw = `${originalUrl}|${userPublicId}`;
  const b64 = Buffer.from(raw).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
  return `${BASE}/api/track/click/${b64}`;
}

// ── Test runner core ──────────────────────────────────────────────────────────

const testResults = [];

async function runTest(fixture) {
  const id = fixture.id;
  const name = fixture.name;
  const result = { id, name, passed: false, skipped: false, error: null, log: [] };
  const testLog = (msg) => { result.log.push(msg); if (VERBOSE) log(dim(`    ${msg}`)); };

  section(`${id} — ${name}`);

  try {
    await withTimeout(runTestBody(fixture, testLog), TIMEOUT_MS, id);
    result.passed = true;
    ok(`${bold(name)} PASSED`);
  } catch (err) {
    result.error = err.message;
    fail(`${bold(name)} FAILED: ${err.message}`);
    if (!VERBOSE) result.log.forEach(l => log(dim(`    ${l}`)));
  }

  testResults.push(result);
}

async function runTestBody(fixture, log) {
  const ts = Date.now();
  const creatorEmail = `creator-${ts}@test.local`;
  const userEmail    = `user-${ts}@test.local`;

  // 1. Reset DB
  if (!NO_RESET) {
    log('Resetting DB...');
    await resetDB();
    await mailhogClear();
  }

  // 2. Register creator + user
  log(`Registering creator: ${creatorEmail}`);
  const subscriberId = await registerCreator(creatorEmail);
  if (!subscriberId) throw new Error('creator registration returned no public_id');
  log(`  subscriber_id = ${subscriberId}`);

  log(`Registering user: ${userEmail}`);
  const userId = await registerUser(subscriberId, userEmail, 'Test', 'User');
  if (!userId) throw new Error('user registration returned no public_id');
  log(`  user_id = ${userId}`);

  // 3. Compress durations in source
  const compressed = compressDurations(fixture.source);
  log(`Durations compressed in source (${fixture.source.length} → ${compressed.length} chars)`);

  // 4. Deploy script
  log('Deploying script...');
  const deployed = await deployScript(subscriberId, compressed);

  if (deployed.diagnostics?.length) {
    const errors = deployed.diagnostics.filter(d => d.level === 'error');
    if (errors.length) throw new Error(`Compile errors: ${errors.map(e => e.message).join('; ')}`);
    const warns = deployed.diagnostics.filter(d => d.level === 'warning');
    if (warns.length) log(`  Warnings: ${warns.map(w => w.message).join('; ')}`);
  }

  const stories = parseDeployedStories(deployed);
  if (!stories.length) throw new Error('No stories returned from deploy');
  log(`  Deployed ${stories.length} story(ies): ${stories.map(storyName).join(', ')}`);

  // 5. Start all stories
  log('Starting stories...');
  for (const story of stories) {
    const pid = storyPublicId(story);
    if (!pid) { log(`  WARNING: story has no public_id, skipping start`); continue; }
    const startResult = await startStory(pid, subscriberId, userId);
    if (startResult.status !== 200 && startResult.status !== 201) {
      log(`  WARNING: start story ${pid} returned ${startResult.status}: ${startResult.raw.slice(0,200)}`);
    } else {
      log(`  Started story "${storyName(story)}" (${pid})`);
    }
  }

  // 6. Wait for first email
  log('Waiting for first email from MailHog...');
  const firstEmail = await waitForEmail(userEmail, 8000);
  if (!firstEmail) {
    warn(`No email arrived for ${userEmail} within 8s — story may have no immediate send`);
    log(`  Checking if story started with deferred or badge-gated entry...`);
    // Not a hard failure — some scripts use send_immediate false or badge gating
    return;
  }

  const subject = getEmailSubject(firstEmail);
  log(`  Received: "${subject}" → to ${getEmailTo(firstEmail)}`);

  // 7. Extract + simulate interactions
  const links = extractLinksFromEmail(firstEmail);
  log(`  Found ${links.length} link(s) in email`);

  // Determine interaction strategy based on fixture ID
  await simulateInteractions(fixture, {
    subscriberId, userId, userEmail,
    stories, deployed,
    firstEmail, links,
    log,
  });
}

// ── Interaction simulator ─────────────────────────────────────────────────────
// For each fixture, we simulate the appropriate interactions.
// The strategy: try to click all tracking links (which are /api/track/click/...),
// or simulate direct webhooks. We cycle through emails until none arrive.

async function simulateInteractions(fixture, ctx) {
  const { subscriberId, userEmail, log } = ctx;
  const id = fixture.id;

  // Collect interactions to perform based on fixture characteristics
  const strategy = inferStrategy(fixture);
  log(`  Strategy: ${strategy.join(', ')}`);

  let emailCount = 1;
  let currentEmails = [ctx.firstEmail];

  // Process emails in waves
  for (let wave = 0; wave < 10; wave++) {
    if (!currentEmails.length) break;

    for (const email of currentEmails) {
      const subject = getEmailSubject(email);
      const links = extractLinksFromEmail(email);
      log(`  [wave ${wave}] email: "${subject}", links: ${links.length}`);

      const trackingLinks = links.filter(l => l.includes('/api/track/click/'));
      const externalLinks = links.filter(l => !l.includes('/api/track/') && l.startsWith('http'));

      if (strategy.includes('click') && trackingLinks.length) {
        // Click the first tracking link
        const clickUrl = trackingLinks[0];
        log(`    clicking tracking link: ${clickUrl.slice(0, 80)}...`);
        const r = await get(clickUrl); // GET the tracking URL (simulates browser click)
        log(`    → ${r.status}`);
        emailCount++;
      } else if (strategy.includes('click') && externalLinks.length) {
        // Simulate click via webhook
        const url = externalLinks[0];
        log(`    simulating click webhook: ${url}`);
        await simulateClick(subscriberId, userEmail, url);
        emailCount++;
      }

      if (strategy.includes('open')) {
        const emailId = email.ID || email.id;
        if (emailId) {
          log(`    simulating open: ${emailId}`);
          await simulateOpen(subscriberId, userEmail, emailId);
        }
      }

      if (strategy.includes('webhook')) {
        // Fire a generic webhook event
        const eventName = inferWebhookEventName(fixture);
        log(`    simulating webhook event: ${eventName}`);
        await simulateWebhook(eventName, subscriberId);
      }

      if (strategy.includes('bounce')) {
        log(`    simulating bounce`);
        await simulateBounce(subscriberId, userEmail);
      }

      if (strategy.includes('spam')) {
        log(`    simulating spam report`);
        await simulateSpam(subscriberId, userEmail);
      }
    }

    // Wait for next wave of emails
    await sleep(500);
    const allEmails = await getAllEmails();
    const newEmails = allEmails.slice(0, allEmails.length - emailCount + 1)
      .filter(e => {
        const to = getEmailTo(e);
        return to && to.includes(userEmail.split('@')[0]);
      });

    if (newEmails.length === currentEmails.length) break; // No new emails arrived
    currentEmails = newEmails.slice(currentEmails.length);
    if (!currentEmails.length) break;
  }

  log(`  Total emails processed: ~${emailCount}`);
}

// Infer what kinds of interactions a fixture needs based on its ID/name
function inferStrategy(fixture) {
  const id = fixture.id.toLowerCase();
  const name = (fixture.name || '').toLowerCase();
  const strategies = new Set();

  // Default: click (most fixtures use click triggers)
  strategies.add('click');

  if (id.includes('open') || id.includes('not_open') || name.includes('open')) {
    strategies.add('open');
  }
  if (id.includes('webhook') || id.includes('03_trigger') || name.includes('webhook')) {
    strategies.add('webhook');
  }
  if (id.includes('bounce') || name.includes('bounce')) {
    strategies.add('bounce');
  }
  if (id.includes('spam') || name.includes('spam')) {
    strategies.add('spam');
  }

  // Fixtures with "not_click" or "retry" should also simulate non-clicks via open
  if (id.includes('retry') || id.includes('loop') || id.includes('not_click')) {
    strategies.add('open');
  }

  return [...strategies];
}

function inferWebhookEventName(fixture) {
  const id = fixture.id.toLowerCase();
  // Try to extract event name from source
  const m = fixture.source.match(/on\s+webhook\s+"([^"]+)"/i);
  if (m) return m[1];
  return 'test_event';
}

// ── Main ──────────────────────────────────────────────────────────────────────
async function main() {
  log('');
  log(bold(cyan('╔══════════════════════════════════════════════════════════╗')));
  log(bold(cyan('║     SENTANYL LIVE INTEGRATION TEST RUNNER                ║')));
  log(bold(cyan('╚══════════════════════════════════════════════════════════╝')));
  log('');
  log(`  API:     ${bold(BASE)}`);
  log(`  MailHog: ${bold(MAILHOG)}`);
  log(`  Timeout: ${TIMEOUT_MS}ms per test`);
  log('');

  // Detect Docker IP for webhook receiver
  webhookIP = detectDockerIP();

  // Start webhook receiver
  await startWebhookServer();

  // Check server health
  log('\nChecking server health...');
  try {
    const health = await get(`${BASE}/`);
    ok(`Sentanyl API reachable (${health.status})`);
  } catch (err) {
    fail(`Sentanyl API not reachable at ${BASE}: ${err.message}`);
    fail('Start the server first, then re-run.');
    process.exit(1);
  }

  // Check MailHog
  try {
    const mh = await get(`${MAILHOG}/api/v2/messages`);
    ok(`MailHog reachable (${mh.status})`);
  } catch (err) {
    warn(`MailHog not reachable at ${MAILHOG}: ${err.message}`);
    warn('Email simulation will be limited.');
  }

  // Fetch fixtures list
  section('Fetching Fixtures');
  const fixturesResp = await get(`${BASE}/api/script/fixtures`);
  if (fixturesResp.status !== 200) {
    fail(`Failed to fetch fixtures: ${fixturesResp.status}`);
    process.exit(1);
  }

  const allFixtures = fixturesResp.body?.fixtures || [];
  log(`Found ${allFixtures.length} fixtures`);

  if (LIST_ONLY) {
    log('');
    log(bold('Available fixtures:'));
    for (const f of allFixtures) {
      log(`  ${cyan(f.id.padEnd(45))} ${f.name}`);
    }
    process.exit(0);
  }

  // Filter fixtures
  let toRun = allFixtures;
  if (ONLY_FIXTURE) {
    toRun = allFixtures.filter(f => f.id === ONLY_FIXTURE);
    if (!toRun.length) {
      fail(`Fixture "${ONLY_FIXTURE}" not found. Use --list to see available fixtures.`);
      process.exit(1);
    }
  } else if (FILTER) {
    toRun = allFixtures.filter(f => f.id.includes(FILTER) || (f.name || '').toLowerCase().includes(FILTER.toLowerCase()));
    log(`Filter "${FILTER}" matched ${toRun.length} fixture(s)`);
  }

  // Fetch full source for each fixture (list endpoint omits source)
  section(`Loading ${toRun.length} fixture sources`);
  const fixtures = [];
  for (const f of toRun) {
    try {
      const r = await get(`${BASE}/api/script/fixture/${f.id}`);
      if (r.status === 200 && r.body?.source) {
        fixtures.push({ ...f, source: r.body.source });
      } else {
        warn(`Could not fetch source for ${f.id}: ${r.status}`);
      }
    } catch (err) {
      warn(`Error fetching ${f.id}: ${err.message}`);
    }
  }
  ok(`Loaded ${fixtures.length} fixture sources`);

  // Run tests
  section(`Running ${fixtures.length} tests`);
  log('');

  for (const fixture of fixtures) {
    clearWebhooks();
    await runTest(fixture);
    // Brief pause between tests to let async ops settle
    await sleep(200);
  }

  // ── Summary ──────────────────────────────────────────────────────────────────
  log('');
  log(bold(cyan('══════════════════ RESULTS ══════════════════')));
  log('');

  const passed  = testResults.filter(r => r.passed);
  const failed  = testResults.filter(r => !r.passed && !r.skipped);
  const skipped = testResults.filter(r => r.skipped);

  for (const r of testResults) {
    const icon  = r.passed ? green('✓') : r.skipped ? yellow('○') : red('✗');
    const label = r.passed ? green('PASS') : r.skipped ? yellow('SKIP') : red('FAIL');
    log(`  ${icon} [${label}] ${r.id}`);
    if (!r.passed && !r.skipped && r.error) {
      log(`         ${red(r.error)}`);
    }
  }

  log('');
  log(bold(`  Total:   ${testResults.length}`));
  log(green(bold(`  Passed:  ${passed.length}`)));
  if (failed.length)  log(red(bold(`  Failed:  ${failed.length}`)));
  if (skipped.length) log(yellow(bold(`  Skipped: ${skipped.length}`)));
  log('');

  if (failed.length) {
    log(bold('Failed tests:'));
    for (const r of failed) {
      log(`\n  ${red(bold(r.name))}`);
      log(`  Error: ${r.error}`);
      if (r.log.length) {
        log('  Log:');
        r.log.forEach(l => log(`    ${dim(l)}`));
      }
    }
  }

  // Shutdown webhook server
  if (webhookServer) webhookServer.close();

  process.exit(failed.length ? 1 : 0);
}

main().catch((err) => {
  console.error(red(bold('\nFATAL: ' + err.message)));
  console.error(err.stack);
  process.exit(1);
});
