import '../config/model_lab_config.dart';
import '../database/database.dart';
import 'engine_replica.dart';
import 'feature_whitelist.dart';
import 'learning_market.dart';
import 'metrics.dart';
import 'model_registry_service.dart';

/// Section 33-36: Shadow Predictions. Erzeugt für jeden aktiven Challenger
/// (und optional den vorherigen Champion, Section 36) eine Vorhersage auf
/// Basis DESSELBEN bereits gespeicherten Pre-Match-Snapshots wie die
/// produktive Engine - ohne zusätzliche API-Football-/KI-Aufrufe
/// (Section 34/84). Hat eine Liga noch keinen eigenen Champion, wird der
/// globale Champion als feste Rückfallbasis verwendet. So beginnt die
/// Datensammlung sofort, ohne einen unreifen Liga-Champion zu erfinden.
class ShadowPredictionService {
  ShadowPredictionService({required this.database, required this.config});

  final PhoenixDatabase database;
  final ModelLabConfig config;

  /// Section 33: erzeugt Shadow Predictions für alle Fixtures, deren Kickoff
  /// noch in der Zukunft liegt, für jeden aktiven Champion + Challenger der
  /// jeweiligen Liga x Markt-Kombination. Idempotent (UNIQUE-Constraint auf
  /// model_version_id + fixture_id + market verhindert Duplikate).
  Future<int> generatePendingShadowPredictions() async {
    final rows = await database.modelLabUpcomingSnapshots(
      minDataQuality: config.minDataQuality,
    );
    final registry = ModelRegistryService(database: database, config: config);

    var created = 0;
    for (final row in rows) {
      final fixtureId = row['fixture_id']?.toString();
      final leagueId = row['league_id']?.toString();
      final normalizedInput = row['normalized_input'];
      final kickoff = _dateTime(row['kickoff_utc']);
      final phaseTwoScanRunId = row['phase_two_scan_run_id'] as int?;
      if (fixtureId == null ||
          leagueId == null ||
          normalizedInput is! Map ||
          kickoff == null) {
        continue;
      }

      final features = FeatureWhitelist.extract(
        Map<String, Object?>.from(normalizedInput),
      );

      for (final market in LearningMarket.values) {
        final champion = await registry.productionChampion(
          leagueId: leagueId,
          market: market.key,
        );
        final candidates = <Map<String, Object?>>[
          if (champion != null) champion,
          ...await registry.currentChallengers(
            leagueId: leagueId,
            market: market.key,
          ),
          // Section 36: der VORHERIGE Champion soll (falls vorhanden) nach
          // einer Promotion optional weiter Shadow Predictions erzeugen.
          // Da V0 keine echten Promotions durchführt (Section 53), betrifft
          // dies nur zukünftige, außerhalb von V0 liegende Zustände - der
          // Code ist bereits dafür vorbereitet.
          ...await database.allModelVersions(status: 'retired', limit: 20).then(
                (list) => list.where(
                  (m) =>
                      m['market'] == market.key &&
                      (m['league_id']?.toString() ?? leagueId) == leagueId,
                ),
              ),
        ];

        // Ein Modell kann durch einen späteren Liga-Champion und die
        // Rückfallbasis theoretisch doppelt in der Liste landen. Pro
        // fixture×market darf es exakt eine Shadow Prediction geben.
        final modelsById = <int, Map<String, Object?>>{};
        for (final model in candidates) {
          final modelId = model['id'];
          if (modelId is int) modelsById[modelId] = model;
        }

        for (final model in modelsById.values) {
          final modelId = model['id'] as int;
          final weights = registry.weightsFromModel(model);
          final output = EngineReplica.evaluate(
            market: market,
            features: features,
            weights: weights,
          );

          final inserted = await database.upsertShadowPrediction(
            modelVersionId: modelId,
            fixtureId: fixtureId,
            leagueId: leagueId,
            market: market.key,
            phaseTwoScanRunId: phaseTwoScanRunId,
            kickoff: kickoff,
            classLabels: output.classLabels,
            classProbabilities: output.classProbabilities,
          );
          if (inserted) created += 1;
        }
      }
    }
    return created;
  }

