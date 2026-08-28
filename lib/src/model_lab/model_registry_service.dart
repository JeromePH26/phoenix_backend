import '../config/model_lab_config.dart';
import '../database/database.dart';
import 'dixon_coles_engine.dart';
import 'engine_replica.dart';
import 'global_goals_v1_engine.dart';
import 'global_market_engine.dart';
import 'learning_market.dart';
import 'team_strength_engine.dart';
import 'weight_config.dart';

/// Section 12/59/60: Model Registry. Verwaltet unveränderliche
/// (`immutable`) Model-Versionen (Champion + Challenger) je Liga x Markt.
/// Jede Challenger-Version wird genau einmal erzeugt - ein erneuter Versuch,
/// dieselbe Gewichts-Konfiguration zu erzeugen, liefert wegen des
/// `config_hash`-Unique-Index dieselbe bestehende Zeile zurück, statt eine
/// neue anzulegen (Section 12: "niemals still verändert oder überschrieben").
class ModelRegistryService {
  ModelRegistryService({required this.database, required this.config});

  final PhoenixDatabase database;
  final ModelLabConfig config;

  static const String codeSchemaVersion = engineReplicaVersion;

  /// Kein Wettmarkt, sondern die gemeinsame Ergebnisverteilung einer
  /// Fußballpartie. Modelle unter diesem Schlüssel liefern ausschließlich
  /// erwartete Heim-/Auswärtstore; sämtliche sichtbaren Märkte werden danach
  /// gemeinsam aus genau dieser Verteilung abgeleitet.
  static const String matchDistributionMarket = 'match_distribution';

  /// Legt die eine globale PHÖNIX-Referenz an, gegen die Liga-Engines im
  /// Schattenbetrieb verglichen werden. Die historischen marktweisen
  /// Baselines bleiben für ihre Auswertung erhalten, dürfen aber nicht mehr
  /// als Live-Entscheider dienen.
  Future<int> ensureGlobalMatchDistributionBaseline() async {
    final existing =
        await database.globalBaselineModel(matchDistributionMarket);
    if (existing != null) {
      if (existing['status'] != 'champion') {
        await _promoteIfNoChampionExists(
          market: matchDistributionMarket,
          leagueId: null,
          modelVersionId: existing['id'] as int,
        );
      }
      return existing['id'] as int;
    }

    const engine = ModelEngine.globalGoalsV1();
    final id = await database.insertModelVersion(
      readableVersion: 'PHOENIX-GLOBAL-V1',
      generation: 1,
      leagueId: null,
      market: matchDistributionMarket,
      modelType: 'global_baseline',
      featureConfig: {
        'engineFamily': 'PHOENIX_GLOBAL_ENGINE_V1',
        'scope': 'all_markets_from_one_goal_distribution',
        'note':
            'Einziger globaler Referenzmotor. 1X2, Tore, BTTS, DNB und DC stammen aus derselben Monte-Carlo-Ergebnisverteilung.',
      },
      weights: engine.toJson(),
      trainingCount: 0,
      validationCount: 0,
      holdoutCount: 0,
      shadowCount: 0,
      status: 'champion',
      configHash: 'phoenix_global_engine_v1',
      codeSchemaVersion: codeSchemaVersion,
    );
    await database.insertModelLabAuditLog(
      action: 'global_match_engine_created',
      actor: 'system',
      modelVersionId: id,
      market: matchDistributionMarket,
      details: {'readableVersion': 'PHOENIX-GLOBAL-V1'},
    );
    return id;
  }

