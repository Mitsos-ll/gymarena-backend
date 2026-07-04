import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
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
import 'routes/coach_routes.dart';
import 'routes/invite_routes.dart';
import 'routes/me_routes.dart';
import 'routes/sync_routes.dart';
import 'services/email_service.dart';
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
        emailService = EmailService(
          apiKey: config.resendApiKey,
          fromEmail: config.resendFromEmail,
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
      emailService: emailService,
    );
    meRoutes = MeRoutes(userRepository: userRepository);
    adminRoutes = AdminRoutes(database: database, adminSecret: config.adminSecret);
    coachRoutes = CoachRoutes(
      userRepository: userRepository,
      database: database,
      photosDir: p.join(p.dirname(config.databasePath), 'coach_photos'),
    );
    inviteRoutes = InviteRoutes(userRepository: userRepository, database: database);
    syncRoutes = SyncRoutes(userRepository: userRepository, database: database);
  }

  final AppConfig config;
  final AppDatabase database;
  final SessionService sessionService;
  final GoogleTokenService googleTokenService;
  final EmailService emailService;
  final RateLimiter _globalLimiter;
  final RateLimiter _authLimiter;
  late final UserRepository userRepository;
  late final AuthRoutes authRoutes;
  late final MeRoutes meRoutes;
  late final AdminRoutes adminRoutes;
  late final CoachRoutes coachRoutes;
  late final InviteRoutes inviteRoutes;
  late final SyncRoutes syncRoutes;

  Handler get handler {
    final router = Router();

    router.get('/health', _healthHandler);
    router.get('/admin/stats', adminRoutes.statsHandler);

    router.post('/auth/google', authRoutes.signInGoogle);
    router.post('/auth/register', authRoutes.register);
    router.post('/auth/login', authRoutes.login);
    router.post('/auth/refresh', authRoutes.refresh);
    router.post('/auth/logout', authRoutes.logout);
    router.post('/auth/forgot-password', authRoutes.forgotPassword);
    router.post('/auth/reset-password', authRoutes.resetPassword);

    router.get('/me', meRoutes.getMe);
    router.put('/me/profile', meRoutes.upsertProfile);
    router.put('/me/fitness-goal', meRoutes.updateFitnessGoal);

    // ── Admin ──────────────────────────────────────────────────────────────
    router.put('/admin/users/<userId>/set-coach', adminRoutes.setCoach);
    router.get('/admin/users/<userId>/workouts', adminRoutes.listUserWorkouts);
    router.delete('/admin/users/<userId>/workouts/<workoutId>', adminRoutes.deleteUserWorkout);
    router.delete('/admin/users/<userId>/workouts', adminRoutes.deleteAllUserWorkouts);
    router.get('/admin/users/<userId>/programs', adminRoutes.listUserPrograms);
    router.delete('/admin/users/<userId>/programs', adminRoutes.deleteAllUserPrograms);
    router.delete('/admin/users/<userId>/exercises', adminRoutes.deleteAllUserExercises);
    router.get('/admin/users/<userId>/debug-sync', adminRoutes.debugUserSync);
    router.get('/admin/debug-users', adminRoutes.debugListUsers);
    router.get('/admin/debug-workouts/<workoutId>', adminRoutes.debugWorkoutDetail);
    router.get('/admin/users/<userId>/debug-name', adminRoutes.debugDisplayName);

    // ── Coach ──────────────────────────────────────────────────────────────
    router.post('/coach/invite-codes', coachRoutes.generateInviteCode);
    router.post('/coach/invite-codes/redeem', coachRoutes.redeemCode);
    router.get('/coach/athletes', coachRoutes.getAthletes);
    router.delete('/coach/athletes/<athleteUserId>', coachRoutes.removeAthlete);
    router.get('/coach/athletes/<athleteUserId>/detail', coachRoutes.getAthleteDetail);
    router.put('/coach/athletes/<athleteUserId>/workouts/<workoutId>/note', coachRoutes.saveNote);
    router.put('/coach/athletes/<athleteUserId>/program', coachRoutes.assignProgram);
    router.delete('/coach/athletes/<athleteUserId>/program', coachRoutes.removeProgram);
    router.put('/coach/public-profile', coachRoutes.upsertPublicProfile);
    router.get('/coach/public-profile', coachRoutes.getMyPublicProfile);
    router.put('/coach/public-profile/photo', coachRoutes.uploadProfilePhoto);
    router.get('/coach-photos/<filename>', coachRoutes.servePhoto);
    router.get('/coaches/public', coachRoutes.getPublicCoaches);
    router.get('/athlete/coach', coachRoutes.getMyCoach);
    router.get('/athlete/assigned-program', coachRoutes.getAssignedProgram);
    router.delete('/athlete/coach', coachRoutes.revokeCoach);
    router.post('/coach/<coachUserId>/invite-requests', coachRoutes.requestInvite);
    router.get('/coach/invite-requests', coachRoutes.getInviteRequests);
    router.post('/coach/invite-requests/<requestId>/approve', coachRoutes.approveInviteRequest);
    router.post('/coach/invite-requests/<requestId>/decline', coachRoutes.declineInviteRequest);

    // ── Invitations d'amis (lien / QR) ────────────────────────────────────────
    router.post('/invites', inviteRoutes.generateInviteCode);
    router.get('/invites/<code>', inviteRoutes.getInviteInfo);
    router.post('/invites/<code>/redeem', inviteRoutes.redeemInviteCode);
    router.get('/invite/<code>', inviteRoutes.landingPage);

    // ── Universal Links / App Links (à compléter avec les vraies valeurs
    // Apple Team ID / bundle ID et empreinte SHA-256 du certificat Android
    // avant de publier — voir commentaires dans _wellKnownHandler) ───────────
    router.get('/.well-known/apple-app-site-association', _appleAppSiteAssociationHandler);
    router.get('/.well-known/assetlinks.json', _assetLinksHandler);

    // ── Sync ───────────────────────────────────────────────────────────────
    router.get('/me/snapshot', syncRoutes.getSnapshot);
    router.post('/workouts/batch', syncRoutes.pushWorkoutBatch);
    router.post('/workouts', syncRoutes.pushWorkout);
    router.delete('/workouts/<workoutId>', syncRoutes.deleteWorkout);
    router.post('/programs/batch', syncRoutes.pushProgramBatch);
    router.post('/programs', syncRoutes.pushProgram);
    router.delete('/programs/<programId>', syncRoutes.deleteProgram);
    router.post('/session-templates/batch', syncRoutes.pushSessionTemplateBatch);
    router.delete('/session-templates/<localId>', syncRoutes.deleteSessionTemplate);
    router.post('/exercises/batch', syncRoutes.pushExerciseBatch);
    router.post('/exercises', syncRoutes.pushExercise);
    router.post('/weight-history/batch', syncRoutes.pushWeightBatch);
    router.post('/body-measurements/batch', syncRoutes.pushMeasurementBatch);
    router.put('/me/gamification', syncRoutes.pushGamification);
    router.put('/me/community-profile', syncRoutes.pushCommunityProfile);
    router.post('/community/shares/workout', syncRoutes.pushWorkoutShare);
    router.delete('/community/shares/workout/<shareId>', syncRoutes.deleteWorkoutShare);
    router.post('/community/shares/program', syncRoutes.pushProgramShare);
    router.delete('/community/shares/program/<shareId>', syncRoutes.deleteProgramShare);
    router.post('/community/relations', syncRoutes.pushRelation);
    router.patch('/community/relations/<relationId>', syncRoutes.patchRelation);
    router.delete('/community/relations/<relationId>', syncRoutes.deleteRelation);
    router.get('/community/relations', syncRoutes.getRelations);
    router.get('/community/friends/shares', syncRoutes.getFriendsShares);
    router.get('/community/friends/<friendUserId>/exercise-stats', syncRoutes.getFriendExerciseStats);

    return const Pipeline()
        .addMiddleware(requestIdMiddleware())
        .addMiddleware(corsMiddleware(config.corsAllowedOrigins))
        .addMiddleware(_globalLimiter.asMiddleware())
        .addMiddleware(_structuredLoggerMiddleware())
        .addMiddleware(_errorCatcherMiddleware())
        .addHandler(router.call);
  }

  // Valeurs à renseigner avant activation des Universal Links / App Links :
  // - iOS : remplacer TEAMID.com.gymtrack.app par "<Apple Team ID>.<bundle id>"
  // - Android : remplacer le package et ajouter l'empreinte SHA-256 du
  //   certificat de signature (obtenue via `keytool -list -v`)
  Response _appleAppSiteAssociationHandler(Request request) {
    return jsonResponse({
      'applinks': {
        'apps': [],
        'details': [
          {
            'appID': 'TEAMID.com.gymtrack.app',
            'paths': ['/invite/*'],
          },
        ],
      },
    });
  }

  Response _assetLinksHandler(Request request) {
    return jsonResponse([
      {
        'relation': ['delegate_permission/common.handle_all_urls'],
        'target': {
          'namespace': 'android_app',
          'package_name': 'com.gymtrack.app',
          'sha256_cert_fingerprints': <String>[],
        },
      },
    ]);
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
