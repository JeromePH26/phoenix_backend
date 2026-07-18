import '../database/database.dart';

class FootballMarketSelectionService {
  FootballMarketSelectionService({required this.database});

  final PhoenixDatabase database;

  static const modelVersion = 'market_selection_trust_v2_decimal';

  Future<Map<String, Object?>> select({
    required int phaseTwoScanRunId,
    int limit = 20,
    double minimumProbability = 0,
  }) async {
    final rows = await database.simulationRowsForSelection(
      phaseTwoScanRunId: phaseTwoScanRunId,
      limit: limit.clamp(1, 20),
    );

    final outputs = <Map<String, Object?>>[];
    final minimumProbabilityDecimal =
        minimumProbability > 1 ? minimumProbability / 100 : minimumProbability;

    for (final row in rows) {
      final fixtureId = _string(row['fixture_id']);
      final simulation = _map(row['result']);
      final probabilities = _map(simulation['probabilities']);
      final fairOdds = _map(simulation['fairOdds']);
      final goalExpectations = _map(simulation['goalExpectations']);
      final aiContext = _map(simulation['aiContext']);

      final candidates = <Map<String, Object?>>[
        _candidate(
          key: 'homeWin',
          label: 'Heimsieg',
          probability: probabilities['homeWin'] ?? probabilities['home'],
          fairOdds: fairOdds['homeWin'] ?? fairOdds['home'],
        ),
        _candidate(
          key: 'draw',
          label: 'Unentschieden',
          probability: probabilities['draw'],
          fairOdds: fairOdds['draw'],
        ),
        _candidate(
          key: 'awayWin',
          label: 'Auswärtssieg',
          probability: probabilities['awayWin'] ?? probabilities['away'],
          fairOdds: fairOdds['awayWin'] ?? fairOdds['away'],
        ),
        _candidate(
          key: 'over25',
          label: 'Über 2,5 Tore',
          probability: probabilities['over25'],
          fairOdds: fairOdds['over25'],
        ),
        _candidate(
          key: 'under25',
          label: 'Unter 2,5 Tore',
          probability: probabilities['under25'],
          fairOdds: fairOdds['under25'],
        ),
        _candidate(
          key: 'bttsYes',
          label: 'Beide Teams treffen – Ja',
          probability: probabilities['bttsYes'],
          fairOdds: fairOdds['bttsYes'],
        ),
        _candidate(
          key: 'bttsNo',
          label: 'Beide Teams treffen – Nein',
          probability: probabilities['bttsNo'],
          fairOdds: fairOdds['bttsNo'],
        ),
      ];

      candidates.sort((a, b) {
        final pA = _number(a['probability']) ?? 0;
        final pB = _number(b['probability']) ?? 0;
        return pB.compareTo(pA);
      });

      final best = candidates.first;
      final second = candidates.length > 1 ? candidates[1] : candidates.first;

      final bestProbability = _asProbability(best['probability']);
      final secondProbability = _asProbability(second['probability']);
      final probabilityGap =
          (bestProbability - secondProbability).clamp(0.0, 1.0).toDouble();

      final bestProbabilityPercent = bestProbability * 100;
      final probabilityGapPercent = probabilityGap * 100;

      final dataQuality = _int(simulation['dataQuality'], fallback: 0);
      final realXgAvailable = goalExpectations['realXgAvailable'] == true;
      final simulations =
          _int(simulation['simulations'], fallback: 100000);

      final trustScore = _trustScore(
        bestProbabilityPercent: bestProbabilityPercent,
        probabilityGapPercent: probabilityGapPercent,
        dataQuality: dataQuality,
        simulations: simulations,
        realXgAvailable: realXgAvailable,
      );

      final qualifiesForTip =
          bestProbability >= minimumProbabilityDecimal.clamp(0.0, 1.0);

      final selection = <String, Object?>{
        'fixtureId': fixtureId,
        'homeTeam': simulation['homeTeam'],
        'awayTeam': simulation['awayTeam'],
        'league': simulation['league'],
        'kickoff': simulation['kickoff'],
        'modelVersion': modelVersion,
        'qualifiesForTip': qualifiesForTip,
        'phoenixTip': {
          'marketKey': best['key'],
          'market': best['label'],
          'probability': _roundProbability(bestProbability),
          'probabilityPercent': _round(bestProbabilityPercent),
          'fairOdds': best['fairOdds'],
        },
        'trust': {
          'score': trustScore,
          'label': _trustLabel(trustScore),
          'components': {
            'modelProbability': _roundProbability(bestProbability),
            'modelProbabilityPercent': _round(bestProbabilityPercent),
            'probabilityGapToSecondMarket':
                _roundProbability(probabilityGap),
            'probabilityGapPercent': _round(probabilityGapPercent),
            'dataQuality': dataQuality,
            'simulationCount': simulations,
            'realXgAvailable': realXgAvailable,
            'lineupConfirmed':
                aiContext['lineupStatus'] == 'confirmed',
            'aiContextVerified': aiContext['applied'] == true,
          },
        },
        'topMarkets': candidates.take(3).toList(),
        'aiContext': aiContext,
        'value': {
          'status': 'not_checked',
          'marketOdds': null,
          'minimumMarketOdds': 1.40,
          'minimumValuePercent': 5.0,
          'valuePercent': null,
          'isValueTip': false,
          'reason':
              'Die Buchmacherquote wurde noch nicht mit der fairen Quote verglichen.',
        },
        'display': {
          'primaryLabel': 'PHÖNIX-TIPP',
          'valueLabel': 'VALUE-TIPP',
          'showPhoenixTip': true,
          'showValueTip': false,
        },
        'warnings': [
          if (!realXgAvailable)
            'Noch keine echten xG/xGA-Daten vorhanden.',
          if (aiContext['lineupStatus'] != 'confirmed')
            'Bestätigte Aufstellung ist noch nicht verfügbar.',
          if (aiContext['applied'] == true)
            'Gemini-Kontext wurde bereits vor der Simulation angewendet.',
          if (aiContext['applied'] != true)
            'Kein verifizierter Gemini-Kontext angewendet.',
          if (aiContext['fallbackUsed'] == true)
            'Verifizierter Kontext-Fallback wurde verwendet.',
        ],
      };

      await database.saveFootballMarketSelection(
        phaseTwoScanRunId: phaseTwoScanRunId,
        fixtureId: fixtureId,
        modelVersion: modelVersion,
        selection: selection,
      );

      outputs.add(selection);
    }

    return {
      'status': 'completed',
      'phaseTwoScanRunId': phaseTwoScanRunId,
      'modelVersion': modelVersion,
      'processed': outputs.length,
      'results': outputs,
    };
  }

