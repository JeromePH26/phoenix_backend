import '../database/database.dart';

class FootballMarketSelectionService {
  FootballMarketSelectionService({required this.database});

  final PhoenixDatabase database;

  static const modelVersion = 'market_selection_trust_v1';

  Future<Map<String, Object?>> select({
    required int phaseTwoScanRunId,
    int limit = 1,
    double minimumProbability = 0,
  }) async {
    final rows = await database.simulationRowsForSelection(
      phaseTwoScanRunId: phaseTwoScanRunId,
      limit: limit,
    );

    final outputs = <Map<String, Object?>>[];

    for (final row in rows) {
      final fixtureId = _string(row['fixture_id']);
      final simulation = _map(row['result']);
      final probabilities = _map(simulation['probabilities']);
      final fairOdds = _map(simulation['fairOdds']);
      final goalExpectations = _map(simulation['goalExpectations']);

      final candidates = <Map<String, Object?>>[
        _candidate(
          key: 'homeWin',
          label: 'Heimsieg',
          probability: probabilities['homeWin'],
          fairOdds: fairOdds['homeWin'],
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
          probability: probabilities['awayWin'],
          fairOdds: fairOdds['awayWin'],
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

      final bestProbability = _number(best['probability']) ?? 0;
      final secondProbability = _number(second['probability']) ?? 0;
      final probabilityGap = (bestProbability - secondProbability).clamp(0, 100);

      final dataQuality = _int(simulation['dataQuality'], fallback: 95);
      final realXgAvailable = goalExpectations['realXgAvailable'] == true;

      final trustScore = _trustScore(
        bestProbability: bestProbability,
        probabilityGap: probabilityGap.toDouble(),
        dataQuality: dataQuality,
        simulations: _int(simulation['simulations'], fallback: 10000),
        realXgAvailable: realXgAvailable,
      );

      final selection = <String, Object?>{
        'fixtureId': fixtureId,
        'homeTeam': simulation['homeTeam'],
        'awayTeam': simulation['awayTeam'],
        'league': simulation['league'],
        'kickoff': simulation['kickoff'],
        'modelVersion': modelVersion,
        'phoenixTip': {
          'marketKey': best['key'],
          'market': best['label'],
          'probability': bestProbability,
          'fairOdds': best['fairOdds'],
        },
        'trust': {
          'score': trustScore,
          'label': _trustLabel(trustScore),
          'components': {
            'modelProbability': bestProbability,
            'probabilityGapToSecondMarket': _round(probabilityGap.toDouble()),
            'dataQuality': dataQuality,
            'simulationCount': _int(
              simulation['simulations'],
              fallback: 10000,
            ),
            'realXgAvailable': realXgAvailable,
            'lineupConfirmed': false,
            'aiContextVerified': false,
          },
        },
        'topMarkets': candidates.take(3).toList(),
        'value': {
          'status': 'not_checked',
          'marketOdds': null,
          'minimumMarketOdds': 1.40,
          'minimumValuePercent': 5.0,
          'valuePercent': null,
          'isValueTip': false,
          'reason':
              'Die echte Buchmacherquote wurde noch nicht mit der fairen Quote verglichen.',
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
          'Bestätigte Aufstellung ist noch nicht eingerechnet.',
          'OpenAI-Kontextprüfung ist noch nicht eingerechnet.',
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

  int _trustScore({
    required double bestProbability,
    required double probabilityGap,
    required int dataQuality,
    required int simulations,
    required bool realXgAvailable,
  }) {
    // Vertrauen ist nicht identisch mit der Tipp-Wahrscheinlichkeit.
    // 35 % Modellwahrscheinlichkeit
    // 20 % Abstand zum zweitbesten Markt
    // 30 % Datenqualität
    // 10 % Simulationsstabilität
    // 5 % echte xG/xGA-Verfügbarkeit
    final probabilityComponent =
        (bestProbability.clamp(0, 100) / 100) * 35;

    final gapComponent =
        (probabilityGap.clamp(0, 25) / 25) * 20;

    final dataQualityComponent =
        (dataQuality.clamp(0, 100) / 100) * 30;

    final simulationComponent =
        (simulations.clamp(1000, 10000) / 10000) * 10;

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

  Map<String, Object?> _candidate({
    required String key,
    required String label,
    required Object? probability,
    required Object? fairOdds,
  }) {
    return {
      'key': key,
      'label': label,
      'probability': _number(probability),
      'fairOdds': _number(fairOdds),
    };
  }

  double? _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  }

  int _int(Object? value, {int fallback = 0}) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  double _round(double value) =>
      double.parse(value.toStringAsFixed(2));

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  String _string(Object? value) => value?.toString().trim() ?? '';
}
