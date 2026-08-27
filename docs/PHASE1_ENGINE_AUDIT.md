# PHÖNIX Phase 1 – Engine Audit (synthesis)

Date: 2026-08-27. Head commit `1673ee5` (+ `c23c8ff` / `d07b685` / `1673ee5` eligibility fixes
shipped today). Authoritative spec: `C:\Users\Justin\Documents\Claude AN2.txt` – binding two-phase
order, Phase 1 = engine to expert level, Phase 2 = Control Center to enterprise level (parked).

This is the merge of five parallel read-only audits. Detail lives in:

- [`engine-audit/01-live-engine-pipeline.md`](engine-audit/01-live-engine-pipeline.md) – the production analysis → tip path
- [`engine-audit/02-data-availability-audit.md`](engine-audit/02-data-availability-audit.md) – what data PHÖNIX actually has (live DB)
- [`engine-audit/03-model-lab-learning-challengers.md`](engine-audit/03-model-lab-learning-challengers.md) – the Model Lab / learning system
- [`engine-audit/04-calibration-uncertainty.md`](engine-audit/04-calibration-uncertainty.md) – calibration & uncertainty
- [`engine-audit/05-db-schema-jobs-scan-datasources.md`](engine-audit/05-db-schema-jobs-scan-datasources.md) – schema, jobs, scan, API

---

## Executive summary

**The one constraint that shapes everything: PHÖNIX has ≈ 6 weeks of history and ≈ 650 usable
learning rows, with no xG, no lineups, no shots, mostly no injuries, and no stored odds prices.**
Every "expert-level" ambition in AN2 (per-league models, real walk-forward, temporal stability,
the xG branch, ROI/CLV, calibration validation on a holdout) is bottlenecked on data that does not
exist yet. AN2 §2 is explicit about this: fit the engine to the data we actually get. So Phase 1 is
necessarily: **one global pooled engine, goal-rate + team-strength based, robust on tiny samples,
with honest (wide) uncertainty and a real calibration layer** – not the two-tier global+per-league
system as a near-term deliverable.

Top findings:

1. **"The model" in production is two Poisson means → a 100k Monte-Carlo.** λ = plain average of
   own scored rate and opponent conceded rate, shrunk toward a league baseline for thin samples.
   No team-strength vector, no tempo, no uncertainty object, **no calibration**. (01 §TL;DR)
2. **All markets already derive from ONE score distribution** – both the live MC and the Model Lab
   `scoreMatrix`. This is the single strongest existing asset and matches AN2 §9–13 at the maths
   layer. What's missing is the rich shared "Match-State" (§11): today the only shared object is
   `{λ_home, λ_away}`. (01, 03)
3. **No probability calibration anywhere** – not live, not in the Lab, not in any challenger.
   Independent Poisson systematically under-predicts draws and nothing corrects it. Calibration is
   the highest-value single addition. (04 §TL;DR)
4. **The Model Lab is not really a learning system.** Only `TEAM_STRENGTH_IPF_V1` fits anything;
   every other "challenger" is a fixed pre-declared parameter (attackWeight grid point, DC `rho`).
   "Walk-forward" is computed and never used for scoring – it's a single chronological split. (03)
5. **The live global champions were never evaluated.** `GLOBAL_1X2_V1 … V2`, `train=0 val=0
   holdout=0`, activated by fiat via a path that bypasses `PHOENIX_MODEL_PROMOTION_ENABLED`. Every
   challenger is measured against an unvalidated incumbent, and none has ever beaten it. (03)
6. **Promotion is fully stubbed; 0 monthly reviews have ever run; 11 of 15 learning runs are
   `orphaned`** – killed by a Railway redeploy mid-run (the run takes ~11 h). Scheduled crons
   appear not to be configured (0 `scheduled` runs ever). (03, 05)
7. **`data_quality` is an "API completeness" score, not a modelling-input-quality score** – two
   incompatible formulas across tiers, ignores sample size/recency/opponent quality, and only
   drives read-time visibility + one linear term in tip selection. AN2 §22 wants it to drive
   confidence, uncertainty, value thresholds and model weighting; it drives none of those. (02, 04)
