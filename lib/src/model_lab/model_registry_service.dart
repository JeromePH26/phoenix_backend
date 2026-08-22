import '../config/model_lab_config.dart';
import '../database/database.dart';
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
}
