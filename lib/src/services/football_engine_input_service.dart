import 'dart:convert';

import '../database/database.dart';

class FootballEngineInputService {
  FootballEngineInputService({required this.database});

  final PhoenixDatabase database;

  // "gemini_context" bewusst entfernt: der KI-Kontext-Schritt ist
  // deaktiviert, dieser Dienst fällt immer auf die statistische Basis
  // zurück (siehe _normalize weiter unten).
  static const modelVersion = 'goal_rate_normalization_v5_sample_size_shrinkage';

  // Bei sampleSize == k ist der Kandidat genau zur Hälfte Richtung Baseline
  // geglättet (n / (n + k) = 0.5). 8 Spiele als Halbwertspunkt heißt: eine
  // Handvoll Saisonspiele beeinflusst die Torerwartung schon spürbar, aber
  // erst ca. 20+ Spiele (ungefähr eine Rückrunde) wiegen annähernd so viel
  // wie die reine Rohquote. Bewusst derselbe Formeltyp wie das bereits
  // produktive EngineWeightConfig.shrunkTowardsGlobal (model_lab/
  // weight_config.dart), nur mit einem eigenen, für Torraten (statt eines
  // 0-1-Gewichts) sinnvollen k.
  static const sampleSizeShrinkageK = 8;

  Future<Map<String, Object?>> prepare({
    int? phaseTwoScanRunId,
    int? limit,
    bool includeBackground = false,
  }) async {
    final scanRunId = phaseTwoScanRunId;
    if (scanRunId == null) {
      return {'status': 'phase_two_scan_id_missing', 'prepared': 0};
    }

    final rows = await database.phaseFourCandidates(
      phaseTwoScanRunId: scanRunId,
      limit: limit ?? 1000000,
      includeBackground: includeBackground,
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
        contextResult: _jsonMap(row['context_result']),
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
  }) {
    final homeFor = _number(availability['homeGoalsForAverageHome']);
    final homeAgainst = _number(availability['homeGoalsAgainstAverageHome']);
    final awayFor = _number(availability['awayGoalsForAverageAway']);
    final awayAgainst = _number(availability['awayGoalsAgainstAverageAway']);

    final calculatedHome = _averageAvailable(homeFor, awayAgainst);
    final calculatedAway = _averageAvailable(awayFor, homeAgainst);
    final usesFallback = calculatedHome == null || calculatedAway == null;

    // Claude AN2.txt Section 3 ("SAMPLE-SIZE-LOGIK"): eine Torquote aus
    // wenigen Spielen ist kein stabiler Wert - live beobachtet an einem
    // Heimsieg-Tipp mit 83% Wahrscheinlichkeit, der aus goalExpectations
    // home=2.3/away=0.3 (dataQuality nur 29) entstand, ohne jede Absicherung
    // gegen eine dünne Stichprobe. `goalAverageIfPlayed` (football_service.
    // dart) unterscheidet zwar bereits "0 Spiele" von "0.0 Tore", behandelt
    // aber 2-3 Spiele identisch zuverlässig wie 25 - genau die in Section 3
    // beschriebene Lücke. Empirical-Bayes-Shrinkage Richtung neutraler
    // Baseline (1.35/1.10, dieselben Werte wie der bisherige Nulldaten-
    // Fallback), Stärke abhängig von der kleineren der beiden je Seite
    // eingehenden Spielanzahlen (Heimteam zuhause, Auswärtsteam auswärts) -
    // dieselbe Formel (n / (n + k)) wie das bereits produktive
    // EngineWeightConfig.shrunkTowardsGlobal (model_lab/weight_config.dart).
    final homePlayedHome = _int(_map(availability['homePlayed'])['home']);
    final awayPlayedAway = _int(_map(availability['awayPlayed'])['away']);
    final sampleSize = homePlayedHome < awayPlayedAway
        ? homePlayedHome
        : awayPlayedAway;

    final baseHome = _shrinkTowardsBaseline(
      calculatedHome ?? 1.35,
      baseline: 1.35,
      sampleSize: sampleSize,
    );
    final baseAway = _shrinkTowardsBaseline(
      calculatedAway ?? 1.10,
      baseline: 1.10,
      sampleSize: sampleSize,
    );
    final thinSample = !usesFallback && sampleSize < sampleSizeShrinkageK;

    final context = _map(contextResult['context']);
    final contextApplied = context['applied'] == true &&
        context['contextSource'] == 'current_scan';
    final reliability = _int(context['reliability']).clamp(0, 100);

    final homeDelta = contextApplied && reliability >= 60
        ? (_number(context['homeGoalDelta']) ?? 0).clamp(-0.15, 0.15).toDouble()
        : 0.0;
    final awayDelta = contextApplied && reliability >= 60
        ? (_number(context['awayGoalDelta']) ?? 0).clamp(-0.15, 0.15).toDouble()
        : 0.0;

    final expectedHome = (baseHome + homeDelta).clamp(0.20, 3.80).toDouble();
    final expectedAway = (baseAway + awayDelta).clamp(0.20, 3.80).toDouble();

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
          : thinSample
              ? 'goal_rates_not_xg_thin_sample_shrunk'
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
        'homeDefenseStrength': _inverseRelativeStrength(homeAgainst, 1.35) ?? 1.0,
        'awayAttackStrength': _relativeStrength(awayFor, 1.15) ?? 1.0,
        'awayDefenseStrength': _inverseRelativeStrength(awayAgainst, 1.35) ?? 1.0,
        'baseGoalRateExpectedHome': _round(baseHome),
        'baseGoalRateExpectedAway': _round(baseAway),
        'geminiHomeGoalDelta': _round(homeDelta),
        'geminiAwayGoalDelta': _round(awayDelta),
        'goalRateExpectedHome': _round(expectedHome),
        'goalRateExpectedAway': _round(expectedAway),
        'goalRateExpectedTotal': _round(expectedHome + expectedAway),
        'contextAdjusted': contextApplied && (homeDelta != 0 || awayDelta != 0),
        'sampleSize': sampleSize,
        'sampleSizeShrinkageApplied': thinSample,
      },
      'aiContext': context,
      // Section 10 (Claude AN2.txt, "KEIN GEMINI"): kein Warnhinweis mehr für
      // fehlenden KI-Kontext - der Schritt ist bewusst nie verdrahtet (siehe
      // Kommentar in football_daily_pipeline_service.dart), sein Fehlen ist
      // der dauerhafte Normalzustand, kein Fehler. `contextApplied` bleibt
      // heute strukturell immer `false`; die Felder unten bleiben trotzdem
      // bestehen, falls ein kompatibler Kontext-Dienst künftig wieder
      // angebunden wird.
      'warnings': [
        if (usesFallback) 'Torwerte fehlen teilweise; PHÖNIX nutzt eine neutrale Basis.',
        if (thinSample)
          'Nur $sampleSize gespielte Partien als Datenbasis; Torerwartung wurde Richtung Liga-Normalwert geglättet.',
        if (availability['realXgAvailable'] != true) 'Keine echten xG/xGA-Daten vorhanden.',
      ],
      'engineReady': true,
    };
  }

  Map<String, Object?> _jsonMap(Object? value) {
    if (value is Map) return Map<String, Object?>.from(value);
    if (value is String && value.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) return Map<String, Object?>.from(decoded);
      } catch (_) {}
    }
    return <String, Object?>{};
  }

  double? _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  }

  /// Öffentlich und statisch (wie `FootballService.goalAverageIfPlayed`),
  /// damit die Formel isoliert ohne Datenbank getestet werden kann.
  static double shrinkGoalRateTowardsBaseline(
    double raw, {
    required double baseline,
    required int sampleSize,
  }) {
    final safeSampleSize = sampleSize < 0 ? 0 : sampleSize;
    final factor = safeSampleSize / (safeSampleSize + sampleSizeShrinkageK);
    return double.parse((baseline + factor * (raw - baseline)).toStringAsFixed(3));
  }

  double _shrinkTowardsBaseline(
    double raw, {
    required double baseline,
    required int sampleSize,
  }) =>
      shrinkGoalRateTowardsBaseline(
        raw,
        baseline: baseline,
        sampleSize: sampleSize,
      );

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
  int _int(Object? value) => value is int
      ? value
      : value is num
          ? value.round()
          : int.tryParse(value?.toString() ?? '') ?? 0;
}
