# 01 – Live Production Analysis + Tip Pipeline (end-to-end audit)

Repo: `phoenix_backend` (Dart / shelf). Scope: the code path that produces the tips the Flutter app
shows today. Read-only audit. All line refs are `path:line` relative to repo root.
Date of audit: 2026-08-27. Head commit `1673ee5`.

---

## TL;DR

- **"The model" today = two Poisson means (λ_home, λ_away) fed into a 100k-draw Monte-Carlo.**
  There is no team-strength vector, no tempo, no uncertainty object, no calibration in the live path.
  λ is a plain average of *own scored rate* and *opponent conceded rate*
  (`football_engine_input_service.dart:115-116`), shrunk toward a league-aware baseline for thin samples.
- **All markets DO come from one shared score distribution.** 1X2, BTTS, O/U 2.5 and ~30 derived
  markets (DC, DNB, team goals, European handicap, score-combos) are all counted from the same
  MC loop (`football_simulation_service.dart:134-206`). This already matches AN2 §9–13 at the
  *simulation* level — but the shared object is only `{λ_home, λ_away}`, not the rich
  "Match-State" AN2 §11 asks for, and DC/DNB are the only markets flagged as "derived".
- **xG/xGA is never available.** `coverageForFixture` hard-codes `realXgAvailable = false`
  (`football_service.dart:379-380`). Every downstream "if realXg" branch is dead in production.
- **Lineups are never fetched** — hard-coded empty (`football_service.dart:363-365`).
  Injuries are fetched only as a yes/no coverage flag; they never move λ.
- **The Gemini / AI-context step is permanently unwired.** `contextApplied` is structurally always
  `false`; `homeGoalDelta/awayGoalDelta` are always 0 (`football_engine_input_service.dart:174-187`).
- **The AN.txt "identical probabilities" bug is *mostly* fixed, not fully.** The 0-games→0.0-goals
  artefact and the single universal 1.35/1.10 fallback are fixed. But any match where both goal
  rates are missing still lands on `safe_baseline_fallback` → **identical λ for every such match in
  the same league → identical probabilities**, and that analysis is still published.
- **The AN.txt "tip despite 0 sims / stability 0" bug is fixed at the data level but re-opened at the
  UX level by design.** `football_v1_mc100k` and the `stability` field are gone; sims are always
  ≥1000 and the pipeline hard-fails if 0. But the 2026-08-26 "every match must have a tip" change
  makes `showPhoenixTip:true` and `recommendation` unconditional whenever any core market clears
  50% — independent of `qualifiesForTip` (the real gate: sims>0 ∧ dataQuality≥60 ∧ trust≥60).
- **`data_quality` only gates tips at *read time*** (`football_analysis_api.dart:36-39,143`:
  `>=60` today / `>=50` past). The nightly pipeline stores everything (`minimumDataQuality=0`).
  It does not influence λ, confidence weighting, or the value threshold.
- **Dead / contradictory code in the live tree:** `FootballFinalizationService`
  (`phoenix_full_v1`, reads `simulation['stability']` / `['phaseFour']` / `['topScores']` that the
  current simulator never emits) is still wired to `POST /api/admin/football/finalize`
  (`routes.dart:1132-1152`) but is **not** part of the nightly cron. `_decide()` in phase one is
  `// ignore: unused_element`.
- **`normalized.*Strength` fields are computed and stored but never consumed.** Simulation reads
  only `goalRateExpectedHome/Away`. They also use inconsistent hard-coded baselines
  (1.35 / 1.15 / 1.35, `football_engine_input_service.dart:218-221`).

---

## Pipeline (step by step, file:line)

### 0. Orchestration
- `bin/phoenix_daily_cron.dart` runs on Railway cron. Skips unless Berlin-time hour == 0
  (`:23`) unless `PHOENIX_CRON_FORCE_RUN`.
- Order: settle last 3 (or 9) days of tips (`:50-69`) → sync league catalog (`:75`) →
  `POST /api/admin/football/daily-scan` (`:83`, `_startDailyScan:196`) → poll job to terminal
  state (`:93`, `_waitForCompletion:236`) → `POST /api/admin/football/matches/settle` (`:107`).
