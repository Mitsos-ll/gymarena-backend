import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'config.dart';
import 'db/app_database.dart';
import 'middleware/cors_middleware.dart';
import 'middleware/rate_limit_middleware.dart';
import 'middleware/request_id_middleware.dart';
import 'repositories/exercise_catalog_repository.dart';
import 'repositories/moderation_repository.dart';
import 'repositories/user_repository.dart';
import 'routes/admin_routes.dart';
import 'routes/auth_routes.dart';
import 'routes/coach_routes.dart';
import 'routes/exercise_catalog_routes.dart';
import 'routes/invite_routes.dart';
import 'routes/me_routes.dart';
import 'routes/moderation_routes.dart';
import 'routes/push_routes.dart';
import 'routes/sync_routes.dart';
import 'services/apple_rest_service.dart';
import 'services/apple_token_service.dart';
import 'services/email_service.dart';
import 'services/gif_cache_service.dart';
import 'services/google_token_service.dart';
import 'services/push_service.dart';
import 'services/session_service.dart';
import 'services/workoutx_service.dart';
import 'utils/http_json.dart';
import 'utils/logger.dart';

class GymTrackBackend {
  /// [appleTokenService] n'est à fournir que par les tests (faux jeu de clés
  /// Apple) ; en exécution normale il est construit depuis [config].
  GymTrackBackend(
    this.config, {
    AppleTokenService? appleTokenService,
    AppleRestService? appleRestService,
    EmailService? emailService,
    PushSender? pushSender,
  })
      : database = AppDatabase.open(config.databasePath),
        sessionService = SessionService(
          accessTokenTtlDays: config.accessTokenTtlDays,
          refreshTokenTtlDays: config.refreshTokenTtlDays,
        ),
        googleTokenService = GoogleTokenService(
          webClientId: config.googleWebClientId,
        ),
        appleTokenService = appleTokenService ??
            AppleTokenService(bundleId: config.appleBundleId),
        appleRestService = appleRestService ??
            AppleRestService(
              clientId: config.appleBundleId,
              teamId: config.appleTeamId,
              keyId: config.appleKeyId,
              privateKey: config.applePrivateKey,
            ),
        emailService = emailService ??
            EmailService(
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
        ),
        // Rate-limit dédié pour /admin/* — plus strict que le global, distinct
        // de l'auth. Les endpoints admin protègent des opérations à fort
        // impact (dump de données, suppression de masse) derrière un unique
        // secret statique ; un rate-limit spécifique ralentit toute tentative
        // de force brute sur ce secret indépendamment du trafic global.
        _adminLimiter = RateLimiter(
          maxRequests: 20,
          windowDuration: const Duration(seconds: 60),
        ) {
    userRepository = UserRepository(
      database: database,
      sessionService: sessionService,
    );
    moderationRepository = ModerationRepository(database: database);
    pushNotifier = PushNotifier(
      database: database,
      sender: pushSender ?? FcmPushSender.fromServiceAccount(config.firebaseServiceAccount),
    );
    pushRoutes = PushRoutes(userRepository: userRepository, database: database);
    authRoutes = AuthRoutes(
      googleTokenService: googleTokenService,
      appleTokenService: this.appleTokenService,
      appleRestService: this.appleRestService,
      userRepository: userRepository,
      authLimiter: _authLimiter,
      emailService: this.emailService,
    );
    meRoutes = MeRoutes(
      userRepository: userRepository,
      appleRestService: this.appleRestService,
    );
    moderationRoutes = ModerationRoutes(
      userRepository: userRepository,
      moderation: moderationRepository,
    );
    adminRoutes = AdminRoutes(
      moderation: moderationRepository,
      database: database,
      adminSecret: config.adminSecret,
      adminLimiter: _adminLimiter,
      push: pushNotifier,
    );
    coachRoutes = CoachRoutes(
      userRepository: userRepository,
      database: database,
      photosDir: p.join(p.dirname(config.databasePath), 'coach_photos'),
      emailService: this.emailService,
      adminNotifyEmail: config.adminNotifyEmail,
      push: pushNotifier,
    );
    inviteRoutes = InviteRoutes(
      userRepository: userRepository,
      database: database,
      moderation: moderationRepository,
    );
    syncRoutes = SyncRoutes(
      userRepository: userRepository,
      database: database,
      moderation: moderationRepository,
    );
    exerciseCatalogRepository = ExerciseCatalogRepository(database: database);
    workoutXService = WorkoutXService(
      apiKey: config.workoutXApiKey,
      baseUrl: config.workoutXBaseUrl,
    );
    gifCacheService = GifCacheService(
      // Sur le volume persistant (même dossier que la DB) — pas un
      // chemin relatif au binaire, qui serait perdu à chaque déploiement.
      cacheDir: Directory(p.join(p.dirname(config.databasePath), 'exercise_gifs')),
      workoutX: workoutXService,
    );
    exerciseCatalogRoutes = ExerciseCatalogRoutes(
      repository: exerciseCatalogRepository,
      adminSecret: config.adminSecret,
      gifCache: gifCacheService,
    );
  }

