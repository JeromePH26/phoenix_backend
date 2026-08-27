import 'dart:math';

import '../config/model_lab_config.dart';
import '../database/database.dart';
import '../model_lab/engine_replica.dart';
import '../model_lab/feature_whitelist.dart';
import '../model_lab/learning_market.dart';
import '../model_lab/model_registry_service.dart';

class FootballSimulationService {
  FootballSimulationService({required this.database});

  final PhoenixDatabase database;

  static const modelVersion = 'poisson_monte_carlo_v7_team_goal_lines';

  Future<Map<String, Object?>> run({
    required int phaseTwoScanRunId,
    int? limit,
    int simulations = 100000,
  }) async {
    final safeSimulations = simulations.clamp(1000, 100000);

    final rows = await database.engineInputsForSimulation(
      phaseTwoScanRunId: phaseTwoScanRunId,
      limit: limit ?? 1000000,
    );
    final modelRegistry = ModelRegistryService(
      database: database,
      config: ModelLabConfig.fromEnvironment(),
    );
    final leagueIds = rows
        .map((row) {
          final input = _map(row['normalized_input']);
          return _string(input['leagueId'] ?? row['league_id']);
        })
        .where((leagueId) => leagueId.isNotEmpty)
        .toSet()
        .toList(growable: false);
    // Alle aktiven Liga-Champions werden in EINEM Query geladen. Ohne dieses
    // Batch-Lookup wären bei 30 Ligen und 17 Märkten über 500 synchrone
    // Datenbank-Roundtrips pro Tages-Scan nötig.
    final championBatch =
        await modelRegistry.currentChampionsAndChallengersBatch(
      leagueIds: leagueIds,
      markets: [for (final market in LearningMarket.values) market.key],
    );
    final appliedModelsByLeague = <String, _AppliedMarketModels>{};

    final outputs = <Map<String, Object?>>[];

    for (final row in rows) {
      final fixtureId = _string(row['fixture_id']);
      final input = _map(row['normalized_input']);
      final normalized = _map(input['normalized']);

      final homeLambda = _number(normalized['goalRateExpectedHome']);
      final awayLambda = _number(normalized['goalRateExpectedAway']);

      if (homeLambda == null || awayLambda == null) {
        outputs.add({
          'fixtureId': fixtureId,
          'status': 'skipped',
          'reason': 'goal_expectation_missing',
        });
        continue;
      }

      final leagueId = _string(input['leagueId'] ?? row['league_id']);
      final activeModels = leagueId.isEmpty
          ? const _AppliedMarketModels.empty()
          : await _resolveLeagueChampionModels(
              leagueId: leagueId,
              input: input,
              registry: modelRegistry,
              cache: appliedModelsByLeague,
              championsByLeagueMarket: championBatch.champions,
            );

      final result = _simulate(
        input: input,
        homeLambda: homeLambda.clamp(0.05, 5.0).toDouble(),
        awayLambda: awayLambda.clamp(0.05, 5.0).toDouble(),
        simulations: safeSimulations,
        activeModels: activeModels,
      );

      await database.saveFootballSimulationResult(
        phaseTwoScanRunId: phaseTwoScanRunId,
        fixtureId: fixtureId,
        modelVersion: modelVersion,
        simulations: safeSimulations,
        result: result,
      );

      outputs.add(result);
    }

    return {
      'status': 'completed',
      'phaseTwoScanRunId': phaseTwoScanRunId,
      'modelVersion': modelVersion,
      'simulationsPerMatch': safeSimulations,
      'processed': outputs.length,
      'results': outputs,
    };
  }

