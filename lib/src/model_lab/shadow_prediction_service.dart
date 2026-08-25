import '../config/model_lab_config.dart';
import '../database/database.dart';
import 'engine_replica.dart';
import 'feature_whitelist.dart';
import 'global_goals_v1_engine.dart';
import 'learning_dataset_builder.dart';
import 'learning_market.dart';
import 'learning_sample.dart';
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
          final modelWeights = model['weights'];
          // GLOBAL_GOALS_V1-/GlobalMarketEngine-Challenger brauchen einen
          // Phase-2-Snapshot des NÄCHSTEN Fixtures (andere Datenquelle als
          // der whitelisted-Feature-Satz, den Shadow Predictions hier
          // verwenden) - dessen Live-Beschaffung ist noch nicht angebunden.
          // `weightsFromModel` würde für so ein Model kommentarlos auf
          // attackWeight=0.5 zurückfallen und eine falsche Vorhersage unter
          // dem Namen dieses Challengers speichern; bis die Anbindung
          // existiert, wird für jedes Model mit einem `engineVersion`-Tag
          // (d.h. jedes Nicht-attackWeight-Model) lieber ehrlich keine
          // Shadow Prediction erzeugt statt eine irreführende.
          if (modelWeights is Map && modelWeights['engineVersion'] != null) {
            continue;
          }
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

    // Section (2026-08-25): zweiter Durchlauf speziell für GLOBAL_GOALS_V1-/
    // GlobalMarketEngine-Modelle. Der Durchlauf oben überspringt sie
    // bewusst (kommentiert an `modelWeights['engineVersion']`), weil sie den
    // rohen Phase-2-Availability-Snapshot brauchen statt des whitelisted
    // Feature-Satzes. Vorher bedeutete das: JEDER aktuelle Champion (alle 17
    // Märkte sind inzwischen dieser Engine-Familie) bekam nie eine
    // Vorhersage-Historie. Nutzt `registry.modelEngine()` (siehe dortiger
    // Kommentar: "muss für jeden Champion-Lesezugriff verwendet werden")
    // statt direkt Gewichte zu lesen.
    final globalRows = await database.modelLabUpcomingGlobalMarketSnapshots(
      minDataQuality: config.minDataQuality,
    );
    for (final row in globalRows) {
      final fixtureId = row['fixture_id']?.toString();
      final leagueId = row['league_id']?.toString();
      final availabilityRaw = row['availability'];
      final kickoff = _dateTime(row['kickoff_utc']);
      final phaseTwoScanRunId = row['phase_two_scan_run_id'] as int?;
      final homeTeamId = row['home_team_id']?.toString() ?? '';
      final awayTeamId = row['away_team_id']?.toString() ?? '';
      if (fixtureId == null ||
          leagueId == null ||
          availabilityRaw is! Map ||
          kickoff == null ||
          homeTeamId.isEmpty ||
          awayTeamId.isEmpty) {
        continue;
      }
      final availability = Map<String, Object?>.from(availabilityRaw);
      final leagueAvgHome = _double(row['league_avg_home_goals']);
      final leagueAvgAway = _double(row['league_avg_away_goals']);
      final goalsV1 = GlobalGoalsV1Engine.compute(
        availability: availability,
        homeTeamId: homeTeamId,
        awayTeamId: awayTeamId,
        leagueAvgHomeGoalsPerGame: leagueAvgHome,
        leagueAvgAwayGoalsPerGame: leagueAvgAway,
      );
      // Nur für `ModelEngine.evaluate()` konstruiert (globalGoalsV1/
      // globalMarket lesen weder homeGoals/awayGoals noch snapshotCreatedAt) -
      // kein echtes Trainings-Sample, deshalb bewusst kein Ergebnis erfunden.
      final sample = LearningSample(
        fixtureId: fixtureId,
        leagueId: leagueId,
        kickoff: kickoff,
        snapshotCreatedAt: DateTime.now().toUtc(),
        dataQuality: 0,
        features: const {},
        homeGoals: 0,
        awayGoals: 0,
        globalGoalsV1ExpectedHome: goalsV1.expectedHome,
        globalGoalsV1ExpectedAway: goalsV1.expectedAway,
        globalMarketAvailability: availability,
        globalMarketHomeTeamId: homeTeamId,
        globalMarketAwayTeamId: awayTeamId,
        globalMarketLeagueAvgHomeGoals: leagueAvgHome,
        globalMarketLeagueAvgAwayGoals: leagueAvgAway,
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
        ];
        final modelsById = <int, Map<String, Object?>>{};
        for (final model in candidates) {
          final modelId = model['id'];
          if (modelId is int) modelsById[modelId] = model;
        }

        for (final model in modelsById.values) {
          final modelId = model['id'] as int;
          final engine = registry.modelEngine(model);
          // attackWeight-Modelle wurden bereits im Durchlauf oben behandelt.
          if (!(engine.isGlobalGoalsV1 || engine.isGlobalMarket)) continue;
          final output = engine.evaluate(market: market, sample: sample);
          if (output == null) continue;

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

  /// Section (Prediction-History-Backfill, 2026-08-25): "bereits
  /// analysierte [Spiele] sollen [in der Historie] auftauchen" - ohne diesen
  /// Nachtrag würde die Historie erst ab jetzt langsam wachsen, obwohl
  /// längst tausende bereits abgeschlossene, leakage-sichere Analysen
  /// vorliegen. Nutzt exakt dieselben Samples wie das echte Training
  /// ([LearningDatasetBuilder]), damit garantiert dieselben Sicherheits-/
  /// Leakage-Regeln gelten wie überall sonst im Model Lab. Deckt sowohl die
  /// neuen Global-Engine- als auch die alten attackWeight-Modelle ab - beide
  /// hatten bislang nur die (noch leere) künftige Vorhersage-Historie, nie
  /// eine rückwirkende.
  ///
  /// Champion/Challenger je Liga×Markt werden einmalig gecacht: sie ändern
  /// sich nicht pro Sample, und ohne diesen Cache wären bei tausenden
  /// Samples ebenso viele einzelne DB-Rundreisen nötig. Idempotent (derselbe
  /// Unique-Index wie bei echten Predictions) - ein erneuter Aufruf mit
  /// höherem [limit] ergänzt nur, was noch fehlt.
  Future<int> backfillHistoricalShadowPredictions({int limit = 2000}) async {
    final builder = LearningDatasetBuilder(database: database, config: config);
    final samples = await builder.buildSamples();
    // Neueste zuerst: bei einem Abbruch/Limit ist die jüngste, relevanteste
    // Historie zuerst gefüllt statt eines zufälligen alten Ausschnitts.
    final ordered = samples.reversed.take(limit).toList();

    final registry = ModelRegistryService(database: database, config: config);
    final candidateCache = <String, List<Map<String, Object?>>>{};
    var created = 0;

    for (final sample in ordered) {
      for (final market in LearningMarket.values) {
        final cacheKey = '${sample.leagueId}|${market.key}';
        if (!candidateCache.containsKey(cacheKey)) {
          final champion = await registry.productionChampion(
            leagueId: sample.leagueId,
            market: market.key,
          );
          final challengers = await registry.currentChallengers(
            leagueId: sample.leagueId,
            market: market.key,
          );
          candidateCache[cacheKey] = [
            if (champion != null) champion,
            ...challengers,
          ];
        }

        final modelsById = <int, Map<String, Object?>>{};
        for (final model in candidateCache[cacheKey]!) {
          final modelId = model['id'];
          if (modelId is int) modelsById[modelId] = model;
        }

        final outcomeIndex = sample.outcomeIndexFor(market);
        for (final model in modelsById.values) {
          final modelId = model['id'] as int;
          final engine = registry.modelEngine(model);
          final output = engine.evaluate(market: market, sample: sample);
          if (output == null) continue;

          final brier = market.isMultiClass
              ? Metrics.brierMultiClass(
                  probabilities: output.classProbabilities,
                  outcomeIndex: outcomeIndex,
                )
              : Metrics.brierBinary(
                  probability: output.classProbabilities[0],
                  outcomePositive: outcomeIndex == 0,
                );
          final logLoss = market.isMultiClass
              ? Metrics.logLossMultiClass(
                  probabilities: output.classProbabilities,
                  outcomeIndex: outcomeIndex,
                )
              : Metrics.logLossBinary(
                  probability: output.classProbabilities[0],
                  outcomePositive: outcomeIndex == 0,
                );

          final inserted = await database.upsertSettledShadowPrediction(
            modelVersionId: modelId,
            fixtureId: sample.fixtureId,
            leagueId: sample.leagueId,
            market: market.key,
            kickoff: sample.kickoff,
            classLabels: output.classLabels,
            classProbabilities: output.classProbabilities,
            outcomeIndex: outcomeIndex,
            brierScore: brier,
            logLoss: logLoss,
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

  static double? _double(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }
}
