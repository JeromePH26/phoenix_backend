import '../database/database.dart';
import 'football_service.dart';

class FootballResultSettlementService {
  FootballResultSettlementService({
    required this.database,
    required this.football,
  });

  final PhoenixDatabase database;
  final FootballService football;

  Future<Map<String, Object?>> settle({
    required DateTime date,
    bool reconcile = false,
  }) async {
    final matches = await football.matchesForDate(date);
    final pending = await database.footballTipsForSettlement(
      date: date,
      reconcile: reconcile,
    );

    final matchById = <String, Map<String, Object?>>{};
    for (final match in matches) {
      final fixture = _map(match['fixture']);
      final id = fixture['id']?.toString() ??
          match['id']?.toString() ??
          match['fixtureId']?.toString();
      if (id != null && id.isNotEmpty) {
        matchById[id] = match;
      }
    }

    var settled = 0;
    var skipped = 0;
    final results = <Map<String, Object?>>[];

    for (final tip in pending) {
      final fixtureId = tip['fixture_id']?.toString() ?? '';
      var match = matchById[fixtureId];
      if (match == null) {
        // Ein einzelner Fixture-Abruf verhindert, dass ein lückenhafter
        // Tagesfeed eine abgeschlossene Wette dauerhaft offen lässt.
        match = await football.fixtureById(fixtureId);
        if (match != null) matchById[fixtureId] = match;
      }

      if (match == null) {
        skipped++;
        continue;
      }

      var fixture = _map(match['fixture']);
      final status = _map(fixture['status']);
      var shortStatus = status['short']?.toString().toUpperCase() ??
          match['status']?.toString().toUpperCase() ??
          '';

      // Der Tagesfeed darf im Cache kurz hinterherhinken. Erst wenn auch die
      // frische Einzelabfrage keinen finalen Status liefert, bleibt der Tipp
      // korrekt offen (z. B. bei Live- oder verschobenen Spielen).
      if (!_isVoided(shortStatus) && !_isFinished(shortStatus)) {
        final fresh = await football.fixtureById(fixtureId);
        if (fresh != null) {
          matchById[fixtureId] = fresh;
          match = fresh;
          fixture = _map(match['fixture']);
          final freshStatus = _map(fixture['status']);
          shortStatus = freshStatus['short']?.toString().toUpperCase() ??
              match['status']?.toString().toUpperCase() ??
              '';
        }
      }

      // Abgesagte oder abgebrochene Partien dürfen nie dauerhaft als offen
      // erscheinen. Verschobene Spiele (PST) bleiben dagegen pending, weil sie
      // später mit derselben Tipp-ID noch regulär stattfinden können.
      final isVoidedFixture = _isVoided(shortStatus);
      if (!isVoidedFixture && !_isFinished(shortStatus)) {
        skipped++;
        continue;
      }

      final goals = _map(match['goals']);
      final homeScore = _integer(
        goals['home'] ?? match['homeGoals'] ?? match['home_score'],
      );
      final awayScore = _integer(
        goals['away'] ?? match['awayGoals'] ?? match['away_score'],
      );

      final payload = _map(tip['payload']);
      final marketKey = tip['market_key']?.toString() ??
          payload['marketKey']?.toString() ??
          '';
      final marketLabel = tip['market_label']?.toString() ??
          payload['marketLabel']?.toString() ??
          '';

      final resultStatus = isVoidedFixture
          ? 'voided'
          : gradeMarket(
              marketKey: marketKey,
              marketLabel: marketLabel,
              homeScore: homeScore,
              awayScore: awayScore,
            );

      if (resultStatus == 'unsupported') {
        skipped++;
        results.add({
          'fixtureId': fixtureId,
          'status': 'unsupported_market',
          'marketKey': marketKey,
          'marketLabel': marketLabel,
        });
        continue;
      }

      final units = _number(tip['assigned_units']) ?? 0;
      final odds =
          _number(tip['market_odds']) ?? _number(payload['marketOdds']) ?? 0;

      final profitUnits = switch (resultStatus) {
        'won' => units > 0 && odds > 1 ? units * (odds - 1) : 0.0,
        'lost' => -units,
        _ => 0.0,
      };

      await database.settleFootballTip(
        phaseTwoScanRunId: _integer(tip['phase_two_scan_run_id']),
        fixtureId: fixtureId,
        homeScore: homeScore,
        awayScore: awayScore,
        resultStatus: resultStatus,
        profitUnits: profitUnits,
      );

      settled++;
      results.add({
        'fixtureId': fixtureId,
        'score': '$homeScore:$awayScore',
        'marketLabel': marketLabel,
        'resultStatus': resultStatus,
        'assignedUnits': units,
        'profitUnits': profitUnits,
      });
    }

    final comboResults = <Map<String, Object?>>[];
    for (final combo in await database.footballDailyCombosForSettlement(
      date: date,
      reconcile: reconcile,
    )) {
      final payload = _map(combo['payload']);
      final legs = payload['legs'] is List ? payload['legs'] as List : const [];
      if (legs.isEmpty) {
        continue;
      }

      final grades = <String>[];
      var allFixturesFinished = true;
      for (final rawLeg in legs) {
        final leg = _map(rawLeg);
        final fixtureId = leg['fixtureId']?.toString() ?? '';
        final match = matchById[fixtureId];
        if (match == null) {
          allFixturesFinished = false;
          break;
        }
        final fixture = _map(match['fixture']);
        final status = _map(fixture['status']);
        final shortStatus = status['short']?.toString().toUpperCase() ??
            match['status']?.toString().toUpperCase() ??
            '';
        if (!_isFinished(shortStatus)) {
          allFixturesFinished = false;
          break;
        }
        final goals = _map(match['goals']);
        final grade = gradeMarket(
          marketKey: leg['marketKey']?.toString() ?? '',
          marketLabel: leg['market']?.toString() ?? '',
          homeScore: _integer(goals['home'] ?? match['homeGoals']),
          awayScore: _integer(goals['away'] ?? match['awayGoals']),
        );
        if (grade == 'unsupported') {
          allFixturesFinished = false;
          break;
        }
        grades.add(grade);
      }
      if (!allFixturesFinished) continue;

      final resultStatus = grades.any((grade) => grade == 'lost')
          ? 'lost'
          : grades.any((grade) => grade == 'push')
              ? 'push'
              : 'won';
      final units = _number(combo['assigned_units']) ?? 1;
      final odds = _number(combo['combined_odds']) ?? 0;
      final profitUnits = switch (resultStatus) {
        'won' => units * (odds - 1),
        'lost' => -units,
        _ => 0.0,
      };
      await database.settleFootballDailyCombo(
        date: date,
        resultStatus: resultStatus,
        profitUnits: profitUnits,
      );
      comboResults.add({
        'status': resultStatus,
        'assignedUnits': units,
        'profitUnits': profitUnits,
        'legs': grades.length,
      });
    }

    return {
      'status': 'completed',
      'date': date.toIso8601String().substring(0, 10),
      'reconcile': reconcile,
      'pendingFound': pending.length,
      'settled': settled,
      'skipped': skipped,
      'results': results,
      'dailyCombos': comboResults,
      'performance': await database.footballPerformanceSummary(),
      'dailyComboPerformance': await database.footballDailyComboPerformance(),
    };
  }

