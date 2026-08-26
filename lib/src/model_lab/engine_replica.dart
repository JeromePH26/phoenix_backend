import 'dixon_coles_engine.dart';
import 'global_goals_v1_engine.dart';
import 'global_market_engine.dart';
import 'learning_market.dart';
import 'learning_sample.dart';
import 'poisson_math.dart';
import 'team_strength_engine.dart';
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
    double rho = 0.0,
  }) {
    final goals = expectedGoals(features: features, weights: weights);
    return evaluateGoals(market: market, goals: goals, rho: rho);
  }

  /// Wie [evaluate], nimmt aber eine bereits berechnete Torerwartung
  /// entgegen statt sie selbst aus [weights] herzuleiten. Das trennt die
  /// eigentliche Markt-Wahrscheinlichkeitsberechnung (Poisson, engine-
  /// unabhängig) von der Frage, WIE die Torerwartung zustande kam -
  /// notwendig, damit auch das GLOBAL_GOALS_V1-Modell (siehe `ModelEngine`
  /// unten), das keine `EngineWeightConfig` verwendet, dieselbe
  /// Markt-Logik nutzen kann statt sie zu duplizieren.
  ///
  /// [rho] (Default `0.0` = bisheriges, unabhängiges Poisson-Verhalten,
  /// unverändert) ist der Dixon-Coles-Korrelationsfaktor für die
  /// zweiseitigen Märkte (1X2, Über/Unter, BTTS, Doppelte Chance, Draw No
  /// Bet - alle aus derselben gemeinsamen Score-Matrix abgeleitet, siehe
  /// `PoissonMath.scoreMatrix`). Die Team-Tor-Märkte betreffen nur eine
  /// Seite und bleiben bewusst unverändert (Standard-Dixon-Coles-Praxis:
  /// die Korrelation korrigiert das gemeinsame Ergebnis, nicht die
  /// einseitige Randverteilung).
  static EngineReplicaOutput evaluateGoals({
    required LearningMarket market,
    required ({double home, double away, bool usedFallback}) goals,
    double rho = 0.0,
  }) {
    switch (market) {
      case LearningMarket.oneXTwo:
        final probabilities = PoissonMath.matchResultProbabilities(
          goals.home,
          goals.away,
          rho: rho,
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
          rho: rho,
        );
        return EngineReplicaOutput(
          market: market,
          classProbabilities: [probabilities.over, probabilities.under],
          classLabels: const ['over25', 'under25'],
          usedFallbackBaseline: goals.usedFallback,
        );
      case LearningMarket.overUnder15:
        final probabilities = PoissonMath.overUnderProbabilities(
          goals.home,
          goals.away,
          1.5,
          rho: rho,
        );
        return EngineReplicaOutput(
          market: market,
          classProbabilities: [probabilities.over, probabilities.under],
          classLabels: const ['over15', 'under15'],
          usedFallbackBaseline: goals.usedFallback,
        );
      case LearningMarket.overUnder35:
        final probabilities = PoissonMath.overUnderProbabilities(
          goals.home,
          goals.away,
          3.5,
          rho: rho,
        );
        return EngineReplicaOutput(
          market: market,
          classProbabilities: [probabilities.over, probabilities.under],
          classLabels: const ['over35', 'under35'],
          usedFallbackBaseline: goals.usedFallback,
        );
      case LearningMarket.btts:
        final probabilities = PoissonMath.bttsProbabilities(
          goals.home,
          goals.away,
          rho: rho,
        );
        return EngineReplicaOutput(
          market: market,
          classProbabilities: [probabilities.yes, probabilities.no],
          classLabels: const ['bttsYes', 'bttsNo'],
          usedFallbackBaseline: goals.usedFallback,
        );
      case LearningMarket.homeTeamOver15:
        final probabilities = PoissonMath.teamOverUnderProbabilities(
          goals.home,
          1.5,
        );
        return EngineReplicaOutput(
          market: market,
          classProbabilities: [probabilities.over, probabilities.under],
          classLabels: const ['homeOver15', 'homeUnder15'],
          usedFallbackBaseline: goals.usedFallback,
        );
      case LearningMarket.homeTeamUnder15:
        final probabilities = PoissonMath.teamOverUnderProbabilities(
          goals.home,
          1.5,
        );
        return EngineReplicaOutput(
          market: market,
          classProbabilities: [probabilities.under, probabilities.over],
          classLabels: const ['homeUnder15', 'homeOver15'],
          usedFallbackBaseline: goals.usedFallback,
        );
      case LearningMarket.awayTeamOver15:
        final probabilities = PoissonMath.teamOverUnderProbabilities(
          goals.away,
          1.5,
        );
        return EngineReplicaOutput(
          market: market,
          classProbabilities: [probabilities.over, probabilities.under],
          classLabels: const ['awayOver15', 'awayUnder15'],
          usedFallbackBaseline: goals.usedFallback,
        );
      case LearningMarket.awayTeamUnder15:
        final probabilities = PoissonMath.teamOverUnderProbabilities(
          goals.away,
          1.5,
        );
        return EngineReplicaOutput(
          market: market,
          classProbabilities: [probabilities.under, probabilities.over],
          classLabels: const ['awayUnder15', 'awayOver15'],
          usedFallbackBaseline: goals.usedFallback,
        );
      case LearningMarket.homeTeamOver25:
        final probabilities = PoissonMath.teamOverUnderProbabilities(
          goals.home,
          2.5,
        );
        return EngineReplicaOutput(
          market: market,
          classProbabilities: [probabilities.over, probabilities.under],
          classLabels: const ['homeOver25', 'homeUnder25'],
          usedFallbackBaseline: goals.usedFallback,
        );
      case LearningMarket.homeTeamUnder25:
        final probabilities = PoissonMath.teamOverUnderProbabilities(
          goals.home,
          2.5,
        );
        return EngineReplicaOutput(
          market: market,
          classProbabilities: [probabilities.under, probabilities.over],
          classLabels: const ['homeUnder25', 'homeOver25'],
          usedFallbackBaseline: goals.usedFallback,
        );
      case LearningMarket.awayTeamOver25:
        final probabilities = PoissonMath.teamOverUnderProbabilities(
          goals.away,
          2.5,
        );
        return EngineReplicaOutput(
          market: market,
          classProbabilities: [probabilities.over, probabilities.under],
          classLabels: const ['awayOver25', 'awayUnder25'],
          usedFallbackBaseline: goals.usedFallback,
        );
      case LearningMarket.awayTeamUnder25:
        final probabilities = PoissonMath.teamOverUnderProbabilities(
          goals.away,
          2.5,
        );
        return EngineReplicaOutput(
          market: market,
          classProbabilities: [probabilities.under, probabilities.over],
          classLabels: const ['awayUnder25', 'awayOver25'],
          usedFallbackBaseline: goals.usedFallback,
        );
      case LearningMarket.doubleChance1x:
        final probabilities = PoissonMath.matchResultProbabilities(
          goals.home,
          goals.away,
          rho: rho,
        );
        final yes = probabilities.home + probabilities.draw;
        return EngineReplicaOutput(
          market: market,
          classProbabilities: [yes, 1 - yes],
          classLabels: const ['dc1x', 'dc1xNo'],
          usedFallbackBaseline: goals.usedFallback,
        );
      case LearningMarket.doubleChanceX2:
        final probabilities = PoissonMath.matchResultProbabilities(
          goals.home,
          goals.away,
          rho: rho,
        );
        final yes = probabilities.draw + probabilities.away;
        return EngineReplicaOutput(
          market: market,
          classProbabilities: [yes, 1 - yes],
          classLabels: const ['dcX2', 'dcX2No'],
          usedFallbackBaseline: goals.usedFallback,
        );
      case LearningMarket.drawNoBetHome:
        final probabilities = PoissonMath.matchResultProbabilities(
          goals.home,
          goals.away,
          rho: rho,
        );
        return EngineReplicaOutput(
          market: market,
          classProbabilities: [
            probabilities.home,
            probabilities.draw,
            probabilities.away,
          ],
          classLabels: const ['won', 'push', 'lost'],
          usedFallbackBaseline: goals.usedFallback,
        );
      case LearningMarket.drawNoBetAway:
        final probabilities = PoissonMath.matchResultProbabilities(
          goals.home,
          goals.away,
          rho: rho,
        );
        return EngineReplicaOutput(
          market: market,
          classProbabilities: [
            probabilities.away,
            probabilities.draw,
            probabilities.home,
          ],
          classLabels: const ['won', 'push', 'lost'],
          usedFallbackBaseline: goals.usedFallback,
        );
    }
  }

  static double? _num(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }
}

