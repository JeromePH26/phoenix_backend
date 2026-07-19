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

  Future<Map<String, Object?>> processPrepared(Map<String, Object?> prepared) async {
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
          fixtureId: fixtureId,
          leagueId: leagueId,
          season: season,
          homeTeamId: _string(payload['homeTeamId']),
          awayTeamId: _string(payload['awayTeamId']),
        );
        final sanitized = _sanitizeAvailability(availability);
        final quality = _quality(sanitized);
        final analysisAllowed = quality >= minimumDataQuality;
        analysisAllowed ? allowed++ : below++;
        final resultPayload = <String, Object?>{...payload, 'phaseTwo': {
          'dataQuality': quality,
          'minimumDataQuality': minimumDataQuality,
          'analysisAllowed': analysisAllowed,
          'availability': sanitized,
        }};
        await database.savePhaseTwoResult(
          scanRunId: scanRunId,
          fixtureId: fixtureId,
          leagueId: leagueId,
          season: season,
          dataQuality: quality,
          analysisAllowed: analysisAllowed,
          availability: sanitized,
          payload: resultPayload,
        );
      }
      await database.completeFootballScanRun(
        scanRunId: scanRunId,
        totalMatches: matches.length,
        eligibleMatches: allowed,
        excludedMatches: below,
        payload: {'minimumDataQuality': minimumDataQuality, 'checked': matches.length},
      );
      return {
        'status': 'completed',
        'scanRunId': scanRunId,
        'checked': matches.length,
        'allowed': allowed,
        'belowMinimum': below,
      };
    } catch (error) {
      await database.failFootballScanRun(scanRunId, error);
      rethrow;
    }
  }

  Map<String, Object?> _sanitizeAvailability(Map<String, Object?> source) {
    final result = <String, Object?>{...source};
    final homePlayed = _playedTotal(source['homePlayed']);
    final awayPlayed = _playedTotal(source['awayPlayed']);
    result['homePlayedTotal'] = homePlayed;
    result['awayPlayedTotal'] = awayPlayed;
    final homeStatsUsable = source['homeTeamStatistics'] == true && homePlayed >= 3;
    final awayStatsUsable = source['awayTeamStatistics'] == true && awayPlayed >= 3;
    result['homeTeamStatistics'] = homeStatsUsable;
    result['awayTeamStatistics'] = awayStatsUsable;
    result['homeTeamStatisticsUsable'] = homeStatsUsable;
    result['awayTeamStatisticsUsable'] = awayStatsUsable;
    if (!homeStatsUsable) _removeGoalAverages(result, 'home');
    if (!awayStatsUsable) _removeGoalAverages(result, 'away');
    return result;
  }

  void _removeGoalAverages(Map<String, Object?> target, String prefix) {
    target.remove('${prefix}GoalsForAverageTotal');
    target.remove('${prefix}GoalsForAverageHome');
    target.remove('${prefix}GoalsForAverageAway');
    target.remove('${prefix}GoalsAgainstAverageTotal');
    target.remove('${prefix}GoalsAgainstAverageHome');
    target.remove('${prefix}GoalsAgainstAverageAway');
    target.remove('${prefix}Form');
  }

  int _quality(Map<String, Object?> a) {
    var score = 5;
    if (a['standings'] == true) score += 15;
    score += ((_int(a['homeRecentCount']).clamp(0, 5) / 5) * 10).round();
    score += ((_int(a['awayRecentCount']).clamp(0, 5) / 5) * 10).round();
    if (a['odds'] == true) score += 15;
    if (a['injuries'] == true) score += 10;
    if (a['h2h'] == true) score += 10;
    if (a['homeTeamStatisticsUsable'] == true) score += 10;
    if (a['awayTeamStatisticsUsable'] == true) score += 10;
    if (a['realXgAvailable'] == true) score += 5;
    if (_int(a['homePlayedTotal']) == 0 || _int(a['awayPlayedTotal']) == 0) score -= 15;
    return score.clamp(0, 100);
  }

  int _playedTotal(Object? value) {
    final map = _map(value);
    if (map.isNotEmpty) return _int(map['total']);
    return _int(value);
  }

  Map<String, Object?> _map(Object? v) => v is Map ? Map<String, Object?>.from(v) : <String, Object?>{};
  String _string(Object? v) => v?.toString().trim() ?? '';
  int _int(Object? v) => v is int ? v : v is num ? v.round() : int.tryParse(v?.toString() ?? '') ?? 0;
}
