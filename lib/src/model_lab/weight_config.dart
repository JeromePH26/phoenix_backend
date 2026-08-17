import 'dart:convert';
import 'package:crypto/crypto.dart';

import '../config/model_lab_config.dart';

/// Der einzige V0-Gewichtsparameter, den Challenger kontrolliert variieren:
/// das Mischverhältnis zwischen "eigener Torquote" (Angriff) und
/// "gegnerischer Gegentorquote" (Verteidigung des Gegners) bei der
/// Torerwartung. Die produktive Engine nutzt aktuell fest 50/50
/// (`FootballEngineInputService._normalize`: `(a + b) / 2`).
///
/// Dies ist bewusst der EINZIGE Freiheitsgrad für V0 (Section 13/14):
/// "Nutze ausschließlich Komponenten, die tatsächlich in der aktuellen
/// PHÖNIX-Engine vorhanden sind" - Form, Tabelle, Verletzungen, H2H etc.
/// existieren im heutigen Engine-Code nicht als numerische Inputs (siehe
/// Backend-Audit) und werden deshalb NICHT erfunden.
class EngineWeightConfig {
  const EngineWeightConfig({required this.attackWeight});

  /// Gewicht der eigenen Torquote (Angriff). Gegengewicht
  /// `1 - attackWeight` fällt auf die gegnerische Gegentorquote (Verteidigung
  /// des Gegners). Global-/Champion-Baseline = exakt 0.5 (identisch zur
  /// produktiven Engine-Formel).
  final double attackWeight;

  static const EngineWeightConfig global = EngineWeightConfig(
    attackWeight: 0.5,
  );

  double get defenseWeight => 1 - attackWeight;

  /// Section 14: begrenzt, normalisiert, nachvollziehbar. Ein Kandidat
  /// außerhalb der konfigurierten Grenzen ist per Definition kein
  /// zulässiger V0-Challenger.
  bool isWithinBounds(ModelLabConfig config) =>
      attackWeight >= config.attackWeightMin &&
      attackWeight <= config.attackWeightMax;

  /// Section 15 Shrinkage: je kleiner die Liga-Stichprobe, desto näher
  /// bleibt der effektive Kandidat an der Global Engine (0.5). Einfache,
  /// nachvollziehbare Empirical-Bayes-Formel: factor = n / (n + k).
  EngineWeightConfig shrunkTowardsGlobal({
    required int sampleSize,
    required ModelLabConfig config,
  }) {
    final factor = sampleSize / (sampleSize + config.shrinkageK);
    final shrunkWeight =
        EngineWeightConfig.global.attackWeight +
        factor * (attackWeight - EngineWeightConfig.global.attackWeight);
    return EngineWeightConfig(attackWeight: shrunkWeight);
  }

  Map<String, Object?> toJson() => {
    'attackWeight': double.parse(attackWeight.toStringAsFixed(4)),
    'defenseWeight': double.parse(defenseWeight.toStringAsFixed(4)),
  };

  factory EngineWeightConfig.fromJson(Map<String, Object?> json) =>
      EngineWeightConfig(
        attackWeight: (json['attackWeight'] as num?)?.toDouble() ?? 0.5,
      );

  /// Deterministischer Config-Hash (Section 12) - identische Gewichte ergeben
  /// immer denselben Hash, unabhängig von Erstellungszeitpunkt.
  String configHash() {
    final canonical = jsonEncode({
      'attackWeight': double.parse(attackWeight.toStringAsFixed(6)),
      'engineVersion': engineReplicaVersion,
    });
    return sha256.convert(utf8.encode(canonical)).toString();
  }
}

/// Versionskennzeichen der Model-Lab-lokalen Engine-Nachbildung
/// (`engine_replica.dart`). Ändert sich diese Logik jemals, ändert sich
/// automatisch auch jeder Config-Hash - alte Challenger bleiben dadurch
/// eindeutig einer Codebasis zuordenbar.
const String engineReplicaVersion = 'model_lab_engine_replica_v1';