- Config defaults (`_CronConfig.fromEnvironment:363-399`): `limit=1000`,
  **`minimumDataQuality=0`** (store everything), `simulations=10000` (clamped 1000–100000).
- Route `routes.dart:2051` creates a job row and runs `FootballDailyPipelineService(...).run(...)`
  (`routes.dart:2100`) in the background.

### 1. Phase 1 scan — `football_phase_one_scan_service.dart`
- `run()` pulls the whole global fixture list for the date (`football.matchesForDate`,
  `football_service.dart:63`), upserts every non-blocked league into the data pool.
- Only leagues at `FootballLeagueTier.focus` are eligible for public analysis
  (`:103-109`); everything else is tagged `background_*` for shadow/learning only.
- `_decideWhitelisted()` (`:372`) is the active gate: needs fixture id + both teams, status `NS`,
  kickoff in the future, not friendly (`_isFriendly:441`), not youth (`_isYouthCompetition:451`).
- `_decide()` (`:198`) is the richer historical gate — **unused** (`// ignore: unused_element`).

### 2. Phase 2 coverage / data-quality — `football_phase_two_scan_service.dart`
- `prepare()` takes eligible phase-1 fixtures, creates a phase-2 scan run.
- `processPrepared()` calls `football.coverageForFixture` per fixture
  (`football_service.dart:174`), which fires provider calls for: standings, home last-5,
  away last-5, odds (flag only), injuries (flag only), **lineups (hard-coded false, `:363-365`)**,
  h2h, home team statistics, away team statistics. `realXgAvailable` hard-coded `false` (`:379`).
- Team statistics: if current season has <3 played, it retries previous season and uses whichever
  has more games (`football_service.dart:251-273`).
- `goalAverageIfPlayed()` (`football_service.dart:56-61`): returns `null` (not `0.0`) when a
  split has 0 games — the AN.txt "0 away games ≠ 0.0 goals" fix.
- `_sanitizeAvailability()` (`:85`): team stats are "usable" only if present **and** ≥3 games;
  otherwise all `*GoalsFor/AgainstAverage*` and `*Form` keys are deleted (`:97-110`).
- `_quality()` (`:112-136`): additive score, base 5 + standings 15 + form ≤6+6 + odds 15 +
  injuries 10 + h2h 10 + homeStats 12 + awayStats 12 + realXg 5 − 5 if both teams 0 games.
  → **`data_quality` can exceed 60 with zero usable goal averages** (e.g. 15+15+10+10+12 = 62).
- Row saved with `analysis_allowed = data_quality >= minimumDataQuality` (0 in prod → always true
  for focus fixtures).

### 3. Engine input (λ construction) — `football_engine_input_service.dart`
`modelVersion = goal_rate_normalization_v6_league_aware_baseline` (`:13`).
Per fixture, `_normalize()` (`:100`):
1. Read 4 raw split rates from availability: `homeGoalsForAverageHome`,
   `homeGoalsAgainstAverageHome`, `awayGoalsForAverageAway`, `awayGoalsAgainstAverageAway`
   (`:110-113`).
2. `calculatedHome = mean(homeFor, awayAgainst)`, `calculatedAway = mean(awayFor, homeAgainst)`
   (`_averageAvailable:315`). If only one side present, use it; if both missing → `null`.
3. `usesFallback = calculatedHome==null || calculatedAway==null` (`:117`).
4. League-aware baseline (`leagueAwareBaseline:299`): global 1.35 / 1.10 shrunk toward this
   league's 400-day rolling avg goals (`footballLeagueGoalContextBatch`, `database.dart:6552`,
   shrink k = 50). No league history → exactly 1.35 / 1.10.
5. Sample size = `min(homePlayedHome, awayPlayedAway)` (`:156-160`).
6. `_shrinkTowardsBaseline(calculated ?? leagueBaseline, baseline=leagueBaseline, n)` with
   factor `n/(n+8)` (`shrinkGoalRateTowardsBaseline:273`). Thin sample (`n<8`) is pulled toward
   the league baseline; `usesFallback` → result **is** the league baseline exactly.
