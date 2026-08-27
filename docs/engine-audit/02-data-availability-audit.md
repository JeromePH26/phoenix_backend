# 02 – Data Availability Audit (what PHÖNIX actually has)

Read-only audit against the Railway production Postgres, 2026-08-27.
Method: temp SELECT-only Dart script (`bin/_audit_data_tmp*.dart`, modelled on
`bin/phoenix_model_lab_eligibility_probe.dart`, deleted after use). Builds on the
eligibility probe (commits c23c8ff / d07b685 / 1673ee5); does not re-derive it.

Scope tables: `football_matches`, `football_phase_two_results` (holds the
`availability` JSONB snapshot), `football_engine_inputs` (holds `normalized_input`),
`football_leagues`, `api_sports_daily_usage`, `phoenix_shadow_predictions`,
`phoenix_model_versions`, `historical_twin_matches`, `historical_elo_ratings`,
`football_live_events`.

---

## TL;DR

1. **PHÖNIX has ~6 weeks of history.** Every finished match in the DB kicked off
   between **2026-07-18 and 2026-08-26** (n = 2,224 finished-with-result of 4,304
   stored). `season` is 2026 for 898 of 973 settled+scanned fixtures. There is **no
   multi-season history, no historical team strength**, and the window is a single
   season-phase: European cup qualifiers + Nordic summer leagues, with the big-5
   leagues only 1–2 matchdays in.

2. **Genuinely usable learning rows today ≈ 650.** One row per fixture (latest
   pre-kickoff `football_engine_inputs` snapshot):
   1,385 fixtures have any snapshot → 888 have a pre-kickoff snapshot → 758 of
   those are settled → **655 pass the current `data_quality >= 40` gate** (630
   focus / 22 watchlist / 0 data_pool / 3 blocked). At the old `>= 50` gate it is
   557; at `>= 60` it is 474. The eligibility probe's 554/906 is the `>=50` slice.

3. **xG, xGA, lineups, suspensions, coach data, shots, half-time score: 0%
   coverage. Not "sometimes" – never.** `coverageForFixture` hard-codes
   `realXgAvailable = false` / `lineups = false`; `football_matches.raw_json`
   carries no `statistics` / `lineups` / `events` / `score` (0 of 4,304).

4. **Odds are stored as a presence bit only.** `/odds` is fetched with
   `retainRows: false`, so the snapshot keeps `odds: true/false` + `oddsCount` and
   **discards every price**. No opening odds values, no closing odds, no CLV
   possible. "Odds coverage 95%" means "a bookmaker line existed", not "we have it".

5. **`data_quality` is a weighted count of which API endpoints returned rows**
   (0–~91 on the focus path, 0–100 on the background path – two different
   formulas), not a measure of statistical adequacy. It ignores sample size
   (beyond a binary "≥3 games"), recency, whether odds values were kept, and
   opponent quality.

6. **No league can support a per-league model.** Only **2 leagues** have ≥50
   eligible (dq≥40) samples – UEFA Conference League (~70) and the English League
   Cup (~54), both cross-league knockout competitions. **0 leagues reach 100.**
   The spec's league-adaptation thresholds (100 / 300 / 600) are all unreachable;
   everything is global-pool-only for the foreseeable future.

7. **The shadow-mode track is mostly retro-fitted.** Of ~10,300 settled
   `phoenix_shadow_predictions`, **9,401 were generated *after* kickoff**; only
   **915 are genuinely pre-kickoff**. `phoenix_model_versions` has 17 markets ×
   (1 champion + 9 challengers + 1 retired), **all global, zero per-league**.

8. **Pool hygiene is mostly OK on the learning slice, weak on the raw pool.**
   0 duplicate fixtures, 0 invalid timestamps. But ~1,805 matches with a past
   kickoff are stuck in a non-terminal status (1,668 still `NS`), 20 finished
   fixtures never got a result backfilled (all July), 36% of scanned fixtures
   have *only* post-kickoff snapshots, and `football_live_events` is empty (no
   red-card-minute data → spec §26 distortion diagnostics have nothing to run on).

