import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../database/database.dart';

class BaseballService {
  BaseballService({
    required this.apiKey,
    this.database,
    http.Client? client,
  }) : _client = client ?? http.Client();

  static const _baseUrl = 'https://v1.baseball.api-sports.io';
  static const _dailySafetyLimit = 90;

  final String apiKey;
  final PhoenixDatabase? database;
  final http.Client _client;
  final Map<String, _BaseballCacheEntry> _cache = {};
  DateTime? _quotaDay;
  int _requestsToday = 0;

  bool get isConfigured => apiKey.trim().isNotEmpty;
  int get requestsToday => _requestsToday;

  Future<Map<String, dynamic>> mlbGames(String date) async {
    final rows = await _gamesForDate(date);
    return {
      'date': date,
      'league': 'MLB',
      'response': rows,
      'requestsUsedToday': _requestsToday,
      'dailySafetyLimit': _dailySafetyLimit,
    };
  }

  Future<Map<String, dynamic>> mlbOverview(String date) async {
    final fixtures = await _gamesForDate(date);
    final requested = DateTime.tryParse(date) ?? DateTime.now();
    final history = <Map<String, dynamic>>[
      ...fixtures,
      ...await _officialMlbHistory(requested),
    ];
    final completed = history.where(_isCompleted).toList(growable: false);
    await _settleStoredAnalyses(completed);
    final standings = _formStandings(completed);
    const standingsKind = 'Formtabelle (letzte 8 Spieltage)';
    final analyses = <String, dynamic>{};
    for (final game in fixtures) {
      final id = game['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final analysis = _analyse(game, completed, const []);
      analyses[id] = analysis;
      final scheduledAt = DateTime.tryParse(game['date']?.toString() ?? '');
      if (!_isCompleted(game) &&
          scheduledAt != null &&
          scheduledAt.isAfter(DateTime.now())) {
        await database?.saveBaseballAnalysisHistory(
          game: game,
          analysis: analysis,
        );
      }
    }
    return {
      'date': date,
      'league': 'MLB',
      'response': fixtures,
      'analyses': analyses,
      'standings': standings,
      'standingsKind': standingsKind,
      'model': 'Phoenix MLB v1',
      'requestsUsedToday': _requestsToday,
      'dailySafetyLimit': _dailySafetyLimit,
      'performance': database == null
          ? null
          : await database!.baseballPerformanceSummary(),
    };
  }

  Future<void> _settleStoredAnalyses(
    List<Map<String, dynamic>> completed,
  ) async {
    final store = database;
    if (store == null || completed.isEmpty) return;
    final pending = await store.pendingBaseballAnalyses();
    for (final snapshot in pending) {
      final gameId = snapshot['game_id']?.toString() ?? '';
      final home = snapshot['home_team']?.toString() ?? '';
      final away = snapshot['away_team']?.toString() ?? '';
      final game = completed.cast<Map<String, dynamic>>().firstWhere(
        (candidate) {
          final teams = _map(candidate['teams']);
          final candidateHome = _map(teams['home'])['name']?.toString() ?? '';
          final candidateAway = _map(teams['away'])['name']?.toString() ?? '';
          return candidate['id']?.toString() == gameId ||
              (candidateHome == home && candidateAway == away);
        },
        orElse: () => const <String, dynamic>{},
      );
      if (game.isEmpty) continue;
      final scores = _map(game['scores']);
      final homeScore = _integer(_map(scores['home'])['total']);
      final awayScore = _integer(_map(scores['away'])['total']);
      if (homeScore == null || awayScore == null || homeScore == awayScore) {
        continue;
      }
      final pickSide = snapshot['pick_side']?.toString();
      final won =
          pickSide == 'home' ? homeScore > awayScore : awayScore > homeScore;
      final units = _number(snapshot['assigned_units']);
      final odds = _number(snapshot['market_odds']);
      await store.settleBaseballAnalysis(
        gameId: gameId,
        homeScore: homeScore,
        awayScore: awayScore,
        resultStatus: won ? 'won' : 'lost',
        profitUnits: won && units > 0 && odds > 1
            ? units * (odds - 1)
            : won
                ? 0
                : -units,
      );
    }
  }

  Future<List<Map<String, dynamic>>> _gamesForDate(String date) async {
    final local = DateTime.now();
    final requested = DateTime.tryParse(date);
    final today = requested != null &&
        requested.year == local.year &&
        requested.month == local.month &&
        requested.day == local.day;
    final rows = await _rows(
      '/games',
      {'date': date},
      cacheKey: 'mlb-games-$date',
      ttl: today ? const Duration(minutes: 30) : const Duration(hours: 12),
    );
    return rows.where((row) {
      final league = _map(row['league']);
      return league['name']?.toString().trim().toUpperCase() == 'MLB';
    }).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _rows(
    String path,
    Map<String, String> query, {
    required String cacheKey,
    required Duration ttl,
  }) async {
    final now = DateTime.now().toUtc();
    final cached = _cache[cacheKey];
    if (cached != null && now.isBefore(cached.expiresAt)) return cached.rows;
    if (!isConfigured) throw StateError('API_BASEBALL_KEY fehlt.');
    _resetQuotaIfNeeded(now);
    if (_requestsToday >= _dailySafetyLimit) {
      throw StateError(
          'Baseball-Tageslimit zum Schutz des Free-Tarifs erreicht.');
    }
    final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: query);
    _requestsToday++;
    final response = await _client.get(
      uri,
      headers: {'x-apisports-key': apiKey},
    ).timeout(const Duration(seconds: 30));
    final decoded = jsonDecode(response.body);
    if (response.statusCode != 200 || decoded is! Map) {
      throw StateError(
          'Baseball-Anbieter antwortet mit ${response.statusCode}.');
    }
    final envelope = Map<String, dynamic>.from(decoded);
    final errors = envelope['errors'];
    if (errors is Map && errors.isNotEmpty) {
      throw StateError(errors.values.join(', '));
    }
    final rows = envelope['response'] is List
        ? (envelope['response'] as List)
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList(growable: false)
        : const <Map<String, dynamic>>[];
    _cache[cacheKey] = _BaseballCacheEntry(rows: rows, expiresAt: now.add(ttl));
    return rows;
  }

  Future<List<Map<String, dynamic>>> _officialMlbHistory(DateTime end) async {
    final start = end.subtract(const Duration(days: 14));
    String day(DateTime value) =>
        '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
    final cacheKey = 'official-mlb-${day(end)}';
    final now = DateTime.now().toUtc();
    final cached = _cache[cacheKey];
    if (cached != null && now.isBefore(cached.expiresAt)) return cached.rows;
    final uri = Uri.https('statsapi.mlb.com', '/api/v1/schedule', {
      'sportId': '1',
      'startDate': day(start),
      'endDate': day(end),
    });
    final response =
        await _client.get(uri).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) return const [];
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['dates'] is! List) return const [];
    final rows = <Map<String, dynamic>>[];
    for (final date in (decoded['dates'] as List).whereType<Map>()) {
      final games = date['games'];
      if (games is! List) continue;
      for (final raw in games.whereType<Map>()) {
        final game = Map<String, dynamic>.from(raw);
        final teams = _map(game['teams']);
        final home = _map(teams['home']);
        final away = _map(teams['away']);
        final homeTeam = _map(home['team']);
        final awayTeam = _map(away['team']);
        final state = _map(game['status'])['abstractGameState']?.toString();
        rows.add({
          'id': game['gamePk'],
          'date': game['gameDate'],
          'status': {'short': state == 'Final' ? 'FT' : state},
          'teams': {
            'home': {'id': homeTeam['id'], 'name': homeTeam['name']},
            'away': {'id': awayTeam['id'], 'name': awayTeam['name']},
          },
          'scores': {
            'home': {'total': home['score']},
            'away': {'total': away['score']},
          },
        });
      }
    }
    _cache[cacheKey] = _BaseballCacheEntry(
      rows: rows,
      expiresAt: now.add(const Duration(hours: 12)),
    );
    return rows;
  }

  Map<String, dynamic> _analyse(
    Map<String, dynamic> fixture,
    List<Map<String, dynamic>> completed,
    List<Map<String, dynamic>> odds,
  ) {
    final teams = _map(fixture['teams']);
    final home = _map(teams['home']);
    final away = _map(teams['away']);
    final homeId = home['id']?.toString() ?? '';
    final awayId = away['id']?.toString() ?? '';
    final cutoff = DateTime.tryParse(fixture['date']?.toString() ?? '');
    final homeForm = _teamForm(
      homeId,
      home['name']?.toString() ?? '',
      completed,
      cutoff,
    );
    final awayForm = _teamForm(
      awayId,
      away['name']?.toString() ?? '',
      completed,
      cutoff,
    );
    final sample = math.min(homeForm.games, awayForm.games);
    final reliability = (sample / 10).clamp(0.0, 1.0);
    final logit = (homeForm.winRate - awayForm.winRate) * 2.4 +
        (homeForm.runDifference - awayForm.runDifference) * 0.10 +
        0.14;
    final rawHome = 1 / (1 + math.exp(-logit));
    final formHomeProbability =
        (0.5 + (rawHome - 0.5) * reliability).clamp(0.18, 0.82);
    final expectedHome = reliability == 0
        ? 4.5
        : ((homeForm.runsFor + awayForm.runsAgainst) / 2 + 0.15)
            .clamp(1.0, 9.0);
    final expectedAway = reliability == 0
        ? 4.3
        : ((awayForm.runsFor + homeForm.runsAgainst) / 2).clamp(1.0, 9.0);
    final quality = (reliability * 85).round();
    final simulation = _simulate(
      expectedHome: expectedHome,
      expectedAway: expectedAway,
      formHomeProbability: formHomeProbability,
      dataQuality: quality,
      seed: int.tryParse(fixture['id']?.toString() ?? '') ??
          fixture['id'].toString().hashCode,
    );
    final homeProbability =
        simulation.probabilities['home_win'] ?? formHomeProbability.toDouble();
    final awayProbability = 1 - homeProbability;
    final pickHome = homeProbability >= awayProbability;
    final pickProbability = pickHome ? homeProbability : awayProbability;
    final pickTeam = (pickHome ? home['name'] : away['name'])?.toString() ?? '';
    final market = _moneylineOdds(fixture['id']?.toString() ?? '', odds);
    final marketOdd = pickHome ? market.$1 : market.$2;
    final value =
        marketOdd == null ? null : (pickProbability * marketOdd - 1) * 100;
    final isValue = value != null && value >= 3 && quality >= 60;

    return {
      'homeProbability': _percent(homeProbability),
      'awayProbability': _percent(awayProbability),
      'expectedHomeRuns': _decimal(expectedHome),
      'expectedAwayRuns': _decimal(expectedAway),
      'expectedTotalRuns': _decimal(expectedHome + expectedAway),
      'predictedHomeScore': expectedHome.round(),
      'predictedAwayScore': expectedAway.round(),
      'bestPick': '$pickTeam Sieg',
      'pickSide': pickHome ? 'home' : 'away',
      'bestPickProbability': _percent(pickProbability),
      'fairOdds': _decimal(1 / pickProbability),
      'marketOdds': marketOdd == null ? null : _decimal(marketOdd),
      'valuePercent': value == null ? null : _decimal(value),
      'isValueBet': isValue,
      'recommendation':
          isValue ? '$pickTeam Sieg' : 'Kein bestätigter Value-Bet',
      'confidence': _percent((pickProbability - 0.5).abs() * 2),
      'dataQuality': quality,
      'simulationRuns': simulation.runs,
      'simulationStability': simulation.stability,
      'simulationLow': _percent(simulation.low),
      'simulationHigh': _percent(simulation.high),
      'markets': simulation.markets,
      'homeForm': homeForm.toJson(),
      'awayForm': awayForm.toJson(),
      'method':
          '100.000 Monte-Carlo-Simulationen · letzte 10 Spiele · Run-Differenz · Heimvorteil',
    };
  }

  _MlbSimulation _simulate({
    required double expectedHome,
    required double expectedAway,
    required double formHomeProbability,
    required int dataQuality,
    required int seed,
  }) {
    const runs = 100000;
    const batches = 20;
    const batchSize = runs ~/ batches;
    final random = math.Random(seed);
    final counts = <String, int>{};
    final batchHome = <double>[];
    var homeInBatch = 0;
    final uncertainty = (0.12 + (100 - dataQuality.clamp(0, 100)) / 100 * 0.22)
        .clamp(0.12, 0.34);

    void hit(String key, bool value) {
      if (value) counts[key] = (counts[key] ?? 0) + 1;
    }

    for (var i = 0; i < runs; i++) {
      final homeLambda = _varyRunRate(expectedHome, uncertainty, random);
      final awayLambda = _varyRunRate(expectedAway, uncertainty, random);
      final homeRuns = _poisson(homeLambda, random);
      final awayRuns = _poisson(awayLambda, random);
      final total = homeRuns + awayRuns;
      final homeWin = homeRuns == awayRuns
          ? random.nextDouble() < formHomeProbability
          : homeRuns > awayRuns;
      if (homeWin) homeInBatch++;
      hit('home_win', homeWin);
      hit('away_win', !homeWin);
      hit('over_65', total >= 7);
      hit('under_65', total <= 6);
      hit('over_75', total >= 8);
      hit('under_75', total <= 7);
      hit('over_85', total >= 9);
      hit('under_85', total <= 8);
      hit('over_95', total >= 10);
      hit('under_95', total <= 9);
      hit('home_minus_15', homeRuns - awayRuns >= 2);
      hit('away_minus_15', awayRuns - homeRuns >= 2);
      hit('home_over_35', homeRuns >= 4);
      hit('home_over_45', homeRuns >= 5);
      hit('away_over_35', awayRuns >= 4);
      hit('away_over_45', awayRuns >= 5);
      if ((i + 1) % batchSize == 0) {
        batchHome.add(homeInBatch / batchSize);
        homeInBatch = 0;
      }
    }
    final probabilities = counts.map(
      (key, value) => MapEntry(key, value / runs),
    );
    batchHome.sort();
    final low = batchHome[1];
    final high = batchHome[18];
    final stability = (100 - (high - low) * 500).round().clamp(0, 100);
    const labels = <String, String>{
      'home_win': 'Heimsieg',
      'away_win': 'Auswärtssieg',
      'over_65': 'Über 6,5 Runs',
      'under_65': 'Unter 6,5 Runs',
      'over_75': 'Über 7,5 Runs',
      'under_75': 'Unter 7,5 Runs',
      'over_85': 'Über 8,5 Runs',
      'under_85': 'Unter 8,5 Runs',
      'over_95': 'Über 9,5 Runs',
      'under_95': 'Unter 9,5 Runs',
      'home_minus_15': 'Heimteam -1,5',
      'away_minus_15': 'Auswärtsteam -1,5',
      'home_over_35': 'Heimteam über 3,5 Runs',
      'home_over_45': 'Heimteam über 4,5 Runs',
      'away_over_35': 'Auswärtsteam über 3,5 Runs',
      'away_over_45': 'Auswärtsteam über 4,5 Runs',
    };
    final markets = probabilities.entries
        .map((entry) => {
              'key': entry.key,
              'name': labels[entry.key] ?? entry.key,
              'probability': _percent(entry.value),
              'fairOdds': _decimal(1 / entry.value),
            })
        .toList()
      ..sort((a, b) =>
          (b['probability'] as double).compareTo(a['probability'] as double));
    return _MlbSimulation(
      runs: runs,
      probabilities: probabilities,
      stability: stability,
      low: low,
      high: high,
      markets: markets,
    );
  }

  double _varyRunRate(double base, double sigma, math.Random random) {
    final u1 = math.max(random.nextDouble(), 1e-12);
    final u2 = random.nextDouble();
    final normal = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
    return (base * math.exp(normal * sigma - 0.5 * sigma * sigma))
        .clamp(0.2, 12.0);
  }

  int _poisson(double lambda, math.Random random) {
    final limit = math.exp(-lambda);
    var product = 1.0;
    var k = 0;
    do {
      k++;
      product *= random.nextDouble();
    } while (product > limit && k < 30);
    return k - 1;
  }

  _TeamForm _teamForm(
    String teamId,
    String teamName,
    List<Map<String, dynamic>> games,
    DateTime? cutoff,
  ) {
    final relevant = games.where((game) {
      final teams = _map(game['teams']);
      bool matches(Map<String, dynamic> team) =>
          team['id']?.toString() == teamId ||
          _teamKey(team['name']) == _teamKey(teamName);
      final plays =
          matches(_map(teams['home'])) || matches(_map(teams['away']));
      if (!plays) return false;
      final date = DateTime.tryParse(game['date']?.toString() ?? '');
      return cutoff == null || date == null || date.isBefore(cutoff);
    }).toList()
      ..sort((a, b) =>
          (b['date']?.toString() ?? '').compareTo(a['date']?.toString() ?? ''));
    var wins = 0;
    var runsFor = 0.0;
    var runsAgainst = 0.0;
    final selected = relevant.take(10).toList(growable: false);
    for (final game in selected) {
      final teams = _map(game['teams']);
      final homeTeam = _map(teams['home']);
      final isHome = homeTeam['id']?.toString() == teamId ||
          _teamKey(homeTeam['name']) == _teamKey(teamName);
      final scores = _map(game['scores']);
      final homeScore = _number(_map(scores['home'])['total']);
      final awayScore = _number(_map(scores['away'])['total']);
      final scored = isHome ? homeScore : awayScore;
      final conceded = isHome ? awayScore : homeScore;
      runsFor += scored;
      runsAgainst += conceded;
      if (scored > conceded) wins++;
    }
    final count = selected.length;
    return _TeamForm(
      games: count,
      wins: wins,
      runsFor: count == 0 ? 4.4 : runsFor / count,
      runsAgainst: count == 0 ? 4.4 : runsAgainst / count,
    );
  }

  (double?, double?) _moneylineOdds(
    String gameId,
    List<Map<String, dynamic>> odds,
  ) {
    double? home;
    double? away;
    for (final row in odds) {
      final linked =
          _map(row['game'])['id']?.toString() ?? row['id']?.toString();
      if (linked != gameId) continue;
      final bookmakers = row['bookmakers'];
      if (bookmakers is! List) continue;
      for (final bookmaker in bookmakers.whereType<Map>()) {
        final bets = bookmaker['bets'];
        if (bets is! List) continue;
        for (final bet in bets.whereType<Map>()) {
          final name = bet['name']?.toString().toLowerCase() ?? '';
          if (!name.contains('winner') && !name.contains('moneyline')) continue;
          final values = bet['values'];
          if (values is! List) continue;
          for (final value in values.whereType<Map>()) {
            final label = value['value']?.toString().toLowerCase() ?? '';
            final odd = double.tryParse(value['odd']?.toString() ?? '');
            if (odd == null) continue;
            if (label.contains('home') || label == '1') home = odd;
            if (label.contains('away') || label == '2') away = odd;
          }
          if (home != null || away != null) return (home, away);
        }
      }
    }
    return (home, away);
  }

  List<Map<String, dynamic>> _formStandings(
    List<Map<String, dynamic>> games,
  ) {
    final teams = <String, Map<String, dynamic>>{};
    for (final game in games) {
      final pair = _map(game['teams']);
      final scores = _map(game['scores']);
      final homeScore = _number(_map(scores['home'])['total']);
      final awayScore = _number(_map(scores['away'])['total']);
      final home = _map(pair['home']);
      final away = _map(pair['away']);
      for (final entry in [
        (home, homeScore, awayScore),
        (away, awayScore, homeScore),
      ]) {
        final team = entry.$1;
        final id = _teamKey(team['name']);
        final row = teams.putIfAbsent(
            id,
            () => {
                  'teamId': team['id'],
                  'team': team['name'],
                  'logo': team['logo'],
                  'played': 0,
                  'wins': 0,
                  'losses': 0,
                  'runsFor': 0.0,
                  'runsAgainst': 0.0,
                });
        row['played'] = (row['played'] as int) + 1;
        row['runsFor'] = (row['runsFor'] as num) + entry.$2;
        row['runsAgainst'] = (row['runsAgainst'] as num) + entry.$3;
        if (entry.$2 > entry.$3) {
          row['wins'] = (row['wins'] as int) + 1;
        } else {
          row['losses'] = (row['losses'] as int) + 1;
        }
      }
    }
    final rows = teams.values.toList()
      ..sort((a, b) {
        final aRate = (a['wins'] as int) / math.max(1, a['played'] as int);
        final bRate = (b['wins'] as int) / math.max(1, b['played'] as int);
        return bRate.compareTo(aRate);
      });
    for (var index = 0; index < rows.length; index++) {
      rows[index]['position'] = index + 1;
    }
    return rows;
  }

  bool _isCompleted(Map<String, dynamic> game) {
    final short = _map(game['status'])['short']?.toString().toUpperCase() ?? '';
    return const {'FT', 'AET', 'AP'}.contains(short);
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
  static String _teamKey(Object? value) =>
      value?.toString().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '') ??
      '';
  static double _number(Object? value) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '') ?? 0;

  static int? _integer(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  static double _percent(double value) => (value * 1000).round() / 10;
  static double _decimal(double value) => (value * 100).round() / 100;

  void _resetQuotaIfNeeded(DateTime now) {
    final day = DateTime.utc(now.year, now.month, now.day);
    if (_quotaDay != day) {
      _quotaDay = day;
      _requestsToday = 0;
    }
  }

  void close() => _client.close();
}

class _TeamForm {
  const _TeamForm(
      {required this.games,
      required this.wins,
      required this.runsFor,
      required this.runsAgainst});
  final int games;
  final int wins;
  final double runsFor;
  final double runsAgainst;
  double get winRate => games == 0 ? 0.5 : wins / games;
  double get runDifference => runsFor - runsAgainst;
  Map<String, dynamic> toJson() => {
        'games': games,
        'wins': wins,
        'losses': games - wins,
        'winRate': BaseballService._percent(winRate),
        'runsFor': BaseballService._decimal(runsFor),
        'runsAgainst': BaseballService._decimal(runsAgainst),
        'runDifference': BaseballService._decimal(runDifference),
      };
}

class _MlbSimulation {
  const _MlbSimulation({
    required this.runs,
    required this.probabilities,
    required this.stability,
    required this.low,
    required this.high,
    required this.markets,
  });
  final int runs;
  final Map<String, double> probabilities;
  final int stability;
  final double low;
  final double high;
  final List<Map<String, dynamic>> markets;
}

class _BaseballCacheEntry {
  const _BaseballCacheEntry({required this.rows, required this.expiresAt});
  final List<Map<String, dynamic>> rows;
  final DateTime expiresAt;
}
