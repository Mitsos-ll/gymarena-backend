import 'package:shelf/shelf.dart';
import '../db/app_database.dart';
import '../middleware/rate_limit_middleware.dart';
import '../utils/api_exception.dart';
import '../utils/client_ip.dart';
import '../utils/http_json.dart';
import '../utils/logger.dart';
import '../utils/secure_compare.dart';

class AdminRoutes {
  AdminRoutes({
    required this.database,
    required this.adminSecret,
    required RateLimiter adminLimiter,
  }) : _adminLimiter = adminLimiter;

  final AppDatabase database;
  final String adminSecret;
  final RateLimiter _adminLimiter;

  /// Vérifie le rate-limit dédié puis le secret admin (comparaison à temps
  /// constant), et journalise tout accès autorisé pour audit. Retourne une
  /// [Response] 429/401 si la requête doit être rejetée, ou `null` si elle
  /// peut continuer.
  Response? _guard(Request request, String endpoint) {
    final ip = clientIp(request);

    if (!_adminLimiter.allow(ip)) {
      return Response(429,
          body: '{"message":"Too many admin requests."}',
          headers: {'Content-Type': 'application/json'});
    }

    final auth = request.headers['authorization'] ?? '';
    if (!constantTimeEquals(auth, 'Bearer $adminSecret')) {
      return Response(401,
          body: '{"message":"Unauthorized"}',
          headers: {'Content-Type': 'application/json'});
    }

    logInfo('Admin access', extra: {'endpoint': endpoint, 'ip': ip});
    return null;
  }

  Response statsHandler(Request request) {
    final denied = _guard(request, 'GET /admin/stats');
    if (denied != null) return denied;

    final db = database.raw;

    final totalUsers = (db.select(
      'SELECT COUNT(*) as c FROM users WHERE is_deleted = 0',
    ).first['c'] as int?) ?? 0;

    final activeUsers7d = (db.select(
      "SELECT COUNT(*) as c FROM users WHERE is_deleted = 0 AND last_login_at >= datetime('now', '-7 days')",
    ).first['c'] as int?) ?? 0;

    final activeUsers30d = (db.select(
      "SELECT COUNT(*) as c FROM users WHERE is_deleted = 0 AND last_login_at >= datetime('now', '-30 days')",
    ).first['c'] as int?) ?? 0;

    final newToday = (db.select(
      "SELECT COUNT(*) as c FROM users WHERE is_deleted = 0 AND created_at >= datetime('now', 'start of day')",
    ).first['c'] as int?) ?? 0;

    final newThisWeek = (db.select(
      "SELECT COUNT(*) as c FROM users WHERE is_deleted = 0 AND created_at >= datetime('now', '-7 days')",
    ).first['c'] as int?) ?? 0;

    final activeSessions = (db.select(
      "SELECT COUNT(*) as c FROM auth_sessions WHERE revoked_at IS NULL AND refresh_expires_at > datetime('now')",
    ).first['c'] as int?) ?? 0;

    final totalCoaches = (db.select(
      'SELECT COUNT(*) as c FROM user_profiles WHERE is_coach = 1',
    ).first['c'] as int?) ?? 0;

    return jsonResponse({
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'users': {
        'total': totalUsers,
        'new_today': newToday,
        'new_this_week': newThisWeek,
        'active_7d': activeUsers7d,
        'active_30d': activeUsers30d,
      },
      'sessions': {
        'active': activeSessions,
      },
      'coaches': {
        'total': totalCoaches,
      },
    });
  }

  Response listUserWorkouts(Request request, String userId) {
    final denied = _guard(request, 'GET /admin/users/<userId>/workouts');
    if (denied != null) return denied;

    final db = database.raw;
    final workouts = db.select(
      'SELECT id, workout_date, duration_seconds, notes FROM workouts WHERE user_id=? ORDER BY workout_date DESC',
      [userId],
    );
    final result = workouts.map((w) {
      final weRows = db.select('SELECT COUNT(*) as c FROM workout_exercises WHERE workout_id=?', [w['id']]);
      return {
        'id': w['id'],
        'date': w['workout_date'],
        'durationSeconds': w['duration_seconds'],
        'notes': w['notes'],
        'exerciseCount': weRows.first['c'],
      };
    }).toList();
    return jsonResponse({'userId': userId, 'workouts': result, 'total': result.length});
  }