8. **"Vertrauen 74 %" is a hand-weighted 0–100 heuristic**, not a probability, never checked
   against realised frequency; **"Stabilität 0/100" is a dead field** football never populates.
   `showPhoenixTip` is hard-coded `true` regardless of `qualifiesForTip`. (01, 04)
9. **`draw_no_bet` is encoded 3-class in the Lab (identical to 1x2) and 2-class conditional live** –
   the two sides score a different quantity under the same name. The "abnormal" Brier ≈ 0.63 is
   this artefact, not a hard market. (04 §draw_no_bet)
10. **No Learning Dataset Pipeline / Production-Learning-Research classification exists** (AN2
    §24–32) – data-class selection is inline SQL in `modelLabRawDataset()`. `historical_twin_matches`
    (68k, 2019–25) + `historical_elo_ratings` (245k) exist but are **disconnected from the engine**
    and only 22 % league-matched. (02, 05)
11. **Infra fragility:** single shared DB connection (no pool); 3 job families with 3 separate
    redeploy-recovery implementations; API-Football uncapped (62 % of a 7,500 Pro quota on a burst
    day, a 55 %-error day on 2026-08-22); ~1,805 orphaned fixtures; 91 % of shadow predictions
    retro-fitted (made after kickoff). (02, 05)

---

## The data reality (hard limits for the plan)

| Fact | Number | Source | Implication |
|---|---|---|---|
| `football_matches` span | 2026-07-17 … 08-27 (~6 wks) | 02, 05 | No multi-season history. No winter/season-start/season-end variation. Walk-forward / temporal stability (§34/§38) cannot be done honestly yet. |
| Finished-with-result | 2,224 | 02 | — |
| Fixtures with a **pre-kickoff** snapshot | 888 | 02 | The engine can only learn from fixtures it snapshotted before kickoff. |
| Usable learning rows (settled, pre-kickoff, dq ≥ 40) | **≈ 650** | 02 | 630 focus / 22 watchlist / **0 data_pool**. One 6-week window, cup-heavy (13 %), Nordic-summer-heavy. |
| Leagues with ≥ 50 eligible samples | **2** (both cross-league cups) | 02 | — |
| Leagues with ≥ 100 / 300 / 600 | **0 / 0 / 0** | 02 | AN2 §5–7 per-league models are not viable for months. Big-5 leagues have 8–15 samples each. |
| xG / xGA / lineups / shots / HT score / suspensions / coach | **0 %** (hard-coded off) | 01, 02 | The entire "xG falls vorhanden" branch (§10, §21) is dead code today. |
| Injuries | ~30 % focus, 0 % elsewhere; feeds `data_quality` only, never λ | 01, 02 | — |
| Odds | presence bit only (`retainRows:false`) – **every price discarded** | 01, 02 | No opening/closing odds → no value-vs-market in the Lab, no CLV (§40). |
| Genuine pre-kickoff shadow predictions | **~915** of ~10,300 settled | 02, 03 | 91 % were made after kickoff and must be quarantined out of every metric. |
| `safe_baseline_fallback` inputs (no usable goal averages → pure league prior) | **14 %** (343 / 2,499) | 01, 02 | These produce identical probabilities for every such match in a league and are still published. |

---

## Current architecture

### Live pipeline (`bin/phoenix_daily_cron.dart` → `FootballDailyPipelineService`)

