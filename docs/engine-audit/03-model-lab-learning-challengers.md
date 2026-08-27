# 03 – Model Lab: learning, challengers, evaluation, promotion

Audit date: 2026-08-27. Scope: `lib/src/model_lab/**`, `lib/src/config/model_lab_config.dart`,
`lib/src/api/model_lab_routes.dart`, `bin/phoenix_model_lab_*.dart`, `test/model_lab/**`.
Read-only. Prod facts pulled via `bin/phoenix_model_lab_status_check.dart` and the admin API.

---

## TL;DR

- **The learning run works end-to-end and is leakage-careful, but it is not really a
  learning system.** No model is fitted to the training split except `TEAM_STRENGTH_IPF_V1`.
  Every other "challenger" is a fixed, pre-declared parameter (attackWeight grid point,
  Dixon-Coles `rho`, a named weight-scaling hypothesis). "Walk-forward" is nominal: the
  `steps` list is computed (`walk_forward_evaluator.dart:56`) and then **never used** for
  scoring — validation/holdout are each scored in one shot.
- **Everything is global (pooled, `league_id = null`) today.** Per-league challenger creation
  is coded (`learning_run_service.dart:354-872`) but produces ~nothing: run #15 processed
  1233 leagues and created 68 challengers, *all* pooled-global. Prod has 9 open challengers
  per market, every one `league_id = null`. Only 153 learning candidates in the last 30 days,
  all under the `null` bucket.
- **The current global champions (`GLOBAL_1X2_V1` … `GLOBAL_TEAM_GOALS_V1`, all `V2`) were
  never evaluated.** They were hand-activated as fixed weight presets via
  `activateGlobalMarketChampion` (`model_registry_service.dart:378`), `train=0 val=0 holdout=0`.
  They are the incumbents that every challenger is measured against.
- **On run #15 no challenger beat the champion.** Sampled evaluations: DC/TS challengers show
  `championBetter` on walk-forward and `approximatelyEqual` on holdout; nothing `challengerBetter`.
  Matches the AN2 rule "if a challenger is not better, do not deploy it" — the system is
  honouring that, it just has no winner.
- **Promotion is fully stubbed off.** `PHOENIX_MODEL_PROMOTION_ENABLED` defaults `false`
  (`model_lab_config.dart:153`); the promote/rollback routes 403 and the monthly-review
  auto-promo path is gated on the same flag. **Zero monthly reviews have ever run.**
- **Metrics present:** Brier, log loss, accuracy, calibration buckets, paired bootstrap CI.
  **Missing vs AN2 §40:** ECE (single number), ROI/yield/CLV (no odds in the lab), stability
  across seasons/phases, max drawdown, confidence buckets as a decision input, explicit
  per-league breakdown of a global model (§39).