---

## Feature coverage matrix

"Available pre-match" = present in the latest `football_phase_two_results.availability`
snapshot whose `created_at < kickoff_utc`, for **settled** fixtures.

### By collection tier

| Feature | focus (n≈733) | watchlist (n≈48) | data_pool (n≈40) |
|---|---:|---:|---:|
| Full-time goals (outcome) | 100% (filter) | 100% | 100% |
| Recent form, home ≥3 of last 5 | 95% | 52% | 5% |
| Recent form, away ≥3 of last 5 | 95% | 52% | 5% |
| H2H (last 5) | 78% | 90% | 65% |
| League table / standings | 57% | 38% | 0% |
| Team season stats present (raw flag) | ~78% | ~33% | ~53% |
| Team season stats **usable** (≥3 games), home | 66% | 27% | 0% |
| Team season stats **usable** (≥3 games), away | 68% | 23% | 0% |
| Injuries | 30% | 0% | 0% |
| Odds — **presence bit only, no prices** | 95% | 0% | 0% |
| Opening odds as values | 0% | 0% | 0% |
| Closing odds | 0% | 0% | 0% |
| xG / xGA | 0% | 0% | 0% |
| Lineups | 0% | 0% | 0% |
| Suspensions | 0% | 0% | 0% |
| Coach data | 0% | 0% | 0% |
| Half-time score / shots / match stats | 0% (not stored anywhere) | – | – |
| Historical team strength (multi-season) | 0% (only 6 weeks of history exist) | – | – |
| Opponent-strength input | derived only (league 400-day goal avg + team goal avgs); no ratings table | | |
| avg `data_quality` (settled, pre-match) | **65.8** | 51.8 | 18.9 |

Notes:
- data_pool + watchlist are enriched by `FootballBackgroundEnrichmentService` on a
  fixed daily budget (200 fixtures/day). It uses a **different** `_quality`
  formula and **saves the raw, un-sanitized `availability`** (no ≥3-game gate), so
  their `data_quality` is not comparable to focus and they contribute ~0 eligible
  learning rows (data_pool avg dq 19).
- "Recent form" is saison-übergreifend (`/fixtures?last=5`, no season filter), so
  after the July/Aug season rollover it mixes league + cup + friendly results.

### By top leagues (settled, pre-match, focus unless noted) — coverage %, and avg dq

| League | n | standings | odds(bit) | injuries | h2h | team-stats usable | avg dq |
|---|---:|---:|---:|---:|---:|---:|---:|
| UEFA Europa Conference League | 93 | 0 | 92 | 0 | 40 | 59 | 48 |
| League Cup (EFL) | 58 | 0 | 100 | 0 | 88 | 29 | 47 |
| UEFA Champions League | 48 | 0 | 98 | 25 | 52 | 46 | 50 |
| Major League Soccer | 43 | 100 | 100 | 100 | 100 | 100 | 91 |
| UEFA Europa League | 38 | 0 | 100 | 0 | 37 | 37 | 44 |
| Allsvenskan (SWE) | 31 | 90 | 100 | 100 | 100 | 90 | 86 |
| Ykkönen (FIN) | 26 | 100 | 100 | 0 | 100 | 100 | 81 |
| 1. Division (DEN) | 26 | 100 | 96 | 0 | 100 | 100 | 80 |
| DFB Pokal | 24 | 0 | 88 | 0 | 46 | 0 | 41 |
| Jupiler Pro League (BEL) | 24 | 92 | 92 | 0 | 92 | 83 | 72 |
| Veikkausliiga (FIN) | 24 | 96 | 100 | 0 | 100 | 96 | 79 |
| Championship (ENG) | 23 | 96 | 100 | 100 | 96 | 74 | 84 |
| Eredivisie (NED) | 23 | 100 | 100 | 96 | 100 | 83 | 87 |
| Primeira Liga (POR) | 23 | 91 | 91 | 0 | 87 | 78 | 71 |
| Coppa Italia | 20 | 0 | 75 | 0 | 55 | 25 | 33 |
| 3. Liga (GER) | 20 | 95 | 95 | 0 | 85 | 65 | 69 |
| Segunda División (ESP) | 20 | 85 | 85 | 0 | 80 | 60 | 62 |
| Eliteserien (NOR) | 20 | 95 | 95 | 95 | 95 | 95 | 87 |
| 2. Bundesliga | 18 | 100 | 100 | 0 | 100 | 72 | 74 |
| Süper Lig (TUR) | 17 | 82 | 82 | 82 | 76 | 71 | 72 |

