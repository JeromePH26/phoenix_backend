import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../database/database.dart';
import 'firebase_push_service.dart';
import 'football_service.dart';

class FootballFavoriteLiveMonitor {
  FootballFavoriteLiveMonitor({
    required this.database,
    required this.football,
    required this.push,
    this.interval = const Duration(seconds: 5),
  });

  final PhoenixDatabase database;
  final FootballService football;
  final FirebasePushService push;
  final Duration interval;
  Timer? _timer;
  bool _running = false;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(runOnce()));
    unawaited(runOnce());
  }

  Future<void> runOnce() async {
    if (_running || !database.isConfigured || !push.isConfigured) return;
    _running = true;
    try {
      for (final fixtureId in await database.trackedFavoriteFixtureIds()) {
        try {
          await _processFixture(fixtureId);
        } catch (error) {
          stderr.writeln('[PUSH] fixture $fixtureId failed: $error');
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _processFixture(String fixtureId) async {
    final snapshot = await football.liveSnapshot(fixtureId);
    final events = snapshot['events'];
    if (events is List) {
      for (final value in events) {
        if (value is! Map) continue;
        final event = Map<String, Object?>.from(value);
        final type = event['type']?.toString() ?? '';
        if (!const {'goal', 'red_card', 'penalty_missed'}.contains(type))
          continue;
        final key = 'provider:${event['id']}';
        await _publish(snapshot, key, type, event);
      }
    }

    final status = snapshot['statusShort']?.toString().toUpperCase() ?? '';
    if (const {'1H', '2H', 'LIVE', 'IN_PLAY'}.contains(status)) {
      await _publish(snapshot, 'status:kickoff', 'kickoff', snapshot);
    } else if (const {'HT', 'HALFTIME', 'PAUSED'}.contains(status)) {
      await _publish(snapshot, 'status:halftime', 'halftime', snapshot);
    } else if (const {'FT', 'AET', 'PEN', 'FINISHED'}.contains(status)) {
      await _publish(snapshot, 'status:fulltime', 'fulltime', snapshot);
    }
  }

  Future<void> _publish(
    Map<String, Object?> snapshot,
    String eventKey,
    String type,
    Map<String, Object?> payload,
  ) async {
    final fixtureId = snapshot['fixtureId']?.toString() ?? '';
    if (!await database.claimFootballLiveEvent(
      fixtureId: fixtureId,
      eventKey: eventKey,
      eventType: type,
      payload: payload,
    )) return;

    final home = (snapshot['homeTeam'] as Map?)?['name']?.toString() ?? 'Heim';
    final away =
        (snapshot['awayTeam'] as Map?)?['name']?.toString() ?? 'Auswärts';
    final score = '${snapshot['homeGoals'] ?? 0}:${snapshot['awayGoals'] ?? 0}';
    final title = switch (type) {
      'goal' => '⚽ TOR! $score',
      'red_card' => '🟥 Rote Karte',
      'penalty_missed' => 'Elfmeter verschossen',
      'kickoff' => 'Anpfiff',
      'halftime' => 'Halbzeit · $score',
      'fulltime' => 'Abpfiff · $score',
      _ => 'PHÖNIX Live',
    };
    final body = '$home – $away';
    final channel = type == 'goal'
        ? 'phoenix_favorite_goals_v1'
        : 'phoenix_favorite_whistle_v1';

    for (final target in await database.pushTargetsForFixture(fixtureId)) {
      final installationId = target['installationId']!;
      try {
        final response = await push.send(
          token: target['pushToken']!,
          title: title,
          body: body,
          androidChannelId: channel,
          data: {
            'type': type,
            'fixtureId': fixtureId,
            'eventKey': eventKey,
            'score': score,
            'payload': jsonEncode(payload),
          },
        );
        await database.recordPushDelivery(
          fixtureId: fixtureId,
          eventKey: eventKey,
          installationId: installationId,
          status: response.statusCode < 300 ? 'sent' : 'failed',
          providerResponse: response.body,
        );
      } catch (error) {
        await database.recordPushDelivery(
          fixtureId: fixtureId,
          eventKey: eventKey,
          installationId: installationId,
          status: 'failed',
          providerResponse: error.toString(),
        );
      }
    }
  }

  void close() {
    _timer?.cancel();
    _timer = null;
    push.close();
  }
}
