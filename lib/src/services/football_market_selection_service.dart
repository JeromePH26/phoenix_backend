import '../database/database.dart';

class FootballMarketSelectionService {
  FootballMarketSelectionService({required this.database});

  final PhoenixDatabase database;

  static const modelVersion = 'market_selection_v12_team_goal_lines';

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
      final selection = selectForFixture(
        fixtureId: fixtureId,
        simulation: simulation,
        minimumProbabilityDecimal: minimumProbabilityDecimal,
      );
      if (selection == null) continue;

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

  /// Reine, DB-freie Auswahllogik für ein einzelnes Fixture - testbar ohne
  /// Datenbank. Gibt `null` zurück, wenn kein Kernmarkt (1X2/BTTS/O-U 2,5)
  /// eine verwertbare Wahrscheinlichkeit hat (Publish Gate: Fixture wird
  /// dann von select() übersprungen statt eine künstliche Empfehlung zu
  /// erzeugen).
  Map<String, Object?>? selectForFixture({
    required String fixtureId,
    required Map<String, Object?> simulation,
    required double minimumProbabilityDecimal,
  }) {
    {
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
          key: 'over15',
          label: 'Über 1,5 Tore',
          probability: probabilities['over15'],
          fairOdds: fairOdds['over15'],
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
          key: 'homeUnder15',
          label: 'Heimteam unter 1,5 Tore',
          probability: probabilities['homeUnder15'],
          fairOdds: fairOdds['homeUnder15'],
        ),
        _candidate(
          key: 'awayOver15',
          label: 'Auswärtsteam über 1,5 Tore',
          probability: probabilities['awayOver15'],
          fairOdds: fairOdds['awayOver15'],
        ),
        _candidate(
          key: 'awayUnder15',
          label: 'Auswärtsteam unter 1,5 Tore',
          probability: probabilities['awayUnder15'],
          fairOdds: fairOdds['awayUnder15'],
        ),
        _candidate(
          key: 'homeOver25',
          label: 'Heimteam über 2,5 Tore',
          probability: probabilities['homeOver25'],
          fairOdds: fairOdds['homeOver25'],
        ),
        _candidate(
          key: 'homeUnder25',
          label: 'Heimteam unter 2,5 Tore',
          probability: probabilities['homeUnder25'],
          fairOdds: fairOdds['homeUnder25'],
        ),
        _candidate(
          key: 'awayOver25',
          label: 'Auswärtsteam über 2,5 Tore',
          probability: probabilities['awayOver25'],
          fairOdds: fairOdds['awayOver25'],
        ),
        _candidate(
          key: 'awayUnder25',
          label: 'Auswärtsteam unter 2,5 Tore',
          probability: probabilities['awayUnder25'],
          fairOdds: fairOdds['awayUnder25'],
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

      // Section 7 (Claude AN2.txt, "DOPPELTE CHANCE DARF NICHT HAUPTTIPP
      // WERDEN"): der PHÖNIX-Haupttipp (phoenixTip/analysisLead) darf NUR
      // aus 1X2, BTTS und Über/Unter 2,5 kommen - live beobachtet an
      // Fixture 1623096 (Sheffield Wednesday vs. Wolves), wo "Doppelte
      // Chance 1X" als Haupttipp gewählt wurde. Alle anderen Märkte (DC,
      // DNB, Team-Tore-Linien, weitere Tor-Linien, Handicaps) werden
      // weiterhin berechnet, gespeichert und im Marktcheck angezeigt -
      // dafür bleibt `displayTipKeys` bewusst breiter als `mainTipKeys`.
      // Mindestquoten je Markt (siehe `_minimumFairOddsFor`) verhindern
      // zusätzlich, dass triviale Absicherungen den Tipp nur wegen ihrer
      // hohen Wahrscheinlichkeit verdrängen.
      const mainTipKeys = <String>{
        'homeWin',
        'draw',
        'awayWin',
        'bttsYes',
        'bttsNo',
        'over25',
        'under25',
      };
      const displayTipKeys = <String>{
        'homeWin',
        'draw',
        'awayWin',
        'dc1x',
        'dcX2',
        'over15',
        'over25',
        'under25',
        'over35',
        'under35',
        'bttsYes',
        'bttsNo',
        'homeOver15',
        'homeUnder15',
        'awayOver15',
        'awayUnder15',
        'homeOver25',
        'homeUnder25',
        'awayOver25',
        'awayUnder25',
        'dnbHome',
        'dnbAway',
      };
      bool isContradictoryDraw(Map<String, Object?> candidate) {
        final key = _string(candidate['key']);
        final probability = _asProbability(candidate['probability']);
        return key == 'draw' &&
            probability <
                _asProbability(
                    probabilities['homeWin'] ?? probabilities['home']) &&
            probability <
                _asProbability(
                    probabilities['awayWin'] ?? probabilities['away']);
      }

      final selectableMain = candidates.where((candidate) {
        final key = _string(candidate['key']);
        final probability = _asProbability(candidate['probability']);
        final fair = _number(candidate['fairOdds']) ?? 0;
        return mainTipKeys.contains(key) &&
            !isContradictoryDraw(candidate) &&
            probability >= minimumProbabilityDecimal.clamp(0.0, 1.0) &&
            fair >= _minimumFairOddsFor(key);
      }).toList(growable: false);
      final fallbackCoreMain = candidates.where((candidate) {
        final key = _string(candidate['key']);
        final probability = _asProbability(candidate['probability']);
        final fair = _number(candidate['fairOdds']) ?? 0;
        return mainTipKeys.contains(key) &&
            !isContradictoryDraw(candidate) &&
            probability >= 0.50 &&
            fair >= _minimumFairOddsFor(key);
      }).toList(growable: false);

      int byScoreThenProbability(
        Map<String, Object?> a,
        Map<String, Object?> b,
      ) {
        final scoreComparison =
            _selectionScore(b).compareTo(_selectionScore(a));
        if (scoreComparison != 0) return scoreComparison;
        return (_number(b['probability']) ?? 0)
            .compareTo(_number(a['probability']) ?? 0);
      }

      // rankedMain bestimmt den einen PHÖNIX-Tipp. Die Auswahl ist breiter
      // als früher, aber nie eine Notlösung mit Kombi, DC 12 oder 0,5-Linie.
      final rankedMain = List<Map<String, Object?>>.from(
        selectableMain.isNotEmpty ? selectableMain : fallbackCoreMain,
      )..sort(byScoreThenProbability);

      // rankedDisplay speist nur die informative Marktübersicht (Marktcheck)
      // und darf bewusst breiter sein als rankedMain.
      final rankedDisplay = List<Map<String, Object?>>.from(
        candidates.where(
          (candidate) => displayTipKeys.contains(_string(candidate['key'])),
        ),
      )..sort(byScoreThenProbability);

      if (rankedMain.isEmpty) {
        // Kein sinnvoller, einzeln abrechenbarer Markt: lieber keine
        // künstliche Empfehlung als eine Niedrigquoten-Absicherung.
        return null;
      }

      final best = rankedMain.first;
      final second = rankedMain.length > 1 ? rankedMain[1] : rankedMain.first;
      final ranked = rankedDisplay.isNotEmpty ? rankedDisplay : rankedMain;

      final bestProbability = _asProbability(best['probability']);
      final selectionScoreGap =
          (_selectionScore(best) - _selectionScore(second))
              .clamp(0.0, 1.0)
              .toDouble();

      final bestProbabilityPercent = bestProbability * 100;
      final probabilityGapPercent = selectionScoreGap * 100;

      final dataQuality = _int(simulation['dataQuality'], fallback: 0);
      final realXgAvailable = goalExpectations['realXgAvailable'] == true;
      // Fehlt der reale Wert, MUSS das ehrlich als "0 Simulationen" sichtbar
      // werden statt fälschlich 100.000 echte Läufe vorzutäuschen.
      final simulations = _int(simulation['simulations'], fallback: 0);

      final trustScore = _trustScore(
        bestProbabilityPercent: bestProbabilityPercent,
        probabilityGapPercent: probabilityGapPercent,
        dataQuality: dataQuality,
        simulations: simulations,
        realXgAvailable: realXgAvailable,
      );

      // Publish Gate: Eine rechnerische Markt-Führung ist noch kein
      // veröffentlichter PHÖNIX-Tipp. Unsichere Fallbacks bleiben als
      // Analyse sichtbar, dürfen aber weder in die Tipp-Historie noch in die
      // Performance einfließen.
      final qualifiesForTip =
          bestProbability >= minimumProbabilityDecimal.clamp(0.0, 1.0) &&
              simulations > 0 &&
              dataQuality >= 60 &&
              trustScore >= 60;

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
          'showPhoenixTip': qualifiesForTip,
          'showValueTip': false,
        },
        // Section 10 (Claude AN2.txt, "KEIN GEMINI"): die beiden
        // Gemini-Kontext-Warnungen entfernt - `aiContext['applied']`/
        // `aiContext['fallbackUsed']` können strukturell nie gesetzt werden
        // (der KI-Kontext-Schritt ist in der Tagespipeline bewusst nie
        // verdrahtet, siehe football_daily_pipeline_service.dart), die
        // "kein Kontext"-Warnung feuerte deshalb auf JEDER Analyse und
        // suggerierte fälschlich eine fehlende Funktion statt des
        // dauerhaften Normalzustands. Die Lineup-Warnung bleibt: sie ist
        // unabhängig vom KI-Kontext wahr (Aufstellungen sind vor Anpfiff
        // fast nie bestätigt) und weiterhin eine echte, nützliche Information.
        'warnings': [
          if (!qualifiesForTip)
            'Analyse vorhanden, aber kein PHÖNIX-Tipp: Mindestwerte nicht erreicht.',
          if (!realXgAvailable) 'Noch keine echten xG/xGA-Daten vorhanden.',
          if (aiContext['lineupStatus'] != 'confirmed')
            'Bestätigte Aufstellung ist noch nicht verfügbar.',
        ],
      };

