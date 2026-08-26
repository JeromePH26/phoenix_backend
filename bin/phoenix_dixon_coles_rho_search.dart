import 'dart:convert';
import 'dart:io';

import 'package:phoenix_backend/src/config/model_lab_config.dart';
import 'package:phoenix_backend/src/database/database.dart';
import 'package:phoenix_backend/src/model_lab/engine_replica.dart';
import 'package:phoenix_backend/src/model_lab/learning_dataset_builder.dart';
import 'package:phoenix_backend/src/model_lab/learning_market.dart';
import 'package:phoenix_backend/src/model_lab/metrics.dart';
import 'package:phoenix_backend/src/model_lab/walk_forward_evaluator.dart';
import 'package:phoenix_backend/src/model_lab/weight_config.dart';

/// PHÖNIX Engine-Umbau, Phase 1 Spur A - Grid-Search (Plan
/// "wild-cuddling-hoare"): findet den empirisch besten Dixon-Coles-
/// Korrelationsfaktor `rho` auf echten historischen, bereits abgerechneten
/// PHÖNIX-Spielen, statt sich nur auf Literaturwerte (-0.05/-0.10) zu
/// verlassen. Nur lesende DB-Zugriffe, identisch zum Sicherheits-Muster in
/// `phoenix_engine_input_baseline_backtest.dart`/`phoenix_model_lab_dry_run.
/// dart`.
///
/// Testet ein Gitter von rho-Werten gegen die drei PHÖNIX-Hauptmärkte
/// (1X2, BTTS, Über/Unter 2,5 - Section 7: nur diese drei dürfen
/// PHÖNIX-Haupttipp werden) auf Basis derselben Torerwartung, die der
/// globale Champion heute nutzt (`EngineWeightConfig.global`,
/// attackWeight 0.5) - `rho` ist die einzige Testvariable, identisch zum
/// Prinzip in `DixonColesEngine`.
Future<void> main() async {
  final databaseUrl = (Platform.environment['DATABASE_PUBLIC_URL'] ??
          Platform.environment['DATABASE_URL'] ??
          '')
      .trim();
  if (databaseUrl.isEmpty) {
    stderr.writeln('DATABASE_URL/DATABASE_PUBLIC_URL fehlt.');
    exitCode = 1;
    return;
  }

  final database = PhoenixDatabase(databaseUrl);
  final config = ModelLabConfig.fromEnvironment();

  // Gitter statt freier Optimierung (Section 14: "keine absurden
  // Kandidaten") - deckt den in der Dixon-Coles-Literatur (1997, spätere
  // Fußball-Studien) plausiblen Bereich ab, plus 0.0 als Kontrollwert
  // (= heutiges, unverändertes Verhalten) und ein paar positive Werte zur
  // Absicherung, dass negativ wirklich die richtige Richtung ist.
  const rhoGrid = [
    -0.25, -0.20, -0.15, -0.10, -0.05, 0.0, 0.05, 0.10,
  ];

  try {
    stdout.writeln(
        '== Migration (additiv, identisch zum produktiven Boot-Pfad) ==');
    await database.migrate();
    stdout.writeln('OK\n');

    final datasetBuilder =
        LearningDatasetBuilder(database: database, config: config);
    final leagues = await database.modelLabWhitelistedLeagues();

    final audit = await datasetBuilder.auditEligibility();
    final eligibleLeagueIds = audit.perLeague
        .where((c) => c.settled > 0)
        .map((c) => c.leagueId)
        .toSet();
    final leaguesToCheck = leagues
        .where((l) => eligibleLeagueIds.contains(l['league_id']?.toString()))
        .toList();
    stdout.writeln(
        '${leaguesToCheck.length} von ${leagues.length} Whitelist-Ligen haben '
        'abgerechnete Spiele - nur diese werden geladen.\n');

    const markets = [
      LearningMarket.oneXTwo,
      LearningMarket.btts,
      LearningMarket.overUnder25,
    ];

    // Pro rho-Wert: Aggregat über alle drei Hauptmärkte zusammen (Brier ist
    // pro Markt vergleichbar skaliert - Summe/Durchschnitt über die drei
    // Märkte ergibt ein robustes Gesamtbild statt nur eines Einzelmarkts).
    final perRhoOverall = {for (final rho in rhoGrid) rho: _AggregateScore()};
    final perRhoPerMarket = {
      for (final rho in rhoGrid)
        rho: {for (final market in markets) market: _AggregateScore()},
    };

    var totalSamples = 0;
    var leaguesUsed = 0;

    for (final league in leaguesToCheck) {
      final leagueId = league['league_id']?.toString();
      if (leagueId == null) continue;
      stdout.writeln('-> ${league['league_name']} ($leagueId)');

      final samples = await datasetBuilder.buildSamples(leagueId: leagueId);
      if (samples.isEmpty) continue;

      final split = ChronologicalSplit.split(samples, config);
      if (split.holdout.isEmpty) continue;

      var usedThisLeague = false;

      for (final sample in split.holdout) {
        final goals = EngineReplica.expectedGoals(
          features: sample.features,
          weights: EngineWeightConfig.global,
        );
        // Fehlende Torquoten liefern ohnehin nur die neutrale Baseline für
        // beide Seiten - rho hat dann keinen Effekt (identische Lambdas
        // egal welcher Korrelationsfaktor), verwässert also nur das
        // Ergebnis ohne Information zu liefern.
        if (goals.usedFallback) continue;

        usedThisLeague = true;
        totalSamples += 1;

        for (final rho in rhoGrid) {
          for (final market in markets) {
            final outcomeIndex = sample.outcomeIndexFor(market);
            final output = EngineReplica.evaluateGoals(
              market: market,
              goals: goals,
              rho: rho,
            );
            final score = market == LearningMarket.oneXTwo
                ? Metrics.brierMultiClass(
                    probabilities: output.classProbabilities,
                    outcomeIndex: outcomeIndex,
                  )
                : Metrics.brierBinary(
                    probability: output.classProbabilities[0],
                    outcomePositive: outcomeIndex == 0,
                  );
            perRhoOverall[rho]!.add(score);
            perRhoPerMarket[rho]![market]!.add(score);
          }
        }
      }

      if (usedThisLeague) leaguesUsed += 1;
    }

    stdout.writeln('\n== ERGEBNIS ==');
    stdout.writeln('Ligen mit verwertbaren Holdout-Spielen: $leaguesUsed');
    stdout.writeln('Verwertbare Holdout-Spiele: $totalSamples\n');

    if (totalSamples == 0) {
      stdout.writeln('KEINE verwertbaren Fälle gefunden - Grid-Search liefert '
          'keine Entscheidungsgrundlage.');
      return;
    }

    final ranked = rhoGrid.toList()
      ..sort((a, b) =>
          perRhoOverall[a]!.average.compareTo(perRhoOverall[b]!.average));

    stdout.writeln('rho     | Ø Brier gesamt (1X2+BTTS+Ü/U 2,5) | 1X2      | '
        'BTTS     | Ü/U 2,5');
    for (final rho in ranked) {
      final overall = perRhoOverall[rho]!.average;
      final byMarket = perRhoPerMarket[rho]!;
      stdout.writeln(
        '${rho.toStringAsFixed(2).padLeft(6)}  | '
        '${overall.toStringAsFixed(6).padLeft(6)}'
        '                          | '
        '${byMarket[LearningMarket.oneXTwo]!.average.toStringAsFixed(5)} | '
        '${byMarket[LearningMarket.btts]!.average.toStringAsFixed(5)} | '
        '${byMarket[LearningMarket.overUnder25]!.average.toStringAsFixed(5)}',
      );
    }

    final best = ranked.first;
    final control = perRhoOverall[0.0]!.average;
    final bestScore = perRhoOverall[best]!.average;
    stdout.writeln('\n=> Empirisch bester rho-Wert: ${best.toStringAsFixed(2)} '
        '(Ø Brier ${bestScore.toStringAsFixed(6)} vs. ${control.toStringAsFixed(6)} '
        'bei rho=0.0/unverändert, Differenz '
        '${(bestScore - control).toStringAsFixed(6)}).');
    stdout.writeln(
      best == 0.0
          ? 'Kontrollwert (kein Korrelationsausgleich) ist selbst der beste - '
              'auf diesen Daten kein Hinweis auf einen Nutzen von Dixon-Coles.'
          : 'Empfehlung: DixonColesEngine.rhoCandidates auf Werte nahe '
              '${best.toStringAsFixed(2)} umstellen (siehe Ergebnistabelle '
              'für Alternativen).',
    );

    stdout.writeln('\n== ROH-JSON (zum Weiterverarbeiten) ==');
    stdout.writeln(jsonEncode({
      for (final rho in rhoGrid)
        rho.toStringAsFixed(2): {
          'overallBrier': perRhoOverall[rho]!.average,
          'count': perRhoOverall[rho]!.count,
          'oneXTwoBrier': perRhoPerMarket[rho]![LearningMarket.oneXTwo]!.average,
          'bttsBrier': perRhoPerMarket[rho]![LearningMarket.btts]!.average,
          'overUnder25Brier':
              perRhoPerMarket[rho]![LearningMarket.overUnder25]!.average,
        },
    }));
  } finally {
    await database.close();
  }
}

class _AggregateScore {
  int count = 0;
  double _sum = 0.0;

  void add(double value) {
    count += 1;
    _sum += value;
  }

  double get average => count == 0 ? 0.0 : _sum / count;
}
