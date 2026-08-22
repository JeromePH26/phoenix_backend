import '../database/database.dart';
import 'football_engine_input_service.dart';
import 'football_service.dart';

/// Lädt Details für Beobachtungsliste und Datenpool mit festem Tagesbudget.
/// Gespeicherte Coverage ist mit Fokus-Ligen strukturell identisch, erhält
/// aber nie eine öffentliche Analyse-Freigabe.
class FootballBackgroundEnrichmentService {
  FootballBackgroundEnrichmentService({
    required this.database,
    required this.football,
  });

  final PhoenixDatabase database;
  final FootballService football;

  Future<Map<String, Object?>> run({
    required DateTime date,
    int maxFixtures = 30,
  }) async {
    final candidates = await database.backgroundEnrichmentCandidates(
      anchorDate: date,
      limit: maxFixtures,
    );
    if (candidates.isEmpty) {
      return const {'status': 'no_candidates', 'processed': 0};
    }

    final scanRunId = await database.createFootballPhaseTwoScanRun(date);
    var processed = 0;
    var failed = 0;
    try {
      for (final candidate in candidates) {
        final payload = _map(candidate['raw_json']);
        final fixtureId = _text(candidate['fixture_id']);
        final leagueId = _text(candidate['league_id']);
        final season = _integer(candidate['season']);
        if (fixtureId.isEmpty || leagueId.isEmpty || season <= 0) continue;

        try {
          final availability = await football.coverageForFixture(
            fixtureId: fixtureId,
            leagueId: leagueId,
            season: season,
            homeTeamId: _text(payload['homeTeamId']),
            awayTeamId: _text(payload['awayTeamId']),
            // Hintergrund darf die öffentliche Fokus-Pipeline nicht
            // verdrängen. Der kleine Abstand hält API-Sports stabil.
            pauseBetweenCalls: const Duration(milliseconds: 450),
          );
          final quality = _quality(availability);
          await database.savePhaseTwoResult(
            scanRunId: scanRunId,
            fixtureId: fixtureId,
            leagueId: leagueId,
            season: season,
            dataQuality: quality,
            analysisAllowed: false,
            availability: availability,
            payload: {
              ...payload,
              'backgroundEnrichment': {
                'tier': _text(candidate['collection_tier']),
                'dataQuality': quality,
              },
            },
          );
          processed += 1;
        } catch (_) {
          // Eine einzelne Provider-Lücke darf den Datenpool-Lauf nicht
          // stoppen. Die Liga bleibt beim nächsten budgetierten Turnus dran.
          failed += 1;
        }
      }

      // Diese Inputs sind ausschließlich Shadow-Trainingsmaterial: Sie
      // werden niemals simuliert, bewertet oder als Tipp veröffentlicht.
      final engineInputs = await FootballEngineInputService(
        database: database,
      ).prepare(
        phaseTwoScanRunId: scanRunId,
        limit: maxFixtures,
        includeBackground: true,
      );

      await database.completeFootballScanRun(
        scanRunId: scanRunId,
        totalMatches: candidates.length,
        eligibleMatches: 0,
        excludedMatches: candidates.length,
        payload: {
          'kind': 'background_enrichment',
          'processed': processed,
          'failed': failed,
          'engineInputs': engineInputs['prepared'] ?? 0,
        },
      );
      return {
        'status': 'completed',
        'scanRunId': scanRunId,
        'processed': processed,
        'failed': failed,
        'engineInputs': engineInputs['prepared'] ?? 0,
      };
    } catch (error) {
      await database.failFootballScanRun(scanRunId, error);
      rethrow;
    }
  }

  int _quality(Map<String, Object?> value) {
    var score = 5;
    if (value['standings'] == true) score += 20;
    if (value['homeRecent'] == true && value['awayRecent'] == true) score += 15;
    if (value['h2h'] == true) score += 15;
    if (value['homeTeamStatistics'] == true &&
        value['awayTeamStatistics'] == true) {
      score += 25;
    }
    if (value['injuries'] == true) score += 10;
    if (value['odds'] == true) score += 10;
    return score.clamp(0, 100);
  }

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};
  String _text(Object? value) => value?.toString().trim() ?? '';
  int _integer(Object? value) => value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '') ?? 0;
}
