import '../database/database.dart';
import 'football_service.dart';

class FootballPhaseTwoScanService {
  FootballPhaseTwoScanService({
    required this.database,
    required this.football,
  });

  final PhoenixDatabase database;
  final FootballService football;

  Future<Map<String, Object?>> prepare({
    int? phaseOneScanRunId,
    int limit = 20,
    int minimumDataQuality = 50,
  }) async {
    final matches = await database.eligiblePhaseOneMatches(
      scanRunId: phaseOneScanRunId,
      limit: limit.clamp(1, 20),
    );

    if (matches.isEmpty) {
      return {
        'started': false,
        'phase': 2,
        'status': 'no_eligible_matches',
        'matches': <Map<String, Object?>>[],
      };
    }

    final scanDate =
        DateTime.tryParse(matches.first['scan_date']?.toString() ?? '') ??
            DateTime.now();
    final scanRunId = await database.createFootballPhaseTwoScanRun(scanDate);

    return {
      'started': true,
      'scanRunId': scanRunId,
      'phase': 2,
      'status': 'running',
      'limit': matches.length,
      'minimumDataQuality': minimumDataQuality.clamp(0, 100),
      'matches': matches,
    };
  }

  Future<Map<String, Object?>> processPrepared(
    Map<String, Object?> prepared,
  ) async {
    final scanRunId = _int(prepared['scanRunId']);
    final minimumDataQuality =
        _int(prepared['minimumDataQuality']).clamp(0, 100);
    final rawMatches = prepared['matches'];
    final matches = rawMatches is List
        ? rawMatches
            .whereType<Map>()
            .map((value) => Map<String, Object?>.from(value))
            .toList()
        : <Map<String, Object?>>[];

    var allowed = 0;
    var below = 0;
    var failed = 0;

    for (final row in matches) {
      final payload = _map(row['payload']);
      final fixtureId = _string(row['fixture_id']);
      final leagueId = _string(row['league_id']);
      final season = _int(row['season']);

      if (fixtureId.isEmpty) {
        failed++;
        continue;
      }

      Map<String, Object?> availability;
      String? coverageError;

      try {
        availability = await football.coverageForFixture(
          fixtureId: fixtureId,
          leagueId: leagueId,
          season: season,
          homeTeamId: _string(payload['homeTeamId']),
          awayTeamId: _string(payload['awayTeamId']),
        );
      } catch (error) {
        coverageError = error.toString();
        availability = <String, Object?>{
          'coverageError': coverageError,
          'standings': false,
          'homeRecent': false,
          'awayRecent': false,
          'odds': false,
          'injuries': false,
          'h2h': false,
          'homeTeamStatistics': false,
          'awayTeamStatistics': false,
          'realXgAvailable': false,
        };
      }

      final quality = _quality(availability);
      final analysisAllowed = quality >= minimumDataQuality;

      if (analysisAllowed) {
        allowed++;
      } else {
        below++;
      }

      final resultPayload = <String, Object?>{
        ...payload,
        'phaseTwo': {
          'dataQuality': quality,
          'minimumDataQuality': minimumDataQuality,
          'analysisAllowed': analysisAllowed,
          'availability': availability,
          if (coverageError != null) 'coverageError': coverageError,
        },
      };

      await database.savePhaseTwoResult(
        scanRunId: scanRunId,
        fixtureId: fixtureId,
        leagueId: leagueId,
        season: season,
        dataQuality: quality,
        analysisAllowed: analysisAllowed,
        availability: availability,
        payload: resultPayload,
      );
    }

    await database.completeFootballScanRun(
      scanRunId: scanRunId,
      totalMatches: matches.length,
      eligibleMatches: allowed,
      excludedMatches: below + failed,
      payload: {
        'minimumDataQuality': minimumDataQuality,
        'checked': matches.length,
        'allowed': allowed,
        'belowQuality': below,
        'failed': failed,
      },
    );

    return {
      'status': 'completed',
      'scanRunId': scanRunId,
      'checked': matches.length,
      'allowed': allowed,
      'belowQuality': below,
      'failed': failed,
    };
  }

  int _quality(Map<String, Object?> availability) {
    var score = 5;
    if (availability['standings'] == true) score += 15;
    if (availability['homeRecent'] == true) score += 10;
    if (availability['awayRecent'] == true) score += 10;
    if (availability['odds'] == true) score += 15;
    if (availability['injuries'] == true) score += 10;
    if (availability['h2h'] == true) score += 10;
    if (availability['homeTeamStatistics'] == true) score += 10;
    if (availability['awayTeamStatistics'] == true) score += 10;
    if (availability['realXgAvailable'] == true) score += 5;
    return score.clamp(0, 100);
  }

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  String _string(Object? value) => value?.toString().trim() ?? '';

  int _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
