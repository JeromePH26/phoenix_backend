import '../config/model_lab_config.dart';
import '../database/database.dart';
import 'learning_dataset_builder.dart';
import 'learning_market.dart';
import 'metrics.dart';
import 'model_lab_schedule.dart';
import 'model_registry_service.dart';
import 'walk_forward_evaluator.dart';

/// Section 48-52: der monatliche Champion Review am ersten Mittwoch. Erzeugt
/// pro Liga x Markt-Kombination mit mindestens einem Challenger eine
/// Empfehlung. Eine automatische Promotion ist nur möglich, wenn sie
/// explizit per ENV freigegeben ist UND alle statistischen Gates bestanden
/// wurden; ohne dieses Opt-in bleibt der Review rein beobachtend.
class MonthlyReviewService {
  MonthlyReviewService({required this.database, required this.config});

  final PhoenixDatabase database;
  final ModelLabConfig config;

  static const String lockName = 'monthly_review';

  Future<Map<String, Object?>> run({required String triggerType}) async {
    final berlinNow = ModelLabSchedule.berlinNow();

    // Section 49/94/95: der automatische (geplante) Lauf ist AUSSCHLIESSLICH
    // am ersten Mittwoch des Monats ein echter Review - jeder andere
    // Mittwoch (bzw. jeder andere Wochentag) ist ein sauberer no-op. Der
    // manuelle Test-Button (Section 79) nutzt dieselbe Business-Logik,
    // ignoriert aber bewusst das Datumsgate, damit er jederzeit testbar ist.
    if (triggerType == 'scheduled' &&
        !ModelLabSchedule.isFirstWednesday(berlinNow, config)) {
      return {
        'status': 'skipped',
        'reason': 'Heute ist nicht der erste Mittwoch des Monats.',
      };
    }

    final locked = await database.acquireModelLabLock(
      lockName,
      staleAfterMinutes: config.staleLockMinutes,
    );
    if (!locked) {
      return {
        'status': 'skipped',
        'reason': 'Ein anderer Monthly Review läuft bereits (Lock aktiv).',
      };
    }

    try {
      final year = berlinNow.year;
      final month = berlinNow.month;
      final registry = ModelRegistryService(
        database: database,
        config: config,
      );
      final datasetBuilder = LearningDatasetBuilder(
        database: database,
        config: config,
      );

      final leagues = await database.modelLabWhitelistedLeagues();
      final results = <Map<String, Object?>>[];

      for (final market in LearningMarket.values) {
        for (final league in leagues) {
          final leagueId = league['league_id']?.toString();
          if (leagueId == null) continue;

          final challengers = await registry.currentChallengers(
            leagueId: leagueId,
            market: market.key,
          );
          if (challengers.isEmpty) continue;

          // Section 50: Idempotenz - pro Jahr/Monat/Liga/Markt nur EIN
          // Review.
          final alreadyReviewed = await database.monthlyReviewExists(
            year: year,
            month: month,
            leagueId: leagueId,
            market: market.key,
          );
          if (alreadyReviewed) continue;

          final review = await _reviewLeagueMarket(
            leagueId: leagueId,
            market: market,
            challengers: challengers,
            registry: registry,
            datasetBuilder: datasetBuilder,
            year: year,
            month: month,
          );
          results.add(review);
        }
      }

      await database.insertModelLabAuditLog(
        action: 'monthly_review_completed',
        actor: triggerType == 'scheduled' ? 'system' : 'admin',
        details: {'year': year, 'month': month, 'reviewed': results.length},
      );

      return {
        'status': 'completed',
        'year': year,
        'month': month,
        'reviewed': results.length,
        'results': results,
      };
    } finally {
      await database.releaseModelLabLock(lockName);
    }
  }

