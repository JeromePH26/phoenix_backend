import 'dart:async';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../config/app_config.dart';
import '../database/database.dart';
import '../http/json_response.dart';
import '../services/football_phase_one_scan_service.dart';
import '../services/football_phase_two_scan_service.dart';
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

    router.get(
      '/api/tips/today',
      (Request request) => jsonResponse({
        'date': _day(DateTime.now()),
        'football': null,
        'tennis': null,
        'status': 'Noch keine serverseitige Vollanalyse ausgeführt.',
      }),
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
