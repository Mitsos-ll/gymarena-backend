import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'config.dart';
import 'db/app_database.dart';
import 'middleware/cors_middleware.dart';
import 'middleware/rate_limit_middleware.dart';
import 'middleware/request_id_middleware.dart';
import 'repositories/user_repository.dart';
import 'routes/admin_routes.dart';
import 'routes/auth_routes.dart';
import 'routes/me_routes.dart';
import 'services/google_token_service.dart';
import 'services/session_service.dart';
import 'utils/http_json.dart';
import 'utils/logger.dart';

class GymTrackBackend {
  GymTrackBackend(this.config)
      : database = AppDatabase.open(config.databasePath),
        sessionService = SessionService(
          accessTokenTtlDays: config.accessTokenTtlDays,
          refreshTokenTtlDays: config.refreshTokenTtlDays,
        ),
        googleTokenService = GoogleTokenService(
          webClientId: config.googleWebClientId,
        ),
        _globalLimiter = RateLimiter(
          maxRequests: config.rateLimitMaxRequests,
          windowDuration: Duration(seconds: config.rateLimitWindowSeconds),
        ),
        _authLimiter = RateLimiter(
          maxRequests: config.authRateLimitMaxRequests,
          windowDuration: Duration(seconds: config.authRateLimitWindowSeconds),
        ) {
    userRepository = UserRepository(
      database: database,
      sessionService: sessionService,
    );
    authRoutes = AuthRoutes(
      googleTokenService: googleTokenService,
      userRepository: userRepository,
      authLimiter: _authLimiter,
    );
    meRoutes = MeRoutes(userRepository: userRepository);
    adminRoutes = AdminRoutes(database: database, adminSecret: config.adminSecret);
  }

  final AppConfig config;
  final AppDatabase database;
  final SessionService sessionService;
  final GoogleTokenService googleTokenService;
  final RateLimiter _globalLimiter;
  final RateLimiter _authLimiter;
  late final UserRepository userRepository;
  late final AuthRoutes authRoutes;
  late final MeRoutes meRoutes;
  late final AdminRoutes adminRoutes;

  Handler get handler {
    final router = Router();

    router.get('/health', _healthHandler);
    router.get('/admin/stats', adminRoutes.statsHandler);

    router.post('/auth/google', authRoutes.signInGoogle);
    router.post('/auth/register', authRoutes.register);
    router.post('/auth/login', authRoutes.login);
    router.post('/auth/refresh', authRoutes.refresh);
    router.post('/auth/logout', authRoutes.logout);

    router.get('/me', meRoutes.getMe);
    router.put('/me/profile', meRoutes.upsertProfile);

    return const Pipeline()
        .addMiddleware(requestIdMiddleware())
        .addMiddleware(corsMiddleware(config.corsAllowedOrigins))
        .addMiddleware(_globalLimiter.asMiddleware())
        .addMiddleware(_structuredLoggerMiddleware())
        .addMiddleware(_errorCatcherMiddleware())
        .addHandler(router.call);
  }

  Response _healthHandler(Request request) {
    return jsonResponse({
      'ok': true,
      'service': 'gymtrack-backend',
      'version': '0.2.0',
      'env': config.env,
      'time': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> close() async {
    googleTokenService.close();
    database.close();
  }
}

// ── Middleware de logging structuré ──────────────────────────────────────────

Middleware _structuredLoggerMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      final start = DateTime.now();
      final rid = requestId(request);

      final response = await inner(request);

      final ms = DateTime.now().difference(start).inMilliseconds;
      final status = response.statusCode;
      final lvl = status >= 500
          ? Level.SEVERE
          : status >= 400
              ? Level.WARNING
              : Level.INFO;

      log.log(
        lvl,
        '${request.method} ${request.requestedUri.path} $status ${ms}ms',
        <String, dynamic>{
          'req_id': rid,
          'method': request.method,
          'path': request.requestedUri.path,
          'status': status,
          'ms': ms,
        },
      );

      return response;
    };
  };
}

// ── Middleware global catch-all ───────────────────────────────────────────────

Middleware _errorCatcherMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      try {
        return await inner(request);
      } catch (e, stack) {
        logError('Uncaught exception', e, stack, requestId: requestId(request));
        return Response.internalServerError(
          body: jsonEncode({'message': 'Internal server error.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    };
  };
}