  Response debugWorkoutDetail(Request request, String workoutId) {
    final denied = _guard(request, 'GET /admin/debug-workouts/<workoutId>');
    if (denied != null) return denied;

    final db = database.raw;
    final rows = db.select(
      'SELECT we.id as we_id, COALESCE(e.name, we.exercise_name_snapshot) as exercise_name, '
      'e.muscle_group_name as muscle_group_name, ws.weight_kg, ws.reps '
      'FROM workout_exercises we '
      'LEFT JOIN exercises e ON e.id = we.exercise_id '
      'LEFT JOIN workout_sets ws ON ws.workout_exercise_id = we.id '
      'WHERE we.workout_id=?',
      [workoutId],
    );
    return jsonResponse({
      'workoutId': workoutId,
      'rows': rows.map((r) => {
        'exerciseName': r['exercise_name'],
        'muscleGroupName': r['muscle_group_name'],
        'weightKg': r['weight_kg'],
        'reps': r['reps'],
      }).toList(),
    });
  }

  Response deleteUserWorkout(Request request, String userId, String workoutId) {
    final denied = _guard(request, 'DELETE /admin/users/<userId>/workouts/<workoutId>');
    if (denied != null) return denied;

    final db = database.raw;
    db.execute('DELETE FROM workouts WHERE id=? AND user_id=?', [workoutId, userId]);
    return jsonResponse({'deleted': workoutId});
  }

  Response deleteAllUserWorkouts(Request request, String userId) {
    final denied = _guard(request, 'DELETE /admin/users/<userId>/workouts');
    if (denied != null) return denied;

    final db = database.raw;
    db.execute('DELETE FROM workouts WHERE user_id=?', [userId]);
    return jsonResponse({'deleted': true, 'userId': userId});
  }

  Response listUserPrograms(Request request, String userId) {
    final denied = _guard(request, 'GET /admin/users/<userId>/programs');
    if (denied != null) return denied;

    final db = database.raw;
    final rows = db.select(
      'SELECT id, name, created_at FROM programs WHERE user_id=? ORDER BY name',
      [userId],
    );
    return jsonResponse({'userId': userId, 'programs': rows.map((r) => {'id': r['id'], 'name': r['name'], 'created_at': r['created_at']}).toList(), 'total': rows.length});
  }

  Response deleteAllUserPrograms(Request request, String userId) {
    final denied = _guard(request, 'DELETE /admin/users/<userId>/programs');
    if (denied != null) return denied;

    final db = database.raw;
    db.execute('DELETE FROM programs WHERE user_id=?', [userId]);
    return jsonResponse({'deleted': true, 'userId': userId});
  }

  Response debugListUsers(Request request) {
    final denied = _guard(request, 'GET /admin/debug-users');
    if (denied != null) return denied;

    final db = database.raw;
    final users = db.select(
      'SELECT id, email, display_name FROM users WHERE is_deleted = 0 ORDER BY created_at DESC',
    );
    final relations = db.select(
      "SELECT user_id_a, user_id_b, status, request_status FROM social_relations WHERE request_status='accepted'",
    );
    final workoutCounts = db.select(
      'SELECT user_id, COUNT(*) as c FROM workouts GROUP BY user_id',
    );
    return jsonResponse({
      'users': users.map((r) => {
        'id': r['id'], 'email': r['email'], 'displayName': r['display_name'],
      }).toList(),
      'acceptedRelations': relations.map((r) => {
        'userIdA': r['user_id_a'], 'userIdB': r['user_id_b'], 'status': r['status'],
      }).toList(),
      'workoutCounts': workoutCounts.map((r) => {
        'userId': r['user_id'], 'count': r['c'],
      }).toList(),
    });
  }