  /// Stellt sicher, dass für einen Markt die Global-/Baseline-Engine als
  /// Model-Version existiert (attackWeight = 0.5, identisch zur produktiven
  /// Engine-Formel). Diese Zeile ist die Rückfallbasis für alle Ligen ohne
  /// eigenen Champion (Section 8).
  Future<int> ensureGlobalBaseline(String market) async {
    final existing = await database.globalBaselineModel(market);
    if (existing != null) {
      // Falls noch kein Champion für den Markt gesetzt ist (z.B. frisch
      // migrierte DB), wird die Global Baseline automatisch zum initialen
      // Champion - PHÖNIX braucht immer eine produktive Basis.
      if (existing['status'] != 'champion') {
        await _promoteIfNoChampionExists(
          market: market,
          leagueId: null,
          modelVersionId: existing['id'] as int,
        );
      }
      return existing['id'] as int;
    }

    final weights = EngineWeightConfig.global;
    final id = await database.insertModelVersion(
      readableVersion: 'V1',
      generation: 1,
      leagueId: null,
      market: market,
      modelType: 'global_baseline',
      featureConfig: {
        'features': 'attackWeightBlend',
        'market': market,
        'engineFamily': 'poisson_monte_carlo_derived',
        'note':
            'Marktspezifischer Champion; lernt getrennt auf identischen, zeitlich sauberen Pre-Match-Snapshots.',
      },
      weights: weights.toJson(),
      trainingCount: 0,
      validationCount: 0,
      holdoutCount: 0,
      shadowCount: 0,
      status: 'champion',
      configHash: weights.configHash(),
      codeSchemaVersion: codeSchemaVersion,
    );

    await database.insertModelLabAuditLog(
      action: 'global_baseline_created',
      actor: 'system',
      modelVersionId: id,
      market: market,
      details: {'readableVersion': 'V1'},
    );

    return id;
  }

  Future<void> _promoteIfNoChampionExists({
    required String market,
    required String? leagueId,
    required int modelVersionId,
  }) async {
    final champion = await database.championModel(
      leagueId: leagueId,
      market: market,
    );
    if (champion != null) return;
    await database.promoteModel(newChampionId: modelVersionId);
  }

  Future<Map<String, Object?>?> currentChampion({
    String? leagueId,
    required String market,
  }) =>
      database.championModel(leagueId: leagueId, market: market);

  /// Liefert die tatsächlich verfügbare Produktionsbasis für eine Liga. Eine
  /// Liga bekommt erst nach ausreichend vielen sauber abgerechneten Spielen
  /// einen eigenen Champion. Bis dahin ist der globale Champion bewusst die
  /// Rückfallbasis – auch für Shadow Predictions. Ohne diesen Fallback würden
  /// neue Ligen zwar einen Snapshot haben, aber gar keine Messwerte sammeln.
  Future<Map<String, Object?>?> productionChampion({
    required String leagueId,
    required String market,
  }) async {
    final leagueChampion = await currentChampion(
      leagueId: leagueId,
      market: market,
    );
    // NICHT `globalBaselineModel` (liefert immer die ÄLTESTE
    // `global_baseline`-Zeile unabhängig vom Status - seit
    // `activateGlobalMarketChampion` kann das die längst archivierte
    // attackWeight-Formel sein). `currentChampion(leagueId: null, ...)`
    // respektiert den tatsächlichen `champion`-Status.
    return leagueChampion ??
        await currentChampion(leagueId: null, market: market);
  }

  Future<List<Map<String, Object?>>> currentChallengers({
    String? leagueId,
    required String market,
  }) =>
      database.challengerModels(leagueId: leagueId, market: market);

  /// Batch-Variante von [currentChampion]/[currentChallengers] für den
  /// Model-Lab-Übersichts-Endpoint: ein einziger DB-Roundtrip für ALLE
  /// Liga x Markt-Kombinationen statt 2 sequenzielle Anfragen je Kombination.
  Future<
      ({
        Map<String, Map<String, Object?>> champions,
        Map<String, List<Map<String, Object?>>> challengers,
      })> currentChampionsAndChallengersBatch({
    required List<String> leagueIds,
    required List<String> markets,
  }) async {
    final rows = await database.modelVersionsForLeagueMarkets(
      leagueIds: leagueIds,
      markets: markets,
    );

    final champions = <String, Map<String, Object?>>{};
    final challengers = <String, List<Map<String, Object?>>>{};
    for (final row in rows) {
      final leagueId = row['league_id']?.toString();
      final market = row['market']?.toString();
      if (leagueId == null || market == null) continue;
      final key = leagueMarketKey(leagueId, market);
      if (row['status'] == 'champion') {
        champions[key] = row;
      } else {
        (challengers[key] ??= <Map<String, Object?>>[]).add(row);
      }
    }
    return (champions: champions, challengers: challengers);
  }

  /// Schlüsselformat für die Lookup-Maps aus
  /// [currentChampionsAndChallengersBatch].
  static String leagueMarketKey(String leagueId, String market) =>
      '$leagueId|$market';

