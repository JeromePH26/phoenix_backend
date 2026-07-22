import '../database/database.dart';
import 'football_service.dart';

/// Temporärer Build-Fix.
///
/// Die vorherige Datei referenzierte eine nicht vorhandene
/// `GeminiContextService`-Klasse. Damit Railway wieder bauen und die neuen
/// Tennis-Routen deployen kann, wird der Football-Tageslauf vorübergehend
/// kontrolliert beendet. Die normalen Football-Match- und Tennis-Routen bleiben
/// davon unberührt.
class FootballDailyPipelineService {
  FootballDailyPipelineService({
    required this.database,
    required this.football,
  });

  final PhoenixDatabase database;
  final FootballService football;

  static const String publishedModelVersion =
      'phoenix_daily_pipeline_v9_gemini_all_matches_100k';

  Future<void> run({
    required int jobId,
    required DateTime date,
    int? limit,
    int minimumDataQuality = 60,
    int simulations = 100000,
  }) async {
    try {
      await database.updateFootballDailyPipelineJob(
        jobId: jobId,
        status: 'completed',
        currentStep: 'temporarily_disabled_build_fix',
        processed: 0,
        published: 0,
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
}