```
Phase 1 scan (focus leagues, future kickoff only)
  → Phase 2 coverage (8–10 API-Football calls/fixture; lineups OFF, xG OFF, odds=bit, injuries=bit)
    → data_quality = additive API-completeness score (two different formulas per tier)
  → engine input:  λ_home = mean(home scored@home, away conceded@away), λ_away = mirror
                   → shrink toward league-aware baseline (k=8 team, k=50 league)
                   → both missing ⇒ λ = league baseline exactly  (safe_baseline_fallback, 14%)
  → simulation:    100k independent-Poisson Monte-Carlo, deterministic seed per fixture
                   → ONE score matrix → 1X2 / BTTS / O-U / ~30 derived markets (incl. DNB 2-class)
  → market selection: pick from {homeWin,draw,awayWin,btts*,over/under2.5}; p≥0.68; fairOdds≥1.35
                   → trustScore = 35·p + 20·gap + 30·dq + 10·sims + 5·xG   (xG term always 0)
                   → qualifiesForTip = p≥0.68 ∧ sims>0 ∧ dq≥60 ∧ trust≥60   (gates VALUE only)
  → value check:   real bookmaker odds fetched here, used transiently, never stored
  → publish:       INSERT … ON CONFLICT (sport,match_id,model_version) DO NOTHING  (frozen on publish)
  → app read:      analyses WHERE data_quality ≥ 60 (today) / 50 (past)   ← the de-facto tip gate
```

No calibration step. No uncertainty output. `showPhoenixTip` hard-coded `true`.
`FootballFinalizationService` (`phoenix_full_v1`, reads fields the simulator no longer emits) is
still wired to `POST /finalize` but not in the cron – dead/contradictory.

### Model Lab (`lib/src/model_lab/`, `LearningRunService`)

```
weekly run (Tue, in practice always manual):
  auditEligibility → load whitelist → build leakage-safe samples (grouped by league)
  for each of 17 LearningMarkets:
     pooled-global challengers (league_id = null):
        GLOBAL_GOALS_V1 ×1 · GlobalMarket hypotheses ×4 · Dixon-Coles rho ×2 · TeamStrength halfLife ×2
        → ChronologicalSplit (holdout 20% newest; training = first 60; validation = rest)
        → score validation ("walk_forward") + holdout in ONE block each   (steps[] computed, unused)
        → persist champion & challenger Brier/logloss/calibration + paired bootstrap CI
     per-league challengers: coded (~500 lines) but produce ~nothing (no league clears 50 samples)
  shadow predictions + monthly review run on separate schedules (monthly review: 0 rows ever)
```

Champions = 17 market-level `GLOBAL_*_V1 V2` rows, `league_id = null`, never backtested, activated
by fiat. `promotionEnabled` default `false` → promote/rollback 403. On run #15 **no challenger beat
the champion** (all `championBetter` / `approximatelyEqual`).

### What is shared / consistent

- **One score matrix → all markets** (live MC `scoreMatrix`; Lab `PoissonMath.scoreMatrix` +
  `EngineReplica.evaluateGoals`). Keep this.
- **Leakage discipline** in the Lab is genuinely careful: SQL prefilter + in-code re-check +
  positive feature whitelist + `no_ai_isolation_test`. (One gap: the GG1/GlobalMarket/TeamStrength
  sample path trusts SQL for `snapshot_created_at < kickoff` without the redundant in-code guard.)
- **Input shrinkage toward a prior** (goal rates, team strengths) is implemented and sensible.

---

## Gap matrix vs AN2 Phase 1

