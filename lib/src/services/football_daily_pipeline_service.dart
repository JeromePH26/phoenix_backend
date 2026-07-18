import '../database/database.dart';
import 'football_engine_input_service.dart';
import 'football_finalization_service.dart';
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
      // Phase 1: Ausschluss
      await _step(jobId, 'phase1_exclusion');
      final phaseOne = await FootballPhaseOneScanService(
        database: database,
        football: football,
      ).run(date);
      final phaseOneId = _integer(phaseOne['scanRunId']);

      // Phase 2: strukturierte Basisanalyse
      await _step(jobId, 'phase2_base_analysis');
      final phaseTwoService = FootballPhaseTwoScanService(
        database: database,
        football: football,
      );
      final prepared = await phaseTwoService.prepare(
        phaseOneScanRunId: phaseOneId,
        limit: limit,
        minimumDataQuality: minimumDataQuality,
      );

      if (prepared['started'] != true) {
        await database.updateFootballDailyPipelineJob(
          jobId: jobId,
          status: 'completed',
          currentStep: 'no_eligible_matches',
          phaseOneScanRunId: phaseOneId,
          processed: 0,
          published: 0,
          completed: true,
        );
        return;
      }

      final phaseTwoId = _integer(prepared['scanRunId']);
      await database.updateFootballDailyPipelineJob(
        jobId: jobId,
        status: 'running',
        currentStep: 'phase2_processing',
        phaseOneScanRunId: phaseOneId,
        phaseTwoScanRunId: phaseTwoId,
      );
      await phaseTwoService.processPrepared(prepared);

      // Phase 3: Gemini-Nachrichtenprüfung
      await _step(jobId, 'phase3_gemini_news');
      await GeminiContextService(database: database).verifyPhaseTwoMatches(
        phaseTwoScanRunId: phaseTwoId,
        limit: limit,
      );

      // Phase 4: endgültige Analyse aus allen Informationen
      await _step(jobId, 'phase4_final_engine');
      await FootballEngineInputService(database: database).prepare(
        phaseTwoScanRunId: phaseTwoId,
        limit: limit,
      );

      // Phase 5: Monte Carlo + Schwankungsprüfung
      await _step(jobId, 'phase5_monte_carlo');
      await FootballSimulationService(database: database).run(
        phaseTwoScanRunId: phaseTwoId,
        limit: limit,
        simulations: simulations,
      );

      // Phase 6: Markt, Quoten und Value
      await _step(jobId, 'phase6_market_selection');
      await FootballMarketSelectionService(database: database).select(
        phaseTwoScanRunId: phaseTwoId,
        limit: limit,
        minimumProbability: 50,
      );

      await _step(jobId, 'phase6_odds_value');
      await FootballValueService(
        database: database,
        football: football,
      ).check(
        phaseTwoScanRunId: phaseTwoId,
        limit: limit,
        minimumMarketOdds: 1.40,
        minimumValuePercent: 5,
      );

      await _step(jobId, 'publish');
      final finalResult = await FootballFinalizationService(
        database: database,
      ).finalize(phaseTwoScanRunId: phaseTwoId);

      await database.updateFootballDailyPipelineJob(
        jobId: jobId,
        status: 'completed',
        currentStep: 'completed',
        phaseOneScanRunId: phaseOneId,
        phaseTwoScanRunId: phaseTwoId,
        processed: _integer(finalResult['processed']),
        published: _integer(finalResult['published']),
        completed: true,
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

  Future<void> _step(int jobId, String step) =>
      database.updateFootballDailyPipelineJob(
        jobId: jobId,
        status: 'running',
        currentStep: step,
      );

  int _integer(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
