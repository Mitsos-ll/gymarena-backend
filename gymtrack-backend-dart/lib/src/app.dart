import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'config.dart';
import 'db/app_database.dart';
import 'repositories/user_repository.dart';
import 'routes/auth_routes.dart';
import 'routes/me_routes.dart';
import 'services/google_token_service.dart';
import 'services/session_service.dart';
import 'utils/http_json.dart';

class GymTrackBackend {
  GymTrackBackend(this.config)
      : database = AppDatabase.open(config.databasePath),
        sessionService = SessionService(
          accessTokenTtlDays: config.accessTokenTtlDays,
          refreshTokenTtlDays: config.refreshTokenTtlDays,
        ),
        googleTokenService = GoogleTokenService(
          webClientId: config.googleWebClientId,
        ) {
    userRepository = UserRepository(
      database: database,
      sessionService: sessionService,
    );
    authRoutes = AuthRoutes(
      googleTokenService: googleTokenService,
      userRepository: userRepository,
    );
    meRoutes = MeRoutes(userRepository: userRepository);
  }

  final AppConfig config;
  final AppDatabase database;
  final SessionService sessionService;
  final GoogleTokenService googleTokenService;
  late final UserRepository userRepository;
  late final AuthRoutes authRoutes;
  late final MeRoutes meRoutes;

  Handler get handler {
    final router = Router();

    router.get('/health', (Request request) {
      return jsonResponse({
        'ok': true,
        'service': 'gymtrack-backend',
        'time': DateTime.now().toUtc().toIso8601String(),
      });
    });

    router.post('/auth/google', authRoutes.signInGoogle);
    router.post('/auth/register', authRoutes.register);
    router.post('/auth/login', authRoutes.login);
    router.post('/auth/refresh', authRoutes.refresh);
    router.post('/auth/logout', authRoutes.logout);
    router.get('/me', meRoutes.getMe);
    router.put('/me/profile', meRoutes.upsertProfile);

    return const Pipeline()
        .addMiddleware(logRequests())
        .addHandler(router.call);
  }

  Future<void> close() async {
    googleTokenService.close();
    database.close();
  }
}
