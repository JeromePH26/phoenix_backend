import '../database/database.dart';

class FootballMarketSelectionService {
  FootballMarketSelectionService({required this.database});

  final PhoenixDatabase database;

  static const modelVersion = 'market_selection_v10_no_dc12';

  Future<Map<String, Object?>> select({
    required int phaseTwoScanRunId,
    int? limit,
    double minimumProbability = 0.68,
  }) async {
    final rows = await database.simulationRowsForSelection(
      phaseTwoScanRunId: phaseTwoScanRunId,
      limit: limit ?? 1000000,
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
          key: 'dc1x',
          label: 'Doppelte Chance 1X',
          probability: probabilities['dc1x'],
          fairOdds: fairOdds['dc1x'],
        ),
        _candidate(
          key: 'dcX2',
          label: 'Doppelte Chance X2',
          probability: probabilities['dcX2'],
          fairOdds: fairOdds['dcX2'],
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
        _candidate(
          key: 'homeOver15',
          label: 'Heimteam über 1,5 Tore',
          probability: probabilities['homeOver15'],
          fairOdds: fairOdds['homeOver15'],
        ),
        _candidate(
          key: 'awayOver15',
          label: 'Auswärtsteam über 1,5 Tore',
          probability: probabilities['awayOver15'],
          fairOdds: fairOdds['awayOver15'],
        ),
      ];

      const extendedMarkets = <String, String>{
        'over35': 'Über 3,5 Tore',
        'under35': 'Unter 3,5 Tore',
      };
      for (final market in extendedMarkets.entries) {
        candidates.add(
          _candidate(
            key: market.key,
            label: market.value,
            probability: probabilities[market.key],
            fairOdds: fairOdds[market.key],
          ),
        );
      }
      // DNB ist kein pauschaler Sicherheitsmarkt. Er wird nur überhaupt
      // berücksichtigt, wenn die zugrunde liegende Siegthese ausreichend
      // offen ist (faire 1X2-Quote etwa 1.90+) und die Absicherung selbst
      // mindestens eine faire 1.30 hergibt.
      void addDnbIfInteresting({
        required String dnbKey,
        required String winKey,
        required String label,
      }) {
        final winFairOdds = _number(fairOdds[winKey]) ?? 0;
        final dnbFairOdds = _number(fairOdds[dnbKey]) ?? 0;
        if (winFairOdds < 1.90 || dnbFairOdds < 1.30) return;
        candidates.add(
          _candidate(
            key: dnbKey,
            label: label,
            probability: probabilities[dnbKey],
            fairOdds: fairOdds[dnbKey],
          ),
        );
      }

      addDnbIfInteresting(
        dnbKey: 'dnbHome',
        winKey: 'homeWin',
        label: 'Draw No Bet Heim',
      );
      addDnbIfInteresting(
        dnbKey: 'dnbAway',
        winKey: 'awayWin',
        label: 'Draw No Bet Auswärts',
      );
      candidates.removeWhere(
        (candidate) => (_number(candidate['probability']) ?? 0) <= 0,
      );

      candidates.sort((a, b) {
        final pA = _number(a['probability']) ?? 0;
        final pB = _number(b['probability']) ?? 0;
        return pB.compareTo(pA);
      });

      // Extrem sichere Linien wie Über 0,5 oder Unter 5,5 haben fast immer
      // unspielbar kleine Quoten. Sie bleiben in der Marktübersicht, dürfen
      // aber nicht automatisch jeden sinnvolleren Pick verdrängen.
      // Der Phoenix-Top-Tipp soll eine echte Spielthese sein. 1X und X2
      // bleiben als nachvollziehbare Absicherung verfügbar, DC 12 und
      // Kombimärkte werden dagegen niemals als Tipp veröffentlicht. DNB ist
      // allein unter der oben geprüften Mindestquote als selektiver
      // Ausweichmarkt erlaubt.
      const primaryTipKeys = <String>{
        'homeWin',
        'draw',
        'awayWin',
        'dc1x',
        'dcX2',
        'over25',
        'under25',
        'bttsYes',
        'bttsNo',
        'homeOver15',
        'awayOver15',
        'dnbHome',
        'dnbAway',
      };
      const reserveTipKeys = <String>{
        'over35',
        'under35',
      };
      final selectable = candidates.where((candidate) {
        final key = _string(candidate['key']);
        final probability = _asProbability(candidate['probability']);
        final fair = _number(candidate['fairOdds']) ?? 0;
        final isContradictoryDraw = key == 'draw' &&
            probability <
                _asProbability(
                    probabilities['homeWin'] ?? probabilities['home']) &&
            probability <
                _asProbability(
                    probabilities['awayWin'] ?? probabilities['away']);
        return primaryTipKeys.contains(key) &&
            !isContradictoryDraw &&
            probability >= minimumProbabilityDecimal.clamp(0.0, 1.0) &&
            fair >= 1.20;
      }).toList(growable: false);
      final fallbackCore = candidates.where((candidate) {
        final key = _string(candidate['key']);
        final probability = _asProbability(candidate['probability']);
        final isContradictoryDraw = key == 'draw' &&
            probability <
                _asProbability(
                    probabilities['homeWin'] ?? probabilities['home']) &&
            probability <
                _asProbability(
                    probabilities['awayWin'] ?? probabilities['away']);
        return primaryTipKeys.contains(key) && !isContradictoryDraw;
      }).toList(growable: false);
      final ranked = List<Map<String, Object?>>.from(
        selectable.isNotEmpty
            ? selectable
            : fallbackCore.isNotEmpty
                ? fallbackCore
                : candidates.where((candidate) {
                    final key = _string(candidate['key']);
                    // Nur wenn die Kernmärkte vollständig fehlen, greifen wir
                    // auf eine breite Torlinie zurück. Kombi- und DC-12-
                    // Märkte werden niemals als Notlösung veröffentlicht.
                    return reserveTipKeys.contains(key);
                  }).toList(growable: false),
      )..sort((a, b) {
          final scoreA = _selectionScore(a);
          final scoreB = _selectionScore(b);
          final scoreComparison = scoreB.compareTo(scoreA);
          if (scoreComparison != 0) return scoreComparison;
          return (_number(b['probability']) ?? 0)
              .compareTo(_number(a['probability']) ?? 0);
        });

      if (ranked.isEmpty) {
        // Kein Markt mit verwertbarer Wahrscheinlichkeit: keine künstliche
        // Empfehlung erzeugen und den Scan robust fortsetzen.
        continue;
      }

      final best = ranked.first;
      final second = ranked.length > 1 ? ranked[1] : ranked.first;

      final bestProbability = _asProbability(best['probability']);
      final selectionScoreGap =
          (_selectionScore(best) - _selectionScore(second))
              .clamp(0.0, 1.0)
              .toDouble();

      final bestProbabilityPercent = bestProbability * 100;
      final probabilityGapPercent = selectionScoreGap * 100;

      final dataQuality = _int(simulation['dataQuality'], fallback: 0);
      final realXgAvailable = goalExpectations['realXgAvailable'] == true;
      final simulations = _int(simulation['simulations'], fallback: 100000);

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
          'selectionScore': _round(_selectionScore(best) * 100),
        },
        'trust': {
          'score': trustScore,
          'label': _trustLabel(trustScore),
          'components': {
            'modelProbability': _roundProbability(bestProbability),
            'modelProbabilityPercent': _round(bestProbabilityPercent),
            'selectionScoreGapToSecondMarket':
                _roundProbability(selectionScoreGap),
            'probabilityGapPercent': _round(probabilityGapPercent),
            'dataQuality': dataQuality,
            'simulationCount': simulations,
            'realXgAvailable': realXgAvailable,
            'lineupConfirmed': aiContext['lineupStatus'] == 'confirmed',
            'aiContextVerified': aiContext['applied'] == true,
          },
        },
        'topMarkets': ranked.take(5).toList(),
        'allMarkets': candidates,
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
          if (!realXgAvailable) 'Noch keine echten xG/xGA-Daten vorhanden.',
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

