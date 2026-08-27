import 'dart:io';
import 'dart:math' as math;

import 'package:phoenix_backend/src/database/database.dart';
import 'package:phoenix_backend/src/model_lab/division_map.dart';
import 'package:phoenix_backend/src/model_lab/team_name_resolver.dart';
import 'package:postgres/postgres.dart';

/// Ordnet die importierten Historical-Twin-Spiele (externe Roh-Teamnamen,
/// football-data.co.uk-Divisionscodes) unseren eigenen PHÖNIX-Liga-IDs und
/// Provider-Team-IDs zu und befüllt dabei zusätzlich die persistente
/// `football_team_aliases`-Dimension (Quelle `twins`).
///
/// Sicherheitsprinzip (kein Fabrizieren falscher Zuordnungen):
/// 1. Divisionscode -> Liga-ID: nutzt zuerst `football_division_map` (falls
///    per `bin/phoenix_division_map_report.dart --write` befüllt), sonst die
///    verifizierten `kDivisionHints` - jeweils nur, wenn die vermutete
///    API-Football-ID in `football_leagues` existiert UND Land/Name plausibel
///    passen; sonst Fallback auf Land+Stufe+Name-Suche; sonst "nicht
///    aufgelöst" (kein Raten).
/// 2. Team-Name-Zuordnung nur bei eindeutig hohem Ähnlichkeits-Score
///    (>= [TeamNameResolver.matchThreshold]) UND deutlichem Abstand zum
///    zweitbesten Kandidaten (sonst als mehrdeutig verworfen statt geraten).
/// 3. Standardmäßig DRY RUN (nur Report, kein Schreiben). Erst mit `--write`
///    werden `historical_twin_matches.matched_*` und `football_team_aliases`
///    tatsächlich befüllt.
///
/// Aufruf:
///   dart run bin/phoenix_twins_match_teams.dart            (Report only)
///   dart run bin/phoenix_twins_match_teams.dart --write     (schreibt Ergebnisse)
Future<void> main(List<String> args) async {
  final write = args.contains('--write');
  final databaseUrl = (Platform.environment['DATABASE_PUBLIC_URL'] ??
          Platform.environment['DATABASE_URL'] ??
          '')
      .trim();
  final database = PhoenixDatabase(databaseUrl);
  try {
    await database.migrate();
    final db = await database.connection();

    var totalMatchesConsidered = 0;
    var totalTeamMatchesWritten = 0;
    var totalAliasesWritten = 0;
    var divisionsResolved = 0;

    for (final hint in kDivisionHints) {
      final resolved = await _resolveLeague(db, hint);
      if (resolved == null) {
        stdout.writeln(
            '${hint.division}: NICHT AUFGELÖST (keine passende Liga in football_leagues gefunden)');
        continue;
      }
      divisionsResolved++;
      final (resolvedLeagueId, resolvedLeagueName) = resolved;

      // Unsere bekannten Teamnamen für diese Liga (normalisiert -> team_id).
      final ourTeamsRows = await db.execute(
        Sql.named('''
          SELECT DISTINCT id, name FROM (
            SELECT home_team_id AS id, home_team_name AS name
              FROM football_matches WHERE league_id = @lid
            UNION
            SELECT away_team_id, away_team_name
              FROM football_matches WHERE league_id = @lid
          ) x
          WHERE name IS NOT NULL
        '''),
        parameters: {'lid': resolvedLeagueId},
      );
      final ourTeams = <String, String>{}; // normalized -> team_id (keeps first)
      final ourTeamsRaw = <String, String>{}; // normalized -> raw name
      for (final row in ourTeamsRows) {
        final id = row[0] as String;
        final name = row[1] as String;
        final norm = TeamNameResolver.normalize(name);
        if (norm.isEmpty) continue;
        ourTeams.putIfAbsent(norm, () => id);
        ourTeamsRaw.putIfAbsent(norm, () => name);
      }

      if (ourTeams.isEmpty) {
        stdout.writeln(
            '${hint.division} -> $resolvedLeagueId ($resolvedLeagueName): aufgelöst, aber 0 eigene Teamnamen gespeichert - kein Team-Matching möglich.');
        continue;
      }

      // Twin-Teamnamen dieser Division.
      final twinTeamsRows = await db.execute(
        Sql.named('''
          SELECT DISTINCT t FROM (
            SELECT home_team AS t FROM historical_twin_matches WHERE division = @div
            UNION
            SELECT away_team FROM historical_twin_matches WHERE division = @div
          ) x
        '''),
        parameters: {'div': hint.division},
      );

      final nameMap = <String, String>{}; // raw twin name -> matched team_id
      final aliasWrites = <(String aliasNorm, String teamId, double conf)>[];
      var matchedCount = 0;
      var ambiguousCount = 0;
      var noMatchCount = 0;
      final sampleMatches = <String>[];

      for (final row in twinTeamsRows) {
        final rawTwinName = row[0] as String;
        final r = TeamMatchResult();
        final teamId = TeamNameResolver.bestMatch(rawTwinName, ourTeams,
            result: r);
        switch (r.status) {
          case TeamMatchStatus.matched:
            nameMap[rawTwinName] = teamId!;
            matchedCount++;
            aliasWrites.add(
                (TeamNameResolver.normalize(rawTwinName), teamId, r.bestScore));
            if (sampleMatches.length < 5) {
              sampleMatches.add(
                  '"$rawTwinName" -> "${ourTeamsRaw[r.bestCandidateKey]}" (${(r.bestScore * 100).toStringAsFixed(0)}%)');
            }
          case TeamMatchStatus.ambiguous:
            ambiguousCount++;
          case TeamMatchStatus.noMatch:
            noMatchCount++;
        }
      }

      stdout.writeln(
          '${hint.division} -> $resolvedLeagueId ($resolvedLeagueName) | unsere Teams: ${ourTeams.length} | Twin-Teams: ${twinTeamsRows.length} | gematcht: $matchedCount | mehrdeutig: $ambiguousCount | kein Treffer: $noMatchCount');
      for (final s in sampleMatches) {
        stdout.writeln('   $s');
      }

      if (nameMap.isEmpty) continue;

      // Alias-Zeilen (persistente football_team_aliases-Dimension, Quelle
      // `twins`) - unabhängig davon, ob eine konkrete Spielzeile am Ende
      // beide Teams zuordnen kann.
      if (write && aliasWrites.isNotEmpty) {
        totalAliasesWritten += await database.upsertTeamAliases(
          [
            for (final a in aliasWrites)
              (aliasNorm: a.$1, teamId: a.$2, confidence: a.$3),
          ],
          source: 'twins',
        );
      }

      // Spiele dieser Division, bei denen BEIDE Teams gematcht wurden.
      final matchRows = await db.execute(
        Sql.named(
            'SELECT id, home_team, away_team FROM historical_twin_matches WHERE division = @div'),
        parameters: {'div': hint.division},
      );
      final writableIds = <int>[];
      final writableHomeIds = <String>[];
      final writableAwayIds = <String>[];
      for (final row in matchRows) {
        final homeId = nameMap[row[1] as String];
        final awayId = nameMap[row[2] as String];
        if (homeId == null || awayId == null) continue;
        writableIds.add(row[0] as int);
        writableHomeIds.add(homeId);
        writableAwayIds.add(awayId);
      }
      totalMatchesConsidered += writableIds.length;

      // Ein Bulk-UPDATE pro Division (Multi-Row VALUES), in Batches von 500.
      if (write && writableIds.isNotEmpty) {
        const batchSize = 500;
        for (var start = 0; start < writableIds.length; start += batchSize) {
          final end = math.min(start + batchSize, writableIds.length);
          final valueClauses = <String>[];
          final params = <String, Object?>{
            'lid': resolvedLeagueId,
            'conf': TeamNameResolver.matchThreshold,
          };
          for (var i = start; i < end; i++) {
            final j = i - start;
            valueClauses.add('(@id$j::bigint, @hid$j::text, @aid$j::text)');
            params['id$j'] = writableIds[i];
            params['hid$j'] = writableHomeIds[i];
            params['aid$j'] = writableAwayIds[i];
          }
          await db.execute(
            Sql.named('''
              UPDATE historical_twin_matches AS t
              SET matched_league_id = @lid, matched_home_team_id = v.hid,
                  matched_away_team_id = v.aid, match_confidence = @conf,
                  matched_at = NOW()
              FROM (VALUES ${valueClauses.join(', ')}) AS v(id, hid, aid)
              WHERE t.id = v.id
            '''),
            parameters: params,
          );
        }
        totalTeamMatchesWritten += writableIds.length;
      }
      stdout.writeln(
          '   -> ${writableIds.length} von ${matchRows.length} Spielen in dieser Division mit beiden Teams gematcht.');
    }

    stdout.writeln('\n== Zusammenfassung ==');
    stdout.writeln(
        'Divisionen aufgelöst: $divisionsResolved von ${kDivisionHints.length}');
    stdout.writeln(
        'Spiele mit beiden Teams gematcht (gesamt): $totalMatchesConsidered');
    if (write) {
      stdout.writeln('Tatsächlich geschriebene Spiel-Zeilen: $totalTeamMatchesWritten');
      stdout.writeln('Geschriebene Team-Aliase (Quelle twins): $totalAliasesWritten');
    } else {
      stdout.writeln('DRY RUN - nichts geschrieben. Mit --write erneut ausführen.');
    }
  } finally {
    await database.close();
  }
}

