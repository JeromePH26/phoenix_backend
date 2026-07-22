import '../database/database.dart';
import 'football_engine_input_service.dart';
import 'football_market_selection_service.dart';
import 'football_phase_one_scan_service.dart';
import 'football_phase_two_scan_service.dart';
import 'football_service.dart';
import 'football_simulation_service.dart';
import 'football_value_service.dart';
import 'gemini_context_service.dart';

class FootballDailyPipelineService {
  FootballDailyPipelineService({
    required this.database,
    required this.football,
  });

  final PhoenixDatabase database;
  final FootballService football;

  static const publishedModelVersion =
      'phoenix_daily_pipeline_v9_gemini_all_matches_100k';

  Future<void> run({
    required int jobId,
    required DateTime date,
    int? limit,
    int minimumDataQuality = 60,
    int simulations = 100000,
  }) async {
    try {
      final effectiveLimit = limit ?? 1000000;
      final safeQuality = minimumDataQuality.clamp(0, 100);
      final safeSimulations = simulations.clamp(1000, 100000);

      await _step(jobId, 'phase1');
      final phaseOne = await FootballPhaseOneScanService(
        database: database,
        football: football,
      ).run(date);
      final phaseOneId = _integer(phaseOne['scanRunId']);

      await database.updateFootballDailyPipelineJob(
        jobId: jobId,
        status: 'running',
        currentStep: 'phase2_prepare',
        phaseOneScanRunId: phaseOneId,
      );

      final phaseTwoService = FootballPhaseTwoScanService(
        database: database,
        football: football,
      );

      // Phase 2 prüft bis zu 100 heutige Kandidaten auf ihre echte
      // Datenqualität. Erst danach verarbeiten Gemini, Engine und Simulation
      // ausschließlich alle qualifizierten Whitelist-Spiele.
      final prepared = await phaseTwoService.prepare(
        phaseOneScanRunId: phaseOneId,
        limit: effectiveLimit,
        minimumDataQuality: safeQuality,
      );

      if (prepared['started'] != true) {
        await _finish(
          jobId: jobId,
          step: 'no_eligible_matches',
          processed: 0,
          published: 0,
        );
        return;
      }

      final phaseTwoId = _integer(prepared['scanRunId']);

      await database.updateFootballDailyPipelineJob(
        jobId: jobId,
        status: 'running',
        currentStep: 'phase2_processing',
        phaseTwoScanRunId: phaseTwoId,
      );

      final phaseTwoResult = await phaseTwoService.processPrepared(prepared);
      final allowed = _integer(phaseTwoResult['allowed']);

      if (allowed <= 0) {
        await _finish(
          jobId: jobId,
          step: 'no_quality_matches',
          processed: _integer(phaseTwoResult['checked']),
          published: 0,
          phaseTwoId: phaseTwoId,
        );
        return;
      }

      // Gemini läuft bewusst VOR dem Engine-Input. Dadurch fließen
      // verifizierte Kontext-Deltas in die Torerwartungen und Simulation ein.
      await _step(jobId, 'gemini_context');

      try {
        await GeminiContextService(database: database).verifyPhaseTwoMatches(
          phaseTwoScanRunId: phaseTwoId,
          limit: effectiveLimit,
        );
      } catch (_) {
        // Die Pipeline bleibt lauffähig. Der Gemini-Service speichert
        // Kandidatenfehler selbst und lässt die mathematische Pipeline ohne Gemini weiterlaufen.
      }

      await _step(jobId, 'engine_input');
      final engineResult =
          await FootballEngineInputService(database: database).prepare(
        phaseTwoScanRunId: phaseTwoId,
        limit: effectiveLimit,
      );

      final preparedInputs = _integer(engineResult['prepared']);
      if (preparedInputs <= 0) {
        throw StateError('Keine Engine-Eingaben wurden erzeugt.');
      }

      await _step(jobId, 'simulation');
      final simulationResult =
          await FootballSimulationService(database: database).run(
        phaseTwoScanRunId: phaseTwoId,
        limit: effectiveLimit,
        simulations: safeSimulations,
      );

      final simulated = _integer(simulationResult['processed']);
      if (simulated <= 0) {
        throw StateError('Keine Simulation wurde erzeugt.');
      }

      await _step(jobId, 'market_selection');
      final marketResult =
          await FootballMarketSelectionService(database: database).select(
        phaseTwoScanRunId: phaseTwoId,
        limit: effectiveLimit,
        minimumProbability: 60,
      );

      final selected = _integer(marketResult['processed']);
      if (selected <= 0) {
        throw StateError('Keine Marktauswahl wurde erzeugt.');
      }

      await _step(jobId, 'value_check_optional');

      try {
        await FootballValueService(
          database: database,
          football: football,
        ).check(
          phaseTwoScanRunId: phaseTwoId,
          limit: effectiveLimit,
          minimumMarketOdds: 1.40,
          minimumValuePercent: 5,
        );
      } catch (_) {
        // Ohne Quote bleibt der PHÖNIX-Tipp sichtbar; nur Value fehlt.
      }

      await _step(jobId, 'publishing');
      final publishResult = await _publishAnalyses(
        phaseTwoScanRunId: phaseTwoId,
      );

      await _finish(
        jobId: jobId,
        step: 'completed',
        processed: _integer(publishResult['processed']),
        published: _integer(publishResult['published']),
        phaseTwoId: phaseTwoId,
      );
    } catch (error) {
      await database.updateFootballDailyPipelineJob(
        jobId: jobId,
        status: 'failed',
        currentStep: 'failed',
        error: error,
        completed: true,
      );
    }
  }

