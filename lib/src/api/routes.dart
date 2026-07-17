import 'dart:async';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../config/app_config.dart';
import '../database/database.dart';
import '../http/json_response.dart';
import '../services/football_phase_one_scan_service.dart';
import '../services/football_phase_two_scan_service.dart';
import '../services/football_engine_input_service.dart';
import '../services/football_simulation_service.dart';
import '../services/football_market_selection_service.dart';
import '../services/football_value_service.dart';
import '../services/football_finalization_service.dart';
import '../services/football_daily_pipeline_service.dart';
import '../services/gemini_context_service.dart';
import '../services/football_service.dart';
import '../services/tennis_service.dart';

class ApiRoutes {
  ApiRoutes({
    required this.config,
    required this.database,
    required this.football,
    required this.tennis,
  });

  final AppConfig config;
  final PhoenixDatabase database;
  final FootballService football;
  final TennisService tennis;

  Router get router {
    final router = Router();

    router.get('/health', (Request request) async {
      var databaseOk = false;
      String? databaseError;
      if (database.isConfigured) {
        try {
          databaseOk = await database.ping();
        } catch (error) {
          databaseError = error.toString();
        }
      }

      return jsonResponse({
        'status': 'ok',
        'service': 'phoenix-backend',
        'time': DateTime.now().toUtc().toIso8601String(),
        'environment': config.environment,
        'database': {
          'configured': database.isConfigured,
          'connected': databaseOk,
          if (databaseError != null) 'error': databaseError,
        },
        'providers': {
          'football': football.isConfigured,
          'tennis': tennis.isConfigured,
        },
      });
    });

    router.get('/api/football/matches/today', (Request request) async {
      try {
        final matches = await football.matchesForDate(DateTime.now());
        return jsonResponse({
          'sport': 'football',
          'date': _day(DateTime.now()),
          'count': matches.length,
          'matches': matches,
        });
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 502);
      }
    });

    router.get(
      '/api/football/matches/<date|[0-9]{4}-[0-9]{2}-[0-9]{2}>',
      (Request request, String date) async {
        final parsed = DateTime.tryParse(date);
        if (parsed == null) {
          return jsonResponse(
            {'error': 'Datum muss YYYY-MM-DD sein.'},
            statusCode: 400,
          );
        }

        try {
          final matches = await football.matchesForDate(parsed);
          return jsonResponse({
            'sport': 'football',
            'date': _day(parsed),
            'count': matches.length,
            'matches': matches,
          });
        } catch (error) {
          return jsonResponse({'error': error.toString()}, statusCode: 502);
        }
      },
    );

    router.post('/api/admin/football/scan/phase1', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }

      final dateValue = request.url.queryParameters['date'];
      final date =
          dateValue == null ? DateTime.now() : DateTime.tryParse(dateValue);

      if (date == null) {
        return jsonResponse(
          {'error': 'Datum muss YYYY-MM-DD sein.'},
          statusCode: 400,
        );
      }

