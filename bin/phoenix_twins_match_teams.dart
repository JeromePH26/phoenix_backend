import 'dart:io';
import 'dart:math' as math;

import 'package:phoenix_backend/src/database/database.dart';
import 'package:postgres/postgres.dart';

/// Ordnet die importierten Historical-Twin-Spiele (externe Roh-Teamnamen,
/// football-data.co.uk-Divisionscodes) unseren eigenen PHÖNIX-Liga-IDs und
/// Team-Namen zu (die "Team-ID" in PHÖNIX ist die vom Provider stammende
/// home_team_id/away_team_id aus football_matches - es gibt keine separate
/// Teams-Tabelle).
///
/// Sicherheitsprinzip (kein Fabrizieren falscher Zuordnungen):
/// 1. Divisionscode -> Liga-ID wird NUR akzeptiert, wenn die vermutete
///    API-Football-ID in unserer football_leagues-Tabelle existiert UND
///    Land/Name plausibel passen - sonst Fallback auf Land+Stufe+Name-Suche,
///    sonst "nicht aufgelöst" (kein Raten).
/// 2. Team-Name-Zuordnung nur bei eindeutig hohem Ähnlichkeits-Score
///    (>= [_matchThreshold]) UND deutlichem Abstand zum zweitbesten
///    Kandidaten (sonst als mehrdeutig verworfen statt geraten).
/// 3. Standardmäßig DRY RUN (nur Report, kein Schreiben). Erst mit
///    `--write` werden die Spalten tatsächlich befüllt.
///
/// Aufruf:
///   dart run bin/phoenix_twins_match_teams.dart            (Report only)
///   dart run bin/phoenix_twins_match_teams.dart --write     (schreibt Ergebnisse)
const _matchThreshold = 0.82;
const _minMarginOverSecondBest = 0.05;

class _DivisionHint {
  const _DivisionHint(this.division, this.country, this.tier, this.nameContains, this.guessedLeagueId);
  final String division;
  final String country;
  final int? tier;
  final String nameContains;
  final int? guessedLeagueId;
}

// Bekannte football-data.co.uk-Divisionscodes -> Land/Stufe/Namens-Hinweis.
// guessedLeagueId ist die häufig dokumentierte API-Football-Liga-ID - wird
// unten GEGEN unsere eigene football_leagues-Tabelle verifiziert, nie blind
// übernommen.
const _divisionHints = <_DivisionHint>[
  _DivisionHint('E0', 'England', 1, 'Premier League', 39),
  _DivisionHint('E1', 'England', 2, 'Championship', 40),
  _DivisionHint('E2', 'England', 3, 'League One', 41),
  _DivisionHint('E3', 'England', 4, 'League Two', 42),
  _DivisionHint('EC', 'England', 5, 'National League', 43),
  _DivisionHint('SC0', 'Scotland', 1, 'Premiership', 179),
  _DivisionHint('SC1', 'Scotland', 2, 'Championship', 180),
  _DivisionHint('SC2', 'Scotland', 3, 'League One', 181),
  _DivisionHint('SC3', 'Scotland', 4, 'League Two', 182),
  _DivisionHint('D1', 'Germany', 1, 'Bundesliga', 78),
  _DivisionHint('D2', 'Germany', 2, '2. Bundesliga', 79),
  _DivisionHint('SP1', 'Spain', 1, 'La Liga', 140),
  _DivisionHint('SP2', 'Spain', 2, 'Segunda', 141),
  _DivisionHint('I1', 'Italy', 1, 'Serie A', 135),
  _DivisionHint('I2', 'Italy', 2, 'Serie B', 136),
  _DivisionHint('F1', 'France', 1, 'Ligue 1', 61),
  _DivisionHint('F2', 'France', 2, 'Ligue 2', 62),
  _DivisionHint('N1', 'Netherlands', 1, 'Eredivisie', 88),
  _DivisionHint('B1', 'Belgium', 1, 'Pro League', 144),
  _DivisionHint('P1', 'Portugal', 1, 'Primeira Liga', 94),
  _DivisionHint('T1', 'Turkey', 1, 'Süper Lig', 203),
  _DivisionHint('G1', 'Greece', 1, 'Super League', 197),
  _DivisionHint('ROM', 'Romania', 1, 'Liga', 283),
  _DivisionHint('POL', 'Poland', 1, 'Ekstraklasa', 106),
  _DivisionHint('RUS', 'Russia', 1, 'Premier League', 235),
  _DivisionHint('SWE', 'Sweden', 1, 'Allsvenskan', 113),
  _DivisionHint('SUI', 'Switzerland', 1, 'Super League', 207),
  _DivisionHint('NOR', 'Norway', 1, 'Eliteserien', 103),
  _DivisionHint('DEN', 'Denmark', 1, 'Superliga', 119),
  _DivisionHint('FIN', 'Finland', 1, 'Veikkausliiga', 244),
  _DivisionHint('IRL', 'Ireland', 1, 'Premier Division', 357),
  _DivisionHint('AUT', 'Austria', 1, 'Bundesliga', 218),
  _DivisionHint('ARG', 'Argentina', null, 'Liga Profesional', 128),
  _DivisionHint('BRA', 'Brazil', 1, 'Serie A', 71),
  _DivisionHint('MEX', 'Mexico', 1, 'Liga MX', 262),
  _DivisionHint('USA', 'USA', 1, 'Major League Soccer', 253),
  _DivisionHint('JAP', 'Japan', 1, 'J1 League', 98),
  _DivisionHint('CHN', 'China', null, 'Super League', 169),
];

