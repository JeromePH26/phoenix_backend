import '../config/model_lab_config.dart';
import '../database/database.dart';
import 'challenger_generator.dart';
import 'dixon_coles_engine.dart';
import 'engine_replica.dart';
import 'global_goals_v1_engine.dart';
import 'global_market_engine.dart';
import 'learning_dataset_builder.dart';
import 'learning_market.dart';
import 'learning_sample.dart';
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
    // Ein abgebrochener oder noch gesperrter Learning-Run darf die
    // Initialisierung neuer, bereits produktiv verfügbarer Markt-Familien
    // nicht blockieren. Die globale Baseline ist idempotent und verändert
    // weder einen bestehenden Champion noch eine Produktionsanalyse.
    // Sie wird deshalb bewusst VOR dem Run-Lock sichergestellt.
    final baselineRegistry = ModelRegistryService(
      database: database,
      config: config,
    );
    for (final market in LearningMarket.values) {
      await baselineRegistry.ensureGlobalBaseline(market.key);
    }

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

  Future<_RunResult> _runSteps(int runId, _ResumeState? resumeState) async {
    final datasetBuilder = LearningDatasetBuilder(
      database: database,
      config: config,
    );
    final registry = ModelRegistryService(database: database, config: config);

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
        final baselineModel =
            leagueChampion ?? await database.championModel(leagueId: null, market: market.key) ??
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
            final challenger = await registry.createOrReuseGlobalMarketChallenger(
              leagueId: leagueId,
              market: market,
              hypothesis: hypothesis,
              generation: generation,
              challengerIndex: challengerIndex,
              sampleSize: eligibleSampleSize,
              parentModelId: championId,
              trainingStart:
                  split.training.isEmpty ? null : split.training.first.kickoff,
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
        if (split.validation.length >= config.minValidationSample ||
            split.holdout.length >= config.minHoldoutSample) {
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
                challengerEngine: ModelEngine.attackWeightBlend(created.weights),
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
                challengerEngine: ModelEngine.attackWeightBlend(created.weights),
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

    final globalChampionModel = await database.championModel(leagueId: null, market: market.key);
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
      trainingStart: split.training.isEmpty ? null : split.training.first.kickoff,
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

    final globalChampionModel = await database.championModel(leagueId: null, market: market.key);
    if (globalChampionModel == null) return 0;
    final globalChampionId = globalChampionModel['id'] as int;
    final globalChampionEngine = registry.modelEngine(globalChampionModel);

    final generation = await registry.nextGeneration(leagueId: null, market: market.key);
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
        trainingStart: split.training.isEmpty ? null : split.training.first.kickoff,
        trainingEnd: split.training.isEmpty ? null : split.training.last.kickoff,
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
