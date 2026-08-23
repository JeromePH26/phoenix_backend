import '../database/database.dart';
import 'football_engine_input_service.dart';
import 'football_market_selection_service.dart';
import 'football_service.dart';
import 'football_simulation_service.dart';

/// Lädt Details für Beobachtungsliste und Datenpool mit festem Tagesbudget.
/// Gespeicherte Coverage ist mit Fokus-Ligen strukturell identisch, erhält
/// aber nie eine öffentliche Analyse-Freigabe. Nach der Anreicherung werden
/// trotzdem Shadow-Analysen berechnet: sie sind im Control Center sichtbar
/// und Lernmaterial, aber weder App-Tipps noch Teil von ROI/History.
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

      // Shadow-Inputs werden genauso simuliert und bewertet wie Fokusspiele.
      // Entscheidend: Ihre Ergebnisse bleiben vom öffentlichen Tipp-/ROI-Feed
      // getrennt und erscheinen nur als klar markierte Control-Center-Analyse.
      final engineInputs = await FootballEngineInputService(
        database: database,
      ).prepare(
        phaseTwoScanRunId: scanRunId,
        limit: maxFixtures,
        includeBackground: true,
      );

      final simulation = await FootballSimulationService(database: database)
          .run(
        phaseTwoScanRunId: scanRunId,
        limit: maxFixtures,
        simulations: 100000,
      );
      final marketSelection = await FootballMarketSelectionService(
        database: database,
      ).select(
        phaseTwoScanRunId: scanRunId,
        limit: maxFixtures,
        minimumProbability: 68,
      );
      final analyses = await _saveShadowAnalyses(scanRunId);

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
          'simulations': simulation['processed'] ?? 0,
          'marketSelections': marketSelection['processed'] ?? 0,
          'shadowAnalyses': analyses,
        },
      );
      return {
        'status': 'completed',
        'scanRunId': scanRunId,
        'processed': processed,
        'failed': failed,
        'engineInputs': engineInputs['prepared'] ?? 0,
        'simulations': simulation['processed'] ?? 0,
        'marketSelections': marketSelection['processed'] ?? 0,
        'shadowAnalyses': analyses,
      };
    } catch (error) {
      await database.failFootballScanRun(scanRunId, error);
      rethrow;
    }
  }

  Future<int> _saveShadowAnalyses(int scanRunId) async {
    final candidates = await database.backgroundAnalysisCandidates(
      phaseTwoScanRunId: scanRunId,
    );
    var saved = 0;

    for (final candidate in candidates) {
      final fixtureId = _text(candidate['fixture_id']);
      final match = _map(candidate['payload']);
      final simulation = _map(candidate['simulation']);
      final selection = _map(candidate['selection']);
      if (fixtureId.isEmpty || simulation.isEmpty) continue;

      final analysisLead = _map(selection['phoenixTip']);
      final trust = _map(selection['trust']);
      final dataQuality =
          _integer(candidate['data_quality']).clamp(0, 100).toInt();
      final confidence = _integer(trust['score']).clamp(0, 100).toInt();
      final tier = _text(
        _map(match['backgroundEnrichment'])['tier'],
      );
      final recommendation = _text(analysisLead['market']);

      await database.upsertFootballShadowAnalysis(
        fixtureId: fixtureId,
        dataQuality: dataQuality,
        confidence: confidence,
        recommendation: recommendation.isEmpty ? null : recommendation,
        payload: {
          ...match,
          'source': 'background_shadow',
          'analysisScope': 'shadow_learning',
          'visibility': 'control_center_only',
          'collectionTier': tier,
          'modelVersion': FootballSimulationService.modelVersion,
          'dataQuality': dataQuality,
          'confidence': confidence,
          'recommendation': recommendation,
          // Eine Markt-Führung darf angezeigt werden, ist aber ausdrücklich
          // kein veröffentlichter PHÖNIX-Tipp und fließt nicht in ROI ein.
          'analysisLead': analysisLead,
          'phoenixTip': const <String, Object?>{},
          'selection': selection,
          'probabilities': _map(simulation['probabilities']),
          'fairOdds': _map(simulation['fairOdds']),
          'goalExpectations': simulation['goalExpectations'],
          'topScorelines': simulation['topScorelines'],
          'simulation': simulation,
          'simulationCount': simulation['simulations'],
          'analyzedAt': DateTime.now().toUtc().toIso8601String(),
        },
      );
      saved += 1;
    }
    return saved;
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
