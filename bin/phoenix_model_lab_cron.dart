import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// PHÖNIX MODEL LAB Scheduler (Section 45-49). Folgt exakt demselben Muster
/// wie `phoenix_daily_cron.dart`: ein eigenständiges Dart-Skript, das die
/// bereits vorhandene Railway-Cron-Infrastruktur nutzt (kein zweiter
/// In-Process-Scheduler) und ausschließlich die geschützten Admin-HTTP-
/// Endpunkte des laufenden Servers aufruft.
///
/// Empfohlene Railway-Cron-Konfiguration: TÄGLICH gegen 04:00 Europe/Berlin
/// starten (z.B. wie der bestehende `phoenix_daily_cron.dart`-Service, aber
/// zeitlich nach dessen Settlement-Phase). Das Skript selbst entscheidet
/// serverseitig, ob heute tatsächlich etwas zu tun ist:
///   - Dienstag  -> Learning Run (Section 45).
///   - 1. Mittwoch im Monat -> Monthly Champion Review (Section 48/49).
///   - jeder andere Tag -> sauberer no-op.
/// Beide Business-Regeln werden zusätzlich serverseitig in
/// `ModelLabSchedule`/`MonthlyReviewService` durchgesetzt, falls der Cron aus
/// irgendeinem Grund an einem falschen Tag ausgelöst wird.
Future<void> main() async {
  final config = _ModelLabCronConfig.fromEnvironment();
  final nowUtc = DateTime.now().toUtc();

  stdout.writeln(
    '[PHOENIX MODEL LAB CRON] Start UTC=${nowUtc.toIso8601String()}',
  );

  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    ..idleTimeout = const Duration(seconds: 30);

  try {
    // Shadow Predictions täglich aktualisieren (Section 33-36): neue
    // Fixtures mit Snapshot vor Kickoff erhalten Shadow Predictions, bereits
    // beendete Matches werden abgerechnet. Läuft unabhängig vom Wochentag,
    // da neue Matches jeden Tag gescannt werden.
    await _post(client, config, '/api/admin/model-lab/shadow-predictions/generate');
    await _post(client, config, '/api/admin/model-lab/shadow-predictions/settle');

    final weekday = nowUtc.weekday; // Grobe UTC-Schätzung; die Server-Routen
    // selbst prüfen zusätzlich in Europe/Berlin (siehe ModelLabSchedule).
    if (weekday == DateTime.tuesday) {
      stdout.writeln('[PHOENIX MODEL LAB CRON] Dienstag: Learning Run ...');
      final response = await _post(
        client,
        config,
        '/api/admin/model-lab/learning-runs/start',
      );
      stdout.writeln('[PHOENIX MODEL LAB CRON] Learning Run: $response');
    }

    if (weekday == DateTime.wednesday) {
      stdout.writeln(
        '[PHOENIX MODEL LAB CRON] Mittwoch: prüfe Monthly Review (nur '
        'am ersten Mittwoch des Monats aktiv) ...',
      );
      final response = await _post(
        client,
        config,
        '/api/admin/model-lab/monthly-review/run',
      );
      stdout.writeln('[PHOENIX MODEL LAB CRON] Monthly Review: $response');
    }

    exitCode = 0;
  } catch (error, stackTrace) {
    stderr.writeln('[PHOENIX MODEL LAB CRON] FEHLER: $error');
    stderr.writeln(stackTrace);
    exitCode = 1;
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> _post(
  HttpClient client,
  _ModelLabCronConfig config,
  String path,
) async {
  final uri = Uri.parse('${config.backendUrl}$path');
  final request = await client.postUrl(uri);
  request.headers
    ..set(HttpHeaders.acceptHeader, 'application/json')
    ..set(HttpHeaders.authorizationHeader, 'Bearer ${config.adminToken}')
    ..set(HttpHeaders.userAgentHeader, 'PHOENIX-ModelLab-Cron/1.0');

  final response = await request.close().timeout(const Duration(minutes: 10));
  final body = await utf8.decoder.bind(response).join();

  dynamic decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    throw HttpException('Ungültige Serverantwort (${response.statusCode}): $body', uri: uri);
  }

  if (response.statusCode >= 500) {
    throw HttpException('HTTP ${response.statusCode}: $decoded', uri: uri);
  }

  return decoded is Map ? Map<String, dynamic>.from(decoded) : {'raw': decoded};
}

class _ModelLabCronConfig {
  const _ModelLabCronConfig({required this.backendUrl, required this.adminToken});

  final String backendUrl;
  final String adminToken;

  factory _ModelLabCronConfig.fromEnvironment() {
    final environment = Platform.environment;
    final backendUrl = (environment['PHOENIX_BACKEND_URL'] ??
            'https://energetic-peace-production-b6f2.up.railway.app')
        .replaceAll(RegExp(r'/+$'), '');
    final adminToken = environment['PHOENIX_ADMIN_TOKEN']?.trim() ?? '';
    if (adminToken.isEmpty) {
      throw StateError('PHOENIX_ADMIN_TOKEN fehlt im Model-Lab-Cron-Service.');
    }
    return _ModelLabCronConfig(backendUrl: backendUrl, adminToken: adminToken);
  }
}