      try {
        final scanner = FootballPhaseOneScanService(
          database: database,
          football: football,
        );
        final includeDetails =
            request.url.queryParameters['details'] == 'true';
        final result = await scanner.run(
          date,
          includeDetails: includeDetails,
        );
        return jsonResponse(result);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 502);
      }
    });



    router.post('/api/admin/football/scan/phase2', (Request request) async {
      if (!_isAdmin(request)) return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      final phaseOneScanRunId = int.tryParse(request.url.queryParameters['scanRunId'] ?? '');
      final limit = int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 1;
      final minimumDataQuality = int.tryParse(request.url.queryParameters['minimumDataQuality'] ?? '') ?? 50;
      if (limit < 1 || limit > 20) return jsonResponse({'error': 'limit muss zwischen 1 und 20 liegen.'}, statusCode: 400);
      try {
        final scanner = FootballPhaseTwoScanService(database: database, football: football);
        final prepared = await scanner.prepare(
          phaseOneScanRunId: phaseOneScanRunId, limit: limit, minimumDataQuality: minimumDataQuality);
        if (prepared['started'] != true) return jsonResponse(prepared);
        unawaited(scanner.processPrepared(prepared));
        return jsonResponse({
          'status': 'started', 'phase': 2, 'scanRunId': prepared['scanRunId'],
          'limit': prepared['limit'], 'minimumDataQuality': prepared['minimumDataQuality'],
          'statusUrl': '/api/admin/football/scan/phase2/${prepared['scanRunId']}',
        }, statusCode: 202);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 502);
      }
    });

    router.get('/api/admin/football/scan/phase2/<scanRunId|[0-9]+>',
      (Request request, String scanRunId) async {
        if (!_isAdmin(request)) return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
        final id = int.tryParse(scanRunId);
        if (id == null) return jsonResponse({'error': 'Ungültige Scan-ID.'}, statusCode: 400);
        final status = await database.footballScanRunStatus(id);
        if (status == null) return jsonResponse({'error': 'Scan nicht gefunden.'}, statusCode: 404);
        return jsonResponse(status);
      },
    );


    router.get(
      '/api/admin/football/scan/phase2/<scanRunId|[0-9]+>/results',
      (Request request, String scanRunId) async {
        if (!_isAdmin(request)) {
          return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
        }

        final id = int.tryParse(scanRunId);
        if (id == null) {
          return jsonResponse(
            {'error': 'Ungültige Scan-ID.'},
            statusCode: 400,
          );
        }

        try {
          final status = await database.footballScanRunStatus(id);
          if (status == null) {
            return jsonResponse(
              {'error': 'Scan nicht gefunden.'},
              statusCode: 404,
            );
          }

          final results = await database.footballPhaseTwoResults(id);

          return jsonResponse({
            'scanRunId': id,
            'status': status['status'],
            'checked': status['checked'] ?? 0,
            'analysisAllowed': status['analysis_allowed'] ?? 0,
            'belowThreshold': status['below_threshold'] ?? 0,
            'count': results.length,
            'results': results,
          });
        } catch (error) {
          return jsonResponse({'error': error.toString()}, statusCode: 500);
        }
      },
    );


router.post('/api/admin/football/engine/prepare', (Request request) async {
  if (!_isAdmin(request)) {
    return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
  }

  final phaseTwoScanRunId = int.tryParse(
    request.url.queryParameters['phase2ScanRunId'] ?? '',
  );
  final limit = int.tryParse(
        request.url.queryParameters['limit'] ?? '',
      ) ??
      1;

  if (limit < 1 || limit > 20) {
    return jsonResponse(
      {'error': 'limit muss zwischen 1 und 20 liegen.'},
      statusCode: 400,
    );
  }

  try {
    final service = FootballEngineInputService(database: database);
    final result = await service.prepare(
      phaseTwoScanRunId: phaseTwoScanRunId,
      limit: limit,
    );
    return jsonResponse(result);
  } catch (error) {
    return jsonResponse({'error': error.toString()}, statusCode: 500);
  }
});

