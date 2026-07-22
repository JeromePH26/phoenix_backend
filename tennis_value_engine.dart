import 'dart:math';

import 'tennis_gemini_context_service.dart';
import 'tennis_math_engine.dart';
import 'tennis_value_risk_service.dart';

class TennisValueEngine {
  TennisValueEngine({
    TennisMathEngine? math,
    TennisGeminiContextService? gemini,
    TennisValueRiskService? risk,
  })  : math = math ?? const TennisMathEngine(),
        gemini = gemini ?? TennisGeminiContextService(),
        risk = risk ?? const TennisValueRiskService();

  static const modelVersion = 'tennis_markov_gemini_value_v1';

  final TennisMathEngine math;
  final TennisGeminiContextService gemini;
  final TennisValueRiskService risk;

  Future<Map<String, Object?>> analyze({
    required Map<String, Object?> fixture,
    required TennisSurfaceStats statsA,
    required TennisSurfaceStats statsB,
    required List<double> oddsA,
    required List<double> oddsB,
    required double bankrollEuro,
    Map<String, Object?> structuredFatigue = const {},
    int simulations = 100000,
  }) async {
    final mathResult = math.analyze(
      playerA: statsA,
      playerB: statsB,
      bestOf: _int(fixture['bestOf'], 3),
      simulations: simulations,
      seed: (fixture['id']?.toString() ?? '').hashCode,
    );

    final context = await gemini.analyze(
      playerA: fixture['playerOne']?.toString() ?? '',
      playerB: fixture['playerTwo']?.toString() ?? '',
      tournament: fixture['tournament']?.toString() ?? '',
      surface: fixture['surface']?.toString() ?? '',
      startTime: DateTime.tryParse(fixture['startTime']?.toString() ?? '') ?? DateTime.now().toUtc(),
      structuredFatigue: structuredFatigue,
    );

    final rawA = _double(mathResult['rawMatchProbA']);
    final modifierA = _double(context['modifierA']);
    final modifierB = _double(context['modifierB']);
    final finalA = _logitAdjust(rawA, modifierA - modifierB);
    final finalB = 1 - finalA;
    final quality = _int(mathResult['dataQuality'], 0);
    final uncertainty = _double(mathResult['modelUncertainty']);

    final valueA = risk.calculate(
      probability: finalA,
      odds: oddsA,
      bankrollEuro: bankrollEuro,
      dataQuality: quality,
      uncertainty: uncertainty,
    );
    final valueB = risk.calculate(
      probability: finalB,
      odds: oddsB,
      bankrollEuro: bankrollEuro,
      dataQuality: quality,
      uncertainty: uncertainty,
    );

    final stable = _int(mathResult['stabilityScore'], 0) >= 70;
    final aValue = valueA['hasValue'] == true && stable;
    final bValue = valueB['hasValue'] == true && stable;
    String? selection;
    Map<String, Object?>? selected;
    if (aValue || bValue) {
      final edgeA = _double(valueA['edgePercent']);
      final edgeB = _double(valueB['edgePercent']);
      if (aValue && (!bValue || edgeA >= edgeB)) {
        selection = fixture['playerOne']?.toString();
        selected = valueA;
      } else {
        selection = fixture['playerTwo']?.toString();
        selected = valueB;
      }
    }

    return {
      'appName': 'PHÖNIX',
      'modelVersion': modelVersion,
      'matchId': fixture['id'],
      'sport': 'tennis',
      'fixture': fixture,
      'dataQuality': {
        'score': quality,
        'sampleMatchesA': statsA.sampleMatches,
        'sampleMatchesB': statsB.sampleMatches,
      },
      'mathModel': mathResult,
      'geminiContext': context,
      'finalModel': {
        'probA': _r(finalA),
        'probB': _r(finalB),
        'fairOddsA': _r(1 / finalA),
        'fairOddsB': _r(1 / finalB),
        'confidenceIntervalA': {
          'low': _r(max(0.01, finalA - uncertainty)),
          'high': _r(min(0.99, finalA + uncertainty)),
        },
        'stabilityScore': mathResult['stabilityScore'],
      },
      'markets': {'playerA': valueA, 'playerB': valueB},
      'publication': {
        'publish': selection != null,
        'signal': selection == null ? 'NO BET' : 'VALUE BET',
        'selection': selection,
        'value': selected,
        'warnings': [
          if (quality < 60) 'Datenqualität unter 60.',
          if (!stable) 'Modell nicht stabil genug.',
          if (context['applied'] != true) 'Kein verifizierter Gemini-Kontext angewendet.',
        ],
      },
      'analyzedAt': DateTime.now().toUtc().toIso8601String(),
    };
  }

  double _logitAdjust(double p, double modifierDifference) {
    final safe = p.clamp(0.01, 0.99);
    final logit = log(safe / (1 - safe));
    return (1 / (1 + exp(-(logit + modifierDifference * 3.0))))
        .clamp(0.05, 0.95)
        .toDouble();
  }

  int _int(Object? value, int fallback) => value is int
      ? value
      : value is num
          ? value.round()
          : int.tryParse(value?.toString() ?? '') ?? fallback;

  double _double(Object? value) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '') ?? 0;

  double _r(double value) => double.parse(value.toStringAsFixed(6));

  void close() => gemini.close();
}