  /// Copie les GIFs et métadonnées bundlés dans l'image (voir seed/) vers le
  /// volume persistant, si absents. Idempotent — sans effet après le premier
  /// démarrage sur un volume déjà peuplé. Évite de re-consommer le quota
  /// WorkoutX pour propager les données déjà récupérées en dev vers un
  /// nouvel environnement (prod).
  Future<void> bootstrapExerciseCatalog() async {
    gifCacheService.ensureCacheDir();

    final seedGifsDir = Directory('seed/gifs');
    if (seedGifsDir.existsSync()) {
      var copied = 0;
      for (final entity in seedGifsDir.listSync()) {
        if (entity is! File) continue;
        final fileName = p.basename(entity.path);
        final target = File(p.join(gifCacheService.cacheDir.path, fileName));
        if (!target.existsSync()) {
          await entity.copy(target.path);
          copied++;
        }
      }
      if (copied > 0) {
        logInfo('Bootstrap: copied $copied GIF(s) to persistent volume');
      }
    }

    final seedCatalogFile = File('seed/exercise_catalog_export.json');
    if (exerciseCatalogRepository.count() == 0 && seedCatalogFile.existsSync()) {
      final rows = jsonDecode(await seedCatalogFile.readAsString()) as List;
      for (final row in rows) {
        final r = row as Map<String, dynamic>;
        exerciseCatalogRepository.upsert(
          slug: r['slug'] as String,
          workoutXId: r['workoutXId'] as String,
          name: r['name'] as String,
          targetMuscles: (r['targetMuscles'] as List).map((e) => e.toString()).toList(),
          secondaryMuscles: (r['secondaryMuscles'] as List).map((e) => e.toString()).toList(),
          equipment: r['equipment'] as String?,
          difficulty: r['difficulty'] as String?,
          instructions: (r['instructions'] as List).map((e) => e.toString()).toList(),
          gifPath: r['gifPath'] as String?,
          cachedAt: r['cachedAt'] as String?,
        );
      }
      logInfo('Bootstrap: imported ${rows.length} exercise_catalog row(s)');
    }
  }

  final AppConfig config;
  final AppDatabase database;
  final SessionService sessionService;
  final GoogleTokenService googleTokenService;
  final AppleTokenService appleTokenService;
  final AppleRestService appleRestService;
  final EmailService emailService;
  final RateLimiter _globalLimiter;
  final RateLimiter _authLimiter;
  final RateLimiter _adminLimiter;
  late final UserRepository userRepository;
  late final ModerationRepository moderationRepository;
  late final ModerationRoutes moderationRoutes;
  late final AuthRoutes authRoutes;
  late final MeRoutes meRoutes;
  late final AdminRoutes adminRoutes;
  late final CoachRoutes coachRoutes;
  late final PushNotifier pushNotifier;
  late final PushRoutes pushRoutes;
  late final InviteRoutes inviteRoutes;
  late final SyncRoutes syncRoutes;
  late final ExerciseCatalogRepository exerciseCatalogRepository;
  late final WorkoutXService workoutXService;
  late final GifCacheService gifCacheService;
  late final ExerciseCatalogRoutes exerciseCatalogRoutes;