  /// Section 12: nächste Generation für eine Liga x Markt-Kombination.
  /// Generation 1 = Global Baseline. Jede Promotion (später, außerhalb V0)
  /// erhöht die Generation um 1; innerhalb einer Generation zählen
  /// Challenger als V{generation}-C1, C2, ... hoch.
  Future<int> nextGeneration({
    required String? leagueId,
    required String market,
  }) async {
    final champion = await currentChampion(leagueId: leagueId, market: market);
    if (champion != null) {
      return (champion['generation'] as int? ?? 1) + 1;
    }
    return 1;
  }

  Future<int> nextChallengerIndex({
    required String? leagueId,
    required String market,
    required int generation,
  }) async {
    final challengers = await currentChallengers(
      leagueId: leagueId,
      market: market,
    );
    final matchingGeneration = challengers.where(
      (c) => (c['generation'] as int? ?? 0) == generation,
    );
    return matchingGeneration.length + 1;
  }

  /// Erzeugt (oder findet die bereits existierende, identische) Challenger-
  /// Version für eine Liga x Markt-Kombination. `sampleSize` steuert die
  /// Shrinkage-Stärke (Section 15).
  Future<({int id, EngineWeightConfig weights})> createOrReuseChallenger({
    required String? leagueId,
    required String market,
    required int generation,
    required int challengerIndex,
    required EngineWeightConfig rawWeights,
    required int sampleSize,
    required int parentModelId,
    DateTime? trainingStart,
    DateTime? trainingEnd,
    required int trainingCount,
    required int validationCount,
    required int holdoutCount,
  }) async {
    final effectiveWeights = rawWeights.shrunkTowardsGlobal(
      sampleSize: sampleSize,
      config: config,
    );

    final readableVersion = 'V$generation-C$challengerIndex';
    final id = await database.insertModelVersion(
      readableVersion: readableVersion,
      parentModelId: parentModelId,
      generation: generation,
      leagueId: leagueId,
      market: market,
      modelType: 'weight_variant',
      featureConfig: const {'features': 'attackWeightBlend'},
      weights: {
        ...effectiveWeights.toJson(),
        'rawAttackWeight': double.parse(
          rawWeights.attackWeight.toStringAsFixed(4),
        ),
        'shrinkageSampleSize': sampleSize,
        'shrinkageK': config.shrinkageK,
      },
      trainingStart: trainingStart,
      trainingEnd: trainingEnd,
      trainingCount: trainingCount,
      validationCount: validationCount,
      holdoutCount: holdoutCount,
      shadowCount: 0,
      status: 'challenger',
      configHash: effectiveWeights.configHash(),
      codeSchemaVersion: codeSchemaVersion,
    );

    await database.insertModelLabAuditLog(
      action: 'challenger_created',
      actor: 'system',
      modelVersionId: id,
      leagueId: leagueId,
      market: market,
      details: {
        'readableVersion': readableVersion,
        'attackWeight': effectiveWeights.attackWeight,
        'sampleSize': sampleSize,
      },
    );

    return (id: id, weights: effectiveWeights);
  }

  EngineWeightConfig weightsFromModel(Map<String, Object?> model) {
    final weights = model['weights'];
    if (weights is Map) {
      return EngineWeightConfig.fromJson(Map<String, Object?>.from(weights));
    }
    return EngineWeightConfig.global;
  }

  /// Wie [weightsFromModel], aber engine-übergreifend: erkennt an
  /// `weights.engineVersion`, welche Formel ein Model tatsächlich verwendet
  /// - attackWeight-Blend, GLOBAL_GOALS_V1, oder eine `GlobalMarketEngine`-
  /// Familie (optional mit Hypothesis). WICHTIG seit Section 59 (Claude
  /// AN2.txt): globale Champions sind NICHT mehr zwingend attackWeight-
  /// basiert - `activateGlobalMarketChampion` aktiviert `GlobalMarketEngine`-
  /// Champions. Jeder Vergleich, der einen Champion liest (Learning Run,
  /// Monthly Review, produktive Simulation), muss deshalb diese Methode
  /// verwenden statt [weightsFromModel] direkt.
  ModelEngine modelEngine(Map<String, Object?> model) {
    final weights = model['weights'];
    if (weights is Map) {
      final engineVersion = weights['engineVersion'];
      if (engineVersion == GlobalGoalsV1Engine.version) {
        return const ModelEngine.globalGoalsV1();
      }
      for (final family in GlobalMarketFamily.values) {
        if (engineVersion != family.version) continue;
        final hypothesisKey = weights['hypothesis']?.toString();
        GlobalMarketHypothesis? hypothesis;
        if (hypothesisKey != null) {
          for (final h in GlobalMarketHypothesis.values) {
            if (h.key == hypothesisKey) {
              hypothesis = h;
              break;
            }
          }
        }
        return ModelEngine.globalMarket(family, hypothesis: hypothesis);
      }
    }
    return ModelEngine.attackWeightBlend(weightsFromModel(model));
  }

