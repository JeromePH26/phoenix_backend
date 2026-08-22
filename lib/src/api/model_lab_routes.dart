import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../config/app_config.dart';
import '../config/model_lab_config.dart';
import '../database/database.dart';
import '../http/json_response.dart';
import '../model_lab/global_goals_v1_engine.dart';
import '../model_lab/learning_dataset_builder.dart';
import '../model_lab/learning_market.dart';
import '../model_lab/learning_run_service.dart';
import '../model_lab/league_market_status.dart';
import '../model_lab/model_lab_schedule.dart';
import '../model_lab/model_registry_service.dart';
import '../model_lab/monthly_review_service.dart';
import '../model_lab/shadow_prediction_service.dart';

/// PHÖNIX MODEL LAB Admin-API (Section 80). Wird über
/// `router.mount('/api/admin/model-lab/', ModelLabRoutes(...).router)` in
/// `lib/src/api/routes.dart` eingehängt. Nutzt exakt dieselbe Admin-Auth wie
/// alle anderen Admin-Routen (Bearer-Token-Vergleich in konstanter Zeit).
class ModelLabRoutes {
  ModelLabRoutes({
    required this.config,
    required this.modelLabConfig,
    required this.database,
  });

  final AppConfig config;
  final ModelLabConfig modelLabConfig;
  final PhoenixDatabase database;

