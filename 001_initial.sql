import 'dart:io';

class AppConfig {
  const AppConfig({
    required this.port,
    required this.environment,
    required this.databaseUrl,
    required this.apiFootballKey,
    required this.sportradarTennisApiKey,
    required this.sportradarAccessLevel,
    required this.sportradarLanguage,
    required this.adminToken,
  });

  final int port;
  final String environment;
  final String databaseUrl;
  final String apiFootballKey;
  final String sportradarTennisApiKey;
  final String sportradarAccessLevel;
  final String sportradarLanguage;
  final String adminToken;

  bool get hasDatabase => databaseUrl.trim().isNotEmpty;
  bool get hasFootballApi => apiFootballKey.trim().isNotEmpty;
  bool get hasTennisApi => sportradarTennisApiKey.trim().isNotEmpty;

  factory AppConfig.fromEnvironment() {
    String read(String key, [String fallback = '']) =>
        Platform.environment[key]?.trim() ?? fallback;

    return AppConfig(
      port: int.tryParse(read('PORT', '8080')) ?? 8080,
      environment: read('APP_ENV', 'production'),
      databaseUrl: read('DATABASE_URL'),
      apiFootballKey: read('API_FOOTBALL_KEY'),
      sportradarTennisApiKey: read('SPORTRADAR_TENNIS_API_KEY'),
      sportradarAccessLevel:
          read('SPORTRADAR_TENNIS_ACCESS_LEVEL', 'trial'),
      sportradarLanguage: read('SPORTRADAR_TENNIS_LANGUAGE', 'de'),
      adminToken: read('PHOENIX_ADMIN_TOKEN'),
    );
  }
}
