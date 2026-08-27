import 'dart:io';

import 'package:phoenix_backend/src/config/model_lab_config.dart';
import 'package:phoenix_backend/src/database/database.dart';
import 'package:phoenix_backend/src/model_lab/learning_dataset_classifier.dart';
import 'package:phoenix_backend/src/model_lab/learning_market.dart';

/// M2: befüllt `phoenix_learning_dataset` - je LIVE-Pre-Match-Snapshot x
/// Markt eine Zeile mit Datenklasse (production / learning / research /
/// quarantine) und Ausschlussgrund. Ersetzt die verstreute Inline-Filterung.
///
/// Standardmäßig DRY RUN (nur Verteilung). Mit `--write` wird die Tabelle
/// tatsächlich befüllt (additiv, idempotent).
///
///   dart run bin/phoenix_classify_dataset.dart
///   dart run bin/phoenix_classify_dataset.dart --write
Future<void> main(List<String> args) async {
  final write = args.contains('--write');
  final databaseUrl = (Platform.environment['DATABASE_PUBLIC_URL'] ??
          Platform.environment['DATABASE_URL'] ??
          '')
      .trim();
  final database = PhoenixDatabase(databaseUrl);
  final config = ModelLabConfig.fromEnvironment();
  final classifier = LearningDatasetClassifier(
    minDataQuality: config.minDataQuality,
  );

  try {
    await database.migrate();
    final db = await database.connection();

    // Ein Datensatz je Fixture: der beste (pre-kickoff bevorzugte) Snapshot,
    // angereichert um Ligastufe/Name und die Availability des jüngsten
    // Phase-2-Laufs (für standings / verwertbare Teamstatistik).
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

    // Pro Liga die Zahl der (grob) sonst-eligiblen Samples - für die
    // "zu dünne Beobachtungsliga"-Regel.
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
    final classCounts = <String, int>{};
    final reasonCounts = <String, int>{};
    final datasetRows = <
        ({
          String fixtureId,
          String market,
          String source,
          String dataClass,
          double? featureCompleteness,
          bool leakageChecked,
          String? leakageResult,
          String? snapshotRef,
          int? dataQuality,
          bool isCup,
          String? excludedReason,
          String? leagueId,
          DateTime? kickoff,
        })>[];

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
      final availability = m['availability'];
      final avail = availability is Map ? availability : const {};
      final hasStandings = avail['standings'] == true ||
          avail['standings']?.toString() == 'true';
      final hasUsableTeamStats =
          avail.containsKey('homeGoalsForAverageHome') &&
              avail.containsKey('awayGoalsForAverageAway');
      final isCup = _isCup(
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
      if (result.excludedReason != null) {
        reasonCounts[result.excludedReason!] =
            (reasonCounts[result.excludedReason!] ?? 0) + 1;
      }

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

    stdout.writeln('== phoenix_learning_dataset (source=live) ==');
    stdout.writeln('Fixtures klassifiziert: ${rows.length}');
    stdout.writeln('Zeilen (x ${LearningMarket.values.length} Märkte): '
        '${datasetRows.length}');
    stdout.writeln('\nKlassen (je Fixture):');
    for (final e in classCounts.entries) {
      stdout.writeln('  ${e.key.padRight(12)} ${e.value}');
    }
    stdout.writeln('\nAusschlussgründe:');
    final sortedReasons = reasonCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in sortedReasons) {
      stdout.writeln('  ${e.key.padRight(28)} ${e.value}');
    }

    if (write) {
      final written = await database.upsertLearningDatasetRows(datasetRows);
      stdout.writeln('\n$written Zeilen in phoenix_learning_dataset geschrieben.');
    } else {
      stdout.writeln('\nDRY RUN - nichts geschrieben. Mit --write erneut ausführen.');
    }
  } finally {
    await database.close();
  }
}

bool _isCup(String leagueName, int? competitionLevel) {
  final n = leagueName.toLowerCase();
  const patterns = [
    'cup', 'pokal', 'coupe', 'copa ', 'coppa', 'taça', 'taca', 'beker',
    'trophy', 'shield', 'supercopa', 'supercoppa', 'super cup', 'supercup',
    'champions league', 'europa league', 'conference league', 'libertadores',
    'sudamericana', 'playoff', 'play-off', 'promotion', 'relegation',
  ];
  if (patterns.any(n.contains)) return true;
  // Ligastufe 0/null ist meist ein Pokal-/Sonderwettbewerb.
  return competitionLevel == null || competitionLevel == 0;
}
