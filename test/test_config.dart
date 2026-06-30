import '../lib/src/config.dart';

AppConfig testConfig() => AppConfig(
      port: 0,
      env: 'test',
      databasePath: ':memory:',
      googleWebClientId: 'test-client-id',
      accessTokenTtlDays: 1,
      refreshTokenTtlDays: 7,
      corsAllowedOrigins: ['*'],
      rateLimitMaxRequests: 1000,
      rateLimitWindowSeconds: 60,
      authRateLimitMaxRequests: 1000,
      authRateLimitWindowSeconds: 60,
      adminSecret: 'test-admin-secret',
    );
