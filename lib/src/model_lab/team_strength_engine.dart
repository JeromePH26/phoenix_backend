import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

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
    this.kickoff,
  });

  final String homeTeamId;
  final String awayTeamId;
  final int homeGoals;
  final int awayGoals;

  /// Optional - nur nötig, wenn [TeamStrengthEngine.fit] mit
  /// `halfLifeDays` (Zeitverfall-Gewichtung, Phase 3) aufgerufen wird.
  /// `null` bedeutet: dieses Spiel bekommt bei aktiviertem Zeitverfall das
  /// volle Gewicht 1.0 (kein Datum bekannt, keine Abwertung möglich).
  final DateTime? kickoff;
}

class TeamStrengthFit {
  const TeamStrengthFit({
    required this.attack,
    required this.defense,
    required this.homeAdvantage,
    required this.iterations,
    required this.converged,
    this.priors = const {},
  });

  /// M3b: Angriff/Abwehr-PRIOR je Team (aus dem Elo, siehe `EloPrior`).
  /// Wird als Shrinkage-Ziel im Fit genutzt UND als Fallback für Teams ohne
  /// eigene Fit-Historie (Cold Start / Aufsteiger) - statt flach 1.0.
  final Map<String, ({double attack, double defense})> priors;

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

  double attackOf(String teamId) =>
      attack[teamId] ?? priors[teamId]?.attack ?? neutralStrength;
  double defenseOf(String teamId) =>
      defense[teamId] ?? priors[teamId]?.defense ?? neutralStrength;