String _normalizeTeamName(String raw) {
  var s = raw.toLowerCase();
  const accentMap = {
    'ä': 'a', 'ö': 'o', 'ü': 'u', 'ß': 'ss', 'é': 'e', 'è': 'e', 'ê': 'e',
    'á': 'a', 'à': 'a', 'í': 'i', 'ó': 'o', 'ú': 'u', 'ñ': 'n', 'ç': 'c',
    'ã': 'a', 'õ': 'o', 'ý': 'y', 'č': 'c', 'š': 's', 'ž': 'z',
  };
  accentMap.forEach((k, v) => s = s.replaceAll(k, v));
  const aliasReplacements = {
    ' utd': ' united',
    'man united': 'manchester united',
    'man city': 'manchester city',
    'spurs': 'tottenham',
    'wolves': 'wolverhampton',
    "nott'm forest": 'nottingham forest',
  };
  aliasReplacements.forEach((k, v) {
    if (s.contains(k)) s = s.replaceAll(k, v);
  });
  const stripTokens = [
    'fc', 'cf', 'sc', 'afc', 'ac', 'cd', 'ud', 'sd', 'ca', 'cp', 'ec', 'rc',
    'club', 'calcio', 'futbol', 'football', 'ssd', 'asd', 'us', 'as',
    '1.', 'tsg', 'sv', 'vfb', 'vfl', 'bsc', 'fsv', 'sg',
  ];
  final tokens = s.split(RegExp(r'[^a-z0-9]+')).where((t) => t.isNotEmpty).where((t) => !stripTokens.contains(t)).toList();
  return tokens.join(' ');
}

double _tokenSimilarity(String a, String b) {
  if (a == b) return 1.0;
  final ta = a.split(' ').toSet();
  final tb = b.split(' ').toSet();
  if (ta.isEmpty || tb.isEmpty) return 0.0;
  final intersection = ta.intersection(tb).length;
  final union = ta.union(tb).length;
  final jaccard = union == 0 ? 0.0 : intersection / union;
  final lev = _levenshteinSimilarity(a, b);
  return math.max(jaccard, lev);
}

double _levenshteinSimilarity(String a, String b) {
  final dist = _levenshtein(a, b);
  final maxLen = math.max(a.length, b.length);
  if (maxLen == 0) return 1.0;
  return 1.0 - (dist / maxLen);
}

// Section: AUT-Bug (guessedLeagueId traf zwar das richtige Land, aber die
// falsche Liga-Stufe/Wettbewerb, z.B. "2. Liga" statt "Bundesliga") - eine
// geratene ID wird deshalb erst akzeptiert, wenn ihr echter league_name auch
// inhaltlich zum erwarteten Namens-Stichwort passt, nicht nur das Land.
bool _namePlausible(String actualName, String hintName) {
  final actual = actualName.toLowerCase();
  final hint = hintName.toLowerCase();
  if (actual.contains(hint) || hint.contains(actual)) return true;
  final hintWords = hint.split(RegExp(r'\s+')).where((w) => w.length >= 4);
  return hintWords.any(actual.contains);
}

