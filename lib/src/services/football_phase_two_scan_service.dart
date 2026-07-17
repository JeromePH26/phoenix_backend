import '../database/database.dart';
import 'football_service.dart';

class FootballPhaseTwoScanService {
  FootballPhaseTwoScanService({required this.database, required this.football});
  final PhoenixDatabase database;
  final FootballService football;

  Future<Map<String, Object?>> prepare({int? phaseOneScanRunId, int limit = 1, int minimumDataQuality = 50}) async {
    final matches = await database.eligiblePhaseOneMatches(scanRunId: phaseOneScanRunId, limit: limit);
    if (matches.isEmpty) {
      return {'started': false, 'phase': 2, 'status': 'no_eligible_matches', 'matches': <Map<String, Object?>>[]};
    }
    final scanDate = DateTime.tryParse(matches.first['scan_date']?.toString() ?? '') ?? DateTime.now();
    final scanRunId = await database.createFootballPhaseTwoScanRun(scanDate);
    return {
      'started': true, 'scanRunId': scanRunId, 'phase': 2, 'status': 'running',
      'limit': matches.length, 'minimumDataQuality': minimumDataQuality, 'matches': matches,
    };
  }

  Future<void> processPrepared(Map<String, Object?> prepared) async {
    final scanRunId = _int(prepared['scanRunId']);
    final minimumDataQuality = _int(prepared['minimumDataQuality']);
    final rawMatches = prepared['matches'];
    final matches = rawMatches is List
        ? rawMatches.whereType<Map>().map((e) => Map<String, Object?>.from(e)).toList()
        : <Map<String, Object?>>[];
    var allowed = 0;
    var below = 0;
    try {
      for (final row in matches) {
        final payload = _map(row['payload']);
        final fixtureId = _string(row['fixture_id']);
        final leagueId = _string(row['league_id']);
        final season = _int(row['season']);
        final availability = await football.coverageForFixture(
          fixtureId: fixtureId, leagueId: leagueId, season: season,
          homeTeamId: _string(payload['homeTeamId']), awayTeamId: _string(payload['awayTeamId']),
        );
        final quality = _quality(availability);
        final analysisAllowed = quality >= minimumDataQuality;
        analysisAllowed ? allowed++ : below++;
        final resultPayload = <String, Object?>{...payload, 'phaseTwo': {
          'dataQuality': quality, 'minimumDataQuality': minimumDataQuality,
          'analysisAllowed': analysisAllowed, 'availability': availability,
        }};
        await database.savePhaseTwoResult(
          scanRunId: scanRunId, fixtureId: fixtureId, leagueId: leagueId, season: season,
          dataQuality: quality, analysisAllowed: analysisAllowed, availability: availability,
          payload: resultPayload,
        );
      }
      await database.completeFootballScanRun(
        scanRunId: scanRunId, totalMatches: matches.length, eligibleMatches: allowed,
        excludedMatches: below, payload: {'minimumDataQuality': minimumDataQuality, 'checked': matches.length},
      );
    } catch (error) {
      await database.failFootballScanRun(scanRunId, error);
    }
  }

  int _quality(Map<String, Object?> a) {
    var score = 5;
    if (a['standings'] == true) score += 15;
    if (a['homeRecent'] == true) score += 10;
    if (a['awayRecent'] == true) score += 10;
    if (a['odds'] == true) score += 15;
    if (a['injuries'] == true) score += 10;
    if (a['h2h'] == true) score += 10;
    if (a['homeTeamStatistics'] == true) score += 10;
    if (a['awayTeamStatistics'] == true) score += 10;
    if (a['realXgAvailable'] == true) score += 5;
    return score.clamp(0, 100);
  }
  Map<String, Object?> _map(Object? v) => v is Map ? Map<String, Object?>.from(v) : <String, Object?>{};
  String _string(Object? v) => v?.toString().trim() ?? '';
  int _int(Object? v) => v is int ? v : int.tryParse(v?.toString() ?? '') ?? 0;
}