router.get(
  '/api/admin/football/engine/inputs/<scanRunId|[0-9]+>',
  (Request request, String scanRunId) async {
    if (!_isAdmin(request)) {
      return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
    }

    final id = int.tryParse(scanRunId);
    if (id == null) {
      return jsonResponse({'error': 'Ungültige Scan-ID.'}, statusCode: 400);
    }

    final inputs = await database.footballEngineInputs(id);
    return jsonResponse({
      'phaseTwoScanRunId': id,
      'count': inputs.length,
      'inputs': inputs,
    });
  },
);


    router.post('/api/admin/football/engine/simulate', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }

      final phaseTwoScanRunId = int.tryParse(
        request.url.queryParameters['phase2ScanRunId'] ?? '',
      );
      final limit = int.tryParse(
            request.url.queryParameters['limit'] ?? '',
          ) ??
          1;
      final simulations = int.tryParse(
            request.url.queryParameters['simulations'] ?? '',
          ) ??
          10000;

      if (phaseTwoScanRunId == null) {
        return jsonResponse(
          {'error': 'phase2ScanRunId fehlt.'},
          statusCode: 400,
        );
      }

      if (limit < 1 || limit > 20) {
        return jsonResponse(
          {'error': 'limit muss zwischen 1 und 20 liegen.'},
          statusCode: 400,
        );
      }

      if (simulations < 1000 || simulations > 100000) {
        return jsonResponse(
          {'error': 'simulations muss zwischen 1000 und 100000 liegen.'},
          statusCode: 400,
        );
      }

      try {
        final service = FootballSimulationService(database: database);
        final result = await service.run(
          phaseTwoScanRunId: phaseTwoScanRunId,
          limit: limit,
          simulations: simulations,
        );
        return jsonResponse(result);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get(
      '/api/admin/football/engine/simulations/<scanRunId|[0-9]+>',
      (Request request, String scanRunId) async {
        if (!_isAdmin(request)) {
          return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
        }

        final id = int.tryParse(scanRunId);
        if (id == null) {
          return jsonResponse({'error': 'Ungültige Scan-ID.'}, statusCode: 400);
        }

        final results = await database.footballSimulationResults(id);
        return jsonResponse({
          'phaseTwoScanRunId': id,
          'count': results.length,
          'results': results,
        });
      },
    );


    router.post(
      '/api/admin/football/engine/select-market',
      (Request request) async {
        if (!_isAdmin(request)) {
          return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
        }

        final phaseTwoScanRunId = int.tryParse(
          request.url.queryParameters['phase2ScanRunId'] ?? '',
        );
        final limit = int.tryParse(
              request.url.queryParameters['limit'] ?? '',
            ) ??
            1;
        final minimumProbability = double.tryParse(
              request.url.queryParameters['minimumProbability'] ?? '',
            ) ??
            55.0;

        if (phaseTwoScanRunId == null) {
          return jsonResponse(
            {'error': 'phase2ScanRunId fehlt.'},
            statusCode: 400,
          );
        }

        if (limit < 1 || limit > 20) {
          return jsonResponse(
            {'error': 'limit muss zwischen 1 und 20 liegen.'},
            statusCode: 400,
          );
        }

        if (minimumProbability < 0 || minimumProbability > 100) {
          return jsonResponse(
            {'error': 'minimumProbability muss zwischen 0 und 100 liegen.'},
            statusCode: 400,
          );
        }

        try {
          final service = FootballMarketSelectionService(database: database);
          final result = await service.select(
            phaseTwoScanRunId: phaseTwoScanRunId,
            limit: limit,
            minimumProbability: minimumProbability,
          );
          return jsonResponse(result);
        } catch (error) {
          return jsonResponse({'error': error.toString()}, statusCode: 500);
        }
      },
    );

    router.get(
      '/api/admin/football/engine/selections/<scanRunId|[0-9]+>',
      (Request request, String scanRunId) async {
        if (!_isAdmin(request)) {
          return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
        }

        final id = int.tryParse(scanRunId);
        if (id == null) {
          return jsonResponse({'error': 'Ungültige Scan-ID.'}, statusCode: 400);
        }

        final selections = await database.footballMarketSelections(id);
        return jsonResponse({
          'phaseTwoScanRunId': id,
          'count': selections.length,
          'selections': selections,
        });
      },
    );


    router.post('/api/admin/football/engine/check-value', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }

      final phaseTwoScanRunId = int.tryParse(
        request.url.queryParameters['phase2ScanRunId'] ?? '',
      );
      final limit = int.tryParse(
            request.url.queryParameters['limit'] ?? '',
          ) ??
          1;
      final minimumMarketOdds = double.tryParse(
            request.url.queryParameters['minimumMarketOdds'] ?? '',
          ) ??
          1.40;
      final minimumValuePercent = double.tryParse(
            request.url.queryParameters['minimumValuePercent'] ?? '',
          ) ??
          5.0;

      if (phaseTwoScanRunId == null) {
        return jsonResponse(
          {'error': 'phase2ScanRunId fehlt.'},
          statusCode: 400,
        );
      }

      if (limit < 1 || limit > 20) {
        return jsonResponse(
          {'error': 'limit muss zwischen 1 und 20 liegen.'},
          statusCode: 400,
        );
      }

      try {
        final service = FootballValueService(
          database: database,
          football: football,
        );
        final result = await service.check(
          phaseTwoScanRunId: phaseTwoScanRunId,
          limit: limit,
          minimumMarketOdds: minimumMarketOdds,
          minimumValuePercent: minimumValuePercent,
        );
        return jsonResponse(result);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });


    router.post(
      '/api/admin/football/ai/verify-context',
      (Request request) async {
        if (!_isAdmin(request)) {
          return jsonResponse(
            {'error': 'Nicht autorisiert.'},
            statusCode: 401,
          );
        }

        final scanId = int.tryParse(
          request.url.queryParameters['phase2ScanRunId'] ?? '',
        );
        final limit =
            int.tryParse(
              request.url.queryParameters['limit'] ?? '',
            ) ??
            1;

        if (scanId == null) {
          return jsonResponse(
            {'error': 'phase2ScanRunId fehlt.'},
            statusCode: 400,
          );
        }

        if (limit < 1 || limit > 10) {
          return jsonResponse(
            {'error': 'limit muss zwischen 1 und 10 liegen.'},
            statusCode: 400,
          );
        }

        try {
          final jobId = await database.createFootballAiContextJob(
            phaseTwoScanRunId: scanId,
            limit: limit,
          );

          final service = GeminiContextService(database: database);

          unawaited(
            service.runBackground(
              jobId: jobId,
              phaseTwoScanRunId: scanId,
              limit: limit,
            ),
          );

          return jsonResponse({
            'status': 'started',
            'jobId': jobId,
            'phaseTwoScanRunId': scanId,
            'limit': limit,
            'statusUrl': '/api/admin/football/ai/jobs/$jobId',
            'resultUrl': '/api/admin/football/ai/context/$scanId',
          }, statusCode: 202);
        } catch (error) {
          return jsonResponse(
            {'error': error.toString()},
            statusCode: 500,
          );
        }
      },
    );

    router.get(
      '/api/admin/football/ai/jobs/<jobId|[0-9]+>',
      (Request request, String jobId) async {
        if (!_isAdmin(request)) {
          return jsonResponse(
            {'error': 'Nicht autorisiert.'},
            statusCode: 401,
          );
        }

        final id = int.tryParse(jobId);
        if (id == null) {
          return jsonResponse(
            {'error': 'Ungültige Job-ID.'},
            statusCode: 400,
          );
        }

        final status = await database.footballAiContextJobStatus(id);
        if (status == null) {
          return jsonResponse(
            {'error': 'Job nicht gefunden.'},
            statusCode: 404,
          );
        }

        return jsonResponse(status);
      },
    );

    router.get('/api/admin/football/ai/context/<scanRunId|[0-9]+>', (Request request, String scanRunId) async {
      if (!_isAdmin(request)) return jsonResponse({'error':'Nicht autorisiert.'}, statusCode:401);
      final id=int.tryParse(scanRunId);
      if (id==null) return jsonResponse({'error':'Ungültige Scan-ID.'}, statusCode:400);
      final results=await database.footballAiContextChecks(id);
      return jsonResponse({'phaseTwoScanRunId':id,'count':results.length,'results':results});
    });

    router.post('/api/admin/football/leagues/seed-start', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }

      final season = int.tryParse(
            request.url.queryParameters['season'] ?? '',
          ) ??
          2026;

      try {
        await database.seedFootballStartLeagues(season: season);
        return jsonResponse({
          'status': 'start_leagues_whitelisted',
          'season': season,
          'count': 10,
          'leagueIds': [
            '39',
            '61',
            '78',
            '79',
            '80',
            '88',
            '94',
            '135',
            '140',
            '144',
          ],
        });
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/api/admin/football/leagues', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }

      final limit = int.tryParse(
            request.url.queryParameters['limit'] ?? '',
          ) ??
          200;

      try {
        final leagues = await database.listFootballLeagueProfiles(limit: limit);
        return jsonResponse({
          'count': leagues.length,
          'leagues': leagues,
        });
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.post(
      '/api/admin/football/leagues/<leagueId>/status',
      (Request request, String leagueId) async {
        if (!_isAdmin(request)) {
          return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
        }

        final value = request.url.queryParameters['value']?.trim() ?? '';
        if (!const {'auto', 'whitelist', 'blacklist'}.contains(value)) {
          return jsonResponse(
            {'error': 'value muss auto, whitelist oder blacklist sein.'},
            statusCode: 400,
          );
        }

        try {
          final updated = await database.setFootballLeagueManualStatus(
            leagueId: leagueId,
            manualStatus: value,
          );
          if (!updated) {
            return jsonResponse(
              {'error': 'Liga nicht gefunden.'},
              statusCode: 404,
            );
          }
          return jsonResponse({
            'status': 'updated',
            'leagueId': leagueId,
            'manualStatus': value,
          });
        } on ArgumentError catch (error) {
          return jsonResponse(
            {'error': error.message?.toString() ?? error.toString()},
            statusCode: 400,
          );
        } catch (error) {
          return jsonResponse({'error': error.toString()}, statusCode: 500);
        }
      },
    );

    router.get('/api/tennis/matches/today', (Request request) async {
      try {
        final matches = await tennis.matchesForDate(DateTime.now());
        return jsonResponse({
          'sport': 'tennis',
          'date': _day(DateTime.now()),
          'count': matches.length,
          'matches': matches,
        });
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 502);
      }
    });

    router.get(
      '/api/tennis/matches/<date|[0-9]{4}-[0-9]{2}-[0-9]{2}>',
      (Request request, String date) async {
        final parsed = DateTime.tryParse(date);
        if (parsed == null) {
          return jsonResponse(
            {'error': 'Datum muss YYYY-MM-DD sein.'},
            statusCode: 400,
          );
        }

        try {
          final matches = await tennis.matchesForDate(parsed);
          return jsonResponse({
            'sport': 'tennis',
            'date': _day(parsed),
            'count': matches.length,
            'matches': matches,
          });
        } catch (error) {
          return jsonResponse({'error': error.toString()}, statusCode: 502);
        }
      },
    );

    router.get('/api/tips/today', (Request request) async {
      final date = DateTime.now();
      final tips = await database.footballFinalTipsForDate(date);
      return jsonResponse({
        'date': _day(date),
        'football': tips,
        'footballCount': tips.length,
        'tennis': null,
      });
    });

    router.get(
      '/api/football/tips/<date|[0-9]{4}-[0-9]{2}-[0-9]{2}>',
      (Request request, String date) async {
        final parsed = DateTime.tryParse(date);
        if (parsed == null) {
          return jsonResponse(
            {'error': 'Datum muss YYYY-MM-DD sein.'},
            statusCode: 400,
          );
        }
        final tips = await database.footballFinalTipsForDate(parsed);
        return jsonResponse({
          'date': date,
          'count': tips.length,
          'tips': tips,
        });
      },
    );

    router.post('/api/admin/football/finalize', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      final scanId = int.tryParse(
        request.url.queryParameters['phase2ScanRunId'] ?? '',
      );
      if (scanId == null) {
        return jsonResponse(
          {'error': 'phase2ScanRunId fehlt.'},
          statusCode: 400,
        );
      }
      try {
        final result = await FootballFinalizationService(
          database: database,
        ).finalize(phaseTwoScanRunId: scanId);
        return jsonResponse(result);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.post('/api/admin/football/daily-scan', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }

      final dateText = request.url.queryParameters['date'];
      final date = dateText == null
          ? DateTime.now()
          : DateTime.tryParse(dateText);
      final limit = int.tryParse(
            request.url.queryParameters['limit'] ?? '',
          ) ??
          20;
      final minimumDataQuality = int.tryParse(
            request.url.queryParameters['minimumDataQuality'] ?? '',
          ) ??
          50;
      final simulations = int.tryParse(
            request.url.queryParameters['simulations'] ?? '',
          ) ??
          10000;

      if (date == null) {
        return jsonResponse(
          {'error': 'Datum muss YYYY-MM-DD sein.'},
          statusCode: 400,
        );
      }
      if (limit < 1 || limit > 20) {
        return jsonResponse(
          {'error': 'limit muss zwischen 1 und 20 liegen.'},
          statusCode: 400,
        );
      }

      final jobId = await database.createFootballDailyPipelineJob(
        date: date,
        limit: limit,
        minimumDataQuality: minimumDataQuality,
        simulations: simulations,
      );

      unawaited(
        FootballDailyPipelineService(
          database: database,
          football: football,
        ).run(
          jobId: jobId,
          date: date,
          limit: limit,
          minimumDataQuality: minimumDataQuality,
          simulations: simulations,
        ),
      );

      return jsonResponse({
        'status': 'started',
        'jobId': jobId,
        'date': _day(date),
        'limit': limit,
        'minimumDataQuality': minimumDataQuality,
        'simulations': simulations,
        'statusUrl': '/api/admin/football/daily-scan/$jobId',
      }, statusCode: 202);
    });

    router.get(
      '/api/admin/football/daily-scan/<jobId|[0-9]+>',
      (Request request, String jobId) async {
        if (!_isAdmin(request)) {
          return jsonResponse(
            {'error': 'Nicht autorisiert.'},
            statusCode: 401,
          );
        }
        final id = int.tryParse(jobId);
        if (id == null) {
          return jsonResponse(
            {'error': 'Ungültige Job-ID.'},
            statusCode: 400,
          );
        }
        final job = await database.footballDailyPipelineJob(id);
        if (job == null) {
          return jsonResponse(
            {'error': 'Job nicht gefunden.'},
            statusCode: 404,
          );
        }
        return jsonResponse(job);
      },
    );

    router.post('/api/admin/migrate', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }

      try {
        await database.migrate();
        return jsonResponse({'status': 'migration_complete'});
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.all(
      '/<ignored|.*>',
      (Request request) =>
          jsonResponse({'error': 'Route nicht gefunden.'}, statusCode: 404),
    );

    return router;
  }

  bool _isAdmin(Request request) {
    if (config.adminToken.isEmpty) return false;
    final header = request.headers['authorization'] ?? '';
    return header == 'Bearer ${config.adminToken}';
  }

  String _day(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