/// Löst einen Divisionscode zu `(league_id, league_name)` auf, oder `null`.
/// Nutzt zuerst `football_division_map` (falls befüllt), dann die
/// verifizierten `kDivisionHints`, dann den Land+Stufe+Name-Fallback.
Future<(String, String)?> _resolveLeague(
    Connection db, DivisionHint hint) async {
  // 1a. Persistente Map (falls vorhanden und befüllt).
  final mapped = await db.execute(
    Sql.named('''
      SELECT m.league_id, l.league_name
      FROM football_division_map m
      JOIN football_leagues l ON l.league_id = m.league_id
      WHERE m.division = @div AND m.league_id IS NOT NULL
    '''),
    parameters: {'div': hint.division},
  );
  if (mapped.isNotEmpty) {
    return (mapped.first[0] as String, (mapped.first[1] as String?) ?? '');
  }

  // 1b. Geratene ID gegen football_leagues verifizieren.
  if (hint.guessedLeagueId != null) {
    final rows = await db.execute(
      Sql.named(
          'SELECT league_id, league_name, country FROM football_leagues WHERE league_id = @id'),
      parameters: {'id': hint.guessedLeagueId.toString()},
    );
    if (rows.isNotEmpty) {
      final country = (rows.first[2] as String?) ?? '';
      final name = (rows.first[1] as String?) ?? '';
      final countryOk = country
              .toLowerCase()
              .contains(hint.country.toLowerCase()) ||
          hint.country.toLowerCase().contains(country.toLowerCase());
      if (countryOk &&
          TeamNameResolver.leagueNamePlausible(name, hint.nameKeyword)) {
        return (rows.first[0] as String, name);
      }
    }
  }

  // 1c. Fallback: Land + Stufe + Namens-Stichwort.
  final rows = await db.execute(
    Sql.named('''
      SELECT league_id, league_name FROM football_leagues
      WHERE country ILIKE @country
        AND (@tier::int IS NULL OR competition_level = @tier)
        AND league_name ILIKE @nameLike
      LIMIT 1
    '''),
    parameters: {
      'country': '%${hint.country}%',
      'tier': hint.tier,
      'nameLike': '%${hint.nameKeyword}%',
    },
  );
  if (rows.isNotEmpty) {
    return (rows.first[0] as String, (rows.first[1] as String?) ?? '');
  }
  return null;
}
