import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';

import 'package:phoenix_backend/src/config/app_config.dart';
import 'package:phoenix_backend/src/database/database.dart';

/// Importiert die externen Historical-Twins-Datensätze (Matches.csv,
/// EloRatings.csv) chronologisch in `historical_twin_matches` /
/// `historical_elo_ratings`.
///
/// KRITISCH gegen Data Leakage: Für jedes Match werden zuerst die
/// Rolling-Features aus der bisherigen Team-Historie berechnet und erst
/// DANACH das eigene Ergebnis dieser Historie hinzugefügt. Kein Feature
/// eines Matches enthält jemals Daten aus diesem Match selbst oder aus
/// später gespielten Matches.
///
/// Aufruf:
///   dart run bin/import_historical_twins.dart --limit=1000
///   dart run bin/import_historical_twins.dart            (voller Import)
///   dart run bin/import_historical_twins.dart --skip-elo
const _importVersion = 'historical_twins_v1';
const _rollingWindow = 5;

Future<void> main(List<String> args) async {
  final limit = _argInt(args, '--limit');
  final skipElo = args.contains('--skip-elo');
  final skipMatches = args.contains('--skip-matches');
  // Historie wird IMMER ab dem allerersten CSV-Datum aufgebaut (sonst
  // Leakage-Risiko für die erste Saison nach dem Cutoff) - dieser Parameter
  // bestimmt nur, ab welchem Datum tatsächlich in die DB geschrieben wird.
  // So lässt sich gezielt ein neuerer Zeitraum ergänzen (z. B. 2020-2025),
  // ohne den bereits gespeicherten Bereich erneut zu schreiben und ohne den
  // knappen Speicherplatz mit nicht benötigten Zwischenjahren zu belasten.
  final insertFromDate = _argString(args, '--insert-from');

  final config = AppConfig.fromEnvironment();
  final database = PhoenixDatabase(config.databaseUrl);
  if (!database.isConfigured) {
    stderr.writeln('[TWINS IMPORT] DATABASE_URL fehlt.');
    exitCode = 1;
    return;
  }

  stdout.writeln('[TWINS IMPORT] Phase 1: Migration ...');
  await database.migrate();
  stdout.writeln('[TWINS IMPORT] Migration abgeschlossen.');

  if (!skipElo) {
    await _importEloRatings(database);
  }

  if (!skipMatches) {
    await _importMatches(
      database,
      limit: limit,
      insertFromDate: insertFromDate == null
          ? null
          : DateTime.tryParse(insertFromDate),
    );
  }

  await database.close();
  stdout.writeln('[TWINS IMPORT] Fertig.');
}

