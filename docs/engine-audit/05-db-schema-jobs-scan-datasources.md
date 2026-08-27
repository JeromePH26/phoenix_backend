# 05 – DB Schema · Job System · Daily-Scan Orchestration · Tiering · API Data Sources

Repo: `phoenix_backend` (Dart / shelf). Read-only audit. Line refs are `path:line` vs repo root.
Date: 2026-08-27. Head commit `1673ee5`. Live counts from prod Postgres (`railway run --service Postgres`).

Working tree note: `lib/src/database/database.dart` and `lib/src/api/control_center_routes.dart` are
dirty (parallel audit work); all line numbers below are against the working-tree version.

---

## TL;DR

- **One giant schema file.** `database.dart` is 12,240 lines; `migrate()` (`:92-1129`) plus 10
  `_migrateX()` helpers run **every boot**, fully additive: `CREATE TABLE IF NOT EXISTS` +
  `ADD COLUMN IF NOT EXISTS` + `CREATE INDEX IF NOT EXISTS`. No `DROP TABLE`, no destructive
  `ALTER`. Only non-additive statements: guarded `RENAME COLUMN` in a `DO $$` block
  (`_migrateFootballAssetsSchema`, `:1837`), idempotent `DROP CONSTRAINT IF EXISTS` + re-`ADD` for
  CHECK changes, and a handful of one-off data-fix `UPDATE`s. `app_meta.schema_version` is a
  cosmetic string, currently `'11'` (`:1125`, live value `11`) — nothing reads it to branch.
- **~70 tables total.** Football engine + Model Lab own ~35 of them. `football_matches` holds only
  **4,304 rows spanning 2026-07-17 → 2026-08-27** (≈6 weeks). The real history depth lives in
  `historical_twin_matches` (68,000 rows, 2019–2025) and `historical_elo_ratings` (245,033 rows) —
  a **separate, read-only dataset never joined into the live engine path**.
- **Two orphan tables in prod, zero code references:** `football_final_tips`, `football_ai_context_jobs`
  (both empty). Left over from removed features — schema drift.
- **No "Learning Dataset Pipeline" / Production-Learning-Research classification exists.** The spec's
  §24-32 concept has no home today. The closest artifacts: `collection_tier`
  (`focus`/`watchlist`/`data_pool`/`blocked`) on `football_leagues`, and
  `phoenix_match_learning_flags` (per-fixture eligible/exclusion_reason, 9,667 rows — **all
  `eligible = true`**, no ineligible rows persisted). Data-class selection is currently inline SQL
  filters in `modelLabRawDataset()` (`:7198`), not a table.
- **3 job families, 3 different tracking mechanisms:** `football_daily_pipeline_jobs` (heartbeat +
  partial unique index), `football_match_settlement_jobs` (no concurrency guard at all),
  `phoenix_learning_runs` + `phoenix_model_lab_locks` (advisory-lock row + stale-lock reclaim).
  Each reinvents "a Railway redeploy killed my in-flight job" recovery separately.
- **Learning automation is de-facto not running.** All 15 `phoenix_learning_runs` are
  `trigger_type = 'manual'`; **zero `scheduled`**. 11 of 15 ended `failed` / `current_step='orphaned'`.
  `phoenix_monthly_reviews` = **0 rows ever**. `phoenix_model_assignments` = **0 rows ever** (the
  "append-only assignment history" table is dead — champion is read only from
  `phoenix_model_versions.status='champion'`).
- **API-Football main usage is uncapped.** `FootballService` records but never throttles
  (`recordApiSportsUsage`, fire-and-forget, `:3660`). Live: **4,629 requests on 2026-08-26**,
  2,821 on 2026-08-25; **2026-08-22 had 470 errors / 847 requests (55%)**, 2026-08-23 had 207.
  Rate-limit handling is purely reactive, and only inside the settlement backfill loop
  (`football_match_backfill_service.dart:185-196`).
- **Tier budgets vs. league count are wildly mismatched.** 1,159 `data_pool` + 28 `watchlist`
  leagues; the background enrichment budget is **200 fixtures/day**
  (`football_background_enrichment_service.dart:27`) and Phase 1 only lets **100** non-focus
  fixtures/run into `football_matches` at all (`football_phase_one_scan_service.dart:70`,
  `.clamp(0, 100)`).
- **Pre-match snapshots (`football_engine_inputs`)** are written only for **Phase-2-prepared
  fixtures of a scan run**, by `FootballEngineInputService.prepare()` (`:79`). For focus leagues
  that's during the nightly pipeline; for watchlist/data_pool it's the background enrichment pass.
  Timing relative to kickoff is *whenever the scan runs*, not a fixed pre-kickoff offset. Commit
  `1673ee5` re-ordered `backgroundEnrichmentCandidates` (`:4489`) to put `kickoff_utc > NOW()`
  fixtures first so the fixed daily budget lands where a still-valid pre-kickoff snapshot can be
  created.