  /// Balanciert Sicherheit und Aussagekraft. Ohne diese Gewichtung gewinnt
  /// fast immer die mathematisch breiteste Absicherung (1X/X2 oder Over 1.5),
  /// obwohl ein spezifischerer Markt nur wenige Prozentpunkte dahinterliegt.
  /// Die Modellwahrscheinlichkeit selbst bleibt dabei vollständig unverändert.
  double _selectionScore(Map<String, Object?> candidate) {
    final key = _string(candidate['key']);
    final probability = _asProbability(candidate['probability']);
    final fairOdds = _number(candidate['fairOdds']) ??
        (probability > 0 ? 1 / probability : 0);

    var specificityAdjustment = 0.0;
    if (const {'over05', 'under55'}.contains(key)) {
      specificityAdjustment = -0.20;
    } else if (const {
      'over15',
      'dc1x',
      'dcX2',
    }.contains(key)) {
      specificityAdjustment = -0.075;
    } else if (key == 'dc12' || key == 'under45') {
      specificityAdjustment = -0.04;
    } else if (key.startsWith('combo')) {
      specificityAdjustment = 0.055;
    } else if (const {
      'homeWin',
      'draw',
      'awayWin',
      'over25',
      'under25',
      'bttsYes',
      'bttsNo',
      'homeOver15',
      'awayOver15',
      'dnbHome',
      'dnbAway',
    }.contains(key)) {
      specificityAdjustment = 0.025;
    }

    // Faire Quoten im praxisnahen Bereich erhalten einen kleinen Bonus.
    // Sehr niedrige Quoten bleiben sichtbar, dominieren aber nicht den Pick.
    final oddsAdjustment = fairOdds >= 1.40 && fairOdds <= 2.80
        ? 0.02
        : fairOdds < 1.30
            ? -0.04
            : 0.0;
    return probability + specificityAdjustment + oddsAdjustment;
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

    final gapComponent = (probabilityGapPercent.clamp(0, 25) / 25) * 20;

    final dataQualityComponent = (dataQuality.clamp(0, 100) / 100) * 30;

    final simulationComponent = (simulations.clamp(1000, 100000) / 100000) * 10;

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

  double _round(double value) => double.parse(value.toStringAsFixed(2));

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  String _string(Object? value) => value?.toString().trim() ?? '';

  int _int(Object? value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }
}
