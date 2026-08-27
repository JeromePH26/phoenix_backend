import '../config/model_lab_config.dart';
import '../database/database.dart';
import 'feature_whitelist.dart';
import 'global_goals_v1_engine.dart';
import 'learning_dataset_classifier.dart';
import 'learning_market.dart';
import 'learning_sample.dart';

/// Baut leakage-sichere Learning-Datensätze aus gespeicherten PHÖNIX-Daten
/// (Section 16: NUR eigene PHÖNIX-Daten, keine externen/Twin-Daten) und
/// führt den Eligibility-Audit für den Dry Run (Section 89/90) durch.
class LearningDatasetBuilder {
  LearningDatasetBuilder({required this.database, required this.config});

  final PhoenixDatabase database;
  final ModelLabConfig config;

  /// M2 (AN2 §24-32): klassifiziert jeden gespeicherten LIVE-Pre-Match-
  /// Snapshot x Markt in `phoenix_learning_dataset` (production / learning /
  /// research / quarantine) und persistiert das Ergebnis. Wird als
  /// Kopf-Schritt eines Learning Runs aufgerufen, damit `buildSamples*`
  /// anschließend über `data_class` filtern kann. Idempotent.
  Future<Map<String, int>> classifyLiveDataset({bool write = true}) async {
    final classifier = LearningDatasetClassifier(
      minDataQuality: config.minDataQuality,
    );
    final db = await database.connection();

    final rows = await db.execute('''
      SELECT DISTINCT ON (ei.fixture_id)
        ei.fixture_id,
        ei.league_id,
        ei.data_quality,
        ei.created_at AS snapshot_created_at,
        ei.phase_two_scan_run_id,
        m.kickoff_utc,
        m.status,
        m.home_goals,
        m.away_goals,
        fl.collection_tier,
        fl.league_name,
        fl.competition_level,
        p2.availability
      FROM football_engine_inputs ei
      LEFT JOIN football_matches m ON m.id = ei.fixture_id
      LEFT JOIN football_leagues fl ON fl.league_id = ei.league_id
      LEFT JOIN LATERAL (
        SELECT availability FROM football_phase_two_results r
        WHERE r.fixture_id = ei.fixture_id
        ORDER BY r.scan_run_id DESC LIMIT 1
      ) p2 ON TRUE
      ORDER BY ei.fixture_id,
        CASE WHEN m.kickoff_utc IS NOT NULL AND ei.created_at < m.kickoff_utc
             THEN 0 ELSE 1 END,
        ei.created_at DESC
    ''');

    // Pro Liga die grobe Zahl sonst-eligibler Samples (für die
    // "zu dünne Beobachtungsliga"-Regel).
    final leagueCounts = <String, int>{};
    for (final row in rows) {
      final m = row.toColumnMap();
      final tier = m['collection_tier']?.toString();
      final finished = PhoenixDatabase.modelLabFinishedMatchStatuses
          .contains(m['status']?.toString());
      final hasGoals = m['home_goals'] != null && m['away_goals'] != null;
      final ko = m['kickoff_utc'];
      final snap = m['snapshot_created_at'];
      final preMatch = ko is DateTime && snap is DateTime && snap.isBefore(ko);
      final dq = (m['data_quality'] as num?)?.toInt() ?? 0;
      if ((tier == 'focus' || tier == 'watchlist') &&
          finished &&
          hasGoals &&
          preMatch &&
          dq >= config.minDataQuality) {
        final lg = m['league_id']?.toString() ?? '';
        leagueCounts[lg] = (leagueCounts[lg] ?? 0) + 1;
      }
    }

    final now = DateTime.now().toUtc();
    final classCounts = <String, int>{
      'production': 0,
      'learning': 0,
      'research': 0,
      'quarantine': 0,
    };
    final datasetRows = <LearningDatasetRow>[];

    for (final row in rows) {
      final m = row.toColumnMap();
      final fixtureId = m['fixture_id']?.toString();
      if (fixtureId == null) continue;
      final leagueId = m['league_id']?.toString();
      final dq = (m['data_quality'] as num?)?.toInt() ?? 0;
      final ko = m['kickoff_utc'] is DateTime
          ? m['kickoff_utc'] as DateTime
          : null;
      final snap = m['snapshot_created_at'] is DateTime
          ? m['snapshot_created_at'] as DateTime
          : null;
      final status = m['status']?.toString();
      final finished =
          PhoenixDatabase.modelLabFinishedMatchStatuses.contains(status);
      final hasGoals = m['home_goals'] != null && m['away_goals'] != null;
      final avail = m['availability'] is Map
          ? m['availability'] as Map
          : const <Object?, Object?>{};
      final hasStandings = avail['standings'] == true ||
          avail['standings']?.toString() == 'true';
      final hasUsableTeamStats =
          avail.containsKey('homeGoalsForAverageHome') &&
              avail.containsKey('awayGoalsForAverageAway');
      final isCup = _isCupCompetition(
        m['league_name']?.toString() ?? '',
        (m['competition_level'] as num?)?.toInt(),
      );
      final scanRunId = m['phase_two_scan_run_id'];
      final snapshotRef = scanRunId != null ? '$scanRunId:$fixtureId' : null;

      final result = classifier.classifyLive(
        collectionTier: m['collection_tier']?.toString(),
        finishedStatus: finished,
        hasGoals: hasGoals,
        kickoff: ko,
        snapshotCreatedAt: snap,
        dataQuality: dq,
        isCup: isCup,
        hasStandings: hasStandings,
        hasUsableTeamStats: hasUsableTeamStats,
        leagueEligibleCount: leagueCounts[leagueId ?? ''] ?? 0,
        now: now,
      );
      classCounts[result.dataClass] =
          (classCounts[result.dataClass] ?? 0) + 1;

      for (final market in LearningMarket.values) {
        datasetRows.add((
          fixtureId: fixtureId,
          market: market.key,
          source: 'live',
          dataClass: result.dataClass,
          featureCompleteness: null,
          leakageChecked: true,
          leakageResult: result.leakageResult,
          snapshotRef: snapshotRef,
          dataQuality: dq,
          isCup: isCup,
          excludedReason: result.excludedReason,
          leagueId: leagueId,
          kickoff: ko,
        ));
      }
    }

    if (write) {
      await database.upsertLearningDatasetRows(datasetRows);
    }
    return {
      'fixtures': rows.length,
      'rows': datasetRows.length,
      ...classCounts,
    };
  }

