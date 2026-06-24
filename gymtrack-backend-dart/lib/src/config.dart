import 'dart:io';

class AppConfig {
  AppConfig({
    required this.port,
    required this.databasePath,
    required this.googleWebClientId,
    required this.accessTokenTtlDays,
    required this.refreshTokenTtlDays,
  });

  final int port;
  final String databasePath;
  final String googleWebClientId;
  final int accessTokenTtlDays;
  final int refreshTokenTtlDays;

  factory AppConfig.fromEnvironment() {
    final googleWebClientId =
        Platform.environment['GOOGLE_WEB_CLIENT_ID']?.trim() ?? '';
    if (googleWebClientId.isEmpty) {
      throw StateError(
        'Missing GOOGLE_WEB_CLIENT_ID environment variable.',
      );
    }

    return AppConfig(
      port: int.tryParse(Platform.environment['PORT'] ?? '') ?? 3000,
      databasePath:
          Platform.environment['DATABASE_PATH'] ?? 'data/gymtrack.db',
      googleWebClientId: googleWebClientId,
      accessTokenTtlDays:
          int.tryParse(Platform.environment['ACCESS_TOKEN_TTL_DAYS'] ?? '') ?? 30,
      refreshTokenTtlDays:
          int.tryParse(Platform.environment['REFRESH_TOKEN_TTL_DAYS'] ?? '') ?? 90,
    );
  }
}
