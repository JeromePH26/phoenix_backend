/// POSITIVE Feature-Whitelist für das Self-Learning-System (Section 20).
///
/// Nur die hier explizit gelisteten Pfade aus dem gespeicherten
/// `football_engine_inputs.normalized_input`-JSON (siehe
/// `FootballEngineInputService._normalize`) dürfen als Learning-Feature
/// verwendet werden. Alles andere - insbesondere neue, zukünftige
/// raw_json-Felder - wird automatisch ignoriert, auch wenn es technisch im
/// Snapshot vorhanden wäre. Das verhindert versehentliches Data Leakage und
/// versehentliche Nutzung von KI-/Gemini-Legacy-Feldern.
///
/// AI-/Gemini-Felder stehen NIE auf dieser Liste (Section 5/17):
/// `aiContext`, `geminiHomeGoalDelta`, `geminiAwayGoalDelta`,
/// `contextAdjusted`, `context`, `contextReliability`, `aiReliability`,
/// `aiAnalysis` usw. bleiben dauerhaft ausgeschlossen.
class FeatureWhitelist {
  const FeatureWhitelist._();

  /// Punkt-getrennte Pfade innerhalb des gespeicherten
  /// `normalized_input`-JSON, die für das Learning zugelassen sind.
  static const Set<String> allowedPaths = {
    'raw.homeGoalsForAverageHome',
    'raw.homeGoalsAgainstAverageHome',
    'raw.awayGoalsForAverageAway',
    'raw.awayGoalsAgainstAverageAway',
    'dataQuality',
    'realXgAvailable',
    'sourceType',
    'normalized.homeAttackStrength',
    'normalized.homeDefenseStrength',
    'normalized.awayAttackStrength',
    'normalized.awayDefenseStrength',
    'normalized.baseGoalRateExpectedHome',
    'normalized.baseGoalRateExpectedAway',
  };

  /// Explizit ausgeschlossene AI-/Gemini-Legacy-Pfade. Diese Liste ist nicht
  /// erforderlich, damit die Whitelist funktioniert (jeder nicht gelistete
  /// Pfad ist ohnehin ausgeschlossen) - sie dokumentiert aber ausdrücklich,
  /// welche bekannten Legacy-Felder niemals durchgelassen werden dürfen, und
  /// wird von Tests genutzt, um Regressionen zu erkennen.
  static const Set<String> explicitlyBlockedPaths = {
    'aiContext',
    'aiContext.applied',
    'aiContext.reliability',
    'aiContext.contextSource',
    'aiContext.homeGoalDelta',
    'aiContext.awayGoalDelta',
    'aiContext.lineupStatus',
    'aiContext.fallbackUsed',
    'normalized.geminiHomeGoalDelta',
    'normalized.geminiAwayGoalDelta',
    'normalized.contextAdjusted',
    'warnings',
    'engineReady',
  };

  /// Extrahiert ausschließlich whitelisted Features aus einem gespeicherten
  /// `normalized_input`-Snapshot. Nicht gelistete Felder - inklusive jedes
  /// zukünftigen, heute noch unbekannten raw_json-Felds - werden stillschweigend
  /// verworfen statt automatisch durchgereicht.
  static Map<String, Object?> extract(Map<String, Object?> normalizedInput) {
    final result = <String, Object?>{};
    for (final path in allowedPaths) {
      final value = _readPath(normalizedInput, path);
      if (value != null) {
        result[path] = value;
      }
    }
    return result;
  }

  static Object? _readPath(Map<String, Object?> source, String path) {
    final segments = path.split('.');
    Object? current = source;
    for (final segment in segments) {
      if (current is Map) {
        current = Map<String, Object?>.from(current)[segment];
      } else {
        return null;
      }
    }
    return current;
  }
}
