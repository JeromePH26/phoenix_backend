import 'team_strength_engine.dart';

/// M3 (AN2 §11): das gemeinsame "Bild vom Spiel", das ALLE Märkte
/// speisen soll - statt heute nur zwei nackte Torerwartungen `{λ_home,
/// λ_away}`. Ein reiner Wert-Typ ohne DB-/Engine-Abhängigkeit; die
/// eigentliche Score-Verteilung leiten weiterhin `PoissonMath.scoreMatrix`
/// / `EngineReplica.evaluateGoals` aus `expectedGoalsHome/Away` ab (der
/// score-matrix-Schritt bleibt der einzige Ableitungspunkt).
///
/// Angriff/Abwehr sind multiplikative Faktoren um 1.0 (Liga-Durchschnitt =
/// 1.0), genau wie `TeamStrengthFit`. Abwehr: > 1.0 = schwächer (mehr
/// Gegentore), konsistent mit der Maher-Modellformel.
class MatchState {
  const MatchState({
    required this.homeAttack,
    required this.homeDefense,
    required this.awayAttack,
    required this.awayDefense,
    required this.homeAdvantage,
    required this.leagueBaselineHome,
    required this.leagueBaselineAway,
    required this.expectedGoalsHome,
    required this.expectedGoalsAway,
    required this.uncertainty,
    required this.sourceType,
  });

  final double homeAttack;
  final double homeDefense;
  final double awayAttack;
  final double awayDefense;

  /// Multiplikativer Heimvorteil (z. B. 1.30 = 30 % mehr erwartete Heimtore
  /// bei sonst gleich starken Teams).
  final double homeAdvantage;

  /// Liga-Grundniveau an erwarteten Toren (Heim/Auswärts), auf das dünn
  /// besetzte Teams zurückfallen.
  final double leagueBaselineHome;
  final double leagueBaselineAway;

  final double expectedGoalsHome;
  final double expectedGoalsAway;

  /// Grobes Match-Tempo = Summe der erwarteten Tore. Höher = offeneres,
  /// torreicheres Spiel.
  double get tempo => expectedGoalsHome + expectedGoalsAway;

  final MatchStateUncertainty uncertainty;

  /// Wie die Torerwartung zustande kam - z. B. `team_strength_elo_prior`,
  /// `goal_rates_shrunk`, `safe_baseline_fallback`.
  final String sourceType;

  Map<String, Object?> toJson() => {
        'homeAttack': _round(homeAttack),
        'homeDefense': _round(homeDefense),
        'awayAttack': _round(awayAttack),
        'awayDefense': _round(awayDefense),
        'homeAdvantage': _round(homeAdvantage),
        'leagueBaselineHome': _round(leagueBaselineHome),
        'leagueBaselineAway': _round(leagueBaselineAway),
        'expectedGoalsHome': _round(expectedGoalsHome),
        'expectedGoalsAway': _round(expectedGoalsAway),
        'tempo': _round(tempo),
        'sourceType': sourceType,
        'uncertainty': uncertainty.toJson(),
      };

  static double _round(double v) => double.parse(v.toStringAsFixed(4));
}

/// Explizite Unsicherheit pro Spiel (AN2 §21-23). M3 füllt die datenseitigen
/// Signale; Modell-/Challenger-Streuung und ein Wahrscheinlichkeits-Intervall
/// kommen in M6 dazu.
class MatchStateUncertainty {
  const MatchStateUncertainty({
    required this.effectiveSampleSize,
    required this.coverage,
    required this.usedFallbackBaseline,
    required this.eloCoverage,
  });

  /// Wirksame Zahl der Spiele hinter der Team-Schätzung (kleiner = unsicherer).
  final double effectiveSampleSize;

  /// Anteil der verfügbaren Pre-Match-Signale (0..1) aus `data_quality`.
  final double coverage;

  /// Es lag keine eigene Team-Torbasis vor -> reiner Liga-Prior. Diese Spiele
  /// dürfen nie einen selbstbewussten Tipp erzeugen (M6).
  final bool usedFallbackBaseline;

  /// Beide Teams an eine echte Elo-Reihe gebunden? Ohne Elo ist der
  /// Cold-Start-/Aufsteiger-Anker schwächer.
  final bool eloCoverage;

