import '../config/model_lab_config.dart';

/// Section 3: die sechs möglichen Status einer Liga x Markt-Kombination.
enum LeagueMarketStatus {
  notEnoughData('NOT_ENOUGH_DATA'),
  globalOnly('GLOBAL_ONLY'),
  leagueAdaptation('LEAGUE_ADAPTATION'),
  challengerReady('CHALLENGER_READY'),
  shadowActive('SHADOW_ACTIVE'),
  championActive('CHAMPION_ACTIVE');

  const LeagueMarketStatus(this.label);

  final String label;
}

/// Reine, deterministische Statusklassifikation (Section 3/8) - keine
/// künstliche Aktivierung bei zu wenig Daten (Section 93).
LeagueMarketStatus classifyLeagueMarketStatus({
  required int eligibleSampleSize,
  required bool hasLeagueChampion,
  required bool hasLeagueChallengers,
  required bool hasShadowPredictions,
  required ModelLabConfig config,
}) {
  if (eligibleSampleSize < config.minLearningEligibleSamples) {
    return LeagueMarketStatus.notEnoughData;
  }
  if (hasLeagueChampion) {
    return LeagueMarketStatus.championActive;
  }
  if (hasShadowPredictions) {
    return LeagueMarketStatus.shadowActive;
  }
  if (hasLeagueChallengers) {
    return LeagueMarketStatus.challengerReady;
  }
  if (eligibleSampleSize >= config.leagueAdaptationSampleThreshold) {
    return LeagueMarketStatus.leagueAdaptation;
  }
  return LeagueMarketStatus.globalOnly;
}

/// Section 8: benannte Sample-Größenklasse (zur Anzeige im Model Lab, z.B.
/// "300-599: stärkere Liga-Anpassung möglich").
String sampleSizeTier(int eligibleSampleSize, ModelLabConfig config) {
  if (eligibleSampleSize < config.leagueAdaptationSampleThreshold) {
    return 'practically_global_only';
  }
  if (eligibleSampleSize < config.strongerAdaptationSampleThreshold) {
    return 'cautious_league_adaptation';
  }
  if (eligibleSampleSize < config.fullLeagueEngineSampleThreshold) {
    return 'stronger_league_adaptation';
  }
  return 'full_league_engine_possible';
}
