import '../database/database.dart';

/// Sicherheitsabschaltung für den früheren Gemini-Kontextschritt.
///
/// Der Dienst bleibt als kompatible Klasse im Projekt, damit ältere Imports
/// oder Admin-Aufrufe nicht den Build brechen. Er führt jedoch keinen
/// Netzwerkzugriff aus, liest keinen API-Key und schreibt keinen KI-Fallback.
class GeminiContextService {
  GeminiContextService({
    required this.database,
    Object? client,
  });

  final PhoenixDatabase database;

  String get apiKey => '';
  String get model => 'disabled';

  Future<Map<String, Object?>> verifyPhaseTwoMatches({
    required int phaseTwoScanRunId,
    int limit = 20,
  }) async {
    return <String, Object?>{
      'status': 'disabled',
      'phase': 3,
      'provider': 'gemini',
      'phaseTwoScanRunId': phaseTwoScanRunId,
      'requestedLimit': limit.clamp(1, 20),
      'processed': 0,
      'applied': 0,
      'fallbackUsed': 0,
      'failed': 0,
      'networkRequestStarted': false,
      'results': const <Map<String, Object?>>[],
    };
  }
}