Future<void> _importEloRatings(PhoenixDatabase database) async {
  final file = File('data/historical_twins/EloRatings.csv');
  if (!file.existsSync()) {
    stdout.writeln(
      '[TWINS IMPORT] data/historical_twins/EloRatings.csv nicht gefunden - '
      'überspringe Elo-Zeitreihe.',
    );
    return;
  }

  stdout.writeln('[TWINS IMPORT] Lese EloRatings.csv ...');
  final lines = await file.readAsLines(encoding: utf8);
  if (lines.isEmpty) return;
  final header = _splitCsvLine(lines.first);
  final col = {for (var i = 0; i < header.length; i++) header[i]: i};

  final conn = await database.connection();
  var inserted = 0, invalid = 0, duplicates = 0;
  const insertBatchSize = 200;
  const commitBatchSize = 4000;

  final validRows = <Map<String, Object?>>[];
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim().isEmpty) continue;
    final fields = _splitCsvLine(line);
    if (fields.length < header.length) {
      invalid++;
      continue;
    }
    final date = fields[col['date'] ?? 0];
    final club = fields[col['club'] ?? 1];
    final country = col.containsKey('country') ? fields[col['country']!] : '';
    final elo = _double(fields[col['elo'] ?? 3]);
    final parsedDate = DateTime.tryParse(date);
    if (parsedDate == null || club.trim().isEmpty || elo == null) {
      invalid++;
      continue;
    }
    validRows.add({
      'date': parsedDate,
      'club': club.trim(),
      'country': country.trim(),
      'elo': elo,
    });
  }

  // Gleiches Batching-Prinzip wie beim Matches-Import: Multi-Row-INSERTs
  // statt einer Anweisung pro Zeile, Transaktionsgrenze pro Commit-Batch
  // statt einer einzigen Transaktion für alle 245.000 Zeilen.
  for (var batchStart = 0;
      batchStart < validRows.length;
      batchStart += commitBatchSize) {
    final batchEnd = (batchStart + commitBatchSize < validRows.length)
        ? batchStart + commitBatchSize
        : validRows.length;

    await conn.runTx<void>((session) async {
      for (var insertStart = batchStart;
          insertStart < batchEnd;
          insertStart += insertBatchSize) {
        final insertEnd = (insertStart + insertBatchSize < batchEnd)
            ? insertStart + insertBatchSize
            : batchEnd;
        final chunk = validRows.sublist(insertStart, insertEnd);

        final valuesSql = <String>[];
        final parameters = <String, Object?>{};
        for (var r = 0; r < chunk.length; r++) {
          valuesSql.add('(@date_$r, @club_$r, @country_$r, @elo_$r)');
          chunk[r].forEach((key, value) => parameters['${key}_$r'] = value);
        }

        try {
          final result = await session.execute(
            Sql.named('''
              INSERT INTO historical_elo_ratings (rating_date, club, country, elo)
              VALUES ${valuesSql.join(',')}
              ON CONFLICT (rating_date, club) DO NOTHING
            '''),
            parameters: parameters,
          );
          inserted += result.affectedRows;
          duplicates += chunk.length - result.affectedRows;
        } catch (error) {
          invalid += chunk.length;
          stderr.writeln('[TWINS IMPORT] Elo-Batch-Fehler: $error');
        }
      }
    });

    stdout.writeln(
      '[TWINS IMPORT] Elo: $batchEnd/${validRows.length} verarbeitet '
      '(inserted=$inserted duplicates=$duplicates invalid=$invalid)',
    );
  }

  stdout.writeln(
    '[TWINS IMPORT] EloRatings.csv fertig: inserted=$inserted '
    'duplicates=$duplicates invalid=$invalid',
  );
}