  static bool _isCupCompetition(String leagueName, int? competitionLevel) {
    final n = leagueName.toLowerCase();
    const patterns = [
      'cup', 'pokal', 'coupe', 'copa ', 'coppa', 'taça', 'taca', 'beker',
      'trophy', 'shield', 'supercopa', 'supercoppa', 'super cup', 'supercup',
      'champions league', 'europa league', 'conference league', 'libertadores',
      'sudamericana', 'playoff', 'play-off', 'promotion', 'relegation',
    ];
    if (patterns.any(n.contains)) return true;
    return competitionLevel == null || competitionLevel == 0;
  }

  /// Section 19/21: liefert alle leakage-sicheren Samples für eine (optional
  /// auf eine Liga eingeschränkte) Abfrage, chronologisch nach Kickoff
  /// sortiert (Voraussetzung für Walk-Forward, Section 30/31).
  Future<List<LearningSample>> buildSamples({
    String? leagueId,
    bool includeAllTiers = false,
  }) async {
    final rows = await database.modelLabRawDataset(
      leagueId: leagueId,
      minDataQuality: config.minDataQuality,
      includeAllTiers: includeAllTiers,
      useDatasetClassFilter: !includeAllTiers,
    );
    final phaseTwoByFixture =
        await _phaseTwoDataByFixture(includeAllTiers: includeAllTiers);
    return _samplesFromRows(rows, phaseTwoByFixture);
  }