  Map<String, Object?> _candidate({
    required String key,
    required String label,
    required Object? probability,
    required Object? fairOdds,
  }) {
    final normalizedProbability = _asProbability(probability);
    final parsedFairOdds = _number(fairOdds) ??
        (normalizedProbability > 0 ? 1 / normalizedProbability : null);

    return {
      'key': key,
      'label': label,
      'probability': _roundProbability(normalizedProbability),
      'probabilityPercent': _round(normalizedProbability * 100),
      'fairOdds': parsedFairOdds == null
          ? null
          : double.parse(parsedFairOdds.toStringAsFixed(2)),
    };
  }

  int _trustScore({
    required double bestProbabilityPercent,
    required double probabilityGapPercent,
    required int dataQuality,
    required int simulations,
    required bool realXgAvailable,
  }) {
    final probabilityComponent =
        (bestProbabilityPercent.clamp(0, 100) / 100) * 35;

    final gapComponent =
        (probabilityGapPercent.clamp(0, 25) / 25) * 20;

    final dataQualityComponent =
        (dataQuality.clamp(0, 100) / 100) * 30;

    final simulationComponent =
        (simulations.clamp(1000, 100000) / 100000) * 10;

    final xgComponent = realXgAvailable ? 5.0 : 0.0;

    final score = probabilityComponent +
        gapComponent +
        dataQualityComponent +
        simulationComponent +
        xgComponent;

    return score.round().clamp(0, 100);
  }

  String _trustLabel(int score) {
    if (score >= 80) return 'Hohes Vertrauen';
    if (score >= 65) return 'Gutes Vertrauen';
    if (score >= 50) return 'Mittleres Vertrauen';
    return 'Niedriges Vertrauen';
  }

  double _asProbability(Object? value) {
    final number = _number(value) ?? 0;
    if (number > 1) return (number / 100).clamp(0.0, 1.0).toDouble();
    return number.clamp(0.0, 1.0).toDouble();
  }

  double? _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  }

  double _roundProbability(double value) =>
      double.parse(value.toStringAsFixed(6));

  double _round(double value) =>
      double.parse(value.toStringAsFixed(2));

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  String _string(Object? value) => value?.toString().trim() ?? '';

  int _int(Object? value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }
}
