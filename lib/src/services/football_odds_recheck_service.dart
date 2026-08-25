import 'dart:async';
import 'dart:io';

import '../database/database.dart';
import 'football_service.dart';
import 'football_value_service.dart';

/// Läuft periodisch (Standard: alle 20 Minuten) im selben Prozess wie der
/// Webserver, analog zu PushScheduleService/FootballFavoriteLiveMonitor -
/// kein separater Cron-Job nötig.
///
/// Grund: FootballValueService.check() läuft im Tagesscan nur EIN einziges
/// Mal, oft viele Stunden vor Anpfiff. Buchmacher veröffentlichen ihre
/// Quoten für einen Teil der Spiele aber erst kurz vorher - ohne diesen
/// Nachcheck bleibt ein bereits qualifizierter PHÖNIX-Tipp für immer
/// "odds_unavailable" und taucht nie in der ROI-Historie auf, obwohl später
/// eine echte Quote existiert hätte.
class FootballOddsRecheckService {
  FootballOddsRecheckService({
    required this.database,
    required this.football,
    this.interval = const Duration(minutes: 20),
  });

  final PhoenixDatabase database;
  final FootballService football;
  final Duration interval;
  Timer? _timer;
  bool _running = false;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(runOnce()));
    unawaited(runOnce());
  }

  Future<void> runOnce() async {
    if (_running || !database.isConfigured || !football.isConfigured) return;
    _running = true;
    try {
      final candidates = await database.pendingOddsRecheckCandidates();
      if (candidates.isEmpty) return;

      final byScanRun = <int, Set<String>>{};
      for (final row in candidates) {
        final scanRunId = row['phase_two_scan_run_id'] as int?;
        final fixtureId = row['fixture_id']?.toString();
        if (scanRunId == null || fixtureId == null) continue;
        byScanRun.putIfAbsent(scanRunId, () => <String>{}).add(fixtureId);
      }

      var checked = 0;
      var newlyChecked = 0;
      for (final entry in byScanRun.entries) {
        try {
          final result = await FootballValueService(
            database: database,
            football: football,
          ).check(
            phaseTwoScanRunId: entry.key,
            limit: entry.value.length,
            fixtureIds: entry.value,
          );
          checked += entry.value.length;
          final results = result['results'];
          if (results is List) {
            newlyChecked += results
                .whereType<Map>()
                .where((r) => (r['value'] as Map?)?['status'] == 'checked')
                .length;
          }
        } catch (error) {
          stderr.writeln(
            '[ODDS RECHECK] Lauf ${entry.key} fehlgeschlagen: $error',
          );
        }
      }

      if (checked > 0) {
        stdout.writeln(
          '[ODDS RECHECK] $checked Fixture(s) geprüft, $newlyChecked '
          'davon jetzt mit echter Quote.',
        );
      }
    } finally {
      _running = false;
    }
  }

  void close() {
    _timer?.cancel();
    _timer = null;
  }
}
