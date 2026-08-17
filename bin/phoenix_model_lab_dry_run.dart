import 'dart:convert';
import 'dart:io';

import 'package:phoenix_backend/src/config/model_lab_config.dart';
import 'package:phoenix_backend/src/database/database.dart';
import 'package:phoenix_backend/src/model_lab/challenger_generator.dart';
import 'package:phoenix_backend/src/model_lab/learning_dataset_builder.dart';
import 'package:phoenix_backend/src/model_lab/learning_market.dart';
import 'package:phoenix_backend/src/model_lab/league_market_status.dart';
import 'package:phoenix_backend/src/model_lab/walk_forward_evaluator.dart';
import 'package:phoenix_backend/src/model_lab/weight_config.dart';

/// Read-only(-ish) Dry Run für PHÖNIX MODEL LAB V0 (Section 88-93).
///
/// Führt AUSSER dem bereits heute bei jedem Server-Boot laufenden additiven
/// `database.migrate()` (CREATE TABLE IF NOT EXISTS / ADD COLUMN IF NOT
/// EXISTS - identisch sicher wie der produktive Boot-Pfad) KEINE Schreiboperation
/// aus: kein INSERT/UPDATE/DELETE in irgendeine Model-Lab- oder
/// Produktionstabelle. Der "erste Learning-Test" (Section 92) wird komplett
/// im Speicher berechnet und nur ausgegeben, nicht persistiert - das
/// tatsächliche Anlegen von Challengern passiert erst, wenn der echte
/// Tuesday-Learning-Run (`/api/admin/model-lab/learning-runs/start`) manuell
/// oder per Cron ausgeführt wird.
Future<void> main() async {
  // Lokale Ausführung außerhalb von Railways privatem Netzwerk kann die
  // interne DATABASE_URL nicht auflösen - DATABASE_PUBLIC_URL (Railway TCP
  // Proxy) ist von außen erreichbar und wird deshalb bevorzugt.
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

  try {
    stdout.writeln('== Migration (additiv, identisch zum produktiven Boot-Pfad) ==');
    await database.migrate();
    stdout.writeln('OK\n');

    final datasetBuilder = LearningDatasetBuilder(
      database: database,
      config: config,
    );

    stdout.writeln('== GLOBAL AUDIT (Section 89) ==');
    final audit = await datasetBuilder.auditEligibility();
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(audit.toJson()));
    stdout.writeln('');

    stdout.writeln('== WHITELIST-LIGEN (Section 90) ==');
    final leagues = await database.modelLabWhitelistedLeagues();
    stdout.writeln('Whitelist-Ligen insgesamt: ${leagues.length}');

    final perLeagueMarket = <Map<String, Object?>>[];
    Map<String, Object?>? bestCandidate;
    var bestCandidateSample = -1;

    for (final league in leagues) {
      final leagueId = league['league_id']?.toString();
      if (leagueId == null) continue;
      final counts = audit.perLeague.firstWhere(
        (c) => c.leagueId == leagueId,
        orElse: () => LeagueEligibilityCounts(leagueId: leagueId),
      );

      final marketStatuses = <Map<String, Object?>>[];
      for (final market in LearningMarket.values) {
        final status = classifyLeagueMarketStatus(
          eligibleSampleSize: counts.eligible,
          hasLeagueChampion: false,
          hasLeagueChallengers: false,
          hasShadowPredictions: false,
          config: config,
        );
        marketStatuses.add({'market': market.key, 'sampleSize': counts.eligible, 'status': status.label});

        if (counts.eligible > bestCandidateSample) {
          bestCandidateSample = counts.eligible;
          bestCandidate = {
            'leagueId': leagueId,
            'leagueName': league['league_name'],
            'market': market.key,
            'sampleSize': counts.eligible,
          };
        }
      }

      final entry = {
        'leagueId': leagueId,
        'leagueName': league['league_name'],
        'country': league['country'],
        'storedMatches': counts.stored,
        'settledMatches': counts.settled,
        'eligibleMatches': counts.eligible,
        'markets': marketStatuses,
      };
      perLeagueMarket.add(entry);
      stdout.writeln(jsonEncode(entry));
    }
    stdout.writeln('');

    stdout.writeln('== BEST TEST CANDIDATE (Section 91) ==');
    stdout.writeln(
      bestCandidate == null
          ? 'Kein Kandidat gefunden (keine Whitelist-Ligen mit Daten).'
          : jsonEncode(bestCandidate),
    );
    stdout.writeln('');

    stdout.writeln('== ERSTER LEARNING TEST (Section 92, NUR IM SPEICHER, NICHTS GESPEICHERT) ==');
    if (bestCandidate == null || bestCandidateSample < config.minLearningEligibleSamples) {
      stdout.writeln('NOCH NICHT GENUG PHÖNIX-EIGENE DATEN.');
      stdout.writeln(
        'Bester Kandidat: ${bestCandidate?['leagueName']} (${bestCandidate?['leagueId']}) '
        '/ ${bestCandidate?['market']} - vorhanden: $bestCandidateSample, '
        'benötigt: ${config.minLearningEligibleSamples}.',
      );
    } else {
      final leagueId = bestCandidate['leagueId'] as String;
      final market = LearningMarket.fromKey(bestCandidate['market'] as String)!;
      final samples = await datasetBuilder.buildSamples(leagueId: leagueId);
      final split = ChronologicalSplit.split(samples, config);

      stdout.writeln('Liga: ${bestCandidate['leagueName']} ($leagueId), Markt: ${market.key}');
      stdout.writeln(
        'Training: ${split.training.length}, Validation: ${split.validation.length}, '
        'Holdout: ${split.holdout.length}',
      );

      if (split.validation.isEmpty && split.holdout.isEmpty) {
        stdout.writeln('Zeitliche Aufteilung liefert keine Validation/Holdout-Menge - noch zu wenig Daten für einen echten Vergleich.');
      } else {
        final grid = ChallengerGenerator.candidateAttackWeights(config);
        stdout.writeln('Challenger-Suchraum (attackWeight): $grid');

        for (var i = 0; i < grid.length; i++) {
          final raw = EngineWeightConfig(attackWeight: grid[i]);
          final shrunk = raw.shrunkTowardsGlobal(sampleSize: samples.length, config: config);
          stdout.writeln(
            '\n--- Challenger V-C${i + 1} (raw attackWeight=${grid[i]}, '
            'shrunk=${shrunk.attackWeight.toStringAsFixed(4)}, sampleSize=${samples.length}) ---',
          );

          if (split.validation.isNotEmpty) {
            final validationComparison = ChampionChallengerComparison.compare(
              market: market,
              leagueId: leagueId,
              scopeSamples: split.validation,
              championWeights: EngineWeightConfig.global,
              challengerWeights: shrunk,
              config: config,
            );
            stdout.writeln('Validation: ${jsonEncode(validationComparison.toJson())}');
          }
          if (split.holdout.isNotEmpty) {
            final holdoutComparison = ChampionChallengerComparison.compare(
              market: market,
              leagueId: leagueId,
              scopeSamples: split.holdout,
              championWeights: EngineWeightConfig.global,
              challengerWeights: shrunk,
              config: config,
            );
            stdout.writeln('Holdout: ${jsonEncode(holdoutComparison.toJson())}');
          }
        }
      }
    }

    stdout.writeln('\n== FERTIG - KEINE Promotion, KEINE Challenger/Model-Zeilen wurden geschrieben. ==');
  } finally {
    await database.close();
  }
}
