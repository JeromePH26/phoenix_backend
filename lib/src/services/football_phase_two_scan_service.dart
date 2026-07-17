import '../database/database.dart';
import 'football_service.dart';

class FootballPhaseTwoScanService {
  FootballPhaseTwoScanService({
    required this.database,
    required this.football,
  });

  final PhoenixDatabase database;
  final FootballService football;

  Future<Map<String, Object?>> run({
    int? phaseOneScanRunId,
    int limit = 1,
    int minimumDataQuality = 50,
  }) async {
    final matches = await database.eligiblePhaseOneMatches(
      scanRunId: phaseOneScanRunId,
      limit: limit,
    );

    if (matches.isEmpty) {
      return {
        'phase': 2,
        'status': 'no_eligible_matches',
        'checked': 0,
        'analysisAllowed': 0,
        'belowThreshold': 0,
      };
    }

    final scanDateText = matches.first['scan_date']?.toString() ?? '';
    final scanDate = DateTime.tryParse(scanDateText) ?? DateTime.now();
    final scanRunId = await database.createFootballPhaseTwoScanRun(scanDate);

    var allowedCount = 0;
    var belowThresholdCount = 0;
    final summaries = <Map<String, Object?>>[];

    try {
      for (final row in matches) {
        final payload = _map(row['payload']);
        final fixtureId = _string(row['fixture_id']);
        final leagueId = _string(row['league_id']);
        final season = _int(row['season']);
        final homeTeamId = _string(payload['homeTeamId']);
        final awayTeamId = _string(payload['awayTeamId']);

        final availability = await football.coverageForFixture(
          fixtureId: fixtureId,
          leagueId: leagueId,
          season: season,
          homeTeamId: homeTeamId,
          awayTeamId: awayTeamId,
        );

        final quality = _quality(availability);
        final analysisAllowed = quality >= minimumDataQuality;

        if (analysisAllowed) {
          allowedCount++;
        } else {
          belowThresholdCount++;
        }

        final resultPayload = <String, Object?>{
          ...payload,
          'phaseTwo': {
            'dataQuality': quality,
            'minimumDataQuality': minimumDataQuality,
            'analysisAllowed': analysisAllowed,
            'availability': availability,
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

        summaries.add({
          'fixtureId': fixtureId,
          'match': '${_string(payload['homeTeam'])} vs ${_string(payload['awayTeam'])}',
          'league': _string(payload['league']),
          'dataQuality': quality,
          'analysisAllowed': analysisAllowed,
          'availability': availability,
        });
      }

      await database.completeFootballScanRun(
        scanRunId: scanRunId,
        totalMatches: matches.length,
        eligibleMatches: allowedCount,
        excludedMatches: belowThresholdCount,
        payload: {
          'minimumDataQuality': minimumDataQuality,
          'checked': matches.length,
        },
      );

      return {
        'scanRunId': scanRunId,
        'phase': 2,
        'checked': matches.length,
        'minimumDataQuality': minimumDataQuality,
        'analysisAllowed': allowedCount,
        'belowThreshold': belowThresholdCount,
        'matches': summaries,
      };
    } catch (error) {
      await database.failFootballScanRun(scanRunId, error);
      rethrow;
    }
  }

  int _quality(Map<String, Object?> availability) {
    var score = 10;
    if (availability['standings'] == true) score += 20;
    if (availability['homeRecent'] == true) score += 15;
    if (availability['awayRecent'] == true) score += 15;
    if (availability['injuries'] == true) score += 10;
    if (availability['odds'] == true) score += 15;
    if (availability['h2h'] == true) score += 10;
    if (availability['lineups'] == true) score += 5;
    return score.clamp(0, 100);
  }

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  String _string(Object? value) => value?.toString().trim() ?? '';

  int _int(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
