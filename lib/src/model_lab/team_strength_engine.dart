/// PHÖNIX Engine-Umbau, Phase 2 (Plan "wild-cuddling-hoare"): der laut Plan
/// größte Hebel - Team-Stärke-Ratings statt roher Saison-Torschnitte.
///
/// Fitting-Modell: das Standard-Angriff/Abwehr-Poisson-Modell für Fußball
/// (Maher 1982, Grundlage auch von Dixon & Coles 1997):
///
///   E[Heimtore]     = attack[Heimteam] * defense[Auswärtsteam] * homeAdvantage
///   E[Auswärtstore] = attack[Auswärtsteam] * defense[Heimteam]
///
/// `attack`/`defense` sind multiplikative Stärkefaktoren um 1.0 herum
/// (Liga-Durchschnitt = 1.0). Gefittet per Iterative Proportional Fitting
/// (IPF) - ein Fixpunktverfahren, das für genau dieses bipartite
/// Poisson-Modell zur Maximum-Likelihood-Lösung konvergiert (kein
/// Gradientenverfahren/keine externe Optimierungsbibliothek nötig, siehe
/// `fit()`).
///
/// Section 4 (Claude AN2.txt, "EINE ENGINE PRO LIGA"): dieser Fit läuft
/// PRO LIGA (ein `fit()`-Aufruf bekommt nur die Spiele einer Liga) - jede
/// Liga bekommt so ihre eigenen, aus echten Ergebnissen gelernten
/// Team-Stärken statt eines geteilten globalen Modells.
class MatchResult {
  const MatchResult({
    required this.homeTeamId,
    required this.awayTeamId,
    required this.homeGoals,
    required this.awayGoals,
  });

  final String homeTeamId;
  final String awayTeamId;
  final int homeGoals;
  final int awayGoals;
}

class TeamStrengthFit {
  const TeamStrengthFit({
    required this.attack,
    required this.defense,
    required this.homeAdvantage,
    required this.iterations,
    required this.converged,
  });

  /// Angriffsstärke je Team, normiert um 1.0 (Liga-Durchschnitt). > 1.0 =
  /// überdurchschnittlicher Angriff.
  final Map<String, double> attack;

  /// Abwehrschwäche je Team, normiert um 1.0. > 1.0 = überdurchschnittlich
  /// VIELE Gegentore (schwache Abwehr) - multipliziert die gegnerische
  /// Angriffsstärke, deshalb "größer = schlechter" (konsistent mit der
  /// Modellformel oben, nicht invertiert).
  final Map<String, double> defense;

  /// Multiplikativer Heimvorteil (z.B. 1.35 = 35% mehr erwartete Heimtore
  /// bei sonst gleicher Team-Stärke).
  final double homeAdvantage;

  final int iterations;
  final bool converged;

  /// Neutraler Startwert für ein Team ohne eigene Fit-Historie (Cold Start,
  /// Section "Team-Stärke... Cold-Start-Handling" im Plan) - exakt
  /// Liga-Durchschnitt, identisch zum Prinzip von `EngineWeightConfig.
  /// global`/den bestehenden Baseline-Fallbacks.
  static const double neutralStrength = 1.0;

  double attackOf(String teamId) => attack[teamId] ?? neutralStrength;
  double defenseOf(String teamId) => defense[teamId] ?? neutralStrength;
}

class TeamStrengthEngine {
  const TeamStrengthEngine._();