7. AI-context deltas: gated on `context['applied']==true && contextSource=='current_scan'`
   which is never true → `homeDelta = awayDelta = 0` (`:174-187`).
8. `expectedHome/Away = (base + delta).clamp(0.20, 3.80)` (`:186-187`).
9. `sourceType` ∈ {`safe_baseline_fallback`, `goal_rates_not_xg_thin_sample_shrunk`,
   `goal_rates_not_xg`} (`:205-209`). Also emits unused `normalized.*Strength` (`:218-221`),
   `sampleSize`, `leagueBaseline*`, `warnings` (`:245-250`).
Stored to `football_engine_inputs` (`database.dart:4678`).

### 4. Simulation — `football_simulation_service.dart`
`modelVersion = poisson_monte_carlo_v7_team_goal_lines` (`:15`).
- `homeLambda = normalized.goalRateExpectedHome`, `awayLambda = ...Away`, clamped 0.05–5.0
  (`:57-58, 82-83`). Missing → row `status:skipped, reason:goal_expectation_missing` (`:60-67`).
- League champion lookup batch (`:43-48`). `_resolveLeagueChampionModels` (`:334`) would apply a
  learned `EngineReplica` per market — but **skips `GlobalMarketEngine`-based champions** (`:368-371`)
  and the comment states "aktuell hat keine Liga einen eigenen Champion" (`:367`). ⇒ live path is
  pure MC; `learned(key, baseline)` (`:233`) always returns the MC baseline.
- `_simulate()` (`:109`): `Random(_stableSeed(fixtureId, simulations))` (`:117, 446`) — the MC is
  **deterministic per fixture** (same fixture id + sim count → identical output every run).
- Per draw: `homeGoals = _samplePoisson(λ_home)`, `awayGoals = _samplePoisson(λ_away)` (Knuth,
  capped at 20 goals, `:433-444`), independent (no Dixon-Coles low-score correction).
- Tally: 1X2, O/U 2.5 (total ≥ 3), BTTS, plus `hit()` for ~30 extended keys — over/under
  0.5–5.5, dc1x/dc12/dcX2, dnbHome/dnbAway, homeOver/Under 1.5/2.5, awayOver/Under 1.5/2.5,
  European handicap ±1/±2, and 6 result×total combos (`:162-203`).
- DNB probability is made conditional on no-draw (`:225-229`).
- Output: `probabilities` (decimal), `probabilitiesPercent`, `fairOdds` (= 1/p), `goalExpectations`
  (λ + base λ + sourceType + realXgAvailable), `topScorelines` (top 5), `modelLab` note.
  No `stability`, no `phaseFour`, no calibration. Stored to `football_simulation_results`.

### 5. Market selection + trust — `football_market_selection_service.dart`
`modelVersion = market_selection_v12_team_goal_lines` (`:8`). `selectForFixture()` (`:58`):
- Builds ~25 candidates from `probabilities` + `fairOdds` (`:69-225`), drops p ≤ 0, sorts by p.
- `mainTipKeys` = {homeWin, draw, awayWin, bttsYes, bttsNo, over25, under25} (`:247-255`) —
  **the only markets allowed to become the PHÖNIX tip** (AN2 §7 / AN.txt §6).
- `displayTipKeys` (`:256-279`) is broader (adds dc1x/dcX2, over/under 1.5/3.5, team goals, DNB)
  and feeds only the "Marktcheck" list.
- `selectableMain` = mainTipKeys ∧ p ≥ 0.68 ∧ fairOdds ≥ `_minimumFairOddsFor(key)` (1.35–1.40,
  `:490`). Fallback `fallbackCoreMain` = same but p ≥ 0.50 (`:301-309`).
- `rankedMain = selectableMain || fallbackCoreMain`; **if empty → returns `null` → fixture is
  dropped entirely** (no analysis row) (`:336-340`). This is the one hard publish gate.
- `_trustScore()` (`:498-525`): `p*35 + gapToSecond*20 + dataQuality/100*30 + sims/100000*10 +
  (realXg?5:0)`. With realXg always false, max ≈ 95; sims 10000 contributes only 1 pt.
