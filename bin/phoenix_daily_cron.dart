import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final config = _CronConfig.fromEnvironment();
  final nowUtc = DateTime.now().toUtc();
  final berlinNow = _toBerlin(nowUtc);

  stdout.writeln(
    '[PHOENIX CRON] Start UTC=${nowUtc.toIso8601String()} '
    'Berlin=${berlinNow.toIso8601String()}',
  );

  // Der Railway-Cron wird im Sommer und Winter zu zwei UTC-Zeiten gestartet.
  // Nur der Lauf, der tatsächlich in die Berliner 00-Uhr-Stunde fällt,
  // führt den Tagesscan aus. Der andere beendet sich sofort.
  final forceRun =
      Platform.environment['PHOENIX_CRON_FORCE_RUN']?.toLowerCase() ==
          'true';

  if (!forceRun && berlinNow.hour != 0) {
    stdout.writeln(
      '[PHOENIX CRON] Übersprungen: In Berlin ist es nicht 00 Uhr.',
    );
    exitCode = 0;
    return;
  }

  if (forceRun) {
    stdout.writeln('[PHOENIX CRON] Manueller Testlauf erzwungen.');
  }

  final today = DateTime(
    berlinNow.year,
    berlinNow.month,
    berlinNow.day,
  );
  final yesterday = today.subtract(const Duration(days: 1));

  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    ..idleTimeout = const Duration(seconds: 30);

  try {
    // Zuerst werden offene Tipps des Vortages abgerechnet.
    // Ein Fehler dabei darf den heutigen Tagesscan NICHT mehr stoppen.
    try {
      await _settleDate(
        client: client,
        config: config,
        date: yesterday,
      );
    } catch (error, stackTrace) {
      stderr.writeln(
        '[PHOENIX CRON] Ergebnisabrechnung übersprungen: $error',
      );
      stderr.writeln(stackTrace);
    }

    // Danach wird der komplette heutige PHÖNIX-Lauf gestartet.
    final jobId = await _startDailyScan(
      client: client,
      config: config,
      date: today,
    );

    await _waitForCompletion(
      client: client,
      config: config,
      jobId: jobId,
    );

    stdout.writeln('[PHOENIX CRON] Tageslauf vollständig abgeschlossen.');
    exitCode = 0;
  } catch (error, stackTrace) {
    stderr.writeln('[PHOENIX CRON] FEHLER: $error');
    stderr.writeln(stackTrace);
    exitCode = 1;
  } finally {
    client.close(force: true);
  }
}

Future<void> _settleDate({
  required HttpClient client,
  required _CronConfig config,
  required DateTime date,
}) async {
  final day = _day(date);
  final uri = config.uri(
    '/api/admin/football/settle',
    {'date': day},
  );

  stdout.writeln('[PHOENIX CRON] Ergebnisabrechnung für $day ...');

  final response = await _requestJson(
    client: client,
    uri: uri,
    method: 'POST',
    adminToken: config.adminToken,
  );

  stdout.writeln(
    '[PHOENIX CRON] Abrechnung: '
    'settled=${response['settled'] ?? 0}, '
    'skipped=${response['skipped'] ?? 0}',
  );
}

Future<int> _startDailyScan({
  required HttpClient client,
  required _CronConfig config,
  required DateTime date,
}) async {
  final day = _day(date);
  final uri = config.uri(
    '/api/admin/football/daily-scan',
    {
      'date': day,
      'limit': config.limit.toString(),
      'minimumDataQuality': config.minimumDataQuality.toString(),
      'simulations': config.simulations.toString(),
    },
  );

  stdout.writeln(
    '[PHOENIX CRON] Starte Tagesscan $day '
    '(Limit ${config.limit}, Datenqualität '
    '${config.minimumDataQuality}, Simulationen ${config.simulations}) ...',
  );

  final response = await _requestJson(
    client: client,
    uri: uri,
    method: 'POST',
    adminToken: config.adminToken,
  );

  final jobId = _integer(response['jobId']);
  if (jobId == null || jobId < 1) {
    throw StateError(
      'Der Server hat keine gültige Job-ID geliefert: $response',
    );
  }

  stdout.writeln('[PHOENIX CRON] Job $jobId wurde gestartet.');
  return jobId;
}

Future<void> _waitForCompletion({
  required HttpClient client,
  required _CronConfig config,
  required int jobId,
}) async {
  final deadline = DateTime.now().add(config.maximumRuntime);
  String? lastStep;
  int? lastProcessed;

  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(config.pollingInterval);

    final uri = config.uri(
      '/api/admin/football/daily-scan/$jobId',
    );
    final response = await _requestJson(
      client: client,
      uri: uri,
      method: 'GET',
      adminToken: config.adminToken,
    );

    final status = response['status']?.toString().toLowerCase() ?? '';
    final step =
        response['current_step']?.toString() ??
        response['currentStep']?.toString() ??
        '';
    final processed = _integer(response['processed']) ?? 0;
    final published = _integer(response['published']) ?? 0;

    if (step != lastStep || processed != lastProcessed) {
      stdout.writeln(
        '[PHOENIX CRON] Job $jobId: status=$status, '
        'step=$step, processed=$processed, published=$published',
      );
      lastStep = step;
      lastProcessed = processed;
    }

    if (status == 'completed') {
      return;
    }

    if (status == 'failed' ||
        status == 'error' ||
        status == 'interrupted') {
      throw StateError(
        'Tagesscan $jobId wurde mit Status "$status" beendet: '
        '${response['error'] ?? response['last_error'] ?? response}',
      );
    }
  }

  throw TimeoutException(
    'Tagesscan $jobId wurde nach '
    '${config.maximumRuntime.inMinutes} Minuten nicht abgeschlossen.',
  );
}

