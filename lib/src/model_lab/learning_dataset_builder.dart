import '../config/model_lab_config.dart';
import '../database/database.dart';
import 'feature_whitelist.dart';
import 'global_goals_v1_engine.dart';
import 'learning_sample.dart';

/// Baut leakage-sichere Learning-Datensätze aus gespeicherten PHÖNIX-Daten
/// (Section 16: NUR eigene PHÖNIX-Daten, keine externen/Twin-Daten) und
/// führt den Eligibility-Audit für den Dry Run (Section 89/90) durch.
class LearningDatasetBuilder {
  LearningDatasetBuilder({required this.database, required this.config});

  final PhoenixDatabase database;
  final ModelLabConfig config;

  /// Section 19/21: liefert alle leakage-sicheren Samples für eine (optional
  /// auf eine Liga eingeschränkte) Abfrage, chronologisch nach Kickoff
  /// sortiert (Voraussetzung für Walk-Forward, Section 30/31).
  Future<List<LearningSample>> buildSamples({String? leagueId}) async {
    final rows = await database.modelLabRawDataset(
      leagueId: leagueId,
      minDataQuality: config.minDataQuality,
    );
    final goalsV1ByFixture = await _globalGoalsV1ByFixture();
    return _samplesFromRows(rows, goalsV1ByFixture);
  }

  /// Lädt den gemeinsamen, leakage-sicheren Rohdatensatz genau einmal und
  /// gruppiert ihn anschließend nach Liga. Ein Learning-Run bewertet viele
  /// Märkte auf denselben Fixtures; ohne diesen Batch-Pfad wurde derselbe
  /// Datenbank-Scan bisher für jeden Markt erneut ausgeführt.
  Future<Map<String, List<LearningSample>>> buildSamplesByLeague() async {
    final rows = await database.modelLabRawDataset(
      minDataQuality: config.minDataQuality,
    );
    final goalsV1ByFixture = await _globalGoalsV1ByFixture();
    final grouped = <String, List<LearningSample>>{};
    for (final sample in _samplesFromRows(rows, goalsV1ByFixture)) {
      grouped.putIfAbsent(sample.leagueId, () => <LearningSample>[])
          .add(sample);
    }
    return grouped;
  }

  /// Section GLOBAL_GOALS_V1: berechnet für jedes Fixture mit einem
  /// leakage-sicheren Phase-2-Snapshot vor dem Kickoff die Torerwartung des
  /// GLOBAL_GOALS_V1-Engines EINMAL im Voraus, statt sie bei jeder
  /// Markt-Auswertung desselben Fixtures neu zu berechnen (derselbe
  /// Batch-Gedanke wie bei `buildSamplesByLeague`).
  Future<Map<String, ({double? home, double? away})>>
      _globalGoalsV1ByFixture() async {
    final rows = await database.modelLabGlobalGoalsV1Dataset();
    final result = <String, ({double? home, double? away})>{};
    for (final row in rows) {
      final fixtureId = row['fixture_id']?.toString();
      final availability = row['availability'];
      if (fixtureId == null || availability is! Map) continue;
      final v1 = GlobalGoalsV1Engine.compute(
        availability: Map<String, Object?>.from(availability),
        homeTeamId: row['home_team_id']?.toString() ?? '',
        awayTeamId: row['away_team_id']?.toString() ?? '',
        leagueAvgHomeGoalsPerGame: _double(row['league_avg_home_goals']),
        leagueAvgAwayGoalsPerGame: _double(row['league_avg_away_goals']),
      );
      result[fixtureId] = (home: v1.expectedHome, away: v1.expectedAway);
    }
    return result;
  }

  List<LearningSample> _samplesFromRows(
    List<Map<String, Object?>> rows,
    Map<String, ({double? home, double? away})> goalsV1ByFixture,
  ) {
    final samples = <LearningSample>[];
    for (final row in rows) {
      final sample = _rowToSample(row, goalsV1ByFixture);
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
    Map<String, ({double? home, double? away})> goalsV1ByFixture,
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
    final goalsV1 = goalsV1ByFixture[fixtureId];

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
      globalGoalsV1ExpectedHome: goalsV1?.home,
      globalGoalsV1ExpectedAway: goalsV1?.away,
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
      // verwenden (Fokus- UND Beobachtungsliga), sonst zeigt der Audit-
      // Bericht Beobachtungsliga-Spiele fälschlich als "not_whitelisted" an,
      // obwohl sie im echten Training längst berücksichtigt werden. Der
      // alte `manual_status == 'whitelist'`-Check kannte nur Fokus-Ligen und
      // wurde vor Einführung der Beobachtungsliste/des Datenpools geschrieben.
      if (collectionTier != 'focus' && collectionTier != 'watchlist') {
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