| AN2 § | Requirement | Today | Gap size |
|---|---|---|---|
| 1 | Understand the whole system first | done (this audit) | – |
| 2 | Fit engine to real data, not theory; present/partial/missing/zero/unknown | partial: `goalAverageIfPlayed` returns null (good); but xG scaffolding is dead code, no explicit "unknown" vs "zero" object | medium |
| 3 | Full data audit | done ([02](engine-audit/02-data-availability-audit.md)) | – |
| 4–7 | Global engine as champion + per-league challengers; league switches only when provably better | global-only exists; per-league path is dead code (0 rows); "provably better" gate exists but nothing passes it | **large (per-league not viable now – see plan)** |
| 8 | Each challenger a justified hypothesis, no 20 near-identical | GlobalMarket 4 hypotheses = OK; attackWeight 6-grid + DC 2-grid = blind grids | medium |
| 9–13 | ONE match engine → shared match-state → score distribution → derived markets + market-specific calibration | score distribution → markets: **done**. Shared match-state: only `{λ}`. Market-specific calibration: **none**. Still 17 market-champion rows, not one match model. | medium (calibration is large) |
| 14 | Market-specific calibration | none | **large** |
| 15 | Compare Poisson / Dixon-Coles / bivariate / NegBin on real data | DC + independent Poisson exist in the Lab; bivariate & NegBin not implemented; none compared for the *champion* | medium |
| 16 | Data-driven feature weights (importance / ablation) | λ is a fixed 50/50 mean; `attackWeight` is a Lab-only knob; no ablation | medium |
| 17 | Opponent adjustment | partial (opp conceded rate is half of λ); no strength-of-schedule correction | medium |
| 18–19 | Home/away with sample-size protection; blend current+prev season+long-term+prior+global | partial (split rates + k=8 shrink); no multi-season blend (no multi-season data) | medium |
| 20 | Promoted / new teams | none – <3 games ⇒ stats dropped ⇒ `safe_baseline_fallback` | medium |
| 21 | Missing data → flagged fallback + raise uncertainty | flags/warnings exist; **nothing raises a numeric uncertainty** | large |
| 22 | Data quality as a real model component (confidence/tip-release/uncertainty/value/weighting) | read-time filter + 1 linear term only | **large** |
| 23 | Per-prediction uncertainty (8 named signals) | 6 of 8 not propagated; no interval on any probability | **large** |
| 24–32 | Learning Dataset Pipeline; Production/Learning/Research classes; audit the pool; transfer/hierarchy | no pipeline table, no data classes; inline SQL filters; `historical_*` datasets unused | **large** |
| 33–36 | Leakage prevention / walk-forward / holdout / shadow | leakage: good. walk-forward: **not real** (single split). holdout: yes. shadow: yes but 91 % retro-fitted | medium |
| 37–41 | Many tests; temporal & per-league stability; full metric set; not hitrate | Brier/logloss/calibration-buckets/bootstrap present. Missing: ECE, ROI/yield/CLV, stability, max drawdown, per-league slice of a global model | medium |
| 42–44 | Champion decision rules; no lucky-weekend switch; rollback + versioning | bootstrap "CI excludes 0" gate + n≥120 = decent lucky-weekend guard; calibration **not** a gate; no cross-market regression veto; training *dataset* not snapshotted (only its date range) | medium |
| 45 | Archive old engines with metadata | partial (`status='retired'` + `feature_config`); no "replacement reason", no archive view | small |
| 46–51 | Go live only after tests/backtests/holdout/sanity/migration/rollback; full daily scan + audit; fix + re-test | promotion path never run end-to-end; daily-scan audit (§49) not built | medium |

---

## Cross-cutting problems (grouped)

### Modelling
- No calibration layer (04). Independent Poisson mis-calibrates draws; DC exists only as a
  shadow challenger.
- Shared "Match-State" is just `{λ_home, λ_away}` – no attack/defence strength, home advantage
  term, tempo, or uncertainty (01 §Gaps).
- `safe_baseline_fallback` (14 %) publishes identical per-league probabilities (01).
- DNB definition inconsistent between live (2-class) and Lab (3-class == 1x2) (04).
- Blind parameter grids instead of hypotheses for attackWeight / DC (03 §§8).

### Data & pipeline
- No Learning Dataset Pipeline / data-class table; inline SQL selection (05 §Migration).
- `data_quality` is API-completeness, not modelling quality; two formulas, not comparable (02, 04).
- Odds prices thrown away (`retainRows:false`) – no value/CLV possible (02).
- 91 % of shadow predictions made after kickoff; ~1,805 orphaned fixtures; 20 never-backfilled
  results; 36 % of scanned fixtures have only post-kickoff snapshots (02).
- `historical_twin_matches` (68k) + `historical_elo_ratings` (245k) not keyed to
  `football_matches`, never fed to the engine (02, 05).
- data_pool tier: 200/day enrichment budget but Phase-1 only admits 100 non-focus fixtures/run;
  contributes ~0 usable learning rows (avg dq 19) (05).

### Infrastructure
- 11-hour learning run on a push-to-deploy service → orphaned 11/15 times (03, 05).
- 3 job families, 3 orphan-recovery implementations, no shared lease/heartbeat primitive (05).
- Single shared DB connection, no pool (05).
- API-Football uncapped; the only guard is wired to the wrong (secondary) client; 55 %-error day
  on 2026-08-22 (05).