  static String gradeMarket({
    required String marketKey,
    required String marketLabel,
    required int homeScore,
    required int awayScore,
  }) {
    final key = '$marketKey $marketLabel'
        .toLowerCase()
        .replaceAll(',', '.')
        .replaceAll('ü', 'u');

    final total = homeScore + awayScore;
    // Historische Datensätze verwenden teils snake_case, neuere CamelCase.
    // Für die Ergebnisabrechnung müssen beide Schreibweisen identisch sein;
    // ansonsten konnte eine Kombiwette nach ihrem Toranteil statt als gesamte
    // Kombination bewertet werden.
    final normalizedMarketKey =
        marketKey.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final goalDifference = homeScore - awayScore;

    // Older snapshots can contain a provider display label instead of the
    // internal key. Settle European handicaps before their 1X2 text is read.
    final historicalHandicap = _gradeHistoricalEuropeanHandicap(
      key,
      goalDifference,
    );
    if (historicalHandicap != null) return historicalHandicap;

    // Kombinations- und Handicapmärkte müssen vor den enthaltenen
    // Einzelbegriffen (z. B. 1X oder Heimsieg) ausgewertet werden.
    switch (normalizedMarketKey) {
      case 'combo1xunder35':
        return homeScore >= awayScore && total < 3.5 ? 'won' : 'lost';
      case 'combox2under35':
        return awayScore >= homeScore && total < 3.5 ? 'won' : 'lost';
      case 'combo1xover15':
        return homeScore >= awayScore && total > 1.5 ? 'won' : 'lost';
      case 'combox2over15':
        return awayScore >= homeScore && total > 1.5 ? 'won' : 'lost';
      case 'combohomeover15':
        return homeScore > awayScore && total > 1.5 ? 'won' : 'lost';
      case 'comboawayover15':
        return awayScore > homeScore && total > 1.5 ? 'won' : 'lost';
      case 'homeover15':
        return homeScore >= 2 ? 'won' : 'lost';
      case 'awayover15':
        return awayScore >= 2 ? 'won' : 'lost';
      // Nur für bereits gespeicherte historische Tipps. Neue Scans erzeugen
      // keine asiatischen Handicaps mehr, ihre Auswertung darf jedoch nicht
      // verfälscht oder offen gelassen werden.
      case 'ahhomeminus05':
        return goalDifference >= 1 ? 'won' : 'lost';
      case 'ahhomeplus05':
        return goalDifference >= 0 ? 'won' : 'lost';
      case 'ahhomeminus15':
        return goalDifference >= 2 ? 'won' : 'lost';
      case 'ahhomeplus15':
        return goalDifference >= -1 ? 'won' : 'lost';
      case 'ahawayminus05':
        return goalDifference <= -1 ? 'won' : 'lost';
      case 'ahawayplus05':
        return goalDifference <= 0 ? 'won' : 'lost';
      case 'ahawayminus15':
        return goalDifference <= -2 ? 'won' : 'lost';
      case 'ahawayplus15':
        return goalDifference <= 1 ? 'won' : 'lost';
      case 'ehhomeminus1':
        return goalDifference >= 2 ? 'won' : 'lost';
      case 'ehdrawminus1':
        return goalDifference == 1 ? 'won' : 'lost';
      case 'ehawayplus1':
        return goalDifference <= 0 ? 'won' : 'lost';
      case 'ehhomeminus2':
        return goalDifference >= 3 ? 'won' : 'lost';
      case 'ehdrawminus2':
        return goalDifference == 2 ? 'won' : 'lost';
      case 'ehawayplus2':
        return goalDifference <= 1 ? 'won' : 'lost';
      case 'dnbhome':
        return goalDifference > 0
            ? 'won'
            : goalDifference == 0
                ? 'push'
                : 'lost';
      case 'dnbaway':
        return goalDifference < 0
            ? 'won'
            : goalDifference == 0
                ? 'push'
                : 'lost';
      case 'bttsyes':
        return homeScore > 0 && awayScore > 0 ? 'won' : 'lost';
      case 'bttsno':
        return homeScore > 0 && awayScore > 0 ? 'lost' : 'won';
      case 'awaywin':
        return awayScore > homeScore ? 'won' : 'lost';
    }

    // Manche ältere Snapshots speichern nur das sichtbare Label statt des
    // Schlüssels. Ohne diese Variante blieb Draw No Bet trotz Endstand offen.
    if (_containsAny(key, [
      'draw no bet heim',
      'draw no bet home',
      'dnb heim',
      'dnb home',
    ])) {
      return goalDifference > 0
          ? 'won'
          : goalDifference == 0
              ? 'push'
              : 'lost';
    }
    if (_containsAny(key, [
      'draw no bet auswarts',
      'draw no bet away',
      'dnb auswarts',
      'dnb away',
    ])) {
      return goalDifference < 0
          ? 'won'
          : goalDifference == 0
              ? 'push'
              : 'lost';
    }

    if (_containsAny(key, ['home_win', 'home win', 'heimsieg', '1x2_home'])) {
      return homeScore > awayScore ? 'won' : 'lost';
    }
    if (_containsAny(key, ['draw', 'unentschieden', '1x2_draw'])) {
      return homeScore == awayScore ? 'won' : 'lost';
    }
    if (_containsAny(key, [
      'away_win',
      'away win',
      'auswartssieg',
      '1x2_away',
    ])) {
      return awayScore > homeScore ? 'won' : 'lost';
    }

    if (_containsAny(key, ['1x', 'home or draw', 'heim oder unentschieden'])) {
      return homeScore >= awayScore ? 'won' : 'lost';
    }
    if (_containsAny(key, [
      'x2',
      'away or draw',
      'auswarts oder unentschieden',
    ])) {
      return awayScore >= homeScore ? 'won' : 'lost';
    }
    if (_containsAny(key, ['12', 'home or away'])) {
      return homeScore != awayScore ? 'won' : 'lost';
    }

    if (_containsAny(key, [
      'btts_yes',
      'both teams to score yes',
      'beide treffen ja',
    ])) {
      return homeScore > 0 && awayScore > 0 ? 'won' : 'lost';
    }
    if (_containsAny(key, [
      'btts_no',
      'both teams to score no',
      'beide treffen nein',
    ])) {
      return homeScore == 0 || awayScore == 0 ? 'won' : 'lost';
    }

    final overLine = _extractLine(key, ['over ', 'over_', 'uber ', 'u ']);
    if (overLine != null && _containsAny(key, ['over', 'uber'])) {
      return total > overLine
          ? 'won'
          : total == overLine
              ? 'push'
              : 'lost';
    }

    final underLine = _extractLine(key, ['under ', 'under_', 'unter ']);
    if (underLine != null && _containsAny(key, ['under', 'unter'])) {
      return total < underLine
          ? 'won'
          : total == underLine
              ? 'push'
              : 'lost';
    }

    return 'unsupported';
  }