  Map<String, Object?> _simulate({
    required Map<String, Object?> input,
    required double homeLambda,
    required double awayLambda,
    required int simulations,
    required _AppliedMarketModels activeModels,
  }) {
    final fixtureId = _string(input['fixtureId']);
    final random = Random(_stableSeed(fixtureId, simulations));

    var homeWins = 0;
    var draws = 0;
    var awayWins = 0;
    var over25 = 0;
    var under25 = 0;
    var bttsYes = 0;
    var bttsNo = 0;
    final extendedCounts = <String, int>{};

    void hit(String key, bool condition) {
      if (condition) extendedCounts[key] = (extendedCounts[key] ?? 0) + 1;
    }

    final scoreCounts = <String, int>{};

    for (var i = 0; i < simulations; i++) {
      final homeGoals = _samplePoisson(homeLambda, random);
      final awayGoals = _samplePoisson(awayLambda, random);

      if (homeGoals > awayGoals) {
        homeWins++;
      } else if (homeGoals == awayGoals) {
        draws++;
      } else {
        awayWins++;
      }

      if (homeGoals + awayGoals >= 3) {
        over25++;
      } else {
        under25++;
      }

      if (homeGoals > 0 && awayGoals > 0) {
        bttsYes++;
      } else {
        bttsNo++;
      }

      final total = homeGoals + awayGoals;
      final homeWin = homeGoals > awayGoals;
      final draw = homeGoals == awayGoals;
      final awayWin = homeGoals < awayGoals;
      hit('over05', total >= 1);
      hit('under05', total == 0);
      hit('over15', total >= 2);
      hit('under15', total <= 1);
      hit('over35', total >= 4);
      hit('under35', total <= 3);
      hit('over45', total >= 5);
      hit('under45', total <= 4);
      hit('over55', total >= 6);
      hit('under55', total <= 5);
      hit('dc1x', homeWin || draw);
      hit('dc12', homeWin || awayWin);
      hit('dcX2', draw || awayWin);
      hit('dnbHome', homeWin);
      hit('dnbAway', awayWin);
      // Teamtore sind eine konkrete Alternative zu pauschalen Gesamtmärkten.
      // 0,5-Linien bleiben bewusst ausgeschlossen, weil sie fast immer nur
      // nichtssagende Niedrigquoten erzeugen.
      hit('homeOver15', homeGoals >= 2);
      hit('homeUnder15', homeGoals <= 1);
      hit('awayOver15', awayGoals >= 2);
      hit('awayUnder15', awayGoals <= 1);
      hit('homeOver25', homeGoals >= 3);
      hit('homeUnder25', homeGoals <= 2);
      hit('awayOver25', awayGoals >= 3);
      hit('awayUnder25', awayGoals <= 2);
      final goalDifference = homeGoals - awayGoals;
      // Europäisches Handicap ist ein Dreiweg-Markt. Für jede Linie sind
      // Heimsieg, Handicap-Remis und Auswärtssieg getrennte Quotenausgänge.
      hit('ehHomeMinus1', goalDifference >= 2);
      hit('ehDrawMinus1', goalDifference == 1);
      hit('ehAwayPlus1', goalDifference <= 0);
      hit('ehHomeMinus2', goalDifference >= 3);
      hit('ehDrawMinus2', goalDifference == 2);
      hit('ehAwayPlus2', goalDifference <= 1);
      hit('combo1xUnder35', (homeWin || draw) && total <= 3);
      hit('comboX2Under35', (awayWin || draw) && total <= 3);
      hit('combo1xOver15', (homeWin || draw) && total >= 2);
      hit('comboX2Over15', (awayWin || draw) && total >= 2);
      hit('comboHomeOver15', homeWin && total >= 2);
      hit('comboAwayOver15', awayWin && total >= 2);

      final score = '$homeGoals:$awayGoals';
      scoreCounts[score] = (scoreCounts[score] ?? 0) + 1;
    }

    final topScores = scoreCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final homeWinProbability = homeWins / simulations;
    final drawProbability = draws / simulations;
    final awayWinProbability = awayWins / simulations;
    final over25Probability = over25 / simulations;
    final under25Probability = under25 / simulations;
    final bttsYesProbability = bttsYes / simulations;
    final bttsNoProbability = bttsNo / simulations;
    final extendedProbabilities = <String, double>{
      for (final entry in extendedCounts.entries)
        entry.key: entry.value / simulations,
    };
    // A Draw-No-Bet wager is void on a draw. Its quoted win probability and
    // fair odds must therefore be conditional on the match not finishing
    // level, rather than using the raw 1X2 win probability.
    final noDrawProbability = homeWinProbability + awayWinProbability;
    extendedProbabilities['dnbHome'] =
        noDrawProbability > 0 ? homeWinProbability / noDrawProbability : 0;
    extendedProbabilities['dnbAway'] =
        noDrawProbability > 0 ? awayWinProbability / noDrawProbability : 0;

    final aiContext = _map(input['aiContext']);
    final normalized = _map(input['normalized']);
    double learned(String key, double baseline) =>
        activeModels.probabilities[key] ?? baseline;

    final activeHome = learned('home', homeWinProbability);
    final activeDraw = learned('draw', drawProbability);
    final activeAway = learned('away', awayWinProbability);
    final activeOver25 = learned('over25', over25Probability);
    final activeUnder25 = learned('under25', under25Probability);
    final activeBttsYes = learned('bttsYes', bttsYesProbability);
    final activeBttsNo = learned('bttsNo', bttsNoProbability);
    for (final entry in activeModels.probabilities.entries) {
      extendedProbabilities[entry.key] = entry.value;
    }

    return {
      'fixtureId': fixtureId,
      'homeTeam': _string(input['homeTeam']),
      'awayTeam': _string(input['awayTeam']),
      'league': _string(input['league']),
      'kickoff': _string(input['kickoff']),
      'modelVersion': modelVersion,
      'dataQuality': _int(input['dataQuality']),
      'simulations': simulations,
      'goalExpectations': {
        'home': _round(homeLambda),
        'away': _round(awayLambda),
        'total': _round(homeLambda + awayLambda),
        'baseHome': normalized['baseGoalRateExpectedHome'],
        'baseAway': normalized['baseGoalRateExpectedAway'],
        'contextAdjusted': normalized['contextAdjusted'] == true,
        'sourceType': input['sourceType'],
        'realXgAvailable': input['realXgAvailable'] == true,
      },
      'modelLab': {
        'applied': activeModels.models.isNotEmpty,
        'marketModels': activeModels.models,
        'note': activeModels.models.isEmpty
            ? 'Kein liga-spezifischer Champion aktiv; statistische Global-Basis verwendet.'
            : 'Aktive Liga-Champions wurden marktweise auf den gespeicherten Pre-Match-Input angewendet.',
      },
      'probabilities': {
        'home': _probability(activeHome),
        'draw': _probability(activeDraw),
        'away': _probability(activeAway),
        'homeWin': _probability(activeHome),
        'awayWin': _probability(activeAway),
        'over25': _probability(activeOver25),
        'under25': _probability(activeUnder25),
        'bttsYes': _probability(activeBttsYes),
        'bttsNo': _probability(activeBttsNo),
        for (final entry in extendedProbabilities.entries)
          entry.key: _probability(entry.value),
      },
      'probabilitiesPercent': {
        'home': _percent(activeHome),
        'draw': _percent(activeDraw),
        'away': _percent(activeAway),
        'over25': _percent(activeOver25),
        'under25': _percent(activeUnder25),
        'bttsYes': _percent(activeBttsYes),
        'bttsNo': _percent(activeBttsNo),
        for (final entry in extendedProbabilities.entries)
          entry.key: _percent(entry.value),
      },
      'fairOdds': {
        'home': _fairOdds(activeHome),
        'draw': _fairOdds(activeDraw),
        'away': _fairOdds(activeAway),
        'homeWin': _fairOdds(activeHome),
        'awayWin': _fairOdds(activeAway),
        'over25': _fairOdds(activeOver25),
        'under25': _fairOdds(activeUnder25),
        'bttsYes': _fairOdds(activeBttsYes),
        'bttsNo': _fairOdds(activeBttsNo),
        for (final entry in extendedProbabilities.entries)
          entry.key: _fairOdds(entry.value),
      },
      'topScorelines': topScores.take(5).map((entry) {
        final probability = entry.value / simulations;
        return {
          'score': entry.key,
          'count': entry.value,
          'probability': _probability(probability),
          'probabilityPercent': _percent(probability),
        };
      }).toList(),
      'aiContext': aiContext,
      // Section 10 (Claude AN2.txt, "KEIN GEMINI"): der KI-Kontext-Schritt ist
      // fuer Fussball bewusst nie verdrahtet (siehe
      // football_daily_pipeline_service.dart), `aiContext` bleibt strukturell
      // immer leer. Kein Warnhinweis mehr dafuer - sein Fehlen ist der
      // dauerhafte Normalzustand, kein Fehler.
      'warnings': [
        if (input['realXgAvailable'] != true)
          'Simulation basiert noch auf Torquoten, nicht auf echtem xG/xGA.',
        if (activeModels.models.isNotEmpty)
          'Liga-spezifische Champion-Modelle wurden marktweise angewendet.',
      ],
    };
  }