---

## Table inventory (grouped, with row counts)

Live exact counts (2026-08-27 ~13:00 UTC). "—" = table exists, 0 rows.

### Match data
| table | rows | purpose / key cols |
|---|---:|---|
| `football_matches` | 4,304 | canonical fixture store; PK `id` (fixture id as TEXT). `kickoff_utc`, `status`, `league_id`, `home/away_goals`, `raw_json JSONB`. 9 per-match control flags added by Control Center (`visible`, `analysis_enabled`, `tip_enabled`, `learning_enabled`, `live_enabled`, `status_locked…`, `_migrateFootballMatchControls` `:1873`). Only 354 distinct leagues present, ~6 weeks span. Status mix: FT 2165, NS 1807, PST 58, live/HT ~140, CANC 36. |
| `football_leagues` | 1,234 | league catalog + tiering. PK `league_id`. `manual_status` (auto/whitelist/blacklist), `historical_status`, `collection_tier`, `background_enabled`, `detail_refresh_hours`, sample counters. Seeded whitelist of 35 (`:668-732`) + 1 blacklist (Belarus, `:736`). |
| `football_league_seasons` | 1,242 | per-league-season coverage counters (fixtures/standings/lineups/odds/… `_available`). 1,233 leagues, seasons 2014–2027. |
| `football_league_sync_state` | — | per-league sync timestamps. **Dead — never written.** |
| `football_scan_runs` | 246 | Phase-1/Phase-2 scan-run headers (`phase`, `status`, counts, `payload`). |
| `football_scan_matches` | 45,280 | per-fixture Phase-1 decision rows (`eligible`, `decision_status`, `exclusion_reason`, `payload`). FK→`football_scan_runs` ON DELETE CASCADE. Largest churny table. |
| `football_coverage_samples` | — | per-fixture coverage booleans. **Dead — never written** (0 rows). |
| `tennis_matches` | — | out of scope. |

### Features / analysis snapshots
| table | rows | purpose |
|---|---:|---|
| `football_phase_two_results` | 2,940 | per-fixture data-quality + `availability JSONB` + `payload` for a scan run. PK `(scan_run_id, fixture_id)`. 1,475 distinct fixtures, 2,116 `analysis_allowed`. |
| `football_engine_inputs` | 2,499 | **the pre-match snapshot** — normalized λ inputs. PK `(phase_two_scan_run_id, fixture_id)`. 1,388 distinct fixtures, 233 leagues. `normalized_input JSONB`, `data_quality`, `model_version`. DQ histogram: 80s=641, 90s=678, <40 ≈ 235. |
| `football_simulation_results` | 2,462 | Monte-Carlo output per fixture/scan. |
| `football_market_selections` | 2,431 | selected market / value per fixture/scan. |
| `football_ai_context_checks` | 86 | legacy AI-context step output. Step is permanently unwired (`football_daily_pipeline_service.dart:167-180`). |
| `football_analysis_history` | 1,411 | immutable published-prediction snapshots. `result_status`: won 740 / lost 539 / pending 119 / push 13 (~57.9% settled hit rate). Heavily indexed (7 indexes). |
| `analyses` | 1,487 | latest analysis per `(sport, match_id, model_version)` — what the app reads. |
| `baseball_analysis_history` | 32 | out of scope. |
| `football_season_projections` | — | league table Monte-Carlo. **0 rows.** |

### Odds / tips
| table | rows | purpose |
|---|---:|---|
| `daily_tips` | — | per-day tip payload. **0 rows.** |
| `football_daily_combos` | — | per-day combo snapshot. **0 rows** (combo builder produces nothing in prod). |
| `football_final_tips` | — | **ORPHAN — no code references, empty.** |

Odds themselves are **not stored** — fetched live per fixture via `/odds` (2-min cache) and used
transiently in `FootballValueService`.

### Model Lab
| table | rows | purpose |
|---|---:|---|
| `phoenix_model_versions` | 187 | immutable model registry. `market`, `league_id` (NULL=global), `status` (champion/challenger/retired/rejected), `weights/feature_config JSONB`, `config_hash`. **All 187 are `league_id IS NULL` (global).** ~17 markets × (1 champion + 9 challenger + 1 retired). Partial unique idx = one champion per `(market, league)` (`:2534`). |
| `phoenix_model_assignments` | — | append-only champion-assignment log. **Dead — 0 rows.** |
| `phoenix_learning_runs` | 15 | weekly learning-run headers. `status` running/completed/failed, `trigger_type` scheduled/manual. **15/15 manual; 11 failed (`orphaned`).** Run #15 ran 22:56→10:15 next day (11h). |
| `phoenix_learning_candidates` | 153 | challenger models created per run. |
| `phoenix_model_evaluations` | 1,224 | walk_forward / holdout / shadow / monthly_review metric rows (brier, log_loss, calibration JSONB, roi). |
| `phoenix_shadow_predictions` | 14,555 | pre-kickoff shadow preds (10,316 settled / 4,239 open). References snapshot by `(phase_two_scan_run_id, fixture_id)` instead of copying payload. |
| `phoenix_monthly_reviews` | — | champion-review results. **0 rows ever.** |
| `phoenix_model_audit_log` | 210 | model-lifecycle events. |
| `phoenix_match_learning_flags` | 9,667 | per-`(fixture, market)` learning eligibility. **All `eligible=true`** (ineligible rows are not persisted). |
| `phoenix_model_lab_locks` | — | advisory-lock rows (`lock_name` PK). 0 now (healthy = no run in flight). |