Pattern: coverage and dq are high for settled domestic leagues that were mid-season
in July–Aug (Nordics, Eredivisie, MLS, Championship). They are low for the
**cup/knockout competitions that dominate the volume** (Conference/Europa/Champions
League, League Cup, DFB Pokal, Coppa Italia): standings 0% (no single table),
injuries ~0%, dq in the 40s. Injuries coverage is essentially binary per country:
~100% for MLS/Championship/Eredivisie/Eliteserien/Allsvenskan/Süper Lig, ~0%
everywhere else.

### By season

All settled scanned fixtures: 898 season 2026, 4 season 2025, 71 season 0 (missing /
bad season on the fixture – almost all cup ties). There is not enough of any prior
season to break coverage down by season meaningfully.

---

## data_quality score: what it actually measures

There is **no `data_quality` service**. It is computed inline in two places from the
`availability` map, and consumed downstream (`football_market_selection_service`
weights it 30/100 into its selection score; `football_finalization_service` gates
publish at `>= 50`; Model Lab gates learning at `>= 40`).

### Focus path — `FootballPhaseTwoScanService._quality` (on sanitized availability)

| Component | Points | Condition |
|---|---:|---|
| base | +5 | always |
| standings | +15 | `standings == true` |
| home recent form | 0…+6 | `round(clamp(homeRecentCount,0,5)/5 * 6)` |
| away recent form | 0…+6 | `round(clamp(awayRecentCount,0,5)/5 * 6)` |
| odds | +15 | `odds == true` (bit only – prices already discarded) |
| injuries | +10 | `injuries == true` |
| h2h | +10 | `h2h == true` |
| home team stats **usable** | +12 | raw stat flag **and** homePlayed ≥ 3 |
| away team stats **usable** | +12 | raw stat flag **and** awayPlayed ≥ 3 |
| real xG | +5 | `realXgAvailable == true` → **never true**, so dead |
| both teams 0 games played | −5 | penalty |

Clamp 0–100. Effective max ≈ **91** (the +5 xG term can never fire).

### Background path — `FootballBackgroundEnrichmentService._quality` (on RAW availability)

base 5 · standings +20 · (homeRecent&&awayRecent) +15 · h2h +15 ·
(homeTeamStatistics&&awayTeamStatistics, **raw flags, no ≥3-game gate**) +25 ·
injuries +10 · odds +10 → max 100.

Consequences:
- **Not comparable across tiers.** A watchlist/data_pool fixture and a focus fixture
  with identical underlying data get different scores, on different scales, and the
  background one is scored against un-sanitized flags.
- **It is an "API completeness" score, not a "modelling input quality" score.** It
  does not look at: how many games the averages are based on (beyond binary ≥3),
  how recent anything is, whether standings position is statistically meaningful
  this early in a season, whether odds *values* were retained (they never are),
  opponent quality, or home/away split depth.
- The spec (§22) wants data_quality to drive confidence / uncertainty / value
  thresholds / model weighting. Today it only drives two hard gates and one linear
  term in tip selection.

### Distribution (production)

`football_phase_two_results.data_quality`, all 2,940 rows:

| bucket | 0 | 10 | 20 | 30 | 40 | 50 | 60 | 70 | 80 | 90 | 100 |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| n | 43 | 39 | 59 | 236 | 258 | 246 | 329 | 175 | 751 | 793 | 11 |

