import 'dart:io';
import 'dart:math';

import 'package:phoenix_backend/src/database/database.dart';
import 'package:phoenix_backend/src/model_lab/elo_prior.dart';
import 'package:phoenix_backend/src/model_lab/team_strength_engine.dart';

/// READ-ONLY (M3b): fittet die Team-Stärke pro Liga auf dem kombinierten
/// Korpus (historische Twins + eigene abgerechnete Spiele) und meldet
/// Abdeckung, Konvergenz und den global gefitteten Elo-Prior-Koeffizienten.
/// Kein Schreiben, keine Challenger - der echte Backtest kommt in M4.
Future<void> main() async {
  final url = (Platform.environment['DATABASE_PUBLIC_URL'] ??
          Platform.environment['DATABASE_URL'] ??
          '')
      .trim();
  final database = PhoenixDatabase(url);
  try {
    await database.migrate();
    final corpus = await database.teamStrengthCorpus();
    stdout.writeln('Korpus-Zeilen gesamt: ${corpus.length}');

    // Nach Liga gruppieren.
    final byLeague = <String, List<Map<String, Object?>>>{};
    for (final row in corpus) {
      final lg = row['league_id']?.toString() ?? '';
      if (lg.isEmpty) continue;
      byLeague.putIfAbsent(lg, () => []).add(row);
    }

    // Globalen Elo-Prior fitten: pro Liga je Team den mittleren Pre-Match-Elo
    // und Tore erzielt/kassiert sammeln, standardisieren, poolen.
    final pooledObs = <({double z, double supremacyLog})>[];
    for (final rows in byLeague.values) {
      final eloSum = <String, double>{};
      final eloCount = <String, int>{};
      final gf = <String, double>{};
      final ga = <String, double>{};
      for (final r in rows) {
        final h = r['home_team_id']!.toString();
        final a = r['away_team_id']!.toString();
        final hg = (r['home_goals'] as num).toDouble();
        final ag = (r['away_goals'] as num).toDouble();
        gf[h] = (gf[h] ?? 0) + hg;
        ga[h] = (ga[h] ?? 0) + ag;
        gf[a] = (gf[a] ?? 0) + ag;
        ga[a] = (ga[a] ?? 0) + hg;
        final he = (r['home_elo'] as num?)?.toDouble();
        final ae = (r['away_elo'] as num?)?.toDouble();
        if (he != null) {
          eloSum[h] = (eloSum[h] ?? 0) + he;
          eloCount[h] = (eloCount[h] ?? 0) + 1;
        }
        if (ae != null) {
          eloSum[a] = (eloSum[a] ?? 0) + ae;
          eloCount[a] = (eloCount[a] ?? 0) + 1;
        }
      }
      final teamElo = <String, double>{
        for (final id in eloSum.keys)
          if ((eloCount[id] ?? 0) > 0) id: eloSum[id]! / eloCount[id]!,
      };
      if (teamElo.length < 4) continue;
      final leagueMean =
          teamElo.values.reduce((a, b) => a + b) / teamElo.length;
      pooledObs.addAll(EloPrior.standardize([
        for (final id in teamElo.keys)
          (
            eloDiff: teamElo[id]! - leagueMean,
            goalsFor: gf[id] ?? 0,
            goalsAgainst: ga[id] ?? 0,
          ),
      ]));
    }
    final eloPrior = EloPrior.fit(pooledObs);
    stdout.writeln('Elo-Prior-Beobachtungen: ${pooledObs.length}');
    stdout.writeln('Gefitteter Elo-Prior k: ${eloPrior.k.toStringAsFixed(4)}');

    var leaguesFitted = 0;
    var converged = 0;
    var withPriorConverged = 0;
    var eloLeagues = 0;
    final rows = <String>[];

    for (final entry in byLeague.entries) {
      final matches = <MatchResult>[];
      for (final r in entry.value) {
        matches.add(MatchResult(
          homeTeamId: r['home_team_id']!.toString(),
          awayTeamId: r['away_team_id']!.toString(),
          homeGoals: (r['home_goals'] as num).toInt(),
          awayGoals: (r['away_goals'] as num).toInt(),
          kickoff: r['kickoff'] is DateTime ? r['kickoff'] as DateTime : null,
        ));
      }
      if (matches.length < 40) continue;
      leaguesFitted++;

      // Per-Team-Priors aus mittlerem Elo.
      final eloSum = <String, double>{};
      final eloCount = <String, int>{};
      for (final r in entry.value) {
        final h = r['home_team_id']!.toString();
        final a = r['away_team_id']!.toString();
        final he = (r['home_elo'] as num?)?.toDouble();
        final ae = (r['away_elo'] as num?)?.toDouble();
        if (he != null) {
          eloSum[h] = (eloSum[h] ?? 0) + he;
          eloCount[h] = (eloCount[h] ?? 0) + 1;
        }
        if (ae != null) {
          eloSum[a] = (eloSum[a] ?? 0) + ae;
          eloCount[a] = (eloCount[a] ?? 0) + 1;
        }
      }
      final teamElo = {
        for (final id in eloSum.keys)
          if ((eloCount[id] ?? 0) > 0) id: eloSum[id]! / eloCount[id]!,
      };
      Map<String, ({double attack, double defense})> priors = {};
      if (teamElo.length >= 4) {
        eloLeagues++;
        final mean = teamElo.values.reduce((a, b) => a + b) / teamElo.length;
        var variance = 0.0;
        for (final v in teamElo.values) {
          variance += (v - mean) * (v - mean);
        }
        final sd = sqrt(variance / teamElo.length);
        priors = {
          for (final id in teamElo.keys)
            id: eloPrior.forTeam(
              elo: teamElo[id],
              leagueMeanElo: mean,
              leagueEloSd: sd,
            ),
        };
      }

      final plain = TeamStrengthEngine.fit(matches);
      final withPrior = TeamStrengthEngine.fit(matches, priors: priors);
      if (plain.converged) converged++;
      if (withPrior.converged) withPriorConverged++;

      if (rows.length < 25) {
        rows.add('${entry.key.padRight(6)} n=${matches.length.toString().padLeft(5)} '
            'teams=${plain.attack.length.toString().padLeft(3)} '
            'elo=${(teamElo.length).toString().padLeft(3)} '
            'conv=${plain.converged ? 'y' : 'n'}/${withPrior.converged ? 'y' : 'n'} '
            'iters=${plain.iterations}/${withPrior.iterations}');
      }
    }

    stdout.writeln('\nLigen mit >=40 Spielen gefittet: $leaguesFitted');
    stdout.writeln('  davon konvergiert (ohne/mit Prior): $converged / $withPriorConverged');
    stdout.writeln('  Ligen mit Elo-Abdeckung (>=4 Teams): $eloLeagues');
    stdout.writeln('\nBeispiel-Ligen (id, Spiele, Teams, Elo-Teams, conv ohne/mit, iters):');
    for (final r in rows) {
      stdout.writeln('  $r');
    }
    stdout.writeln('\n== FERTIG (read-only) ==');
  } finally {
    await database.close();
  }
}