### Jobs
| table | rows | purpose |
|---|---:|---|
| `football_daily_pipeline_jobs` | 129 | nightly pipeline job. `status`, `current_step`, `phase_one/two_scan_run_id`, `processed`, `published`, `last_activity_at` (heartbeat). 90 completed / 39 failed. Partial unique index `((1)) WHERE status='running'` = max one at a time (`:574`). |
| `football_match_settlement_jobs` | 21 | result-backfill batch job. `checked/settled/pending/failed`, `last_error`. 20 completed / 1 failed. **No concurrency guard, no heartbeat.** |
| (`phoenix_learning_runs` also a job table — listed above) | | |

### Audit / ops / other (Control-Center scope, listed for completeness)
`admin_employees` (2), `admin_sessions` (~42), `admin_audit_log`, `admin_failed_logins`,
`admin_pending_two_factor_logins`, `app_control_state`, `module_control` (6), `system_audit_runs` (2),
`feature_flags`, `app_release_config`, `incidents`, `incident_timeline_events`,
`database_size_snapshots`, `support_tickets`, `support_ticket_messages`,
`phoenix_editorial_articles`, `phoenix_faq_articles`, `ad_campaigns`, `push_broadcasts`,
`premium_feature_matrix`, `media_assets`, `news_articles` (1,090), `push_devices` (0),
`football_favorites`/`football_favorite_entities`/`football_live_events`/`push_deliveries`/
`news_push_deliveries` (all 0), `app_meta` (1), `api_sports_daily_usage` (17).

