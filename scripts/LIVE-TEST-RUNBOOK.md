# SentanylScript Live Integration Test Runbook

## What This Is

A set of instructions for Claude to manually test every SentanylScript fixture against the live Sentanyl platform. Claude deploys scripts, creates users, watches emails arrive in MailHog, simulates clicks/opens/webhooks, reads Docker logs, and verifies the full lifecycle works. Bugs are fixed in-place and retested until passing.

This catches bugs that automated tests miss — wrong-path-right-result issues, cascading serialization failures, timing/race conditions, and "works but smells wrong" problems.

## How To Resume

Tell Claude:

```
Read /Users/josephalai/go/src/github.com/sentanyl/scripts/LIVE-TEST-RUNBOOK.md and follow the instructions. Pick up from the first untested fixture in the tracker table.
```

## Environment

| Service | URL | Container |
|---------|-----|-----------|
| Sentanyl API | http://localhost:8000 | sntl-api |
| MailHog UI | http://localhost:8026 | sntl-mailhog |
| MailHog API | http://localhost:8026/api/v2/messages | sntl-mailhog |
| MongoDB | localhost:27017 | sntl-mongo |

**Subscriber ID**: `eTWiks7JvJUts2cNdyaqTT`
**Creator ID (MongoDB)**: Look up dynamically — `db.creators.findOne()._id` (changes on API restart/reseed)
**Email List ID**: Look up dynamically — `db.creators.findOne().lists[0]._id`

> **IMPORTANT**: Creator IDs change when the API container restarts and re-seeds. Always look up the current creator ID before creating test users:
> ```bash
> docker exec sntl-mongo mongo sentanyl --quiet --eval '
>   var c = db.creators.findOne();
>   print("creator_id=" + c._id + " list_id=" + c.lists[0]._id);
> '
> ```

## Pre-Flight Checklist

Before testing, verify:

1. **Docker containers running**: `docker ps | grep sntl`
2. **API responding**: `curl -s http://localhost:8000/api/script/fixtures | head -20`
3. **MailHog responding**: `curl -s http://localhost:8026/api/v2/messages`
4. **Branch**: `copilot/implement-sentanylscript-features`

If containers are down: `docker-compose up -d` (check which compose file — ports may be non-standard).

## Test Procedure Per Fixture

For EVERY fixture, follow these steps:

### Step 1: Clear State
```bash
# Clear MailHog
curl -s -X DELETE http://localhost:8026/api/v1/messages

# Deactivate all hot triggers for the test user
docker exec sntl-mongo mongo sentanyl --quiet --eval '
  db.hot_triggers.update(
    {"user_id": "<USER_PUBLIC_ID>", "active": true},
    {"$set": {"active": false}},
    {multi: true}
  );
'
```

### Step 2: Deploy the Fixture

Compress all timeframes to **seconds** (10s-15s) for fast testing. Load the fixture source from the API or from the Go constants, modify durations, then deploy:

```bash
curl -s http://localhost:8000/api/script/deploy \
  -H "Content-Type: application/json" \
  -d '{"source": "<SCRIPT_WITH_COMPRESSED_TIMEFRAMES>", "subscriber_id": "eTWiks7JvJUts2cNdyaqTT"}'
```

Note the returned `public_id` for the story.

### Step 3: Create Test User (if needed)

Create a fresh user in MongoDB with proper fields:

```bash
docker exec sntl-mongo mongo sentanyl --quiet --eval '
  var pid = "test_<fixture_name>_" + Math.random().toString(36).substr(2, 8);
  db.users.insert({
    "public_id": pid,
    "subscriber_id": "eTWiks7JvJUts2cNdyaqTT",
    "creator_id": ObjectId("69cf8b90e1ca65009c9284a9"),
    "email_list": ObjectId("69cf8b90e1ca65009c9284aa"),
    "email": "<fixture>@t.local",
    "name": {"first_name": "Test", "last_name": "User"},
    "subscribed": true,
    "current_scene_idx": 0,
    "retry_count": 0,
    "timestamps": {"created_at": new Date(), "updated_at": new Date()}
  });
  print(pid);
'
```

### Step 4: Start the Story

```bash
curl -s -X POST "http://localhost:8000/api/user/<USER_PID>/story/<STORY_PID>" \
  -H "Content-Type: application/json" \
  -d '{"subscriber_id": "eTWiks7JvJUts2cNdyaqTT"}'
```

### Step 5: Verify Email Arrival

