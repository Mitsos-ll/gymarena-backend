import 'dart:io';

class AppConfig {
  AppConfig({
    required this.port,
    required this.env,
    required this.databasePath,
    required this.googleWebClientId,
    required this.accessTokenTtlDays,
    required this.refreshTokenTtlDays,
    required this.corsAllowedOrigins,
    required this.rateLimitMaxRequests,
    required this.rateLimitWindowSeconds,
    required this.authRateLimitMaxRequests,
    required this.authRateLimitWindowSeconds,
    required this.adminSecret,
    required this.resendApiKey,
    required this.resendFromEmail,
    required this.workoutXApiKey,
    required this.workoutXBaseUrl,
  });

  final int port;
  final String env;          // 'development' | 'production'
  final String databasePath;
  final String googleWebClientId;
  final int accessTokenTtlDays;
  final int refreshTokenTtlDays;
  final List<String> corsAllowedOrigins;
  final int rateLimitMaxRequests;
  final int rateLimitWindowSeconds;
  final int authRateLimitMaxRequests;
  final int authRateLimitWindowSeconds;
  final String adminSecret;
  final String resendApiKey;
  final String resendFromEmail;
  final String workoutXApiKey;
  final String workoutXBaseUrl;

  bool get isProduction => env == 'production';

  factory AppConfig.fromEnvironment() {
    // Charger .env si présent (dev) — Platform.environment prime toujours
    final envMap = <String, String>{..._loadDotEnv('.env')};
    envMap.addAll(Platform.environment); // platform écrase .env

    String require(String key) {
      final v = envMap[key]?.trim() ?? '';
      if (v.isEmpty) throw StateError('Missing required env variable: $key');
      return v;
    }

    String get(String key, String defaultValue) =>
        envMap[key]?.trim().isNotEmpty == true ? envMap[key]!.trim() : defaultValue;

    int getInt(String key, int defaultValue) =>
        int.tryParse(envMap[key]?.trim() ?? '') ?? defaultValue;

    final rawOrigins = get('CORS_ALLOWED_ORIGINS', '*');
    final corsOrigins = rawOrigins.split(',').map((s) => s.trim()).toList();
    final env = get('ENV', 'development');

    // '*' est acceptable en dev mais jamais censé atteindre la prod
    // silencieusement — sans ce garde-fou, un déploiement qui oublie de
    // positionner CORS_ALLOWED_ORIGINS tourne indéfiniment avec CORS
    // grand ouvert sans que personne ne s'en aperçoive.
    if (env == 'production' && corsOrigins.contains('*')) {
      throw StateError(
        'CORS_ALLOWED_ORIGINS must not be "*" in production. '
        'Set it explicitly (comma-separated allowed origins).',
      );
    }

    return AppConfig(
      port: getInt('PORT', 3000),
      env: env,
      databasePath: get('DATABASE_PATH', 'data/gymtrack.db'),
      googleWebClientId: require('GOOGLE_WEB_CLIENT_ID'),
      accessTokenTtlDays: getInt('ACCESS_TOKEN_TTL_DAYS', 30),
      refreshTokenTtlDays: getInt('REFRESH_TOKEN_TTL_DAYS', 90),
      corsAllowedOrigins: corsOrigins,
      rateLimitMaxRequests: getInt('RATE_LIMIT_MAX_REQUESTS', 60),
      rateLimitWindowSeconds: getInt('RATE_LIMIT_WINDOW_SECONDS', 60),
      authRateLimitMaxRequests: getInt('AUTH_RATE_LIMIT_MAX_REQUESTS', 10),
      authRateLimitWindowSeconds: getInt('AUTH_RATE_LIMIT_WINDOW_SECONDS', 60),
      adminSecret: require('ADMIN_SECRET'),
      resendApiKey: get('RESEND_API_KEY', ''),
      resendFromEmail: get('RESEND_FROM_EMAIL', 'onboarding@resend.dev'),
      workoutXApiKey: get('WORKOUTX_API_KEY', ''),
      workoutXBaseUrl: get('WORKOUTX_BASE_URL', 'https://api.workoutxapp.com/v1'),
    );
  }
}

/// Lit un fichier .env basique (KEY=VALUE, commentaires #, guillemets optionnels).
/// N'écrase jamais Platform.environment — appelant doit merger dans l'ordre voulu.
Map<String, String> _loadDotEnv(String path) {
  final file = File(path);
  if (!file.existsSync()) return {};

  final result = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final idx = trimmed.indexOf('=');
    if (idx <= 0) continue;
    final key = trimmed.substring(0, idx).trim();
    var value = trimmed.substring(idx + 1).trim();
    // Enlever guillemets simples ou doubles
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    result[key] = value;
  }
  return result;
}
