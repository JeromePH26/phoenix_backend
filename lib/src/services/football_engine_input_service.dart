import '../database/database.dart';

class FootballEngineInputService {
  FootballEngineInputService({required this.database});

  final PhoenixDatabase database;

  static const modelVersion = 'goal_rate_normalization_v5_context_persistence';

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
        contextResult: _map(row['context_result']),
        contextSource: _string(row['context_source']),
        contextSourceScanRunId: _int(row['context_source_scan_run_id']),
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
    required Map<String, Object?> contextResult,
    required String contextSource,
    required int contextSourceScanRunId,
  }) {
    final homeFor = _number(availability['homeGoalsForAverageHome']);
    final homeAgainst = _number(availability['homeGoalsAgainstAverageHome']);
    final awayFor = _number(availability['awayGoalsForAverageAway']);
    final awayAgainst = _number(availability['awayGoalsAgainstAverageAway']);

    final calculatedHome = _averageAvailable(homeFor, awayAgainst);
    final calculatedAway = _averageAvailable(awayFor, homeAgainst);
    final usesFallback = calculatedHome == null || calculatedAway == null;

    final contextWrapper = _map(contextResult['context']);
    final context = contextWrapper.isNotEmpty ? contextWrapper : contextResult;
    final reliability = _int(context['reliability']).clamp(0, 100);
    final contextApplied = context['applied'] == true && reliability >= 60;

    // Diese beiden Deltas enthalten bereits die gesamte zulässige Wirkung
    // aus Taktik, Pressing, Wichtigkeit, Personal und sonstigem Kontext.
    // Einzelne taktische Teilwerte werden deshalb nicht erneut addiert.
    final homeGoalDelta = contextApplied
        ? (_number(context['homeGoalDelta']) ?? 0).clamp(-0.20, 0.20).toDouble()
        : 0.0;
    final awayGoalDelta = contextApplied
        ? (_number(context['awayGoalDelta']) ?? 0).clamp(-0.20, 0.20).toDouble()
        : 0.0;
    final confidenceDelta = contextApplied
        ? _int(context['confidenceDelta']).clamp(-10, 5)
        : 0;

    final matchImportance = _map(context['matchImportance']);
    final homeTactics = _map(context['homeTacticalProfile']);
    final awayTactics = _map(context['awayTacticalProfile']);
    final tacticalMatchup = _map(context['tacticalMatchup']);

    final baseHome = calculatedHome ?? 1.35;
    final baseAway = calculatedAway ?? 1.10;
    final expectedHome = _goalRate(baseHome + homeGoalDelta);
    final expectedAway = _goalRate(baseAway + awayGoalDelta);
    final lineupConfirmed = context['lineupStatus'] == 'confirmed';

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
      'lineupConfirmed': lineupConfirmed,
      'aiContextApplied': contextApplied,
      'tacticalContextAvailable':
          homeTactics.isNotEmpty && awayTactics.isNotEmpty,
      'confidenceDelta': confidenceDelta,
      'aiContext': {
        'applied': contextApplied,
        'contextSource': contextSource.isEmpty ? 'missing' : contextSource,
        'contextSourceScanRunId': contextSourceScanRunId,
        'fallbackUsed': contextSource == 'fallback',
        'provider': context['provider'],
        'model': context['model'],
        'verificationStatus': context['verificationStatus'],
        'reliability': reliability,
        'homeContextScore': _int(context['homeContextScore']),
        'awayContextScore': _int(context['awayContextScore']),
        'homeGoalDelta': homeGoalDelta,
        'awayGoalDelta': awayGoalDelta,
        'confidenceDelta': confidenceDelta,
        'lineupStatus': context['lineupStatus'],
        'critical': context['critical'] == true,
        'requiresReanalysis': context['requiresReanalysis'] == true,
        'matchImportance': matchImportance,
        'homeTacticalProfile': homeTactics,
        'awayTacticalProfile': awayTactics,
        'tacticalMatchup': tacticalMatchup,
        'summary': context['summary'],
        'facts': context['facts'],
        'sourceUrls': context['sourceUrls'],
      },
      'tacticalSummary': {
        'matchImportanceLevel': _string(matchImportance['level']),
        'pressureLevel': _int(matchImportance['pressureLevel']).clamp(0, 100),
        'homeMotivation':
            _int(matchImportance['homeMotivation']).clamp(-100, 100),
        'awayMotivation':
            _int(matchImportance['awayMotivation']).clamp(-100, 100),
        'homePressingIntensity':
            _int(homeTactics['pressingIntensity']).clamp(0, 100),
        'awayPressingIntensity':
            _int(awayTactics['pressingIntensity']).clamp(0, 100),
        'homePressResistance':
            _int(homeTactics['pressResistance']).clamp(0, 100),
        'awayPressResistance':
            _int(awayTactics['pressResistance']).clamp(0, 100),
        'expectedPressingLevel':
            _int(tacticalMatchup['expectedPressingLevel']).clamp(0, 100),
        'expectedTempo':
            _int(tacticalMatchup['expectedTempo']).clamp(0, 100),
        'fieldTiltHome':
            _int(tacticalMatchup['fieldTiltHome']).clamp(-100, 100),
        'likelyGameState': tacticalMatchup['likelyGameState'],
      },
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
        'goalRateBeforeContextHome': _round(baseHome),
        'goalRateBeforeContextAway': _round(baseAway),
        'goalRateExpectedHome': _round(expectedHome),
        'goalRateExpectedAway': _round(expectedAway),
        'goalRateExpectedTotal': _round(expectedHome + expectedAway),
      },
      'warnings': [
        if (usesFallback)
          'Torwerte fehlen teilweise; PHÖNIX nutzt vorübergehend eine neutrale Basis.',
        if (availability['realXgAvailable'] != true)
          'Keine echten xG/xGA-Daten vorhanden.',
        if (contextResult.isEmpty)
          'Keine aktuelle KI-Kontextprüfung gespeichert.',
        if (contextResult.isNotEmpty && !contextApplied)
          'KI-Kontext wurde wegen zu geringer Verlässlichkeit nicht angewendet.',
        if (homeTactics.isEmpty || awayTactics.isEmpty)
          'Mindestens ein taktisches Teamprofil fehlt.',
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

  double _goalRate(double value) => value.clamp(0.20, 3.80).toDouble();

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