  Future<_AppliedMarketModels> _resolveLeagueChampionModels({
    required String leagueId,
    required Map<String, Object?> input,
    required ModelRegistryService registry,
    required Map<String, _AppliedMarketModels> cache,
    required Map<String, Map<String, Object?>> championsByLeagueMarket,
  }) async {
    final cached = cache[leagueId];
    if (cached != null) return cached;

    final features = FeatureWhitelist.extract(input);
    final probabilities = <String, double>{};
    final models = <String, Object?>{};

    for (final market in LearningMarket.values) {
      // Nur ein tatsächlich beförderter Liga-Champion verändert künftige
      // Vorhersagen. Die globale 50/50-Basis bleibt exakt die bisherige
      // Produktionsformel und wird nicht als angeblich neue Erkenntnis
      // ausgegeben.
      final champion = championsByLeagueMarket[
          ModelRegistryService.leagueMarketKey(leagueId, market.key)];
      if (champion == null) continue;

      // Section 59 (Claude AN2.txt): globale Champions können inzwischen
      // GlobalMarketEngine-basiert sein (H2H/Form/Tabelle statt fest 50/50),
      // die dafür nötigen Live-Rohdaten (Phase-2-Snapshot mit H2H/Standings)
      // werden an dieser Stelle der produktiven Analyse-Pipeline aber noch
      // nicht mitgeführt. `weightsFromModel` würde ein solches Model
      // stillschweigend als attackWeight=0.5 fehlinterpretieren statt seine
      // echte Formel zu nutzen - lieber ehrlich überspringen (identisch zum
      // "kein Champion"-Fall) als eine falsche Zahl unter dem Namen dieses
      // Champions veröffentlichen. Betrifft heute nur eine hypothetische
      // künftige Liga-Promotion (Promotion ist serverseitig blockiert,
      // aktuell hat keine Liga einen eigenen Champion).
      final championWeights = champion['weights'];
      if (championWeights is Map && championWeights['engineVersion'] != null) {
        continue;
      }

      final output = EngineReplica.evaluate(
        market: market,
        features: features,
        weights: registry.weightsFromModel(champion),
      );
      _mergeLearnedProbabilities(
        probabilities: probabilities,
        market: market,
        classProbabilities: output.classProbabilities,
        classLabels: output.classLabels,
      );
      final weights = registry.weightsFromModel(champion);
      models[market.key] = {
        'modelVersionId': champion['id'],
        'readableVersion': champion['readable_version'],
        'attackWeight': _round(weights.attackWeight),
        'defenseWeight': _round(weights.defenseWeight),
      };
    }

    final resolved = _AppliedMarketModels(
      probabilities: probabilities,
      models: models,
    );
    cache[leagueId] = resolved;
    return resolved;
  }

