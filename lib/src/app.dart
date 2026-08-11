import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_cors_headers/shelf_cors_headers.dart';

import 'api/routes.dart';
import 'config/app_config.dart';
import 'database/database.dart';
import 'http/football_analysis_api.dart';
import 'http/json_response.dart';
import 'http/phoenix_api_guard.dart';
import 'http/tennis_analysis_api.dart';
import 'services/football_service.dart';
import 'services/baseball_service.dart';
import 'services/api_sports_team_engine.dart';
import 'services/firebase_push_service.dart';
import 'services/football_favorite_live_monitor.dart';
import 'services/football_news_service.dart';
import 'services/tennis_service.dart';

class PhoenixBackend {
  PhoenixBackend._({
    required this.config,
    required this.database,
    required this.handler,
    required this.football,
    required this.baseball,
    required this.teamSports,
    required this.tennis,
    required this.favoriteLiveMonitor,
    required this.news,
  });

  final AppConfig config;
  final PhoenixDatabase database;
  final Handler handler;
  final FootballService football;
  final BaseballService baseball;
  final Map<String, ApiSportsTeamEngine> teamSports;
  final TennisService tennis;
  final FootballFavoriteLiveMonitor favoriteLiveMonitor;
  final FootballNewsService news;

  static Future<PhoenixBackend> create() async {
    final config = AppConfig.fromEnvironment();
    final database = PhoenixDatabase(config.databaseUrl);
    final football = FootballService(apiKey: config.apiFootballKey);
    final baseball = BaseballService(
      apiKey: config.apiBaseballKey,
      database: database,
    );
    final teamSports = <String, ApiSportsTeamEngine>{
      'afl': ApiSportsTeamEngine(
        sport: 'AFL',
        baseUrl: 'https://v1.afl.api-sports.io',
        apiKey: config.apiSportsKeyFor('AFL'),
        database: database,
      ),
      'basketball': ApiSportsTeamEngine(
        sport: 'Basketball',
        baseUrl: 'https://v1.basketball.api-sports.io',
        apiKey: config.apiSportsKeyFor('BASKETBALL'),
        database: database,
      ),
      'handball': ApiSportsTeamEngine(
        sport: 'Handball',
        baseUrl: 'https://v1.handball.api-sports.io',
        apiKey: config.apiSportsKeyFor('HANDBALL'),
        database: database,
      ),
      'hockey': ApiSportsTeamEngine(
        sport: 'Hockey',
        baseUrl: 'https://v1.hockey.api-sports.io',
        apiKey: config.apiSportsKeyFor('HOCKEY'),
        database: database,
      ),
      'nba': ApiSportsTeamEngine(
        sport: 'NBA',
        baseUrl: 'https://v2.nba.api-sports.io',
        apiKey: config.apiSportsKeyFor('NBA'),
        database: database,
      ),
      'nfl': ApiSportsTeamEngine(
        sport: 'NFL',
        baseUrl: 'https://v1.american-football.api-sports.io',
        apiKey: config.apiSportsKeyFor('NFL'),
        database: database,
      ),
      'rugby': ApiSportsTeamEngine(
        sport: 'Rugby',
        baseUrl: 'https://v1.rugby.api-sports.io',
        apiKey: config.apiSportsKeyFor('RUGBY'),
        database: database,
      ),
      'volleyball': ApiSportsTeamEngine(
        sport: 'Volleyball',
        baseUrl: 'https://v1.volleyball.api-sports.io',
        apiKey: config.apiSportsKeyFor('VOLLEYBALL'),
        database: database,
      ),
    };
    final tennis = TennisService(
      apiKey: config.sportradarTennisApiKey,
      accessLevel: config.sportradarAccessLevel,
      language: config.sportradarLanguage,
    );
    final push = FirebasePushService(
      projectId: config.firebaseProjectId,
      serviceAccountJson: config.firebaseServiceAccountJson,
    );
    final favoriteLiveMonitor = FootballFavoriteLiveMonitor(
      database: database,
      football: football,
      push: push,
    );
    final news = FootballNewsService(database: database, push: push);

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
      baseball: baseball,
      teamSports: teamSports,
      tennis: tennis,
      news: news,
    );

    final apiGuard = PhoenixApiGuard(
      database: database,
      football: football,
      tennis: tennis,
    );

    final tennisAnalysisApi = TennisAnalysisApi(tennis: tennis);
    final footballAnalysisApi = FootballAnalysisApi(database: database);

    final pipeline = Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(corsHeaders())
        .addMiddleware(_errorMiddleware())
        // Muss vor ApiRoutes liegen, weil ApiRoutes sonst mit seiner
        // Catch-all-Route zuerst 404 zurückgibt.
        .addMiddleware(tennisAnalysisApi.middleware)
        .addMiddleware(apiGuard.middleware)
        // Liefert vorbereitete Football-Analysen aus PostgreSQL. Vor der
        // Auslieferung aktualisiert _preparedFootballAnalyses() in routes.dart
        // kurz Status/Endstand/Logos beim Datenanbieter (ein Aufruf für alle
        // Spiele des Tages), damit beendete Partien nicht als LIVE 0:0
        // stehen bleiben. Die eigentliche Analyse (Simulation, Value,
        // Empfehlung) kommt weiterhin ausschließlich aus der Datenbank.
        .addMiddleware(footballAnalysisApi.middleware)
        .addHandler(routes.router.call);

    if (config.hasFirebasePush && database.isConfigured) {
      favoriteLiveMonitor.start();
    }
    if (database.isConfigured) news.start();

    return PhoenixBackend._(
      config: config,
      database: database,
      handler: pipeline,
      football: football,
      baseball: baseball,
      teamSports: teamSports,
      tennis: tennis,
      favoriteLiveMonitor: favoriteLiveMonitor,
      news: news,
    );
  }

  Future<HttpServer> serve() => shelf_io.serve(
        handler,
        InternetAddress.anyIPv4,
        config.port,
        shared: true,
      );

  Future<void> close() async {
    favoriteLiveMonitor.close();
    news.close();
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