      return selection;
    }
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

  /// Die Markt-Auswahl bleibt neutral: Sie folgt ausschließlich der
  /// modellierten Wahrscheinlichkeit. Mindestquoten und der Publish-Gate
  /// schützen bereits vor trivialen Absicherungen; künstliche Boni für BTTS,
  /// Tore oder einzelne Marktarten würden die Engine sonst systematisch
  /// verzerren.
  double _selectionScore(Map<String, Object?> candidate) {
    return _asProbability(candidate['probability']);
  }

  /// Marktbezogene Mindestquoten sind ein Qualitätsfilter, keine implizite
  /// Value-Berechnung. Sie halten nur Märkte fern, deren Informationsgehalt
  /// für einen öffentlich sichtbaren Tipp zu niedrig wäre.
  double _minimumFairOddsFor(String key) {
    if (const {'dnbHome', 'dnbAway'}.contains(key)) return 1.30;
    if (const {'over15', 'dc1x', 'dcX2', 'under35'}.contains(key)) {
      return 1.35;
    }
    return 1.40;
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

    // Kein künstlicher Mindestwert mehr: 0 echte Simulationen ergeben 0
    // Punkte statt eine vorgetäuschte Basis-Vertrauenswürdigkeit.
    final simulationComponent = (simulations.clamp(0, 100000) / 100000) * 10;

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
