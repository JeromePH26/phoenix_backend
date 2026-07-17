
import '../database/database.dart';

class FootballEngineInputService {
  FootballEngineInputService({required this.database});

  final PhoenixDatabase database;

  static const modelVersion = 'goal_rate_normalization_v1';

  Future<Map<String, Object?>> prepare({
    int? phaseTwoScanRunId,
    int limit = 1,
  }) async {
    final scanRunId =
        phaseTwoScanRunId ?? await database.latestCompletedPhaseTwoScanRunId();

    if (scanRunId == null) {
      return {
        'status': 'no_completed_phase_two_scan',
        'prepared': 0,
      };
    }

    final rows = await database.allowedPhaseTwoRows(
      scanRunId: scanRunId,
      limit: limit,
    );

    final results = <Map<String, Object?>>[];

    for (final row in rows) {
      final fixtureId = _string(row['fixture_id']);
      final leagueId = _string(row['league_id']);
      final season = _int(row['season']);
      final dataQuality = _int(row['data_quality']);
      final availability = _map(row['availability']);
      final payload = _map(row['payload']);

      final normalized = _normalize(
        fixtureId: fixtureId,
        leagueId: leagueId,
        season: season,
        dataQuality: dataQuality,
        availability: availability,
        payload: payload,
      );

      await database.saveFootballEngineInput(
        phaseTwoScanRunId: scanRunId,
        fixtureId: fixtureId,
        leagueId: leagueId,
        season: season,
        dataQuality: dataQuality,
        modelVersion: modelVersion,
        normalizedInput: normalized,
      );

      results.add(normalized);
    }

    return {
      'status': 'prepared',
      'phaseTwoScanRunId': scanRunId,
      'modelVersion': modelVersion,
      'prepared': results.length,
      'results': results,
    };
  }

  Map<String, Object?> _normalize({
    required String fixtureId,
    required String leagueId,
    required int season,
    required int dataQuality,
    required Map<String, Object?> availability,
    required Map<String, Object?> payload,
  }) {
    final homeGoalsForHome =
        _number(availability['homeGoalsForAverageHome']);
    final homeGoalsAgainstHome =
        _number(availability['homeGoalsAgainstAverageHome']);
    final awayGoalsForAway =
        _number(availability['awayGoalsForAverageAway']);
    final awayGoalsAgainstAway =
        _number(availability['awayGoalsAgainstAverageAway']);

    final expectedHomeGoals = _averageAvailable(
      homeGoalsForHome,
      awayGoalsAgainstAway,
    );
    final expectedAwayGoals = _averageAvailable(
      awayGoalsForAway,
      homeGoalsAgainstHome,
    );

    final homeAttack = _relativeStrength(homeGoalsForHome, 1.35);
    final homeDefense = _inverseRelativeStrength(
      homeGoalsAgainstHome,
      1.35,
    );
    final awayAttack = _relativeStrength(awayGoalsForAway, 1.15);
    final awayDefense = _inverseRelativeStrength(
      awayGoalsAgainstAway,
      1.35,
    );

    return {
      'fixtureId': fixtureId,
      'leagueId': leagueId,
      'season': season,
      'homeTeam': _string(payload['homeTeam']),
      'awayTeam': _string(payload['awayTeam']),
      'league': _string(payload['league']),
      'kickoff': _string(payload['kickoff']),
      'dataQuality': dataQuality,
      'modelVersion': modelVersion,
      'sourceType': 'goal_rates_not_xg',
      'realXgAvailable': availability['realXgAvailable'] == true,
      'raw': {
        'homeGoalsForAverageHome': homeGoalsForHome,
        'homeGoalsAgainstAverageHome': homeGoalsAgainstHome,
        'awayGoalsForAverageAway': awayGoalsForAway,
        'awayGoalsAgainstAverageAway': awayGoalsAgainstAway,
        'homePlayed': availability['homePlayed'],
        'awayPlayed': availability['awayPlayed'],
      },
      'normalized': {
        'homeAttackStrength': homeAttack,
        'homeDefenseStrength': homeDefense,
        'awayAttackStrength': awayAttack,
        'awayDefenseStrength': awayDefense,
        'goalRateExpectedHome': expectedHomeGoals,
        'goalRateExpectedAway': expectedAwayGoals,
        'goalRateExpectedTotal':
            _sumAvailable(expectedHomeGoals, expectedAwayGoals),
      },
      'warnings': [
        if (availability['realXgAvailable'] != true)
          'Keine echten xG/xGA-Daten: Torquoten-Modell ist nur Vorbereitung.',
        if (expectedHomeGoals == null || expectedAwayGoals == null)
          'Mindestens ein benötigter Heim/Auswärts-Torwert fehlt.',
      ],
      'engineReady':
          expectedHomeGoals != null &&
          expectedAwayGoals != null &&
          dataQuality >= 50,
    };
  }

  double? _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  }

  double? _averageAvailable(double? a, double? b) {
    if (a == null && b == null) return null;
    if (a == null) return _round(b!);
    if (b == null) return _round(a);
    return _round((a + b) / 2);
  }

  double? _sumAvailable(double? a, double? b) {
    if (a == null || b == null) return null;
    return _round(a + b);
  }

  double? _relativeStrength(double? value, double baseline) {
    if (value == null || baseline <= 0) return null;
    return _round(value / baseline);
  }

  double? _inverseRelativeStrength(double? value, double baseline) {
    if (value == null || value <= 0) return null;
    return _round(baseline / value);
  }

  double _round(double value) =>
      double.parse(value.toStringAsFixed(3));

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  String _string(Object? value) => value?.toString().trim() ?? '';

  int _int(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
