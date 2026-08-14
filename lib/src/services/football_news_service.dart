import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../database/database.dart';
import 'firebase_push_service.dart';
import 'football_service.dart';
import 'phoenix_editorial_composer.dart';
import 'football_season_projection_service.dart';

/// Own, fact-bound Phoenix reporting. External RSS content is deliberately not
/// used here: every article is generated from stored match/analysis data or a
/// confirmed API-Football transfer response.
class FootballNewsService {
  FootballNewsService({
    required this.database,
    required this.push,
    required this.football,
    PhoenixEditorialComposer? composer,
  }) : _composer = composer ?? const PhoenixEditorialComposer();

  final PhoenixDatabase database;
  final FirebasePushService push;
  final FootballService football;
  final PhoenixEditorialComposer _composer;
  Timer? _timer;
  DateTime? _lastRefresh;
  DateTime? _lastTransferSync;
  DateTime? _lastSeasonProjection;
  bool _refreshing = false;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => unawaited(refresh()),
    );
    unawaited(refresh());
  }

  Future<void> refreshIfStale() async {
    final last = _lastRefresh;
    if (last == null ||
        DateTime.now().difference(last) > const Duration(minutes: 12)) {
      await refresh();
    }
  }

  Future<void> refresh() async {
    if (_refreshing || !database.isConfigured) return;
    _refreshing = true;
    try {
      final rows = await database.phoenixEditorialMatches();
      final matches =
          rows.map(_match).whereType<PhoenixEditorialMatch>().toList();
      for (final match in matches) {
        if (_isFinished(rows
                .firstWhere(
                    (row) => row['id']?.toString() == match.fixtureId)['status']
                ?.toString() ??
            '')) {
          await _storeMatchArticle(match, review: true);
        } else if (match.kickoff.isAfter(DateTime.now().toUtc()) &&
            match.kickoff.isBefore(
                DateTime.now().toUtc().add(const Duration(hours: 48)))) {
          await _storeMatchArticle(match, review: false);
        }
      }
      await _syncTransfersOncePerDay(matches);
      await _refreshSeasonProjectionsOncePerDay();
      _lastRefresh = DateTime.now();
    } catch (error, stackTrace) {
      stderr.writeln('[PHOENIX NEWS] $error');
      stderr.writeln(stackTrace);
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _refreshSeasonProjectionsOncePerDay() async {
    final now = DateTime.now().toUtc();
    final last = _lastSeasonProjection;
    if (last != null &&
        last.year == now.year &&
        last.month == now.month &&
        last.day == now.day) {
      return;
    }
    _lastSeasonProjection = now;
    try {
      await FootballSeasonProjectionService(
              database: database, football: football)
          .refresh();
    } catch (error) {
      stderr.writeln('[PHOENIX SEASON PROJECTIONS] $error');
    }
  }

  Future<void> _storeMatchArticle(
    PhoenixEditorialMatch match, {
    required bool review,
  }) async {
    final article = review
        ? _composer.composeReview(match)
        : _composer.composePreview(match);
    final kind = article.kind;
    final uri = 'phoenix://report/$kind/${match.fixtureId}';
    final inserted = await database.upsertNewsArticle({
      'id': _id(uri),
      'sourceName': 'PHOENIX',
      'sourceUrl': 'phoenix://reports',
      'articleUrl': uri,
      'title': article.title,
      'summary': article.summary,
      'body': article.body,
      'articleType': kind,
      'imageUrl': '',
      'category': review ? 'match_report' : 'match_preview',
      'importance': article.importance,
      'teamIds': [match.homeTeamId, match.awayTeamId],
      'teamNames': [match.homeTeam, match.awayTeam],
      'leagueIds': [match.leagueId],
      'leagueNames': [match.leagueName],
      'publishedAt': review ? DateTime.now().toUtc() : match.kickoff.toUtc(),
    });
    if (inserted && article.importance >= 70 && push.isConfigured) {
      await _notifyFavorites(
        id: _id(uri),
        title: article.title,
        teamIds: [match.homeTeamId, match.awayTeamId],
        leagueIds: [match.leagueId],
      );
    }
  }

  Future<void> _syncTransfersOncePerDay(
    List<PhoenixEditorialMatch> matches,
  ) async {
    final now = DateTime.now().toUtc();
    final last = _lastTransferSync;
    if (last != null &&
        last.year == now.year &&
        last.month == now.month &&
        last.day == now.day) {
      return;
    }
    _lastTransferSync = now;

    final teams =
        <String, ({String name, String leagueId, String leagueName})>{};
    for (final match in matches) {
      teams[match.homeTeamId] = (
        name: match.homeTeam,
        leagueId: match.leagueId,
        leagueName: match.leagueName,
      );
      teams[match.awayTeamId] = (
        name: match.awayTeam,
        leagueId: match.leagueId,
        leagueName: match.leagueName,
      );
    }

    // One request per active whitelisted team per day. At the current league
    // scope this stays far below the 7,500-request plan; failures are optional
    // and never block match reports.
    for (final entry in teams.entries) {
      try {
        final payload = await football.providerRequest(
          path: '/transfers',
          query: {'team': entry.key},
        );
        final response = payload['response'];
        if (response is! List) continue;
        for (final item in response.whereType<Map>()) {
          await _storeRecentTransfers(
            teamId: entry.key,
            teamName: entry.value.name,
            leagueId: entry.value.leagueId,
            leagueName: entry.value.leagueName,
            raw: Map<String, Object?>.from(item),
          );
        }
      } catch (error) {
        stderr.writeln('[PHOENIX TRANSFERS] ${entry.value.name}: $error');
      }
    }
  }

  Future<void> _storeRecentTransfers({
    required String teamId,
    required String teamName,
    required String leagueId,
    required String leagueName,
    required Map<String, Object?> raw,
  }) async {
    final player = _map(raw['player']);
    final playerId = player['id']?.toString() ?? '';
    final playerName = player['name']?.toString().trim() ?? '';
    final transfers = raw['transfers'];
    if (playerId.isEmpty || playerName.isEmpty || transfers is! List) return;
    for (final transferValue in transfers.whereType<Map>()) {
      final transfer = Map<String, Object?>.from(transferValue);
      final date =
          DateTime.tryParse(transfer['date']?.toString() ?? '')?.toUtc();
      if (date == null ||
          DateTime.now().toUtc().difference(date) > const Duration(days: 14))
        continue;
      final teams = _map(transfer['teams']);
      final incoming = _map(teams['in']);
      final outgoing = _map(teams['out']);
      final incomingId = incoming['id']?.toString() ?? '';
      final outgoingId = outgoing['id']?.toString() ?? '';
      final direction = incomingId == teamId
          ? 'in'
          : outgoingId == teamId
              ? 'out'
              : '';
      if (direction.isEmpty) continue;
      final article = _composer.composeTransfer(
        teamName: teamName,
        playerName: playerName,
        direction: direction,
        leagueName: leagueName,
        transferId:
            '$teamId-$playerId-${date.toIso8601String().substring(0, 10)}-$direction',
      );
      final uri =
          'phoenix://transfer/$teamId/$playerId/${date.toIso8601String().substring(0, 10)}/$direction';
      final inserted = await database.upsertNewsArticle({
        'id': _id(uri),
        'sourceName': 'PHOENIX',
        'sourceUrl': 'phoenix://reports',
        'articleUrl': uri,
        'title': article.title,
        'summary': article.summary,
        'body': article.body,
        'articleType': article.kind,
        'imageUrl': '',
        'category': 'transfer',
        'importance': article.importance,
        'teamIds': [teamId],
        'teamNames': [teamName],
        'leagueIds': [leagueId],
        'leagueNames': [leagueName],
        'publishedAt': date,
      });
      if (inserted && push.isConfigured) {
        await _notifyFavorites(
          id: _id(uri),
          title: article.title,
          teamIds: [teamId],
          leagueIds: [leagueId],
        );
      }
    }
  }

  PhoenixEditorialMatch? _match(Map<String, Object?> row) {
    final id = row['id']?.toString() ?? '';
    final leagueId = row['league_id']?.toString() ?? '';
    final homeId = row['home_team_id']?.toString() ?? '';
    final awayId = row['away_team_id']?.toString() ?? '';
    final homeName = row['home_team_name']?.toString() ?? '';
    final awayName = row['away_team_name']?.toString() ?? '';
    final kickoff = row['kickoff_utc'] as DateTime?;
    if (id.isEmpty ||
        leagueId.isEmpty ||
        homeId.isEmpty ||
        awayId.isEmpty ||
        homeName.isEmpty ||
        awayName.isEmpty ||
        kickoff == null) return null;
    final payload = _map(row['analysis_payload']);
    final probabilities = _map(payload['probabilities']);
    return PhoenixEditorialMatch(
      fixtureId: id,
      leagueId: leagueId,
      leagueName: row['league_name']?.toString() ?? '',
      homeTeamId: homeId,
      homeTeam: homeName,
      awayTeamId: awayId,
      awayTeam: awayName,
      kickoff: kickoff.toUtc(),
      homeGoals: _integerOrNull(row['home_goals']),
      awayGoals: _integerOrNull(row['away_goals']),
      homeProbability:
          _probability(probabilities['home'] ?? probabilities['homeWin']),
      drawProbability: _probability(probabilities['draw']),
      awayProbability:
          _probability(probabilities['away'] ?? probabilities['awayWin']),
    );
  }

  Future<void> _notifyFavorites({
    required String id,
    required String title,
    required List<String> teamIds,
    required List<String> leagueIds,
  }) async {
    final targets = await database.newsPushTargets(
      teamIds: teamIds,
      leagueIds: leagueIds,
    );
    for (final target in targets) {
      final installationId = target['installationId']!;
      if (!await database.claimNewsPush(id, installationId)) continue;
      try {
        await push.send(
          token: target['pushToken']!,
          title: 'PHOENIX · Bericht',
          body: title,
          androidChannelId: 'phoenix_news_v1',
          data: {'type': 'phoenix_report', 'articleId': id},
        );
      } catch (error) {
        stderr.writeln('[PHOENIX NEWS PUSH] $installationId: $error');
      }
    }
  }

  bool _isFinished(String status) =>
      const {'FT', 'AET', 'PEN', 'AWD', 'WO'}.contains(status.toUpperCase());

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  int? _integerOrNull(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  double? _probability(Object? value) {
    final number = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    if (number == null || !number.isFinite) return null;
    return number > 1 ? number / 100 : number.clamp(0, 1).toDouble();
  }

  String _id(String value) => sha256.convert(utf8.encode(value)).toString();

  void close() {
    _timer?.cancel();
  }
}