  /// Erzeugt (oder findet die bereits existierende) GLOBAL_GOALS_V1-
  /// Challenger-Version für eine Liga x Markt-Kombination. Anders als
  /// [createOrReuseChallenger] gibt es hier keinen Gewichts-Suchraum und
  /// keine Sample-Size-Shrinkage: GLOBAL_GOALS_V1 hat keinen einzelnen
  /// freien Parameter, den man Richtung Global-Gewicht "einziehen" könnte -
  /// fehlende Eingaben werden bereits pro Spiel durch die eigene
  /// Renormalisierung abgefedert (siehe `feature_renormalization.dart`).
  /// Pro Liga x Markt kann es deshalb konzeptionell nur GENAU einen solchen
  /// Challenger geben (der konstante `configHash` erzwingt das über den
  /// bestehenden Unique-Index).
  Future<({int id, ModelEngine engine})> createOrReuseGlobalGoalsV1Challenger({
    required String? leagueId,
    required String market,
    required int generation,
    required int challengerIndex,
    required int sampleSize,
    required int parentModelId,
    DateTime? trainingStart,
    DateTime? trainingEnd,
    required int trainingCount,
    required int validationCount,
    required int holdoutCount,
  }) async {
    final readableVersion = 'V$generation-C$challengerIndex-GG1';
    final id = await database.insertModelVersion(
      readableVersion: readableVersion,
      parentModelId: parentModelId,
      generation: generation,
      leagueId: leagueId,
      market: market,
      modelType: 'weight_variant',
      featureConfig: const {
        'features': 'globalGoalsV1',
        'engineFamily': 'weighted_feature_blend_poisson_derived',
      },
      weights: const {'engineVersion': GlobalGoalsV1Engine.version},
      trainingStart: trainingStart,
      trainingEnd: trainingEnd,
      trainingCount: trainingCount,
      validationCount: validationCount,
      holdoutCount: holdoutCount,
      shadowCount: 0,
      status: 'challenger',
      configHash: GlobalGoalsV1Engine.configHash(),
      codeSchemaVersion: codeSchemaVersion,
    );

    await database.insertModelLabAuditLog(
      action: 'challenger_created',
      actor: 'system',
      modelVersionId: id,
      leagueId: leagueId,
      market: market,
      details: {
        'readableVersion': readableVersion,
        'engineVersion': GlobalGoalsV1Engine.version,
        'sampleSize': sampleSize,
      },
    );

    return (id: id, engine: const ModelEngine.globalGoalsV1());
  }

