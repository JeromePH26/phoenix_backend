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
    int simulations = 10000,
  }) async {
    try {
      await _step(jobId, 'phase1');
      final phaseOne = await FootballPhaseOneScanService(
        database: database,
        football: football,
      ).run(date);
      final phaseOneId = _integer(phaseOne['scanRunId']);
      await database.updateFootballDailyPipelineJob(
        jobId: jobId,
        status: 'running',
        currentStep: 'phase2',
        phaseOneScanRunId: phaseOneId,
      );

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
        phaseTwoScanRunId: phaseTwoId,
      );
      await phaseTwoService.processPrepared(prepared);

      await _step(jobId, 'engine_input');
      await FootballEngineInputService(database: database).prepare(
        phaseTwoScanRunId: phaseTwoId,
        limit: limit,
      );

      await _step(jobId, 'simulation');
      await FootballSimulationService(database: database).run(
        phaseTwoScanRunId: phaseTwoId,
        limit: limit,
        simulations: simulations,
      );

      await _step(jobId, 'market_selection');
      await FootballMarketSelectionService(database: database).select(
        phaseTwoScanRunId: phaseTwoId,
        limit: limit,
        minimumProbability: 50,
      );

      await _step(jobId, 'value_check');
      await FootballValueService(
        database: database,
        football: football,
      ).check(
        phaseTwoScanRunId: phaseTwoId,
        limit: limit,
        minimumMarketOdds: 1.40,
        minimumValuePercent: 5,
      );

      await _step(jobId, 'gemini_context');
      await GeminiContextService(database: database).verifyAllEligibleTips(
        phaseTwoScanRunId: phaseTwoId,
        candidateLimit: limit,
      );

      await _step(jobId, 'finalization');
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
