import 'dart:math';

/// Reine Poisson-Wahrscheinlichkeitsmathematik ohne jeglichen Zufall/State.
///
/// Die produktive PHÖNIX-Engine (`FootballSimulationService`) approximiert
/// diese Verteilungen per Monte-Carlo (100.000 Ziehungen je Spiel,
/// unabhängige Heim-/Auswärts-Poisson-Ziehungen). Für das Model Lab wird
/// dieselbe zugrunde liegende Verteilungsannahme (unabhängige
/// Poisson-Torzahlen) stattdessen GESCHLOSSEN (analytisch) ausgewertet:
/// gleiche Statistik, aber deterministisch, ohne RNG-Seed und ohne die
/// 100k-Iterationen-Kosten - unverzichtbar, um tausende historische Spiele
/// in einem Learning Run in Sekunden statt Stunden zu bewerten.
///
/// Dies verändert NICHT die produktive Engine - es ist eine Model-Lab-lokale
/// Neuimplementierung derselben Verteilungsannahme für Backtesting/Shadow.
class PoissonMath {
  const PoissonMath._();

  static const int maxGoalsPerSide = 12;

  static double pmf(double lambda, int k) {
    if (lambda <= 0) return k == 0 ? 1.0 : 0.0;
    return exp(-lambda) * pow(lambda, k) / _factorial(k);
  }

  static double _factorial(int n) {
    var result = 1.0;
    for (var i = 2; i <= n; i++) {
      result *= i;
    }
    return result;
  }

  /// Wahrscheinlichkeiten für 1X2 aus zwei unabhängigen Poisson-Verteilungen.
  static ({double home, double draw, double away}) matchResultProbabilities(
    double homeLambda,
    double awayLambda,
  ) {
    var home = 0.0;
    var draw = 0.0;
    var away = 0.0;
    for (var h = 0; h <= maxGoalsPerSide; h++) {
      final pH = pmf(homeLambda, h);
      for (var a = 0; a <= maxGoalsPerSide; a++) {
        final pA = pmf(awayLambda, a);
        final joint = pH * pA;
        if (h > a) {
          home += joint;
        } else if (h == a) {
          draw += joint;
        } else {
          away += joint;
        }
      }
    }
    final total = home + draw + away;
    if (total <= 0) return (home: 0.0, draw: 0.0, away: 0.0);
    return (home: home / total, draw: draw / total, away: away / total);
  }

  /// P(Gesamttore > line) und P(Gesamttore <= line) für eine Torlinie
  /// (z.B. 2.5).
  static ({double over, double under}) overUnderProbabilities(
    double homeLambda,
    double awayLambda,
    double line,
  ) {
    var over = 0.0;
    var under = 0.0;
    for (var h = 0; h <= maxGoalsPerSide; h++) {
      final pH = pmf(homeLambda, h);
      for (var a = 0; a <= maxGoalsPerSide; a++) {
        final joint = pH * pmf(awayLambda, a);
        if (h + a > line) {
          over += joint;
        } else {
          under += joint;
        }
      }
    }
    final total = over + under;
    if (total <= 0) return (over: 0.0, under: 0.0);
    return (over: over / total, under: under / total);
  }

  /// Beide Teams treffen: bei Unabhängigkeit P(H>=1) * P(A>=1).
  static ({double yes, double no}) bttsProbabilities(
    double homeLambda,
    double awayLambda,
  ) {
    final homeScores = 1 - pmf(homeLambda, 0);
    final awayScores = 1 - pmf(awayLambda, 0);
    final yes = (homeScores * awayScores).clamp(0.0, 1.0).toDouble();
    return (yes: yes, no: 1 - yes);
  }
}