- Scheduled crons unverified (0 `scheduled` runs, 0 monthly reviews ever) (03, 05).
- `database.dart` is 12,240 lines (schema + ~200 queries + Lab + Control Center) (05).

### Bugs / dead code to clear as part of Phase 1
- `showPhoenixTip` hard-coded `true` regardless of `qualifiesForTip` (01).
- `c2b1942` league-aware baseline shipped with commit message "NOT YET DEPLOYED, needs backtest"
  but is live in the imported file (01).
- "Stabilität" dead field renders 0 for every football tip (04).
- Dead: `FootballFinalizationService` + `POST /finalize`; `normalized.*Strength` (inconsistent
  baselines 1.15/1.35); per-league challenger path (~500 lines); `WalkForwardStep`/`steps`;
  `minShadowSample`; `sampleSizeTier()`; orphan tables `football_final_tips`,
  `football_ai_context_jobs`; 5 zero-row dead tables (01, 03, 05).
- `match_scope='clean'` always == `'all'` (red-card coverage ≈ 0) → duplicate eval rows (03).
- `simulations` param: cron sends 10k, route default 100k, DB clamps to exactly 100k (05).

---

## What to keep (working, aligned with AN2)

- **One score matrix → all markets** (01, 03) – the core of AN2 §9–13.
- **Leakage discipline** in the Lab (03 §Leakage) – extend the one missing in-code guard.
- **Input shrinkage toward league/global priors** (01, 04) – already the §19 idea in embryo.
- **Frozen-on-publish contract** (`ON CONFLICT DO NOTHING`) – blocks silent tampering; costs a
  model-version bump per fix (accept or replace deliberately).
- **Paired bootstrap CI + "CI excludes 0" promotion gate + n≥120** (04) – a reasonable
  lucky-weekend guard; upgrade to BCa/permutation and add calibration, don't discard.
- **Additive every-boot migrations** (05) – keep the pattern; add an ordered-version check.
- **`goalAverageIfPlayed` → null for 0 games** (01) – the correct AN2 §2 handling.

---

## Decisions the rebuild plan must resolve

Consolidated from the five "open questions" sections. **Bold = needs a product/cost call from the
user before the plan can be concrete.**

1. **History strategy.** Run Phase 1 on the ~650-row live corpus with wide uncertainty and let a
   season accumulate, **or** backfill history — link `historical_twin_matches` (68k) /
   `historical_elo_ratings` (245k) to `football_leagues`/teams and use them as the training
   corpus, **or** bulk-import fixtures+stats from the provider years deep. This gates the whole
   timeline. (**user call**)
2. **xG / lineups / suspensions.** All 0 % on the current API-Football plan. Either (a) accept a
   goal-rate + team-strength engine and delete the xG scaffolding, or (b) add a provider
   (Understat / FBref / Opta) as a new ingestion path. (**user call**)
3. **Store odds prices.** Required for value, calibration-vs-market, CLV (§40). Keep the actual
   prices at snapshot time and re-poll near kickoff for a closing line. (**user call on provider
   cost / re-poll budget**)
4. **Per-league challengers: aspirational or in-scope?** 0 leagues reach 100 samples. Recommend
   Phase 1 ships global-pool-only with a **cup-vs-league flag** + **country / competition-tier
   grouping** as the finest stratification, and per-league challengers become a 2026/27-season
   data-collection track. Confirm.
5. **One match model vs 17 market champions.** Collapse `LearningMarket` (17) into one `MatchModel`
   per scope with markets derived (AN2 §9), or keep per-market champions. Current `GlobalMarketFamily`
   (4 profiles) is a halfway house.
6. **Calibration layer.** Per-market isotonic or Platt/temperature on the score-distribution
   outputs, fit on LEARNING, validated on HOLDOUT — as **one code path shared by live + Lab**
   (unlike DNB today). Where it sits in the new pipeline.
