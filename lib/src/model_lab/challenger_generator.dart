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
    if (withinBounds.length <= config.maxChallengersPerLeagueMarket ||
        config.maxChallengersPerLeagueMarket <= 1) {
      return withinBounds.take(config.maxChallengersPerLeagueMarket).toList();
    }
    // Ein simples `.take(n)` nach dem Sortieren hätte hier immer nur die
    // NIEDRIGSTEN Werte des Gitters behalten und die obere Hälfte des
    // konfigurierten Suchraums stillschweigend nie getestet, sobald das
    // Gitter mehr Punkte als `maxChallengersPerLeagueMarket` enthält.
    // Gleichmäßiges Sampling über das gesamte (sortierte) Gitter deckt
    // stattdessen den ganzen erlaubten Bereich ab.
    final step = (withinBounds.length - 1) / (config.maxChallengersPerLeagueMarket - 1);
    return [
      for (var i = 0; i < config.maxChallengersPerLeagueMarket; i++)
        withinBounds[(i * step).round().clamp(0, withinBounds.length - 1)],
    ].toSet().toList()
      ..sort();
  }
}
