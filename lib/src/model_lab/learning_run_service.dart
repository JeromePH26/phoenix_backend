import '../config/model_lab_config.dart';
import '../database/database.dart';
import 'challenger_generator.dart';
import 'learning_dataset_builder.dart';
import 'learning_market.dart';
import 'league_market_status.dart';
import 'model_registry_service.dart';
import 'walk_forward_evaluator.dart';
import 'weight_config.dart';

/// Section 45/46: der wöchentliche (Dienstag) Learning Run. Führt für JEDE
/// aktuell freigegebene Whitelist-Liga x jeden der drei Model-Lab-Märkte die
/// in Section 46 beschriebenen 14 Schritte aus - implementiert als eine
/// gemeinsame Schleife über (Markt, Liga), da die Schritte pro Kombination
/// identisch sind.
///
/// WICHTIG (Section 94): ein Learning Run erzeugt NIEMALS automatisch einen
/// neuen Champion. Es werden ausschließlich neue, unveränderliche Challenger
/// erzeugt und evaluiert. Champion-Wechsel geschehen ausschließlich über den
/// separaten, manuell/serverseitig geschützten Monthly-Review-Promotion-Pfad
/// (`monthly_review_service.dart`), der zusätzlich durch
/// `PHOENIX_MODEL_PROMOTION_ENABLED` blockiert ist.
class LearningRunService {
  LearningRunService({required this.database, required this.config});

  final PhoenixDatabase database;
  final ModelLabConfig config;

  static const String lockName = 'learning_run';

  Future<Map<String, Object?>> run({required String triggerType}) async {
    final locked = await database.acquireModelLabLock(
      lockName,
      staleAfterMinutes: config.staleLockMinutes,
    );
    if (!locked) {
      return {
        'status': 'skipped',
        'reason': 'Ein anderer Learning Run läuft bereits (Lock aktiv).',
      };
    }

    // Section 64/65: falls der Lock gerade per Stale-Reclaim übernommen
    // wurde, hängt evtl. noch ein alter Run auf "running" - sauber als
    // "failed" nachtragen, bevor ein neuer Run beginnt.
    await database.reconcileOrphanedLearningRuns(
      staleAfterMinutes: config.staleLockMinutes,
    );

    final runId = await database.createLearningRun(triggerType: triggerType);
    await database.insertModelLabAuditLog(
      action: 'learning_started',
      actor: triggerType == 'scheduled' ? 'system' : 'admin',
      learningRunId: runId,
      details: {'triggerType': triggerType},
    );

    try {
      final result = await _runSteps(runId);
      await database.completeLearningRun(
        id: runId,
        status: 'completed',
        leaguesProcessed: result.leaguesProcessed,
        marketsProcessed: result.marketsProcessed,
        eligibleMatches: result.eligibleMatches,
        excludedMatches: result.excludedMatches,
        exclusionsByReason: result.exclusionsByReason,
        challengersCreated: result.challengersCreated,
        summary: result.summary,
      );
      await database.insertModelLabAuditLog(
        action: 'learning_completed',
        actor: 'system',
        learningRunId: runId,
        details: result.summary,
      );
      return {'status': 'completed', 'runId': runId, ...result.summary};
    } catch (error, stackTrace) {
      // Section 65: ein fehlgeschlagener Learning Run darf den Champion
      // niemals verändern - hier wurden nie promoteModel/Champion-Updates
      // aufgerufen, nur neue Challenger-Zeilen (additiv, unabhängig vom
      // Champion-Status). Der Fehler wird sauber protokolliert.
      await database.completeLearningRun(
        id: runId,
        status: 'failed',
        leaguesProcessed: 0,
        marketsProcessed: 0,
        eligibleMatches: 0,
        excludedMatches: 0,
        exclusionsByReason: const {},
        challengersCreated: 0,
        errors: [error.toString()],
        summary: {'error': error.toString()},
      );
      await database.insertModelLabAuditLog(
        action: 'learning_failed',
        actor: 'system',
        learningRunId: runId,
        details: {'error': error.toString(), 'stackTrace': stackTrace.toString()},
      );
      return {'status': 'failed', 'runId': runId, 'error': error.toString()};
    } finally {
      await database.releaseModelLabLock(lockName);
    }
  }