  void _mergeLearnedProbabilities({
    required Map<String, double> probabilities,
    required LearningMarket market,
    required List<double> classProbabilities,
    required List<String> classLabels,
  }) {
    double value(int index) => index < classProbabilities.length
        ? classProbabilities[index].clamp(0.0, 1.0).toDouble()
        : 0.0;

    switch (market) {
      case LearningMarket.oneXTwo:
        probabilities['home'] = value(0);
        probabilities['draw'] = value(1);
        probabilities['away'] = value(2);
        return;
      case LearningMarket.drawNoBetHome:
        // EngineReplica liefert Draw No Bet seit 2026-08-27 als 2 Klassen
        // [Gewinn, Verlust], bereits bedingt auf "kein Remis".
        probabilities['dnbHome'] = value(0);
        return;
      case LearningMarket.drawNoBetAway:
        probabilities['dnbAway'] = value(0);
        return;
      default:
        for (var index = 0; index < classLabels.length; index++) {
          probabilities[classLabels[index]] = value(index);
        }
        return;
    }
  }

  int _samplePoisson(double lambda, Random random) {
    final limit = exp(-lambda);
    var product = 1.0;
    var k = 0;

    do {
      k++;
      product *= random.nextDouble();
    } while (product > limit && k < 20);

    return k - 1;
  }

  int _stableSeed(String fixtureId, int simulations) {
    var hash = 17;
    for (final unit in fixtureId.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return (hash + simulations) & 0x7fffffff;
  }

  double? _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  }

  double _probability(double value) =>
      double.parse(value.clamp(0.0, 1.0).toStringAsFixed(6));

  double _percent(double value) =>
      double.parse((value.clamp(0.0, 1.0) * 100).toStringAsFixed(2));

  double? _fairOdds(double probability) {
    if (probability <= 0) return null;
    return double.parse((1 / probability).toStringAsFixed(2));
  }

  double _round(double value) => double.parse(value.toStringAsFixed(3));

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  String _string(Object? value) => value?.toString().trim() ?? '';

  int _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class _AppliedMarketModels {
  const _AppliedMarketModels({
    required this.probabilities,
    required this.models,
  });

  const _AppliedMarketModels.empty()
      : probabilities = const {},
        models = const {};

  final Map<String, double> probabilities;
  final Map<String, Object?> models;
}