  Future<Map<String, Object?>> _publishAnalyses({
    required int phaseTwoScanRunId,
  }) async {
    final rows = await database.finalizationCandidates(
      phaseTwoScanRunId: phaseTwoScanRunId,
    );

    var processed = 0;
    var published = 0;

    for (final row in rows) {
      processed++;

      final fixtureId = _string(row['fixture_id']);
      final dataQuality = _integer(row['data_quality']);
      final matchPayload = _map(row['payload']);
      final simulation = _map(row['simulation']);
      final selection = _map(row['selection']);

      if (fixtureId.isEmpty || simulation.isEmpty || selection.isEmpty) {
        continue;
      }

      final rawProbabilities = _map(simulation['probabilities']);
      final rawFairOdds = _map(simulation['fairOdds']);
      final phoenixTip = _map(selection['phoenixTip']);
      final trust = _map(selection['trust']);
      final aiContext = _map(simulation['aiContext']);

      final baseConfidence = _integer(trust['score']).clamp(0, 100);
      final contextConfidenceDelta = aiContext['applied'] == true
          ? _integer(aiContext['confidenceDelta']).clamp(-10, 5)
          : 0;
      final confidence =
          (baseConfidence + contextConfidenceDelta).clamp(0, 100);

      final recommendation = _string(phoenixTip['market']);

      final homeProbability = _probability(
        rawProbabilities['home'] ?? rawProbabilities['homeWin'],
      );
      final drawProbability = _probability(rawProbabilities['draw']);
      final awayProbability = _probability(
        rawProbabilities['away'] ?? rawProbabilities['awayWin'],
      );

      final fairOdds = <String, Object?>{
        'home': rawFairOdds['home'] ?? rawFairOdds['homeWin'],
        'draw': rawFairOdds['draw'],
        'away': rawFairOdds['away'] ?? rawFairOdds['awayWin'],
        'homeWin': rawFairOdds['homeWin'] ?? rawFairOdds['home'],
        'awayWin': rawFairOdds['awayWin'] ?? rawFairOdds['away'],
        'over25': rawFairOdds['over25'],
        'under25': rawFairOdds['under25'],
        'bttsYes': rawFairOdds['bttsYes'],
        'bttsNo': rawFairOdds['bttsNo'],
      };

      final analysisPayload = <String, Object?>{
        ...matchPayload,
        'source': 'server_prepared',
        'modelVersion': publishedModelVersion,
        'dataQuality': dataQuality,
        'confidence': confidence,
        'baseConfidence': baseConfidence,
        'contextConfidenceDelta': contextConfidenceDelta,
        'recommendation': recommendation,
        'probabilities': {
          'home': homeProbability,
          'draw': drawProbability,
          'away': awayProbability,
          'homeWin': homeProbability,
          'awayWin': awayProbability,
          'over25': _probability(rawProbabilities['over25']),
          'under25': _probability(rawProbabilities['under25']),
          'bttsYes': _probability(rawProbabilities['bttsYes']),
          'bttsNo': _probability(rawProbabilities['bttsNo']),
        },
        'fairOdds': fairOdds,
        'goalExpectations': simulation['goalExpectations'],
        'topScorelines': simulation['topScorelines'],
        'phoenixTip': phoenixTip,
        'selection': selection,
        'simulation': simulation,
        'simulationCount': simulation['simulations'],
        'aiContext': aiContext,
        'contextApplied': aiContext['applied'] == true,
        'contextSource': aiContext['contextSource'],
        'contextSourceScanRunId': aiContext['contextSourceScanRunId'],
        'fallbackUsed': aiContext['fallbackUsed'] == true,
        'publishedAt': DateTime.now().toUtc().toIso8601String(),
      };

      await database.upsertFootballMatchFromPayload(
        fixtureId: fixtureId,
        payload: matchPayload,
      );

      await database.saveFinalFootballAnalysis(
        fixtureId: fixtureId,
        modelVersion: publishedModelVersion,
        dataQuality: dataQuality,
        confidence: confidence,
        recommendation:
            recommendation.isEmpty ? null : recommendation,
        payload: analysisPayload,
      );

      published++;
    }

    return {
      'processed': processed,
      'published': published,
    };
  }

  Future<void> _finish({
    required int jobId,
    required String step,
    required int processed,
    required int published,
    int? phaseTwoId,
  }) {
    return database.updateFootballDailyPipelineJob(
      jobId: jobId,
      status: 'completed',
      currentStep: step,
      phaseTwoScanRunId: phaseTwoId,
      processed: processed,
      published: published,
      completed: true,
    );
  }

  Future<void> _step(int jobId, String step) {
    return database.updateFootballDailyPipelineJob(
      jobId: jobId,
      status: 'running',
      currentStep: step,
    );
  }

  double _probability(Object? value) {
    final number = _number(value) ?? 0;
    final decimal = number > 1 ? number / 100 : number;
    return double.parse(
      decimal.clamp(0.0, 1.0).toStringAsFixed(6),
    );
  }

  double? _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  }

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  String _string(Object? value) => value?.toString().trim() ?? '';

  int _integer(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
