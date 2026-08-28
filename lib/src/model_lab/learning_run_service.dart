import '../config/model_lab_config.dart';
import '../database/database.dart';
import 'challenger_generator.dart';
import 'dixon_coles_engine.dart';
import 'elo_prior.dart';
import 'engine_replica.dart';
import 'global_goals_v1_engine.dart';
import 'global_market_engine.dart';
import 'learning_dataset_builder.dart';
import 'learning_market.dart';
import 'learning_sample.dart';
import 'league_market_status.dart';
import 'model_registry_service.dart';
import 'team_strength_engine.dart';
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

  /// Eigene, kleinere Mindest-Stichprobe für Dixon-Coles/Team-Stärke-
  /// Challenger. `config.minValidationSample`/`minHoldoutSample` (Default 40)
  /// sind für die ÄLTEREN, global gepoolten Engines kalibriert - Dixon-Coles
  /// und Team-Stärke rechnen bewusst PRO LIGA (Kern des Engine-Umbaus, Plan
  /// "wild-cuddling-hoare"), wo 40 Holdout-Spiele praktisch unerreichbar sind
  /// (live beobachtet: selbst die datenreichste Liga im Backtest hatte nur 27
  /// Holdout-Spiele, `bin/phoenix_team_strength_decay_search.dart`). Ohne
  /// diese eigene Schwelle wird für diese beiden Engines NIE ein Challenger
  /// angelegt - bestätigt durch drei aufeinanderfolgende Learning Runs mit
  /// `challengers_created: 0`. Identisch zur bereits live validierten
  /// Backtest-Schwelle. Betrifft NUR die Challenger-ERSTELLUNG - die
  /// unveränderte, deutlich höhere `minPromotionSample` (Default 120)
  /// entscheidet weiterhin allein über eine tatsächliche Beförderung.
  static const int perLeagueEngineMinSample = 5;

  Future<Map<String, Object?>> run({required String triggerType}) async {
    // Die eine globale Referenz wird vor dem Lock sichergestellt. Sie ist
    // idempotent und verändert weder eine Produktionsanalyse noch historische
    // marktweise Modelle; neue Runs erzeugen ausschließlich vollständige
    // Liga-Engines gegen diese Referenz.
    final baselineRegistry = ModelRegistryService(
      database: database,
      config: config,
    );
    await baselineRegistry.ensureGlobalMatchDistributionBaseline();

    var locked = await database.acquireModelLabLock(
      lockName,
      staleAfterMinutes: config.staleLockMinutes,
    );
    // Ein alter Prozess kann durch Deploy/Crash verschwinden, ohne seinen
    // Datenbank-Lock zu entfernen. Vor einem vorschnellen "skipped" wird
    // deshalb genau einmal die sichere Orphan-Reconciliation versucht und
    // der Lock erneut erworben. Ein frischer Run bleibt dabei unberührt.
    if (!locked) {
      await database.recoverOrphanedLearningRunAndLock(
        staleAfterMinutes: config.staleLockMinutes,
      );
      locked = await database.acquireModelLabLock(
        lockName,
        staleAfterMinutes: config.staleLockMinutes,
      );
    }
    if (!locked) {
      return {
        'status': 'skipped',
        'reason': 'Ein anderer Learning Run läuft bereits (Lock aktiv).',
      };
    }

    // Der Lock ist jetzt exklusiv unser - jede Zeile, die trotzdem noch als
    // "running" markiert ist, MUSS von einem toten Vorgänger stammen
    // (unabhängig von ihrem Alter, siehe Doku an
    // `reconcileOrphanedLearningRuns`). Sauber als "failed" nachtragen,
    // bevor ein neuer Run beginnt. Der Rückgabewert trägt den letzten
    // Fortschritt des verwaisten Laufs (siehe `_resumeStateFrom`), damit ein
    // neuer Run bei vielen Liga×Markt-Paaren nicht bei jedem Redeploy wieder
    // bei Null anfängt.
    final orphanedRuns = await database.reconcileOrphanedLearningRuns();
    final resumeState = _resumeStateFrom(orphanedRuns);

    final runId = await database.createLearningRun(triggerType: triggerType);
    await database.insertModelLabAuditLog(
      action: 'learning_started',
      actor: triggerType == 'scheduled' ? 'system' : 'admin',
      learningRunId: runId,
      details: {
        'triggerType': triggerType,
        if (resumeState != null)
          'resumedFrom': {
            'market': resumeState.marketKey,
            'leagueId': resumeState.leagueId,
            'carriedOverChallengersCreated':
                resumeState.challengersCreatedCarriedOver,
          },
      },
    );

    try {
      final result = await _runSteps(runId, resumeState);
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
        details: {
          'error': error.toString(),
          'stackTrace': stackTrace.toString()
        },
      );
      return {'status': 'failed', 'runId': runId, 'error': error.toString()};
    } finally {
      await database.releaseModelLabLock(lockName);
    }
  }

  /// Section 65 Fortsetzung: liest aus den soeben als "failed" nachgetragenen
  /// verwaisten Läufen (siehe [PhoenixDatabase.reconcileOrphanedLearningRuns])
  /// heraus, wie weit der letzte Versuch tatsächlich gekommen war. Es kann
  /// wegen des Advisory-Locks nie mehr als einen echten "running"-Lauf
  /// gleichzeitig geben, daher genügt der erste Treffer.
  _ResumeState? _resumeStateFrom(List<Map<String, Object?>> orphanedRuns) {
    if (orphanedRuns.isEmpty) return null;
    final summary = orphanedRuns.first['summary'];
    if (summary is! Map || summary['phase'] != 'processing_league_markets') {
      // Der alte Lauf ist vor Erreichen der Liga×Markt-Schleife gestorben
      // (z.B. noch beim Laden der Trainingsdaten) - dort gibt es nichts
      // Sinnvolles zum Fortsetzen, ein normaler Neustart ist am saubersten.
      return null;
    }
    final marketKey = summary['currentMarket']?.toString();
    final leagueId = summary['currentLeagueId']?.toString();
    if (marketKey == null || leagueId == null) return null;
    return _ResumeState(
      marketKey: marketKey,
      leagueId: leagueId,
      challengersCreatedCarriedOver:
          orphanedRuns.first['challengers_created'] as int? ?? 0,
    );
  }

  /// Der produktive Lernpfad: ein globales Referenzmodell, ein vollständiger
  /// Challenger pro Liga. Alle Marktmetriken werden zwar einzeln gespeichert,
  /// aber beide Seiten liefern immer dieselbe zugrunde liegende
  /// Torverteilung.
  Future<_RunResult> _runSteps(int runId, _ResumeState? resumeState) async {
    final datasetBuilder = LearningDatasetBuilder(
      database: database,
      config: config,
    );
    final registry = ModelRegistryService(database: database, config: config);

    await database.updateLearningRunStep(
      id: runId,
      currentStep: 'classifying_dataset',
    );
    await datasetBuilder.classifyLiveDataset(write: true);

    await database.updateLearningRunStep(
      id: runId,
      currentStep: 'auditing_eligibility',
    );
    final audit = await datasetBuilder.auditEligibility();
    final leagues = await database.modelLabWhitelistedLeagues();
    final samplesByLeague = await datasetBuilder.buildSamplesByLeague();

    final globalModelId =
        await registry.ensureGlobalMatchDistributionBaseline();
    final globalModel = await database.modelVersion(globalModelId);
    if (globalModel == null) {
      throw StateError('Globale PHÖNIX-Engine konnte nicht geladen werden.');
    }
    final globalEngine = registry.modelEngine(globalModel);

    final trainingDataByLeague =
        <String, ({List<MatchResult> matches, DateTime asOf})?>{};
    final fitByLeague = <String, TeamStrengthFit?>{};
    final globalEloPriorCache = <DateTime, EloPrior>{};
    final leaguePriorCache =
        <String, Map<String, ({double attack, double defense})>>{};
    final statuses = <Map<String, Object?>>[];
    var challengersCreated = 0;
    var processed = 0;

    await database.updateLearningRunProgress(
      id: runId,
      currentStep: 'processing_league_engines',
      leaguesProcessed: 0,
      marketsProcessed: 0,
      eligibleMatches: audit.eligible,
      excludedMatches: audit.notEligible,
      challengersCreated: 0,
      summary: {
        'phase': 'processing_league_engines',
        'architecture': 'one_global_engine_vs_one_league_engine',
        'leagueCount': leagues.length,
        if (resumeState != null) 'restartedAfterRun': resumeState.marketKey,
      },
    );

    for (final league in leagues) {
      final leagueId = league['league_id']?.toString();
      if (leagueId == null) continue;
      final samples = samplesByLeague[leagueId] ?? const <LearningSample>[];

      // Die Nachvollziehbarkeit bleibt je Markt erhalten, die Kandidaten-
      // Engine selbst wird jedoch nur ein einziges Mal je Liga erzeugt.
      for (final sample in samples) {
        for (final market in LearningMarket.values) {
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
      }

      final split = ChronologicalSplit.split(samples, config);
      final comparableValidation = split.validation
          .where((sample) => sample.hasGlobalGoalsV1Data)
          .toList(growable: false);
      final comparableHoldout = split.holdout
          .where((sample) => sample.hasGlobalGoalsV1Data)
          .toList(growable: false);
      final enoughEvidence =
          comparableValidation.length >= perLeagueEngineMinSample ||
              comparableHoldout.length >= perLeagueEngineMinSample;

      if (!enoughEvidence) {
        statuses.add({
          'leagueId': leagueId,
          'leagueName': league['league_name'],
          'status': 'global_only',
          'eligibleSampleSize': samples.length,
          'reason': 'Noch zu wenige leakage-sichere Vorab-Snapshots.',
        });
      } else {
        final fit = await _teamStrengthFitFor(
          leagueId: leagueId,
          split: split,
          halfLifeDays: 30.0,
          trainingDataCache: trainingDataByLeague,
          fitCache: fitByLeague,
          globalEloPriorCache: globalEloPriorCache,
          leaguePriorCache: leaguePriorCache,
        );
        if (fit == null || !fit.converged) {
          statuses.add({
            'leagueId': leagueId,
            'leagueName': league['league_name'],
            'status': 'global_only',
            'eligibleSampleSize': samples.length,
            'reason':
                'Liga-Teamstärke konnte noch nicht stabil gefittet werden.',
          });
        } else {
          final generation = await registry.nextGeneration(
            leagueId: leagueId,
            market: ModelRegistryService.matchDistributionMarket,
          );
          final challengerIndex = await registry.nextChallengerIndex(
            leagueId: leagueId,
            market: ModelRegistryService.matchDistributionMarket,
            generation: generation,
          );
          final challenger = await registry.createOrReuseLeagueEngineChallenger(
            leagueId: leagueId,
            fit: fit,
            halfLifeDays: 30.0,
            generation: generation,
            challengerIndex: challengerIndex,
            sampleSize: samples.length,
            parentModelId: globalModelId,
            trainingStart:
                split.training.isEmpty ? null : split.training.first.kickoff,
            trainingEnd:
                split.training.isEmpty ? null : split.training.last.kickoff,
            trainingCount: split.training.length,
            validationCount: comparableValidation.length,
            holdoutCount: comparableHoldout.length,
          );
          challengersCreated += 1;
          await database.addLearningCandidate(
            learningRunId: runId,
            modelVersionId: challenger.id,
            leagueId: leagueId,
            market: ModelRegistryService.matchDistributionMarket,
          );

          // Ein und derselbe Challenger muss sich in ALLEN öffentlichen
          // Märkten bewähren. Keine Einzelmarkt-Promotion ist mehr möglich.
          for (final market in LearningMarket.values) {
            if (comparableValidation.isNotEmpty) {
              await _persistComparison(
                comparison: ChampionChallengerComparison.compare(
                  market: market,
                  leagueId: leagueId,
                  scopeSamples: comparableValidation,
                  championEngine: globalEngine,
                  challengerEngine: challenger.engine,
                  config: config,
                ),
                evaluationType: 'walk_forward',
                championModelId: globalModelId,
                challengerModelId: challenger.id,
              );
            }
            if (comparableHoldout.isNotEmpty) {
              await _persistComparison(
                comparison: ChampionChallengerComparison.compare(
                  market: market,
                  leagueId: leagueId,
                  scopeSamples: comparableHoldout,
                  championEngine: globalEngine,
                  challengerEngine: challenger.engine,
                  config: config,
                ),
                evaluationType: 'holdout',
                championModelId: globalModelId,
                challengerModelId: challenger.id,
              );
            }
          }
          statuses.add({
            'leagueId': leagueId,
            'leagueName': league['league_name'],
            'status': 'challenger_shadow',
            'eligibleSampleSize': samples.length,
            'validationSampleSize': comparableValidation.length,
            'holdoutSampleSize': comparableHoldout.length,
            'challengerModelId': challenger.id,
          });
        }
      }

      processed += 1;
      await database.updateLearningRunProgress(
        id: runId,
        currentStep: 'processing_league_engines',
        leaguesProcessed: processed,
        marketsProcessed: LearningMarket.values.length,
        eligibleMatches: audit.eligible,
        excludedMatches: audit.notEligible,
        challengersCreated: challengersCreated,
        summary: {
          'phase': 'processing_league_engines',
          'architecture': 'one_global_engine_vs_one_league_engine',
          'currentLeagueId': leagueId,
          'currentLeagueName': league['league_name'],
          'leaguesProcessed': processed,
          'leagueCount': leagues.length,
        },
      );
    }

    return _RunResult(
      leaguesProcessed: processed,
      marketsProcessed: LearningMarket.values.length,
      eligibleMatches: audit.eligible,
      excludedMatches: audit.notEligible,
      exclusionsByReason: audit.exclusionsByReason,
      challengersCreated: challengersCreated,
      summary: {
        'architecture': 'one_global_engine_vs_one_league_engine',
        'globalModelId': globalModelId,
        'eligibleMatches': audit.eligible,
        'excludedMatches': audit.notEligible,
        'challengersCreated': challengersCreated,
        'leagueEngineStatuses': statuses,
      },
    );
  }

  /// Historischer Markt-für-Markt-Pfad. Er bleibt ausschließlich für
  /// bestehende Auswertungen lesbar; neue Learning Runs benutzen
  /// [_runSteps] und erzeugen komplette Liga-Engines.
  Future<_RunResult> runLegacyMarketStepsForMigration(
    int runId,
    _ResumeState? resumeState,
  ) async {
    final datasetBuilder = LearningDatasetBuilder(
      database: database,
      config: config,
    );
    final registry = ModelRegistryService(database: database, config: config);

    // M2 (AN2 §24-32): Learning Dataset Pipeline aktualisieren, BEVOR
    // irgendetwas Samples liest - `buildSamples*` filtert anschließend über
    // `phoenix_learning_dataset.data_class`.
    await database.updateLearningRunStep(
        id: runId, currentStep: 'classifying_dataset');
    await datasetBuilder.classifyLiveDataset(write: true);

    // Schritt 1-4: neue gesettelte Matches finden, Whitelist/Eligibility/
    // Pre-Match-Integrity prüfen (Section 46, Punkte 1-4).
    await database.updateLearningRunStep(
        id: runId, currentStep: 'auditing_eligibility');
    final audit = await datasetBuilder.auditEligibility();

    await database.updateLearningRunStep(
        id: runId, currentStep: 'loading_whitelist');
    final leagues = await database.modelLabWhitelistedLeagues();

    // Alle Märkte eines Fixtures verwenden denselben Pre-Match-Snapshot.
    // Der Batch verhindert damit 17 identische Datenbank-Abfragen pro
    // Liga und macht die Lernläufe auch bei vielen historischen Spielen
    // zuverlässig innerhalb eines Worker-Zyklus fertig.
    await database.updateLearningRunProgress(
      id: runId,
      currentStep: 'loading_training_data',
      leaguesProcessed: 0,
      marketsProcessed: 0,
      eligibleMatches: audit.eligible,
      excludedMatches: audit.notEligible,
      challengersCreated: 0,
      summary: {
        'phase': 'loading_training_data',
        'leagueCount': leagues.length,
      },
    );
    final samplesByLeague = await datasetBuilder.buildSamplesByLeague();

    var challengersCreated = resumeState?.challengersCreatedCarriedOver ?? 0;
    var marketsProcessed = 0;
    var leagueMarketPairsProcessed = 0;
    final processedLeagueIds = <String>{};
    final leagueStatusSummary = <Map<String, Object?>>[];

    // PHÖNIX Engine-Umbau Phase 2/3 (Plan "wild-cuddling-hoare"): anders als
    // die übrigen Engine-Kinds wird `TeamStrengthFit` NICHT pro Sample
    // abgeleitet, sondern EINMAL pro Liga (und pro getesteter Halbwertszeit,
    // Phase 3) aus der gesamten Trainingshistorie gefittet (IPF, siehe
    // `TeamStrengthEngine.fit`) und dann über alle 3 Märkte hinweg
    // wiederverwendet - market ist die äußere, league die innere Schleife
    // unten, Caches verhindern also ein erneutes Laden/Fitten derselben
    // Liga bei jedem Markt-Durchlauf. `null` bedeutet: für diese Liga wurde
    // bereits versucht zu fitten, aber zu wenig Historie vorhanden (Cache
    // verhindert wiederholte erfolglose Versuche).
    final teamStrengthTrainingDataByLeague =
        <String, ({List<MatchResult> matches, DateTime asOf})?>{};
    final teamStrengthFitsByLeagueAndHalfLife = <String, TeamStrengthFit?>{};
    final teamStrengthGlobalEloPriorCache = <DateTime, EloPrior>{};
    final teamStrengthLeaguePriorCache =
        <String, Map<String, ({double attack, double defense})>>{};
    // Nutzerkorrektur (2026-08-27): analoge Caches für den gepoolten
    // GLOBALEN Team-Stärke-Fit (siehe _ensurePooledTeamStrengthChallenger) -
    // einmal pro Halbwertszeit für den GANZEN Lauf, nicht pro Liga.
    final pooledTeamStrengthTrainingDataCache = <String, Object?>{};
    final pooledTeamStrengthFitCache = <double?, TeamStrengthFit?>{};
    // Live gegen PHÖNIX-Daten getestet (Halbwertszeit-Grid-Search, 9
    // Ligen/98 Holdout-Spiele): klarer, monotoner - aber kleiner - Trend
    // Richtung "kürzere Halbwertszeit ist etwas besser" (30 Tage: Ø Brier
    // -0,4% ggü. keinem Verfall). Zu klein/zu wenig Daten für eine feste
    // Entscheidung direkt in Produktion - deshalb hier als zweiter,
    // benannter Challenger neben dem Kontrollwert (kein Verfall) getestet,
    // über die richtige Walk-Forward/Paired-Bootstrap-Auswertung statt aus
    // einem einzelnen Backtest übernommen.
    const teamStrengthHalfLifeCandidates = <double?>[null, 30.0];

    // Section 65 Fortsetzung: Position, an der der letzte (verwaiste)
    // Versuch unterbrochen wurde. Vollständig abgeschlossene Märkte
    // (marketIndex < resumeMarketIndex) werden komplett übersprungen; im
    // Markt, in dem der Abbruch passierte, werden alle Ligen bis
    // einschließlich der zuletzt bearbeiteten übersprungen - deren
    // Challenger existieren entweder schon (config_hash verhindert
    // Duplikate ohnehin) oder werden bewusst ausgelassen statt riskiert,
    // ihre Evaluationszeilen durch ein erneutes Durchlaufen zu duplizieren.
    // Fehlt die Liga im aktuellen Whitelist-Snapshot (z.B. inzwischen
    // entfernt), greift kein Skip und der Markt läuft komplett neu - sicher,
    // nur etwas langsamer.
    final resumeMarket = resumeState != null
        ? LearningMarket.fromKey(resumeState.marketKey)
        : null;
    final resumeMarketIndex =
        resumeMarket != null ? LearningMarket.values.indexOf(resumeMarket) : -1;
    final resumeLeagueIndex = resumeMarket != null
        ? leagues.indexWhere(
            (l) => l['league_id']?.toString() == resumeState!.leagueId,
          )
        : -1;

    await database.updateLearningRunStep(
      id: runId,
      currentStep: 'processing_league_markets',
    );

    for (var marketIndex = 0;
        marketIndex < LearningMarket.values.length;
        marketIndex++) {
      final market = LearningMarket.values[marketIndex];
      // Schritt 7: Global Champion laden (bzw. anlegen, falls es der allererste
      // Lauf ist).
      await registry.ensureGlobalBaseline(market.key);
      marketsProcessed += 1;

      // Über alle Ligen gepoolter GLOBAL_GOALS_V1-Kandidat für diesen Markt
      // (Liga-Feld = null, genau wie bei der globalen Baseline selbst).
      // Läuft VOR dem Resume-Skip unten und unabhängig von der Liga-Schleife,
      // weil er nicht auf eine einzelne Liga wartet: die meisten Ligen
      // sammeln einzeln viel zu wenige Spiele, um je die 40er-Schwelle zu
      // erreichen (im Schnitt 5-6 Spiele je Liga) - über alle Ligen zusammen
      // ist die Stichprobe sofort/viel früher groß genug für eine echte
      // Aussage: lohnt sich das reichere Modell für diesen Markt überhaupt.
      // Idempotent wie jeder andere Challenger (config_hash) - ein erneuter
      // Aufruf für einen bereits erzeugten Kandidaten ist ein billiger
      // No-op, deshalb bewusst auch bei jedem (auch fortgesetzten) Run-Versuch
      // erneut angestoßen statt in die Resume-Logik verwoben zu werden.
      challengersCreated += await _ensurePooledGlobalGoalsV1Challenger(
        market: market,
        leagues: leagues,
        samplesByLeague: samplesByLeague,
        registry: registry,
        runId: runId,
      );
      challengersCreated += await _ensurePooledGlobalMarketChallengers(
        market: market,
        leagues: leagues,
        samplesByLeague: samplesByLeague,
        registry: registry,
        runId: runId,
      );
      challengersCreated += await _ensurePooledDixonColesChallengers(
        market: market,
        leagues: leagues,
        samplesByLeague: samplesByLeague,
        registry: registry,
        runId: runId,
      );
      challengersCreated += await _ensurePooledTeamStrengthChallenger(
        market: market,
        leagues: leagues,
        samplesByLeague: samplesByLeague,
        registry: registry,
        runId: runId,
        fitCache: pooledTeamStrengthFitCache,
        trainingDataCache: pooledTeamStrengthTrainingDataCache,
        halfLifeCandidates: teamStrengthHalfLifeCandidates,
      );

      if (resumeMarketIndex >= 0 && marketIndex < resumeMarketIndex) {
        for (final league in leagues) {
          final leagueId = league['league_id']?.toString();
          if (leagueId != null) processedLeagueIds.add(leagueId);
        }
        leagueMarketPairsProcessed += leagues.length;
        continue;
      }

      for (var leagueIndex = 0; leagueIndex < leagues.length; leagueIndex++) {
        final league = leagues[leagueIndex];
        final leagueId = league['league_id']?.toString();
        if (leagueId == null) continue;

        if (marketIndex == resumeMarketIndex &&
            resumeLeagueIndex >= 0 &&
            leagueIndex <= resumeLeagueIndex) {
          processedLeagueIds.add(leagueId);
          leagueMarketPairsProcessed += 1;
          continue;
        }

        try {
          // Schritt 5/6: Trainingsdatensatz + Liga x Markt-Samples
          // aktualisieren.
          final samples = samplesByLeague[leagueId] ?? const [];

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
          final baselineModel = leagueChampion ??
              await database.championModel(
                  leagueId: null, market: market.key) ??
              await database.globalBaselineModel(market.key);
          if (baselineModel == null) continue;
          // Seit `activateGlobalMarketChampion` (Claude AN2.txt Section 59)
          // ist der globale Champion nicht mehr zwingend attackWeight-basiert
          // - `modelEngine()` erkennt die tatsächlich verwendete Formel.
          final championEngine = registry.modelEngine(baselineModel);
          final championId = baselineModel['id'] as int;

          // Section GLOBAL_GOALS_V1: zusätzlich zum attackWeight-Gitter EIN
          // deterministischer Challenger mit dem sechs-Feature-gewichteten
          // GLOBAL_GOALS_V1-Modell (siehe `GlobalGoalsV1Engine`) - kein
          // Suchraum nötig, da es keinen freien Parameter hat. Läuft VOR dem
          // `remainingSlots`-Check unten, weil er ein eigenes, unabhängiges
          // Budget hat (immer genau 1 pro Liga x Markt, nie mehr) und sonst
          // nie erzeugt würde, sobald das attackWeight-Gitter bereits voll
          // ist. Entsteht erst, sobald genug historische Fixtures dieser Liga
          // einen Phase-2-Scan VOR ihrem Kickoff haben - das läuft erst seit
          // Kurzem und nur budgetiert für Beobachtungsligen, ist also anfangs
          // oft noch leer.
          final ggv1Validation =
              split.validation.where((s) => s.hasGlobalGoalsV1Data).toList();
          final ggv1Holdout =
              split.holdout.where((s) => s.hasGlobalGoalsV1Data).toList();
          final hasGlobalGoalsV1Challenger = existingChallengers.any(
            (c) =>
                (c['weights'] as Map?)?['engineVersion'] ==
                GlobalGoalsV1Engine.version,
          );
          if (!hasGlobalGoalsV1Challenger &&
              (ggv1Validation.length >= config.minValidationSample ||
                  ggv1Holdout.length >= config.minHoldoutSample)) {
            final ggv1ChallengerIndex = await registry.nextChallengerIndex(
              leagueId: leagueId,
              market: market.key,
              generation: generation,
            );
            final ggv1Challenger =
                await registry.createOrReuseGlobalGoalsV1Challenger(
              leagueId: leagueId,
              market: market.key,
              generation: generation,
              challengerIndex: ggv1ChallengerIndex,
              sampleSize: eligibleSampleSize,
              parentModelId: championId,
              trainingStart:
                  split.training.isEmpty ? null : split.training.first.kickoff,
              trainingEnd:
                  split.training.isEmpty ? null : split.training.last.kickoff,
              trainingCount: split.training.length,
              validationCount: ggv1Validation.length,
              holdoutCount: ggv1Holdout.length,
            );
            challengersCreated += 1;

            await database.addLearningCandidate(
              learningRunId: runId,
              modelVersionId: ggv1Challenger.id,
              leagueId: leagueId,
              market: market.key,
            );

            if (ggv1Validation.isNotEmpty) {
              await _persistComparison(
                comparison: ChampionChallengerComparison.compare(
                  market: market,
                  leagueId: leagueId,
                  scopeSamples: ggv1Validation,
                  championEngine: championEngine,
                  challengerEngine: ggv1Challenger.engine,
                  config: config,
                ),
                evaluationType: 'walk_forward',
                championModelId: championId,
                challengerModelId: ggv1Challenger.id,
              );
            }
            if (ggv1Holdout.isNotEmpty) {
              await _persistComparison(
                comparison: ChampionChallengerComparison.compare(
                  market: market,
                  leagueId: leagueId,
                  scopeSamples: ggv1Holdout,
                  championEngine: championEngine,
                  challengerEngine: ggv1Challenger.engine,
                  config: config,
                ),
                evaluationType: 'holdout',
                championModelId: championId,
                challengerModelId: ggv1Challenger.id,
              );
            }
          }

          // Section 10-12 (Claude AN2.txt): mindestens 4 benannte,
          // nachvollziehbare Challenger-Hypothesen je Marktfamilie statt
          // eines blinden Zahlengitters (siehe `GlobalMarketHypothesis`).
          // Gleiches Muster wie der GLOBAL_GOALS_V1-Block oben: eigenes,
          // unabhängiges Budget (max. 4 pro Liga x Markt, eine je Hypothese),
          // läuft unabhängig vom attackWeight-Gitter-Budget unten.
          final globalMarketValidation =
              split.validation.where((s) => s.hasGlobalMarketData).toList();
          final globalMarketHoldout =
              split.holdout.where((s) => s.hasGlobalMarketData).toList();
          if (globalMarketValidation.length >= config.minValidationSample ||
              globalMarketHoldout.length >= config.minHoldoutSample) {
            final existingHypotheses = existingChallengers
                .map((c) => (c['weights'] as Map?)?['hypothesis']?.toString())
                .whereType<String>()
                .toSet();
            for (final hypothesis in GlobalMarketHypothesis.values) {
              if (existingHypotheses.contains(hypothesis.key)) continue;
              final challengerIndex = await registry.nextChallengerIndex(
                leagueId: leagueId,
                market: market.key,
                generation: generation,
              );
              final challenger =
                  await registry.createOrReuseGlobalMarketChallenger(
                leagueId: leagueId,
                market: market,
                hypothesis: hypothesis,
                generation: generation,
                challengerIndex: challengerIndex,
                sampleSize: eligibleSampleSize,
                parentModelId: championId,
                trainingStart: split.training.isEmpty
                    ? null
                    : split.training.first.kickoff,
                trainingEnd:
                    split.training.isEmpty ? null : split.training.last.kickoff,
                trainingCount: split.training.length,
                validationCount: globalMarketValidation.length,
                holdoutCount: globalMarketHoldout.length,
              );
              challengersCreated += 1;

              await database.addLearningCandidate(
                learningRunId: runId,
                modelVersionId: challenger.id,
                leagueId: leagueId,
                market: market.key,
              );

              if (globalMarketValidation.isNotEmpty) {
                await _persistComparison(
                  comparison: ChampionChallengerComparison.compare(
                    market: market,
                    leagueId: leagueId,
                    scopeSamples: globalMarketValidation,
                    championEngine: championEngine,
                    challengerEngine: challenger.engine,
                    config: config,
                  ),
                  evaluationType: 'walk_forward',
                  championModelId: championId,
                  challengerModelId: challenger.id,
                );
              }
              if (globalMarketHoldout.isNotEmpty) {
                await _persistComparison(
                  comparison: ChampionChallengerComparison.compare(
                    market: market,
                    leagueId: leagueId,
                    scopeSamples: globalMarketHoldout,
                    championEngine: championEngine,
                    challengerEngine: challenger.engine,
                    config: config,
                  ),
                  evaluationType: 'holdout',
                  championModelId: championId,
                  challengerModelId: challenger.id,
                );
              }
            }
          }

          // PHÖNIX Engine-Umbau Phase 1 Spur A (Plan "wild-cuddling-hoare",
          // 2026-08-26): Dixon-Coles-Korrelationsausgleich als eigene,
          // benannte Challenger-Hypothesen (Section 4/10-12, Claude AN2.txt).
          // Nutzt dieselben, immer verfügbaren attackWeightBlend-Features wie
          // das attackWeight-Gitter unten - eigenes, unabhängiges Budget (max.
          // `DixonColesEngine.rhoCandidates.length` pro Liga x Markt), läuft
          // unabhängig vom attackWeight-Gitter-Budget unten. Bleibt reiner
          // Model-Lab-Schatten-Betrieb (PHOENIX_MODEL_PROMOTION_ENABLED),
          // portiert NICHT die produktive Simulation.
          if (split.validation.length >= perLeagueEngineMinSample ||
              split.holdout.length >= perLeagueEngineMinSample) {
            final existingRhos = existingChallengers
                .map((c) => (c['weights'] as Map?)?['rho'])
                .whereType<num>()
                .map((rho) => rho.toDouble())
                .toSet();
            for (final rho in DixonColesEngine.rhoCandidates) {
              if (existingRhos.contains(rho)) continue;
              final challengerIndex = await registry.nextChallengerIndex(
                leagueId: leagueId,
                market: market.key,
                generation: generation,
              );
              final dixonColesChallenger =
                  await registry.createOrReuseDixonColesChallenger(
                leagueId: leagueId,
                market: market,
                rho: rho,
                generation: generation,
                challengerIndex: challengerIndex,
                sampleSize: eligibleSampleSize,
                parentModelId: championId,
                trainingStart: split.training.isEmpty
                    ? null
                    : split.training.first.kickoff,
                trainingEnd:
                    split.training.isEmpty ? null : split.training.last.kickoff,
                trainingCount: split.training.length,
                validationCount: split.validation.length,
                holdoutCount: split.holdout.length,
              );
              challengersCreated += 1;

              await database.addLearningCandidate(
                learningRunId: runId,
                modelVersionId: dixonColesChallenger.id,
                leagueId: leagueId,
                market: market.key,
              );

              if (split.validation.isNotEmpty) {
                await _persistComparison(
                  comparison: ChampionChallengerComparison.compare(
                    market: market,
                    leagueId: leagueId,
                    scopeSamples: split.validation,
                    championEngine: championEngine,
                    challengerEngine: dixonColesChallenger.engine,
                    config: config,
                  ),
                  evaluationType: 'walk_forward',
                  championModelId: championId,
                  challengerModelId: dixonColesChallenger.id,
                );
              }
              if (split.holdout.isNotEmpty) {
                await _persistComparison(
                  comparison: ChampionChallengerComparison.compare(
                    market: market,
                    leagueId: leagueId,
                    scopeSamples: split.holdout,
                    championEngine: championEngine,
                    challengerEngine: dixonColesChallenger.engine,
                    config: config,
                  ),
                  evaluationType: 'holdout',
                  championModelId: championId,
                  challengerModelId: dixonColesChallenger.id,
                );
              }
            }
          }

          // PHÖNIX Engine-Umbau Phase 2/3 (Plan "wild-cuddling-hoare", Live-
          // Backtests: Team-Stärke mit Shrinkage-Regularisierung 9 Ligen,
          // Ø Brier -7,3% ggü. einfachem Durchschnitt; Zeitverfall-
          // Halbwertszeit-Grid-Search auf denselben Daten zeigte einen
          // kleinen, aber sauber monotonen Vorteil für kürzere Halbwertszeiten
          // - zu klein für eine feste Entscheidung, deshalb hier als eigener,
          // benannter Challenger neben dem Kontrollwert getestet statt
          // übernommen). Eigenes, unabhängiges Budget (max.
          // `teamStrengthHalfLifeCandidates.length` pro Liga x Markt), läuft
          // unabhängig vom attackWeight-Gitter-Budget unten.
          final existingTeamStrengthHalfLives = existingChallengers
              .where((c) =>
                  (c['weights'] as Map?)?['engineVersion'] ==
                  TeamStrengthEngine.version)
              .map((c) => (c['feature_config'] as Map?)?['halfLifeDays'])
              .toSet();
          for (final halfLifeDays in teamStrengthHalfLifeCandidates) {
            if (existingTeamStrengthHalfLives.contains(halfLifeDays)) continue;

            final teamStrengthFit = await _teamStrengthFitFor(
              leagueId: leagueId,
              split: split,
              halfLifeDays: halfLifeDays,
              trainingDataCache: teamStrengthTrainingDataByLeague,
              fitCache: teamStrengthFitsByLeagueAndHalfLife,
              globalEloPriorCache: teamStrengthGlobalEloPriorCache,
              leaguePriorCache: teamStrengthLeaguePriorCache,
            );
            // Nur mit konvergiertem Fit als Challenger anlegen - ein
            // nicht-konvergierter Fit ist nicht vertrauenswürdig (live
            // beobachtet: ohne Regularisierung 6 von 9 Ligen ohne Konvergenz,
            // deutlich schlechter als der einfache Durchschnitt).
            if (teamStrengthFit == null || !teamStrengthFit.converged) continue;

            final teamStrengthValidation =
                split.validation.where((s) => s.hasGlobalMarketData).toList();
            final teamStrengthHoldout =
                split.holdout.where((s) => s.hasGlobalMarketData).toList();
            if (teamStrengthValidation.length < perLeagueEngineMinSample &&
                teamStrengthHoldout.length < perLeagueEngineMinSample) {
              continue;
            }

            final challengerIndex = await registry.nextChallengerIndex(
              leagueId: leagueId,
              market: market.key,
              generation: generation,
            );
            final teamStrengthChallenger =
                await registry.createOrReuseTeamStrengthChallenger(
              leagueId: leagueId,
              market: market,
              fit: teamStrengthFit,
              halfLifeDays: halfLifeDays,
              generation: generation,
              challengerIndex: challengerIndex,
              sampleSize: eligibleSampleSize,
              parentModelId: championId,
              trainingStart:
                  split.training.isEmpty ? null : split.training.first.kickoff,
              trainingEnd:
                  split.training.isEmpty ? null : split.training.last.kickoff,
              trainingCount: split.training.length,
              validationCount: teamStrengthValidation.length,
              holdoutCount: teamStrengthHoldout.length,
            );
            challengersCreated += 1;

            await database.addLearningCandidate(
              learningRunId: runId,
              modelVersionId: teamStrengthChallenger.id,
              leagueId: leagueId,
              market: market.key,
            );

            if (teamStrengthValidation.isNotEmpty) {
              await _persistComparison(
                comparison: ChampionChallengerComparison.compare(
                  market: market,
                  leagueId: leagueId,
                  scopeSamples: teamStrengthValidation,
                  championEngine: championEngine,
                  challengerEngine: teamStrengthChallenger.engine,
                  config: config,
                ),
                evaluationType: 'walk_forward',
                championModelId: championId,
                challengerModelId: teamStrengthChallenger.id,
              );
            }
            if (teamStrengthHoldout.isNotEmpty) {
              await _persistComparison(
                comparison: ChampionChallengerComparison.compare(
                  market: market,
                  leagueId: leagueId,
                  scopeSamples: teamStrengthHoldout,
                  championEngine: championEngine,
                  challengerEngine: teamStrengthChallenger.engine,
                  config: config,
                ),
                evaluationType: 'holdout',
                championModelId: championId,
                challengerModelId: teamStrengthChallenger.id,
              );
            }
          }

          final grid = ChallengerGenerator.candidateAttackWeights(config);
          // Die Challenger-Obergrenze ist ein echter Sicherheitsmechanismus,
          // keine reine Konfigurations-Dokumentation. Ohne sie erzeugte jeder
          // neue Lauf dieselben Varianten erneut bzw. meldete sie fälschlich
          // als neu erstellt.
          final remainingSlots =
              config.maxChallengersPerLeagueMarket - existingChallengers.length;
          if (remainingSlots <= 0) continue;
          final candidates = grid.take(remainingSlots).toList(growable: false);
          for (var i = 0; i < candidates.length; i++) {
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
              rawWeights: EngineWeightConfig(attackWeight: candidates[i]),
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
                  championEngine: championEngine,
                  challengerEngine:
                      ModelEngine.attackWeightBlend(created.weights),
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
                  championEngine: championEngine,
                  challengerEngine:
                      ModelEngine.attackWeightBlend(created.weights),
                  config: config,
                ),
                evaluationType: 'holdout',
                championModelId: championId,
                challengerModelId: created.id,
              );
            }
          }
        } finally {
          leagueMarketPairsProcessed += 1;
          processedLeagueIds.add(leagueId);
          // Der finale Run schreibt diese Werte ebenfalls. Dieses Update
          // während des Laufs ist bewusst klein und gibt der UI einen echten
          // Heartbeat; bei einem Absturz bleibt so zudem der letzte sichere
          // Arbeitsschritt nachvollziehbar.
          await database.updateLearningRunProgress(
            id: runId,
            currentStep: 'processing_league_markets',
            leaguesProcessed: processedLeagueIds.length,
            marketsProcessed: marketIndex + 1,
            eligibleMatches: audit.eligible,
            excludedMatches: audit.notEligible,
            challengersCreated: challengersCreated,
            summary: {
              'phase': 'processing_league_markets',
              'currentLeagueId': leagueId,
              'currentLeagueName': league['league_name'],
              'currentMarket': market.key,
              'leagueMarketPairsProcessed': leagueMarketPairsProcessed,
              'leagueMarketPairsTotal':
                  leagues.length * LearningMarket.values.length,
            },
          );
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

  /// Erzeugt (idempotent) den über alle Ligen gepoolten GLOBAL_GOALS_V1-
  /// Kandidaten für [market] gegen den globalen Champion, sofern genug
  /// gepoolte Samples mit echten GLOBAL_GOALS_V1-Daten existieren und noch
  /// kein solcher Kandidat für diesen Markt existiert. Gibt zurück, wie
  /// viele Challenger dabei neu erzeugt wurden (0 oder 1), damit der Aufrufer
  /// den laufenden `challengersCreated`-Zähler aktualisieren kann.
  Future<int> _ensurePooledGlobalGoalsV1Challenger({
    required LearningMarket market,
    required List<Map<String, Object?>> leagues,
    required Map<String, List<LearningSample>> samplesByLeague,
    required ModelRegistryService registry,
    required int runId,
  }) async {
    final existingGlobalChallengers = await registry.currentChallengers(
      leagueId: null,
      market: market.key,
    );
    final alreadyExists = existingGlobalChallengers.any(
      (c) =>
          (c['weights'] as Map?)?['engineVersion'] ==
          GlobalGoalsV1Engine.version,
    );
    if (alreadyExists) return 0;

    final pooled = <LearningSample>[
      for (final league in leagues)
        ...?samplesByLeague[league['league_id']?.toString()]?.where(
          (s) => s.hasGlobalGoalsV1Data,
        ),
    ]..sort((a, b) => a.kickoff.compareTo(b.kickoff));

    final split = ChronologicalSplit.split(pooled, config);
    if (split.validation.length < config.minValidationSample &&
        split.holdout.length < config.minHoldoutSample) {
      return 0;
    }

    final globalChampionModel =
        await database.championModel(leagueId: null, market: market.key);
    if (globalChampionModel == null) return 0;
    final globalChampionId = globalChampionModel['id'] as int;
    final globalChampionEngine = registry.modelEngine(globalChampionModel);

    final generation = await registry.nextGeneration(
      leagueId: null,
      market: market.key,
    );
    final challengerIndex = await registry.nextChallengerIndex(
      leagueId: null,
      market: market.key,
      generation: generation,
    );
    final challenger = await registry.createOrReuseGlobalGoalsV1Challenger(
      leagueId: null,
      market: market.key,
      generation: generation,
      challengerIndex: challengerIndex,
      sampleSize: pooled.length,
      parentModelId: globalChampionId,
      trainingStart:
          split.training.isEmpty ? null : split.training.first.kickoff,
      trainingEnd: split.training.isEmpty ? null : split.training.last.kickoff,
      trainingCount: split.training.length,
      validationCount: split.validation.length,
      holdoutCount: split.holdout.length,
    );

    await database.addLearningCandidate(
      learningRunId: runId,
      modelVersionId: challenger.id,
      leagueId: null,
      market: market.key,
    );

    if (split.validation.isNotEmpty) {
      await _persistComparison(
        comparison: ChampionChallengerComparison.compare(
          market: market,
          leagueId: null,
          scopeSamples: split.validation,
          championEngine: globalChampionEngine,
          challengerEngine: challenger.engine,
          config: config,
        ),
        evaluationType: 'walk_forward',
        championModelId: globalChampionId,
        challengerModelId: challenger.id,
      );
    }
    if (split.holdout.isNotEmpty) {
      await _persistComparison(
        comparison: ChampionChallengerComparison.compare(
          market: market,
          leagueId: null,
          scopeSamples: split.holdout,
          championEngine: globalChampionEngine,
          challengerEngine: challenger.engine,
          config: config,
        ),
        evaluationType: 'holdout',
        championModelId: globalChampionId,
        challengerModelId: challenger.id,
      );
    }

    return 1;
  }

  /// Wie [_ensurePooledGlobalGoalsV1Challenger], aber für die vier benannten
  /// `GlobalMarketHypothesis`-Varianten (Section 10-12, Claude AN2.txt) -
  /// über alle Ligen gepoolt, aus demselben Grund: die meisten Ligen sammeln
  /// einzeln viel zu wenige Spiele, um je für sich eine der vier Hypothesen
  /// statistisch zu prüfen.
  Future<int> _ensurePooledGlobalMarketChallengers({
    required LearningMarket market,
    required List<Map<String, Object?>> leagues,
    required Map<String, List<LearningSample>> samplesByLeague,
    required ModelRegistryService registry,
    required int runId,
  }) async {
    final existingGlobalChallengers = await registry.currentChallengers(
      leagueId: null,
      market: market.key,
    );
    final existingHypotheses = existingGlobalChallengers
        .map((c) => (c['weights'] as Map?)?['hypothesis']?.toString())
        .whereType<String>()
        .toSet();
    final remainingHypotheses = GlobalMarketHypothesis.values
        .where((h) => !existingHypotheses.contains(h.key))
        .toList();
    if (remainingHypotheses.isEmpty) return 0;

    final pooled = <LearningSample>[
      for (final league in leagues)
        ...?samplesByLeague[league['league_id']?.toString()]?.where(
          (s) => s.hasGlobalMarketData,
        ),
    ]..sort((a, b) => a.kickoff.compareTo(b.kickoff));

    final split = ChronologicalSplit.split(pooled, config);
    if (split.validation.length < config.minValidationSample &&
        split.holdout.length < config.minHoldoutSample) {
      return 0;
    }

    final globalChampionModel =
        await database.championModel(leagueId: null, market: market.key);
    if (globalChampionModel == null) return 0;
    final globalChampionId = globalChampionModel['id'] as int;
    final globalChampionEngine = registry.modelEngine(globalChampionModel);

    final generation =
        await registry.nextGeneration(leagueId: null, market: market.key);
    var created = 0;
    for (final hypothesis in remainingHypotheses) {
      final challengerIndex = await registry.nextChallengerIndex(
        leagueId: null,
        market: market.key,
        generation: generation,
      );
      final challenger = await registry.createOrReuseGlobalMarketChallenger(
        leagueId: null,
        market: market,
        hypothesis: hypothesis,
        generation: generation,
        challengerIndex: challengerIndex,
        sampleSize: pooled.length,
        parentModelId: globalChampionId,
        trainingStart:
            split.training.isEmpty ? null : split.training.first.kickoff,
        trainingEnd:
            split.training.isEmpty ? null : split.training.last.kickoff,
        trainingCount: split.training.length,
        validationCount: split.validation.length,
        holdoutCount: split.holdout.length,
      );
      created += 1;

      await database.addLearningCandidate(
        learningRunId: runId,
        modelVersionId: challenger.id,
        leagueId: null,
        market: market.key,
      );

      if (split.validation.isNotEmpty) {
        await _persistComparison(
          comparison: ChampionChallengerComparison.compare(
            market: market,
            leagueId: null,
            scopeSamples: split.validation,
            championEngine: globalChampionEngine,
            challengerEngine: challenger.engine,
            config: config,
          ),
          evaluationType: 'walk_forward',
          championModelId: globalChampionId,
          challengerModelId: challenger.id,
        );
      }
      if (split.holdout.isNotEmpty) {
        await _persistComparison(
          comparison: ChampionChallengerComparison.compare(
            market: market,
            leagueId: null,
            scopeSamples: split.holdout,
            championEngine: globalChampionEngine,
            challengerEngine: challenger.engine,
            config: config,
          ),
          evaluationType: 'holdout',
          championModelId: globalChampionId,
          challengerModelId: challenger.id,
        );
      }
    }

    return created;
  }

  /// Wie [_ensurePooledGlobalGoalsV1Challenger]/[_ensurePooledGlobalMarketChallengers],
  /// aber für Dixon-Coles (Section 4/10-12, Claude AN2.txt). Ursprünglich
  /// (Plan "wild-cuddling-hoare" Phase 1) rein PRO LIGA angelegt - bei nur
  /// ~570 leakage-sicheren Samples über 1233 Ligen verteilt erreichte
  /// praktisch keine einzelne Liga die nötige Stichprobe (live beobachtet:
  /// `challengers_created: 0` über drei aufeinanderfolgende Learning Runs).
  /// Nutzerkorrektur (2026-08-27): erst GLOBAL (Liga-Feld = null, über alle
  /// Ligen gepoolt, exakt wie die beiden Methoden oben) testen, damit sofort
  /// jedes Spiel abgedeckt ist. Die bereits bestehende PRO-LIGA-Variante
  /// weiter unten in der Liga-Schleife bleibt UNVERÄNDERT bestehen und
  /// "veredelt" automatisch jede Liga zu einer eigenen Engine, sobald sie
  /// für sich genug eigene Historie hat - kein Widerspruch, beide laufen
  /// nebeneinander.
  Future<int> _ensurePooledDixonColesChallengers({
    required LearningMarket market,
    required List<Map<String, Object?>> leagues,
    required Map<String, List<LearningSample>> samplesByLeague,
    required ModelRegistryService registry,
    required int runId,
  }) async {
    final existingGlobalChallengers = await registry.currentChallengers(
      leagueId: null,
      market: market.key,
    );
    final existingRhos = existingGlobalChallengers
        .where((c) =>
            (c['weights'] as Map?)?['engineVersion'] ==
            DixonColesEngine.version)
        .map((c) => (c['weights'] as Map?)?['rho'])
        .whereType<num>()
        .map((rho) => rho.toDouble())
        .toSet();
    if (DixonColesEngine.rhoCandidates.every(existingRhos.contains)) return 0;

    final pooled = <LearningSample>[
      for (final league in leagues)
        ...?samplesByLeague[league['league_id']?.toString()],
    ]..sort((a, b) => a.kickoff.compareTo(b.kickoff));

    final split = ChronologicalSplit.split(pooled, config);
    if (split.validation.length < config.minValidationSample &&
        split.holdout.length < config.minHoldoutSample) {
      return 0;
    }

    final globalChampionModel =
        await database.championModel(leagueId: null, market: market.key);
    if (globalChampionModel == null) return 0;
    final globalChampionId = globalChampionModel['id'] as int;
    final globalChampionEngine = registry.modelEngine(globalChampionModel);

    final generation =
        await registry.nextGeneration(leagueId: null, market: market.key);

    var created = 0;
    for (final rho in DixonColesEngine.rhoCandidates) {
      if (existingRhos.contains(rho)) continue;

      final challengerIndex = await registry.nextChallengerIndex(
        leagueId: null,
        market: market.key,
        generation: generation,
      );
      final challenger = await registry.createOrReuseDixonColesChallenger(
        leagueId: null,
        market: market,
        rho: rho,
        generation: generation,
        challengerIndex: challengerIndex,
        sampleSize: pooled.length,
        parentModelId: globalChampionId,
        trainingStart:
            split.training.isEmpty ? null : split.training.first.kickoff,
        trainingEnd:
            split.training.isEmpty ? null : split.training.last.kickoff,
        trainingCount: split.training.length,
        validationCount: split.validation.length,
        holdoutCount: split.holdout.length,
      );
      created += 1;

      await database.addLearningCandidate(
        learningRunId: runId,
        modelVersionId: challenger.id,
        leagueId: null,
        market: market.key,
      );

      if (split.validation.isNotEmpty) {
        await _persistComparison(
          comparison: ChampionChallengerComparison.compare(
            market: market,
            leagueId: null,
            scopeSamples: split.validation,
            championEngine: globalChampionEngine,
            challengerEngine: challenger.engine,
            config: config,
          ),
          evaluationType: 'walk_forward',
          championModelId: globalChampionId,
          challengerModelId: challenger.id,
        );
      }
      if (split.holdout.isNotEmpty) {
        await _persistComparison(
          comparison: ChampionChallengerComparison.compare(
            market: market,
            leagueId: null,
            scopeSamples: split.holdout,
            championEngine: globalChampionEngine,
            challengerEngine: challenger.engine,
            config: config,
          ),
          evaluationType: 'holdout',
          championModelId: globalChampionId,
          challengerModelId: challenger.id,
        );
      }
    }
    return created;
  }

  /// Wie [_ensurePooledDixonColesChallengers], aber für Team-Stärke
  /// (`TeamStrengthEngine`). Fittet EIN gemeinsames Angriff/Abwehr-Rating
  /// über ALLE Ligen zusammen (jedes Team bekommt sofort ein Rating, auch
  /// ohne eigene ausreichende Liga-Historie - dünn besetzte Teams werden
  /// von der bestehenden Shrinkage-Regularisierung in
  /// `TeamStrengthEngine.fit` automatisch Richtung neutral(1.0) gezogen,
  /// exakt dasselbe Sicherheitsnetz wie beim Pro-Liga-Fit). Die bestehende
  /// PRO-LIGA-Variante bleibt unverändert bestehen und ersetzt diesen
  /// globalen Fallback automatisch, sobald eine Liga für sich genug eigene
  /// Historie hat (eigener, spezifischerer `config_hash`/`league_id` -
  /// beide können nebeneinander als separate Challenger existieren).
  Future<int> _ensurePooledTeamStrengthChallenger({
    required LearningMarket market,
    required List<Map<String, Object?>> leagues,
    required Map<String, List<LearningSample>> samplesByLeague,
    required ModelRegistryService registry,
    required int runId,
    required Map<double?, TeamStrengthFit?> fitCache,
    required Map<String, Object?> trainingDataCache,
    required List<double?> halfLifeCandidates,
  }) async {
    final existingGlobalChallengers = await registry.currentChallengers(
      leagueId: null,
      market: market.key,
    );
    final existingHalfLives = existingGlobalChallengers
        .where((c) =>
            (c['weights'] as Map?)?['engineVersion'] ==
            TeamStrengthEngine.version)
        .map((c) => (c['feature_config'] as Map?)?['halfLifeDays'])
        .toSet();

    final pooled = <LearningSample>[
      for (final league in leagues)
        ...?samplesByLeague[league['league_id']?.toString()],
    ]..sort((a, b) => a.kickoff.compareTo(b.kickoff));

    var created = 0;
    for (final halfLifeDays in halfLifeCandidates) {
      if (existingHalfLives.contains(halfLifeDays)) continue;

      final split = ChronologicalSplit.split(pooled, config);
      final fit = await _pooledTeamStrengthFitFor(
        leagues: leagues,
        split: split,
        halfLifeDays: halfLifeDays,
        trainingDataCache: trainingDataCache,
        fitCache: fitCache,
      );
      if (fit == null || !fit.converged) continue;

      final teamStrengthValidation =
          split.validation.where((s) => s.hasGlobalMarketData).toList();
      final teamStrengthHoldout =
          split.holdout.where((s) => s.hasGlobalMarketData).toList();
      if (teamStrengthValidation.length < config.minValidationSample &&
          teamStrengthHoldout.length < config.minHoldoutSample) {
        continue;
      }

      final globalChampionModel =
          await database.championModel(leagueId: null, market: market.key);
      if (globalChampionModel == null) continue;
      final globalChampionId = globalChampionModel['id'] as int;
      final globalChampionEngine = registry.modelEngine(globalChampionModel);

      final generation =
          await registry.nextGeneration(leagueId: null, market: market.key);
      final challengerIndex = await registry.nextChallengerIndex(
        leagueId: null,
        market: market.key,
        generation: generation,
      );
      final challenger = await registry.createOrReuseTeamStrengthChallenger(
        leagueId: null,
        market: market,
        fit: fit,
        halfLifeDays: halfLifeDays,
        generation: generation,
        challengerIndex: challengerIndex,
        sampleSize: pooled.length,
        parentModelId: globalChampionId,
        trainingStart:
            split.training.isEmpty ? null : split.training.first.kickoff,
        trainingEnd:
            split.training.isEmpty ? null : split.training.last.kickoff,
        trainingCount: split.training.length,
        validationCount: teamStrengthValidation.length,
        holdoutCount: teamStrengthHoldout.length,
      );
      created += 1;

      await database.addLearningCandidate(
        learningRunId: runId,
        modelVersionId: challenger.id,
        leagueId: null,
        market: market.key,
      );

      if (teamStrengthValidation.isNotEmpty) {
        await _persistComparison(
          comparison: ChampionChallengerComparison.compare(
            market: market,
            leagueId: null,
            scopeSamples: teamStrengthValidation,
            championEngine: globalChampionEngine,
            challengerEngine: challenger.engine,
            config: config,
          ),
          evaluationType: 'walk_forward',
          championModelId: globalChampionId,
          challengerModelId: challenger.id,
        );
      }
      if (teamStrengthHoldout.isNotEmpty) {
        await _persistComparison(
          comparison: ChampionChallengerComparison.compare(
            market: market,
            leagueId: null,
            scopeSamples: teamStrengthHoldout,
            championEngine: globalChampionEngine,
            challengerEngine: challenger.engine,
            config: config,
          ),
          evaluationType: 'holdout',
          championModelId: globalChampionId,
          challengerModelId: challenger.id,
        );
      }
    }
    return created;
  }

  /// Wie [_teamStrengthTrainingDataFor], aber über ALLE Ligen gepoolt
  /// (`database.footballSettledMatchesForLeagues`, EIN Datenbank-Roundtrip
  /// statt 1233). Ergebnis wird in [trainingDataCache] unter dem festen
  /// Schlüssel `'__GLOBAL__'` für die Dauer des Laufs abgelegt, exakt
  /// dasselbe Cache-Prinzip wie pro Liga.
  Future<({List<MatchResult> matches, DateTime asOf})?>
      _pooledTeamStrengthTrainingData({
    required List<Map<String, Object?>> leagues,
    required ChronologicalSplit split,
    required Map<String, Object?> trainingDataCache,
  }) async {
    const cacheKey = '__GLOBAL__';
    if (trainingDataCache.containsKey(cacheKey)) {
      return trainingDataCache[cacheKey] as ({
        List<MatchResult> matches,
        DateTime asOf
      })?;
    }

    final evaluatedSamples =
        split.validation.isNotEmpty ? split.validation : split.holdout;
    if (evaluatedSamples.isEmpty) {
      trainingDataCache[cacheKey] = null;
      return null;
    }
    final boundary = evaluatedSamples.first.kickoff;

    final leagueIds = leagues
        .map((l) => l['league_id']?.toString())
        .whereType<String>()
        .toSet();
    // Der globale Fallback erhält denselben M1-Historienkorpus wie der
    // Liga-Fit; nur die aktiv berücksichtigten Ligen werden einbezogen.
    final rawMatches = (await database.teamStrengthCorpus())
        .where((row) => leagueIds.contains(row['league_id']?.toString()))
        .toList();
    final trainingMatches = rawMatches.where((row) {
      final kickoff = row['kickoff'];
      if (kickoff is! DateTime) return false;
      return kickoff.isBefore(boundary);
    }).toList();

    // Gepoolt über alle Ligen ist eine deutlich niedrigere Mindestmenge als
    // die 25 der Pro-Liga-Variante nicht nötig, aber dieselbe Grundregel
    // (kein Fit auf einer Mini-Stichprobe) gilt weiterhin.
    const minimumTrainingMatches = 25;
    if (trainingMatches.length < minimumTrainingMatches) {
      trainingDataCache[cacheKey] = null;
      return null;
    }

    final matchResults = trainingMatches
        .map((row) => MatchResult(
              homeTeamId: row['home_team_id']?.toString() ?? '',
              awayTeamId: row['away_team_id']?.toString() ?? '',
              homeGoals: _parseGoals(row['home_goals']),
              awayGoals: _parseGoals(row['away_goals']),
              kickoff: row['kickoff'] as DateTime?,
            ))
        .where((m) => m.homeTeamId.isNotEmpty && m.awayTeamId.isNotEmpty)
        .toList();

    final result = (matches: matchResults, asOf: boundary);
    trainingDataCache[cacheKey] = result;
    return result;
  }

  /// Wie [_teamStrengthFitFor], aber für den gepoolten globalen Fit.
  Future<TeamStrengthFit?> _pooledTeamStrengthFitFor({
    required List<Map<String, Object?>> leagues,
    required ChronologicalSplit split,
    double? halfLifeDays,
    required Map<String, Object?> trainingDataCache,
    required Map<double?, TeamStrengthFit?> fitCache,
  }) async {
    if (fitCache.containsKey(halfLifeDays)) return fitCache[halfLifeDays];

    final trainingData = await _pooledTeamStrengthTrainingData(
      leagues: leagues,
      split: split,
      trainingDataCache: trainingDataCache,
    );
    if (trainingData == null) {
      fitCache[halfLifeDays] = null;
      return null;
    }

    final fit = TeamStrengthEngine.fit(
      trainingData.matches,
      halfLifeDays: halfLifeDays,
      asOf: trainingData.asOf,
    );
    fitCache[halfLifeDays] = fit;
    return fit;
  }

  /// Fittet Team-Stärke (`TeamStrengthEngine`) EINMAL pro Liga aus echten,
  /// abgerechneten Ergebnissen VOR dem Beginn von Validation/Holdout
  /// (Leakage-Sicherheit) - unabhängig von `LearningSample`/Phase-2-
  /// Snapshot-Abdeckung (`database.footballSettledMatchesForLeague`,
  /// dieselbe Begründung wie im Backtest-Skript: die Snapshot-Abdeckung ist
  /// für ein verlässliches Team-Rating-Fitting zu lückenhaft). Ergebnis wird
  /// in [cache] für die Dauer des Laufs abgelegt (auch `null`, wenn zu wenig
  /// Historie vorhanden ist - verhindert wiederholte erfolglose Versuche
  /// bei jedem der 3 Märkte).
  /// Lädt/bereitet die Trainingsspiele EINER Liga für das Team-Stärke-
  /// Fitting vor (leakage-sicher: nur Spiele vor Beginn von Validation/
  /// Holdout) - einmal pro Liga, unabhängig von der Halbwertszeit, damit
  /// mehrere Halbwertszeit-Kandidaten (siehe [_teamStrengthFitFor]) sich
  /// dieselbe Datenbank-Abfrage teilen statt sie zu wiederholen.
  Future<({List<MatchResult> matches, DateTime asOf})?>
      _teamStrengthTrainingDataFor({
    required String leagueId,
    required ChronologicalSplit split,
    required Map<String, ({List<MatchResult> matches, DateTime asOf})?> cache,
  }) async {
    if (cache.containsKey(leagueId)) return cache[leagueId];

    final evaluatedSamples =
        split.validation.isNotEmpty ? split.validation : split.holdout;
    if (evaluatedSamples.isEmpty) {
      cache[leagueId] = null;
      return null;
    }
    final boundary = evaluatedSamples.first.kickoff;

    // M3b: Nicht nur die kurze PHÖNIX-Live-Historie verwenden. Der M1-
    // Korpus enthält zusätzlich sauber an unsere Teams/Liga gebundene,
    // abgeschlossene historische Spiele. Das Zeitfenster unten bleibt dabei
    // strikt vor Validation/Holdout und schützt den Backtest vor Leakage.
    final rawMatches = await database.teamStrengthCorpus(leagueId: leagueId);
    final trainingMatches = rawMatches.where((row) {
      final kickoff = row['kickoff'];
      if (kickoff is! DateTime) return false;
      return kickoff.isBefore(boundary);
    }).toList();

    // Dieselbe Mindestmenge wie der Live-Backtest (Plan "wild-cuddling-
    // hoare"): darunter ist selbst mit Shrinkage-Regularisierung kein
    // verlässlicher Fit zu erwarten (live getestet: bei 40 hatten nur 4 von
    // 1233 Ligen genug Historie, 25 ist der bewusste Kompromiss).
    const minimumTrainingMatches = 25;
    if (trainingMatches.length < minimumTrainingMatches) {
      cache[leagueId] = null;
      return null;
    }

    final matchResults = trainingMatches
        .map((row) => MatchResult(
              homeTeamId: row['home_team_id']?.toString() ?? '',
              awayTeamId: row['away_team_id']?.toString() ?? '',
              homeGoals: _parseGoals(row['home_goals']),
              awayGoals: _parseGoals(row['away_goals']),
              kickoff: row['kickoff'] as DateTime?,
            ))
        .where((m) => m.homeTeamId.isNotEmpty && m.awayTeamId.isNotEmpty)
        .toList();

    final result = (matches: matchResults, asOf: boundary);
    cache[leagueId] = result;
    return result;
  }

  /// Fittet Team-Stärke für eine bestimmte Halbwertszeit (`null` = kein
  /// Zeitverfall) - cached separat je (Liga, Halbwertszeit), teilt sich
  /// aber die vorbereiteten Trainingsspiele über [_teamStrengthTrainingDataFor]
  /// mit allen anderen Halbwertszeit-Kandidaten derselben Liga.
  Future<TeamStrengthFit?> _teamStrengthFitFor({
    required String leagueId,
    required ChronologicalSplit split,
    double? halfLifeDays,
    required Map<String, ({List<MatchResult> matches, DateTime asOf})?>
        trainingDataCache,
    required Map<String, TeamStrengthFit?> fitCache,
    required Map<DateTime, EloPrior> globalEloPriorCache,
    required Map<String, Map<String, ({double attack, double defense})>>
        leaguePriorCache,
  }) async {
    final cacheKey = '$leagueId|${halfLifeDays ?? "none"}';
    if (fitCache.containsKey(cacheKey)) return fitCache[cacheKey];

    final trainingData = await _teamStrengthTrainingDataFor(
      leagueId: leagueId,
      split: split,
      cache: trainingDataCache,
    );
    if (trainingData == null) {
      fitCache[cacheKey] = null;
      return null;
    }

    final priors = await _eloPriorsForTraining(
      leagueId: leagueId,
      trainingData: trainingData,
      globalEloPriorCache: globalEloPriorCache,
      leaguePriorCache: leaguePriorCache,
    );
    final fit = TeamStrengthEngine.fit(
      trainingData.matches,
      halfLifeDays: halfLifeDays,
      asOf: trainingData.asOf,
      priors: priors,
    );
    fitCache[cacheKey] = fit;
    return fit;
  }

  /// M3b: leitet pro Liga Cold-Start-Priors aus ELO-Werten ab, die strikt
  /// vor dem Beginn von Validation/Holdout bekannt waren. Der Koeffizient
  /// wird über alle bis dahin verfügbaren, liga-normalisierten historischen
  /// Beobachtungen gefittet; die Anwendung selbst bleibt liga-relativ.
  Future<Map<String, ({double attack, double defense})>> _eloPriorsForTraining({
    required String leagueId,
    required ({List<MatchResult> matches, DateTime asOf}) trainingData,
    required Map<DateTime, EloPrior> globalEloPriorCache,
    required Map<String, Map<String, ({double attack, double defense})>>
        leaguePriorCache,
  }) async {
    final cacheKey = '$leagueId|${trainingData.asOf.toUtc().toIso8601String()}';
    final existing = leaguePriorCache[cacheKey];
    if (existing != null) return existing;

    final globalPrior = await _globalEloPriorAsOf(
      trainingData.asOf,
      cache: globalEloPriorCache,
    );
    if (globalPrior.k == 0) {
      leaguePriorCache[cacheKey] = const {};
      return const {};
    }
    final ratings = await database.eloRatingsAsOf(
      teamIds: [
        for (final match in trainingData.matches) match.homeTeamId,
        for (final match in trainingData.matches) match.awayTeamId,
      ],
      asOf: trainingData.asOf,
    );
    final priors = globalPrior.forLeague(ratings);
    leaguePriorCache[cacheKey] = priors;
    return priors;
  }

  Future<EloPrior> _globalEloPriorAsOf(
    DateTime asOf, {
    required Map<DateTime, EloPrior> cache,
  }) async {
    final key = asOf.toUtc();
    final existing = cache[key];
    if (existing != null) return existing;

    final corpus = await database.teamStrengthCorpus();
    final byLeague = <String, List<Map<String, Object?>>>{};
    for (final row in corpus) {
      final kickoff = row['kickoff'];
      final leagueId = row['league_id']?.toString();
      if (kickoff is! DateTime || leagueId == null || !kickoff.isBefore(key)) {
        continue;
      }
      byLeague.putIfAbsent(leagueId, () => []).add(row);
    }

    final observations = <({double z, double supremacyLog})>[];
    for (final rows in byLeague.values) {
      final eloSum = <String, double>{};
      final eloCount = <String, int>{};
      final goalsFor = <String, double>{};
      final goalsAgainst = <String, double>{};
      for (final row in rows) {
        final home = row['home_team_id']?.toString() ?? '';
        final away = row['away_team_id']?.toString() ?? '';
        final homeGoals = _parseGoals(row['home_goals']);
        final awayGoals = _parseGoals(row['away_goals']);
        if (home.isEmpty || away.isEmpty) continue;
        goalsFor[home] = (goalsFor[home] ?? 0) + homeGoals;
        goalsAgainst[home] = (goalsAgainst[home] ?? 0) + awayGoals;
        goalsFor[away] = (goalsFor[away] ?? 0) + awayGoals;
        goalsAgainst[away] = (goalsAgainst[away] ?? 0) + homeGoals;
        final homeElo = row['home_elo'];
        final awayElo = row['away_elo'];
        if (homeElo is num) {
          eloSum[home] = (eloSum[home] ?? 0) + homeElo.toDouble();
          eloCount[home] = (eloCount[home] ?? 0) + 1;
        }
        if (awayElo is num) {
          eloSum[away] = (eloSum[away] ?? 0) + awayElo.toDouble();
          eloCount[away] = (eloCount[away] ?? 0) + 1;
        }
      }
      final meanEloByTeam = <String, double>{
        for (final entry in eloSum.entries)
          if ((eloCount[entry.key] ?? 0) > 0)
            entry.key: entry.value / eloCount[entry.key]!,
      };
      if (meanEloByTeam.length < 2) continue;
      final leagueMean =
          meanEloByTeam.values.reduce((a, b) => a + b) / meanEloByTeam.length;
      observations.addAll(EloPrior.standardize([
        for (final entry in meanEloByTeam.entries)
          (
            eloDiff: entry.value - leagueMean,
            goalsFor: goalsFor[entry.key] ?? 0,
            goalsAgainst: goalsAgainst[entry.key] ?? 0,
          ),
      ]));
    }
    final prior = EloPrior.fit(observations);
    cache[key] = prior;
    return prior;
  }

  int _parseGoals(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
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

/// Wo der letzte, per Redeploy/Crash unterbrochene Learning Run stehen
/// geblieben ist - siehe [LearningRunService._resumeStateFrom].
class _ResumeState {
  const _ResumeState({
    required this.marketKey,
    required this.leagueId,
    required this.challengersCreatedCarriedOver,
  });

  final String marketKey;
  final String leagueId;
  final int challengersCreatedCarriedOver;
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