Future<void> _importMatches(
  PhoenixDatabase database, {
  int? limit,
  DateTime? insertFromDate,
}) async {
  if (insertFromDate != null) {
    stdout.writeln(
      '[TWINS IMPORT] Historie wird ab dem ersten CSV-Datum aufgebaut, '
      'aber nur Matches ab ${insertFromDate.toIso8601String().substring(0, 10)} '
      'werden geschrieben.',
    );
  }
  final file = File('data/historical_twins/Matches.csv');
  if (!file.existsSync()) {
    stdout.writeln(
      '[TWINS IMPORT] data/historical_twins/Matches.csv nicht gefunden. '
      'Architektur ist vorbereitet, aber es wurde nichts importiert.',
    );
    return;
  }

  stdout.writeln('[TWINS IMPORT] Lese Matches.csv ...');
  final lines = await file.readAsLines(encoding: utf8);
  if (lines.isEmpty) return;
  final header = _splitCsvLine(lines.first);
  final col = {for (var i = 0; i < header.length; i++) header[i]: i};

  String? field(List<String> row, String name) {
    final index = col[name];
    if (index == null || index >= row.length) return null;
    final value = row[index].trim();
    return value.isEmpty ? null : value;
  }

  final rows = <List<String>>[];
  var rowsRead = 0;
  var invalidParse = 0;
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim().isEmpty) continue;
    final fields = _splitCsvLine(line);
    if (fields.length < header.length) {
      invalidParse++;
      continue;
    }
    rowsRead++;
    rows.add(fields);
  }
  stdout.writeln('[TWINS IMPORT] $rowsRead Zeilen gelesen (ungültig: $invalidParse).');

  // KRITISCH: Chronologische Sortierung ist Voraussetzung für Leakage-freie
  // Rolling-Features. Matches.csv ist grob, aber nicht garantiert streng
  // sortiert (Divisionen liegen blockweise hintereinander).
  rows.sort((a, b) {
    final dateA = field(a, 'MatchDate') ?? '';
    final dateB = field(b, 'MatchDate') ?? '';
    final cmp = dateA.compareTo(dateB);
    if (cmp != 0) return cmp;
    return (field(a, 'MatchTime') ?? '').compareTo(field(b, 'MatchTime') ?? '');
  });

  final effectiveRows = limit != null && limit < rows.length
      ? rows.sublist(0, limit)
      : rows;
  stdout.writeln(
    '[TWINS IMPORT] Verarbeite ${effectiveRows.length} Zeilen chronologisch '
    '(limit=${limit ?? "kein Limit"}).',
  );

  final histories = <String, _TeamHistory>{};
  _TeamHistory historyFor(String team) =>
      histories.putIfAbsent(team, () => _TeamHistory());

  var inserted = 0;
  var skippedDuplicate = 0;
  var invalid = 0;
  var featuresBuilt = 0;
  // Commit-Grenze pro Transaktion (siehe Begründung unten) - deutlich größer
  // als der Insert-Batch, weil jede Transaktion jetzt nur noch wenige
  // Multi-Row-Statements statt hunderter Einzel-Inserts enthält.
  const batchCommitSize = 4000;
  // Zeilen pro einzelnem INSERT-Statement. Ein Statement pro Zeile bedeutet
  // einen Netzwerk-Roundtrip pro Zeile - bei 230.000 Zeilen und Latenz zum
  // Railway-Proxy summiert sich das auf viele Stunden. Multi-Row-VALUES
  // reduzieren die Roundtrips um den Faktor insertBatchSize (24 Spalten *
  // 200 Zeilen = 4800 Parameter, weit unter Postgres' Limit von 65535).
  const insertBatchSize = 200;

  final pendingRows = <Map<String, Object?>>[];

  Future<void> flush(TxSession session) async {
    if (pendingRows.isEmpty) return;
    final valuesSql = <String>[];
    final parameters = <String, Object?>{};
    for (var r = 0; r < pendingRows.length; r++) {
      final p = pendingRows[r];
      valuesSql.add('''
        ('external_dataset', @key_$r, @division_$r, @date_$r, @home_team_$r,
         @away_team_$r, @home_goals_$r, @away_goals_$r, @result_$r,
         @home_elo_$r, @away_elo_$r, @elo_diff_$r, @abs_level_$r,
         @form3_home_$r, @form5_home_$r, @form3_away_$r, @form5_away_$r,
         @norm_home_$r, @norm_draw_$r, @norm_away_$r, @over25_$r, @under25_$r,
         CAST(@features_$r AS JSONB), @coverage_$r, @import_version_$r)
      ''');
      p.forEach((key, value) => parameters['${key}_$r'] = value);
    }

    final sql = '''
      INSERT INTO historical_twin_matches (
        source, source_match_key, division, match_date, home_team, away_team,
        home_goals, away_goals, result, home_elo, away_elo, elo_difference,
        absolute_elo_level, form3_home, form5_home, form3_away, form5_away,
        normalized_home_probability, normalized_draw_probability,
        normalized_away_probability, over25_probability, under25_probability,
        features, data_coverage_percent, import_version
      ) VALUES ${valuesSql.join(',')}
      ON CONFLICT (source, source_match_key) DO NOTHING
    ''';

    try {
      final result = await session.execute(
        Sql.named(sql),
        parameters: parameters,
      );
      inserted += result.affectedRows;
      featuresBuilt += result.affectedRows;
      skippedDuplicate += pendingRows.length - result.affectedRows;
    } catch (error) {
      // Ein fehlerhafter Batch darf den restlichen Import nicht abbrechen -
      // die betroffenen Zeilen gelten als invalid und können durch einen
      // erneuten (idempotenten) Lauf nachträglich importiert werden.
      invalid += pendingRows.length;
      stderr.writeln('[TWINS IMPORT] Batch-Fehler (${pendingRows.length} Zeilen): $error');
    }
    pendingRows.clear();
  }

  // Eine Transaktion PRO COMMIT-BATCH statt einer einzigen Transaktion für
  // alle 230.000 Zeilen: schlägt ein Insert-Batch mit einem echten SQL-Fehler
  // fehl, "vergiftet" Postgres sonst die gesamte Transaktion und jeder
  // nachfolgende Batch würde bis zum Transaktionsende stumm mitscheitern.
  // So bleibt der Schaden auf höchstens einen Commit-Batch begrenzt, und der
  // Import ist idempotent erneut ausführbar, um Lücken zu schließen.
  for (var batchStart = 0;
      batchStart < effectiveRows.length;
      batchStart += batchCommitSize) {
    final batchEnd = (batchStart + batchCommitSize < effectiveRows.length)
        ? batchStart + batchCommitSize
        : effectiveRows.length;

    // Der Railway-Proxy trennt lang laufende Verbindungen irgendwann von
    // sich aus (in der Praxis nach ca. 20 Minuten). Ein einzelner
    // Verbindungsabbruch darf den kompletten Import nicht beenden: bis zu
    // drei Versuche, jeweils mit einer frisch geholten (bei Bedarf neu
    // aufgebauten) Verbindung. Dank ON CONFLICT DO NOTHING ist ein Retry
    // desselben Batches immer sicher.
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        final conn = await database.connection();
        await conn.runTx<void>((session) async {
          for (var i = batchStart; i < batchEnd; i++) {
      final row = effectiveRows[i];
      final division = field(row, 'Division') ?? '';
      final matchDateRaw = field(row, 'MatchDate');
      final homeTeam = field(row, 'HomeTeam');
      final awayTeam = field(row, 'AwayTeam');

      if (matchDateRaw == null || homeTeam == null || awayTeam == null) {
        invalid++;
        continue;
      }
      final matchDate = DateTime.tryParse(matchDateRaw);
      if (matchDate == null) {
        invalid++;
        continue;
      }

      final ftHome = _int(field(row, 'FTHome'));
      final ftAway = _int(field(row, 'FTAway'));
      final result = field(row, 'FTResult');

      final homeElo = _double(field(row, 'HomeElo'));
      final awayElo = _double(field(row, 'AwayElo'));
      final form3Home = _double(field(row, 'Form3Home'));
      final form5Home = _double(field(row, 'Form5Home'));
      final form3Away = _double(field(row, 'Form3Away'));
      final form5Away = _double(field(row, 'Form5Away'));

      final oddHome = _double(field(row, 'OddHome'));
      final oddDraw = _double(field(row, 'OddDraw'));
      final oddAway = _double(field(row, 'OddAway'));
      final over25Odd = _double(field(row, 'Over25'));
      final under25Odd = _double(field(row, 'Under25'));

      // Rolling-Features AUSSCHLIESSLICH aus der bisherigen Historie -
      // das aktuelle Match ist zu diesem Zeitpunkt noch nicht eingetragen.
      final homeHist = historyFor(homeTeam);
      final awayHist = historyFor(awayTeam);
      final homeOverallFeat = _rollingFeatures(homeHist.overall);
      final awayOverallFeat = _rollingFeatures(awayHist.overall);
      final homeHomeFeat = _rollingFeatures(homeHist.home);
      final awayAwayFeat = _rollingFeatures(awayHist.away);

      final eloDiff =
          (homeElo != null && awayElo != null) ? homeElo - awayElo : null;
      final absoluteLevel =
          (homeElo != null && awayElo != null) ? (homeElo + awayElo) / 2 : null;

      double? normHome, normDraw, normAway;
      if (oddHome != null &&
          oddHome > 1 &&
          oddDraw != null &&
          oddDraw > 1 &&
          oddAway != null &&
          oddAway > 1) {
        final rawHome = 1 / oddHome;
        final rawDraw = 1 / oddDraw;
        final rawAway = 1 / oddAway;
        final sum = rawHome + rawDraw + rawAway;
        if (sum > 0) {
          normHome = rawHome / sum * 100;
          normDraw = rawDraw / sum * 100;
          normAway = rawAway / sum * 100;
        }
      }

      double? over25Prob, under25Prob;
      if (over25Odd != null &&
          over25Odd > 1 &&
          under25Odd != null &&
          under25Odd > 1) {
        final rawOver = 1 / over25Odd;
        final rawUnder = 1 / under25Odd;
        final sum = rawOver + rawUnder;
        if (sum > 0) {
          over25Prob = rawOver / sum * 100;
          under25Prob = rawUnder / sum * 100;
        }
      }

      final features = <String, Object?>{
        'homeOverall': homeOverallFeat,
        'awayOverall': awayOverallFeat,
        'homeHomeProfile': homeHomeFeat,
        'awayAwayProfile': awayAwayFeat,
      };

      var available = 0;
      const totalBlocks = 6;
      if (eloDiff != null) available++;
      if (form3Home != null || form5Home != null) available++;
      if (normHome != null) available++;
      if (homeOverallFeat['goalsScoredAvg'] != null &&
          awayOverallFeat['goalsScoredAvg'] != null) {
        available++;
      }
      if (homeHomeFeat['goalsScoredAvg'] != null &&
          awayAwayFeat['goalsScoredAvg'] != null) {
        available++;
      }
      if (absoluteLevel != null) available++;
      final dataCoverage = available / totalBlocks * 100;

      final sourceMatchKey = '$division|$matchDateRaw|$homeTeam|$awayTeam';

      // Historie wird für JEDES Match aufgebaut (s. o.), aber nur ab dem
      // Cutoff tatsächlich geschrieben - so bleiben Rolling-Features für
      // 2020+ trotzdem leakage-frei, ohne die dazwischenliegenden Jahre
      // erneut in die knappe Datenbank zu schreiben.
      if (insertFromDate == null || !matchDate.isBefore(insertFromDate)) {
        pendingRows.add({
          'key': sourceMatchKey,
          'division': division,
          'date': matchDate,
          'home_team': homeTeam,
          'away_team': awayTeam,
          'home_goals': ftHome,
          'away_goals': ftAway,
          'result': result,
          'home_elo': homeElo,
          'away_elo': awayElo,
          'elo_diff': eloDiff,
          'abs_level': absoluteLevel,
          'form3_home': form3Home,
          'form5_home': form5Home,
          'form3_away': form3Away,
          'form5_away': form5Away,
          'norm_home': normHome,
          'norm_draw': normDraw,
          'norm_away': normAway,
          'over25': over25Prob,
          'under25': under25Prob,
          'features': jsonEncode(features),
          'coverage': dataCoverage,
          'import_version': _importVersion,
        });
        if (pendingRows.length >= insertBatchSize) {
          await flush(session);
        }
      }

      // ERST NACH dem Speichern der Pre-Match-Features das eigene Ergebnis
      // in die Team-Historie aufnehmen, damit dasselbe Match nie sein
      // eigenes Feature beeinflusst.
      if (ftHome != null && ftAway != null) {
        final homeShots = _double(field(row, 'HomeShots'));
        final awayShots = _double(field(row, 'AwayShots'));
        final homeTarget = _double(field(row, 'HomeTarget'));
        final awayTarget = _double(field(row, 'AwayTarget'));
        final homeOutcome = _MatchOutcome(
          scored: ftHome,
          conceded: ftAway,
          shotsFor: homeShots,
          shotsTargetFor: homeTarget,
        );
        final awayOutcome = _MatchOutcome(
          scored: ftAway,
          conceded: ftHome,
          shotsFor: awayShots,
          shotsTargetFor: awayTarget,
        );
        homeHist.overall.add(homeOutcome);
        homeHist.home.add(homeOutcome);
        awayHist.overall.add(awayOutcome);
        awayHist.away.add(awayOutcome);
        _trim(homeHist.overall);
        _trim(homeHist.home);
        _trim(awayHist.overall);
        _trim(awayHist.away);
      }

      }
      // Am Ende jeder Transaktion IMMER flushen, auch wenn insertBatchSize
      // nicht exakt erreicht wurde - sonst würden Restzeilen erst mit der
      // (dann bereits ungültigen) Session der nächsten Transaktion
      // verarbeitet und stillschweigend verloren gehen.
      await flush(session);
        });
        break; // Batch erfolgreich committet.
      } catch (error) {
        // Ein Verbindungsabbruch rollt die GESAMTE Transaktion zurück
        // (Postgres-Atomarität) - hier wurde also nichts halb gespeichert,
        // dieser Batch muss vollständig wiederholt werden.
        if (attempt >= 3) {
          stderr.writeln(
            '[TWINS IMPORT] Batch $batchStart-$batchEnd nach $attempt '
            'Versuchen aufgegeben: $error. Ein erneuter Skript-Lauf holt '
            'diesen Bereich idempotent nach.',
          );
          break;
        }
        stderr.writeln(
          '[TWINS IMPORT] Batch $batchStart-$batchEnd fehlgeschlagen '
          '(Versuch $attempt/3): $error - neue Verbindung, erneuter Versuch ...',
        );
        await Future<void>.delayed(Duration(seconds: 2 * attempt));
      }
    }

    final pct = (batchEnd / effectiveRows.length * 100).toStringAsFixed(1);
    stdout.writeln(
      '[TWINS IMPORT] $batchEnd/${effectiveRows.length} ($pct%) '
      'inserted=$inserted duplicates=$skippedDuplicate invalid=$invalid '
      'featuresBuilt=$featuresBuilt',
    );
  }

  stdout.writeln(
    '[TWINS IMPORT] Matches.csv fertig: rowsRead=$rowsRead inserted=$inserted '
    'duplicates=$skippedDuplicate invalid=$invalid featuresBuilt=$featuresBuilt',
  );

  final countConn = await database.connection();
  final countRow = await countConn.execute(
    'SELECT COUNT(*) FROM historical_twin_matches',
  );
  stdout.writeln(
    '[TWINS IMPORT] historical_twin_matches = ${countRow.first[0]}',
  );
}