Future<Map<String, dynamic>> _requestJson({
  required HttpClient client,
  required Uri uri,
  required String method,
  required String adminToken,
}) async {
  final request = switch (method) {
    'POST' => await client.postUrl(uri),
    'GET' => await client.getUrl(uri),
    _ => throw ArgumentError('Nicht unterstützte HTTP-Methode: $method'),
  };

  request.headers
    ..set(HttpHeaders.acceptHeader, 'application/json')
    ..set(HttpHeaders.authorizationHeader, 'Bearer $adminToken')
    ..set(HttpHeaders.userAgentHeader, 'PHOENIX-Railway-Cron/1.0');

  final response = await request.close().timeout(
    const Duration(minutes: 2),
  );
  final body = await utf8.decoder.bind(response).join();

  dynamic decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    throw HttpException(
      'Ungültige Serverantwort (${response.statusCode}): $body',
      uri: uri,
    );
  }

  if (response.statusCode < 200 || response.statusCode >= 300) {
    final message = decoded is Map
        ? decoded['error']?.toString() ?? decoded.toString()
        : decoded.toString();
    throw HttpException(
      'HTTP ${response.statusCode}: $message',
      uri: uri,
    );
  }

  if (decoded is! Map) {
    throw HttpException(
      'JSON-Objekt erwartet, erhalten: $decoded',
      uri: uri,
    );
  }

  return Map<String, dynamic>.from(decoded);
}

class _CronConfig {
  const _CronConfig({
    required this.backendUrl,
    required this.adminToken,
    required this.limit,
    required this.minimumDataQuality,
    required this.simulations,
    required this.pollingInterval,
    required this.maximumRuntime,
  });

  final String backendUrl;
  final String adminToken;
  final int limit;
  final int minimumDataQuality;
  final int simulations;
  final Duration pollingInterval;
  final Duration maximumRuntime;

  factory _CronConfig.fromEnvironment() {
    final environment = Platform.environment;
    final backendUrl = (
      environment['PHOENIX_BACKEND_URL'] ??
      'https://energetic-peace-production-b6f2.up.railway.app'
    ).replaceAll(RegExp(r'/+$'), '');

    final adminToken =
        environment['PHOENIX_ADMIN_TOKEN']?.trim() ?? '';
    if (adminToken.isEmpty) {
      throw StateError('PHOENIX_ADMIN_TOKEN fehlt im Cron-Service.');
    }

    int integer(String name, int fallback) {
      return int.tryParse(environment[name] ?? '') ?? fallback;
    }

    return _CronConfig(
      backendUrl: backendUrl,
      adminToken: adminToken,
      limit: integer('PHOENIX_CRON_LIMIT', 20).clamp(1, 20),
      minimumDataQuality:
          integer('PHOENIX_CRON_MINIMUM_DATA_QUALITY', 50).clamp(0, 100),
      simulations:
          integer('PHOENIX_CRON_SIMULATIONS', 10000).clamp(1000, 100000),
      pollingInterval: Duration(
        seconds: integer('PHOENIX_CRON_POLL_SECONDS', 30).clamp(10, 300),
      ),
      maximumRuntime: Duration(
        minutes:
            integer('PHOENIX_CRON_MAX_MINUTES', 90).clamp(10, 180),
      ),
    );
  }

  Uri uri(
    String path, [
    Map<String, String> query = const <String, String>{},
  ]) {
    return Uri.parse('$backendUrl$path').replace(
      queryParameters: query.isEmpty ? null : query,
    );
  }
}

DateTime _toBerlin(DateTime utc) {
  final year = utc.year;
  final summerStart = _lastSundayUtc(
    year: year,
    month: DateTime.march,
    hour: 1,
  );
  final summerEnd = _lastSundayUtc(
    year: year,
    month: DateTime.october,
    hour: 1,
  );

  final isSummerTime =
      !utc.isBefore(summerStart) && utc.isBefore(summerEnd);
  return utc.add(Duration(hours: isSummerTime ? 2 : 1));
}

DateTime _lastSundayUtc({
  required int year,
  required int month,
  required int hour,
}) {
  final lastDay = DateTime.utc(year, month + 1, 0, hour);
  final daysSinceSunday = lastDay.weekday % 7;
  return lastDay.subtract(Duration(days: daysSinceSunday));
}

String _day(DateTime value) {
  return '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

int? _integer(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '');
}
