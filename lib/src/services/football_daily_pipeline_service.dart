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

  Future<void> run({
    required int jobId,
    required DateTime date,
    int limit = 20,
    int minimumDataQuality = 50,
    int simulations = 100000,
  }) async {
    try {
      final safeLimit = limit.clamp(1, 20).toInt();
      final safeQuality = minimumDataQuality.clamp(0, 100).toInt();
      // Für Fußball verwendet PHÖNIX verbindlich 100.000 Läufe.
      final safeSimulations = simulations < 100000
          ? 100000
          : simulations.clamp(100000, 100000).toInt();

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
      final prepared = await phaseTwoService.prepare(
        phaseOneScanRunId: phaseOneId,
        limit: safeLimit,
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

      await _step(jobId, 'gemini_context');
      final gemini = GeminiContextService(database: database);
      try {
        await gemini.verifyPhaseTwoMatches(
          phaseTwoScanRunId: phaseTwoId,
          limit: safeLimit,
        );
      } catch (_) {
        // Die strukturierte PHÖNIX-Analyse läuft weiter, wenn Gemini nicht
        // konfiguriert oder vorübergehend nicht erreichbar ist.
      } finally {
        gemini.close();
      }

      await _step(jobId, 'engine_input');
      final engineResult =
          await FootballEngineInputService(database: database).prepare(
        phaseTwoScanRunId: phaseTwoId,
        limit: safeLimit,
      );

      final preparedInputs = _integer(engineResult['prepared']);
      if (preparedInputs <= 0) {
        throw StateError('Keine Engine-Eingaben wurden erzeugt.');
      }

      await _step(jobId, 'simulation');
      final simulationResult =
          await FootballSimulationService(database: database).run(
        phaseTwoScanRunId: phaseTwoId,
        limit: safeLimit,
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
        limit: safeLimit,
        minimumProbability: 0,
      );

      final selected = _integer(marketResult['processed']);
      if (selected <= 0) {
        throw StateError('Keine Marktauswahl wurde erzeugt.');
      }

      // Quoten/Value sind hilfreich, dürfen aber die Veröffentlichung
      // einer vollständigen Modellanalyse nicht verhindern.
      await _step(jobId, 'value_check_optional');
      try {
        await FootballValueService(
          database: database,
          football: football,
        ).check(
          phaseTwoScanRunId: phaseTwoId,
          limit: safeLimit,
          minimumMarketOdds: 1.40,
          minimumValuePercent: 5,
        );
      } catch (_) {
        // Ohne Quoten bleibt der PHÖNIX-Tipp bestehen, nur Value fehlt.
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

      final probabilities = _map(simulation['probabilities']);
      final fairOdds = _map(simulation['fairOdds']);
      final publicProbabilities = _publicProbabilities(probabilities);
      final publicFairOdds = <String, Object?>{
        ...fairOdds,
        'home': fairOdds['home'] ?? fairOdds['homeWin'],
        'draw': fairOdds['draw'],
        'away': fairOdds['away'] ?? fairOdds['awayWin'],
      };
      final phoenixTip = _map(selection['phoenixTip']);
      final trust = _map(selection['trust']);
      final confidence = _integer(trust['score']).clamp(0, 100);
      final recommendation = _string(phoenixTip['market']);

      final analysisPayload = <String, Object?>{
        ...matchPayload,
        'source': 'server_prepared',
        'modelVersion': 'phoenix_daily_pipeline_v5_context_persistence100k',
        'dataQuality': dataQuality,
        'confidence': confidence,
        'recommendation': recommendation,
        // Öffentliche App-Schnittstelle: Wahrscheinlichkeiten immer 0–1.
        'probabilities': publicProbabilities,
        'fairOdds': publicFairOdds,
        'goalExpectations': simulation['goalExpectations'],
        'topScorelines': simulation['topScorelines'],
        'phoenixTip': <String, Object?>{
          ...phoenixTip,
          if (_probability01(phoenixTip['probability']) != null)
            'probability': _probability01(phoenixTip['probability']),
        },
        'selection': selection,
        'aiContext': simulation['aiContext'],
        'simulationRuns': simulation['simulations'],
        'simulation': simulation,
        'publishedAt': DateTime.now().toUtc().toIso8601String(),
      };

      await database.upsertFootballMatchFromPayload(
        fixtureId: fixtureId,
        payload: matchPayload,
      );

      await database.saveFinalFootballAnalysis(
        fixtureId: fixtureId,
        modelVersion: 'phoenix_daily_pipeline_v5_context_persistence100k',
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

  Map<String, Object?> _publicProbabilities(
    Map<String, Object?> values,
  ) {
    Object? probability(String key, [String? fallback]) =>
        _probability01(values[key] ?? (fallback == null ? null : values[fallback]));

    return <String, Object?>{
      'home': probability('home', 'homeWin'),
      'draw': probability('draw'),
      'away': probability('away', 'awayWin'),
      'homeWin': probability('homeWin', 'home'),
      'awayWin': probability('awayWin', 'away'),
      'over25': probability('over25'),
      'under25': probability('under25'),
      'bttsYes': probability('bttsYes'),
      'bttsNo': probability('bttsNo'),
    };
  }

  double? _probability01(Object? value) {
    final parsed = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
    if (parsed == null || !parsed.isFinite || parsed < 0) return null;
    final normalized = parsed > 1 ? parsed / 100.0 : parsed;
    return normalized.clamp(0.0, 1.0).toDouble();
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