`football_engine_inputs.data_quality`, all 2,499 rows: 36 / 18 / 37 / 144 / 231 /
239 / 308 / 164 / 641 / 678 / 3 across the same buckets. The 80–90 mass is
dominated by *upcoming* fixtures (odds present, +15/+20). For **settled focus**
fixtures the mean is 65.8, median 76; 637 ≥ 40, 536 ≥ 50, 457 ≥ 60.

`sourceType` in `normalized_input` (2,499 engine inputs): `goal_rates_not_xg`
1,856 (74%), **`safe_baseline_fallback` 343 (14%) – no usable team goal averages,
pure league prior**, `goal_rates_not_xg_thin_sample_shrunk` 252 (10%), legacy
gemini rows 48.

---

## Pool hygiene issues (quantified)

| Issue | Count | Notes |
|---|---:|---|
| Total `football_matches` | 4,304 | kickoff 2026-07-17 … 2026-08-27 |
| Finished with result | 2,224 | kickoff 2026-07-18 … 2026-08-26 (≈6 weeks) |
| Duplicate fixtures (same league/home/away/day) | **0** | clean |
| Invalid timestamps (kickoff <2015 or >now+400d) | **0** | clean |
| Finished status (`FT`/`AET`) but goals NULL | **20** | all July; corrupt/void |
| Past kickoff (>36h) still non-terminal | **~1,805** | 1,668 `NS`, 49 `1H`, 38 `2H`, 35 `HT`, 15 `TBD`, … – orphaned, never status-updated |
| Finished, kickoff >3d ago, still no result | **20** | all 2026-07; never backfilled. Aug is clean (0 in last 14d) |
| Name-pattern non-league comps in raw pool | friendlies ~726, youth ~194, reserve ~102, cup ~429, women ~105 | ILIKE heuristic, over-counts; raw pool only |
| …of those, in the pre-match learning pool (n=888) | friendlies 2, youth 2, women 10, **cup 115 (13%)** | friendlies/youth effectively filtered; **cup competitions are a structural part of the learning pool** and mix opponent strength across leagues |
| Engine-input rows created **at/after kickoff** | 614 of 2,488 (25%) | 55 "during match", 172 "3–24h after", 387 ">24h after" – leak risk, excluded by `created_at < kickoff_utc` in `modelLabRawDataset` |
| Fixtures with **only** post-kickoff snapshots | **497 of 1,385 (36%)** | unusable for learning |
| Fixtures with ≥2 engine-input snapshots | 825 of 1,385 (up to 7) | re-scan churn; `DISTINCT ON … created_at DESC` picks last pre-kickoff |
| `football_live_events` rows | **0** | no goal/red-card minute data anywhere → spec §26 red-card distortion score has no input; `earliest_red_card_minute` LATERAL join always NULL |
| `phoenix_shadow_predictions` settled but **made after kickoff** | **9,401 of ~10,316 (91%)** | only 915 settled predictions are genuinely pre-kickoff |
| API-Football error spikes | 2026-08-22: 470 err / 847 req (55%); 08-23: 207 / 1,785 (12%) | recovered 08-25/26 (12 err / 4,629 req). Main API-Football usage is now tracked in `api_sports_daily_usage` (previously only side sports) |
| `snapshot_created_at` vs `kickoff_utc` | pre-kickoff snapshots: mostly 2–24h before (1,687 rows), 181 in last 0–2h, 6 at 1–7d | tight, healthy window when it exists |

External assets present but **excluded from learning** by `FeatureWhitelist`
(AI/twin/elo paths are never whitelisted): `historical_twin_matches` 68,000 rows
(15,108 matched to a PHÖNIX league), `historical_elo_ratings` 245,033 rows. These
are Football-Data / ClubElo imports → RESEARCH class only.

---

## Usable learning data today

Funnel (one row per fixture = latest `football_engine_inputs` snapshot before kickoff):

