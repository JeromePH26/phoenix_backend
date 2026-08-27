import 'global_goals_v1_engine.dart';

/// Die eine globale PHÖNIX-Referenz für jede Fußballpartie.
///
/// Sie erzeugt ausschließlich erwartete Tore. Die nachgelagerte
/// Monte-Carlo-Simulation leitet daraus 1X2, Tor-, BTTS-, DNB-,
/// Doppelte-Chance- und Teamtor-Märkte konsistent aus *derselben*
/// Ergebnisverteilung ab. Es gibt damit keine getrennten Live-Modelle je
/// Markt. Liga-spezifische Engines können später nur diese Torerwartung für
/// ihre eigene Liga herausfordern, nie einzelne Markt-Wahrscheinlichkeiten.
class PhoenixGlobalEngine {
  const PhoenixGlobalEngine._();

  static const version = 'PHOENIX_GLOBAL_ENGINE_V1';

  static PhoenixGlobalEngineResult compute({
    required Map<String, Object?> availability,
    required String homeTeamId,
    required String awayTeamId,
    required double safeHomeFallback,
    required double safeAwayFallback,
    double? leagueAvgHomeGoalsPerGame,
    double? leagueAvgAwayGoalsPerGame,
    double homeContextDelta = 0,
    double awayContextDelta = 0,
  }) {
    final globalGoals = GlobalGoalsV1Engine.compute(
      availability: availability,
      homeTeamId: homeTeamId,
      awayTeamId: awayTeamId,
      leagueAvgHomeGoalsPerGame: leagueAvgHomeGoalsPerGame,
      leagueAvgAwayGoalsPerGame: leagueAvgAwayGoalsPerGame,
    );

    final usesGlobalFeatures =
        globalGoals.expectedHome != null && globalGoals.expectedAway != null;
    final baseHome = globalGoals.expectedHome ?? safeHomeFallback;
    final baseAway = globalGoals.expectedAway ?? safeAwayFallback;

    return PhoenixGlobalEngineResult(
      expectedHome: (baseHome + homeContextDelta).clamp(0.20, 3.80).toDouble(),
      expectedAway: (baseAway + awayContextDelta).clamp(0.20, 3.80).toDouble(),
      baseHome: baseHome,
      baseAway: baseAway,
      source: usesGlobalFeatures ? 'global_goals_v1' : 'global_safe_fallback',
      usesGlobalFeatures: usesGlobalFeatures,
      homeFeatureCoverage: globalGoals.homeFeatureCoverage,
      awayFeatureCoverage: globalGoals.awayFeatureCoverage,
    );
  }
}

class PhoenixGlobalEngineResult {
  const PhoenixGlobalEngineResult({
    required this.expectedHome,
    required this.expectedAway,
    required this.baseHome,
    required this.baseAway,
    required this.source,
    required this.usesGlobalFeatures,
    required this.homeFeatureCoverage,
    required this.awayFeatureCoverage,
  });

  final double expectedHome;
  final double expectedAway;
  final double baseHome;
  final double baseAway;
  final String source;
  final bool usesGlobalFeatures;
  final Map<String, Object?> homeFeatureCoverage;
  final Map<String, Object?> awayFeatureCoverage;
}
