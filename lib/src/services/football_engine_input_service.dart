import '../database/database.dart';

class FootballEngineInputService {
  FootballEngineInputService({required this.database});
  final PhoenixDatabase database;

  static const modelVersion = 'goal_rate_normalization_v4_zero_stats_guard';

  Future<Map<String, Object?>> prepare({int? phaseTwoScanRunId, int limit = 20}) async {
    final scanRunId = phaseTwoScanRunId;
    if (scanRunId == null) return {'status': 'phase_two_scan_id_missing', 'prepared': 0};
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
        contextResult: _map(row['context_result']),
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
    return {'status': 'prepared', 'phaseTwoScanRunId': scanRunId, 'modelVersion': modelVersion, 'prepared': results.length, 'results': results};
  }

  Map<String, Object?> _normalize({
    required String fixtureId,
    required String leagueId,
    required int season,
    required int dataQuality,
    required Map<String, Object?> availability,
    required Map<String, Object?> payload,
    required Map<String, Object?> contextResult,
  }) {
    final homePlayed = _playedTotal(availability['homePlayed'] ?? availability['homePlayedTotal']);
    final awayPlayed = _playedTotal(availability['awayPlayed'] ?? availability['awayPlayedTotal']);
    final homeStatsUsable = availability['homeTeamStatistics'] == true && homePlayed >= 3;
    final awayStatsUsable = availability['awayTeamStatistics'] == true && awayPlayed >= 3;

    final homeFor = homeStatsUsable ? _positiveNumber(availability['homeGoalsForAverageHome']) : null;
    final homeAgainst = homeStatsUsable ? _positiveNumber(availability['homeGoalsAgainstAverageHome']) : null;
    final awayFor = awayStatsUsable ? _positiveNumber(availability['awayGoalsForAverageAway']) : null;
    final awayAgainst = awayStatsUsable ? _positiveNumber(availability['awayGoalsAgainstAverageAway']) : null;

    final calculatedHome = _averageAvailable(homeFor, awayAgainst);
    final calculatedAway = _averageAvailable(awayFor, homeAgainst);
    final baseExpectedHome = calculatedHome ?? 1.35;
    final baseExpectedAway = calculatedAway ?? 1.10;
    final usesFallback = calculatedHome == null || calculatedAway == null;

    final rawContext = _map(contextResult['context']);
    final reliability = _int(rawContext['reliability']).clamp(0, 100);
    final verificationStatus = _string(rawContext['verificationStatus']).isEmpty ? 'unclear' : _string(rawContext['verificationStatus']);
    final contextApplied = _bool(rawContext['applied']) && reliability >= 60 && verificationStatus != 'unclear';
    final homeGoalDelta = contextApplied ? ((_number(rawContext['homeGoalDelta']) ?? 0).clamp(-0.20, 0.20).toDouble()) : 0.0;
    final awayGoalDelta = contextApplied ? ((_number(rawContext['awayGoalDelta']) ?? 0).clamp(-0.20, 0.20).toDouble()) : 0.0;
    final confidenceDelta = contextApplied ? _int(rawContext['confidenceDelta']).clamp(-10, 5) : 0;

    final expectedHome = (baseExpectedHome + homeGoalDelta).clamp(0.35, 4.5).toDouble();
    final expectedAway = (baseExpectedAway + awayGoalDelta).clamp(0.25, 4.5).toDouble();

    final aiContext = <String, Object?>{
      'applied': contextApplied,
      'provider': rawContext['provider'],
      'model': rawContext['model'],
      'verificationStatus': verificationStatus,
      'reliability': reliability,
      'summary': rawContext['summary'],
      'homeGoalDelta': _round(homeGoalDelta),
      'awayGoalDelta': _round(awayGoalDelta),
      'confidenceDelta': confidenceDelta,
      'lineupStatus': rawContext['lineupStatus'],
      'critical': rawContext['critical'] == true,
      'requiresReanalysis': rawContext['requiresReanalysis'] == true,
      'facts': rawContext['facts'] is List ? List<Object?>.from(rawContext['facts'] as List) : <Object?>[],
      'sourceUrls': rawContext['sourceUrls'] is List ? List<Object?>.from(rawContext['sourceUrls'] as List) : <Object?>[],
      'contextSource': rawContext['contextSource'],
      'contextSourceScanRunId': rawContext['contextSourceScanRunId'],
      'fallbackUsed': rawContext['fallbackUsed'] == true,
    };

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
      'sourceType': contextApplied
          ? (usesFallback ? 'safe_baseline_fallback_gemini_adjusted' : 'goal_rates_gemini_adjusted')
          : (usesFallback ? 'safe_baseline_fallback' : 'goal_rates_not_xg'),
      'realXgAvailable': availability['realXgAvailable'] == true,
      'raw': {
        'homePlayed': homePlayed,
        'awayPlayed': awayPlayed,
        'homeStatisticsUsable': homeStatsUsable,
        'awayStatisticsUsable': awayStatsUsable,
        'homeGoalsForAverageHome': homeFor,
        'homeGoalsAgainstAverageHome': homeAgainst,
        'awayGoalsForAverageAway': awayFor,
        'awayGoalsAgainstAverageAway': awayAgainst,
      },
      'normalized': {
        'homeAttackStrength': _relativeStrength(homeFor, 1.35) ?? 1.0,
        'homeDefenseStrength': _inverseRelativeStrength(homeAgainst, 1.35) ?? 1.0,
        'awayAttackStrength': _relativeStrength(awayFor, 1.15) ?? 1.0,
        'awayDefenseStrength': _inverseRelativeStrength(awayAgainst, 1.35) ?? 1.0,
        'baseGoalRateExpectedHome': _round(baseExpectedHome),
        'baseGoalRateExpectedAway': _round(baseExpectedAway),
        'goalRateExpectedHome': _round(expectedHome),
        'goalRateExpectedAway': _round(expectedAway),
        'goalRateExpectedTotal': _round(expectedHome + expectedAway),
        'contextAdjusted': contextApplied,
      },
      'aiContext': aiContext,
      'warnings': [
        if (!homeStatsUsable || !awayStatsUsable) 'Saisonstatistik ist noch nicht ausreichend bespielt.',
        if (usesFallback) 'PHÖNIX nutzt eine neutrale Torbasis statt leerer 0,0-Werte.',
        if (availability['realXgAvailable'] != true) 'Keine echten xG/xGA-Daten vorhanden.',
        if (contextApplied) 'Verifizierter Gemini-Kontext wurde vor der Simulation angewendet.',
        if (!contextApplied) 'Kein ausreichend verifizierter Gemini-Kontext angewendet.',
        if (aiContext['fallbackUsed'] == true) 'Verifizierter Kontext eines vorherigen Laufs wurde wiederverwendet.',
      ],
      'engineReady': true,
    };
  }

  int _playedTotal(Object? value) { final map = _map(value); return map.isNotEmpty ? _int(map['total']) : _int(value); }
  double? _positiveNumber(Object? value) { final n = _number(value); return n == null || n <= 0 ? null : n; }
  double? _number(Object? value) => value is num ? value.toDouble() : double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  double? _averageAvailable(double? a, double? b) { if (a == null && b == null) return null; if (a == null) return _round(b!); if (b == null) return _round(a); return _round((a + b) / 2); }
  double? _relativeStrength(double? value, double baseline) => value == null || baseline <= 0 ? null : _round(value / baseline);
  double? _inverseRelativeStrength(double? value, double baseline) => value == null || value <= 0 ? null : _round(baseline / value);
  bool _bool(Object? value) => value is bool ? value : value?.toString().toLowerCase() == 'true';
  double _round(double value) => double.parse(value.toStringAsFixed(3));
  Map<String, Object?> _map(Object? value) => value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};
  String _string(Object? value) => value?.toString().trim() ?? '';
  int _int(Object? value) => value is int ? value : value is num ? value.round() : int.tryParse(value?.toString() ?? '') ?? 0;
}