  Response debugDisplayName(Request request, String userId) {
    final denied = _guard(request, 'GET /admin/users/<userId>/debug-name');
    if (denied != null) return denied;

    final db = database.raw;
    final cp = db.select('SELECT display_name FROM community_profiles WHERE user_id=?', [userId]);
    final up = db.select('SELECT display_name FROM user_profiles WHERE user_id=?', [userId]);
    final u = db.select('SELECT display_name FROM users WHERE id=?', [userId]);
    return jsonResponse({
      'userId': userId,
      'community_profiles.display_name': cp.isNotEmpty ? cp.first['display_name'] : '<no row>',
      'user_profiles.display_name': up.isNotEmpty ? up.first['display_name'] : '<no row>',
      'users.display_name': u.isNotEmpty ? u.first['display_name'] : '<no row>',
    });
  }

  Response debugUserSync(Request request, String userId) {
    final denied = _guard(request, 'GET /admin/users/<userId>/debug-sync');
    if (denied != null) return denied;

    final db = database.raw;
    final profile = db.select(
      'SELECT user_id, weight_kg, height_cm, fitness_goal, updated_at FROM user_profiles WHERE user_id=?',
      [userId],
    );
    final exercises = db.select(
      'SELECT id, local_id, name, muscle_group_name, created_at FROM exercises WHERE user_id=? ORDER BY created_at DESC',
      [userId],
    );
    final measurements = db.select(
      'SELECT id, local_id, measurement_type, value_cm, created_at FROM body_measurements WHERE user_id=? ORDER BY created_at DESC',
      [userId],
    );
    final weights = db.select(
      'SELECT id, local_id, weight_kg, created_at FROM weight_history WHERE user_id=? ORDER BY created_at DESC',
      [userId],
    );
    return jsonResponse({
      'userId': userId,
      'profile': profile.map((r) => {
        'weightKg': r['weight_kg'],
        'heightCm': r['height_cm'],
        'fitnessGoal': r['fitness_goal'],
        'updatedAt': r['updated_at'],
      }).toList(),
      'exercises': exercises.map((r) => {
        'id': r['id'],
        'localId': r['local_id'],
        'name': r['name'],
        'muscleGroupName': r['muscle_group_name'],
        'createdAt': r['created_at'],
      }).toList(),
      'measurements': measurements.map((r) => {
        'id': r['id'],
        'localId': r['local_id'],
        'measurementType': r['measurement_type'],
        'valueCm': r['value_cm'],
        'createdAt': r['created_at'],
      }).toList(),
      'weights': weights.map((r) => {
        'id': r['id'],
        'localId': r['local_id'],
        'weightKg': r['weight_kg'],
        'createdAt': r['created_at'],
      }).toList(),
    });
  }

  Response deleteAllUserExercises(Request request, String userId) {
    final denied = _guard(request, 'DELETE /admin/users/<userId>/exercises');
    if (denied != null) return denied;

    final db = database.raw;
    db.execute('DELETE FROM exercises WHERE user_id=?', [userId]);
    return jsonResponse({'deleted': true, 'userId': userId});
  }

  Future<Response> setCoach(Request request, String userId) async {
    final denied = _guard(request, 'PUT /admin/users/<userId>/set-coach');
    if (denied != null) return denied;

    try {
      final body = await readJsonBody(request);
      final isCoach = body['isCoach'] == true ? 1 : 0;
      final now = dbNow();

      final rows = database.raw.select('SELECT id FROM users WHERE id=? AND is_deleted=0 LIMIT 1', [userId]);
      if (rows.isEmpty) {
        return errorResponse('User not found.', statusCode: 404);
      }

      database.raw.execute(
        'UPDATE user_profiles SET is_coach=?, updated_at=? WHERE user_id=?',
        [isCoach, now, userId],
      );

      return jsonResponse({'userId': userId, 'isCoach': isCoach == 1, 'updatedAt': now});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }
}
