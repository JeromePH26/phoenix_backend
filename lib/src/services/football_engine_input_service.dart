import '../database/database.dart';

class FootballEngineInputService {
  FootballEngineInputService({required this.database});

  final PhoenixDatabase database;

  static const modelVersion = 'phoenix_engine_v1_context';

  Future<Map<String, Object?>> prepare({
    required int phaseTwoScanRunId,
    int limit = 20,
  }) async {
    final rows = await database.phaseFourCandidates(
      phaseTwoScanRunId: phaseTwoScanRunId,
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
      final contextResult = _map(row['context_result']);
      final context = _map(contextResult['context']);

      final normalized = _normalize(
        fixtureId: fixtureId,
        leagueId: leagueId,
        season: season,
        dataQuality: dataQuality,
        availability: availability,
        payload: payload,
        context: context,
      );

      await database.saveFootballEngineInput(
        phaseTwoScanRunId: phaseTwoScanRunId,
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
      'phase': 4,
      'phaseTwoScanRunId': phaseTwoScanRunId,
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
    required Map<String, Object?> context,
  }) {
    final baseHome = _averageAvailable(
      _number(availability['homeGoalsForAverageHome']),
      _number(availability['awayGoalsAgainstAverageAway']),
    );
    final baseAway = _averageAvailable(
      _number(availability['awayGoalsForAverageAway']),
      _number(availability['homeGoalsAgainstAverageHome']),
    );

    final contextApplied = context['applied'] == true;
    final homeDelta =
        contextApplied ? (_number(context['homeGoalDelta']) ?? 0) : 0.0;
    final awayDelta =
        contextApplied ? (_number(context['awayGoalDelta']) ?? 0) : 0.0;

    final finalHome = baseHome == null
        ? null
        : _round((baseHome + homeDelta).clamp(0.15, 4.50));
    final finalAway = baseAway == null
        ? null
        : _round((baseAway + awayDelta).clamp(0.15, 4.50));

    final lineupConfirmed = context['lineupStatus'] == 'confirmed';
    final reliability = _int(context['reliability']);
    final critical = context['critical'] == true;

    final lineupUncertainty = lineupConfirmed ? 0.03 : 0.10;
    final contextUncertainty = contextApplied
        ? ((100 - reliability).clamp(0, 100) / 100) * 0.12
        : 0.12;
    final dataUncertainty =
        ((100 - dataQuality).clamp(0, 100) / 100) * 0.18;

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
      'sourceType': 'structured_data_plus_gemini_context',
      'realXgAvailable': availability['realXgAvailable'] == true,
      'phaseFour': {
        'baseExpectedGoals': {'home': baseHome, 'away': baseAway},
        'geminiApplied': contextApplied,
        'geminiReliability': reliability,
        'geminiGoalDelta': {'home': homeDelta, 'away': awayDelta},
        'confidenceDelta': _int(context['confidenceDelta']).clamp(-10, 5),
        'critical': critical,
        'requiresReanalysis': context['requiresReanalysis'] == true,
        'lineupStatus': context['lineupStatus'] ?? 'not_available',
        'contextSummary': context['summary'] ?? '',
        'contextFacts': context['facts'] ?? const [],
      },
      'normalized': {
        'goalRateExpectedHome': finalHome,
        'goalRateExpectedAway': finalAway,
        'goalRateExpectedTotal': _sumAvailable(finalHome, finalAway),
        'homeAttackVariance': _round(
          (0.08 + lineupUncertainty + contextUncertainty + dataUncertainty)
              .clamp(0.08, 0.40),
        ),
        'awayAttackVariance': _round(
          (0.08 + lineupUncertainty + contextUncertainty + dataUncertainty)
              .clamp(0.08, 0.40),
        ),
        'gameTempo': 1.0,
        'tempoVariance': _round(
          (0.06 + contextUncertainty + dataUncertainty).clamp(0.06, 0.30),
        ),
        'drawTendency': 1.0,
        'lineupReliability': lineupConfirmed ? 1.0 : 0.65,
        'tacticalUncertainty':
            _round((0.08 + contextUncertainty).clamp(0.08, 0.30)),
        'contextUncertainty': _round(contextUncertainty),
      },
      'warnings': [
        if (availability['realXgAvailable'] != true)
          'Keine echten xG/xGA-Daten vorhanden.',
        if (!contextApplied)
          'Gemini-Kontext wurde wegen zu geringer Verlässlichkeit neutralisiert.',
        if (!lineupConfirmed)
          'Aufstellung noch nicht bestätigt.',
        if (critical)
          'Kritische Kontextmeldung: Tipp muss besonders streng geprüft werden.',
      ],
      'engineReady': finalHome != null &&
          finalAway != null &&
          dataQuality >= 50 &&
          !critical,
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

  double _round(double value) =>
      double.parse(value.toStringAsFixed(3));

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  String _string(Object? value) => value?.toString().trim() ?? '';

  int _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