  Handler get handler {
    final router = Router();

    router.get('/health', _healthHandler);
    router.get('/config', _configHandler);
    router.get('/admin/stats', adminRoutes.statsHandler);

    router.post('/auth/google', authRoutes.signInGoogle);
    router.post('/auth/apple', authRoutes.signInApple);
    router.get('/auth/display-name-available', authRoutes.checkDisplayNameAvailable);
    router.post('/auth/register', authRoutes.register);
    router.post('/auth/login', authRoutes.login);
    router.post('/auth/refresh', authRoutes.refresh);
    router.post('/auth/logout', authRoutes.logout);
    router.post('/auth/forgot-password', authRoutes.forgotPassword);
    router.post('/auth/reset-password', authRoutes.resetPassword);

    router.get('/me', meRoutes.getMe);
    router.put('/me/profile', meRoutes.upsertProfile);
    router.put('/me/fitness-goal', meRoutes.updateFitnessGoal);
    router.delete('/me', meRoutes.deleteAccount);
    router.put('/me/push-tokens', pushRoutes.registerToken);
    router.delete('/me/push-tokens', pushRoutes.unregisterToken);

    // ── Modération : signaler / bloquer (App Store, guideline 1.2) ──────────
    router.get('/community/blocks', moderationRoutes.listBlocked);
    router.post('/community/blocks', moderationRoutes.block);
    router.delete('/community/blocks/<userId>', moderationRoutes.unblock);
    router.post('/community/reports', moderationRoutes.report);

    // ── Admin ──────────────────────────────────────────────────────────────
    router.put('/admin/users/<userId>/set-coach', adminRoutes.setCoach);
    router.get('/admin/coach-applications', adminRoutes.listCoachApplications);
    router.post('/admin/coach-applications/<applicationId>/approve', adminRoutes.approveCoachApplication);
    router.post('/admin/coach-applications/<applicationId>/reject', adminRoutes.rejectCoachApplication);
    router.get('/admin/reports', adminRoutes.listReports);
    router.post('/admin/reports/<reportId>/resolve', adminRoutes.resolveReport);
    router.delete('/admin/users/<userId>', adminRoutes.deleteUser);
    router.get('/admin/users/<userId>/workouts', adminRoutes.listUserWorkouts);
    router.delete('/admin/users/<userId>/workouts/<workoutId>', adminRoutes.deleteUserWorkout);
    router.delete('/admin/users/<userId>/workouts', adminRoutes.deleteAllUserWorkouts);
    router.get('/admin/users/<userId>/programs', adminRoutes.listUserPrograms);
    router.delete('/admin/users/<userId>/programs', adminRoutes.deleteAllUserPrograms);
    router.delete('/admin/users/<userId>/exercises', adminRoutes.deleteAllUserExercises);

    // Endpoints de diagnostic pur (pas d'usage opérationnel légitime en
    // production) — désactivés hors dev/staging pour réduire la surface
    // d'exposition de données personnelles en cas de fuite du secret admin.
    if (!config.isProduction) {
      router.get('/admin/users/<userId>/debug-sync', adminRoutes.debugUserSync);
      router.get('/admin/debug-users', adminRoutes.debugListUsers);
      router.get('/admin/debug-workouts/<workoutId>', adminRoutes.debugWorkoutDetail);
      router.get('/admin/users/<userId>/debug-name', adminRoutes.debugDisplayName);
    }

    // ── Coach ──────────────────────────────────────────────────────────────
    router.post('/coach/invite-codes', coachRoutes.generateInviteCode);
    router.post('/coach/invite-codes/redeem', coachRoutes.redeemCode);
    router.get('/coach/athletes', coachRoutes.getAthletes);
    router.delete('/coach/athletes/<athleteUserId>', coachRoutes.removeAthlete);
    router.get('/coach/athletes/<athleteUserId>/detail', coachRoutes.getAthleteDetail);
    router.put('/coach/athletes/<athleteUserId>/settings', coachRoutes.updateAthleteSettings);
    router.put('/coach/settings', coachRoutes.updateSettings);
    router.put('/coach/athletes/<athleteUserId>/workouts/<workoutId>/note', coachRoutes.saveNote);
    router.post('/coach/athletes/<athleteUserId>/workouts/<workoutId>/seen', coachRoutes.markWorkoutSeen);
    router.put('/coach/athletes/<athleteUserId>/program', coachRoutes.assignProgram);
    router.delete('/coach/athletes/<athleteUserId>/program', coachRoutes.removeProgram);
    router.put('/coach/public-profile', coachRoutes.upsertPublicProfile);
    router.get('/coach/public-profile', coachRoutes.getMyPublicProfile);
    router.put('/coach/public-profile/photo', coachRoutes.uploadProfilePhoto);
    router.delete('/coach/public-profile/photo', coachRoutes.deleteProfilePhoto);
    router.get('/coach-photos/<filename>', coachRoutes.servePhoto);
    router.get('/coaches/public', coachRoutes.getPublicCoaches);
    router.get('/athlete/coach', coachRoutes.getMyCoach);
    router.get('/athlete/invite-request', coachRoutes.getMyInviteRequest);
    router.delete('/athlete/invite-request', coachRoutes.cancelMyInviteRequest);
    router.post('/coach/application', coachRoutes.submitApplication);
    router.get('/coach/application', coachRoutes.getMyApplication);
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
    router.get('/community/users/lookup', syncRoutes.lookupUserByDisplayName);
    router.post('/community/relations', syncRoutes.pushRelation);
    router.patch('/community/relations/<relationId>', syncRoutes.patchRelation);
    router.delete('/community/relations/<relationId>', syncRoutes.deleteRelation);
    router.get('/community/relations', syncRoutes.getRelations);
    router.get('/community/friends/shares', syncRoutes.getFriendsShares);
    router.get('/community/friends/<friendUserId>/exercise-stats', syncRoutes.getFriendExerciseStats);
    router.get('/community/relations/<relationUserId>/session-detail', syncRoutes.getRelationSessionDetail);

    // ── Catalogue d'exercices par défaut (GIFs) ─────────────────────────────
    router.get('/exercises/catalog', exerciseCatalogRoutes.getAll);
    router.get('/exercises/catalog/search', exerciseCatalogRoutes.search);
    router.get('/exercises/catalog/<slug>', exerciseCatalogRoutes.getBySlug);
    router.get('/exercise-gifs/<filename>', exerciseCatalogRoutes.serveGif);
    router.post('/admin/exercises/import', exerciseCatalogRoutes.importCatalog);

    return const Pipeline()
        .addMiddleware(requestIdMiddleware())
        .addMiddleware(corsMiddleware(config.corsAllowedOrigins))
        .addMiddleware(_globalLimiter.asMiddleware())
        .addMiddleware(_structuredLoggerMiddleware())
        .addMiddleware(_errorCatcherMiddleware())
        .addHandler(router.call);
  }

  // iOS : "<Apple Team ID>.<bundle id>". Pour que iOS ouvre réellement l'app,
  // elle doit aussi déclarer l'entitlement Associated Domains
  // (applinks:gymtrack-backend-2.fly.dev), pas encore fait côté app. Android
  // est renseigné (empreinte SHA-256 de la clé de signature d'application
  // Play App Signing).
  Response _appleAppSiteAssociationHandler(Request request) {
    return jsonResponse({
      'applinks': {
        'apps': [],
        'details': [
          {
            'appID': 'S869NWC695.com.gymarena.app',
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
          'package_name': 'com.gymarena.app',
          'sha256_cert_fingerprints': <String>[
            '9F:3B:AB:73:E0:E3:7A:5A:05:08:B0:1A:D3:8F:54:89:DE:72:D5:C6:0A:67:77:96:49:D7:71:84:7F:B9:E2:3B',
          ],
        },
      },
    ]);
  }

  /// Réglages lus par l'app au démarrage, sans compte : couper le coaching
  /// ici le masque sans nouvelle version sur les stores.
  Response _configHandler(Request request) =>
      jsonResponse({'coachEnabled': config.coachFeatureEnabled});

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
    appleTokenService.close();
    appleRestService.close();
    workoutXService.close();
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