enum _ModelEngineKind {
  attackWeightBlend,
  globalGoalsV1,
  globalMarket,
  dixonColes,
  teamStrength,
}

/// Welche Formel ein konkretes Model verwendet, um aus einem [LearningSample]
/// eine Torerwartung abzuleiten. Ein Model verwendet immer GENAU eine
/// Formel, nie eine Mischung:
/// - `attackWeightBlend`: die ursprüngliche V0-Formel (`EngineReplica`,
///   ein einziger Freiheitsgrad, siehe `weight_config.dart`).
/// - `globalGoalsV1`: das erste sechs-Feature-gewichtete Modell
///   (`GlobalGoalsV1Engine`), bereits produktiv als Challenger im Einsatz -
///   bleibt unverändert bestehen (Section 12: nie still verändern).
/// - `globalMarket`: die Nachfolge-Generation (`GlobalMarketEngine`,
///   Claude AN2.txt) mit eigenem Gewichtsprofil je Marktfamilie und
///   optionalen benannten Hypothesis-Varianten (`GlobalMarketHypothesis`).
/// - `dixonColes`: testet einen Korrelationsausgleich für niedrige
///   Ergebnisse (`DixonColesEngine`/`PoissonMath.scoreMatrix`) auf denselben
///   Torerwartungen wie der globale Champion (attackWeight 0.5) - `rho` ist
///   die einzige Testvariable (Section 4: gemeinsame Score-Verteilung statt
///   unabhängiger Markt-Formeln).
/// - `teamStrength`: nutzt ein VORHER (einmal pro Liga, aus der gesamten
///   verfügbaren Spielhistorie) gefittetes `TeamStrengthFit`
///   (`TeamStrengthEngine`, IPF-Angriff/Abwehr-Modell) statt Torquoten aus
///   `sample.features` abzuleiten - architektonisch anders als die übrigen
///   Kinds: das Fit-Objekt kommt von außen (siehe `learning_run_service.
///   dart`, ein Fit pro Liga wird über alle Märkte hinweg wiederverwendet),
///   nicht aus dem einzelnen Sample. Live gegen PHÖNIX-Daten getestet
///   (Plan "wild-cuddling-hoare", Phase 2, Backtest mit Shrinkage-
///   Regularisierung): auf 9 Ligen/98 Holdout-Spielen deutlich besser als
///   der einfache Durchschnitt (Ø Brier -7,3%).
///
/// `globalGoalsV1`, `globalMarket` und `teamStrength` liefern `null` aus
/// [evaluate], wenn für das Sample kein leakage-sicherer Phase-2-Snapshot
/// (Team-IDs) vorhanden ist - die attackWeight-Formel (und damit auch
/// `dixonColes`, die dieselben Torerwartungen nutzt) hat immer einen
/// neutralen Fallback und liefert nie `null`.
class ModelEngine {
  const ModelEngine.attackWeightBlend(EngineWeightConfig weights)
      : _kind = _ModelEngineKind.attackWeightBlend,
        _attackWeightConfig = weights,
        _globalMarketFamily = null,
        _globalMarketWeights = null,
        _globalMarketHypothesis = null,
        _dixonColesRho = null,
        _teamStrengthFit = null;