  /// Lädt den gemeinsamen, leakage-sicheren Rohdatensatz genau einmal und
  /// gruppiert ihn anschließend nach Liga. Ein Learning-Run bewertet viele
  /// Märkte auf denselben Fixtures; ohne diesen Batch-Pfad wurde derselbe
  /// Datenbank-Scan bisher für jeden Markt erneut ausgeführt.
  ///
  /// [includeAllTiers] ist ausschließlich für die schreibgeschützte
  /// Offline-Gewichtsanalyse (`bin/phoenix_model_lab_weight_search.dart`)
  /// gedacht - siehe `PhoenixDatabase.modelLabRawDataset`.
  Future<Map<String, List<LearningSample>>> buildSamplesByLeague({
    bool includeAllTiers = false,
  }) async {
    final rows = await database.modelLabRawDataset(
      minDataQuality: config.minDataQuality,
      includeAllTiers: includeAllTiers,
      useDatasetClassFilter: !includeAllTiers,
    );
    final phaseTwoByFixture =
        await _phaseTwoDataByFixture(includeAllTiers: includeAllTiers);
    final grouped = <String, List<LearningSample>>{};
    for (final sample in _samplesFromRows(rows, phaseTwoByFixture)) {
      grouped.putIfAbsent(sample.leagueId, () => <LearningSample>[])
          .add(sample);
    }
    return grouped;
  }

  /// Section GLOBAL_GOALS_V1 / GlobalMarketEngine: liefert für jedes Fixture
  /// mit einem leakage-sicheren Phase-2-Snapshot vor dem Kickoff sowohl die
  /// vorab berechnete GLOBAL_GOALS_V1-Torerwartung (fester Preset, ein
  /// Feature-Set) als auch die Rohdaten für `GlobalMarketEngine` (mehrere
  /// Marktfamilien x Hypothesis-Varianten - dafür lohnt sich keine
  /// Vorab-Berechnung, siehe `LearningSample.globalMarketAvailability`).
  /// Ein Datenbank-Scan für beide statt zwei getrennte.
  Future<Map<String, _PhaseTwoSampleData>> _phaseTwoDataByFixture({
    bool includeAllTiers = false,
  }) async {
    final rows = await database.modelLabGlobalGoalsV1Dataset(
      includeAllTiers: includeAllTiers,
    );
    final result = <String, _PhaseTwoSampleData>{};
    for (final row in rows) {
      final fixtureId = row['fixture_id']?.toString();
      final availabilityRaw = row['availability'];
      if (fixtureId == null || availabilityRaw is! Map) continue;
      // Belt-and-braces: die SQL-Quelle filtert bereits
      // `p.created_at < m.kickoff_utc`, aber der Phase-2-Pfad (GG1 /
      // GlobalMarket / TeamStrength) hatte diese Zweitprüfung bisher als
      // einziger nicht in Dart (docs/engine-audit/03). Ein Snapshot, der
      // nicht sicher vor dem Anpfiff liegt, fliegt hier raus.
      final snap = _dateTime(row['snapshot_created_at']);
      final kickoff = _dateTime(row['kickoff_utc']);
      if (snap == null || kickoff == null || !snap.isBefore(kickoff)) continue;
      final availability = Map<String, Object?>.from(availabilityRaw);
      final homeTeamId = row['home_team_id']?.toString() ?? '';
      final awayTeamId = row['away_team_id']?.toString() ?? '';
      final leagueAvgHome = _double(row['league_avg_home_goals']);
      final leagueAvgAway = _double(row['league_avg_away_goals']);

      final v1 = GlobalGoalsV1Engine.compute(
        availability: availability,
        homeTeamId: homeTeamId,
        awayTeamId: awayTeamId,
        leagueAvgHomeGoalsPerGame: leagueAvgHome,
        leagueAvgAwayGoalsPerGame: leagueAvgAway,
      );

      result[fixtureId] = _PhaseTwoSampleData(
        goalsV1Home: v1.expectedHome,
        goalsV1Away: v1.expectedAway,
        availability: availability,
        homeTeamId: homeTeamId,
        awayTeamId: awayTeamId,
        leagueAvgHomeGoals: leagueAvgHome,
        leagueAvgAwayGoals: leagueAvgAway,
      );
    }
    return result;
  }

