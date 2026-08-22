import 'dart:async';
import 'dart:io';

import '../database/database.dart';
import 'firebase_push_service.dart';

/// Section 19 (AN2): "Zeitplanung" für Push-Broadcasts. Läuft periodisch
/// (Standard: alle 60s) im selben Prozess wie der Webserver, analog zu
/// FootballFavoriteLiveMonitor - kein separater Cron-Job nötig, da die
/// Prüfung selbst sehr billig ist (eine indexierte SELECT-Abfrage).
class PushScheduleService {
  PushScheduleService({
    required this.database,
    required this.push,
    this.interval = const Duration(seconds: 60),
  });

  final PhoenixDatabase database;
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
      for (final broadcast in await database.duePushBroadcasts()) {
        try {
          await _sendDue(broadcast);
        } catch (error) {
          stderr.writeln(
            '[PUSH SCHEDULE] broadcast ${broadcast['id']} failed: $error',
          );
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _sendDue(Map<String, Object?> broadcast) async {
    final id = broadcast['id'] as int;
    final title = broadcast['title']?.toString() ?? '';
    final body = broadcast['body']?.toString() ?? '';
    final targetType = broadcast['target_type']?.toString() ?? 'all';
    final targetValue = broadcast['target_value']?.toString();
    final deepLink = broadcast['deep_link_url']?.toString();

    final targets = await database.broadcastPushTargets(
      targetType: targetType,
      targetValue: targetValue,
    );
    var sent = 0;
    var failed = 0;
    for (final target in targets) {
      try {
        await push.send(
          token: target['pushToken']!,
          title: title,
          body: body,
          androidChannelId: 'phoenix_news_v1',
          data: {
            'type': 'phoenix_broadcast',
            'broadcastId': id.toString(),
            if (deepLink != null && deepLink.isNotEmpty) 'deepLink': deepLink,
          },
        );
        sent++;
      } catch (error) {
        failed++;
        stderr.writeln('[PUSH SCHEDULE] ${target['installationId']}: $error');
      }
    }
    await database.updatePushBroadcastCounts(
      id: id,
      sentCount: sent,
      failedCount: failed,
    );
  }

  void close() {
    _timer?.cancel();
    _timer = null;
  }
}