  Router get router {
    final router = Router();

    router.get('/overview', (Request request) async {
      if (!_isAdmin(request)) return _unauthorized();
      try {
        final audit = await LearningDatasetBuilder(
          database: database,
          config: modelLabConfig,
        ).auditEligibility();
        final leagues = await database.modelLabWhitelistedLeagues();
        final champions = await database.allModelVersions(status: 'champion');
        final challengers = await database.allModelVersions(
          status: 'challenger',
        );
        final shadowCount = await database.countShadowPredictions();
        final lastRuns = await database.listLearningRuns(limit: 1);
        final berlinNow = ModelLabSchedule.berlinNow();

        return jsonResponse({
          'learningSystem': 'ACTIVE_SHADOW',
          'promotionEnabled': modelLabConfig.promotionEnabled,
          'generativeAi': 'OFF',
          'whitelistLeagues': leagues.length,
          'activeChampions': champions.length,
          'activeChallengers': challengers.length,
          'shadowPredictions': shadowCount,
          'learningEligibleMatches': audit.eligible,
          'lastLearningRun': lastRuns.isEmpty ? null : _jsonSafe(lastRuns.first),
          'nextLearningRunBerlin': ModelLabSchedule.nextLearningRun(
            berlinNow,
            modelLabConfig,
          ).toIso8601String(),
          'nextChampionReviewBerlin': ModelLabSchedule.nextMonthlyReview(
            berlinNow,
            modelLabConfig,
          ).toIso8601String(),
        });
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/leagues', (Request request) async {
      if (!_isAdmin(request)) return _unauthorized();
      try {
        final leagues = await _leagueOverview();
        return jsonResponse({'count': leagues.length, 'leagues': leagues});
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/league/<leagueId>', (Request request, String leagueId) async {
      if (!_isAdmin(request)) return _unauthorized();
      try {
        final overview = await _leagueOverview(onlyLeagueId: leagueId);
        if (overview.isEmpty) {
          return jsonResponse({'error': 'Liga nicht gefunden.'}, statusCode: 404);
        }
        return jsonResponse(overview.first);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/league/<leagueId>/market/<market>', (
      Request request,
      String leagueId,
      String market,
    ) async {
      if (!_isAdmin(request)) return _unauthorized();
      final learningMarket = LearningMarket.fromKey(market);
      if (learningMarket == null) {
        return jsonResponse({'error': 'Unbekannter Markt.'}, statusCode: 400);
      }
      try {
        final registry = ModelRegistryService(
          database: database,
          config: modelLabConfig,
        );
        final champion = await registry.currentChampion(
          leagueId: leagueId,
          market: market,
        ) ?? await database.globalBaselineModel(market);
        final challengers = await registry.currentChallengers(
          leagueId: leagueId,
          market: market,
        );

        final challengerDetails = <Map<String, Object?>>[];
        for (final challenger in challengers) {
          final evaluations = await database.modelEvaluations(
            modelVersionId: challenger['id'] as int,
          );
          challengerDetails.add({
            ...(_jsonSafe(challenger) as Map<String, Object?>),
            'evaluations': evaluations.map(_jsonSafe).toList(),
          });
        }

        final championEvaluations = champion == null
            ? <Map<String, Object?>>[]
            : await database.modelEvaluations(
                modelVersionId: champion['id'] as int,
              );

        return jsonResponse({
          'leagueId': leagueId,
          'market': market,
          'champion': champion == null ? null : _jsonSafe(champion),
          'championEvaluations': championEvaluations.map(_jsonSafe).toList(),
          'challengers': challengerDetails,
        });
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    // Rein lesender Vergleich Produktions-Baseline (goal_rate_normalization
    // v4, unveraendert) vs. GLOBAL_GOALS_V1 (neu, Shadow-only) fuer ein
    // einzelnes Spiel. Schreibt nichts, beeinflusst keine Prediction -
    // Section "LETZTE SICHERHEITSREGEL".
    router.get('/engines/goals-v1/preview', (Request request) async {
      if (!_isAdmin(request)) return _unauthorized();
      final fixtureId = request.url.queryParameters['fixtureId']?.trim();
      if (fixtureId == null || fixtureId.isEmpty) {
        return jsonResponse(
          {'error': 'fixtureId ist erforderlich.'},
          statusCode: 400,
        );
      }
      try {
        final row = await database.footballLatestPhaseTwoResultForFixture(
          fixtureId,
        );
        if (row == null) {
          return jsonResponse(
            {'error': 'Kein Availability-Snapshot für dieses Spiel gefunden.'},
            statusCode: 404,
          );
        }
        final availabilityRaw = row['availability'];
        final availability = availabilityRaw is Map
            ? Map<String, Object?>.from(availabilityRaw)
            : <String, Object?>{};
        final leagueId = row['league_id']?.toString() ?? '';
        final homeTeamId = row['home_team_id']?.toString() ?? '';
        final awayTeamId = row['away_team_id']?.toString() ?? '';

        final context = await database.footballLeagueGoalContext(
          leagueId: leagueId,
        );

        double? number(Object? value) {
          if (value is num) return value.toDouble();
          return double.tryParse(value?.toString() ?? '');
        }

        final homeFor = number(availability['homeGoalsForAverageHome']);
        final homeAgainst = number(availability['homeGoalsAgainstAverageHome']);
        final awayFor = number(availability['awayGoalsForAverageAway']);
        final awayAgainst = number(availability['awayGoalsAgainstAverageAway']);
        double? averageAvailable(double? a, double? b) {
          if (a == null && b == null) return null;
          if (a == null) return b;
          if (b == null) return a;
          return (a + b) / 2;
        }

        final baselineHome = averageAvailable(homeFor, awayAgainst) ?? 1.35;
        final baselineAway = averageAvailable(awayFor, homeAgainst) ?? 1.10;

        final v1 = GlobalGoalsV1Engine.compute(
          availability: availability,
          homeTeamId: homeTeamId,
          awayTeamId: awayTeamId,
          leagueAvgHomeGoalsPerGame:
              number(context['avgHomeGoalsPerGame']),
          leagueAvgAwayGoalsPerGame:
              number(context['avgAwayGoalsPerGame']),
        );

        return jsonResponse({
          'fixtureId': fixtureId,
          'homeTeam': row['home_team_name'],
          'awayTeam': row['away_team_name'],
          'leagueGoalContext': context,
          'baseline': {
            'version': 'goal_rate_normalization_v4_stat_only',
            'expectedHome': baselineHome,
            'expectedAway': baselineAway,
            'expectedTotal': baselineHome + baselineAway,
          },
          'v1': v1.toJson(),
        });
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/models', (Request request) async {
      if (!_isAdmin(request)) return _unauthorized();
      final status = request.url.queryParameters['status'];
      try {
        final models = await database.allModelVersions(status: status);
        return jsonResponse({
          'count': models.length,
          'models': models.map(_jsonSafe).toList(),
        });
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/models/<id|[0-9]+>', (Request request, String id) async {
      if (!_isAdmin(request)) return _unauthorized();
      final modelId = int.tryParse(id);
      if (modelId == null) {
        return jsonResponse({'error': 'Ungültige Model-ID.'}, statusCode: 400);
      }
      try {
        final model = await database.modelVersion(modelId);
        if (model == null) {
          return jsonResponse({'error': 'Model nicht gefunden.'}, statusCode: 404);
        }
        final evaluations = await database.modelEvaluations(
          modelVersionId: modelId,
        );
        return jsonResponse(<String, Object?>{
          ...(_jsonSafe(model) as Map<String, Object?>),
          'evaluations': evaluations.map(_jsonSafe).toList(),
        });
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/learning-runs', (Request request) async {
      if (!_isAdmin(request)) return _unauthorized();
      final limit = int.tryParse(
        request.url.queryParameters['limit'] ?? '',
      ) ?? 50;
      try {
        final runs = await database.listLearningRuns(limit: limit);
        return jsonResponse({
          'count': runs.length,
          'runs': runs.map(_jsonSafe).toList(),
        });
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/learning-runs/<id|[0-9]+>', (Request request, String id) async {
      if (!_isAdmin(request)) return _unauthorized();
      final runId = int.tryParse(id);
      if (runId == null) {
        return jsonResponse({'error': 'Ungültige Run-ID.'}, statusCode: 400);
      }
      try {
        final run = await database.learningRun(runId);
        if (run == null) {
          return jsonResponse({'error': 'Run nicht gefunden.'}, statusCode: 404);
        }
        return jsonResponse(_jsonSafe(run));
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.post('/learning-runs/start', (Request request) async {
      if (!_isAdmin(request)) return _unauthorized();
      if (!await database.moduleEnabled('model_lab_learning')) {
        return jsonResponse({
          'error': 'Modul "Model Lab Learning" ist deaktiviert (App Control → Module).',
        }, statusCode: 503);
      }
      try {
        // Section 79: exakt dieselbe Business-Logik wie der geplante
        // Dienstags-Job, nur mit trigger_type='manual'.
        final result = await LearningRunService(
          database: database,
          config: modelLabConfig,
        ).run(triggerType: 'manual');
        return jsonResponse(result, statusCode: 202);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/monthly-reviews', (Request request) async {
      if (!_isAdmin(request)) return _unauthorized();
      final limit = int.tryParse(
        request.url.queryParameters['limit'] ?? '',
      ) ?? 100;
      try {
        final reviews = await database.listMonthlyReviews(limit: limit);
        return jsonResponse({
          'count': reviews.length,
          'reviews': reviews.map(_jsonSafe).toList(),
        });
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.post('/monthly-review/run', (Request request) async {
      if (!_isAdmin(request)) return _unauthorized();
      try {
        // Section 79: exakt dieselbe Business-Logik wie der geplante
        // Mittwochs-Job, nur mit trigger_type='manual' (ignoriert das
        // First-Wednesday-Datumsgate für Testzwecke, siehe
        // MonthlyReviewService).
        final result = await MonthlyReviewService(
          database: database,
          config: modelLabConfig,
        ).run(triggerType: 'manual');
        return jsonResponse(result, statusCode: 202);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/shadow-performance', (Request request) async {
      if (!_isAdmin(request)) return _unauthorized();
      final modelIdParam = request.url.queryParameters['modelVersionId'];
      final modelId = int.tryParse(modelIdParam ?? '');
      if (modelId == null) {
        return jsonResponse({
          'error': 'Query-Parameter modelVersionId (Zahl) ist erforderlich.',
        }, statusCode: 400);
      }
      try {
        final settled = await database.settledShadowPredictions(
          modelVersionId: modelId,
        );
        final total = settled.length;
        final avgBrier = total == 0
            ? null
            : settled
                    .map((r) => (r['brier_score'] as num?)?.toDouble() ?? 0)
                    .reduce((a, b) => a + b) /
                total;
        return jsonResponse({
          'modelVersionId': modelId,
          'settledShadowPredictions': total,
          'averageBrierScore': avgBrier,
          'predictions': settled.map(_jsonSafe).toList(),
        });
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.post('/shadow-predictions/generate', (Request request) async {
      if (!_isAdmin(request)) return _unauthorized();
      try {
        final created = await ShadowPredictionService(
          database: database,
          config: modelLabConfig,
        ).generatePendingShadowPredictions();
        return jsonResponse({'status': 'completed', 'created': created});
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.post('/shadow-predictions/settle', (Request request) async {
      if (!_isAdmin(request)) return _unauthorized();
      try {
        final settled = await ShadowPredictionService(
          database: database,
          config: modelLabConfig,
        ).settlePendingShadowPredictions();
        return jsonResponse({'status': 'completed', 'settled': settled});
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/dry-run', (Request request) async {
      if (!_isAdmin(request)) return _unauthorized();
      try {
        final audit = await LearningDatasetBuilder(
          database: database,
          config: modelLabConfig,
        ).auditEligibility();
        return jsonResponse(audit.toJson());
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/audit-log', (Request request) async {
      if (!_isAdmin(request)) return _unauthorized();
      final limit = int.tryParse(
        request.url.queryParameters['limit'] ?? '',
      ) ?? 200;
      try {
        final log = await database.listModelLabAuditLog(limit: limit);
        return jsonResponse({
          'count': log.length,
          'entries': log.map(_jsonSafe).toList(),
        });
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    // Section 53/54/55: Promotion ist standardmäßig serverseitig blockiert -
    // unabhängig davon, was die UI anzeigt oder anbietet.
    router.post('/models/<id|[0-9]+>/promote', (
      Request request,
      String id,
    ) async {
      if (!_isAdmin(request)) return _unauthorized();
      final modelId = int.tryParse(id);
      if (modelId == null) {
        return jsonResponse({'error': 'Ungültige Model-ID.'}, statusCode: 400);
      }
      if (!modelLabConfig.promotionEnabled) {
        await database.insertModelLabAuditLog(
          action: 'promotion_rejected',
          actor: 'admin',
          modelVersionId: modelId,
          details: {
            'reason': 'PHOENIX_MODEL_PROMOTION_ENABLED=false',
          },
        );
        return jsonResponse({
          'error': 'Promotion ist deaktiviert (PHOENIX_MODEL_PROMOTION_ENABLED=false).',
          'status': 'rejected',
        }, statusCode: 403);
      }

      try {
        final challenger = await database.modelVersion(modelId);
        if (challenger == null) {
          return jsonResponse({'error': 'Model nicht gefunden.'}, statusCode: 404);
        }
        final market = challenger['market']?.toString() ?? '';
        final leagueId = challenger['league_id']?.toString();
        final currentChampion = await database.championModel(
          leagueId: leagueId,
          market: market,
        );

        await database.promoteModel(
          newChampionId: modelId,
          previousChampionId: currentChampion?['id'] as int?,
        );
        await database.insertModelLabAuditLog(
          action: 'promotion',
          actor: 'admin',
          modelVersionId: modelId,
          leagueId: leagueId,
          market: market,
          details: {
            'previousChampionId': currentChampion?['id'],
          },
        );
        return jsonResponse({'status': 'promoted', 'modelVersionId': modelId});
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.post('/models/<id|[0-9]+>/rollback', (
      Request request,
      String id,
    ) async {
      if (!_isAdmin(request)) return _unauthorized();
      final modelId = int.tryParse(id);
      if (modelId == null) {
        return jsonResponse({'error': 'Ungültige Model-ID.'}, statusCode: 400);
      }
      if (!modelLabConfig.promotionEnabled) {
        return jsonResponse({
          'error': 'Rollback ist deaktiviert (PHOENIX_MODEL_PROMOTION_ENABLED=false).',
          'status': 'rejected',
        }, statusCode: 403);
      }

      try {
        final rollbackTarget = await database.modelVersion(modelId);
        if (rollbackTarget == null) {
          return jsonResponse({'error': 'Model nicht gefunden.'}, statusCode: 404);
        }
        final market = rollbackTarget['market']?.toString() ?? '';
        final leagueId = rollbackTarget['league_id']?.toString();
        final currentChampion = await database.championModel(
          leagueId: leagueId,
          market: market,
        );
        if (currentChampion == null) {
          return jsonResponse({
            'error': 'Kein aktueller Champion für diese Liga x Markt-Kombination.',
          }, statusCode: 400);
        }

        await database.rollbackModel(
          currentChampionId: currentChampion['id'] as int,
          rollbackToModelId: modelId,
        );
        await database.insertModelLabAuditLog(
          action: 'rollback',
          actor: 'admin',
          modelVersionId: modelId,
          leagueId: leagueId,
          market: market,
          details: {'rolledBackFrom': currentChampion['id']},
        );
        return jsonResponse({'status': 'rolled_back', 'modelVersionId': modelId});
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    return router;
  }

  Future<List<Map<String, Object?>>> _leagueOverview({
    String? onlyLeagueId,
  }) async {
    final datasetBuilder = LearningDatasetBuilder(
      database: database,
      config: modelLabConfig,
    );
    final registry = ModelRegistryService(database: database, config: modelLabConfig);
    final audit = await datasetBuilder.auditEligibility();
    final leagues = await database.modelLabWhitelistedLeagues();

    // Section 70/93: EIN Batch-Query für Champions/Challenger aller
    // relevanten Liga x Markt-Kombinationen, statt (wie zuvor) 2 sequenzielle
    // DB-Roundtrips je Kombination in der Schleife unten auszulösen - bei 36
    // Whitelist-Ligen x 3 Märkten waren das bis zu 216 Roundtrips und der
    // Endpoint lief in Produktion in den Client-Timeout.
    final relevantLeagueIds = [
      for (final league in leagues)
        if (league['league_id'] != null &&
            (onlyLeagueId == null ||
                league['league_id'].toString() == onlyLeagueId))
          league['league_id'].toString(),
    ];
    final batch = await registry.currentChampionsAndChallengersBatch(
      leagueIds: relevantLeagueIds,
      markets: [for (final market in LearningMarket.values) market.key],
    );

    final results = <Map<String, Object?>>[];
    for (final league in leagues) {
      final leagueId = league['league_id']?.toString();
      if (leagueId == null) continue;
      if (onlyLeagueId != null && leagueId != onlyLeagueId) continue;

      final counts = audit.perLeague.firstWhere(
        (c) => c.leagueId == leagueId,
        orElse: () => LeagueEligibilityCounts(leagueId: leagueId),
      );

      final markets = <Map<String, Object?>>[];
      for (final market in LearningMarket.values) {
        final key = ModelRegistryService.leagueMarketKey(leagueId, market.key);
        final champion = batch.champions[key];
        final challengers =
            batch.challengers[key] ?? const <Map<String, Object?>>[];
        final status = classifyLeagueMarketStatus(
          eligibleSampleSize: counts.eligible,
          hasLeagueChampion: champion != null,
          hasLeagueChallengers: challengers.isNotEmpty,
          hasShadowPredictions: false,
          config: modelLabConfig,
        );
        markets.add({
          'market': market.key,
          'marketLabel': market.label,
          'sampleSize': counts.eligible,
          // Section 14 (AN2): "Noch X abgerechnete Spiele bis zur
          // liga-spezifischen Version" - der reale Schwellenwert aus der
          // Konfiguration, damit das Frontend den Rest selbst ausrechnen
          // kann, statt einen Wert zu erfinden.
          'sampleThreshold': modelLabConfig.leagueAdaptationSampleThreshold,
          'status': status.label,
          'champion': champion == null
              ? null
              : {
                  'id': champion['id'],
                  'readableVersion': champion['readable_version'],
                },
          'bestChallenger': challengers.isEmpty
              ? null
              : {
                  'id': challengers.first['id'],
                  'readableVersion': challengers.first['readable_version'],
                },
          'challengerCount': challengers.length,
        });
      }

      results.add({
        'leagueId': leagueId,
        'leagueName': league['league_name'],
        'country': league['country'],
        'storedMatches': counts.stored,
        'settledMatches': counts.settled,
        'eligibleMatches': counts.eligible,
        'markets': markets,
      });
    }
    return results;
  }

  Response _unauthorized() =>
      jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);

  /// Identische konstante-Zeit-Prüfung wie `ApiRoutes._isAdmin` - bewusst
  /// dupliziert statt einer riskanten Umstrukturierung von `routes.dart`,
  /// konsistent mit dem bestehenden Wiederholungsmuster in dieser Codebasis.
  bool _isAdmin(Request request) {
    if (config.adminToken.isEmpty) return false;
    final header = request.headers['authorization'] ?? '';
    final expected = 'Bearer ${config.adminToken}';
    if (header.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < header.length; i++) {
      diff |= header.codeUnitAt(i) ^ expected.codeUnitAt(i);
    }
    return diff == 0;
  }

  Object? _jsonSafe(Object? value) {
    if (value == null || value is num || value is bool || value is String) {
      return value;
    }
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), _jsonSafe(item)));
    }
    if (value is Iterable) return value.map(_jsonSafe).toList();
    return value.toString();
  }
}
