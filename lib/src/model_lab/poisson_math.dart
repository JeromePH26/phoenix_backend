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

  /// Dixon-Coles-Korrekturfaktor (Dixon & Coles 1997) für die vier
  /// niedrigen Scorelines, wo unabhängiges Poisson die empirische
  /// Torkorrelation systematisch unterschätzt (0:0/1:1 zu selten, 1:0/0:1 zu
  /// häufig vorhergesagt). `rho == 0.0` liefert für JEDE Scoreline exakt
  /// `1.0` - macht [scoreMatrix] bei `rho: 0.0` identisch zur bisherigen
  /// unabhängigen Poisson-Matrix (Regressionsanker, siehe Tests).
  static double dixonColesTau({
    required int homeGoals,
    required int awayGoals,
    required double homeLambda,
    required double awayLambda,
    required double rho,
  }) {
    if (homeGoals == 0 && awayGoals == 0) {
      return 1 - (homeLambda * awayLambda * rho);
    }
    if (homeGoals == 0 && awayGoals == 1) {
      return 1 + (homeLambda * rho);
    }
    if (homeGoals == 1 && awayGoals == 0) {
      return 1 + (awayLambda * rho);
    }
    if (homeGoals == 1 && awayGoals == 1) {
      return 1 - rho;
    }
    return 1.0;
  }

  /// Gemeinsame Score-Verteilung (das "Match-State"-Objekt, Section 4:
  /// "PHÖNIX soll zuerst das SPIEL verstehen und erst danach die
  /// WETTMÄRKTE ableiten") - alle Markt-Wahrscheinlichkeiten unten leiten
  /// sich aus DERSELBEN Matrix ab, statt unabhängig voneinander zu rechnen.
  /// `rho: 0.0` (Default) reproduziert exakt die bisherige unabhängige
  /// Poisson-Annahme.
  static List<List<double>> scoreMatrix({
    required double homeLambda,
    required double awayLambda,
    double rho = 0.0,
  }) {
    final matrix = List.generate(
      maxGoalsPerSide + 1,
      (_) => List<double>.filled(maxGoalsPerSide + 1, 0.0),
    );
    var total = 0.0;
    for (var h = 0; h <= maxGoalsPerSide; h++) {
      final pH = pmf(homeLambda, h);
      for (var a = 0; a <= maxGoalsPerSide; a++) {
        final pA = pmf(awayLambda, a);
        final tau = rho == 0.0
            ? 1.0
            : dixonColesTau(
                homeGoals: h,
                awayGoals: a,
                homeLambda: homeLambda,
                awayLambda: awayLambda,
                rho: rho,
              );
        final joint = (pH * pA * tau).clamp(0.0, 1.0).toDouble();
        matrix[h][a] = joint;
        total += joint;
      }
    }
    if (total <= 0) return matrix;
    for (var h = 0; h <= maxGoalsPerSide; h++) {
      for (var a = 0; a <= maxGoalsPerSide; a++) {
        matrix[h][a] = matrix[h][a] / total;
      }
    }
    return matrix;
  }

  /// Wahrscheinlichkeiten für 1X2 aus der gemeinsamen Score-Matrix
  /// (`rho: 0.0` = unabhängiges Poisson, bisheriges Verhalten unverändert).
  static ({double home, double draw, double away}) matchResultProbabilities(
    double homeLambda,
    double awayLambda, {
    double rho = 0.0,
  }) {
    final matrix = scoreMatrix(
      homeLambda: homeLambda,
      awayLambda: awayLambda,
      rho: rho,
    );
    var home = 0.0;
    var draw = 0.0;
    var away = 0.0;
    for (var h = 0; h <= maxGoalsPerSide; h++) {
      for (var a = 0; a <= maxGoalsPerSide; a++) {
        final joint = matrix[h][a];
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
    double line, {
    double rho = 0.0,
  }) {
    final matrix = scoreMatrix(
      homeLambda: homeLambda,
      awayLambda: awayLambda,
      rho: rho,
    );
    var over = 0.0;
    var under = 0.0;
    for (var h = 0; h <= maxGoalsPerSide; h++) {
      for (var a = 0; a <= maxGoalsPerSide; a++) {
        final joint = matrix[h][a];
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

  /// Beide Teams treffen. Bei `rho: 0.0` identisch zur bisherigen
  /// Unabhängigkeits-Kurzformel P(H>=1) * P(A>=1); mit `rho != 0` läuft die
  /// echte Summe über die Score-Matrix, weil die Korrelation gerade den
  /// (0,0)-Fall verschiebt, den die Kurzformel nicht abbilden kann.
  static ({double yes, double no}) bttsProbabilities(
    double homeLambda,
    double awayLambda, {
    double rho = 0.0,
  }) {
    final matrix = scoreMatrix(
      homeLambda: homeLambda,
      awayLambda: awayLambda,
      rho: rho,
    );
    var yes = 0.0;
    for (var h = 1; h <= maxGoalsPerSide; h++) {
      for (var a = 1; a <= maxGoalsPerSide; a++) {
        yes += matrix[h][a];
      }
    }
    final clamped = yes.clamp(0.0, 1.0).toDouble();
    return (yes: clamped, no: 1 - clamped);
  }

  /// P(Team erzielt mehr als [line] Tore) und Gegenwahrscheinlichkeit.
  /// Die Berechnung nutzt dieselbe unabhängige Poisson-Annahme wie die
  /// produktive Monte-Carlo-Simulation, nur deterministisch für Learning.
  static ({double over, double under}) teamOverUnderProbabilities(
    double lambda,
    double line,
  ) {
    var over = 0.0;
    var under = 0.0;
    for (var goals = 0; goals <= maxGoalsPerSide; goals++) {
      final probability = pmf(lambda, goals);
      if (goals > line) {
        over += probability;
      } else {
        under += probability;
      }
    }
    final total = over + under;
    if (total <= 0) return (over: 0.0, under: 0.0);
    return (over: over / total, under: under / total);
  }
}
