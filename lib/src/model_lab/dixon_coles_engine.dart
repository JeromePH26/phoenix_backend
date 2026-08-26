import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Section 4 (Claude AN2.txt, "EINE ENGINE PRO LIGA"): erster konkreter
/// Baustein einer gemeinsamen Match-State-Engine statt unabhängiger
/// Markt-Formeln. Die produktive Simulation (`football_simulation_service.
/// dart`) und die bisherige Model-Lab-Nachbildung (`poisson_math.dart`)
/// ziehen Heim-/Auswärtstore heute komplett unabhängig voneinander - kein
/// Ausgleich für die empirisch bekannte Korrelation bei niedrigen
/// Ergebnissen (Dixon & Coles 1997).
///
/// `DixonColesEngine` testet als reiner Model-Lab-Challenger (siehe
/// `ModelEngine.dixonColes` in `engine_replica.dart`), ob ein niedriger
/// Korrelationsfaktor `rho` die Kalibrierung verbessert - BEVOR das in die
/// produktive Simulation übernommen wird (Section 41/42: "teste alt gegen
/// neu", kein blinder Umbau). Nutzt bewusst dieselben Torerwartungen wie
/// der globale Champion (`EngineWeightConfig.global`, attackWeight 0.5) -
/// `rho` ist die einzig getestete Variable, sauberstes mögliches Experiment.
class DixonColesEngine {
  const DixonColesEngine._();

  static const String version = 'DIXON_COLES_V1';

  /// Kleines, benanntes Hypothesen-Set statt eines freien Suchraums
  /// (Section 14: "keine absurden Kandidaten") - Literaturwerte für die
  /// typische Fußball-Korrelation bei niedrigen Ergebnissen.
  static const List<double> rhoCandidates = [-0.05, -0.10];

  /// Deterministischer Hash: derselbe rho-Wert ergibt immer denselben Hash
  /// (verhindert Duplikate über den bestehenden Unique-Index auf
  /// `(market, league_id, config_hash)` - dasselbe Muster wie
  /// `GlobalMarketEngine.configHash()`/`EngineWeightConfig.configHash()`).
  static String configHash(double rho) {
    final canonical = '$version:${rho.toStringAsFixed(4)}';
    return sha256.convert(utf8.encode(canonical)).toString();
  }
}