  Future<Map<String, Object?>> _reviewLeagueMarket({
    required String leagueId,
    required LearningMarket market,
    required List<Map<String, Object?>> challengers,
    required ModelRegistryService registry,
    required LearningDatasetBuilder datasetBuilder,
    required int year,
    required int month,
  }) async {
    final championModel = await registry.currentChampion(
            leagueId: leagueId, market: market.key) ??
        await registry.currentChampion(leagueId: null, market: market.key);

    if (championModel == null) {
      return _persistReview(
        year: year,
        month: month,
        leagueId: leagueId,
        market: market,
        championModelId: null,
        challengerModelId: null,
        sameMatchSample: 0,
        metrics: const {},
        uncertainty: const {},
        recommendation: 'KEIN_GEEIGNETER_CHALLENGER',
        reason: 'Keine Champion-Basis (auch keine Global Baseline) gefunden.',
      );
    }

    final championEngine = registry.modelEngine(championModel);
    final championId = championModel['id'] as int;

    // Section 51: aktuelle Holdout-Menge frisch berechnen (nicht nur die zum
    // Erstellungszeitpunkt gespeicherte Auswertung), damit seit der
    // Challenger-Erstellung neu gesettelte Matches mit einfließen.
    final samples = await datasetBuilder.buildSamples(leagueId: leagueId);
    final split = ChronologicalSplit.split(samples, config);

    Map<String, Object?>? best;
    double? bestMeanDifference;
    final perChallenger = <Map<String, Object?>>[];

    for (final challenger in challengers) {
      final challengerEngine = registry.modelEngine(challenger);
      final challengerId = challenger['id'] as int;

      final holdoutComparison = split.holdout.isEmpty
          ? null
          : ChampionChallengerComparison.compare(
              market: market,
              leagueId: leagueId,
              scopeSamples: split.holdout,
              championEngine: championEngine,
              challengerEngine: challengerEngine,
              config: config,
            );

      final shadowPair = await _pairedShadowBrierDifferences(
        championModelId: championId,
        challengerModelId: challengerId,
      );

      final combinedDifferences = <double>[
        if (holdoutComparison != null)
          for (var i = 0; i < holdoutComparison.challengerAll.sampleSize; i++)
            holdoutComparison.challengerAll.perSampleBrier[i] -
                holdoutComparison.championAll.perSampleBrier[i],
        ...shadowPair,
      ];

      final uncertainty = Metrics.pairedBootstrap(
        lossDifferences: combinedDifferences,
        resamples: config.bootstrapResamples,
        confidenceLevel: config.bootstrapConfidenceLevel,
        minSampleSize:
            1, // Sample-Gate erfolgt separat gegen minPromotionSample.
      );
      final calibrationGate = _calibrationPromotionGate(holdoutComparison);

      perChallenger.add({
        'challengerModelId': challengerId,
        'readableVersion': challenger['readable_version'],
        'holdoutSample': holdoutComparison?.championAll.sampleSize ?? 0,
        'shadowSample': shadowPair.length,
        'combinedSample': combinedDifferences.length,
        'holdoutChampionBrier': holdoutComparison?.championAll.meanBrier,
        'holdoutChallengerBrier': holdoutComparison?.challengerAll.meanBrier,
        'uncertainty': uncertainty.toJson(),
        'calibrationGate': calibrationGate.toJson(),
      });

      if (bestMeanDifference == null ||
          uncertainty.meanDifference < bestMeanDifference) {
        bestMeanDifference = uncertainty.meanDifference;
        best = {
          'challenger': challenger,
          'combinedSample': combinedDifferences.length,
          'shadowSample': shadowPair.length,
          'uncertainty': uncertainty,
          'holdoutComparison': holdoutComparison,
          'calibrationGate': calibrationGate,
        };
      }
    }

    if (best == null) {
      return _persistReview(
        year: year,
        month: month,
        leagueId: leagueId,
        market: market,
        championModelId: championId,
        challengerModelId: null,
        sameMatchSample: 0,
        metrics: {'candidates': perChallenger},
        uncertainty: const {},
        recommendation: 'KEIN_GEEIGNETER_CHALLENGER',
        reason: 'Keine bewertbaren Challenger gefunden.',
      );
    }

    final bestChallenger = best['challenger'] as Map<String, Object?>;
    final combinedSample = best['combinedSample'] as int;
    final shadowSample = best['shadowSample'] as int;
    final uncertainty = best['uncertainty'] as PairedUncertaintyResult;
    final calibrationGate = best['calibrationGate'] as _CalibrationPromotionGate;

    final String recommendation;
    final String reason;
    if (combinedSample < config.minPromotionSample) {
      recommendation = 'NICHT_GENUG_DATEN';
      reason = 'Sample noch zu klein ($combinedSample von '
          '${config.minPromotionSample} benötigten Out-of-Sample-Matches).';
    } else if (shadowSample < config.minShadowSample) {
      recommendation = 'SHADOW_UNZUREICHEND';
      reason = 'Zu wenige echte Pre-Match-Shadow-Vorhersagen ($shadowSample '
          'von mindestens ${config.minShadowSample}).';
    } else if (!calibrationGate.isEligible) {
      recommendation = 'KALIBRIERUNG_UNZUREICHEND';
      reason = calibrationGate.reason;
    } else {
      switch (uncertainty.status) {
        case ComparisonStatus.challengerClearlyBetter:
          recommendation = 'PROMOTION_EMPFOHLEN';
          reason =
              'Challenger ${bestChallenger['readable_version']} ist statistisch '
              'klar besser (Brier-Differenz ${uncertainty.meanDifference.toStringAsFixed(4)}, '
              '95%-CI [${uncertainty.lowerBound.toStringAsFixed(4)}, '
              '${uncertainty.upperBound.toStringAsFixed(4)}]).';
        case ComparisonStatus.approximatelyEqual:
          recommendation = 'WEITER_TESTEN';
          reason = 'Kein statistisch eindeutiger Unterschied zum Champion.';
        case ComparisonStatus.championBetter:
          recommendation = 'CHALLENGER_SCHLECHTER';
          reason =
              'Champion performt statistisch besser als der beste Challenger.';
        case ComparisonStatus.notEnoughData:
          recommendation = 'NICHT_GENUG_DATEN';
          reason = 'Statistische Unsicherheit zu groß für eine Aussage.';
      }
    }

    final persisted = await _persistReview(
      year: year,
      month: month,
      leagueId: leagueId,
      market: market,
      championModelId: championId,
      challengerModelId: bestChallenger['id'] as int,
      sameMatchSample: combinedSample,
      metrics: {'candidates': perChallenger},
      uncertainty: uncertainty.toJson(),
      recommendation: recommendation,
      reason: reason,
    );

    // Selbstständiges Lernen bedeutet nicht, ungetestete Gewichte zu
    // aktivieren. Nur ein klar besserer Challenger mit ausreichender,
    // out-of-sample belegter Datenmenge darf nach expliziter ENV-Freigabe
    // den Champion ersetzen. Die Promotion ist DB-versioniert und wird von
    // der produktiven Simulation beim nächsten Scan marktweise gelesen.
    if (recommendation == 'PROMOTION_EMPFOHLEN' && config.promotionEnabled) {
      final challengerId = bestChallenger['id'] as int;
      await database.promoteModel(
        newChampionId: challengerId,
        previousChampionId: championId,
      );
      await database.insertModelLabAuditLog(
        action: 'promotion_automatic',
        actor: 'model_lab',
        modelVersionId: challengerId,
        leagueId: leagueId,
        market: market.key,
        details: {
          'reviewId': persisted['id'],
          'combinedSample': combinedSample,
          'meanBrierDifference': uncertainty.meanDifference,
          'confidenceInterval': [
            uncertainty.lowerBound,
            uncertainty.upperBound
          ],
          'calibration': calibrationGate.toJson(),
        },
      );
      return {...persisted, 'promotion': 'completed'};
    }

    return {...persisted, 'promotion': 'not_applied'};
  }