int _levenshtein(String a, String b) {
  final la = a.length, lb = b.length;
  if (la == 0) return lb;
  if (lb == 0) return la;
  var prev = List<int>.generate(lb + 1, (j) => j);
  for (var i = 1; i <= la; i++) {
    final curr = List<int>.filled(lb + 1, 0);
    curr[0] = i;
    for (var j = 1; j <= lb; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      curr[j] = [curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost].reduce(math.min);
    }
    prev = curr;
  }
  return prev[lb];
}

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

    if (write) {
      await db.execute('''
        ALTER TABLE historical_twin_matches
        ADD COLUMN IF NOT EXISTS matched_league_id TEXT,
        ADD COLUMN IF NOT EXISTS matched_home_team_id TEXT,
        ADD COLUMN IF NOT EXISTS matched_away_team_id TEXT,
        ADD COLUMN IF NOT EXISTS match_confidence DOUBLE PRECISION,
        ADD COLUMN IF NOT EXISTS matched_at TIMESTAMPTZ
      ''');
      stdout.writeln('Spalten sichergestellt (matched_league_id, matched_home_team_id, matched_away_team_id, match_confidence, matched_at).\n');
    }

    var totalMatchesConsidered = 0;
    var totalTeamMatchesWritten = 0;
    var divisionsResolved = 0;

    for (final hint in _divisionHints) {
      // Schritt 1: Liga-ID auflösen - erst die vermutete ID verifizieren.
      String? resolvedLeagueId;
      String? resolvedLeagueName;
      if (hint.guessedLeagueId != null) {
        final rows = await db.execute(
          Sql.named('SELECT league_id, league_name, country FROM football_leagues WHERE league_id = @id'),
          parameters: {'id': hint.guessedLeagueId.toString()},
        );
        if (rows.isNotEmpty) {
          final country = (rows.first[2] as String?) ?? '';
          final name = (rows.first[1] as String?) ?? '';
          final countryOk = country.toLowerCase().contains(hint.country.toLowerCase()) ||
              hint.country.toLowerCase().contains(country.toLowerCase());
          if (countryOk && _namePlausible(name, hint.nameContains)) {
            resolvedLeagueId = rows.first[0] as String;
            resolvedLeagueName = rows.first[1] as String;
          }
        }
      }
      if (resolvedLeagueId == null) {
        // Fallback: Land + Stufe + Namens-Stichwort.
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
            'nameLike': '%${hint.nameContains}%',
          },
        );
        if (rows.isNotEmpty) {
          resolvedLeagueId = rows.first[0] as String;
          resolvedLeagueName = rows.first[1] as String;
        }
      }

      if (resolvedLeagueId == null) {
        stdout.writeln('${hint.division}: NICHT AUFGELÖST (keine passende Liga in football_leagues gefunden)');
        continue;
      }
      divisionsResolved++;

      // Schritt 2: unsere bekannten Teamnamen für diese Liga.
      final ourTeamsRows = await db.execute(
        Sql.named('''
          SELECT DISTINCT id, name FROM (
            SELECT home_team_id AS id, home_team_name AS name FROM football_matches WHERE league_id = @lid
            UNION
            SELECT away_team_id, away_team_name FROM football_matches WHERE league_id = @lid
          ) x
          WHERE name IS NOT NULL
        '''),
        parameters: {'lid': resolvedLeagueId},
      );
      final ourTeams = <String, String>{}; // normalized -> team_id (keeps first)
      final ourTeamsRaw = <String, String>{}; // normalized -> raw name (for reporting)
      for (final row in ourTeamsRows) {
        final id = row[0] as String;
        final name = row[1] as String;
        final norm = _normalizeTeamName(name);
        if (norm.isEmpty) continue;
        ourTeams.putIfAbsent(norm, () => id);
        ourTeamsRaw.putIfAbsent(norm, () => name);
      }

      if (ourTeams.isEmpty) {
        stdout.writeln('${hint.division} -> $resolvedLeagueId ($resolvedLeagueName): aufgelöst, aber 0 eigene Teamnamen gespeichert - kein Team-Matching möglich.');
        continue;
      }

      // Schritt 3: Twin-Teamnamen dieser Division holen.
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
      var matchedCount = 0;
      var ambiguousCount = 0;
      var noMatchCount = 0;
      final sampleMatches = <String>[];

      for (final row in twinTeamsRows) {
        final rawTwinName = row[0] as String;
        final normTwin = _normalizeTeamName(rawTwinName);
        if (normTwin.isEmpty) continue;

        String? bestKey;
        double bestScore = -1;
        double secondBestScore = -1;
        for (final ourNorm in ourTeams.keys) {
          final score = _tokenSimilarity(normTwin, ourNorm);
          if (score > bestScore) {
            secondBestScore = bestScore;
            bestScore = score;
            bestKey = ourNorm;
          } else if (score > secondBestScore) {
            secondBestScore = score;
          }
        }

        if (bestKey != null && bestScore >= _matchThreshold && (bestScore - secondBestScore) >= _minMarginOverSecondBest) {
          nameMap[rawTwinName] = ourTeams[bestKey]!;
          matchedCount++;
          if (sampleMatches.length < 5) {
            sampleMatches.add('"$rawTwinName" -> "${ourTeamsRaw[bestKey]}" (${(bestScore * 100).toStringAsFixed(0)}%)');
          }
        } else if (bestKey != null && bestScore >= _matchThreshold) {
          ambiguousCount++;
        } else {
          noMatchCount++;
        }
      }

      stdout.writeln(
          '${hint.division} -> $resolvedLeagueId ($resolvedLeagueName) | unsere Teams: ${ourTeams.length} | Twin-Teams: ${twinTeamsRows.length} | gematcht: $matchedCount | mehrdeutig: $ambiguousCount | kein Treffer: $noMatchCount');
      for (final s in sampleMatches) {
        stdout.writeln('   $s');
      }

      if (nameMap.isEmpty) continue;

      // Schritt 4: Spiele dieser Division schreiben/zählen, bei denen BEIDE
      // Teams gematcht werden konnten (nur dann ist die Zeile nutzbar).
      final matchRows = await db.execute(
        Sql.named('SELECT id, home_team, away_team FROM historical_twin_matches WHERE division = @div'),
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

      // Ein einziger Bulk-UPDATE pro Division (Multi-Row VALUES) statt eines
      // Netzwerk-Roundtrips pro Zeile - bei 15k+ Zeilen sonst unpraktikabel
      // langsam gegen die entfernte Railway-DB. In Batches von 500, damit die
      // Query-Größe/Parameteranzahl je Statement begrenzt bleibt.
      if (write && writableIds.isNotEmpty) {
        const batchSize = 500;
        for (var start = 0; start < writableIds.length; start += batchSize) {
          final end = math.min(start + batchSize, writableIds.length);
          final valueClauses = <String>[];
          final params = <String, Object?>{'lid': resolvedLeagueId, 'conf': _matchThreshold};
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
              SET matched_league_id = @lid, matched_home_team_id = v.hid, matched_away_team_id = v.aid,
                  match_confidence = @conf, matched_at = NOW()
              FROM (VALUES ${valueClauses.join(', ')}) AS v(id, hid, aid)
              WHERE t.id = v.id
            '''),
            parameters: params,
          );
        }
        totalTeamMatchesWritten += writableIds.length;
      }
      stdout.writeln('   -> ${writableIds.length} von ${matchRows.length} Spielen in dieser Division mit beiden Teams gematcht.');
    }

    stdout.writeln('\n== Zusammenfassung ==');
    stdout.writeln('Divisionen aufgelöst: $divisionsResolved von ${_divisionHints.length}');
    stdout.writeln('Spiele mit beiden Teams gematcht (gesamt): $totalMatchesConsidered');
    if (write) {
      stdout.writeln('Tatsächlich geschrieben: $totalTeamMatchesWritten');
    } else {
      stdout.writeln('DRY RUN - nichts geschrieben. Mit --write erneut ausführen, um zu speichern.');
    }
  } finally {
    await database.close();
  }
}