  /// Grobe 0..1-Vertrauenszahl (1 = am belastbarsten). Nur ein Startpunkt;
  /// M6 ersetzt sie durch eine geeichte Größe.
  double get confidence {
    final sampleTerm = effectiveSampleSize / (effectiveSampleSize + 10.0);
    var c = 0.55 * sampleTerm + 0.30 * coverage + (eloCoverage ? 0.15 : 0.0);
    if (usedFallbackBaseline) c *= 0.35;
    return c.clamp(0.0, 1.0);
  }

  Map<String, Object?> toJson() => {
        'effectiveSampleSize':
            double.parse(effectiveSampleSize.toStringAsFixed(2)),
        'coverage': double.parse(coverage.toStringAsFixed(3)),
        'usedFallbackBaseline': usedFallbackBaseline,
        'eloCoverage': eloCoverage,
        'confidence': double.parse(confidence.toStringAsFixed(3)),
      };
}

/// Baut ein [MatchState] aus den je nach Pfad verfügbaren Zutaten.
class MatchStateBuilder {
  const MatchStateBuilder._();

  /// Lab-Pfad: aus einem gefitteten [TeamStrengthFit] (siehe
  /// `TeamStrengthEngine`). `expectedGoals` kommt direkt aus dem Fit -
  /// `attack[Heim] * defense[Auswärts] * homeAdvantage` bzw. Spiegelbild.
  static MatchState fromTeamStrength({
    required TeamStrengthFit fit,
    required String homeTeamId,
    required String awayTeamId,
    required double leagueBaselineHome,
    required double leagueBaselineAway,
    required double effectiveSampleSize,
    required double coverage,
    required bool eloCoverage,
  }) {
    final goals = TeamStrengthEngine.expectedGoals(
      fit: fit,
      homeTeamId: homeTeamId,
      awayTeamId: awayTeamId,
    );
    final knownHome = fit.attack.containsKey(homeTeamId);
    final knownAway = fit.attack.containsKey(awayTeamId);
    return MatchState(
      homeAttack: fit.attackOf(homeTeamId),
      homeDefense: fit.defenseOf(homeTeamId),
      awayAttack: fit.attackOf(awayTeamId),
      awayDefense: fit.defenseOf(awayTeamId),
      homeAdvantage: fit.homeAdvantage,
      leagueBaselineHome: leagueBaselineHome,
      leagueBaselineAway: leagueBaselineAway,
      expectedGoalsHome: goals.home,
      expectedGoalsAway: goals.away,
      uncertainty: MatchStateUncertainty(
        effectiveSampleSize: effectiveSampleSize,
        coverage: coverage,
        usedFallbackBaseline: !knownHome && !knownAway,
        eloCoverage: eloCoverage,
      ),
      sourceType: 'team_strength_ipf',
    );
  }

  /// Live-äquivalenter Pfad: aus bereits geshrinkten Torraten plus
  /// Liga-Baseline (heutiges Verhalten der Live-Engine), damit M3 additiv
  /// bleibt, bis M3c den Fit auch live einbindet. Angriff/Abwehr werden aus
  /// dem Verhältnis Torrate/Baseline abgeleitet (nur informativ -
  /// `expectedGoals` bleibt exakt die geshrinkte Rate).
  static MatchState fromGoalRates({
    required double expectedGoalsHome,
    required double expectedGoalsAway,
    required double leagueBaselineHome,
    required double leagueBaselineAway,
    required double effectiveSampleSize,
    required double coverage,
    required bool usedFallbackBaseline,
    bool eloCoverage = false,
    double homeAdvantage = 1.0,
  }) {
    double ratio(double v, double base) => base > 0 ? v / base : 1.0;
    final homeAtt = ratio(expectedGoalsHome, leagueBaselineHome);
    final awayAtt = ratio(expectedGoalsAway, leagueBaselineAway);
    return MatchState(
      homeAttack: homeAtt,
      homeDefense: awayAtt,
      awayAttack: awayAtt,
      awayDefense: homeAtt,
      homeAdvantage: homeAdvantage,
      leagueBaselineHome: leagueBaselineHome,
      leagueBaselineAway: leagueBaselineAway,
      expectedGoalsHome: expectedGoalsHome,
      expectedGoalsAway: expectedGoalsAway,
      uncertainty: MatchStateUncertainty(
        effectiveSampleSize: effectiveSampleSize,
        coverage: coverage,
        usedFallbackBaseline: usedFallbackBaseline,
        eloCoverage: eloCoverage,
      ),
      sourceType:
          usedFallbackBaseline ? 'safe_baseline_fallback' : 'goal_rates_shrunk',
    );
  }
}