  List<LearningSample> _samplesFromRows(
    List<Map<String, Object?>> rows,
    Map<String, _PhaseTwoSampleData> phaseTwoByFixture,
  ) {
    final samples = <LearningSample>[];
    for (final row in rows) {
      final sample = _rowToSample(row, phaseTwoByFixture);
      if (sample == null) continue;
      // Section 19: defensive Zweitprüfung, auch wenn die SQL-Abfrage
      // bereits vorfiltert. Ein Sample, dessen Snapshot nicht sicher vor dem
      // Kickoff liegt, wird NIEMALS als Learning-eligible verwendet.
      if (!sample.hasValidSnapshotTiming) continue;
      samples.add(sample);
    }

    samples.sort((a, b) => a.kickoff.compareTo(b.kickoff));
    return samples;
  }

  LearningSample? _rowToSample(
    Map<String, Object?> row,
    Map<String, _PhaseTwoSampleData> phaseTwoByFixture,
  ) {
    final fixtureId = row['fixture_id']?.toString();
    final leagueId = row['league_id']?.toString();
    final kickoff = _dateTime(row['kickoff_utc']);
    final snapshotCreatedAt = _dateTime(row['snapshot_created_at']);
    final homeGoals = _int(row['home_goals']);
    final awayGoals = _int(row['away_goals']);
    final dataQuality = _int(row['data_quality']);
    final normalizedInput = row['normalized_input'];

    if (fixtureId == null ||
        leagueId == null ||
        kickoff == null ||
        snapshotCreatedAt == null ||
        homeGoals == null ||
        awayGoals == null ||
        dataQuality == null ||
        normalizedInput is! Map) {
      return null;
    }

    final features = FeatureWhitelist.extract(
      Map<String, Object?>.from(normalizedInput),
    );
    final phaseTwo = phaseTwoByFixture[fixtureId];

    return LearningSample(
      fixtureId: fixtureId,
      leagueId: leagueId,
      kickoff: kickoff,
      snapshotCreatedAt: snapshotCreatedAt,
      dataQuality: dataQuality,
      features: features,
      homeGoals: homeGoals,
      awayGoals: awayGoals,
      earliestRedCardMinute: _int(row['earliest_red_card_minute']),
      globalGoalsV1ExpectedHome: phaseTwo?.goalsV1Home,
      globalGoalsV1ExpectedAway: phaseTwo?.goalsV1Away,
      globalMarketAvailability: phaseTwo?.availability,
      globalMarketHomeTeamId: phaseTwo?.homeTeamId,
      globalMarketAwayTeamId: phaseTwo?.awayTeamId,
      globalMarketLeagueAvgHomeGoals: phaseTwo?.leagueAvgHomeGoals,
      globalMarketLeagueAvgAwayGoals: phaseTwo?.leagueAvgAwayGoals,
    );
  }