7. **Uncertainty representation.** A credible interval per market probability (Monte-Carlo over λ +
   parameter posterior) vs a scalar reliability. Must actually move value thresholds / model
   weighting, not just a badge (§22/§23). Replace `_trustScore` hand-weights.
8. **DNB / DC definition.** Freeze one (recommended: DNB = 2-class conditional) across
   `engine_replica`, `shadow_prediction_service`, `football_simulation_service` and the metrics
   column simultaneously.
9. **Learning Dataset Pipeline table.** Add `phoenix_learning_dataset` (per fixture×market:
   `data_class` production/learning/research/quarantine, feature-completeness, leakage-check,
   snapshot-ref, exclusion reason) and route the engine + challengers + `modelLabRawDataset` through
   it. Persist ineligible rows (§49 audit wants the "why excluded" record).
10. **Job infrastructure.** Move the long learning run off the web/deploy path (dedicated worker
    that doesn't redeploy on every backend push) and/or chunk it per-market. Consolidate the 3 job
    families onto one lease/heartbeat/reclaim primitive.
11. **Real walk-forward.** Implement expanding-window scoring with the already-computed `steps`, or
    rename to "chronological holdout" and drop `walkForwardStepSize`. §34/§38 need real rolling
    windows once there's enough history.
12. **Champion legitimacy.** Require every champion — including the initial global one — to pass a
    holdout backtest before `champion` status; remove the "activate by fiat" path that bypasses
    `promotionEnabled`.
13. **Metrics to add:** ECE (aggregate the existing buckets) + calibration as a promotion veto;
    per-league Brier/calibration slice of the pooled global model (§39); Brier skill score vs a
    market-implied / climatology baseline; (ROI/yield/CLV once odds are stored).
14. **API quota governance.** Confirm plan tier (Pro 7,500 vs Ultra 75,000); add a proactive daily
    budget with reservation on the main client; per-run cost estimate before a learning/enrichment
    pass. (**user call on tier**)
15. **Shadow pipeline hygiene.** Only score `predicted_before_kickoff = true`; quarantine the
    ~9,400 post-hoc rows out of every metric; wire (or delete) `minShadowSample` + a minimum shadow
    *time* window before review eligibility (§36).
16. **Orphaned-fixture reconciliation sweep** + a "finished-by-clock but not by status" monitor so
    the pool doesn't silently rot.
17. **Dead-code / dead-table cleanup** as part of Phase 1 (list in "Bugs / dead code" above) — or
    a deliberate decision to revive each feature.

---

## Suggested Phase-1 shape (for the plan – not yet decided)

1. **Learning Dataset Pipeline** (§24–32): the `phoenix_learning_dataset` table + data-class
   classifier + leakage re-check everywhere + shadow-hygiene quarantine. Foundation for everything.
2. **Shared Match-State object** (§11): attack/defence strength (from the existing team-strength
   IPF fit, pooled-global), home-advantage term, league baseline, tempo, and an explicit
   uncertainty (sample size / coverage / fallback). One object, consumed by the score-matrix step.
3. **Goal-model comparison** (§15): independent Poisson vs Dixon-Coles vs bivariate Poisson vs
   NegBin, as candidates **for the champion**, scored on the ~650-row holdout with wide CIs.
4. **Calibration layer** (§14): per-market, shared live+Lab, fit on LEARNING / validated on HOLDOUT.
5. **Uncertainty + data-quality wiring** (§21–23): numeric uncertainty that widens intervals and
   moves value thresholds; unify `data_quality` onto one scale that consumes sample size / recency /
   opponent quality; keep a separate raw "API completeness" number for ops.
6. **Promotion path, run end-to-end once** (§42–46): champion legitimacy (no fiat), calibration
   veto, per-league slice of the global model, real monthly review producing a row.
7. **Infra**: worker service for the learning run; API budget governance; job-primitive
   consolidation; orphaned-fixture sweep.
8. **Full daily scan + §49 audit**, fix findings, re-test — the gate to Phase 2.

Per-league challengers (§5–8) are explicitly **out of near-term scope** – reopened once a league
accumulates a season of leakage-safe snapshots.