| Stage | focus | watchlist | data_pool | blocked | total |
|---|---:|---:|---:|---:|---:|
| Pre-kickoff snapshot exists | 775 | 25 | 85 | 3 | **888** |
| … and match is settled | 718 | 25 | 12 | 3 | **758** |
| … and `data_quality ≥ 40` (current gate) | 630 | 22 | 0 | 3 | **655** |
| … and `data_quality ≥ 50` (old gate) | 532 | 22 | 0 | 3 | **557** |
| … and `data_quality ≥ 60` | 453 | 15 | 0 | 3 | **471** |

(The eligibility probe's "best snapshot" tie-break variant yields 652 / 554 for the
≥40 / ≥50 lines – same picture.)

By kickoff month (settled, dq≥40): **2026-07 → 29**, **2026-08 → 626**. That is the
entire learning corpus: ~650 matches, one 6-week window, no winter/season-end/
season-start variation, cup-heavy, Nordic-summer-heavy.

Against the spec's own gates this is far below viable:
- `minLearningEligibleSamples` = 50 **per league × market** → only met globally.
- Walk-forward min training window 60, holdout fraction 0.20, min holdout 40, min
  validation 40, min shadow 30, min promotion 120: a **global** model can just
  about run one thin walk-forward pass; a per-league model cannot.
