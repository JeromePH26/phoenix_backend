import '../database/database.dart';

class FootballMarketSelectionService {
  FootballMarketSelectionService({required this.database});

  final PhoenixDatabase database;

  static const modelVersion = 'market_selection_phoenix_v3_priority';
  static const double defaultMinimumProbability = 0.60;
  static const double safetyMarketAdvantageRequired = 0.10;

  Future<Map<String, Object?>> select({
    required int phaseTwoScanRunId,
    int limit = 20,
    double minimumProbability = 60,
  }) async {
    final rows = await database.simulationRowsForSelection(
      phaseTwoScanRunId: phaseTwoScanRunId,
      limit: limit.clamp(1, 20),
    );

    final outputs = <Map<String, Object?>>[];
    final threshold = _normalizeThreshold(minimumProbability);

    for (final row in rows) {
      final fixtureId = _string(row['fixture_id']);
      final simulation = _map(row['result']);
      final probabilities = _map(simulation['probabilities']);
      final fairOdds = _map(simulation['fairOdds']);
      final goalExpectations = _map(simulation['goalExpectations']);
      final aiContext = _map(simulation['aiContext']);

      final standardMarkets = <Map<String, Object?>>[
        _candidate(
          key: 'homeWin',
          label: 'Heimsieg',
          group: 'standard',
          probability: probabilities['homeWin'] ?? probabilities['home'],
          fairOdds: fairOdds['homeWin'] ?? fairOdds['home'],
        ),
        _candidate(
          key: 'draw',
          label: 'Unentschieden',
          group: 'standard',
          probability: probabilities['draw'],
          fairOdds: fairOdds['draw'],
        ),
        _candidate(
          key: 'awayWin',
          label: 'Auswärtssieg',
          group: 'standard',
          probability: probabilities['awayWin'] ?? probabilities['away'],
          fairOdds: fairOdds['awayWin'] ?? fairOdds['away'],
        ),
        _candidate(
          key: 'over25',
          label: 'Über 2,5 Tore',
          group: 'standard',
          probability: probabilities['over25'],
          fairOdds: fairOdds['over25'],
        ),
        _candidate(
          key: 'under25',
          label: 'Unter 2,5 Tore',
          group: 'standard',
          probability: probabilities['under25'],
          fairOdds: fairOdds['under25'],
        ),
        _candidate(
          key: 'bttsYes',
          label: 'Beide Teams treffen – Ja',
          group: 'standard',
          probability: probabilities['bttsYes'],
          fairOdds: fairOdds['bttsYes'],
        ),
        _candidate(
          key: 'bttsNo',
          label: 'Beide Teams treffen – Nein',
          group: 'standard',
          probability: probabilities['bttsNo'],
          fairOdds: fairOdds['bttsNo'],
        ),
      ];

      final safetyMarkets = <Map<String, Object?>>[
        _candidate(
          key: 'homeOrDraw',
          label: 'Doppelte Chance 1X',
          group: 'safety',
          probability: probabilities['homeOrDraw'],
          fairOdds: fairOdds['homeOrDraw'],
        ),
        _candidate(
          key: 'drawOrAway',
          label: 'Doppelte Chance X2',
          group: 'safety',
          probability: probabilities['drawOrAway'],
          fairOdds: fairOdds['drawOrAway'],
        ),
        _candidate(
          key: 'homeOrAway',
          label: 'Doppelte Chance 12',
          group: 'safety',
          probability: probabilities['homeOrAway'],
          fairOdds: fairOdds['homeOrAway'],
        ),
        _candidate(
          key: 'over15',
          label: 'Über 1,5 Tore',
          group: 'safety',
          probability: probabilities['over15'],
          fairOdds: fairOdds['over15'],
        ),
        _candidate(
          key: 'under35',
          label: 'Unter 3,5 Tore',
          group: 'safety',
          probability: probabilities['under35'],
          fairOdds: fairOdds['under35'],
        ),
      ];

      final allCandidates = <Map<String, Object?>>[
        ...standardMarkets,
        ...safetyMarkets,
      ]..sort(_compareProbabilityDescending);

      final eligibleStandard = standardMarkets
          .where((candidate) => _asProbability(candidate['probability']) > threshold)
          .toList()
        ..sort(_compareProbabilityDescending);

      final eligibleSafety = safetyMarkets
          .where((candidate) => _asProbability(candidate['probability']) > threshold)
          .toList()
        ..sort(_compareProbabilityDescending);

      final selected = _selectMarket(
        standard: eligibleStandard,
        safety: eligibleSafety,
      );

      final qualifiesForTip = selected != null;
      final selectedProbability =
          selected == null ? 0.0 : _asProbability(selected['probability']);

      final comparisonCandidates = allCandidates
          .where((candidate) => candidate['key'] != selected?['key'])
          .toList();
      final secondProbability = comparisonCandidates.isEmpty
          ? 0.0
          : _asProbability(comparisonCandidates.first['probability']);
      final probabilityGap =
          (selectedProbability - secondProbability).clamp(0.0, 1.0).toDouble();

      final dataQuality = _int(simulation['dataQuality'], fallback: 0);
      final realXgAvailable = goalExpectations['realXgAvailable'] == true;
      final simulations = _int(simulation['simulations'], fallback: 100000);

      final trustScore = qualifiesForTip
          ? _trustScore(
              selectedProbabilityPercent: selectedProbability * 100,
              probabilityGapPercent: probabilityGap * 100,
              dataQuality: dataQuality,
              simulations: simulations,
              realXgAvailable: realXgAvailable,
            )
          : 0;

      final phoenixTip = selected == null
          ? <String, Object?>{}
          : <String, Object?>{
              'marketKey': selected['key'],
              'market': selected['label'],
              'marketGroup': selected['group'],
              'probability': _roundProbability(selectedProbability),
              'probabilityPercent': _round(selectedProbability * 100),
              'fairOdds': selected['fairOdds'],
              'selectionReason': _selectionReason(
                selected: selected,
                bestStandard: eligibleStandard.isEmpty
                    ? null
                    : eligibleStandard.first,
                bestSafety:
                    eligibleSafety.isEmpty ? null : eligibleSafety.first,
              ),
            };

      final selection = <String, Object?>{
        'fixtureId': fixtureId,
        'homeTeam': simulation['homeTeam'],
        'awayTeam': simulation['awayTeam'],
        'league': simulation['league'],
        'kickoff': simulation['kickoff'],
        'modelVersion': modelVersion,
        'minimumProbability': _round(threshold * 100),
        'qualifiesForTip': qualifiesForTip,
        'phoenixTip': phoenixTip,
        'trust': {
          'score': trustScore,
          'label': qualifiesForTip
              ? _trustLabel(trustScore)
              : 'Keine Einschätzung über Mindestwahrscheinlichkeit',
          'components': {
            'modelProbability': _roundProbability(selectedProbability),
            'modelProbabilityPercent': _round(selectedProbability * 100),
            'probabilityGapToNextMarket':
                _roundProbability(probabilityGap),
            'probabilityGapPercent': _round(probabilityGap * 100),
            'dataQuality': dataQuality,
            'simulationCount': simulations,
            'realXgAvailable': realXgAvailable,
            'lineupConfirmed':
                aiContext['lineupStatus'] == 'confirmed',
            'aiContextVerified': aiContext['applied'] == true,
          },
        },
        'topMarkets': allCandidates.take(5).toList(),
        'standardMarkets': standardMarkets,
        'safetyMarkets': safetyMarkets,
        'aiContext': aiContext,
        'value': {
          'status': qualifiesForTip ? 'not_checked' : 'no_estimate',
          'marketOdds': null,
          'marketReferenceOdds': null,
          'minimumMarketOdds': 1.40,
          'minimumValuePercent': 5.0,
          'maximumAutomaticValuePercent': 25.0,
          'valuePercent': null,
          'isValueTip': false,
          'reason': qualifiesForTip
              ? 'Die Buchmacherquote wurde noch nicht mit der fairen Quote verglichen.'
              : 'Kein Markt liegt über der Mindestwahrscheinlichkeit.',
        },
        'display': {
          'primaryLabel': 'PHÖNIX-EINSCHÄTZUNG',
          'valueLabel': 'VALUE-TIPP',
          'showPhoenixTip': qualifiesForTip,
          'showValueTip': false,
        },
        'warnings': [
          if (!qualifiesForTip)
            'Kein Markt liegt über ${_round(threshold * 100)} %.',
          if (!realXgAvailable)
            'Noch keine echten xG/xGA-Daten vorhanden.',
          if (aiContext['lineupStatus'] != 'confirmed')
            'Bestätigte Aufstellung ist noch nicht verfügbar.',
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
      'minimumProbability': _round(threshold * 100),
      'processed': outputs.length,
      'withEstimate':
          outputs.where((row) => row['qualifiesForTip'] == true).length,
      'results': outputs,
    };
  }

  Map<String, Object?>? _selectMarket({
    required List<Map<String, Object?>> standard,
    required List<Map<String, Object?>> safety,
  }) {
    final bestStandard = standard.isEmpty ? null : standard.first;
    final bestSafety = safety.isEmpty ? null : safety.first;

    if (bestStandard == null) return bestSafety;
    if (bestSafety == null) return bestStandard;

    final standardProbability =
        _asProbability(bestStandard['probability']);
    final safetyProbability =
        _asProbability(bestSafety['probability']);

    if (safetyProbability >=
        standardProbability + safetyMarketAdvantageRequired) {
      return bestSafety;
    }

    return bestStandard;
  }

  String _selectionReason({
    required Map<String, Object?> selected,
    required Map<String, Object?>? bestStandard,
    required Map<String, Object?>? bestSafety,
  }) {
    if (selected['group'] == 'standard') {
      return 'Aussagekräftiger Standardmarkt über 60 %.';
    }
    if (bestStandard == null) {
      return 'Kein Standardmarkt über 60 %; stärkster Sicherheitsmarkt gewählt.';
    }
    return 'Sicherheitsmarkt ist mindestens 10 Prozentpunkte stärker als der beste Standardmarkt.';
  }

  int _compareProbabilityDescending(
    Map<String, Object?> a,
    Map<String, Object?> b,
  ) {
    final pA = _asProbability(a['probability']);
    final pB = _asProbability(b['probability']);
    return pB.compareTo(pA);
  }

  Map<String, Object?> _candidate({
    required String key,
    required String label,
    required String group,
    required Object? probability,
    required Object? fairOdds,
  }) {
    final normalizedProbability = _asProbability(probability);
    final parsedFairOdds = _number(fairOdds) ??
        (normalizedProbability > 0 ? 1 / normalizedProbability : null);

    return {
      'key': key,
      'label': label,
      'group': group,
      'probability': _roundProbability(normalizedProbability),
      'probabilityPercent': _round(normalizedProbability * 100),
      'fairOdds': parsedFairOdds == null
          ? null
          : double.parse(parsedFairOdds.toStringAsFixed(2)),
    };
  }

  int _trustScore({
    required double selectedProbabilityPercent,
    required double probabilityGapPercent,
    required int dataQuality,
    required int simulations,
    required bool realXgAvailable,
  }) {
    final probabilityComponent =
        (selectedProbabilityPercent.clamp(0, 100) / 100) * 35;
    final gapComponent =
        (probabilityGapPercent.clamp(0, 25) / 25) * 20;
    final dataQualityComponent =
        (dataQuality.clamp(0, 100) / 100) * 30;
    final simulationComponent =
        (simulations.clamp(1000, 100000) / 100000) * 10;
    final xgComponent = realXgAvailable ? 5.0 : 0.0;

    return (probabilityComponent +
            gapComponent +
            dataQualityComponent +
            simulationComponent +
            xgComponent)
        .round()
        .clamp(0, 100);
  }

  String _trustLabel(int score) {
    if (score >= 80) return 'Hohes Vertrauen';
    if (score >= 65) return 'Gutes Vertrauen';
    if (score >= 50) return 'Mittleres Vertrauen';
    return 'Niedriges Vertrauen';
  }

  double _normalizeThreshold(double value) {
    if (!value.isFinite) return defaultMinimumProbability;
    final normalized = value > 1 ? value / 100 : value;
    return normalized.clamp(0.0, 1.0).toDouble();
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