  /// Kalibrierung ist ein eigenständiges Promotion-Gate: Ein Modell mit
  /// zufällig besserem Brier-Wert, aber übertriebenen Wahrscheinlichkeiten,
  /// darf nie Champion werden. Gemessen wird ausschließlich auf dem
  /// chronologisch reservierten Holdout, nie auf Trainings- oder
  /// post-hoc-Shadow-Daten.
  _CalibrationPromotionGate _calibrationPromotionGate(
    ChampionChallengerComparison? comparison,
  ) {
    if (comparison == null) {
      return const _CalibrationPromotionGate.unavailable(
        'Kein chronologischer Holdout für eine Kalibrierungsprüfung.',
      );
    }
    final championBuckets = comparison.championAll.calibration;
    final challengerBuckets = comparison.challengerAll.calibration;
    final championSamples = Metrics.calibrationSampleSize(championBuckets);
    final challengerSamples = Metrics.calibrationSampleSize(challengerBuckets);
    final championEce = Metrics.expectedCalibrationError(championBuckets);
    final challengerEce = Metrics.expectedCalibrationError(challengerBuckets);
    final minSamples = config.minPromotionCalibrationSample;

    if (championEce == null || challengerEce == null) {
      return _CalibrationPromotionGate.unavailable(
        'Zu wenige ausreichend große Kalibrierungs-Buckets im Holdout.',
        championEce: championEce,
        challengerEce: challengerEce,
        championSamples: championSamples,
        challengerSamples: challengerSamples,
      );
    }
    if (championSamples < minSamples || challengerSamples < minSamples) {
      return _CalibrationPromotionGate.unavailable(
        'Kalibrierungsmenge zu klein ($challengerSamples von mindestens '
        '$minSamples benötigten Holdout-Vorhersagen).',
        championEce: championEce,
        challengerEce: challengerEce,
        championSamples: championSamples,
        challengerSamples: challengerSamples,
      );
    }
    if (challengerEce > config.maxPromotionCalibrationError) {
      return _CalibrationPromotionGate.rejected(
        'Challenger-ECE ${challengerEce.toStringAsFixed(3)} liegt über der '
        'Grenze ${config.maxPromotionCalibrationError.toStringAsFixed(3)}.',
        championEce: championEce,
        challengerEce: challengerEce,
        championSamples: championSamples,
        challengerSamples: challengerSamples,
      );
    }
    if (challengerEce >
        championEce + config.maxPromotionCalibrationRegression) {
      return _CalibrationPromotionGate.rejected(
        'Challenger ist schlechter kalibriert als der Champion '
        '(ECE ${challengerEce.toStringAsFixed(3)} vs '
        '${championEce.toStringAsFixed(3)}).',
        championEce: championEce,
        challengerEce: challengerEce,
        championSamples: championSamples,
        challengerSamples: challengerSamples,
      );
    }
    return _CalibrationPromotionGate.eligible(
      championEce: championEce,
      challengerEce: challengerEce,
      championSamples: championSamples,
      challengerSamples: challengerSamples,
    );
  }

