import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

class BaseballService {
  BaseballService({required this.apiKey, http.Client? client})
      : _client = client ?? http.Client();

  static const _baseUrl = 'https://v1.baseball.api-sports.io';
  static const _dailySafetyLimit = 90;
  static const _mlbLeagueId = '1';

  final String apiKey;
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
    final season = _seasonFrom(fixtures, requested.year);
    final results = await _safeRows(
      '/games',
      {'league': _mlbLeagueId, 'season': '$season'},
      cacheKey: 'mlb-season-$season',
      ttl: const Duration(hours: 8),
    );
    final standingsRaw = await _safeRows(
      '/standings',
      {'league': _mlbLeagueId, 'season': '$season'},
      cacheKey: 'mlb-standings-$season',
      ttl: const Duration(hours: 6),
    );
    final oddsRaw = await _safeRows(
      '/odds',
      {'league': _mlbLeagueId, 'season': '$season', 'date': date},
      cacheKey: 'mlb-odds-$date',
      ttl: const Duration(hours: 2),
    );

    var completed = results.where(_isCompleted).toList(growable: false);
    var standings = _normaliseStandings(standingsRaw);
    var standingsKind = 'Saisontabelle';
    if (completed.isEmpty) {
      final history = <Map<String, dynamic>>[];
      for (var days = 0; days <= 16; days++) {
        final day = requested.subtract(Duration(days: days));
        final dayText =
            '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
        history.addAll(await _gamesForDate(dayText));
      }
      completed = history.where(_isCompleted).toList(growable: false);
    }
    if (standings.isEmpty) {
      standings = _formStandings(completed);
      standingsKind = 'Formtabelle (letzte 16 Spieltage)';
    }
    final analyses = <String, dynamic>{};
    for (final game in fixtures) {
      final id = game['id']?.toString();
      if (id == null || id.isEmpty) continue;
      analyses[id] = _analyse(game, completed, oddsRaw);
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
    };
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

  Future<List<Map<String, dynamic>>> _safeRows(
    String path,
    Map<String, String> query, {
    required String cacheKey,
    required Duration ttl,
  }) async {
    try {
      return await _rows(path, query, cacheKey: cacheKey, ttl: ttl);
    } catch (_) {
      return const [];
    }
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
    final homeForm = _teamForm(homeId, completed, cutoff);
    final awayForm = _teamForm(awayId, completed, cutoff);
    final sample = math.min(homeForm.games, awayForm.games);
    final reliability = (sample / 10).clamp(0.0, 1.0);
    final logit = (homeForm.winRate - awayForm.winRate) * 2.4 +
        (homeForm.runDifference - awayForm.runDifference) * 0.10 +
        0.14;
    final rawHome = 1 / (1 + math.exp(-logit));
    final homeProbability =
        (0.5 + (rawHome - 0.5) * reliability).clamp(0.18, 0.82);
    final awayProbability = 1 - homeProbability;
    final expectedHome = reliability == 0
        ? 4.5
        : ((homeForm.runsFor + awayForm.runsAgainst) / 2 + 0.15)
            .clamp(1.0, 9.0);
    final expectedAway = reliability == 0
        ? 4.3
        : ((awayForm.runsFor + homeForm.runsAgainst) / 2).clamp(1.0, 9.0);
    final pickHome = homeProbability >= awayProbability;
    final pickProbability = pickHome ? homeProbability : awayProbability;
    final pickTeam = (pickHome ? home['name'] : away['name'])?.toString() ?? '';
    final market = _moneylineOdds(fixture['id']?.toString() ?? '', odds);
    final marketOdd = pickHome ? market.$1 : market.$2;
    final value =
        marketOdd == null ? null : (pickProbability * marketOdd - 1) * 100;
    final quality = (reliability * 100).round();
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
      'bestPickProbability': _percent(pickProbability),
      'fairOdds': _decimal(1 / pickProbability),
      'marketOdds': marketOdd == null ? null : _decimal(marketOdd),
      'valuePercent': value == null ? null : _decimal(value),
      'isValueBet': isValue,
      'recommendation':
          isValue ? '$pickTeam Sieg' : 'Kein bestätigter Value-Bet',
      'confidence': _percent((pickProbability - 0.5).abs() * 2),
      'dataQuality': quality,
      'homeForm': homeForm.toJson(),
      'awayForm': awayForm.toJson(),
      'method': 'Letzte 10 MLB-Spiele, Run-Differenz und Heimvorteil',
    };
  }

  _TeamForm _teamForm(
    String teamId,
    List<Map<String, dynamic>> games,
    DateTime? cutoff,
  ) {
    final relevant = games.where((game) {
      final teams = _map(game['teams']);
      final plays = _map(teams['home'])['id']?.toString() == teamId ||
          _map(teams['away'])['id']?.toString() == teamId;
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
      final isHome = _map(teams['home'])['id']?.toString() == teamId;
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

  List<Map<String, dynamic>> _normaliseStandings(
      List<Map<String, dynamic>> rows) {
    final output = <Map<String, dynamic>>[];
    void visit(Object? value) {
      if (value is List) {
        for (final item in value) visit(item);
      } else if (value is Map) {
        final row = Map<String, dynamic>.from(value);
        final team = _map(row['team']);
        if (team.isNotEmpty &&
            (row.containsKey('position') || row.containsKey('rank'))) {
          final games = _map(row['games']);
          final points = _map(row['points']);
          output.add({
            'position': row['position'] ?? row['rank'],
            'teamId': team['id'],
            'team': team['name'],
            'logo': team['logo'],
            'played': games['played'] ?? row['played'],
            'wins': games['win'] ?? games['wins'] ?? row['wins'],
            'losses': games['lose'] ?? games['losses'] ?? row['losses'],
            'runsFor': points['for'] ?? row['runsFor'],
            'runsAgainst': points['against'] ?? row['runsAgainst'],
          });
        } else {
          for (final child in row.values) visit(child);
        }
      }
    }

    visit(rows);
    return output;
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
        final id = team['id']?.toString() ?? team['name']?.toString() ?? '';
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

  int _seasonFrom(List<Map<String, dynamic>> rows, int fallback) {
    if (rows.isEmpty) return fallback;
    return int.tryParse(
            _map(rows.first['league'])['season']?.toString() ?? '') ??
        fallback;
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
  static double _number(Object? value) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '') ?? 0;
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

class _BaseballCacheEntry {
  const _BaseballCacheEntry({required this.rows, required this.expiresAt});
  final List<Map<String, dynamic>> rows;
  final DateTime expiresAt;
}
