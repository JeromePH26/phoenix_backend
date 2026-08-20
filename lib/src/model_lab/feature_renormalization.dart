/// Section "SEHR WICHTIG – FEHLENDE DATEN": generischer Baustein für jedes
/// gewichtete Feature-Modell in PHÖNIX (aktuell: [GlobalGoalsV1Engine]).
///
/// Eine fehlende Eingabe (NULL) wird NIEMALS als 0 interpretiert - 0 hat
/// fachlich eine völlig andere Bedeutung ("0 Tore erwartet" statt "keine
/// Daten vorhanden"). Stattdessen wird das Feature aus der Gewichtung
/// entfernt und die verbleibenden Gewichte werden proportional wieder auf
/// 100 % normalisiert.
library;

class WeightedFeature {
  const WeightedFeature({
    required this.key,
    required this.idealWeight,
    required this.value,
  }) : assert(idealWeight > 0, 'idealWeight muss positiv sein');

  /// Eindeutiger Feature-Schlüssel (z.B. "seasonAttack").
  final String key;

  /// Ursprüngliches ("ideales") Gewicht, z.B. 15 für 15 Prozentpunkte.
  /// Muss nicht auf 100 aufsummieren - die Klasse normalisiert selbst.
  final double idealWeight;

  /// Der tatsächliche Featurewert, oder `null` wenn nicht verfügbar.
  final double? value;

  bool get isAvailable => value != null;
}

class RenormalizationResult {
  const RenormalizationResult({
    required this.value,
    required this.originalWeights,
    required this.effectiveWeights,
    required this.availableFeatureKeys,
    required this.missingFeatureKeys,
  });

  /// Der gewichtete Durchschnitt über alle verfügbaren Features - `null`,
  /// wenn ausnahmslos alle Features fehlten.
  final double? value;

  /// Ursprüngliches Gewicht jedes Features (verfügbar oder nicht), auf
  /// Summe 1.0 normalisiert - rein dokumentarisch für Feature Coverage.
  final Map<String, double> originalWeights;

  /// Tatsächlich verwendetes Gewicht jedes VERFÜGBAREN Features nach
  /// Renormalisierung - summiert exakt auf 1.0 (sofern mind. ein Feature
  /// verfügbar war).
  final Map<String, double> effectiveWeights;

  final List<String> availableFeatureKeys;
  final List<String> missingFeatureKeys;
}

/// Kombiniert [features] zu einem gewichteten Durchschnitt. Fehlende Werte
/// (`value == null`) werden aus der Gewichtung entfernt statt als 0 gezählt;
/// die verbleibenden Gewichte werden proportional auf 100 % renormalisiert.
RenormalizationResult combineWeightedFeatures(List<WeightedFeature> features) {
  assert(features.isNotEmpty, 'Mindestens ein Feature erforderlich');
  assert(
    features.map((f) => f.key).toSet().length == features.length,
    'Feature-Keys müssen eindeutig sein',
  );

  final totalIdealWeight = features.fold<double>(
    0,
    (sum, f) => sum + f.idealWeight,
  );
  final originalWeights = {
    for (final f in features) f.key: f.idealWeight / totalIdealWeight,
  };

  final available = features.where((f) => f.isAvailable).toList();
  final missing = features.where((f) => !f.isAvailable).toList();

  if (available.isEmpty) {
    return RenormalizationResult(
      value: null,
      originalWeights: originalWeights,
      effectiveWeights: const {},
      availableFeatureKeys: const [],
      missingFeatureKeys: missing.map((f) => f.key).toList(),
    );
  }

  final availableWeightSum = available.fold<double>(
    0,
    (sum, f) => sum + f.idealWeight,
  );
  final effectiveWeights = {
    for (final f in available) f.key: f.idealWeight / availableWeightSum,
  };
  final value = available.fold<double>(
    0,
    (sum, f) => sum + f.value! * (f.idealWeight / availableWeightSum),
  );

  return RenormalizationResult(
    value: value,
    originalWeights: originalWeights,
    effectiveWeights: effectiveWeights,
    availableFeatureKeys: available.map((f) => f.key).toList(),
    missingFeatureKeys: missing.map((f) => f.key).toList(),
  );
}