class _TeamHistory {
  final List<_MatchOutcome> overall = [];
  final List<_MatchOutcome> home = [];
  final List<_MatchOutcome> away = [];
}

class _MatchOutcome {
  const _MatchOutcome({
    required this.scored,
    required this.conceded,
    this.shotsFor,
    this.shotsTargetFor,
  });

  final int scored;
  final int conceded;
  final double? shotsFor;
  final double? shotsTargetFor;
}

void _trim(List<_MatchOutcome> list) {
  while (list.length > _rollingWindow) {
    list.removeAt(0);
  }
}

Map<String, Object?> _rollingFeatures(List<_MatchOutcome> outcomes) {
  if (outcomes.isEmpty) {
    return {
      'sample': 0,
      'goalsScoredAvg': null,
      'goalsConcededAvg': null,
      'totalGoalsAvg': null,
      'pointsPerGame': null,
      'over25Rate': null,
      'bttsRate': null,
      'shotsAvg': null,
      'shotsTargetAvg': null,
    };
  }

  var scoredSum = 0, concededSum = 0, points = 0, over25 = 0, btts = 0;
  var shotsSum = 0.0, shotsCount = 0, targetSum = 0.0, targetCount = 0;

  for (final outcome in outcomes) {
    scoredSum += outcome.scored;
    concededSum += outcome.conceded;
    if (outcome.scored > outcome.conceded) {
      points += 3;
    } else if (outcome.scored == outcome.conceded) {
      points += 1;
    }
    if (outcome.scored + outcome.conceded > 2) over25++;
    if (outcome.scored > 0 && outcome.conceded > 0) btts++;
    if (outcome.shotsFor != null) {
      shotsSum += outcome.shotsFor!;
      shotsCount++;
    }
    if (outcome.shotsTargetFor != null) {
      targetSum += outcome.shotsTargetFor!;
      targetCount++;
    }
  }

  final n = outcomes.length;
  return {
    'sample': n,
    'goalsScoredAvg': scoredSum / n,
    'goalsConcededAvg': concededSum / n,
    'totalGoalsAvg': (scoredSum + concededSum) / n,
    'pointsPerGame': points / n,
    'over25Rate': over25 / n * 100,
    'bttsRate': btts / n * 100,
    'shotsAvg': shotsCount > 0 ? shotsSum / shotsCount : null,
    'shotsTargetAvg': targetCount > 0 ? targetSum / targetCount : null,
  };
}

int? _argInt(List<String> args, String prefix) {
  for (final arg in args) {
    if (arg.startsWith('$prefix=')) {
      return int.tryParse(arg.substring(prefix.length + 1));
    }
  }
  return null;
}

String? _argString(List<String> args, String prefix) {
  for (final arg in args) {
    if (arg.startsWith('$prefix=')) {
      return arg.substring(prefix.length + 1);
    }
  }
  return null;
}

int? _int(String? value) {
  if (value == null) return null;
  final asDouble = double.tryParse(value);
  return asDouble?.round();
}

double? _double(String? value) {
  if (value == null) return null;
  return double.tryParse(value);
}

List<String> _splitCsvLine(String line) {
  final result = <String>[];
  final buffer = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final char = line[i];
    if (char == '"') {
      inQuotes = !inQuotes;
      continue;
    }
    if (char == ',' && !inQuotes) {
      result.add(buffer.toString());
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  result.add(buffer.toString());
  return result;
}