  /// Section 51: gepaarte, tatsächlich beobachtete Shadow-Performance -
  /// Brier-Differenzen NUR für Fixtures, für die BEIDE Modelle (Champion UND
  /// Challenger) bereits eine gesettelte Shadow Prediction besitzen.
  Future<List<double>> _pairedShadowBrierDifferences({
    required int championModelId,
    required int challengerModelId,
  }) async {
    final championShadow = await database.settledShadowPredictions(
      modelVersionId: championModelId,
    );
    final challengerShadow = await database.settledShadowPredictions(
      modelVersionId: challengerModelId,
    );

    final championByFixture = {
      for (final row in championShadow) row['fixture_id']?.toString(): row,
    };

    final differences = <double>[];
    for (final row in challengerShadow) {
      final fixtureId = row['fixture_id']?.toString();
      final championRow = championByFixture[fixtureId];
      if (championRow == null) continue;
      final challengerBrier = (row['brier_score'] as num?)?.toDouble();
      final championBrier = (championRow['brier_score'] as num?)?.toDouble();
      if (challengerBrier == null || championBrier == null) continue;
      differences.add(challengerBrier - championBrier);
    }
    return differences;
  }

  Future<Map<String, Object?>> _persistReview({
    required int year,
    required int month,
    required String leagueId,
    required LearningMarket market,
    required int? championModelId,
    required int? challengerModelId,
    required int sameMatchSample,
    required Map<String, Object?> metrics,
    required Map<String, Object?> uncertainty,
    required String recommendation,
    required String reason,
  }) async {
    final id = await database.insertMonthlyReview(
      year: year,
      month: month,
      leagueId: leagueId,
      market: market.key,
      championModelId: championModelId,
      challengerModelId: challengerModelId,
      sameMatchSample: sameMatchSample,
      metrics: metrics,
      uncertainty: uncertainty,
      recommendation: recommendation,
      reason: reason,
    );

    await database.insertModelLabAuditLog(
      action: 'monthly_review_recommendation',
      actor: 'system',
      modelVersionId: challengerModelId,
      leagueId: leagueId,
      market: market.key,
      details: {'recommendation': recommendation, 'reason': reason},
    );

    return {
      'id': id,
      'leagueId': leagueId,
      'market': market.key,
      'recommendation': recommendation,
      'reason': reason,
      'sameMatchSample': sameMatchSample,
    };
  }
}

class _CalibrationPromotionGate {
  const _CalibrationPromotionGate._({
    required this.isEligible,
    required this.reason,
    this.championEce,
    this.challengerEce,
    this.championSamples = 0,
    this.challengerSamples = 0,
  });

  const _CalibrationPromotionGate.unavailable(
    String reason, {
    double? championEce,
    double? challengerEce,
    int championSamples = 0,
    int challengerSamples = 0,
  }) : this._(
          isEligible: false,
          reason: reason,
          championEce: championEce,
          challengerEce: challengerEce,
          championSamples: championSamples,
          challengerSamples: challengerSamples,
        );

  const _CalibrationPromotionGate.rejected(
    String reason, {
    required double championEce,
    required double challengerEce,
    required int championSamples,
    required int challengerSamples,
  }) : this._(
          isEligible: false,
          reason: reason,
          championEce: championEce,
          challengerEce: challengerEce,
          championSamples: championSamples,
          challengerSamples: challengerSamples,
        );

  const _CalibrationPromotionGate.eligible({
    required double championEce,
    required double challengerEce,
    required int championSamples,
    required int challengerSamples,
  }) : this._(
          isEligible: true,
          reason: 'Kalibrierung ausreichend und nicht schlechter als Champion.',
          championEce: championEce,
          challengerEce: challengerEce,
          championSamples: championSamples,
          challengerSamples: challengerSamples,
        );

  final bool isEligible;
  final String reason;
  final double? championEce;
  final double? challengerEce;
  final int championSamples;
  final int challengerSamples;

  Map<String, Object?> toJson() => {
        'eligible': isEligible,
        'reason': reason,
        'championEce': championEce,
        'challengerEce': challengerEce,
        'championSamples': championSamples,
        'challengerSamples': challengerSamples,
      };
}