  /// Section 2/3/59 (Claude AN2.txt): archiviert (Status `retired`, NIE
  /// gelöscht - Section 25) den bisherigen globalen Champion eines Marktes
  /// und aktiviert ein `GlobalMarketEngine`-Model (Basis-Preset der
  /// zugehörigen Marktfamilie, keine Hypothesis-Abweichung) als neuen
  /// globalen Champion. Idempotent: ist bereits ein solches Model aktiver
  /// Champion, passiert nichts (Section 12: Modelle nie still verändern -
  /// ein zweiter Aufruf legt kein Duplikat an).
  ///
  /// WICHTIG: dies ist eine bewusste, einmalige Admin-Aktion (Section 59:
  /// "Heute: Neue Global Champions aktivieren"), KEINE durch Learning-Runs
  /// automatisch ausgelöste Promotion - genau deshalb ist sie separat von
  /// der sonst überall gesperrten `promoteModel`-Nutzung (Section 23: keine
  /// automatische Promotion) und wird nur explizit administrativ
  /// angestoßen.
  Future<Map<String, Object?>> activateGlobalMarketChampion(
    LearningMarket market,
  ) async {
    final family = GlobalMarketFamily.forMarket(market);
    final currentChampion = await database.championModel(
      leagueId: null,
      market: market.key,
    );
    final currentWeights = currentChampion?['weights'];
    final alreadyActive = currentWeights is Map &&
        currentWeights['engineVersion'] == family.version &&
        currentWeights['hypothesis'] == null;
    if (alreadyActive) {
      return {
        'status': 'already_active',
        'market': market.key,
        'family': family.version,
        'modelVersionId': currentChampion!['id'],
      };
    }

    final previousChampionId = currentChampion?['id'] as int?;
    final generation = await nextGeneration(leagueId: null, market: market.key);
    final engine = ModelEngine.globalMarket(family);
    final readableVersion = 'V$generation';

    final newChampionId = await database.insertModelVersion(
      readableVersion: readableVersion,
      parentModelId: previousChampionId,
      generation: generation,
      leagueId: null,
      market: market.key,
      modelType: 'global_baseline',
      featureConfig: {
        'features': 'globalMarketEngine',
        'family': family.version,
        'market': market.key,
        'note': 'Globaler Basis-Champion (Claude AN2.txt) - echte, gewichtete '
            'Features statt fester 50/50-Formel. xG/Rating/Motivation '
            'aus der Vorlage entfernt (in PHÖNIX nicht real verfügbar), '
            'verbleibende echte Kategorien proportional neu normiert.',
      },
      weights: engine.toJson(),
      trainingCount: 0,
      validationCount: 0,
      holdoutCount: 0,
      shadowCount: 0,
      status: 'challenger',
      configHash: GlobalMarketEngine.configHash(family: family),
      codeSchemaVersion: codeSchemaVersion,
    );

    await database.promoteModel(
      newChampionId: newChampionId,
      previousChampionId: previousChampionId,
    );

    await database.insertModelLabAuditLog(
      action: 'global_champion_activated',
      actor: 'admin',
      modelVersionId: newChampionId,
      market: market.key,
      details: {
        'family': family.version,
        'readableVersion': readableVersion,
        'previousChampionId': previousChampionId,
        'previousChampionArchived': previousChampionId != null,
      },
    );

    return {
      'status': 'activated',
      'market': market.key,
      'family': family.version,
      'modelVersionId': newChampionId,
      'previousChampionId': previousChampionId,
    };
  }

  /// Erzeugt (oder findet die bereits existierende) `GlobalMarketEngine`-
  /// Challenger-Version für eine Liga x Markt-Kombination und optionale
  /// benannte Hypothesis (siehe `GlobalMarketHypothesis`, Section 10-12).
  /// `hypothesis: null` würde denselben Konfigurations-Hash wie der
  /// gerade aktivierte globale Champion selbst ergeben - deshalb nur mit
  /// gesetzter Hypothesis aufrufen (der Champion braucht keinen eigenen
  /// Challenger auf sich selbst).
  Future<({int id, ModelEngine engine})> createOrReuseGlobalMarketChallenger({
    required String? leagueId,
    required LearningMarket market,
    required GlobalMarketHypothesis hypothesis,
    required int generation,
    required int challengerIndex,
    required int sampleSize,
    required int parentModelId,
    DateTime? trainingStart,
    DateTime? trainingEnd,
    required int trainingCount,
    required int validationCount,
    required int holdoutCount,
  }) async {
    final family = GlobalMarketFamily.forMarket(market);
    final readableVersion = 'V$generation-C$challengerIndex-${hypothesis.key}';
    final id = await database.insertModelVersion(
      readableVersion: readableVersion,
      parentModelId: parentModelId,
      generation: generation,
      leagueId: leagueId,
      market: market.key,
      modelType: 'weight_variant',
      featureConfig: {
        'features': 'globalMarketEngine',
        'family': family.version,
        'hypothesis': hypothesis.key,
        'hypothesisLabel': hypothesis.label,
      },
      weights:
          ModelEngine.globalMarket(family, hypothesis: hypothesis).toJson(),
      trainingStart: trainingStart,
      trainingEnd: trainingEnd,
      trainingCount: trainingCount,
      validationCount: validationCount,
      holdoutCount: holdoutCount,
      shadowCount: 0,
      status: 'challenger',
      configHash:
          GlobalMarketEngine.configHash(family: family, hypothesis: hypothesis),
      codeSchemaVersion: codeSchemaVersion,
    );

    await database.insertModelLabAuditLog(
      action: 'challenger_created',
      actor: 'system',
      modelVersionId: id,
      leagueId: leagueId,
      market: market.key,
      details: {
        'readableVersion': readableVersion,
        'engineVersion': family.version,
        'hypothesis': hypothesis.key,
        'sampleSize': sampleSize,
      },
    );

    return (
      id: id,
      engine: ModelEngine.globalMarket(family, hypothesis: hypothesis)
    );
  }