  /// Fittet Angriff/Abwehr/Heimvorteil aus einer Liste bereits abgerechneter
  /// Spiele EINER Liga via Iterative Proportional Fitting.
  ///
  /// Ablauf pro Iteration:
  /// 1. attack[i] = (Tore, die Team i insgesamt erzielt hat) / (Summe der
  ///    erwarteten Gegentore-Beiträge der Gegner, mit aktuellem defense/
  ///    homeAdvantage)
  /// 2. defense[i] = (Tore, die Team i insgesamt kassiert hat) / (Summe der
  ///    erwarteten Angriffsbeiträge der Gegner)
  /// 3. homeAdvantage = (alle Heimtore der Liga) / (Summe aller
  ///    attack[Heimteam] * defense[Auswärtsteam])
  /// 4. Renormierung: attack wird so skaliert, dass der Durchschnitt über
  ///    alle Teams exakt 1.0 ist (defense invers mitskaliert, damit die
  ///    Produkte attack*defense unverändert bleiben - reine
  ///    Interpretierbarkeit, siehe Klassenkommentar oben).
  ///
  /// Konvergenz: das Verfahren ist ein bekanntes Fixpunktverfahren für
  /// genau dieses Modell (äquivalent zur Maximum-Likelihood-Lösung) und
  /// konvergiert für vernünftig große, zusammenhängende Ligen zuverlässig
  /// innerhalb weniger Iterationen.
  static TeamStrengthFit fit(
    List<MatchResult> matches, {
    int maxIterations = 100,
    double convergenceTolerance = 1e-6,
  }) {
    final teamIds = <String>{};
    for (final match in matches) {
      teamIds.add(match.homeTeamId);
      teamIds.add(match.awayTeamId);
    }

    if (teamIds.isEmpty || matches.isEmpty) {
      return const TeamStrengthFit(
        attack: {},
        defense: {},
        homeAdvantage: 1.0,
        iterations: 0,
        converged: true,
      );
    }

    final attack = {for (final id in teamIds) id: 1.0};
    final defense = {for (final id in teamIds) id: 1.0};
    var homeAdvantage = 1.0;

    final totalGoalsFor = <String, double>{for (final id in teamIds) id: 0};
    final totalGoalsAgainst = <String, double>{
      for (final id in teamIds) id: 0,
    };
    var totalHomeGoals = 0.0;
    for (final match in matches) {
      totalGoalsFor[match.homeTeamId] =
          totalGoalsFor[match.homeTeamId]! + match.homeGoals;
      totalGoalsFor[match.awayTeamId] =
          totalGoalsFor[match.awayTeamId]! + match.awayGoals;
      totalGoalsAgainst[match.homeTeamId] =
          totalGoalsAgainst[match.homeTeamId]! + match.awayGoals;
      totalGoalsAgainst[match.awayTeamId] =
          totalGoalsAgainst[match.awayTeamId]! + match.homeGoals;
      totalHomeGoals += match.homeGoals;
    }

    var iterations = 0;
    var converged = false;

    for (; iterations < maxIterations; iterations++) {
      final previousAttack = Map<String, double>.from(attack);

      // Schritt 1: attack.
      final attackDenominator = <String, double>{
        for (final id in teamIds) id: 0,
      };
      for (final match in matches) {
        attackDenominator[match.homeTeamId] = attackDenominator[match.homeTeamId]! +
            defense[match.awayTeamId]! * homeAdvantage;
        attackDenominator[match.awayTeamId] =
            attackDenominator[match.awayTeamId]! + defense[match.homeTeamId]!;
      }
      for (final id in teamIds) {
        final denominator = attackDenominator[id]!;
        if (denominator > 0) {
          attack[id] = totalGoalsFor[id]! / denominator;
        }
      }

      // Schritt 2: defense.
      final defenseDenominator = <String, double>{
        for (final id in teamIds) id: 0,
      };
      for (final match in matches) {
        defenseDenominator[match.homeTeamId] =
            defenseDenominator[match.homeTeamId]! + attack[match.awayTeamId]!;
        defenseDenominator[match.awayTeamId] = defenseDenominator[match.awayTeamId]! +
            attack[match.homeTeamId]! * homeAdvantage;
      }
      for (final id in teamIds) {
        final denominator = defenseDenominator[id]!;
        if (denominator > 0) {
          defense[id] = totalGoalsAgainst[id]! / denominator;
        }
      }

      // Schritt 3: Heimvorteil.
      var expectedHomeGoals = 0.0;
      for (final match in matches) {
        expectedHomeGoals += attack[match.homeTeamId]! * defense[match.awayTeamId]!;
      }
      if (expectedHomeGoals > 0) {
        homeAdvantage = totalHomeGoals / expectedHomeGoals;
      }

      // Schritt 4: Renormierung (Interpretierbarkeit, ändert keine
      // Vorhersage - siehe Klassenkommentar).
      final meanAttack =
          attack.values.reduce((a, b) => a + b) / attack.length;
      if (meanAttack > 0) {
        for (final id in teamIds) {
          attack[id] = attack[id]! / meanAttack;
          defense[id] = defense[id]! * meanAttack;
        }
      }

      var maxDelta = 0.0;
      for (final id in teamIds) {
        final delta = (attack[id]! - previousAttack[id]!).abs();
        if (delta > maxDelta) maxDelta = delta;
      }
      if (maxDelta < convergenceTolerance) {
        converged = true;
        iterations += 1;
        break;
      }
    }

    return TeamStrengthFit(
      attack: attack,
      defense: defense,
      homeAdvantage: homeAdvantage,
      iterations: iterations,
      converged: converged,
    );
  }

  /// Torerwartung für ein konkretes Spiel aus einem gefitteten Modell -
  /// direkt in echten Toren, keine zusätzliche Liga-Skalierung nötig: das
  /// Fitting-Verfahren lernt attack/defense/homeAdvantage bereits so, dass
  /// `attack[Heim] * defense[Auswärts] * homeAdvantage` bzw.
  /// `attack[Auswärts] * defense[Heim]` direkt die beobachteten Torzahlen
  /// reproduzieren (Maximum-Likelihood-Fit auf echte Tore, nicht auf eine
  /// abstrakte Skala). Teams ohne eigene Fit-Historie (Cold Start) fallen
  /// automatisch auf [TeamStrengthFit.neutralStrength] zurück
  /// (`attackOf`/`defenseOf`) - "Durchschnittsteam gegen Durchschnittsteam"
  /// ergibt dann sinnvollerweise exakt `homeAdvantage`/`1.0` Tore.
  static ({double home, double away}) expectedGoals({
    required TeamStrengthFit fit,
    required String homeTeamId,
    required String awayTeamId,
  }) {
    final home = fit.attackOf(homeTeamId) *
        fit.defenseOf(awayTeamId) *
        fit.homeAdvantage;
    final away = fit.attackOf(awayTeamId) * fit.defenseOf(homeTeamId);
    return (home: home, away: away);
  }
}