```bash
curl -s http://localhost:8026/api/v2/messages | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
for m in data.get('items', []):
    h = m['Content']['Headers']
    print(f'{h.get(\"Subject\",[\"?\"])[0]} -> {h.get(\"To\",[\"?\"])[0]}')
"
```

### Step 6: Simulate User Actions (fixture-dependent)

**Click a link:**
```bash
# Find tracking URL in email HTML, then:
curl -s -L "http://localhost:8000/api/track/click/<BASE64_TOKEN>"
```

**Simulate open:**
```bash
curl -s -X POST "http://localhost:8000/api/webhooks/email/opened" \
  -H "Content-Type: application/json" \
  -d '{"subscriber_id": "eTWiks7JvJUts2cNdyaqTT", "user_public_id": "<USER_PID>"}'
```

**Give a badge:**
```bash
curl -s -X POST "http://localhost:8000/api/user/<USER_PID>/badge" \
  -H "Content-Type: application/json" \
  -d '{"subscriber_id": "eTWiks7JvJUts2cNdyaqTT", "name": "<BADGE_NAME>"}'
```

### Step 7: Watch Logs for Timed Tests

```bash
docker logs sntl-api --since 30s 2>&1 | grep -E "(EXPIRED|retry|advance|trigger|execute|email sent)"
```

### Step 8: Check User State

```bash
curl -s "http://localhost:8000/api/user/<USER_PID>?subscriber_id=eTWiks7JvJUts2cNdyaqTT" | python3 -m json.tool
```

Or directly in MongoDB:
```bash
docker exec sntl-mongo mongo sentanyl --quiet --eval '
  printjson(db.users.findOne({"public_id": "<USER_PID>"}, {story_status:1, current_scene_idx:1, retry_count:1}));
'
```

### Step 9: Log Results

Update the tracker table below. If a bug is found:
1. Log it in `scripts/live-test-log-2026-04-03T0907.md` with timestamp and full details
2. Fix the bug in source code
3. `docker restart sntl-api` to pick up changes
4. Retest from Step 1
5. Mark as PASS only after the fix is verified

### Step 10: Commit Periodically

After every 5-8 fixtures (or after any bug fix), commit and push:
```bash
git add -A && git commit -m "..." && git push origin copilot/implement-sentanylscript-features
```

---

## Fixture Tracker

