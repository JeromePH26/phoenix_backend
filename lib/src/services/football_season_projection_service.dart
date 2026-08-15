import 'dart:math';

import '../database/database.dart';
import 'football_service.dart';

/// Simulates the unplayed league schedule from the real current standings.
/// Cups and UEFA competitions are excluded by the database target query.
class FootballSeasonProjectionService {
  FootballSeasonProjectionService(
      {required this.database, required this.football});

  final PhoenixDatabase database;
  final FootballService football;
  static const modelVersion = 'season_monte_carlo_v1';

  Future<Map<String, Object?>> refresh(
      {int? season, int simulations = 10000}) async {
    final targetSeason = season ?? _seasonNow();
    final safeSimulations = simulations.clamp(1000, 10000);
    final targets = await database.seasonProjectionTargets(targetSeason);
    final results = <Map<String, Object?>>[];
    for (final target in targets) {
      try {
        final projection = await _project(
          leagueId: target['leagueId']!,
          leagueName: target['leagueName']!,
          country: target['country']!,
          season: targetSeason,
          simulations: safeSimulations,
        );
        if (projection == null) {
          results.add({
            'leagueId': target['leagueId'],
            'status': 'skipped',
            'reason': 'standings_or_fixtures_unavailable'
          });
          continue;
        }
        await database.saveSeasonProjection(
          leagueId: target['leagueId']!,
          season: targetSeason,
          modelVersion: modelVersion,
          simulations: safeSimulations,
          payload: projection,
        );
        results.add({
          'leagueId': target['leagueId'],
          'status': 'completed',
          'teams': (projection['table'] as List).length
        });
      } catch (error) {
        results.add({
          'leagueId': target['leagueId'],
          'status': 'failed',
          'error': error.toString()
        });
      }
    }
    return {
      'season': targetSeason,
      'simulations': safeSimulations,
      'modelVersion': modelVersion,
      'results': results
    };
  }

  Future<Map<String, Object?>?> _project({
    required String leagueId,
    required String leagueName,
    required String country,
    required int season,
    required int simulations,
  }) async {
    final responses = await Future.wait([
      football.providerRequest(
          path: '/standings', query: {'league': leagueId, 'season': '$season'}),
      football.providerRequest(
          path: '/fixtures',
          query: {'league': leagueId, 'season': '$season', 'status': 'NS'}),
    ]);
    final fixtures = _fixtures(responses[1]);
    final standings = _standings(responses[0]);
    if (standings.length < 4) {
      final teams = _scheduledTeams(fixtures);
      if (teams.length < 4) return null;
      return {
        'leagueId': leagueId,
        'leagueName': leagueName,
        'country': country,
        'season': season,
        'modelVersion': modelVersion,
        'simulations': 0,
        'remainingFixtures': fixtures.length,
        'seasonState': 'preseason',
        'table': [
          for (var index = 0; index < teams.length; index++)
            {
              'teamId': teams[index].id,
              'teamName': teams[index].name,
              'teamLogo': teams[index].logo,
              'currentPoints': 0,
              'currentGoalDifference': 0,
              'played': 0,
              'projectedPosition': index + 1,
              'projectedPoints': 0,
              'projectedGoalDifference': 0,
              'positionProbabilities': const <double>[],
            },
        ],
      };
    }
    final table =
        _simulate(standings, fixtures, simulations, '$leagueId-$season');
    return {
      'leagueId': leagueId,
      'leagueName': leagueName,
      'country': country,
      'season': season,
      'seasonState': 'active',
      'modelVersion': modelVersion,
      'simulations': simulations,
      'remainingFixtures': fixtures.length,
      'table': table,
    };
  }

  List<_SeasonTeam> _standings(Map<String, dynamic> payload) {
    final response = payload['response'];
    if (response is! List || response.isEmpty || response.first is! Map)
      return const [];
    final league = Map<String, dynamic>.from(response.first as Map)['league'];
    if (league is! Map) return const [];
    final groups = league['standings'];
    if (groups is! List || groups.isEmpty || groups.first is! List)
      return const [];
    return (groups.first as List)
        .whereType<Map>()
        .map((raw) {
          final row = Map<String, dynamic>.from(raw);
          final team = row['team'] is Map
              ? Map<String, dynamic>.from(row['team'] as Map)
              : const <String, dynamic>{};
          final all = row['all'] is Map
              ? Map<String, dynamic>.from(row['all'] as Map)
              : const <String, dynamic>{};
          return _SeasonTeam(
            id: team['id']?.toString() ?? '',
            name: team['name']?.toString() ?? '',
            logo: team['logo']?.toString() ?? '',
            points: _integer(row['points']),
            goalDifference: _integer(row['goalsDiff']),
            played: _integer(all['played']),
          );
        })
        .where((team) => team.id.isNotEmpty && team.name.isNotEmpty)
        .toList();
  }

  List<_Fixture> _fixtures(Map<String, dynamic> payload) {
    final response = payload['response'];
    if (response is! List) return const [];
    return response
        .whereType<Map>()
        .map((raw) {
          final value = Map<String, dynamic>.from(raw);
          final teams = value['teams'] is Map
              ? Map<String, dynamic>.from(value['teams'] as Map)
              : const <String, dynamic>{};
          final home = teams['home'] is Map
              ? Map<String, dynamic>.from(teams['home'] as Map)
              : const <String, dynamic>{};
          final away = teams['away'] is Map
              ? Map<String, dynamic>.from(teams['away'] as Map)
              : const <String, dynamic>{};
          return _Fixture(
            home: _SeasonTeam(
              id: home['id']?.toString() ?? '',
              name: home['name']?.toString() ?? '',
              logo: home['logo']?.toString() ?? '',
              points: 0,
              goalDifference: 0,
              played: 0,
            ),
            away: _SeasonTeam(
              id: away['id']?.toString() ?? '',
              name: away['name']?.toString() ?? '',
              logo: away['logo']?.toString() ?? '',
              points: 0,
              goalDifference: 0,
              played: 0,
            ),
          );
        })
        .where((fixture) =>
            fixture.home.id.isNotEmpty && fixture.away.id.isNotEmpty)
        .toList();
  }