  /// Section 89/90: vollständiger Eligibility-Audit über ALLE bekannten
  /// Pre-Match-Snapshots (nicht nur die bereits gefilterten Samples), mit
  /// exaktem Ausschlussgrund je Fixture. Wird für den globalen Dry-Run-
  /// Bericht sowie für die Per-Liga-Übersicht verwendet.
  Future<EligibilityAudit> auditEligibility() async {
    final rows = await database.modelLabEligibilityAuditRows();

    var eligible = 0;
    final exclusions = <String, int>{
      'not_whitelisted': 0,
      'outcome_missing': 0,
      'timestamp_invalid': 0,
      'data_quality_below_minimum': 0,
    };
    final perLeague = <String, LeagueEligibilityCounts>{};

    for (final row in rows) {
      final leagueId = row['league_id']?.toString() ?? 'unknown';
      final counts = perLeague.putIfAbsent(
        leagueId,
        () => LeagueEligibilityCounts(leagueId: leagueId),
      );
      counts.stored += 1;

      final collectionTier = row['collection_tier']?.toString();
      final status = row['status']?.toString();
      final homeGoals = _int(row['home_goals']);
      final awayGoals = _int(row['away_goals']);
      final kickoff = _dateTime(row['kickoff_utc']);
      final snapshotCreatedAt = _dateTime(row['snapshot_created_at']);
      final dataQuality = _int(row['data_quality']) ?? 0;

      final isFinished = status != null &&
          PhoenixDatabase.modelLabFinishedMatchStatuses.contains(status);
      final hasOutcome = isFinished && homeGoals != null && awayGoals != null;

      // Muss exakt denselben Kreis wie [PhoenixDatabase.modelLabRawDataset]
      // verwenden (Fokus, Beobachtungsliga UND seit 2026-08-25 Datenpool),
      // sonst zeigt der Audit-Bericht Spiele fälschlich als "not_whitelisted"
      // an, obwohl sie im echten Training längst berücksichtigt werden.
      if (collectionTier != 'focus' &&
          collectionTier != 'watchlist' &&
          collectionTier != 'data_pool') {
        exclusions['not_whitelisted'] = exclusions['not_whitelisted']! + 1;
        continue;
      }
      counts.whitelisted += 1;

      if (!hasOutcome) {
        exclusions['outcome_missing'] = exclusions['outcome_missing']! + 1;
        continue;
      }
      counts.settled += 1;

      if (kickoff == null ||
          snapshotCreatedAt == null ||
          !snapshotCreatedAt.isBefore(kickoff)) {
        exclusions['timestamp_invalid'] =
            exclusions['timestamp_invalid']! + 1;
        continue;
      }

      if (dataQuality < config.minDataQuality) {
        exclusions['data_quality_below_minimum'] =
            exclusions['data_quality_below_minimum']! + 1;
        continue;
      }

      eligible += 1;
      counts.eligible += 1;
    }

    return EligibilityAudit(
      totalStoredSnapshots: rows.length,
      eligible: eligible,
      exclusionsByReason: exclusions,
      perLeague: perLeague.values.toList(),
    );
  }

  static DateTime? _dateTime(Object? value) {
    if (value is DateTime) return value.toUtc();
    if (value is String) return DateTime.tryParse(value)?.toUtc();
    return null;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '');
  }

  static double? _double(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }
}

class LeagueEligibilityCounts {
  LeagueEligibilityCounts({required this.leagueId});

  final String leagueId;
  int stored = 0;
  int whitelisted = 0;
  int settled = 0;
  int eligible = 0;

  Map<String, Object?> toJson() => {
    'leagueId': leagueId,
    'storedSnapshots': stored,
    'whitelisted': whitelisted,
    'settled': settled,
    'eligible': eligible,
  };
}

class EligibilityAudit {
  const EligibilityAudit({
    required this.totalStoredSnapshots,
    required this.eligible,
    required this.exclusionsByReason,
    required this.perLeague,
  });

  final int totalStoredSnapshots;
  final int eligible;
  final Map<String, int> exclusionsByReason;
  final List<LeagueEligibilityCounts> perLeague;

  int get notEligible => totalStoredSnapshots - eligible;

  Map<String, Object?> toJson() => {
    'totalStoredSnapshots': totalStoredSnapshots,
    'eligible': eligible,
    'notEligible': notEligible,
    'exclusionsByReason': exclusionsByReason,
    'perLeague': perLeague.map((e) => e.toJson()).toList(),
  };
}

/// Interner Zwischentyp: alles, was `LearningDatasetBuilder` pro Fixture aus
/// der Phase-2-Quelle braucht, um sowohl die GLOBAL_GOALS_V1-Torerwartung
/// (fest vorberechnet) als auch die `GlobalMarketEngine`-Rohdaten (auf
/// Abruf berechnet, siehe `LearningSample.hasGlobalMarketData`) zu befüllen.
class _PhaseTwoSampleData {
  const _PhaseTwoSampleData({
    required this.goalsV1Home,
    required this.goalsV1Away,
    required this.availability,
    required this.homeTeamId,
    required this.awayTeamId,
    required this.leagueAvgHomeGoals,
    required this.leagueAvgAwayGoals,
  });

  final double? goalsV1Home;
  final double? goalsV1Away;
  final Map<String, Object?> availability;
  final String homeTeamId;
  final String awayTeamId;
  final double? leagueAvgHomeGoals;
  final double? leagueAvgAwayGoals;
}