| # | Fixture | Category | Status | Notes |
|---|---------|----------|--------|-------|
| 1 | `simple-one-storyline` | Core | PASS | Simple send-only |
| 2 | `multi-storyline` | Core | PASS | No triggers, doesn't auto-advance (by design) |
| 3 | `multi-enactment` | Core | PASS | Fixed BUG-005/006/007, full 3-enactment lifecycle |
| 4 | `multi-scene` | Core | PASS | 3-scene drip in single enactment |
| 5 | `conditional-badge-routing` | Core | PASS | Fixed BUG-001 (serialization) |
| 6 | `click-branching` | Core | PASS | Fixed BUG-003 (missing from_email) |
| 7 | `open-branching` | Core | PASS | |
| 8 | `bounded-retry` | Core | PASS | Fixed BUG-002 (runtime) + BUG-004 (compiler) |
| 9 | `loop-to-prior-enactment` | Core | PASS | Fixed BUG-008/009/010/011, full loop cycle |
| 10 | `failure-fallback` | Core | PASS | Fixed BUG-012, on_fail routing works (badges TBD) |
| 11 | `completion-path` | Core | PASS | 2-storyline completion lifecycle |
| 12 | `full-campaign` | Core | PASS | 2 storylines, 4 enactments, full lifecycle |
| 13 | `compound-trigger-conditions` | E2E | PASS | jump_to_enactment routing verified |
| 14 | `conditional-routing` | E2E | PASS | Both premium (badge-gated) and standard routing paths verified |
| 15 | `conditional-trigger` | E2E | PASS | Badge-gated click triggers, VIP vs standard routing |
| 16 | `storyline-badge-gating` | E2E | PASS | Storyline entry gating by badge, auto-skip |
| 17 | `story-interruption` | E2E | PASS | Full interrupt/resume cycle |
| 18 | `outbound-webhooks` | E2E | PASS | Fixed BUG-014/015, StoryStarted+TriggerTriggered+StoryCompleted delivered |
| 19 | `persistent-links` | E2E | PASS | Badge enrollment + persistent click triggers |
| 20 | `deferred-transitions` | E2E | PASS | 2 storylines × 2 enactments, full lifecycle |
| 21 | `mailhog-full-sequence` | E2E | PASS | 3 SL, 36 enactments, instant delivery, email confirmed |
| 22 | `hybrid-transitions` | E2E | PASS | 3 SL, 39 enactments, mixed deferred+instant, email confirmed |
| 23 | `multi-storyline-enactment-scene` | E2E | PASS | 2×2 SL/enactments, 7 scenes, full lifecycle |
| 24 | `v2-compact-campaign` | V2 | PASS | 4 enactments × 3 scenes from pattern+range, default sender |
| 25 | `v2-default-sender` | V2 | PASS | Email delivered with inherited from_email |
| 26 | `v2-links-and-policies` | V2 | PASS | 2 enactments with click policies compiled |
| 27 | `v2-scenes-range` | V2 | PASS | scenes 1..5 generated 5 scenes, email delivered |
| 28 | `v2-pattern-reuse` | V2 | PASS | 2 storylines from same pattern, email delivered |
| 29 | `v3-data-block-for-loop` | V3 | PASS | Data block + for loop → 4 enactments, interpolated subjects |
| 30 | `v3-storyline-generation` | V3 | PASS | For loop → 3 storylines × 2 enactments, ordered |
| 31 | `v3-inline-data-loop` | V3 | PASS | Inline data for loop → 3 enactments |
| 32 | `v3-enactment-defaults` | V3 | PASS | enactment_defaults with policy applied |
| 33 | `v3-full-generative-campaign` | V3 | PASS | 3 tracks × 4 phases = 12 enactments, email delivered |
| 34 | `v3-dot-access-triggers` | V3 | PASS | Dot-access order, link refs in triggers, badge on_complete |
| 35 | `atomic-all-trigger-types` | Atomic | PASS | 15 trigger types, 3 enactments, email delivered |
| 36 | `atomic-all-action-types` | Atomic | PASS | 20 action types, 2 SL, 6 EN, loop/retry/jump |
| 37 | `atomic-badge-integration` | Atomic | PASS | 13 badges, story/SL/trigger-level badges |
| 38 | `atomic-conditions-and-routing` | Atomic | PASS | when/and/or/not conditions, conditional routes |
| 39 | `atomic-scene-features` | Atomic | PASS | template, vars (3 KV), tags (3) all persisted |
| 40 | `atomic-v3-badge-campaign` | Atomic | PASS | v3 for loop + badge mechanics, 3 SL/3 EN |
| 41 | `multi-story-sequence` | Multi-Story | PASS | 2 stories, 5 SL, 14 EN, data/for/dot-access |
| 42 | `next-story-hopping` | Coverage | PASS | Fixed BUG-013 (NextStory pointer), cross-story chaining |
| 43 | `storyline-on-fail-routes` | Coverage | PASS | on_fail conditional routes with badge gating |
| 44 | `scene-template-name` | Coverage | PASS | 2 templates with vars, Handlebars subjects |
| 45 | `scene-defaults-triggers` | Coverage | PASS | scene_defaults trigger injection to 2 enactments |
| 46 | `handlebars-vars` | Coverage | PASS | 4 vars with Handlebars placeholders in subject/body |

## Bug Log Reference

All bugs found during testing are documented with timestamps in:
`scripts/live-test-log-2026-04-03T0907.md`

## Key Rules

1. **Compress timeframes to seconds** (10s-15s) for fast testing
2. **Log EVERY finding** — even passing tests, note what was verified
3. **Fix bugs immediately** — don't skip to the next fixture
4. **Retest after fixes** — a fixture only gets PASS after the fix is verified
5. **Read Docker logs** — don't just check "did email arrive", check the path was correct
6. **Commit after every bug fix** and after every 5-8 passing fixtures
7. **Update this tracker table** as you go — it's the source of truth for progress
8. **Create test users with proper creator_id** — use MongoDB insert, not the API (API doesn't set public_id)

## Testing Priority Order

Test in this order (highest-value/most-likely-to-find-bugs first):

1. **Core fixtures** (#3, #4, #9-12) — fundamental entity graph patterns
2. **E2E fixtures** (#13-16, #18, #20-23) — complex multi-step flows
3. **Coverage gap fixtures** (#42-46) — features that were previously untested
4. **Multi-story** (#41) — cross-story sequencing
5. **Atomic fixtures** (#35-40) — granular feature validation
6. **V2 fixtures** (#24-28) — DSL v2 authoring sugar
7. **V3 fixtures** (#29-34) — generative/loop features