  List<_SeasonTeam> _scheduledTeams(List<_Fixture> fixtures) {
    final uniqueTeams = <String, _SeasonTeam>{};
    for (final fixture in fixtures) {
      uniqueTeams.putIfAbsent(fixture.home.id, () => fixture.home);
      uniqueTeams.putIfAbsent(fixture.away.id, () => fixture.away);
    }
    final teams = uniqueTeams.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return teams;
  }

  List<Map<String, Object?>> _simulate(List<_SeasonTeam> base,
      List<_Fixture> fixtures, int simulations, String seed) {
    final positions = {
      for (final team in base) team.id: List<int>.filled(base.length, 0)
    };
    final teamsById = {for (final team in base) team.id: team};
    final pointsTotal = {for (final team in base) team.id: 0.0};
    final goalDifferenceTotal = {for (final team in base) team.id: 0.0};
    final random = Random(_seed(seed));
    for (var run = 0; run < simulations; run++) {
      final points = {for (final team in base) team.id: team.points};
      final differences = {
        for (final team in base) team.id: team.goalDifference
      };
      for (final fixture in fixtures) {
        final home = teamsById[fixture.home.id];
        final away = teamsById[fixture.away.id];
        if (home == null || away == null) continue;
        final probability = _homeWinProbability(home, away);
        final draw = _drawProbability(home, away);
        final roll = random.nextDouble();
        if (roll < probability) {
          points[home.id] = points[home.id]! + 3;
          differences[home.id] = differences[home.id]! + 1;
          differences[away.id] = differences[away.id]! - 1;
        } else if (roll < probability + draw) {
          points[home.id] = points[home.id]! + 1;
          points[away.id] = points[away.id]! + 1;
        } else {
          points[away.id] = points[away.id]! + 3;
          differences[away.id] = differences[away.id]! + 1;
          differences[home.id] = differences[home.id]! - 1;
        }
      }
      final ordered = [...base]..sort((a, b) {
          final pointCompare = points[b.id]!.compareTo(points[a.id]!);
          return pointCompare != 0
              ? pointCompare
              : differences[b.id]!.compareTo(differences[a.id]!);
        });
      for (var index = 0; index < ordered.length; index++) {
        final id = ordered[index].id;
        positions[id]![index]++;
        pointsTotal[id] = pointsTotal[id]! + points[id]!;
        goalDifferenceTotal[id] = goalDifferenceTotal[id]! + differences[id]!;
      }
    }
    final rows = base.map((team) {
      final placeCounts = positions[team.id]!;
      final likelyPosition = placeCounts.indexOf(placeCounts.reduce(max)) + 1;
      return <String, Object?>{
        'teamId': team.id,
        'teamName': team.name,
        'teamLogo': team.logo,
        'currentPoints': team.points,
        'currentGoalDifference': team.goalDifference,
        'played': team.played,
        'projectedPoints': double.parse(
            (pointsTotal[team.id]! / simulations).toStringAsFixed(1)),
        'projectedGoalDifference': double.parse(
            (goalDifferenceTotal[team.id]! / simulations).toStringAsFixed(1)),
        'likelyPosition': likelyPosition,
        'positionProbabilities': [
          for (final count in placeCounts)
            double.parse((count / simulations * 100).toStringAsFixed(1))
        ],
      };
    }).toList();
    rows.sort((a, b) => (a['projectedPoints'] as double)
                .compareTo(b['projectedPoints'] as double) ==
            0
        ? (b['projectedGoalDifference'] as double)
            .compareTo(a['projectedGoalDifference'] as double)
        : (b['projectedPoints'] as double)
            .compareTo(a['projectedPoints'] as double));
    for (var index = 0; index < rows.length; index++) {
      rows[index]['projectedPosition'] = index + 1;
    }
    return rows;
  }

  double _homeWinProbability(_SeasonTeam home, _SeasonTeam away) {
    final homeStrength = home.played == 0
        ? 1.5
        : home.points / home.played +
            home.goalDifference / max(home.played, 1) * .08;
    final awayStrength = away.played == 0
        ? 1.5
        : away.points / away.played +
            away.goalDifference / max(away.played, 1) * .08;
    return (.42 + (homeStrength - awayStrength) * .12)
        .clamp(.16, .72)
        .toDouble();
  }

  double _drawProbability(_SeasonTeam home, _SeasonTeam away) => (.29 -
          ((home.points / max(home.played, 1)) -
                      (away.points / max(away.played, 1)))
                  .abs() *
              .035)
      .clamp(.18, .31)
      .toDouble();
  int _seasonNow() {
    final now = DateTime.now().toUtc();
    return now.month >= 7 ? now.year : now.year - 1;
  }

  int _integer(Object? value) =>
      value is num ? value.toInt() : int.tryParse(value?.toString() ?? '') ?? 0;
  int _seed(String value) => value.codeUnits
      .fold(17, (hash, value) => (hash * 31 + value) & 0x7fffffff);
}

class _SeasonTeam {
  const _SeasonTeam(
      {required this.id,
      required this.name,
      required this.logo,
      required this.points,
      required this.goalDifference,
      required this.played});
  final String id, name, logo;
  final int points, goalDifference, played;
}

class _Fixture {
  const _Fixture({required this.home, required this.away});
  final _SeasonTeam home, away;
}