  static String? _gradeHistoricalEuropeanHandicap(
    String value,
    int goalDifference,
  ) {
    if (!value.contains('handicap')) return null;
    final compact = value.replaceAll(RegExp(r'[^a-z0-9+-.]'), '');
    final line = RegExp(r'([+-])([0-9]+)').firstMatch(compact);
    if (line == null) return null;
    final amount = int.tryParse(line.group(2) ?? '');
    if (amount == null || amount <= 0) return null;
    final sign = line.group(1);
    if (compact.contains('heim') || compact.contains('home')) {
      if (sign == '-') return goalDifference >= amount + 1 ? 'won' : 'lost';
      return goalDifference >= 1 - amount ? 'won' : 'lost';
    }
    if (compact.contains('auswart') || compact.contains('away')) {
      if (sign == '+') return goalDifference <= amount - 1 ? 'won' : 'lost';
      return goalDifference <= -amount - 1 ? 'won' : 'lost';
    }
    if (compact.contains('unentschieden') || compact.contains('draw')) {
      final target = sign == '-' ? amount : -amount;
      return goalDifference == target ? 'won' : 'lost';
    }
    return null;
  }

  static double? _extractLine(String value, List<String> prefixes) {
    for (final prefix in prefixes) {
      final index = value.indexOf(prefix);
      if (index == -1) continue;
      final tail = value.substring(index + prefix.length);
      final match = RegExp(r'([0-9]+(?:\.[0-9]+)?)').firstMatch(tail);
      if (match != null) {
        return double.tryParse(match.group(1)!);
      }
    }
    return null;
  }

  static bool _containsAny(String value, List<String> needles) =>
      needles.any(value.contains);

  bool _isFinished(String status) =>
      const {'FT', 'AET', 'PEN', 'AWD', 'WO'}.contains(status);

  bool _isVoided(String status) => const {'CANC', 'ABD'}.contains(status);

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  double? _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  }

  int _integer(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