- **`walkForwardMinTrainingWindow: 60` vs `minValidationSample: 40`** means the pooled split
  is training=60 / validation=~400 / holdout=~116 (observed on run #15). Harmless for
  fixed-parameter challengers, structurally wrong for anything that actually trains.
- Dead/□ config: `minShadowSample` (declared, never read), `walkForwardStepSize` +
  `WalkForwardStep` (computed, only used by tests), `sampleSizeTier()` (only used by its own
  test). `redCardEarly/LateMinute` are effectively dead because red-card coverage is ~0, so
  `clean == all` in every persisted evaluation.

---

## Learning run: step by step (file:line)

Entry: `LearningRunService.run({triggerType})` — `learning_run_service.dart:52`.
Triggered weekly (Tue 04:00 Berlin) by `bin/phoenix_model_lab_cron.dart:47` →
`POST /api/admin/model-lab/learning-runs/start` (`model_lab_routes.dart:457`, fire-and-forget
`unawaited(service.run('manual'))`).

```
run()  learning_run_service.dart:52
 ├─ ensureGlobalBaseline(market) for all 17 markets       :62   (BEFORE the lock – idempotent)
 │     model_registry_service.dart:29 – creates attackWeight V1 baseline if none,
 │     auto-promotes it to champion if the market has no champion (:35, :80)
 ├─ acquireModelLabLock('learning_run', staleAfterMinutes=180)   :66
 │     if stale: recoverOrphanedLearningRunAndLock + retry once  :74-82
 │     else: return {status:'skipped'}                           :83
 ├─ reconcileOrphanedLearningRuns() → _resumeStateFrom()   :98,175
 │     resume only if the dead run died inside 'processing_league_markets' (:178)
 ├─ createLearningRun(triggerType) → runId                 :101
 ├─ audit-log 'learning_started'                           :102
 └─ _runSteps(runId, resumeState)                          :119 / :195
      1. auditEligibility()   learning_dataset_builder.dart:175   (step 'auditing_eligibility')
           over modelLabEligibilityAuditRows(); exclusion buckets:
           not_whitelisted (tier != focus|watchlist|data_pool) :211,
           outcome_missing :219, timestamp_invalid (snapshot !< kickoff) :225,
           data_quality_below_minimum (< config.minDataQuality=40) :233
      2. modelLabWhitelistedLeagues()                      :210   (step 'loading_whitelist')
      3. buildSamplesByLeague()  learning_dataset_builder.dart:41  (step 'loading_training_data')
           ONE leakage-safe scan (modelLabRawDataset, minDataQuality), grouped by league.
           Per row → FeatureWhitelist.extract() (:146) + phase-2 join (:65,_phaseTwoDataByFixture)
           Defensive re-check sample.hasValidSnapshotTiming (:114 / learning_sample.dart:71)
           Sorted by kickoff (:118).
      4. OUTER loop over LearningMarket.values (17 markets)   :292
         ├─ registry.ensureGlobalBaseline(market)             :298
         ├─ POOLED-GLOBAL challengers (league_id = null), run once per market,
         │  independent of the resume-skip and of the league loop:
         │    _ensurePooledGlobalGoalsV1Challenger      :313 / :924   (1 per market)
         │    _ensurePooledGlobalMarketChallengers      :320 / :1029  (4 named hypotheses)
         │    _ensurePooledDixonColesChallengers        :327 / :1146  (rho ∈ {-0.05,-0.10})
         │    _ensurePooledTeamStrengthChallenger       :334 / :1266  (halfLife ∈ {null,30d})
         │  Each: pool all league samples → ChronologicalSplit.split → gate
         │  validation<40 && holdout<40 (:950) → createOrReuse* → addLearningCandidate →
         │  _persistComparison(walk_forward on validation, holdout on holdout)  :990-1019
         └─ INNER loop over whitelisted leagues                :354
            skip fully-processed markets/leagues from resumeState   :345,359
            samples = samplesByLeague[leagueId]                     :371
            upsertMatchLearningFlag per (fixture,market)            :376
            leagueChampion = registry.currentChampion(leagueId,market)  :391
            classifyLeagueMarketStatus()  league_market_status.dart:19  :400
              if NOT_ENOUGH_DATA (<50) or GLOBAL_ONLY → continue    :416
            split = ChronologicalSplit.split(samples, config)       :421
              if validation<40 && holdout<40 → continue             :422
            baselineModel = leagueChampion ?? global champion ?? global baseline  :437
            championEngine = registry.modelEngine(baselineModel)    :444
            per-league challenger families (each own budget, own guard):
              GLOBAL_GOALS_V1  (1)   :458-530   (needs hasGlobalGoalsV1Data samples)
              GlobalMarket 4 hypotheses  :532-611 (needs hasGlobalMarketData samples)
              Dixon-Coles rho grid   :613-693   (gate perLeagueEngineMinSample=5, :622)
              TeamStrength halfLife grid  :695-798 (fit once per league via
                 footballSettledMatchesForLeague, must converge :725; gate 5, :731)
              attackWeight grid  :800-872
                 grid = ChallengerGenerator.candidateAttackWeights(config)  :800
                 remainingSlots = maxChallengers(6) - existingChallengers   :805
                 createOrReuseChallenger → shrunkTowardsGlobal(sampleSize,k=150)
            every family: addLearningCandidate + _persistComparison(walk_forward, holdout)
      5. finally per league: updateLearningRunProgress (heartbeat)  :880
 ← completeLearningRun(status:'completed', counts…)          :120
 ← audit-log 'learning_completed'; releaseModelLabLock       :131,166
```

`_persistComparison` (`:1584`) writes **two** `phoenix_model_evaluations` rows per side
(champion & challenger) × two `match_scope`s (`all`, `clean`), each with Brier, log loss,
calibration array, accuracy, avg top-prob, and the shared paired-bootstrap `uncertainty`.

**Shadow predictions and monthly review are NOT part of the learning run.** They run on
separate schedules:
- `ModelLabAutopilotService.run()` (`model_lab_autopilot_service.dart:22`) — daily via the
  same cron (`phoenix_model_lab_cron.dart:38`): `settlePendingShadowPredictions()` then
  `generatePendingShadowPredictions()` (`shadow_prediction_service.dart:326`, `:29`).
- `MonthlyReviewService.run()` (`monthly_review_service.dart:23`) — cron on Wednesday
  (`phoenix_model_lab_cron.dart:57`), real work only on the first Wednesday
  (`model_lab_schedule.dart:32`).

---

## Engine families table

| Family | Where | What it models | Free param | Wired into learning runs? | Honest result |
|---|---|---|---|---|---|
| **attackWeightBlend** (V0) | `engine_replica.dart:45` `EngineReplica`; `weight_config.dart` | λ_home = w·(own attack rate) + (1−w)·(opp conceded rate), from 4 whitelisted `raw.*` season goal averages only; independent-Poisson markets | `attackWeight` ∈ [0.20,0.80], grid `[0.20,0.35,0.45,0.55,0.65,0.80]` | **Yes** – `ChallengerGenerator.candidateAttackWeights` (`challenger_generator.dart:11`), `learning_run_service.dart:800`. Also the seed baseline (`model_registry_service.dart:45`). | No challenger ever promoted. Baseline (w=0.5) reproduces prod Monte-Carlo. Comment `weight_config.dart:171-179`: pre-2026-08-23 grid ±0.20/4pts "so narrow a challenger could barely produce a measurably different λ". |
| **GLOBAL_1X2_V1 / GLOBAL_TOTALS_V1 / GLOBAL_BTTS_V1 / GLOBAL_TEAM_GOALS_V1** | `global_market_engine.dart:30` `GlobalMarketFamily` + `GlobalMarketWeights.presets` (:125) | Weighted blend of *real* signals only: season attack/defense, last-5 form, standings goal rate, league goal context, H2H. xG / rating / motivation **deleted** (not in PHÖNIX) and remaining weights renormalised (`feature_renormalization.dart`). | none (fixed preset) | **As the champion, not as a candidate.** Activated by `activateGlobalMarketChampion` (`model_registry_service.dart:378`) via `POST /global-market-engines/activate` (`model_lab_routes.dart:354`). | **Never evaluated** – prod champions `#19…#39` all `V2`, `train=0 val=0 holdout=0`. Chosen by fiat, not by a backtest. |
| **GLOBAL_GOALS_V1** | `global_goals_v1_engine.dart:19` | Predecessor of the above: 6 fixed weights, no H2H. `shots`/`motivation` permanently 0 (`:40`). | none | **Yes** – pooled (`learning_run_service.dart:313`) + per-league (`:458`). One challenger per league×market (constant `configHash`). | Runs as a shadow challenger. No promotion. Needs a phase-2 team-id snapshot or `evaluate()` returns null (`engine_replica.dart:466`). |
| **DIXON_COLES_V1** | `dixon_coles_engine.dart:19` (just a version tag + `rhoCandidates`); math in `poisson_math.dart:40` `dixonColesTau` | Low-score correlation correction on the **same** λ as the global champion (attackWeight 0.5). `rho` shifts 0:0/1:0/0:1/1:1 only. | `rho` ∈ {−0.05, −0.10} | **Yes** – pooled (`:327`) + per-league (`:613`). | Run #15: `championBetter` on walk-forward, `approximatelyEqual` on holdout (models 189, 147, …). Commit `54ced7a` = "add as a new engine family (Phase 1 Spur A)". **Not deployed.** |
| **TEAM_STRENGTH_IPF_V1** | `team_strength_engine.dart:110` | Maher attack/defense/home-advantage ratings, fitted by damped IPF with empirical-Bayes shrinkage (`regularizationK=8`), optional exponential time-decay (`halfLifeDays`). λ = attack_h·defense_a·homeAdv, attack_a·defense_h. | half-life ∈ {null, 30 d}; fit is data-derived | **Yes** – pooled (`:334`, one fit per half-life for the whole run) + per-league (`:695`, one fit per league, reused across all 17 markets). Fit source: `footballSettledMatchesForLeague/ForLeagues`, **not** the whitelisted samples. Only added if `fit.converged` (`:725`). | Commit `7fe3edf`: *"honest result: not yet better than simple average"*. Backtest claim (code comments): Ø Brier −7.3% vs simple average on 9 leagues / 98 holdout. Run #15 pooled: `championBetter` on walk-forward, `approximatelyEqual` on holdout (models 190, 186, 182…). **Not deployed.** |
| bivariate Poisson / negative binomial (AN2 §15) | — | — | — | **No** – not implemented at all. |

Shared downstream math for all families: `PoissonMath.scoreMatrix` (`poisson_math.dart:68`),
one joint 13×13 score matrix per match, all markets derived from it (`engine_replica.dart:117`
`evaluateGoals`). This is the one place AN2 §4/§9-§13 ("one match engine, derive markets
after") is actually honoured.

---

## Global vs per-league today

- **Design (AN2 §4-§7, §30-§31):** global engine is champion everywhere; per-league
  challengers specialise and only replace the global model *for their own league* once
  proven better.
- **Reality:**
  - Champions are **market-level only** (`league_id = null`). There is no per-league champion
    anywhere in prod. `currentChampion(leagueId, market)` falls back to the global one
    (`model_registry_service.dart:104` `productionChampion`).
  - Per-league challenger creation exists but is starved: run #15 processed **1233 leagues**,
    created **68 challengers**, **all `league_id = null`**. `phoenix_learning_candidates` in
    the last 30 days: **153 rows, all `league_id = null`**.
  - Root cause: ~554 eligible leakage-safe matches (run #15) spread over 1233 leagues → no
    single league clears `minLearningEligibleSamples = 50`, let alone the split gate. Commit
    history: `c367b7b` "lower per-league sample gate", then `75580a1` "add pooled global
    Dixon-Coles / Team-Strength challengers alongside the per-league ones" — the pooled path
    was bolted on precisely because the per-league path produced 0 over 4 runs.
  - `perLeagueEngineMinSample = 5` (`learning_run_service.dart:50`) is a *creation* gate for
    DC/TS only; promotion still needs `minPromotionSample = 120`.
- **Net:** the two-level architecture is present in code shape only. Operationally PHÖNIX has
  one pooled global model per market and a bag of pooled global challengers, none winning.

---

## Challenger generation vs AN2 §8

AN2 §8 / §32: *"do not generate 20 near-identical engines; every challenger needs a
justified hypothesis."* AN2 §9: *one match engine, not one engine per market.*

- **Grid search (blind):**
  - attackWeight: 6-point grid, capped at `maxChallengersPerLeagueMarket = 6`
    (`challenger_generator.dart:11`). One scalar knob, no hypothesis attached to each point.
  - Dixon-Coles: 2-point `rho` grid. Half-defensible (literature values, comment
    `dixon_coles_engine.dart:24`) but still a grid.
  - TeamStrength half-life: 2-point grid ({no decay, 30 d}) — comment frames it as a
    control + one hypothesis (`learning_run_service.dart:255-263`).
- **Hypothesis-driven:** `GlobalMarketHypothesis` (`global_market_engine.dart:191`) — 4 named,
  documented variants (`form_heavy`, `season_heavy`, `balanced`, `attack_defense_heavy`),
  each a relative re-scaling of the real-feature preset. This *does* satisfy §8/§32 in spirit.
- **Verdict:** partial. The GlobalMarket hypotheses are justified; the attackWeight and DC
  grids are not. Total families per league×market can reach ~15 candidates (6 grid + 1 GG1 +
  4 GM + 2 DC + 2 TS), which brushes against the "don't spam near-identical engines" rule —
  the `maxChallengersPerLeagueMarket` cap only limits the attackWeight family, the others
  each carry an independent budget (`learning_run_service.dart:537`, `:620`, `:704`).
- **§9 (one match engine):** honoured at the math layer (single score matrix) but **not** at
  the model-registry layer — the Model Lab still versions a separate champion per
  `LearningMarket` (17 of them: `learning_market.dart:9`), and `GlobalMarketFamily.forMarket`
  maps 17 markets onto 4 weight profiles. There is no single "match model" row; there are 4
  weight presets and 17 champion rows.

---

## Leakage safety

Mechanisms, strongest first:

1. **SQL prefilter** `modelLabRawDataset` / `modelLabEligibilityAuditRows` — only settled
   matches with a pre-match snapshot; `timestamp_invalid` bucket counts
   `snapshot_created_at !< kickoff` (`learning_dataset_builder.dart:225`).
2. **Defensive re-check in code:** `LearningSample.hasValidSnapshotTiming`
   (`learning_sample.dart:71`), enforced again in `_samplesFromRows`
   (`learning_dataset_builder.dart:114`) — "belt and braces".
3. **Positive feature whitelist:** `FeatureWhitelist.allowedPaths` (`feature_whitelist.dart:20`)
   — only 13 explicit paths; any new/unknown `normalized_input` field is dropped. AI/Gemini
   fields explicitly blocked (`:41`) and regression-tested (`no_ai_isolation_test.dart`).
4. **Chronological split:** `ChronologicalSplit.split` (`walk_forward_evaluator.dart:29`) —
   holdout = newest `holdoutFraction` (20%), taken before training/validation are carved out;
   holdout never enters candidate search.
5. **Structural isolation tests:** `no_ai_isolation_test.dart` asserts no model_lab file
   imports a generative-AI service or the Historical Twins service (AN2 §5/§17).
6. **TeamStrength fit boundary:** `_teamStrengthTrainingDataFor` / `_pooledTeamStrengthTrainingData`
   use `boundary = evaluatedSamples.first.kickoff` and keep only `kickoff < boundary`
   (`learning_run_service.dart:1420`, `:1512`) — the fit sees neither validation nor holdout.

**Residual risks / gaps:**

- **Phase-2 snapshot timing is not re-verified in code.** `_phaseTwoDataByFixture`
  (`learning_dataset_builder.dart:65`) joins `modelLabGlobalGoalsV1Dataset` rows by
  `fixture_id` with **no** `snapshot_created_at < kickoff` check — it trusts the SQL. The
  attackWeight path has the redundant guard (#2); the GlobalMarket / GG1 / TeamStrength path
  does not. If `modelLabGlobalGoalsV1Dataset` ever returns a post-kickoff availability row,
  it leaks silently. (SQL not audited here — flag for the DB pass.)
- **Standings data inside the availability snapshot** (`global_market_engine.dart:260`
  `_flattenStandings`): the *table* is read from the pre-match snapshot, but if that snapshot
  was captured late (e.g. same-day) the standings already include neighbouring results. No
  freshness bound beyond "before kickoff".
- **`ChronologicalSplit` "walk-forward" is not walk-forward.** `steps` is computed and
  discarded (`walk_forward_evaluator.dart:56`, unused outside tests). Validation is scored as
  one block. No look-ahead *within* validation is possible because challengers are fixed, but
  the label oversells what happens.
- **Backfill path** `backfillHistoricalShadowPredictions` (`shadow_prediction_service.dart:244`)
  reuses `LearningDatasetBuilder.buildSamples()` so it inherits the same guards — good.

No hard leak found in the attackWeight/DC path. The phase-2 path is one thin SQL layer away
from a leak and should get the same in-code guard.

---

## Promotion rules & rollback vs AN2 §42-44

**Where promotion can happen (all gated on `promotionEnabled`, default `false`):**

| Path | File | Guard |
|---|---|---|
| Monthly-review auto-promo | `monthly_review_service.dart:285` | `recommendation == 'PROMOTION_EMPFOHLEN' && config.promotionEnabled` |
| Manual `POST /models/<id>/promote` | `model_lab_routes.dart:788` | `if (!promotionEnabled) → 403` + audit `promotion_rejected` |
| Manual `POST /models/<id>/rollback` | `model_lab_routes.dart:846` | same 403 |
| `activateGlobalMarketChampion` | `model_registry_service.dart:378` / route `:354` | **NOT gated** – bypasses `promotionEnabled`, calls `promoteModel` directly. This is how the current champions were set. |

**Monthly-review decision logic** (`_reviewLeagueMarket`, `monthly_review_service.dart:117`):

- Recomputes holdout fresh (`ChronologicalSplit.split` of current samples, `:153`).
- Combines **holdout Brier diffs + paired settled shadow Brier diffs** into one difference
  vector (`:179`), then `Metrics.pairedBootstrap` (`:187`).
- Picks the challenger with the most-negative mean diff (`:206`).
- Gate 1: `combinedSample < minPromotionSample (120)` → `NICHT_GENUG_DATEN` (`:240`).
- Gate 2: bootstrap status → `challengerClearlyBetter` ⇒ `PROMOTION_EMPFOHLEN`,
  `approximatelyEqual` ⇒ `WEITER_TESTEN`, `championBetter` ⇒ `CHALLENGER_SCHLECHTER` (`:245`).
- `challengerClearlyBetter` means the **entire 95% CI of the mean loss difference is < 0**
  (`metrics.dart:139`) — this is the "lucky weekend" guard (AN2 §42-43): a single strong
  window cannot move a 2000-resample paired CI across zero at n ≥ 120.

**Coverage vs AN2 §42:**

| §42 requirement | Status |
|---|---|
| sufficient sample | ✅ `minPromotionSample = 120` combined |
| better calibration | ⚠️ calibration buckets are computed & stored but **not a gate** — only mean Brier drives the decision |
| better probabilistic metrics | ✅ (Brier, via bootstrap) |
| stable results | ⚠️ partial — holdout + shadow combined, but no explicit multi-period / season-phase stability test (§38) |
| no severe regression in a core market | ❌ not checked — decision is per league×market in isolation, no cross-market veto |
| out-of-sample confirmation | ✅ holdout + live shadow both out-of-sample |
| no data leakage / no technical anomaly | ⚠️ implicit (relies on the pipeline), no automated anomaly gate |

**Rollback & versioning (§44):**

- `promoteModel` (`database.dart:7683`): retires previous champion (`status='retired'`,
  never deleted), sets `champion_since`, `last_promotion_at`, `previous_champion_id`.
- `rollbackModel` (`database.dart:7718`): retires current, re-champions target, sets
  `rollback_model_id`. Route gated on `promotionEnabled` (so currently unusable).
- Model rows are immutable (`config_hash` unique index, `model_registry_service.dart:14`) and
  store `feature_config`, `weights`, `training_start/end`, `training/validation/holdout_count`,
  `code_schema_version` (`weight_config.dart:78`). Training *dataset* itself is not snapshotted
  — only its date range and counts. AN2 §44 wants "training dataset" versioned; today you get
  a reproducible pointer, not the data.

**Stubbed / missing:**

- **Monthly-cron AUDIT-XXX report (AN2's audited monthly report): does not exist.**
  `phoenix_monthly_reviews` has **0 rows** in prod. The cron calls the endpoint but the
  first-Wednesday gate + zero eligible league-champions means it is a no-op.
- Old-engine archive with the §45 fields (name/version/architecture/active-period/markets/
  leagues/metrics/replacement-reason/config): partially covered by `status='retired'` +
  `feature_config`, but there is no dedicated archive view or the "replacement reason" field.
- Shadow-mode gating of a "new challenger" before it can be reviewed (§36): the *previous*
  champion keeps producing shadows (`shadow_prediction_service.dart:64-76`) but there is no
  minimum shadow-duration gate — `minShadowSample` is declared and never read.

---

## Metrics: have / missing

`metrics.dart` + `walk_forward_evaluator.dart`:

| AN2 §40 metric | Present? | Where |
|---|---|---|
| Brier (multi-class + binary) | ✅ | `metrics.dart:14`, `:28` |
| Log loss | ✅ | `metrics.dart:38`, `:47` |
| Calibration (reliability buckets) | ✅ | `metrics.dart:60`, edges `[.50,.55,.60,.65,.70,.80,1.0001]`, min 20/bucket |
| Expected Calibration Error (single number) | ❌ | buckets only, never aggregated to ECE |
| ROI | ❌ | no odds in the lab (route comment `model_lab_routes.dart:576` "a ROI would be invented") |
| Yield | ❌ | — |
| CLV | ❌ | closing odds not stored / not used |
| Sample size | ✅ | everywhere |
| Stability (across seasons / season phases) | ❌ | §38 not implemented; single holdout block |
| Max drawdown | ❌ | — |
| Confidence buckets | ⚠️ | calibration buckets exist; not used as a promotion input or reported per-bucket over time |
| Market-specific performance | ✅ | every eval row is per `market` |
| Per-league breakdown of a global model (§39) | ❌ | pooled global evals are league-agnostic; a bad single league is invisible |
| Paired uncertainty / bootstrap CI | ✅ (beyond §40) | `metrics.dart:94` |
| Accuracy / hit-rate | ✅ but correctly *not* a decision metric (AN2 §41) | `walk_forward_evaluator.dart:182` |

Also: `match_scope='clean'` (exclude early-red-card games) is stored but is **always equal to
`all`** in practice — `earliestRedCardMinute` is populated only for user-favourited fixtures,
so `distortionLevel` returns `null` → `isClean` true for ~every sample
(`learning_sample.dart:126-138`).

---

## Config knobs (`lib/src/config/model_lab_config.dart`)

| Knob | ENV | Default | Gates | Notes / flags |
|---|---|---|---|---|
| `promotionEnabled` | `PHOENIX_MODEL_PROMOTION_ENABLED` | `false` | ALL promotion & rollback (except `activateGlobalMarketChampion`) | Correct default; but `activate` bypasses it. |
| `minDataQuality` | `…_MIN_DATA_QUALITY` | `40` | sample eligibility | Lowered 50→40 on 2026-08-27 (comment `:155`). Run #15: 201 matches excluded here. |
| `minLearningEligibleSamples` | `…_MIN_ELIGIBLE_SAMPLES` | `50` | league×market becomes a candidate | Effectively never met per-league (pooled path added to route around it). |
| `leagueAdaptationSampleThreshold` | `…_LEAGUE_ADAPTATION_THRESHOLD` | `100` | `GLOBAL_ONLY` vs `LEAGUE_ADAPTATION` status | display/status only. |
| `strongerAdaptationSampleThreshold` | `…_STRONGER_ADAPTATION_THRESHOLD` | `300` | `sampleSizeTier()` label | **`sampleSizeTier` only used by its own test — dead.** |
| `fullLeagueEngineSampleThreshold` | `…_FULL_LEAGUE_ENGINE_THRESHOLD` | `600` | same | dead (see above). |
| `shrinkageK` | `…_SHRINKAGE_K` | `150` | `EngineWeightConfig.shrunkTowardsGlobal` (attackWeight only) | With pooled n≈500 → factor ≈ 0.77, i.e. challengers keep ~77% of their grid offset. Only affects attackWeightBlend. |
| `attackWeightMin` / `Max` | `…_ATTACK_WEIGHT_MIN/MAX` | `0.20` / `0.80` | grid clamp | Widened from ±0.20 on 2026-08-23 (`weight_config.dart:171`). |
| `attackWeightGrid` | `…_ATTACK_WEIGHT_GRID` | `[.20,.35,.45,.55,.65,.80]` | attackWeight candidates | 6 points = `maxChallengersPerLeagueMarket`, so all 6 always used. |
| `holdoutFraction` | `…_HOLDOUT_FRACTION` | `0.20` | `ChronologicalSplit` holdout size | Run #15 pooled: holdout n≈116. |
| `walkForwardMinTrainingWindow` | `…_WALK_FORWARD_MIN_TRAINING` | `60` | `training` slice size | **Mis-tuned/misleading**: with pooled dev ≈ 516 → training=60, validation≈400 (observed). Only cosmetic today (nothing trains on `split.training`); would be wrong for a real trainer. |
| `walkForwardStepSize` | `…_WALK_FORWARD_STEP` | `20` | `WalkForwardStep` list | **Dead outside tests** — steps never scored. |
| `minHoldoutSample` | `…_MIN_HOLDOUT_SAMPLE` | `40` | challenger-creation split gate (`||` with validation) | |
| `minValidationSample` | `…_MIN_VALIDATION_SAMPLE` | `40` | split gate **and** `pairedBootstrap.minSampleSize` in the learning run (`walk_forward_evaluator.dart:309`) | Below 40 diffs ⇒ `notEnoughData`. |
| `minShadowSample` | `…_MIN_SHADOW_SAMPLE` | `30` | — | **Declared, never referenced.** Dead. |
| `minPromotionSample` | `…_MIN_PROMOTION_SAMPLE` | `120` | monthly-review combined holdout+shadow gate | The real promotion sample gate. |
| `bootstrapResamples` | `…_BOOTSTRAP_RESAMPLES` | `2000` | paired bootstrap | |
| `bootstrapConfidenceLevel` | `…_BOOTSTRAP_CONFIDENCE` | `0.95` | CI width → status thresholds | |
| `calibrationMinBucketSample` | `…_CALIBRATION_MIN_BUCKET` | `20` | hide small calibration buckets | |
| `redCardEarlyMinute` / `LateMinute` | `…_RED_CARD_EARLY/LATE_MINUTE` | `30` / `75` | `distortionLevel` → `clean` scope | Effectively dead (red-card coverage ≈ 0). |
| `learningRunWeekday` / `learningRunHourBerlin` | `…_LEARNING_WEEKDAY/HOUR_BERLIN` | Tue / `4` | cron day (server also re-checks) | Cron actually starts daily; only Tue triggers the run. |
| `monthlyReviewWeekday` / `monthlyReviewMaxDayOfMonth` | `…_MONTHLY_REVIEW_WEEKDAY/MAX_DAY` | Wed / `7` | first-Wednesday gate | |
| `maxChallengersPerLeagueMarket` | `…_MAX_CHALLENGERS` | `6` | attackWeight grid budget **only** | Does not cap DC/TS/GG1/GM families — each has its own budget. |
| `staleLockMinutes` | `…_STALE_LOCK_MINUTES` | `180` | orphan-lock reclaim | Runs #6-#14 mostly "failed (orphaned)" — lock churn from redeploys mid-run is a real operational problem. |

---

## Half-built / dead / contradictory

- **Runs #6–#14 (9 of last 10) are `failed (orphaned)`** with `challengers_created: 0` /
  low `markets_processed`. Only #9 and #15 completed. The run takes >11 h (#15:
  22:56 → 10:15) over 1233 leagues × 17 markets and is regularly killed by a redeploy before
  it finishes. The resume logic (`_resumeStateFrom`, `:175`) mitigates but the run is far too
  long for a fire-and-forget HTTP-triggered job.
- **"Walk-forward" is a misnomer** — `WalkForwardStep` / `steps` / `walkForwardStepSize`
  computed and never used for scoring (`walk_forward_evaluator.dart:56`).
- **`minShadowSample`** declared, never read. **`sampleSizeTier()`** only used by its test.
- **`match_scope='clean'` == `'all'`** in every persisted row (red-card coverage ≈ 0) — two
  DB rows per side that carry identical numbers.
- **Two overlapping "global engine" generations coexist:** `GlobalGoalsV1Engine` (6 weights,
  no H2H, still generated as a challenger) and `GlobalMarketEngine` (parametrised, +H2H, now
  the champion). Comments say GG1 is kept "never silently change a model" — fine — but the
  learning run now generates *both* a GG1 challenger and 4 GM-hypothesis challengers per
  league×market against a GM champion, i.e. GG1 competes against its own successor.
- **`ensureGlobalBaseline` vs `activateGlobalMarketChampion` contradiction:** the learning run
  re-creates an attackWeight `V1` baseline for every market on every run (`:62`, `:298`) and
  auto-promotes it if no champion exists (`model_registry_service.dart:35`), while the live
  champions are `GLOBAL_*_V1 V2`. `productionChampion` has a comment (`:112`) warning that
  `globalBaselineModel` returns the *oldest* `global_baseline` row regardless of status — a
  latent footgun if a champion is ever missing.
- **Per-league challenger path is effectively dead code in prod** (0 rows) yet fully
  maintained — ~500 lines of `learning_run_service.dart` that never fire.
- **Shadow predictions for non-attackWeight models were silently wrong until 2026-08-25**
  (`shadow_prediction_service.dart:93-102`): any model with an `engineVersion` tag was
  skipped in pass 1 to avoid a false attackWeight=0.5 fallback; pass 2 (`:134`) was added to
  handle them. Live acquisition of the phase-2 snapshot for upcoming fixtures is described as
  "noch nicht angebunden" (`:93`) — so GG1/GM shadow coverage depends on that pipeline
  existing.
- **`draw_no_bet_*` treated as 3-class [won, push, lost]** (`learning_sample.dart:110`) —
  prod Brier ≈ 0.63–0.68 (models 189/190), essentially random for a 3-class one-hot. Either
  the market encoding or the engine is not doing anything useful for DNB.
- **`activateGlobalMarketChampion` bypasses `promotionEnabled`** and is a plain `unawaited`
  loop over 17 markets in the route (`model_lab_routes.dart:372`) — no lock, no audit gate
  beyond the per-market audit-log row.

---

## Open questions for the rebuild plan

1. **One match engine vs 17 market champions.** AN2 §9 wants a single match model. Do we
   collapse `LearningMarket` (17) → one `MatchModel` row per (scope) with markets derived, or
   keep per-market champions? Current `GlobalMarketFamily` (4 profiles) is a halfway house.
2. **Is per-league specialisation viable at all with today's data?** 554 eligible matches /
   1233 leagues. Which whitelist leagues actually have ≥ `fullLeagueEngineSampleThreshold`
   (600) leakage-safe matches *with pre-match snapshots*? If none, §5-§7 are aspirational and
   the plan should say so.
3. **Fix or delete "walk-forward".** Either implement real expanding-window scoring using the
   already-computed `steps`, or rename to "chronological holdout" and drop `walkForwardStepSize`.
4. **`walkForwardMinTrainingWindow = 60`** — set to a fraction of dev set, not an absolute,
   before any engine actually trains on `split.training`.
5. **Champion legitimacy.** The live `GLOBAL_*_V1 V2` champions were never backtested. Should
   the rebuild require every champion (incl. the initial global one) to pass holdout before
   `champion` status, i.e. remove the "activate by fiat" path?
6. **Calibration as a gate.** AN2 §42 lists calibration explicitly; today only mean Brier
   decides. Add ECE + a "calibration must not worsen" veto?
7. **Per-league evaluation of the global model** (§39) — pooled evals hide a catastrophic
   single league. Need per-league Brier/calibration slices even for `league_id = null` models.
8. **Run duration & reliability.** An 11-hour fire-and-forget run that redeploys kill 9 times
   in 10 is not operable. Chunk it (per-market job?), make it a real background job with a
   job table like Settlement, or drastically cut the league fan-out.
9. **Monthly review has never produced a row.** Is the first-Wednesday + per-league-champion
   gating right, or should the review operate on the pooled global champions that actually
   exist? The §48-52 audited monthly report needs to be built, not just scheduled.
10. **Phase-2 snapshot leakage guard.** Add the in-code `snapshot_created_at < kickoff`
    re-check to the GG1/GlobalMarket/TeamStrength sample path (parity with the attackWeight
    path) and bound standings-snapshot freshness.
11. **Odds in the lab.** Without stored (closing) odds there is no ROI/yield/CLV and no
    value-bet evaluation — AN2 §40 wants them. Decide whether the lab ingests odds snapshots.
12. **Shadow-duration gate.** Wire `minShadowSample` (or delete it) and define a minimum
    shadow *time* window before a challenger is review-eligible (§36).
13. **Drop or justify the blind grids.** attackWeight 6-grid and DC 2-grid have no
    per-candidate hypothesis (violates §8). Keep only hypothesis-tagged challengers?