  /// Erzeugt (oder findet die bereits existierende) Dixon-Coles-Challenger-
  /// Version für eine Liga x Markt-Kombination und einen benannten
  /// `rho`-Wert (siehe `DixonColesEngine.rhoCandidates`). Nutzt exakt
  /// dieselben Torerwartungen wie der globale Champion (attackWeight 0.5) -
  /// `rho` ist die einzige Testvariable (Section 4, Claude AN2.txt).
  Future<({int id, ModelEngine engine})> createOrReuseDixonColesChallenger({
    required String? leagueId,
    required LearningMarket market,
    required double rho,
    required int generation,
    required int challengerIndex,
    required int sampleSize,
    required int parentModelId,
    DateTime? trainingStart,
    DateTime? trainingEnd,
    required int trainingCount,
    required int validationCount,
    required int holdoutCount,
  }) async {
    final engine = ModelEngine.dixonColes(rho);
    final readableVersion =
        'V$generation-C$challengerIndex-DC${rho.toStringAsFixed(2)}';
    final id = await database.insertModelVersion(
      readableVersion: readableVersion,
      parentModelId: parentModelId,
      generation: generation,
      leagueId: leagueId,
      market: market.key,
      modelType: 'weight_variant',
      featureConfig: {
        'features': 'attackWeightBlend',
        'engineFamily': DixonColesEngine.version,
        'rho': rho,
        'note':
            'Dixon-Coles-Korrelationsausgleich fuer niedrige Ergebnisse, dieselben Torerwartungen wie der globale Champion.',
      },
      weights: engine.toJson(),
      trainingStart: trainingStart,
      trainingEnd: trainingEnd,
      trainingCount: trainingCount,
      validationCount: validationCount,
      holdoutCount: holdoutCount,
      shadowCount: 0,
      status: 'challenger',
      configHash: DixonColesEngine.configHash(rho),
      codeSchemaVersion: codeSchemaVersion,
    );

    await database.insertModelLabAuditLog(
      action: 'challenger_created',
      actor: 'system',
      modelVersionId: id,
      leagueId: leagueId,
      market: market.key,
      details: {
        'readableVersion': readableVersion,
        'engineVersion': DixonColesEngine.version,
        'rho': rho,
        'sampleSize': sampleSize,
      },
    );

    return (id: id, engine: engine);
  }