  Future<_RunResult> _runSteps(int runId) async {
    final datasetBuilder = LearningDatasetBuilder(
      database: database,
      config: config,
    );
    final registry = ModelRegistryService(database: database, config: config);

    // Schritt 1-4: neue gesettelte Matches finden, Whitelist/Eligibility/
    // Pre-Match-Integrity prüfen (Section 46, Punkte 1-4).
    await database.updateLearningRunStep(id: runId, currentStep: 'auditing_eligibility');
    final audit = await datasetBuilder.auditEligibility();

    await database.updateLearningRunStep(id: runId, currentStep: 'loading_whitelist');
    final leagues = await database.modelLabWhitelistedLeagues();

    var challengersCreated = 0;
    var marketsProcessed = 0;
    final leagueStatusSummary = <Map<String, Object?>>[];

    await database.updateLearningRunStep(
      id: runId,
      currentStep: 'processing_league_markets',
    );

    for (final market in LearningMarket.values) {
      // Schritt 7: Global Champion laden (bzw. anlegen, falls es der allererste
      // Lauf ist).
      await registry.ensureGlobalBaseline(market.key);
      marketsProcessed += 1;

      for (final league in leagues) {
        final leagueId = league['league_id']?.toString();
        if (leagueId == null) continue;

        // Schritt 5/6: Trainingsdatensatz + Liga x Markt-Samples
        // aktualisieren.
        final samples = await datasetBuilder.buildSamples(leagueId: leagueId);

        // Section 21/89: Learning-Flags je Fixture x Markt aktualisieren,
        // damit die Model-Lab-UI exakt nachvollziehen kann, welches Match
        // warum (nicht) eligible war.
        for (final sample in samples) {
          await database.upsertMatchLearningFlag(
            fixtureId: sample.fixtureId,
            leagueId: sample.leagueId,
            market: market.key,
            eligible: true,
            dataQuality: sample.dataQuality,
            snapshotTimestamp: sample.snapshotCreatedAt,
            kickoff: sample.kickoff,
          );
        }

        final eligibleSampleSize = samples.length;

        // Schritt 8: League Champion laden (falls vorhanden).
        final leagueChampion = await registry.currentChampion(
          leagueId: leagueId,
          market: market.key,
        );
        final existingChallengers = await registry.currentChallengers(
          leagueId: leagueId,
          market: market.key,
        );

        final status = classifyLeagueMarketStatus(
          eligibleSampleSize: eligibleSampleSize,
          hasLeagueChampion: leagueChampion != null,
          hasLeagueChallengers: existingChallengers.isNotEmpty,
          hasShadowPredictions: false,
          config: config,
        );

        leagueStatusSummary.add({
          'leagueId': leagueId,
          'market': market.key,
          'eligibleSampleSize': eligibleSampleSize,
          'status': status.label,
        });

        // Section 8/93: unter der Schwelle wird NICHT künstlich trainiert.
        if (status == LeagueMarketStatus.notEnoughData ||
            status == LeagueMarketStatus.globalOnly) {
          continue;
        }

        final split = ChronologicalSplit.split(samples, config);
        if (split.validation.length < config.minValidationSample &&
            split.holdout.length < config.minHoldoutSample) {
          // Genug Samples fürs Grundkriterium, aber die zeitliche Aufteilung
          // liefert noch keine belastbare Validation/Holdout-Menge - lieber
          // in diesem Lauf noch keinen Challenger erzeugen als eine
          // Bewertung auf Mini-Stichproben vorzutäuschen.
          continue;
        }

        // Schritt 9: neue immutable Challenger erzeugen (Schritt 10: Walk-
        // Forward Evaluation, Schritt 11: Holdout aktualisieren).
        final generation = await registry.nextGeneration(
          leagueId: leagueId,
          market: market.key,
        );
        final baselineModel =
            leagueChampion ?? await database.globalBaselineModel(market.key);
        if (baselineModel == null) continue;
        final championWeights = registry.weightsFromModel(baselineModel);
        final championId = baselineModel['id'] as int;

        final grid = ChallengerGenerator.candidateAttackWeights(config);
        for (var i = 0; i < grid.length; i++) {
          final challengerIndex = await registry.nextChallengerIndex(
            leagueId: leagueId,
            market: market.key,
            generation: generation,
          );
          final created = await registry.createOrReuseChallenger(
            leagueId: leagueId,
            market: market.key,
            generation: generation,
            challengerIndex: challengerIndex,
            rawWeights: EngineWeightConfig(attackWeight: grid[i]),
            sampleSize: eligibleSampleSize,
            parentModelId: championId,
            trainingStart:
                split.training.isEmpty ? null : split.training.first.kickoff,
            trainingEnd:
                split.training.isEmpty ? null : split.training.last.kickoff,
            trainingCount: split.training.length,
            validationCount: split.validation.length,
            holdoutCount: split.holdout.length,
          );
          challengersCreated += 1;

          await database.addLearningCandidate(
            learningRunId: runId,
            modelVersionId: created.id,
            leagueId: leagueId,
            market: market.key,
          );

          // Schritt 10/11/12: Walk-Forward-Evaluation auf Validation UND
          // Holdout, Metriken speichern (paired, Section 42/43).
          if (split.validation.isNotEmpty) {
            await _persistComparison(
              comparison: ChampionChallengerComparison.compare(
                market: market,
                leagueId: leagueId,
                scopeSamples: split.validation,
                championWeights: championWeights,
                challengerWeights: created.weights,
                config: config,
              ),
              evaluationType: 'walk_forward',
              championModelId: championId,
              challengerModelId: created.id,
            );
          }
          if (split.holdout.isNotEmpty) {
            await _persistComparison(
              comparison: ChampionChallengerComparison.compare(
                market: market,
                leagueId: leagueId,
                scopeSamples: split.holdout,
                championWeights: championWeights,
                challengerWeights: created.weights,
                config: config,
              ),
              evaluationType: 'holdout',
              championModelId: championId,
              challengerModelId: created.id,
            );
          }
        }
      }
    }

    return _RunResult(
      leaguesProcessed: leagues.length,
      marketsProcessed: marketsProcessed,
      eligibleMatches: audit.eligible,
      excludedMatches: audit.notEligible,
      exclusionsByReason: audit.exclusionsByReason,
      challengersCreated: challengersCreated,
      summary: {
        'eligibleMatches': audit.eligible,
        'excludedMatches': audit.notEligible,
        'challengersCreated': challengersCreated,
        'leagueMarketStatuses': leagueStatusSummary,
      },
    );
  }