**User-account schema now exists but is empty:** `users`, `user_auth_providers`, `user_sessions`,
`user_premium_entitlements`, `user_bans`, `ip_blocks` (`_migrateUserAccounts` `:1149`). `users` = 0
rows. (This contradicts the older memory note "PHÖNIX has no user accounts" — the *schema* landed
per AN2 §99, the data hasn't.)

### History / research dataset
| table | rows | purpose |
|---|---:|---|
| `historical_twin_matches` | 68,000 | external CSV import, 2019–2025, 38 divisions, Elo + rolling features in `features JSONB`. 15,108 matched to a `football_leagues.league_id`. Used only by Historical Twins UI. |
| `historical_elo_ratings` | 245,033 | EloRatings.csv time series, 2019+. Not fed into the engine. |

---

## Migration strategy & drift risk

- **Every boot, non-blocking.** `app.dart:148-152` calls `_initializeDatabase()` via `unawaited()`
  *after* the HTTP server is already serving `/health`, so a slow/failed migration never fails the
  Railway healthcheck. Failures are caught and logged (`app.dart:178-181`); server keeps running.
- **All additive.** Every `CREATE TABLE` is `IF NOT EXISTS`; every new column is a separate
  `ALTER TABLE … ADD COLUMN IF NOT EXISTS` (see the `football_daily_pipeline_jobs` back-fill block
  `:514-530` and `news_articles` `:958-962`). CHECK-constraint changes use the idempotent
  `DROP CONSTRAINT IF EXISTS` + `ADD CONSTRAINT` pattern (`:1447-1467`).
- **The only structural rewrite** is `_migrateFootballAssetsSchema` (`:1837`): a `DO $$` block that
  `RENAME COLUMN`s `football_assets.entity_type→asset_type` etc. **only if the old name still
  exists**, wrapped in `SET LOCAL lock_timeout='5s'` so it fails fast instead of hanging a deploy.
  This exists *because of* a real prior drift: prod `football_assets` was created with a different
  column set than the code expected, silently broken for months (comment `:1817-1836`).
- **Data-fix `UPDATE`s run every boot** and are mostly self-limiting (`WHERE` clauses that no longer
  match after the first run), e.g. `football_analysis_history SET assigned_units=0 WHERE …`
  (`:377-383`), the "fail jobs with no heartbeat for 15 min" sweep (`:554-563`), the
  `collection_tier` back-fill (`:635-650`).
- **Drift risks that remain:**
  1. Two orphan tables (`football_final_tips`, `football_ai_context_jobs`) — no `DROP`, so they
     persist forever. Harmless but confusing.
  2. `schema_version` is written but never checked — there is no real migration versioning /
     ordering guarantee beyond "the file runs top to bottom every time".
  3. Column *type/default* changes are done via `ALTER COLUMN … SET DEFAULT` (e.g. `simulations`
     `:582-585`) but **existing rows are not rewritten** — old jobs keep old defaults.
  4. `_migrateUserAccounts` FK-depends on `_migrateControlCenter` + `_migrateSupport` having run
     first; ordering is correct in `migrate()` (`:1112-1121`) but implicit, not enforced.
  5. Several `IF NOT EXISTS` tables were *also* later given `ADD COLUMN` blocks — a fresh DB gets
     the full `CREATE`, an old DB gets `CREATE` (no-op) + `ALTER`. The two definitions can drift
     (they already differ for `football_daily_pipeline_jobs`: `CREATE` has
     `last_activity_at … NOT NULL DEFAULT NOW()`, the `ALTER` adds it nullable then a separate
     statement makes it NOT NULL).

**Where a rebuild would add tables.** The spec's Learning Dataset Pipeline + Production/Learning/
Research classification has no schema today. Natural fit: a new `_migrateLearningDataset(db)` helper
adding e.g. `phoenix_learning_dataset` (one row per `(fixture, market)` with `data_class`
enum `production|learning|research|quarantine`, `feature_completeness`, `leakage_checked`,
`snapshot_ref`, `excluded_reason`) — replacing the implicit inline filters in `modelLabRawDataset()`
(`:7198-7260`) and giving `phoenix_match_learning_flags` a reason to store ineligible rows too.

---

## Job system & failure modes

### 1. `football_daily_pipeline_jobs` (nightly + manual daily scan)
- **Start:** `startFootballDailyPipelineJob()` (`:6980`). First runs a 15-min-no-heartbeat sweep
  (`:6991-7000`), then `INSERT … ON CONFLICT DO NOTHING` guarded by the partial unique index
  `idx_football_daily_pipeline_one_running` (`:574`). If insert returns nothing → returns the
  currently-running job with `started:false` (HTTP 409, `routes.dart:2090`).
- **Heartbeat:** `FootballDailyPipelineService.run()` starts a 30 s `Timer.periodic` →
  `touchFootballDailyPipelineJob()` (`football_daily_pipeline_service.dart:60-63`,
  `database.dart:7077`). Updates `last_activity_at` only while `status='running'`.
- **Orphan reclaim:** two paths — (a) the 15-min sweep at next start; (b)
  `failPipelineJobsFromEarlierServer()` (`:7091`) runs on **every server boot**
  (`app.dart:172`), marking *all* `running` rows `failed / current_step='interrupted_by_restart'`.
  Live: job #127 shows exactly this.
- **Failure modes:** long legitimate scans (>15 min with a dead heartbeat, e.g. a stuck provider
  call inside a step) can be reclaimed while still notionally alive; the `unawaited()` fire in the
  route means an exception after the response is only visible via `status='failed'` +
  `error` column.

### 2. `football_match_settlement_jobs`
- **Start:** `createFootballMatchSettlementJob()` (`:5117`) — plain `INSERT … RETURNING id`,
  **no ON CONFLICT, no running-check**. The route (`routes.dart:1189`) gates on
  `countPendingFootballMatchSettlementJobs()` in application code, which is racy.
- **No heartbeat.** Progress is written per batch (`updateFootballMatchSettlementJob`, `:5137`).
- **Orphan reclaim:** only `failPipelineJobsFromEarlierServer()` (`:7112-7122`) on boot, which also
  sweeps `football_match_settlement_jobs` where `status NOT IN ('completed','failed')`. Comment
  `:7105-7111` records this was added after a 2026-08-25 live incident (a deploy mid-batch left a
  job stuck `running` forever, blocking all future settlement, fixed by hand-SQL).
- **Rate-limit aware:** the batch loop detects "request limit / 429 / quota" strings and stops with
  `status='rate_limited'` (`football_match_backfill_service.dart:121-124,185-196`).

### 3. `phoenix_learning_runs` + `phoenix_model_lab_locks`
- **Lock:** `acquireModelLabLock(name, staleAfterMinutes)` (`:7933`) — `INSERT … ON CONFLICT
  (lock_name) DO UPDATE … WHERE locked_at < NOW() - make_interval(mins => @stale)`. Default stale
  = **180 min** (`ModelLabConfig.staleLockMinutes`, env `PHOENIX_MODEL_LAB_STALE_LOCK_MINUTES`).
- **Two orphan-reconcile paths** in `LearningRunService.run()` (`learning_run_service.dart:66-99`):
  - `recoverOrphanedLearningRunAndLock(staleAfterMinutes)` (`:7971`) — *before* re-acquiring the
    lock; age-gated; marks stale `running` rows `failed / current_step='orphaned'` and deletes the
    lock only if no fresh run exists. Returns the dead run's `summary`/`challengers_created` so a
    new run can resume (`_resumeStateFrom`).
  - `reconcileOrphanedLearningRuns()` (`:8040`) — *after* the lock is held; **age-independent**
    (holding the lock proves any other `running` row is dead). Added after a live case where the
    lock freed itself after 59 min (graceful shutdown) but the run never completed
    (comment `:8031-8039`).
- **Failure reality (live):** 11/15 runs `failed`, all `current_step='orphaned'` — i.e. **almost
  every learning run so far has been killed by a redeploy** (manual runs during active Model-Lab
  development). Run #15 finally completed after 11 h and created 68 challengers. The resume logic
  works but the underlying fragility (an 11-hour job on a service that redeploys on every push) is
  the core problem.
- **Locks table also guards** monthly review + promotion (same `acquireModelLabLock`, different
  `lock_name`), but monthly review has never run.

**Cross-cutting:** all three families independently solve "Railway redeploy = SIGTERM mid-job".
The DB connection itself is a **single shared connection, not a pool**, serialized by a
future-chaining gate (`database.dart:14-90`) after a live crash where the 5 s live-monitor poll
collided with an admin transaction and killed the process.

---

## Cron schedule & daily-scan order

Railway crons are configured in the dashboard (not in `railway.toml`, which only has build +
healthcheck). From memory + the scripts' self-docs:

| service | script | schedule (UTC) | effect |
|---|---|---|---|
| `phoenix_backend` (in project `athletic-heart`) | `bin/phoenix_daily_cron.dart` | `10 22,23 * * *` | runs at 22:10 & 23:10 UTC; script self-gates to the run that is **00:xx Europe/Berlin** (`phoenix_daily_cron.dart:23-29`), the other exits immediately. |
| model-lab cron | `bin/phoenix_model_lab_cron.dart` | **unconfirmed** — script recommends daily ~04:00 Berlin (`phoenix_model_lab_cron.dart:11-17`) | **Likely not actually scheduled**: 0 `phoenix_learning_runs` have `trigger_type='scheduled'`. |
| `energetic-peace` (web) | `bin/server.dart` | always-on | serves API; runs `migrate()` + boot sweeps. |

### Order inside `phoenix_daily_cron.dart` (`main()` `:44-113`)
1. **Settlement of prior days** — `POST /api/admin/football/settle?date=…` for offsets 1..3
   (or 1..9 if `PHOENIX_CRON_RECONCILE=true`), 7 s apart (`:49-69`). This grades *tips/combos* for
   ROI history.
2. **League catalog sync** — `POST /api/admin/football/catalog/sync` (`:75-80`) — one cacheable
   `/leagues?current=true` call; new leagues land in `data_pool`.
3. **Start daily scan** — `POST /api/admin/football/daily-scan?date=today&limit=1000&
   minimumDataQuality=0&simulations=10000` (`:83-87`, config `:378-398`). Note: cron default
   `simulations=10000`, but `startFootballDailyPipelineJob` and the pipeline **force ≥100,000**
   (`database.dart:7014-7016`, `football_daily_pipeline_service.dart:55`).
4. **Poll to completion** — `_waitForCompletion` polls `GET …/daily-scan/{id}` every 30 s up to
   90 min (`:236-290`); the cron process must stay alive or Railway kills the container mid-scan.
5. **Match-result settlement** — `POST /api/admin/football/matches/settle?minHoursSinceKickoff=3&
   batchSize=25` (`:172-194`), fire-and-forget (cron does not wait).

### Order inside `FootballDailyPipelineService.run()` (`:47-296`)
`phase1` → `phase2_prepare` → `phase2_processing` → *(AI-context step: skipped, permanently)* →
`engine_input` → `simulation` (100k) → `market_selection` (min prob 68) → `value_check_optional`
(≥1.40 odds, ≥5% value; failure swallowed) → `publishing` → `daily_combo` → `_finish` →
**then `unawaited` `FootballBackgroundEnrichmentService.run()`** for watchlist/data_pool (fixed
200-fixture budget, produces shadow analyses only).

### Model-lab cron order (`phoenix_model_lab_cron.dart:33-68`)
`POST /autopilot/run` (settle finished shadow preds + create new pre-match shadows) every day →
if UTC weekday == Tuesday: `POST /learning-runs/start` → if Wednesday: `POST /monthly-review/run`
(server re-checks it's the first Wednesday). Weekday is judged in **raw UTC** in the cron, only
re-validated in Berlin server-side (`ModelLabSchedule`).

---

## Collection tiers & budgets

`football_leagues.collection_tier ∈ {focus, watchlist, data_pool, blocked}` +
`background_enabled BOOL` + `detail_refresh_hours INT`. Enum lives in
`lib/src/model_lab/football_league_tier.dart`.

**How a league gets a tier:**
- `focus` ⇐ `manual_status='whitelist'` (35 seeded in `migrate()` `:683-720`, + manual via
  `POST /api/admin/football/leagues/{id}/tier`, `routes.dart:2123`). `detail_refresh_hours=1`.
- `blocked` ⇐ `manual_status='blacklist'` (1 seeded: Belarus). `background_enabled=FALSE`.
- `watchlist` / `data_pool` ⇐ everything else; new leagues auto-land in `data_pool` via
  `upsertLeagueSeen()` during Phase 1 (`football_phase_one_scan_service.dart:175-192`).
  `detail_refresh_hours=24`.

**Live distribution:** focus 46 · watchlist 28 · data_pool 1,159 · blocked 1 (all
`background_enabled=TRUE` except the 1 blocked). The seed is 35 whitelist → 46 focus means 11
leagues were promoted to focus manually.

**Budgets:**
| stage | limit | where |
|---|---:|---|
| Phase 1 non-focus fixtures written to `football_matches` per run | **100** (`backgroundFixtureLimit.clamp(0, 100)`) | `football_phase_one_scan_service.dart:70` |
| Phase 1 focus fixtures | unbounded (all today's focus) | `:68-71` |
| Background enrichment fixtures/day | **200** (`maxFixtures`, param default) | `football_background_enrichment_service.dart:27` |
| `backgroundEnrichmentCandidates` SQL LIMIT | `limit.clamp(1, 300)` | `database.dart:4559` |
| Phase-2 eligible-match limit (focus) | `effectiveLimit` = `limit ?? 1000` clamp 1..1000 | `football_daily_pipeline_service.dart:70` |
| Model-Lab challengers per league×market | 6 (`maxChallengersPerLeagueMarket`) | `model_lab_config.dart:220` |

**Where budgets are too small:** with 1,187 non-focus leagues and only 100 fixtures/run reaching
`football_matches` and 200/day enriched, a full matchday (the code comment cites "585 data_pool +
29 watchlist leagues", `:22-26`) cannot be covered — data_pool history accumulates at a trickle.
The `backgroundEnrichmentCandidates` LIMIT was raised 100→300 and `maxFixtures` 30→200 on
2026-08-25, but the upstream **Phase-1 `clamp(0, 100)` was not raised to match** — so the
enrichment pass often has <100 new candidates to work with regardless of its own 200 budget.
`detail_refresh_hours` for watchlist/data_pool is 24 h, so the same fixtures also compete for the
budget on re-refresh.

---

## API-Football: endpoints, caching, quota

**Client:** `FootballService` (`football_service.dart`), base `https://v3.football.api-sports.io`,
header `x-apisports-key`. Single allow-list of provider paths (`:457-481`).

**Endpoints actually called:**
| path | caller | cache TTL |
|---|---|---|
| `/fixtures?date=` | `matchesForDate` (Phase 1) | 1 min (`:512-514`) |
| `/fixtures?id=` | `fixtureById` (settlement), `liveSnapshot` | 5 min default |
| `/leagues?current=true` | `activeLeagueCatalog` (catalog sync) | 5 min |
| `/standings` | `coverageForFixture` | 10 min |
| `/fixtures?team=&last=5` | home/away recent form (2×/fixture) | 5 min |
| `/odds?fixture=` | coverage + `oddsForFixture` + value check | **2 min** (`:501-503`) |
| `/injuries?fixture=` | coverage | 5 min |
| `/fixtures/headtohead?h2h=&last=5` | coverage | 5 min |
| `/teams/statistics?league=&season=&team=` | coverage (up to 2×/fixture, +previous season if <3 played) | 10 min |
| `/fixtures/events`, `/fixtures/statistics` | `liveSnapshot` (favorite live monitor, 5 s loop) | 15 s |

`/fixtures/lineups` is **hard-disabled** (`:363-365`, returns empty). `realXgAvailable` is
**hard-`false`** (`:379-380`).

**Caching layer:** in-process `Map<String,_FootballCacheEntry>` keyed by sorted path+query
(`:403-447`), plus a `_providerFlights` in-flight dedup map. Cache is per-process, evicted at 500
entries. No shared/Redis cache — a redeploy cold-starts the cache.

**Per-fixture cost:** `coverageForFixture` = ~8–10 provider calls (standings, 2× recent, odds,
injuries, h2h, 2× team-stats, sometimes +2 previous-season). A 43-fixture focus matchday ≈ 350–450
calls, plus 200 enrichment fixtures ≈ 1,600–2,000 calls, plus settlement.

**Usage tracking:** `api_sports_daily_usage (api_name, usage_date, requests, errors)` PK
`(api_name, usage_date)`. Two write paths:
- `recordApiSportsUsage('football')` / `recordApiSportsError('football')` — **uncapped**,
  fire-and-forget, from `FootballService._get` (`:718-728`, `database.dart:3660-3688`).
- `consumeApiSportsRequest(apiName, safetyLimit)` — atomic reserve-one guarded by
  `WHERE requests < safetyLimit`, **`safetyLimit.clamp(1, 100)`** (`database.dart:3633-3654`).
  This is the *old free-plan* guard, now used **only by the secondary `ApiSportsTeamEngine`**
  (other sports), never by the football main path.

**Quota:** the code comment says "Free-Plan: 100 requests/day" (`:104`) but live volume proves a
paid plan — API-Football **Pro = 7,500 req/day** (Ultra = 75,000). Live daily `requests`:
2026-08-27 179 (partial), **2026-08-26 4,629**, 2026-08-25 2,821, 2026-08-23 1,785 (**207 err**),
2026-08-22 847 (**470 err**). A normal focus-only day runs ~2,000–3,000; a day with a full
learning/settlement/enrichment burst hit 4,629 ≈ **62% of a 7,500 Pro quota**. The error spikes on
Aug 22–23 (55% / 12% error rate) indicate the quota *was* hit or the key was mid-upgrade.
**There is no proactive throttle** — only the reactive string-match in the settlement loop.

---

## Pre-match snapshot creation path

`football_engine_inputs` rows are written by exactly one method:
`FootballEngineInputService.prepare()` → `database.saveFootballEngineInput()`
(`football_engine_input_service.dart:79-87`, PK `(phase_two_scan_run_id, fixture_id)`).

**Which fixtures:** `database.phaseFourCandidates(phaseTwoScanRunId, limit, includeBackground)`
(`database.dart:4603`) — the fixtures that passed Phase-2 `prepare/processPrepared` for that scan
run. Two entry points:
1. **Nightly / manual daily pipeline** (`football_daily_pipeline_service.dart:181-192`) — focus
   leagues only, `includeBackground:false`, after Phase-2 processing.
2. **Background enrichment** (`football_background_enrichment_service.dart:87-93`) — watchlist +
   data_pool, `includeBackground:true`, runs `unawaited` right after the public pipeline finishes.

**When relative to kickoff:** whenever its scan runs. The nightly cron fires at Berlin 00:00, so
focus snapshots are typically created 0–24 h before kickoff (same calendar day). Background
enrichment runs immediately after → same window for watchlist/data_pool, *if* the fixture is still
pre-kickoff. There is **no explicit "T-minus-N-hours" trigger.**

**Leakage guard:** `modelLabRawDataset()` (`:7198`) takes `DISTINCT ON (fixture_id)` the snapshot
with `created_at < kickoff_utc` (ordering prefers pre-kickoff, `bin/…eligibility_probe.dart:48-53`
mirrors it). A snapshot created after kickoff is flagged `timestamp_invalid` and is permanently
unusable for learning.

**Interaction with commit `1673ee5`:** `backgroundEnrichmentCandidates` (`database.dart:4489`) now
(a) excludes never-enriched fixtures whose kickoff has already passed
(`AND (m.kickoff_utc > NOW() OR last_detail.created_at IS NOT NULL)`, `:4539-4542`) and (b) orders
`CASE WHEN m.kickoff_utc > NOW() THEN 0 ELSE 1 END` first (`:4547`). So the fixed 200/day budget is
now spent **pre-kickoff fixtures first**, maximizing the number of *valid* (leakage-free) snapshots
that can still be created before the whistle. Previously the budget could be burned on
already-started fixtures (comment: 151 otherwise-usable settled fixtures were lost that way). The
change is purely a candidate ordering/filter — it does not add budget, so on a heavy matchday
low-priority data_pool fixtures still get no snapshot at all.

---

## Fragility / tech debt

1. **Single shared DB connection, no pool** (`database.dart:12-90`). A future-chaining gate
   serializes transactions vs. everything else; a bare `execute()` racing a starting `runTx` can
   still (narrowly) crash the whole process. Documented, not fixed.
2. **12,240-line `database.dart`.** Schema DDL, ~200 query methods, Model-Lab logic, Control-Center
   logic all in one class. `migrate()` + 10 helpers is the only "schema source of truth" and it's
   interleaved with one-off data `UPDATE`s.
3. **3 job systems, 3 orphan-recovery implementations**, each born from a separate live incident
   (comments dated 2026-08-23/24/25). No shared "lease + heartbeat + reclaim" abstraction.
4. **Learning run is an 11-hour job on a push-to-deploy service.** Guaranteed to be orphaned by any
   deploy during its window; resume logic mitigates but every orphan still burns API budget and
   leaves a `failed` row. 11/15 runs orphaned.
5. **Scheduled automation unverified / not firing.** 0 `scheduled` learning runs, 0 monthly
   reviews ever. The weekly/monthly cadence in AN2 §45-49 is currently manual-only in practice.
6. **`phoenix_model_assignments` and `phoenix_model_lab_locks` design mismatch:** assignment
   history table is dead (champion state is a column flag); the "audit trail" the schema comment
   promises (`:2547-2551`) doesn't exist in data.
7. **Tier budget chain is inconsistent:** Phase-1 `clamp(0,100)` vs enrichment `maxFixtures=200`
   vs SQL `clamp(1,300)` — three different numbers for one pipeline, only partially raised in the
   2026-08-25 change.
8. **Orphan tables** `football_final_tips`, `football_ai_context_jobs` — no code, no `DROP`.
9. **Dead tables** `football_league_sync_state`, `football_coverage_samples`,
   `football_season_projections`, `daily_tips`, `football_daily_combos` — schema + queries exist,
   0 rows in prod (features effectively off).
10. **API cost has no ceiling.** `recordApiSportsUsage` counts but never blocks; the only guard
    (`consumeApiSportsRequest`, `clamp(1,100)`) is wired to the wrong (secondary) client. A runaway
    loop or a bad matchday can silently exhaust the quota (as on Aug 22).
11. **`api_sports_daily_usage` "day" is `NOW() AT TIME ZONE 'UTC'`** while scans think in Berlin
    time — the usage counter rolls over mid-evening relative to the scan window.
12. **`simulations` parameter is a lie:** cron sends 10,000, route default 100,000, DB clamps to
    exactly 100,000 (`.clamp(100000, 100000)`, `:7014-7016`). Three layers disagree; the clamp
    wins. Dead config surface.
13. **`schema_version` unused** — no ordered-migration framework; correctness relies on the file
    running identically top-to-bottom on every boot.
14. **`football_matches` is shallow (6 weeks).** Anything wanting real history must use the
    disjoint `historical_twin_matches` / `historical_elo_ratings` datasets, which are **not keyed
    to `football_matches.id`** and only 22% name-matched to `football_leagues`.
15. **Contradiction:** `phoenix_match_learning_flags` is described as the per-fixture eligibility
    ledger but only stores `eligible=true` rows — exclusions are recomputed on the fly in
    `modelLabRawDataset`, so there is no persistent "why was this match excluded from learning"
    record (the spec §49 audit explicitly wants this).

---

## Open questions for the rebuild plan

1. **Learning Dataset Pipeline home.** Add a real `phoenix_learning_dataset` table (per
   fixture×market, with `data_class` Production/Learning/Research/Quarantine, feature-completeness,
   leakage-check result, exclusion reason) and route `modelLabRawDataset()` + the Global Engine +
   per-league challengers through it, instead of inline tier/DQ SQL filters. Persist ineligible
   rows.
2. **History depth.** Is the plan to keep `football_matches` as a rolling 6-week window and treat
   `historical_twin_matches` as the training corpus, or to backfill `football_matches` (and
   `football_engine_inputs`) years deep? The engine currently cannot train on its own snapshot
   table — only ~1,388 fixtures have a pre-match snapshot.
3. **Job infrastructure.** Consolidate the 3 job families onto one lease/heartbeat/reclaim
   primitive? Move the long learning run off the web/deploy path (dedicated worker service that
   doesn't redeploy on every backend push)?
4. **Per-league challengers.** All 187 models are global. Spec §5-8 wants ≥3 challengers per
   whitelist league. The schema supports it (`league_id` column, per-scope champion index) — is
   the plan to generate them in the next learning run, and what's the compute/API budget for
   evaluating ~46 leagues × 17 markets × N challengers on walk-forward?
5. **API quota governance.** Confirm the actual plan tier (Pro 7,500 vs Ultra 75,000). Add a
   proactive daily budget with reservation (extend `consumeApiSportsRequest` to the main client,
   raise the `clamp(1,100)` ceiling), and a per-run cost estimate before a learning/enrichment
   pass starts.
6. **Tier budgets.** Decide a coherent daily budget: how many data_pool leagues does PHÖNIX
   actually want history for, and set Phase-1 limit = enrichment `maxFixtures` = SQL LIMIT to one
   number derived from that.
7. **Scheduled cron reality.** Is a model-lab Railway cron service actually configured? If not,
   the weekly/monthly cadence needs to be set up (or moved in-process with a guard).
8. **Monthly review / promotion.** Never executed. Before any Global Engine goes live under the
   new architecture, the promotion path (`monthly_review_service.dart`, `PHOENIX_MODEL_PROMOTION_
   ENABLED`) needs a first real end-to-end run.
9. **Drop the orphan/dead tables** (`football_final_tips`, `football_ai_context_jobs`, and the
   5 zero-row dead tables) as part of the rebuild, or formally revive the features.
10. **`football_matches` vs learning tier.** Phase 1 only writes 100 non-focus fixtures/run and
    Phase-2/enrichment only snapshots a subset — a rebuild that wants "learn from watchlist +
    data_pool" (spec §28-30) needs the ingestion budget to actually reach those fixtures first.