  /// Section 35: nach Matchende werden offene Shadow Predictions mit dem
  /// tatsächlichen Ergebnis bewertet (Brier/Log Loss je Prediction).
  Future<int> settlePendingShadowPredictions() async {
    final pending = await database.pendingShadowPredictions();
    var settled = 0;

    for (final row in pending) {
      final status = row['match_status']?.toString();
      final homeGoals = _int(row['home_goals']);
      final awayGoals = _int(row['away_goals']);
      if (status == null ||
          !PhoenixDatabase.modelLabFinishedMatchStatuses.contains(status) ||
          homeGoals == null ||
          awayGoals == null) {
        continue;
      }

      final marketKey = row['market']?.toString();
      final market = LearningMarket.fromKey(marketKey ?? '');
      if (market == null) continue;

      final classProbabilitiesRaw = row['class_probabilities'];
      if (classProbabilitiesRaw is! List) continue;
      final probabilities =
          classProbabilitiesRaw.map((v) => (v as num).toDouble()).toList();

      final outcomeIndex = _outcomeIndex(market, homeGoals, awayGoals);
      final brier = market.isMultiClass
          ? Metrics.brierMultiClass(
              probabilities: probabilities,
              outcomeIndex: outcomeIndex,
            )
          : Metrics.brierBinary(
              probability: probabilities[0],
              outcomePositive: outcomeIndex == 0,
            );
      final logLoss = market.isMultiClass
          ? Metrics.logLossMultiClass(
              probabilities: probabilities,
              outcomeIndex: outcomeIndex,
            )
          : Metrics.logLossBinary(
              probability: probabilities[0],
              outcomePositive: outcomeIndex == 0,
            );

      await database.settleShadowPrediction(
        id: row['id'] as int,
        outcomeIndex: outcomeIndex,
        brierScore: brier,
        logLoss: logLoss,
      );
      settled += 1;
    }
    return settled;
  }

  int _outcomeIndex(LearningMarket market, int homeGoals, int awayGoals) {
    switch (market) {
      case LearningMarket.oneXTwo:
        if (homeGoals > awayGoals) return 0;
        if (homeGoals == awayGoals) return 1;
        return 2;
      case LearningMarket.overUnder25:
        return (homeGoals + awayGoals) > 2.5 ? 0 : 1;
      case LearningMarket.overUnder15:
        return (homeGoals + awayGoals) > 1.5 ? 0 : 1;
      case LearningMarket.overUnder35:
        return (homeGoals + awayGoals) > 3.5 ? 0 : 1;
      case LearningMarket.btts:
        return (homeGoals >= 1 && awayGoals >= 1) ? 0 : 1;
      case LearningMarket.homeTeamOver15:
        return homeGoals > 1.5 ? 0 : 1;
      case LearningMarket.homeTeamUnder15:
        return homeGoals <= 1.5 ? 0 : 1;
      case LearningMarket.awayTeamOver15:
        return awayGoals > 1.5 ? 0 : 1;
      case LearningMarket.awayTeamUnder15:
        return awayGoals <= 1.5 ? 0 : 1;
      case LearningMarket.homeTeamOver25:
        return homeGoals > 2.5 ? 0 : 1;
      case LearningMarket.homeTeamUnder25:
        return homeGoals <= 2.5 ? 0 : 1;
      case LearningMarket.awayTeamOver25:
        return awayGoals > 2.5 ? 0 : 1;
      case LearningMarket.awayTeamUnder25:
        return awayGoals <= 2.5 ? 0 : 1;
      case LearningMarket.doubleChance1x:
        return homeGoals >= awayGoals ? 0 : 1;
      case LearningMarket.doubleChanceX2:
        return awayGoals >= homeGoals ? 0 : 1;
      case LearningMarket.drawNoBetHome:
        if (homeGoals > awayGoals) return 0;
        if (homeGoals == awayGoals) return 1;
        return 2;
      case LearningMarket.drawNoBetAway:
        if (awayGoals > homeGoals) return 0;
        if (homeGoals == awayGoals) return 1;
        return 2;
    }
  }

  static DateTime? _dateTime(Object? value) {
    if (value is DateTime) return value.toUtc();
    if (value is String) return DateTime.tryParse(value)?.toUtc();
    return null;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '');
  }
}
