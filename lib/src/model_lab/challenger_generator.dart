import '../config/model_lab_config.dart';

/// Section 13/14: erzeugt die feste, kontrollierte Liste von
/// attackWeight-Kandidaten für neue Challenger. Bewusst KEIN
/// Gradientenverfahren/keine freie Optimierung - nur ein begrenztes,
/// nachvollziehbares Gitter innerhalb der konfigurierten Grenzen
/// (Section 14: "keine absurden Kandidaten").
class ChallengerGenerator {
  const ChallengerGenerator._();

  static List<double> candidateAttackWeights(ModelLabConfig config) {
    final withinBounds = config.attackWeightGrid
        .where(
          (w) => w >= config.attackWeightMin && w <= config.attackWeightMax,
        )
        .toSet() // Duplikate aus der Config entfernen
        .toList()
      ..sort();
    return withinBounds.take(config.maxChallengersPerLeagueMarket).toList();
  }
}