  /// Deterministischer Hash über die tatsächlich gefitteten Werte -
  /// verhindert Duplikate über den bestehenden Unique-Index auf
  /// `(market, league_id, config_hash)`, dasselbe Muster wie
  /// `EngineWeightConfig.configHash()`/`GlobalMarketEngine.configHash()`.
  /// Ändert sich automatisch, sobald ein neuer Learning-Run mit mehr/
  /// anderen Trainingsdaten einen anderen Fit produziert - ein
  /// unveränderter Fit (gleiche Trainingsdaten) erzeugt denselben Hash und
  /// wird deshalb nicht erneut als "neuer" Challenger angelegt.
  String configHash() {
    final sortedAttack = Map.fromEntries(
      attack.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    final sortedDefense = Map.fromEntries(
      defense.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    final sortedPriors = Map.fromEntries(
      priors.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    final canonical = jsonEncode({
      'engineVersion': 'TEAM_STRENGTH_IPF_V1',
      'homeAdvantage': double.parse(homeAdvantage.toStringAsFixed(6)),
      'attack': sortedAttack.map(
        (k, v) => MapEntry(k, double.parse(v.toStringAsFixed(6))),
      ),
      'defense': sortedDefense.map(
        (k, v) => MapEntry(k, double.parse(v.toStringAsFixed(6))),
      ),
      if (priors.isNotEmpty)
        'priors': sortedPriors.map(
          (k, v) => MapEntry(k, [
            double.parse(v.attack.toStringAsFixed(6)),
            double.parse(v.defense.toStringAsFixed(6)),
          ]),
        ),
    });
    return sha256.convert(utf8.encode(canonical)).toString();
  }
}

class TeamStrengthEngine {
  const TeamStrengthEngine._();

  static const String version = 'TEAM_STRENGTH_IPF_V1';

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
    int maxIterations = 200,
    double convergenceTolerance = 1e-6,
    // Live gegen PHÖNIX-Daten getestet (Plan "wild-cuddling-hoare", Phase
    // 2): bei kleinen/ungleich verteilten Ligen (wenige Spiele pro Team)
    // schwingt das ungedämpfte Fixpunktverfahren, statt zu konvergieren
    // (100 Iterationen ohne Konvergenz beobachtet, z.B. MLS mit nur ~2-3
    // Spielen pro Team). Unterrelaxation (nur ein Bruchteil des Schritts
    // je Iteration übernehmen) ist die Standardlösung für genau dieses
    // Oszillationsproblem bei IPF-artigen Fixpunktverfahren.
    double dampingFactor = 0.5,
    // Live gegen PHÖNIX-Daten getestet: selbst mit Dämpfung konvergierten
    // Ligen mit vielen Teams und wenigen Spielen pro Team (z.B. Allsvenskan,
    // EFL Cup - oft nur 1-3 Spiele je Team) nicht zuverlässig, und lieferten
    // deutlich schlechtere Vorhersagen als der einfache Durchschnitt -
    // typisches Identifizierbarkeitsproblem bei zu wenig Beobachtungen pro
    // Parameter. Empirical-Bayes-Shrinkage Richtung neutral (1.0) IN JEDER
    // Iteration, abhängig von der bisherigen Spielanzahl des Teams -
    // dieselbe `n / (n + k)`-Formel wie `FootballEngineInputService.
    // shrinkGoalRateTowardsBaseline`/`leagueAwareBaseline`, jetzt auf
    // Team-Parameter-Ebene. Ein Team mit wenigen Spielen bleibt so nahe an
    // "Durchschnittsteam" statt frei zu driften - stabilisiert sowohl die
    // Konvergenz als auch die Qualität der Schätzung für datenarme Teams.
    double regularizationK = 8,
    // M3b: Angriff/Abwehr-Prior je Team (aus dem Elo). Shrinkage zieht dünn
    // besetzte Teams hierauf statt auf flach 1.0; Teams ganz ohne Historie
    // bekommen den Prior über `TeamStrengthFit.attackOf/defenseOf`. `null`
    // oder leer = altes Verhalten (Shrinkage-Ziel 1.0) - Regressionsanker.
    Map<String, ({double attack, double defense})>? priors,
    // Phase 3 (Plan "wild-cuddling-hoare", "passt natürlich zu Phase 2"):
    // exponentieller Zeitverfall statt jedes Trainingsspiel gleich zu
    // gewichten. `null` (Default) = kein Zeitverfall, identisch zum
    // bisherigen Verhalten (Regressionsanker). Bei gesetztem [halfLifeDays]
    // bekommt ein Spiel, das genau [halfLifeDays] Tage vor [asOf] liegt,
    // die Hälfte des Gewichts eines Spiels von heute; Spiele ohne
    // [MatchResult.kickoff] bekommen immer volles Gewicht (kein Datum
    // bekannt, keine Abwertung möglich).
    double? halfLifeDays,
    DateTime? asOf,
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

    final referenceDate = asOf ?? DateTime.now();
    double matchWeight(MatchResult match) {
      if (halfLifeDays == null || halfLifeDays <= 0) return 1.0;
      final kickoff = match.kickoff;
      if (kickoff == null) return 1.0;
      final daysAgo = referenceDate.difference(kickoff).inHours / 24.0;
      if (daysAgo <= 0) return 1.0;
      return pow(0.5, daysAgo / halfLifeDays).toDouble();
    }

    final attack = {for (final id in teamIds) id: 1.0};
    final defense = {for (final id in teamIds) id: 1.0};
    var homeAdvantage = 1.0;

    // Bei aktiviertem Zeitverfall (`halfLifeDays`) ist [matchWeights] pro
    // Spiel < 1.0 statt immer 1.0 - fließt in JEDE Summe unten ein (Tore,
    // "effektive" Spielanzahl für die Regularisierung, Heimvorteil). Ohne
    // Zeitverfall bleibt hier alles exakt wie vorher (Regressionsanker).
    final matchWeights = [for (final match in matches) matchWeight(match)];

    final totalGoalsFor = <String, double>{for (final id in teamIds) id: 0};
    final totalGoalsAgainst = <String, double>{
      for (final id in teamIds) id: 0,
    };
    // "Effektive" Spielanzahl (Summe der Gewichte, nicht die rohe Anzahl) -
    // ein Team mit vielen, aber lange zurückliegenden Spielen soll für die
    // Regularisierung unten wie ein Team mit WENIGEN Spielen behandelt
    // werden.
    final effectiveMatchCount = <String, double>{
      for (final id in teamIds) id: 0,
    };
    var totalHomeGoals = 0.0;
    for (var i = 0; i < matches.length; i++) {
      final match = matches[i];
      final w = matchWeights[i];
      totalGoalsFor[match.homeTeamId] =
          totalGoalsFor[match.homeTeamId]! + match.homeGoals * w;
      totalGoalsFor[match.awayTeamId] =
          totalGoalsFor[match.awayTeamId]! + match.awayGoals * w;
      totalGoalsAgainst[match.homeTeamId] =
          totalGoalsAgainst[match.homeTeamId]! + match.awayGoals * w;
      totalGoalsAgainst[match.awayTeamId] =
          totalGoalsAgainst[match.awayTeamId]! + match.homeGoals * w;
      effectiveMatchCount[match.homeTeamId] =
          effectiveMatchCount[match.homeTeamId]! + w;
      effectiveMatchCount[match.awayTeamId] =
          effectiveMatchCount[match.awayTeamId]! + w;
      totalHomeGoals += match.homeGoals * w;
    }

    final priorMap = priors ?? const {};
    double shrinkTowardsPrior(
      double rawTarget,
      String teamId, {
      required bool isAttack,
    }) {
      final n = effectiveMatchCount[teamId]!;
      final factor = n / (n + regularizationK);
      final prior = priorMap[teamId];
      final target = prior == null
          ? TeamStrengthFit.neutralStrength
          : (isAttack ? prior.attack : prior.defense);
      return target + factor * (rawTarget - target);
    }

    var iterations = 0;
    var converged = false;

    for (; iterations < maxIterations; iterations++) {
      final previousAttack = Map<String, double>.from(attack);
      final previousDefense = Map<String, double>.from(defense);
      final previousHomeAdvantage = homeAdvantage;

      // Schritt 1: attack.
      final attackDenominator = <String, double>{
        for (final id in teamIds) id: 0,
      };
      for (var i = 0; i < matches.length; i++) {
        final match = matches[i];
        final w = matchWeights[i];
        attackDenominator[match.homeTeamId] = attackDenominator[match.homeTeamId]! +
            defense[match.awayTeamId]! * homeAdvantage * w;
        attackDenominator[match.awayTeamId] =
            attackDenominator[match.awayTeamId]! + defense[match.homeTeamId]! * w;
      }
      for (final id in teamIds) {
        final denominator = attackDenominator[id]!;
        if (denominator > 0) {
          final rawTarget = totalGoalsFor[id]! / denominator;
          final target = shrinkTowardsPrior(rawTarget, id, isAttack: true);
          attack[id] = attack[id]! + dampingFactor * (target - attack[id]!);
        }
      }

      // Schritt 2: defense.
      final defenseDenominator = <String, double>{
        for (final id in teamIds) id: 0,
      };
      for (var i = 0; i < matches.length; i++) {
        final match = matches[i];
        final w = matchWeights[i];
        defenseDenominator[match.homeTeamId] = defenseDenominator[match.homeTeamId]! +
            attack[match.awayTeamId]! * w;
        defenseDenominator[match.awayTeamId] = defenseDenominator[match.awayTeamId]! +
            attack[match.homeTeamId]! * homeAdvantage * w;
      }
      for (final id in teamIds) {
        final denominator = defenseDenominator[id]!;
        if (denominator > 0) {
          final rawTarget = totalGoalsAgainst[id]! / denominator;
          final target = shrinkTowardsPrior(rawTarget, id, isAttack: false);
          defense[id] = defense[id]! + dampingFactor * (target - defense[id]!);
        }
      }

      // Schritt 3: Heimvorteil.
      var expectedHomeGoals = 0.0;
      for (var i = 0; i < matches.length; i++) {
        final match = matches[i];
        final w = matchWeights[i];
        expectedHomeGoals +=
            attack[match.homeTeamId]! * defense[match.awayTeamId]! * w;
      }
      if (expectedHomeGoals > 0) {
        final target = totalHomeGoals / expectedHomeGoals;
        homeAdvantage = homeAdvantage + dampingFactor * (target - homeAdvantage);
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

      // Konvergenz braucht ALLE drei Parametergruppen, nicht nur attack -
      // sonst kann die Schleife fälschlich abbrechen, während defense/
      // homeAdvantage noch spürbar wandern (live an PHÖNIX-Daten
      // beobachtet: attack stabilisierte sich früher als homeAdvantage).
      var maxDelta = (homeAdvantage - previousHomeAdvantage).abs();
      for (final id in teamIds) {
        final attackDelta = (attack[id]! - previousAttack[id]!).abs();
        if (attackDelta > maxDelta) maxDelta = attackDelta;
        final defenseDelta = (defense[id]! - previousDefense[id]!).abs();
        if (defenseDelta > maxDelta) maxDelta = defenseDelta;
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
      priors: priorMap,
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