- `qualifiesForTip = p ≥ 0.68 ∧ sims > 0 ∧ dataQuality ≥ 60 ∧ trust ≥ 60` (`:373-377`).
- `display.showPhoenixTip` is **hard-coded `true`** (`:431`); `qualifiesForTip` only affects
  the value/bet layer and a warning string (`:445-446`).
- `value` block initialised to `status:not_checked` (`:414-423`). Stored to
  `football_market_selections`.

### 6. Value check — `football_value_service.dart`
`modelVersion = value_check_v3_strict_full_time_odds` (`:13`).
- Fetches real bookmaker odds (`football.oddsForFixture`, `:41`). `_oddsForMarket` (`:279`) takes
  median + best across books, trims outliers > median·1.12 (`:338-341`), rejects suspicious odds
  (>5.00 for short markets, >20.00 else, `:673-705`).
- If `qualifiesForTip != true` or no market key → `value.status = no_estimate`,
  `isValueTip = false`, but `marketOdds` is now shown for information (`:53-106`).
- Else: `valuePercent = (marketOdds/fairOdds − 1)·100`; 1X2 uses a de-vigged consensus prob for
  the market-guard (`_devigged1X2Probability:256`).
- `isValueTip = hasOdds ∧ marketOdds ≥ 1.40 ∧ 5% ≤ value ≤ 25% ∧ fair-vs-market dev ≤ 25%`
  (`:164-168`). `display.showValueTip = isValueTip` (`:213`).
- Pipeline wraps this in `try/catch` and ignores failure (`football_daily_pipeline_service.dart:228-240`).

### 7. Publish — `football_daily_pipeline_service.dart::_publishAnalyses` (`:298`)
- Joins phase-2 + simulation + selection (`finalizationCandidates`, `database.dart:4880`,
  requires `analysis_allowed = TRUE`).
- Strips `combo*` and `dc12` from probabilities/fairOdds (`hiddenMarket:328-333`).
- `phoenixTip = analysisLead = selection.phoenixTip` — **always the ranked-main leader**,
  regardless of `qualifiesForTip` (`:340-352`, comment 341-351).
- `confidence = trust.score (0..100) + aiContext.confidenceDelta (always 0)` (`:356-363`).
- `recommendation = phoenixTip.market`; `tracking.isPhoenixTopTip = recommendation.isNotEmpty`
  (`:369, 417-419`).
- `simulationCount = simulation.simulations` (`:447`).
- `engineVersions` all `GLOBAL_*_V0_BASELINE` / `DERIVED_FROM_1X2_V0_BASELINE`, simulation tag
  `poisson_monte_carlo_v6_extended_markets` — **stale**, simulator is on v7 (`:463-472`).
- `database.saveFinalFootballAnalysis` → `INSERT ... ON CONFLICT (sport, match_id, model_version)
  DO NOTHING` (`database.dart:5477-5497`): **a published `(fixture, publishedModelVersion)` tuple is
  frozen**; re-scans cannot change it. That is why fixing anything requires bumping
  `publishedModelVersion` (`v10 → v11 → v12`).
- History + daily combo written only if the INSERT was new (`:492-504`).

### 8. App read — `football_analysis_api.dart`
- `GET /api/football/analysis/<date|today>`: reads `analyses` where
  `data_quality >= minimumQuality` (default **60 today / 50 past**, `:36-39`), `sport='football'`,
  `model_version = FootballDailyPipelineService.publishedModelVersion` (`:143-157`).
- Pure passthrough of the stored payload — **no recomputation** in the API or (for this path) the app.

---

## Per-component status

