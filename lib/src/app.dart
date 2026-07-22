import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_cors_headers/shelf_cors_headers.dart';

import 'api/routes.dart';
import 'config/app_config.dart';
import 'database/database.dart';
import 'http/json_response.dart';
import 'http/phoenix_api_guard.dart';
import 'http/tennis_analysis_api.dart';
import 'services/football_service.dart';
import 'services/tennis_service.dart';

class PhoenixBackend {
  PhoenixBackend._({
    required this.config,
    required this.database,
    required this.handler,
    required this.football,
    required this.tennis,
  });

  final AppConfig config;
  final PhoenixDatabase database;
  final Handler handler;
  final FootballService football;
  final TennisService tennis;

  static Future<PhoenixBackend> create() async {
    final config = AppConfig.fromEnvironment();
    final database = PhoenixDatabase(config.databaseUrl);
    final football = FootballService(apiKey: config.apiFootballKey);
    final tennis = TennisService(
      apiKey: config.sportradarTennisApiKey,
      accessLevel: config.sportradarAccessLevel,
      language: config.sportradarLanguage,
    );

    if (database.isConfigured) {
      try {
        await database.migrate();
      } catch (error, stackTrace) {
        stderr.writeln('Database migration failed: $error');
        stderr.writeln(stackTrace);
      }
    }

    final routes = ApiRoutes(
      config: config,
      database: database,
      football: football,
      tennis: tennis,
    );

    final apiGuard = PhoenixApiGuard(
      database: database,
      football: football,
      tennis: tennis,
    );

    final tennisAnalysisApi = TennisAnalysisApi(tennis: tennis);

    final pipeline = Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(corsHeaders())
        .addMiddleware(_errorMiddleware())
        // Muss vor ApiRoutes liegen, weil ApiRoutes sonst mit seiner
        // Catch-all-Route zuerst 404 zurückgibt.
        .addMiddleware(tennisAnalysisApi.middleware)
        .addMiddleware(apiGuard.middleware)
        .addHandler(routes.router.call);

    return PhoenixBackend._(
      config: config,
      database: database,
      handler: pipeline,
      football: football,
      tennis: tennis,
    );
  }

  Future<HttpServer> serve() => shelf_io.serve(
        handler,
        InternetAddress.anyIPv4,
        config.port,
        shared: true,
      );

  Future<void> close() async {
    football.close();
    tennis.close();
    await database.close();
  }
}

Middleware _errorMiddleware() => (Handler inner) => (Request request) async {
      try {
        return await inner(request);
      } catch (error, stackTrace) {
        stderr.writeln('Unhandled request error: $error');
        stderr.writeln(stackTrace);
        return jsonResponse(
          {'error': 'Interner Serverfehler.'},
          statusCode: 500,
        );
      }
    };
