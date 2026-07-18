import '../database/database.dart';

class FootballMarketSelectionService {
  FootballMarketSelectionService({required this.database});

  final PhoenixDatabase database;

  static const modelVersion = 'market_selection_trust_v2_context100k';

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
      final aiContext = _map(simulation['aiContext']);

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
      ].where((candidate) => candidate['probability'] != null).toList();

      if (candidates.isEmpty) continue;

      candidates.sort((a, b) {
        final pA = _number(a['probability']) ?? 0;
        final pB = _number(b['probability']) ?? 0;
        return pB.compareTo(pA);
      });

      final best = candidates.first;
      final second = candidates.length > 1 ? candidates[1] : candidates.first;
      final bestProbability = _number(best['probability']) ?? 0;
      final secondProbability = _number(second['probability']) ?? 0;
      final probabilityGap =
          (bestProbability - secondProbability).clamp(0, 100).toDouble();

      final dataQuality = _int(simulation['dataQuality'], fallback: 0);
      final realXgAvailable = goalExpectations['realXgAvailable'] == true;
      final aiContextVerified = goalExpectations['aiContextApplied'] == true ||
          aiContext['applied'] == true;
      final lineupConfirmed = simulation['lineupConfirmed'] == true ||
          goalExpectations['lineupConfirmed'] == true;
      final confidenceDelta =
          _int(simulation['confidenceDelta']).clamp(-10, 5);
      final simulationCount =
          _int(simulation['simulations'], fallback: 100000);

      final baseTrust = _trustScore(
        bestProbability: bestProbability,
        probabilityGap: probabilityGap,
        dataQuality: dataQuality,
        simulations: simulationCount,
        realXgAvailable: realXgAvailable,
        aiContextVerified: aiContextVerified,
        lineupConfirmed: lineupConfirmed,
      );
      final trustScore =
          (baseTrust + confidenceDelta).clamp(0, 100).toInt();

      final belowRequestedProbability =
          minimumProbability > 0 && bestProbability < minimumProbability;

      final selection = <String, Object?>{
        'fixtureId': fixtureId,
        'homeTeam': simulation['homeTeam'],
        'awayTeam': simulation['awayTeam'],
        'league': simulation['league'],
        'kickoff': simulation['kickoff'],
        'modelVersion': modelVersion,
        'qualifiesForTip': !belowRequestedProbability,
        'phoenixTip': {
          'marketKey': best['key'],
          'market': best['label'],
          'probability': bestProbability,
          'fairOdds': best['fairOdds'],
        },
        'trust': {
          'score': trustScore,
          'baseScore': baseTrust,
          'confidenceDelta': confidenceDelta,
          'label': _trustLabel(trustScore),
          'components': {
            'modelProbability': bestProbability,
            'probabilityGapToSecondMarket': _round(probabilityGap),
            'dataQuality': dataQuality,
            'simulationCount': simulationCount,
            'realXgAvailable': realXgAvailable,
            'lineupConfirmed': lineupConfirmed,
            'aiContextVerified': aiContextVerified,
          },
        },
        'aiContext': aiContext,
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
          if (!lineupConfirmed)
            'Bestätigte Aufstellung ist noch nicht eingerechnet.',
          if (!aiContextVerified)
            'Keine ausreichend verlässliche Gemini-Kontextprüfung angewendet.',
          if (belowRequestedProbability)
            'Die Tippwahrscheinlichkeit liegt unter der angeforderten Mindestgrenze.',
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
    required bool aiContextVerified,
    required bool lineupConfirmed,
  }) {
    // 30 % Modellwahrscheinlichkeit
    // 15 % Abstand zum zweitbesten Markt
    // 30 % Datenqualität
    // 10 % Simulationsumfang
    // 5 % echte xG/xGA
    // 5 % verifizierter KI-Kontext
    // 5 % bestätigte Aufstellung
    final probabilityComponent =
        (bestProbability.clamp(0, 100) / 100) * 30;
    final gapComponent = (probabilityGap.clamp(0, 25) / 25) * 15;
    final dataQualityComponent =
        (dataQuality.clamp(0, 100) / 100) * 30;
    final simulationComponent =
        (simulations.clamp(1000, 100000) / 100000) * 10;
    final xgComponent = realXgAvailable ? 5.0 : 0.0;
    final aiComponent = aiContextVerified ? 5.0 : 0.0;
    final lineupComponent = lineupConfirmed ? 5.0 : 0.0;

    return (probabilityComponent +
            gapComponent +
            dataQualityComponent +
            simulationComponent +
            xgComponent +
            aiComponent +
            lineupComponent)
        .round()
        .clamp(0, 100);
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
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  double _round(double value) => double.parse(value.toStringAsFixed(2));

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  String _string(Object? value) => value?.toString().trim() ?? '';
}