| Component | Status | Notes |
|---|---|---|
| Phase-1 scan | **works** | focus-tier gate is clean; `_decide()` dead code (`:198`). |
| Phase-2 coverage | **works, thin** | 8 provider calls; lineups disabled, xG disabled, injuries/odds are flags only. |
| `_quality()` score | **half** | additive heuristic; not tied to what λ actually needs (a 62 can have no goal data). |
| `goalAverageIfPlayed` | **works** | correct "missing ≠ 0" handling (AN2 §2). |
| Engine input λ | **half** | only a 2-number mean; league-aware baseline + shrinkage are the only sophistication. `c2b1942` ("league-aware baseline") committed 2026-08-26 with message *"NOT YET DEPLOYED, needs backtest first"* — but it is live in the file the pipeline imports. |
| `normalized.*Strength` | **dead** | computed, stored, never read; inconsistent baselines (1.15). |
| AI-context / Gemini | **removed but scaffolding remains** | every `aiContext`/`context` branch is inert; fields still serialized. |
| Simulation MC | **works** | correct Poisson MC; but independent goals (no Dixon-Coles), deterministic seed, no uncertainty output. |
| League champion override | **half / unreachable** | `EngineReplica` path exists, promotion is server-blocked, `GlobalMarketEngine` champions explicitly skipped → never fires live. |
| Market derivation | **works** | all markets from one score distribution ✔ (AN2 §9–13 partially met). |
| `mainTipKeys` restriction | **works** | DC/DNB/combos/team-goals cannot be the main tip (AN.txt §6 fixed). |
| Trust score | **half** | arbitrary linear weights, never calibrated; xG term dead; sim term negligible. |
| `qualifiesForTip` gate | **works but bypassed for display** | correct gate, but `showPhoenixTip` is hard-coded true. |
| Value check | **works** | strict, real odds, de-vig, outlier trim; failure silently ignored by pipeline. |
| Calibration | **missing in live path** | only in `model_lab/` (learning/backtest). |
| `FootballFinalizationService` | **outdated / contradictory** | `phoenix_full_v1`, reads fields the simulator no longer emits; still on `POST /finalize`; not in cron. |
| Freeze-on-publish | **works, with cost** | guarantees tip immutability; forces model-version bumps for any fix. |
| App read API | **works** | `data_quality` read-filter is the de-facto tip gate. |

---

## Data handling & fallbacks

Legend for "flagged downstream?": is the fallback visible to later stages / the app as a fallback?

| Signal | present | partial | missing | true-zero | how used | fallback | flagged? |
|---|---|---|---|---|---|---|---|
| xG / xGA | **never** (`football_service.dart:379`) | – | always | – | nothing (all branches dead) | n/a | `realXgAvailable:false`, warning string, trust −5pts |
| Team goal rates (splits) | mean → λ | uses the one present side | → league baseline λ | `null` via `goalAverageIfPlayed` (not 0) | sole λ driver | league-aware baseline 1.35/1.10 | `sourceType=safe_baseline_fallback`, warning; **not** as a publish block |
| Recent form (last 5) | `_quality` +≤6/+≤6 only | fewer than 5 counted | −0 | – | quality score only; **not** λ | none | count in payload |
| Home/away split | via split rates above | `min(played)` = sample size | shrinkage k=8 pulls to baseline | 0 games → `null` | shrinkage strength | league baseline | `sampleSizeShrinkageApplied`, warning |
| Opponent strength | implicit: opp conceded rate in the mean | – | drops to own rate only | – | half of each λ | own rate | not separately flagged |
| Team strength (abs.) | – | – | not modelled at all | – | – | – | – |
| League baseline | 400-day rolling avg (`database.dart:6552`) | shrunk to global if `sampleSize<50` | `null` → global 1.35/1.10 | – | baseline for shrinkage | global constant | `leagueContextApplied` |
| Lineups | **never fetched** (`:363-365`) | – | always | – | nothing | n/a | `aiContext.lineupStatus != confirmed` warning always on |
| Injuries | yes/no flag | – | flag false | – | `_quality` +10 only | none | flag in availability |
| Suspensions | not modelled | – | – | – | – | – | – |
| Odds | `football.oddsForFixture` | median/best, outlier-trimmed | `value.status=odds_unavailable`, no fake odds | – | value % + market guard | none (tip stays, value hidden) | `value.status`, `bookmakerQuotesFound` |
| Standings / table pos. | `_quality` +15 only | – | −15 quality | – | quality score only; **not** λ | none | `standings` flag |
| H2H | `_quality` +10 only | – | −10 quality | – | quality score only | none | `h2h` flag |

