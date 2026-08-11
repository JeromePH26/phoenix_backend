import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../database/database.dart';

/// Gemeinsame, sparsame Analysebasis fuer API-Sports-Teamspielprodukte.
///
/// Pro Produkt werden hoechstens 90 von 100 Free-Plan-Anfragen pro UTC-Tag
/// verwendet. Eine Tagesuebersicht benoetigt im Normalfall nur die heutigen
/// Spiele sowie den einen im Free-Plan verfuegbaren Vortag fuer eine erste
/// Formberechnung.
class ApiSportsTeamEngine {
  ApiSportsTeamEngine({
    required this.sport,
    required this.baseUrl,
    required this.apiKey,
    this.database,
    http.Client? client,
  }) : _client = client ?? http.Client();

  static const dailySafetyLimit = 90;
  // Die anderen API-Sports-Free-Produkte erlauben bei date= nur gestern,
  // heute und morgen. Historische Teamdaten werden sportweise separat
  // ergaenzt; diese Basisschicht fragt nie ausserhalb des Freifensters ab.
  static const historyDays = 1;

  final String sport;
  final String baseUrl;
  final String apiKey;
  final PhoenixDatabase? database;
  final http.Client _client;
  final Map<String, _SportCacheEntry> _cache = {};
  DateTime? _quotaDay;
  int _requestsToday = 0;

  bool get isConfigured => apiKey.trim().isNotEmpty;
  int get requestsToday => _requestsToday;

  Future<Map<String, dynamic>> overview(String date) async {
    final requested = DateTime.tryParse(date)?.toUtc();
    if (requested == null) throw StateError('Ungueltiges Datum.');

    final fixtures = await _gamesForDay(requested);
    final history = <Map<String, dynamic>>[];
    for (var offset = 1; offset <= historyDays; offset++) {
      history.addAll(await _gamesForDay(
        requested.subtract(Duration(days: offset)),
      ));
    }
    final completed = history.where(_isCompleted).toList(growable: false);
    final analyses = <String, dynamic>{
      for (final fixture in fixtures)
        if (_id(fixture).isNotEmpty) _id(fixture): _analyse(fixture, completed),
    };

    return {
      'date': date,
      'sport': sport,
      'response': fixtures,
      'analyses': analyses,
      'model': 'PHOENIX ${sport.toUpperCase()} v1',
      'requestsUsedToday': _requestsToday,
      'dailySafetyLimit': dailySafetyLimit,
      'historyDays': historyDays,
    };
  }