  const ModelEngine.globalGoalsV1()
      : _kind = _ModelEngineKind.globalGoalsV1,
        _attackWeightConfig = null,
        _globalMarketFamily = null,
        _globalMarketWeights = null,
        _globalMarketHypothesis = null,
        _dixonColesRho = null,
        _teamStrengthFit = null;

  /// [hypothesis] `null` bedeutet: der Basis-Preset der Marktfamilie (der
  /// Champion selbst), sonst eine benannte, abweichende Gewichts-Variante.
  ModelEngine.globalMarket(
    GlobalMarketFamily family, {
    GlobalMarketHypothesis? hypothesis,
  })  : _kind = _ModelEngineKind.globalMarket,
        _attackWeightConfig = null,
        _globalMarketFamily = family,
        _globalMarketWeights = hypothesis == null
            ? GlobalMarketWeights.presets[family]!
            : hypothesis.apply(GlobalMarketWeights.presets[family]!),
        _globalMarketHypothesis = hypothesis,
        _dixonColesRho = null,
        _teamStrengthFit = null;

  /// [rho] siehe `DixonColesEngine.rhoCandidates`/`PoissonMath.dixonColesTau`.
  const ModelEngine.dixonColes(double rho)
      : _kind = _ModelEngineKind.dixonColes,
        _attackWeightConfig = null,
        _globalMarketFamily = null,
        _globalMarketWeights = null,
        _globalMarketHypothesis = null,
        _dixonColesRho = rho,
        _teamStrengthFit = null;