Hard-coded constants in the live path:
- Global goal baseline `1.35` / `1.10` (`football_engine_input_service.dart:131-140`).
- `*Strength` baselines `1.35`, `1.15`, `1.35` (`:218-221`, **inconsistent**, unused).
- Shrinkage `k = 8` (team, `:23`), `k = 50` (league, `:31`).
- λ clamps `0.20–3.80` (engine input `:186`) then `0.05–5.0` (simulation `:82`).
- Poisson goal cap `20` (`football_simulation_service.dart:441`).
- `minimumProbability = 68`, value `minimumMarketOdds = 1.40`, `minimumValuePercent = 5`
  (`football_daily_pipeline_service.dart:216, 235-236`).
- `qualifiesForTip` thresholds: `dataQuality ≥ 60`, `trust ≥ 60` (`football_market_selection_service.dart:373-377`).
- Read filter `data_quality ≥ 60 / 50` (`football_analysis_api.dart:39`).
- Simulation seed = hash(fixtureId)+simCount (deterministic, `:446-452`).

---

## Model-version lineage

| Stage | current const | notes / git |
|---|---|---|
| Engine input | `goal_rate_normalization_v6_league_aware_baseline` | `0a8c496` (2026-08-26) thin-sample shrinkage toward baseline; `c2b1942` (2026-08-26) league-aware baseline, commit msg says *not yet deployed / needs backtest* but it is in the imported file. Earlier July commits are unnamed "Update …". |
| Simulation | `poisson_monte_carlo_v7_team_goal_lines` | v6 added extended markets; v7 added team-goal lines (`5637a55`). Publish payload still tags it `…v6_extended_markets` (`football_daily_pipeline_service.dart:471`) — stale label. |
| Market selection | `market_selection_v12_team_goal_lines` | |
| Value | `value_check_v3_strict_full_time_odds` | `ba32b80` incident fixes. |
| **Published analysis (app filters on this)** | `phoenix_daily_pipeline_v12_sample_size_shrinkage` | v10→v11 (`d7649fa`, 2026-08-26): stop blanking `phoenixTip` when the publish gate fails — "every match must have a tip". v11→v12 (`29a7a07`, 2026-08-26): thin-sample tips (Lyon/Fenerbahçe, Celje/Slovan, AEK, Newcastle, Rapid Vienna — sampleSize 0–2) had unrealistic probabilities; bump forces a re-scan because published tuples are frozen (`ON CONFLICT DO NOTHING`). |
| AN.txt `football_v1_mc100k` | **gone** | not present anywhere in the tree; `stability` field also removed. |

---

## AN.txt bug — is it fixed?

**"Different matches → near-identical probabilities":** root cause was (a) provider `0.0` from
0-games splits propagated into `_averageAvailable`, dragging both λ to ~0.5, and (b) a single
universal `1.35/1.10` fallback used whenever goal data was missing. Both addressed:
`goalAverageIfPlayed` returns `null` for 0 games (`football_service.dart:56`); thin samples are
shrunk (`k=8`); the fallback is now per-league (`leagueAwareBaseline`).
**Still open:** a match where *both* λ inputs are missing → `sourceType=safe_baseline_fallback` →
λ = exact league baseline → **every such match in a league gets identical probabilities**, and it is
still published. Only the read-time `data_quality ≥ 60` filter may hide it, and that filter can be
passed without any goal data (standings+odds+h2h+injuries+form = 62). Guards that exist:
`sourceType` string, `warnings[]`, `qualifiesForTip=false` — none block publish/display.

**"Tip issued despite 0 simulations / stability 0 / `football_v1_mc100k`":** fixed at the data
level — model string and `stability` gone; `simulations` clamped ≥1000; pipeline throws if
`simulated <= 0` (`football_daily_pipeline_service.dart:206`); `trustScore` sim-component is now a
true 0 at 0 sims (`football_market_selection_service.dart:512-514`); `qualifiesForTip` requires
`simulations > 0`. **Re-opened at the UX level by design:** the 2026-08-26 "every match must have a
tip" change hard-codes `showPhoenixTip:true` and always fills `recommendation` / `topTip` /
`tracking.isPhoenixTopTip` for any core market ≥ 50%, so the app can still render a "PHÖNIX-TIPP"
for an analysis that fails `qualifiesForTip`. Whether it says "TOP-TIPP" now depends on the Flutter
layer honouring `qualifiesForTip` / `tracking.isPhoenixTopTip`.

