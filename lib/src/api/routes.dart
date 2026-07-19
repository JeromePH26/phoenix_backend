import 'dart:async';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:postgres/postgres.dart';

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


    router.get('/api/football/provider', (Request request) async {
      final path = request.url.queryParameters['path'];
      if (path == null || path.trim().isEmpty) {
        return jsonResponse(
          {'error': 'Query-Parameter path fehlt.'},
          statusCode: 400,
        );
      }

      final query = Map<String, String>.from(
        request.url.queryParameters,
      )..remove('path');

      try {
        final payload = await football.providerRequest(
          path: path,
          query: query,
        );
        return jsonResponse(payload);
      } on ArgumentError catch (error) {
        return jsonResponse(
          {'error': error.message?.toString() ?? error.toString()},
          statusCode: 400,
        );
      } catch (error) {
        return jsonResponse(
          {'error': error.toString()},
          statusCode: 502,
        );
      }
    });


    router.get('/api/football/analyses/today', (Request request) async {
      final quality = int.tryParse(
            request.url.queryParameters['minimumQuality'] ?? '',
          ) ??
          60;
      final date = DateTime.now();

      try {
        final matches = await _preparedFootballAnalyses(
          date: date,
          minimumDataQuality: quality,
        );
        return jsonResponse(_jsonSafe({
          'sport': 'football',
          'date': _day(date),
          'source': 'server_prepared',
          'minimumDataQuality': quality.clamp(0, 100),
          'count': matches.length,
          'matches': matches,
        }));
      } catch (error) {
        return jsonResponse(
          {'error': error.toString()},
          statusCode: 500,
        );
      }
    });

    router.get(
      '/api/football/analyses/<date|[0-9]{4}-[0-9]{2}-[0-9]{2}>',
      (Request request, String date) async {
        final parsed = DateTime.tryParse(date);
        if (parsed == null) {
          return jsonResponse(
            {'error': 'Datum muss YYYY-MM-DD sein.'},
            statusCode: 400,
          );
        }

        final quality = int.tryParse(
              request.url.queryParameters['minimumQuality'] ?? '',
            ) ??
            50;

        try {
          final matches = await _preparedFootballAnalyses(
            date: parsed,
            minimumDataQuality: quality,
          );
          return jsonResponse(_jsonSafe({
            'sport': 'football',
            'date': _day(parsed),
            'source': 'server_prepared',
            'minimumDataQuality': quality.clamp(0, 100),
            'count': matches.length,
            'matches': matches,
          }));
        } catch (error) {
          return jsonResponse(
            {'error': error.toString()},
            statusCode: 500,
          );
        }
      },
    );

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


    router.get(
      '/api/football/live/<fixtureId|[0-9]+>',
      (Request request, String fixtureId) async {
        try {
          final snapshot = await football.liveSnapshot(fixtureId);
          return jsonResponse(snapshot);
        } catch (error) {
          return jsonResponse(
            {'error': error.toString()},
            statusCode: 502,
          );
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
      final minimumDataQuality = int.tryParse(request.url.queryParameters['minimumDataQuality'] ?? '') ?? 60;
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
          100000;

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
          60;
      final simulations = int.tryParse(
            request.url.queryParameters['simulations'] ?? '',
          ) ??
          100000;

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
        return jsonResponse(_jsonSafe(job));
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



  Future<List<Map<String, Object?>>> _preparedFootballAnalyses({
    required DateTime date,
    int minimumDataQuality = 60,
  }) async {
    final db = await database.connection();
    final safeQuality = minimumDataQuality.clamp(0, 100);
    final day = _day(date);

    // Vor der Ausgabe werden Status, Endstand und Logos einmal beim
    // Datenanbieter aktualisiert. Dadurch bleiben beendete Spiele nicht
    // fälschlich als LIVE 0:0 in der App stehen.
    try {
      final freshMatches = await football.matchesForDate(date);
      for (final match in freshMatches) {
        final fixtureId = match['id']?.toString() ?? '';
        if (fixtureId.isEmpty) continue;
        await database.upsertFootballMatchFromPayload(
          fixtureId: fixtureId,
          payload: match,
        );
      }
    } catch (_) {
      // Bei einem temporären Providerfehler bleiben die zuletzt gespeicherten
      // Daten verfügbar; die Analyse-API fällt nicht komplett aus.
    }

    final result = await db.execute(
      Sql.named(r'''
        WITH latest_job AS (
          SELECT phase_two_scan_run_id
          FROM football_daily_pipeline_jobs
          WHERE scan_date = CAST(@day AS DATE)
            AND status = 'completed'
            AND phase_two_scan_run_id IS NOT NULL
          ORDER BY id DESC
          LIMIT 1
        )
        SELECT DISTINCT ON (a.match_id)
          m.id,
          m.kickoff_utc,
          m.status,
          m.league_id,
          m.league_name,
          m.country,
          m.home_team_id,
          m.home_team_name,
          m.home_logo,
          m.away_team_id,
          m.away_team_name,
          m.away_logo,
          m.home_goals,
          m.away_goals,
          m.raw_json,
          a.model_version,
          a.data_quality,
          a.confidence,
          a.recommendation,
          a.payload AS analysis_payload,
          a.analyzed_at
        FROM latest_job j
        INNER JOIN football_phase_two_results p
          ON p.scan_run_id = j.phase_two_scan_run_id
         AND p.analysis_allowed = TRUE
        INNER JOIN analyses a
          ON a.match_id = p.fixture_id
         AND a.sport = 'football'
        INNER JOIN football_matches m
          ON m.id = a.match_id
        WHERE a.data_quality >= @minimum_quality
          AND a.payload IS NOT NULL
        ORDER BY a.match_id, a.analyzed_at DESC
      '''),
      parameters: {
        'day': day,
        'minimum_quality': safeQuality,
      },
    );

    return result.map((row) {
      final values = Map<String, Object?>.from(row.toColumnMap());

      Map<String, Object?> mapValue(Object? value) {
        if (value is Map) {
          return Map<String, Object?>.from(value);
        }
        return <String, Object?>{};
      }

      final rawMatch = mapValue(values.remove('raw_json'));
      final analysis = mapValue(values.remove('analysis_payload'));

      return <String, Object?>{
        ...rawMatch,
        'id': values['id']?.toString() ?? '',
        'kickoff': values['kickoff_utc']?.toString() ?? '',
        'status': values['status']?.toString() ?? '',
        'leagueId': values['league_id']?.toString() ?? '',
        'league': values['league_name']?.toString() ?? '',
        'country': values['country']?.toString() ?? '',
        'homeTeamId': values['home_team_id']?.toString() ?? '',
        'homeTeam': values['home_team_name']?.toString() ?? '',
        'homeLogo': values['home_logo']?.toString() ?? '',
        'awayTeamId': values['away_team_id']?.toString() ?? '',
        'awayTeam': values['away_team_name']?.toString() ?? '',
        'awayLogo': values['away_logo']?.toString() ?? '',
        'homeGoals': values['home_goals'],
        'awayGoals': values['away_goals'],
        'analysis': {
          ...analysis,
          'modelVersion': values['model_version']?.toString() ?? '',
          'dataQuality': values['data_quality'],
          'confidence': values['confidence'],
          'recommendation': values['recommendation'],
          'analyzedAt': values['analyzed_at']?.toString() ?? '',
        },
      };
    }).where((row) => (row['id']?.toString() ?? '').isNotEmpty).toList();
  }

  Object? _jsonSafe(Object? value) {
    if (value == null ||
        value is String ||
        value is num ||
        value is bool) {
      return value;
    }

    if (value is DateTime) {
      return value.toUtc().toIso8601String();
    }

    if (value is Map) {
      return value.map(
        (key, item) => MapEntry(key.toString(), _jsonSafe(item)),
      );
    }

    if (value is Iterable) {
      return value.map(_jsonSafe).toList();
    }

    return value.toString();
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