  Future<void> _persistComparison({
    required ChampionChallengerComparison comparison,
    required String evaluationType,
    required int championModelId,
    required int challengerModelId,
  }) async {
    final uncertainty = comparison.brierUncertainty.toJson();

    Future<void> insertSide({
      required int modelId,
      required int comparedAgainstId,
      required MarketEvaluationResult all,
      required MarketEvaluationResult clean,
    }) async {
      await database.insertModelEvaluation(
        modelVersionId: modelId,
        comparedAgainstModelId: comparedAgainstId,
        leagueId: comparison.leagueId,
        market: comparison.market.key,
        evaluationType: evaluationType,
        matchScope: 'all',
        sampleSize: all.sampleSize,
        brierScore: all.meanBrier,
        logLoss: all.meanLogLoss,
        calibration: all.calibration.map((c) => c.toJson()).toList(),
        accuracy: all.accuracy,
        avgProbability: all.avgTopProbability,
        uncertainty: uncertainty,
      );
      await database.insertModelEvaluation(
        modelVersionId: modelId,
        comparedAgainstModelId: comparedAgainstId,
        leagueId: comparison.leagueId,
        market: comparison.market.key,
        evaluationType: evaluationType,
        matchScope: 'clean',
        sampleSize: clean.sampleSize,
        brierScore: clean.sampleSize == 0 ? null : clean.meanBrier,
        logLoss: clean.sampleSize == 0 ? null : clean.meanLogLoss,
        calibration: clean.calibration.map((c) => c.toJson()).toList(),
        accuracy: clean.sampleSize == 0 ? null : clean.accuracy,
        avgProbability: clean.sampleSize == 0 ? null : clean.avgTopProbability,
        uncertainty: uncertainty,
      );
    }

    await insertSide(
      modelId: championModelId,
      comparedAgainstId: challengerModelId,
      all: comparison.championAll,
      clean: comparison.championClean,
    );
    await insertSide(
      modelId: challengerModelId,
      comparedAgainstId: championModelId,
      all: comparison.challengerAll,
      clean: comparison.challengerClean,
    );
  }
}

class _RunResult {
  const _RunResult({
    required this.leaguesProcessed,
    required this.marketsProcessed,
    required this.eligibleMatches,
    required this.excludedMatches,
    required this.exclusionsByReason,
    required this.challengersCreated,
    required this.summary,
  });

  final int leaguesProcessed;
  final int marketsProcessed;
  final int eligibleMatches;
  final int excludedMatches;
  final Map<String, Object?> exclusionsByReason;
  final int challengersCreated;
  final Map<String, Object?> summary;
}
