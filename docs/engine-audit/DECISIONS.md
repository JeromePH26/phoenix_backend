# Phase 1 — dead-code / dead-artefact register

One row per dead or contradictory artefact found in the audits
(`docs/engine-audit/01..05.md`), with its disposition. **Execution happens in
M11**; the "repurpose in Mx" entries are picked up by that milestone. This file
is the checklist M11 works from — update the Status column as items land.

| Artefact | Disposition | Milestone | Rationale | Status |
|---|---|---|---|---|
| `FootballFinalizationService` (`lib/src/services/football_finalization_service.dart`, `phoenix_full_v1`) + `POST /api/admin/football/finalize` (`routes.dart:1132`) | **Remove** | M11 | Reads `simulation['stability']` / `['phaseFour']` / `['topScores']` the current simulator never emits; not in the cron; contradicts the live path (audit 01). | open |
| `normalized.*Strength` fields (`football_engine_input_service.dart:218-221`, inconsistent 1.15/1.35 baselines) | **Repurpose** — fill from `MatchState`; keeps the `feature_whitelist.dart:28-33` paths live | M3 | Closest existing hook for the AN2 §11 shared match-state. | open |
| Per-league challenger path (~500 lines, `learning_run_service.dart:354-872`) | **Keep dormant** behind a new `perLeagueChallengersEnabled` config flag (default `false`) | M0 flag / M9 confirm | 0 leagues reach 100 samples for months (audit 02); AN2 §5-8 stays reachable without live risk or maintenance churn. | open |
| `WalkForwardStep` / `ChronologicalSplit.steps` / `walkForwardStepSize` (`walk_forward_evaluator.dart:56`, computed, never scored) | **Revive** as real expanding-window scoring, or rename to `chronological_holdout` if history is too thin | M7 | "Walk-forward" is currently a single split (audit 03/04). | open |
| `minShadowSample` (`model_lab_config.dart`, declared, never read) | **Revive** as a min shadow count + time-window gate before a challenger is review-eligible | M7 | AN2 §36. | open |
| `sampleSizeTier()` + `strongerAdaptationSampleThreshold` + `fullLeagueEngineSampleThreshold` (`model_lab_config.dart`) | **Remove** | M11 | `sampleSizeTier()` is only used by its own test; the two thresholds only feed it (audit 03). | open |
| Orphan tables `football_final_tips`, `football_ai_context_jobs` (0 rows, no code refs) | **Drop** (`DROP TABLE IF EXISTS`, guarded, in a migration) | M11 | Left over from removed features; harmless but confusing schema drift (audit 05). | open |
| Zero-row tables `football_league_sync_state`, `football_coverage_samples`, `football_season_projections`, `daily_tips`, `football_daily_combos` | **Keep, mark deprecated** in a schema comment; revisit in Phase 2 | M11 | Control Center may revive combos / `daily_tips`; not worth a destructive migration now (audit 05). | open |
| AI-context step wiring (`football_daily_pipeline_service.dart:167-180`) + `football_ai_context_checks` (86 rows) | **Remove the step wiring**; keep the table read-only until Phase 2 | M11 | Permanently unwired; `contextApplied` structurally always false (audit 01). | open |
| `showPhoenixTip` hard-coded `true` (`football_market_selection_service.dart:431`) | **Fix** — drive from `qualifiesForTip` + the M6 uncertainty gate | M6 | AN.txt "tip despite 0 sims" bug re-opened by the 2026-08-26 "every match must have a tip" change (audit 01). | open |
| `match_scope='clean'` == `'all'` duplicate `phoenix_model_evaluations` rows | **Stop writing the `clean` scope** until `football_live_events` has data | M11 | Red-card coverage ≈ 0, so `clean` and `all` carry identical numbers (audit 03). | open |
| `simulations` param disagreement (cron 10k / route default 100k / DB `.clamp(100000,100000)`) | **Collapse to one constant** | M8 | Three layers disagree; the clamp wins — dead config surface (audit 05). | open |
| `draw_no_bet_*` encoded 3-class in the Lab (byte-identical to 1x2), 2-class conditional live | **Frozen to 2-class conditional both sides** | **M0 — done** | Live and Lab scored a different quantity under the same name; Brier ≈ 0.63 was the 3-class-sum artefact (audit 04). | **done (this commit)** |

## M0 changes made in this commit

**DNB definition freeze** — `draw_no_bet_home` / `draw_no_bet_away` are now a
2-class market `[won, lost]`, conditional on "no draw"
(`P(win) / (P(win) + P(lose))`), matching the live engine. Draw (push) outcomes
are filtered out of every evaluation via `LearningSample.isVoidOutcomeFor` /
`LearningMarket.hasVoidableOutcome`, not counted as a loss.

- `learning_market.dart` — `isMultiClass` now true only for `oneXTwo`; new
  `hasVoidableOutcome`.
- `engine_replica.dart` — the two DNB cases return `[wonCond, 1-wonCond]`,
  labels `['won','lost']`.
- `learning_sample.dart` — new `isVoidOutcomeFor(market)`; DNB `outcomeIndexFor`
  returns 0 (won) / 1 (lost).
- `walk_forward_evaluator.dart` — `MarketEvaluationResult.compute` and
  `ChampionChallengerComparison.compare` both drop void samples for **both**
  sides (keeps `perSampleBrier` / `diffs` aligned).
- `shadow_prediction_service.dart` — generate + settle loops skip void samples;
  the settle loop converts legacy 3-class stored DNB rows to the 2-class
  conditional form before scoring.
- `football_simulation_service.dart` — `_mergeLearnedProbabilities` DNB cases
  read the already-conditional `value(0)` (dormant path — no league champions).
- Tests: `engine_replica_test.dart`, `learning_sample_test.dart`,
  `walk_forward_evaluator_test.dart`.

**Not done in M0** (deliberately): the stale `phoenix_model_evaluations` DNB
rows (3-class Brier ≈ 0.63) and stale shadow-prediction rows are left in place.
They must be regenerated / quarantined before M4 reads any DNB baseline — this
is an M4 precondition, tracked there, and M2's shadow-quarantine covers the
shadow side.