**"DC12 as top tip":** fixed — `dc12` and `combo*` stripped at publish
(`football_daily_pipeline_service.dart:328-333`), and `mainTipKeys` excludes all DC/DNB
(`football_market_selection_service.dart:247-255`). `dc1x`/`dcX2` remain in the Marktcheck only.

---

## Gaps vs AN2.txt Phase 1

- **§10–11 shared Match-State:** only `{λ_home, λ_away}` is shared. No attack/defence strength,
  home advantage term, tempo, or explicit uncertainty object. Home advantage is only implicit in
  which split rate is read.
- **§14 market-specific calibration:** none in the live path. No isotonic/Platt, no per-market
  calibration. Only `model_lab/` has calibration, and it never feeds production.
- **§15 goal models:** live path is fixed independent Poisson. Dixon-Coles / bivariate Poisson /
  neg-binomial exist only as `model_lab` engine families, not compared on the live output.
- **§16 data-driven feature weights:** λ is a fixed 50/50 mean of own-attack / opp-defence; no
  feature importance or ablation informs it. `attackWeight` is a `model_lab` concept only.
- **§17 opponent adjustment:** partial — opponent conceded rate is half of λ, but there is no
  strength-of-schedule / opponent-quality correction on the rates themselves.
- **§18–19 home/away + sample-size:** partially met (split rates + `k=8` shrinkage). No blend of
  current + previous season + long-term strength + prior as §19 describes; only current-season
  stats with a crude previous-season swap in `coverageForFixture`.
- **§20 promoted / new teams:** no handling. A promoted side with <3 games → stats dropped →
  `safe_baseline_fallback`.
- **§21 missing data → raise uncertainty:** flags and warnings exist, but nothing raises a numeric
  uncertainty or widens the distribution; missing lineups/injuries do not change anything.
- **§22 data_quality as a real model input:** only a read-time visibility filter + a 30-pt slice of
  a non-calibrated trust score. Does not affect λ, value threshold, or model weighting.
- **§23 uncertainty:** not produced. No sample-size / coverage / league-experience / model-spread
  interval on any probability.
- **§9 one engine, derived markets:** *met at the simulation level* — this is the strongest existing
  building block to keep.

---

## Open questions for the rebuild plan

1. Is `c2b1942` (league-aware baseline) actually backtested and intended to be live now, or did it
   ship ahead of its own commit message? Same file also carries `0a8c496`.
2. Should `safe_baseline_fallback` analyses be publishable at all, or become "no reliable model
   result yet" (AN.txt §7)? If they stay, they need per-match noise or an explicit
   "not individualised" flag the app must render.
3. `showPhoenixTip` is unconditionally true — is the app expected to downgrade display based on
   `qualifiesForTip` / `tracking.isPhoenixTopTip`, and does it? (Needs a Flutter-side check.)
4. `data_quality` currently only filters at read time with different floors for today (60) vs past
   (50). Where should the real gate live post-rebuild — pipeline, selection, or read?
5. Keep the frozen-on-publish contract (`ON CONFLICT DO NOTHING`)? It blocks silent tampering but
   forces a model-version bump for every fix and leaves `v10/v11` rows as permanent history.
6. `FootballFinalizationService` + `POST /finalize`: delete, or is anything still calling it?
7. The MC seed is deterministic per fixture — intentional reproducibility, or should the rebuild
   keep a fixed seed for auditability and store the full score matrix instead of re-simulating?
8. Trust score weights (35/20/30/10/5) are hand-picked and uncalibrated — replace with a
   calibrated confidence derived from historical bucket hit-rates?
9. Injuries and standings are fetched every night but only add to `_quality`. Worth the provider
   budget, or drop until they actually feed the model?
10. `normalized.*Strength` fields — remove, or wire into the new shared Match-State (they are the
    closest existing hook for AN2 §11)?
