import 'learning_market.dart';
import 'poisson_math.dart';
import 'weight_config.dart';

/// Ergebnis einer Model-Lab-Wahrscheinlichkeitsberechnung für EIN Match und
/// EINEN Markt, für ein gegebenes [EngineWeightConfig].
class EngineReplicaOutput {
  const EngineReplicaOutput({
    required this.market,
    required this.classProbabilities,
    required this.classLabels,
    required this.usedFallbackBaseline,
  });

  final LearningMarket market;

  /// Für 1X2: [home, draw, away]. Für binäre Märkte: [positiv, negativ]
  /// (z.B. [over, under] bzw. [bttsYes, bttsNo]).
  final List<double> classProbabilities;
  final List<String> classLabels;

  /// true, wenn eine oder beide Torquoten fehlten und auf die neutrale
  /// Baseline (1.35 Heim / 1.10 Auswärts) zurückgefallen wurde - identisch
  /// zur Fallback-Logik der produktiven Engine (Section 24: Missing != 0,
  /// niemals stillschweigend 0 statt eines echten Werts).
  final bool usedFallbackBaseline;
}

/// Reine, deterministische Model-Lab-Nachbildung der produktiven
/// Torerwartungs-Formel (`FootballEngineInputService._normalize`) und der
/// Monte-Carlo-Marktwahrscheinlichkeiten (`FootballSimulationService`),
/// parametrisiert über [EngineWeightConfig.attackWeight] statt fest 50/50.
///
/// WICHTIG: Dies verändert NICHT die produktive Engine (Section 97: PHÖNIX
/// schreibt niemals selbst Produktionscode um). Es ist eine separate,
/// Model-Lab-lokale Reproduktion derselben Formel/Verteilungsannahme, die
/// ausschließlich für Backtests/Shadow-Predictions im Learning-System
/// verwendet wird. Mit `attackWeight = 0.5` reproduziert sie exakt das
/// Verhalten der produktiven Champion-/Global-Baseline.
class EngineReplica {
  const EngineReplica._();

  static const double _fallbackHomeLambda = 1.35;
  static const double _fallbackAwayLambda = 1.10;
  static const double _minLambda = 0.20;
  static const double _maxLambda = 3.80;

  /// Berechnet Heim-/Auswärts-Torerwartung aus whitelisted Features
  /// (siehe `FeatureWhitelist`), identisch zur produktiven Fallback- und
  /// Clamp-Logik, aber mit variablem attackWeight statt fest 0.5.
  static ({double home, double away, bool usedFallback}) expectedGoals({
    required Map<String, Object?> features,
    required EngineWeightConfig weights,
  }) {
    final homeFor = _num(features['raw.homeGoalsForAverageHome']);
    final homeAgainst = _num(features['raw.homeGoalsAgainstAverageHome']);
    final awayFor = _num(features['raw.awayGoalsForAverageAway']);
    final awayAgainst = _num(features['raw.awayGoalsAgainstAverageAway']);

    final homeBlended = _blend(homeFor, awayAgainst, weights);
    final awayBlended = _blend(awayFor, homeAgainst, weights);
    final usedFallback = homeBlended == null || awayBlended == null;

    final home = (homeBlended ?? _fallbackHomeLambda)
        .clamp(_minLambda, _maxLambda)
        .toDouble();
    final away = (awayBlended ?? _fallbackAwayLambda)
        .clamp(_minLambda, _maxLambda)
        .toDouble();

    return (home: home, away: away, usedFallback: usedFallback);
  }

  /// Blend aus eigener Rate `a` (Angriff) und gegnerischer Rate `b`
  /// (Verteidigung des Gegners) mit `attackWeight`. Fehlt einer der beiden
  /// Werte, wird - wie in der produktiven Formel - der jeweils andere
  /// unverändert übernommen; fehlen beide, ist das Ergebnis `null` (führt zum
  /// neutralen Fallback, niemals zu einer stillschweigenden 0).
  static double? _blend(double? a, double? b, EngineWeightConfig weights) {
    if (a == null && b == null) return null;
    if (a == null) return b;
    if (b == null) return a;
    return weights.attackWeight * a + weights.defenseWeight * b;
  }

  static EngineReplicaOutput evaluate({
    required LearningMarket market,
    required Map<String, Object?> features,
    required EngineWeightConfig weights,
  }) {
    final goals = expectedGoals(features: features, weights: weights);

    switch (market) {
      case LearningMarket.oneXTwo:
        final probabilities = PoissonMath.matchResultProbabilities(
          goals.home,
          goals.away,
        );
        return EngineReplicaOutput(
          market: market,
          classProbabilities: [
            probabilities.home,
            probabilities.draw,
            probabilities.away,
          ],
          classLabels: const ['home', 'draw', 'away'],
          usedFallbackBaseline: goals.usedFallback,
        );
      case LearningMarket.overUnder25:
        final probabilities = PoissonMath.overUnderProbabilities(
          goals.home,
          goals.away,
          2.5,
        );
        return EngineReplicaOutput(
          market: market,
          classProbabilities: [probabilities.over, probabilities.under],
          classLabels: const ['over25', 'under25'],
          usedFallbackBaseline: goals.usedFallback,
        );
      case LearningMarket.btts:
        final probabilities = PoissonMath.bttsProbabilities(
          goals.home,
          goals.away,
        );
        return EngineReplicaOutput(
          market: market,
          classProbabilities: [probabilities.yes, probabilities.no],
          classLabels: const ['bttsYes', 'bttsNo'],
          usedFallbackBaseline: goals.usedFallback,
        );
    }
  }

  static double? _num(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }
}