  /// [fit] muss vorher einmal pro Liga berechnet werden (siehe
  /// `TeamStrengthEngine.fit`) - dieser Konstruktor führt selbst kein
  /// Fitting durch.
  const ModelEngine.teamStrength(TeamStrengthFit fit)
      : _kind = _ModelEngineKind.teamStrength,
        _attackWeightConfig = null,
        _globalMarketFamily = null,
        _globalMarketWeights = null,
        _globalMarketHypothesis = null,
        _dixonColesRho = null,
        _teamStrengthFit = fit;

  final _ModelEngineKind _kind;
  final EngineWeightConfig? _attackWeightConfig;
  final GlobalMarketFamily? _globalMarketFamily;
  final double? _dixonColesRho;
  final GlobalMarketWeights? _globalMarketWeights;
  final GlobalMarketHypothesis? _globalMarketHypothesis;
  final TeamStrengthFit? _teamStrengthFit;

  bool get isGlobalGoalsV1 => _kind == _ModelEngineKind.globalGoalsV1;
  bool get isGlobalMarket => _kind == _ModelEngineKind.globalMarket;
  bool get isDixonColes => _kind == _ModelEngineKind.dixonColes;
  bool get isTeamStrength => _kind == _ModelEngineKind.teamStrength;

  EngineReplicaOutput? evaluate({
    required LearningMarket market,
    required LearningSample sample,
  }) {
    switch (_kind) {
      case _ModelEngineKind.attackWeightBlend:
        return EngineReplica.evaluate(
          market: market,
          features: sample.features,
          weights: _attackWeightConfig!,
        );
      case _ModelEngineKind.globalGoalsV1:
        final home = sample.globalGoalsV1ExpectedHome;
        final away = sample.globalGoalsV1ExpectedAway;
        if (home == null || away == null) return null;
        return EngineReplica.evaluateGoals(
          market: market,
          goals: (home: home, away: away, usedFallback: false),
        );
      case _ModelEngineKind.globalMarket:
        if (!sample.hasGlobalMarketData) return null;
        final result = GlobalMarketEngine.compute(
          family: _globalMarketFamily!,
          availability: sample.globalMarketAvailability!,
          homeTeamId: sample.globalMarketHomeTeamId!,
          awayTeamId: sample.globalMarketAwayTeamId!,
          leagueAvgHomeGoalsPerGame: sample.globalMarketLeagueAvgHomeGoals,
          leagueAvgAwayGoalsPerGame: sample.globalMarketLeagueAvgAwayGoals,
          weightsOverride: _globalMarketWeights,
        );
        final home = result.expectedHome;
        final away = result.expectedAway;
        if (home == null || away == null) return null;
        return EngineReplica.evaluateGoals(
          market: market,
          goals: (home: home, away: away, usedFallback: false),
        );
      case _ModelEngineKind.dixonColes:
        return EngineReplica.evaluate(
          market: market,
          features: sample.features,
          weights: EngineWeightConfig.global,
          rho: _dixonColesRho!,
        );
      case _ModelEngineKind.teamStrength:
        if (!sample.hasGlobalMarketData) return null;
        final goals = TeamStrengthEngine.expectedGoals(
          fit: _teamStrengthFit!,
          homeTeamId: sample.globalMarketHomeTeamId!,
          awayTeamId: sample.globalMarketAwayTeamId!,
        );
        return EngineReplica.evaluateGoals(
          market: market,
          goals: (home: goals.home, away: goals.away, usedFallback: false),
        );
    }
  }

  Map<String, Object?> toJson() {
    switch (_kind) {
      case _ModelEngineKind.attackWeightBlend:
        return _attackWeightConfig!.toJson();
      case _ModelEngineKind.globalGoalsV1:
        return {'engineVersion': GlobalGoalsV1Engine.version};
      case _ModelEngineKind.globalMarket:
        return {
          'engineVersion': _globalMarketFamily!.version,
          if (_globalMarketHypothesis case final hypothesis?) 'hypothesis': hypothesis.key,
        };
      case _ModelEngineKind.dixonColes:
        return {
          'engineVersion': DixonColesEngine.version,
          'rho': _dixonColesRho,
        };
      case _ModelEngineKind.teamStrength:
        final fit = _teamStrengthFit!;
        return {
          'engineVersion': TeamStrengthEngine.version,
          'homeAdvantage': fit.homeAdvantage,
          'fitConverged': fit.converged,
          'fitIterations': fit.iterations,
          'teamCount': fit.attack.length,
          'attack': fit.attack,
          'defense': fit.defense,
        };
    }
  }
}
