import '../database/database.dart';

class FootballEngineInputService {
  FootballEngineInputService({required this.database});

  final PhoenixDatabase database;

  static const modelVersion = 'goal_rate_normalization_v2';

  Future<Map<String, Object?>> prepare({
    int? phaseTwoScanRunId,
    int limit = 20,
  }) async {
    final scanRunId = phaseTwoScanRunId;

    if (scanRunId == null) {
      return {
        'status': 'phase_two_scan_id_missing',
        'prepared': 0,
      };
    }

    final rows = await database.phaseFourCandidates(
      phaseTwoScanRunId: scanRunId,
      limit: limit.clamp(1, 20),
    );

    final results = <Map<String, Object?>>[];

    for (final row in rows) {
      final fixtureId = _string(row['fixture_id']);
      if (fixtureId.isEmpty) continue;

      final normalized = _normalize(
        fixtureId: fixtureId,
        leagueId: _string(row['league_id']),
        season: _int(row['season']),
        dataQuality: _int(row['data_quality']),
        availability: _map(row['availability']),
        payload: _map(row['payload']),
      );

      await database.saveFootballEngineInput(
        phaseTwoScanRunId: scanRunId,
        fixtureId: fixtureId,
        leagueId: _string(row['league_id']),
        season: _int(row['season']),
        dataQuality: _int(row['data_quality']),
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
    final homeFor = _number(availability['homeGoalsForAverageHome']);
    final homeAgainst = _number(availability['homeGoalsAgainstAverageHome']);
    final awayFor = _number(availability['awayGoalsForAverageAway']);
    final awayAgainst = _number(availability['awayGoalsAgainstAverageAway']);

    final calculatedHome = _averageAvailable(homeFor, awayAgainst);
    final calculatedAway = _averageAvailable(awayFor, homeAgainst);

    // Stabiler Minimal-Fallback, damit die Pipeline auch bei dünner
    // API-Abdeckung vollständig getestet und gespeichert werden kann.
    final expectedHome = calculatedHome ?? 1.35;
    final expectedAway = calculatedAway ?? 1.10;
    final usesFallback = calculatedHome == null || calculatedAway == null;

    return {
      'fixtureId': fixtureId,
      'leagueId': leagueId,
      'season': season,
      'homeTeam': _string(payload['homeTeam']),
      'awayTeam': _string(payload['awayTeam']),
      'league': _string(payload['league']),
      'kickoff': _string(payload['kickoff']),
      'status': _string(payload['status']),
      'country': _string(payload['country']),
      'homeTeamId': _string(payload['homeTeamId']),
      'awayTeamId': _string(payload['awayTeamId']),
      'homeLogo': _string(payload['homeLogo']),
      'awayLogo': _string(payload['awayLogo']),
      'dataQuality': dataQuality,
      'modelVersion': modelVersion,
      'sourceType': usesFallback
          ? 'safe_baseline_fallback'
          : 'goal_rates_not_xg',
      'realXgAvailable': availability['realXgAvailable'] == true,
      'raw': {
        'homeGoalsForAverageHome': homeFor,
        'homeGoalsAgainstAverageHome': homeAgainst,
        'awayGoalsForAverageAway': awayFor,
        'awayGoalsAgainstAverageAway': awayAgainst,
      },
      'normalized': {
        'homeAttackStrength': _relativeStrength(homeFor, 1.35) ?? 1.0,
        'homeDefenseStrength':
            _inverseRelativeStrength(homeAgainst, 1.35) ?? 1.0,
        'awayAttackStrength': _relativeStrength(awayFor, 1.15) ?? 1.0,
        'awayDefenseStrength':
            _inverseRelativeStrength(awayAgainst, 1.35) ?? 1.0,
        'goalRateExpectedHome': _round(expectedHome),
        'goalRateExpectedAway': _round(expectedAway),
        'goalRateExpectedTotal': _round(expectedHome + expectedAway),
      },
      'warnings': [
        if (usesFallback)
          'Torwerte fehlen teilweise; PHÖNIX nutzt vorübergehend eine neutrale Basis.',
        if (availability['realXgAvailable'] != true)
          'Keine echten xG/xGA-Daten vorhanden.',
      ],
      'engineReady': true,
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

  double? _relativeStrength(double? value, double baseline) {
    if (value == null || baseline <= 0) return null;
    return _round(value / baseline);
  }

  double? _inverseRelativeStrength(double? value, double baseline) {
    if (value == null || value <= 0) return null;
    return _round(baseline / value);
  }

  double _round(double value) => double.parse(value.toStringAsFixed(3));

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  String _string(Object? value) => value?.toString().trim() ?? '';

  int _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