- Genuine pre-kickoff shadow predictions for out-of-sample evaluation: **~915
  total across all 17 markets** (~54 fixtures' worth per market).

Data-class recommendation (spec §26):
- **PRODUCTION**: focus tier, settled or upcoming, dq ≥ 60, standings + usable team
  stats present, non-cup — ≈ 300–450 historical fixtures.
- **LEARNING**: focus + watchlist, pre-kickoff snapshot, settled, dq ≥ 40 — ≈ 650
  fixtures (the number above). Cup ties included but flagged.
- **RESEARCH / QUARANTINE**: data_pool tier (dq ~19, ~0 usable), the 497
  post-kickoff-only fixtures, the 20 corrupt results, all `historical_twin` /
  `historical_elo` data, and any watchlist league with <20 samples.

---

## Which leagues can support per-league models

Eligible (settled, pre-match, dq≥40) samples per league — top of the list:

| League | eligible dq≥40 | eligible dq≥50 | avg dq | kickoff span |
|---|---:|---:|---:|---|
| UEFA Europa Conference League | 70 | 46 | 51 | 07-22 … 08-27 |
| League Cup (EFL) | 54 | 25 | 47 | 08-01 … 08-27 |
| Major League Soccer | 40 | 40 | 91 | 08-15 … 08-23 |
| UEFA Champions League | 36 | 25 | 52 | 07-21 … 08-26 |
| Allsvenskan | 28 | 28 | 91 | 08-01 … 08-23 |
| UEFA Europa League | 27 | 12 | 47 | 08-04 … 08-27 |
| Ykkönen | 26 | 26 | 81 | 08-01 … 08-23 |
| 1. Division (DEN) | 26 | 26 | 80 | 08-01 … 08-26 |
| Veikkausliiga | 23 | 23 | 81 | 08-01 … 08-23 |
| Championship | 23 | 22 | 84 | 08-14 … 08-23 |
| Eredivisie | 23 | 23 | 87 | 08-07 … 08-23 |
| Jupiler Pro League | 22 | 22 | 72 | 08-07 … 08-23 |
| Primeira Liga | 21 | 21 | 71 | 08-07 … 08-23 |
| Eliteserien / 3. Liga / 2. Bundesliga | 19 / 19 / 18 | … | 87 / 69 / 74 | Aug |
| La Liga / Segunda / Süper Lig | 15 / 17 / 14 | | 83 / 62 / 72 | mid-Aug on |
| Bundesliga / Serie A / Ligue 1 / Premier League | 8 / 8 / 9 / 9 | | ~87 | 08-21 … 08-23 |

Leagues with ≥50 eligible (dq≥40) samples: **2** (Conference League, League Cup).
With ≥100: **0**. With ≥200/300/600: **0**.

Conclusion:
- **No per-league model is viable now**, and none will be for months. Even the two
  leaders are cross-league knockout competitions – the *worst* candidates for a
  "league identity" model (no stable table, opponents from 20+ leagues, injuries
  ~0%, dq in the 40s).
- **Global pool only.** The Global Engine should train on the full ~650-row
  LEARNING set, with a **cup-vs-league flag** and a **country / competition-tier
  grouping** as the finest usable stratification, not per-league.
- The healthiest *domestic* leagues for later per-league challengers (high dq, high
  coverage, mid-season depth in this window) are MLS, Allsvenskan, Eliteserien,
  Eredivisie, Championship, Veikkausliiga, Ykkönen, 1. Division (DEN) — but all
  sit at 20–40 samples; they need a full season before a challenger is meaningful.
- The big-5 leagues currently have 8–15 usable samples each. A per-league
  Bundesliga/PL/LaLiga challenger is a 2026/27-season-long data-collection task
  before it can even be shadow-evaluated.

---

## Open questions for the rebuild plan

1. **xG is a hard zero.** API-Football (current plan) returns none, nothing is
   stored, and `realXgAvailable` is hard-coded `false`. The spec's whole
   "xG/xGA falls vorhanden" branch is dead code today. Decide: (a) accept a
   goal-rate-only engine and delete the xG scaffolding, or (b) add a provider
   (Understat/FBref/Opta) as a new ingestion path before Phase 1 modelling.
   Same question for **lineups** and **suspensions** (both 0%).

2. **Odds prices are thrown away.** `/odds` is fetched with `retainRows: false`.
   To do value, calibration-vs-market, or CLV (spec §40), the pipeline must
   **store the actual prices** at snapshot time, and ideally re-poll near kickoff
   for a closing line. Until then "market comparison" has no market.

3. **`data_quality` needs to become a real modelling signal.** Unify the two
   formulas onto one scale, make it consume sample size / recency / stored-odds /
   opponent quality, and wire it into confidence + uncertainty + value thresholds
   (spec §22/§23). Keep a separate raw "API completeness" number for ops.

4. **Six weeks of history caps everything.** Walk-forward, holdout, temporal
   stability (spec §34/§35/§38) cannot be done honestly yet. Is the plan to
   backfill history via `import_historical_twins` + a bulk fixture/stats import,
   or to run Phase 1 on the thin live corpus and accept wide uncertainty until a
   season accumulates? This decision gates the whole timeline.

5. **Shadow predictions are 91% retro-fitted.** Before any champion/challenger
   comparison is trusted, the shadow pipeline must only ever score predictions
   whose `predicted_before_kickoff = true`, and the ~9,400 post-hoc rows should be
   quarantined out of every metric.

6. **Cup competitions are ~13% of the learning pool and >⅓ of the focus
   whitelist.** They break "league table position", "opponent = same league", and
   home/away assumptions. Decide whether the Global Engine treats them with a
   dedicated competition-context feature, or whether they move to a separate pool.

7. **~1,805 orphaned fixtures** (past kickoff, still `NS`/`1H`/`HT`) and **20
   never-backfilled results**. A settlement/status-reconciliation sweep is needed
   so the pool doesn't silently rot; add a monitor for "finished-by-clock but not
   by status".

8. **data_pool tier contributes ~0 usable rows** (avg dq 19, 0 eligible) despite a
   200-fixture/day enrichment budget and being counted as a learning source since
   2026-08-25. Either fix background enrichment to fetch enough to clear dq≥40, or
   stop feeding data_pool into `modelLabRawDataset` and label it RESEARCH.

9. **`football_matches` is a thin record** (teams, kickoff, status, final goals –
   no half-time, no shots, no stats). Every richer signal lives only in the
   per-scan `availability` JSONB. If the engine ever needs match-level detail for
   historical fixtures it was not scanned for pre-kickoff, that data does not
   exist and cannot be reconstructed.

10. **`football_live_events` is empty**, so red-card timing / early-vs-late
    distortion (spec §26, `redCardEarlyMinute`/`redCardLateMinute` config) has no
    data. Either start capturing events or drop that diagnostic from Phase 1.
