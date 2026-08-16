import 'dart:io';

import '../database/database.dart';
import 'football_service.dart';

/// Ergänzt Endergebnisse in `football_matches`, ohne je Pre-Match-Daten
/// (phaseOne, phaseTwo, Quoten, Formdaten, H2H, Gemini-Kontext, ...) zu
/// berühren. Bedient sowohl den einmaligen Backfill historischer Phase-2-
/// Spiele als auch den wiederkehrenden Tages-Check offener Spiele - beide
/// laufen über dieselbe Kandidatenauswahl und denselben Merge-Schreibpfad,
/// damit es kein zweites, abweichendes Settlement-System gibt.
class FootballMatchBackfillService {
  FootballMatchBackfillService({
    required this.database,
    required this.football,
  });

  final PhoenixDatabase database;
  final FootballService football;

  static const _finished = {'FT', 'AET', 'PEN', 'AWD', 'WO'};
  static const _voided = {'CANC', 'ABD'};

  /// Verarbeitet Batches, bis keine offenen Kandidaten mehr übrig sind oder
  /// [maxFixtures] erreicht ist. Der Batch-Aufruf selbst bleibt klein
  /// ([batchSize]), damit ein einzelner API-Football-Ausfall nur wenige
  /// Spiele betrifft und der Fortschritt regelmäßig sichtbar wird.
  Future<Map<String, Object?>> run({
    required int jobId,
    int minHoursSinceKickoff = 3,
    int batchSize = 25,
    int maxFixtures = 2000,
    Duration pauseBetweenCalls = const Duration(milliseconds: 350),
  }) async {
    var checked = 0;
    var settled = 0;
    var pending = 0;
    var failed = 0;
    // Ein Spiel, das noch läuft oder verschoben ist, bleibt bis zum nächsten
    // Lauf in der Kandidatenliste stehen (Status ändert sich nicht sofort).
    // Ohne dieses Set würde dieselbe Batch-Abfrage es in jeder weiteren
    // Iteration erneut liefern und den Lauf in eine sinnlose Endlosschleife
    // von wiederholten Provider-Abrufen für dasselbe Spiel schicken.
    final visitedThisRun = <String>{};

    try {
      while (checked < maxFixtures) {
        final candidates = await database.footballMatchResultCandidates(
          minHoursSinceKickoff: minHoursSinceKickoff,
          limit: batchSize,
        );
        final newCandidates = candidates
            .where((row) => !visitedThisRun.contains(row['id']?.toString()))
            .toList();
        if (newCandidates.isEmpty) break;

        for (final row in newCandidates) {
          final fixtureId = row['id']?.toString() ?? '';
          if (fixtureId.isEmpty) continue;
          visitedThisRun.add(fixtureId);
          checked++;

          try {
            final fresh = await football.fixtureById(fixtureId);
            if (fresh == null) {
              pending++;
            } else {
              final status =
                  fresh['status']?.toString().toUpperCase() ?? '';
              if (_voided.contains(status)) {
                // Abgesagte/abgebrochene Partien dürfen nicht dauerhaft als
                // offen gelten, bekommen aber bewusst kein erfundenes
                // Ergebnis.
                await database.settleFootballMatchResult(
                  fixtureId: fixtureId,
                  status: status,
                );
                settled++;
                stdout.writeln(
                  '[PHOENIX MATCH SETTLE] $fixtureId -> $status (kein Ergebnis)',
                );
              } else if (_finished.contains(status)) {
                final homeGoals = _int(fresh['homeGoals']);
                final awayGoals = _int(fresh['awayGoals']);
                if (homeGoals == null || awayGoals == null) {
                  // Anbieter meldet FT, liefert aber (noch) keine Tore -
                  // lieber erneut prüfen als ein unvollständiges Ergebnis
                  // schreiben.
                  pending++;
                } else {
                  await database.settleFootballMatchResult(
                    fixtureId: fixtureId,
                    status: status,
                    homeGoals: homeGoals,
                    awayGoals: awayGoals,
                  );
                  settled++;
                  stdout.writeln(
                    '[PHOENIX MATCH SETTLE] $fixtureId -> $status '
                    '$homeGoals:$awayGoals',
                  );
                }
              } else {
                // Live, verschoben oder noch nicht angepfiffen - beim
                // nächsten Lauf erneut versuchen.
                pending++;
              }
            }
          } catch (error) {
            failed++;
            stderr.writeln(
              '[PHOENIX MATCH SETTLE] Fixture $fixtureId fehlgeschlagen: $error',
            );
          }

          if (pauseBetweenCalls > Duration.zero) {
            await Future<void>.delayed(pauseBetweenCalls);
          }
        }

        await database.updateFootballMatchSettlementJob(
          jobId: jobId,
          status: 'running',
          checked: checked,
          settled: settled,
          pending: pending,
          failed: failed,
        );

        // Kleinere Batches als die angeforderte Größe heißen: die Warteschlange
        // ist für diesen Lauf leer.
        if (candidates.length < batchSize) break;
      }

      await database.updateFootballMatchSettlementJob(
        jobId: jobId,
        status: 'completed',
        checked: checked,
        settled: settled,
        pending: pending,
        failed: failed,
        completed: true,
      );

      return {
        'status': 'completed',
        'checked': checked,
        'settled': settled,
        'pending': pending,
        'failed': failed,
      };
    } catch (error) {
      await database.updateFootballMatchSettlementJob(
        jobId: jobId,
        status: 'failed',
        checked: checked,
        settled: settled,
        pending: pending,
        failed: failed,
        error: error,
        completed: true,
      );
      rethrow;
    }
  }

  int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '');
  }
}