  /// Erzeugt (oder findet die bereits existierende) Team-Stärke-Challenger-
  /// Version für eine Liga x Markt-Kombination aus einem VORHER (einmal pro
  /// Liga) gefitteten [TeamStrengthFit] (siehe `TeamStrengthEngine.fit`,
  /// `learning_run_service.dart` fittet einmal pro Liga und nutzt denselben
  /// Fit über alle Märkte hinweg wieder). Live gegen PHÖNIX-Daten getestet
  /// (Plan "wild-cuddling-hoare", Phase 2): auf 9 Ligen deutlich besser als
  /// der einfache Durchschnitt (Ø Brier -7,3%), aber weiterhin reiner
  /// Model-Lab-Schatten-Challenger - keine automatische Beförderung.
  Future<({int id, ModelEngine engine})> createOrReuseTeamStrengthChallenger({
    required String? leagueId,
    required LearningMarket market,
    required TeamStrengthFit fit,
    double? halfLifeDays,
    required int generation,
    required int challengerIndex,
    required int sampleSize,
    required int parentModelId,
    DateTime? trainingStart,
    DateTime? trainingEnd,
    required int trainingCount,
    required int validationCount,
    required int holdoutCount,
  }) async {
    final engine = ModelEngine.teamStrength(fit);
    final readableVersion = halfLifeDays == null
        ? 'V$generation-C$challengerIndex-TS'
        : 'V$generation-C$challengerIndex-TS-HL${halfLifeDays.toStringAsFixed(0)}';
    final id = await database.insertModelVersion(
      readableVersion: readableVersion,
      parentModelId: parentModelId,
      generation: generation,
      leagueId: leagueId,
      market: market.key,
      modelType: 'weight_variant',
      featureConfig: {
        'features': 'teamStrength',
        'engineFamily': TeamStrengthEngine.version,
        'halfLifeDays': halfLifeDays,
        'fitTeamCount': fit.attack.length,
        'fitConverged': fit.converged,
        'fitIterations': fit.iterations,
        'note':
            'IPF-Angriff/Abwehr-Team-Rating (Maher-Modell), einmal pro Liga aus der Trainingshistorie gefittet, ueber alle Maerkte wiederverwendet.',
      },
      weights: engine.toJson(),
      trainingStart: trainingStart,
      trainingEnd: trainingEnd,
      trainingCount: trainingCount,
      validationCount: validationCount,
      holdoutCount: holdoutCount,
      shadowCount: 0,
      status: 'challenger',
      configHash: fit.configHash(),
      codeSchemaVersion: codeSchemaVersion,
    );

    await database.insertModelLabAuditLog(
      action: 'challenger_created',
      actor: 'system',
      modelVersionId: id,
      leagueId: leagueId,
      market: market.key,
      details: {
        'readableVersion': readableVersion,
        'engineVersion': TeamStrengthEngine.version,
        'halfLifeDays': halfLifeDays,
        'fitTeamCount': fit.attack.length,
        'fitConverged': fit.converged,
        'sampleSize': sampleSize,
      },
    );

    return (id: id, engine: engine);
  }

  /// Eine vollständige Liga-Engine statt eines getrennten Modells je Markt.
  /// Sie darf erst nach einem Vergleich gegen [matchDistributionMarket] für
  /// ihre eigene Liga befördert werden.
  Future<({int id, ModelEngine engine})> createOrReuseLeagueEngineChallenger({
    required String leagueId,
    required TeamStrengthFit fit,
    required double? halfLifeDays,
    required int generation,
    required int challengerIndex,
    required int sampleSize,
    required int parentModelId,
    DateTime? trainingStart,
    DateTime? trainingEnd,
    required int trainingCount,
    required int validationCount,
    required int holdoutCount,
  }) async {
    final engine = ModelEngine.teamStrength(fit);
    final readableVersion = 'L$leagueId-V$generation-C$challengerIndex-TS'
        '${halfLifeDays == null ? '' : '-HL${halfLifeDays.toStringAsFixed(0)}'}';
    final id = await database.insertModelVersion(
      readableVersion: readableVersion,
      parentModelId: parentModelId,
      generation: generation,
      leagueId: leagueId,
      market: matchDistributionMarket,
      modelType: 'weight_variant',
      featureConfig: {
        'engineFamily': TeamStrengthEngine.version,
        'scope': 'complete_league_match_distribution',
        'halfLifeDays': halfLifeDays,
        'fitTeamCount': fit.attack.length,
        'fitConverged': fit.converged,
        'fitIterations': fit.iterations,
        'note':
            'Liga-Challenger gegen PHOENIX_GLOBAL_ENGINE_V1. Eine Torverteilung für alle Märkte, niemals marktweise überschrieben.',
      },
      weights: engine.toJson(),
      trainingStart: trainingStart,
      trainingEnd: trainingEnd,
      trainingCount: trainingCount,
      validationCount: validationCount,
      holdoutCount: holdoutCount,
      shadowCount: 0,
      status: 'challenger',
      configHash: 'league_distribution|${fit.configHash()}|$halfLifeDays',
      codeSchemaVersion: codeSchemaVersion,
    );
    await database.insertModelLabAuditLog(
      action: 'league_engine_challenger_created',
      actor: 'system',
      modelVersionId: id,
      leagueId: leagueId,
      market: matchDistributionMarket,
      details: {
        'readableVersion': readableVersion,
        'engineVersion': TeamStrengthEngine.version,
        'sampleSize': sampleSize,
        'halfLifeDays': halfLifeDays,
      },
    );
    return (id: id, engine: engine);
  }
}