  Future<List<Map<String, dynamic>>> _gamesForDay(DateTime value) async {
    final day = _day(value);
    final now = DateTime.now().toUtc();
    final cached = _cache[day];
    if (cached != null && now.isBefore(cached.expiresAt)) return cached.rows;
    if (!isConfigured) throw StateError('API_SPORTS_KEY fehlt.');
    _resetQuotaIfNeeded(now);
    if (_requestsToday >= dailySafetyLimit) {
      throw StateError(
          '$sport-Tageslimit zum Schutz des Free-Tarifs erreicht.');
    }

    final store = database;
    if (store != null && store.isConfigured) {
      final persistedRequests = await store.consumeApiSportsRequest(
        apiName: sport,
        safetyLimit: dailySafetyLimit,
      );
      if (persistedRequests == null) {
        throw StateError(
          '$sport-Tageslimit zum Schutz des Free-Tarifs erreicht.',
        );
      }
      _requestsToday = math.max(_requestsToday, persistedRequests);
    } else {
      _requestsToday++;
    }
    final response = await _client.get(
      Uri.parse('$baseUrl/games').replace(queryParameters: {'date': day}),
      headers: {'x-apisports-key': apiKey},
    ).timeout(const Duration(seconds: 30));
    final decoded = jsonDecode(response.body);
    if (response.statusCode != 200 || decoded is! Map) {
      throw StateError('$sport-Anbieter antwortet mit ${response.statusCode}.');
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
    final isToday = day == _day(now);
    _cache[day] = _SportCacheEntry(
      rows: rows,
      expiresAt: now.add(
          isToday ? const Duration(minutes: 20) : const Duration(hours: 18)),
    );
    return rows;
  }

  Map<String, dynamic> _analyse(
    Map<String, dynamic> fixture,
    List<Map<String, dynamic>> history,
  ) {
    final home = _team(fixture, 'home');
    final away = _team(fixture, 'away');
    final homeForm = _form(history, home);
    final awayForm = _form(history, away);
    final homeStrength = _strength(homeForm) + .045;
    final awayStrength = _strength(awayForm);
    final homeProbability = _clamp(.5 + (homeStrength - awayStrength) * .42);
    final expectedHome = _expectedFor(homeForm, awayForm);
    final expectedAway = _expectedFor(awayForm, homeForm);
    final simulation = _simulate(
      seed: _id(fixture).hashCode,
      homeMean: expectedHome,
      awayMean: expectedAway,
    );
    final quality =
        ((homeForm.games + awayForm.games) / 16 * 100).round().clamp(0, 100);

    return {
      'homeForm': homeForm.toJson(),
      'awayForm': awayForm.toJson(),
      'dataQuality': quality,
      'simulation': {
        'runs': 20000,
        'homeWinProbability': _percent(simulation.homeWins / 20000),
        'awayWinProbability': _percent(simulation.awayWins / 20000),
        'expectedHomeScore': _round(expectedHome),
        'expectedAwayScore': _round(expectedAway),
      },
      'markets': [
        {
          'label': '${_name(home)} gewinnt',
          'probability':
              _percent((simulation.homeWins / 20000 + homeProbability) / 2),
        },
        {
          'label': '${_name(away)} gewinnt',
          'probability': _percent(
              (simulation.awayWins / 20000 + (1 - homeProbability)) / 2),
        },
        {
          'label': 'Gesamtpunkte Ueber ${_round(expectedHome + expectedAway)}',
          'probability': _percent(simulation.overExpected / 20000),
        },
      ],
      'explanation':
          '20.000 Simulationen | letzte $historyDays Spieltage | Punkte-/Run-Differenz | Heimvorteil',
    };
  }

  _TeamForm _form(List<Map<String, dynamic>> rows, Map<String, dynamic> team) {
    final matches = rows.where((row) =>
        _sameTeam(_team(row, 'home'), team) ||
        _sameTeam(_team(row, 'away'), team));
    var wins = 0;
    var scored = 0.0;
    var conceded = 0.0;
    var games = 0;
    for (final match in matches) {
      final home = _team(match, 'home');
      final isHome = _sameTeam(home, team);
      final own = _score(match, isHome ? 'home' : 'away');
      final opponent = _score(match, isHome ? 'away' : 'home');
      if (own == null || opponent == null) continue;
      games++;
      scored += own;
      conceded += opponent;
      if (own > opponent) wins++;
    }
    return _TeamForm(
        games: games, wins: wins, scored: scored, conceded: conceded);
  }

  double _strength(_TeamForm form) {
    if (form.games == 0) return .5;
    final winRate = form.wins / form.games;
    final difference = (form.scored - form.conceded) / form.games;
    return _clamp(winRate * .75 + (.5 + difference / 40) * .25);
  }

  double _expectedFor(_TeamForm own, _TeamForm opponent) {
    if (own.games == 0 && opponent.games == 0) return 1;
    final scored = own.games == 0 ? 1 : own.scored / own.games;
    final conceded =
        opponent.games == 0 ? scored : opponent.conceded / opponent.games;
    return math.max(.1, (scored + conceded) / 2);
  }

  _Simulation _simulate({
    required int seed,
    required double homeMean,
    required double awayMean,
  }) {
    final random = math.Random(seed);
    var homeWins = 0;
    var awayWins = 0;
    var overExpected = 0;
    final line = homeMean + awayMean;
    for (var index = 0; index < 20000; index++) {
      final home = _normal(random, homeMean, math.max(.8, homeMean * .33));
      final away = _normal(random, awayMean, math.max(.8, awayMean * .33));
      if (home > away) homeWins++;
      if (away > home) awayWins++;
      if (home + away > line) overExpected++;
    }
    return _Simulation(homeWins, awayWins, overExpected);
  }

  double _normal(math.Random random, double mean, double deviation) {
    final u = math.max(1e-12, random.nextDouble());
    final v = random.nextDouble();
    return math.max(
        0,
        mean +
            deviation *
                math.sqrt(-2 * math.log(u)) *
                math.cos(2 * math.pi * v));
  }

  bool _isCompleted(Map<String, dynamic> row) =>
      _score(row, 'home') != null && _score(row, 'away') != null;

  Map<String, dynamic> _team(Map<String, dynamic> row, String side) {
    final teams = _map(row['teams']);
    return _map(teams[side]);
  }

  double? _score(Map<String, dynamic> row, String side) {
    final scores = _map(row['scores']);
    final value = scores[side];
    if (value is num) return value.toDouble();
    final score = _map(value);
    for (final key in const ['total', 'points', 'score']) {
      final candidate = score[key];
      if (candidate is num) return candidate.toDouble();
      if (candidate != null) return double.tryParse(candidate.toString());
    }
    return null;
  }

  bool _sameTeam(Map<String, dynamic> one, Map<String, dynamic> other) {
    final id = _id(one);
    return id.isNotEmpty ? id == _id(other) : _name(one) == _name(other);
  }

  String _id(Map<String, dynamic> value) => value['id']?.toString() ?? '';
  String _name(Map<String, dynamic> value) =>
      value['name']?.toString() ?? 'Unbekannt';
  Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : const {};
  String _day(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
  double _clamp(double value) => value.clamp(.05, .95).toDouble();
  double _percent(double value) => (value * 1000).round() / 10;
  double _round(double value) => (value * 10).round() / 10;

  void _resetQuotaIfNeeded(DateTime now) {
    final day = DateTime.utc(now.year, now.month, now.day);
    if (_quotaDay == day) return;
    _quotaDay = day;
    _requestsToday = 0;
  }
}

class _TeamForm {
  const _TeamForm(
      {required this.games,
      required this.wins,
      required this.scored,
      required this.conceded});
  final int games;
  final int wins;
  final double scored;
  final double conceded;

  Map<String, dynamic> toJson() => {
        'games': games,
        'wins': wins,
        'winRate': games == 0 ? 0 : (wins / games * 1000).round() / 10,
        'scoredPerGame': games == 0 ? 0 : (scored / games * 10).round() / 10,
        'concededPerGame':
            games == 0 ? 0 : (conceded / games * 10).round() / 10,
      };
}

class _Simulation {
  const _Simulation(this.homeWins, this.awayWins, this.overExpected);
  final int homeWins;
  final int awayWins;
  final int overExpected;
}

class _SportCacheEntry {
  const _SportCacheEntry({required this.rows, required this.expiresAt});
  final List<Map<String, dynamic>> rows;
  final DateTime expiresAt;
}
