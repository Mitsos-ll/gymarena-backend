import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../repositories/user_repository.dart';
import '../utils/api_exception.dart';
import '../utils/auth_helper.dart';
import '../utils/http_json.dart';

class SyncRoutes {
  SyncRoutes({required UserRepository userRepository, required AppDatabase database})
      : _repo = userRepository,
        _db = database;

  final UserRepository _repo;
  final AppDatabase _db;
  final _uuid = const Uuid();

  /// Résout l'id backend (UUID) pour une entité scopée par utilisateur via
  /// (user_id, local_id), au lieu de réutiliser directement l'id local du
  /// device comme clé primaire globale (collision possible entre comptes
  /// différents partageant le même compteur autoincrement local).
  /// Si aucune correspondance n'existe, génère un nouvel UUID.
  String _resolveScopedId(String table, String userId, dynamic localId) {
    if (localId == null) return _uuid.v4();
    final existing = _db.raw.select(
      'SELECT id FROM $table WHERE user_id=? AND local_id=? LIMIT 1',
      [userId, localId],
    );
    return existing.isNotEmpty ? existing.first['id'] as String : _uuid.v4();
  }

  // ── GET /me/snapshot ──────────────────────────────────────────────────────

  Future<Response> getSnapshot(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;

      final workouts = _db.raw.select(
        'SELECT w.*, GROUP_CONCAT(we.id) as _we_ids FROM workouts w LEFT JOIN workout_exercises we ON we.workout_id=w.id WHERE w.user_id=? GROUP BY w.id ORDER BY w.workout_date DESC',
        [userId],
      );

      final workoutList = <Map<String, dynamic>>[];
      for (final w in workouts) {
        final workoutId = w['id'] as String;
        final exercises = _db.raw.select(
          'SELECT we.*, ws.id as ws_id, ws.set_number, ws.weight_kg, ws.reps, ws.volume_reps, ws.rpe, ws.rest_time_seconds, ws.estimated_1rm, ws.bodyweight_kg, ws.added_weight_kg, ws.set_type '
          'FROM workout_exercises we LEFT JOIN workout_sets ws ON ws.workout_exercise_id=we.id '
          'WHERE we.workout_id=? ORDER BY we.exercise_order, ws.set_number',
          [workoutId],
        );

        final setSides = _db.raw.select(
          'SELECT wss.* FROM workout_set_sides wss '
          'JOIN workout_sets ws ON ws.id = wss.workout_set_id '
          'JOIN workout_exercises we ON we.id = ws.workout_exercise_id '
          'WHERE we.workout_id=?',
          [workoutId],
        );
        final sidesBySetId = <String, List<Map<String, dynamic>>>{};
        for (final row in setSides) {
          final setId = row['workout_set_id'] as String;
          (sidesBySetId[setId] ??= []).add({
            'side': row['side'],
            'reps': row['reps'],
            'rpe': row['rpe'],
          });
        }

        final exerciseMap = <String, Map<String, dynamic>>{};
        for (final row in exercises) {
          final weId = row['id'] as String;
          exerciseMap.putIfAbsent(weId, () => {
            'id': weId,
            'exerciseId': row['exercise_id'],
            'exerciseNameSnapshot': row['exercise_name_snapshot'],
            'exerciseOrder': row['exercise_order'],
            'sets': <Map<String, dynamic>>[],
          });
          if (row['ws_id'] != null) {
            final wsId = row['ws_id'] as String;
            (exerciseMap[weId]!['sets'] as List).add({
              'id': wsId,
              'setNumber': row['set_number'],
              'weightKg': row['weight_kg'],
              'reps': row['reps'],
              'volumeReps': row['volume_reps'],
              'rpe': row['rpe'],
              'restTimeSeconds': row['rest_time_seconds'],
              'estimated1Rm': row['estimated_1rm'],
              'bodyweightKg': row['bodyweight_kg'],
              'addedWeightKg': row['added_weight_kg'],
              'setType': row['set_type'],
              'sides': sidesBySetId[wsId] ?? const [],
            });
          }
        }

        workoutList.add({
          'id': workoutId,
          'localId': w['local_id'],
          'workoutDate': w['workout_date'],
          'startTime': w['start_time'],
          'endTime': w['end_time'],
          'durationSeconds': w['duration_seconds'],
          'bodyweightKgSnapshot': w['bodyweight_kg_snapshot'],
          'notes': w['notes'],
          'exercises': exerciseMap.values.toList(),
        });
      }

      final exercises = _db.raw.select(
        'SELECT * FROM exercises WHERE user_id=? ORDER BY name',
        [userId],
      );

      final programs = _db.raw.select(
        'SELECT * FROM programs WHERE user_id=? ORDER BY name',
        [userId],
      );
      final programList = <Map<String, dynamic>>[];
      for (final p in programs) {
        final programId = p['id'] as String;
        final sessions = _db.raw.select(
          'SELECT ps.*, pe.id as pe_id, pe.exercise_id, pe.exercise_name_snapshot, pe.exercise_order, pe.target_sets, pe.target_reps_min, pe.target_reps_max, pe.target_rpe, pe.progression_step_kg '
          'FROM program_sessions ps LEFT JOIN program_exercises pe ON pe.program_session_id=ps.id '
          'WHERE ps.program_id=? ORDER BY ps.session_order, pe.exercise_order',
          [programId],
        );
        final sessionMap = <String, Map<String, dynamic>>{};
        for (final row in sessions) {
          final psId = row['id'] as String;
          sessionMap.putIfAbsent(psId, () => {
            'id': psId,
            'name': row['name'],
            'sessionOrder': row['session_order'],
            'dayOfWeek': row['day_of_week'],
            'exercises': <Map<String, dynamic>>[],
          });
          if (row['pe_id'] != null) {
            (sessionMap[psId]!['exercises'] as List).add({
              'id': row['pe_id'],
              'exerciseId': row['exercise_id'],
              'exerciseNameSnapshot': row['exercise_name_snapshot'],
              'exerciseOrder': row['exercise_order'],
              'targetSets': row['target_sets'],
              'targetRepsMin': row['target_reps_min'],
              'targetRepsMax': row['target_reps_max'],
              'targetRpe': row['target_rpe'],
              'progressionStepKg': row['progression_step_kg'],
            });
          }
        }
        programList.add({
          'id': programId,
          'localId': p['local_id'],
          'name': p['name'],
          'description': p['description'],
          'daysPerWeek': p['days_per_week'],
          'sessions': sessionMap.values.toList(),
        });
      }

      final sessionTemplates = _db.raw.select(
        'SELECT * FROM session_templates WHERE user_id=? ORDER BY name',
        [userId],
      );
      final sessionTemplateList = <Map<String, dynamic>>[];
      for (final t in sessionTemplates) {
        final templateId = t['id'] as String;
        final teRows = _db.raw.select(
          'SELECT * FROM session_template_exercises WHERE session_template_id=? ORDER BY display_order',
          [templateId],
        );
        sessionTemplateList.add({
          'id': templateId,
          'localId': t['local_id'],
          'name': t['name'],
          'exercises': teRows.map((e) => {
            'exerciseId': e['exercise_id'],
            'exerciseNameSnapshot': e['exercise_name_snapshot'],
            'displayOrder': e['display_order'],
          }).toList(),
        });
      }

      final weightHistory = _db.raw.select(
        'SELECT * FROM weight_history WHERE user_id=? ORDER BY effective_date DESC',
        [userId],
      );

      final measurements = _db.raw.select(
        'SELECT * FROM body_measurements WHERE user_id=? ORDER BY measured_date DESC',
        [userId],
      );

      final gamRows = _db.raw.select(
        'SELECT * FROM gamification_profiles WHERE user_id=? LIMIT 1',
        [userId],
      );
      final achievements = _db.raw.select(
        'SELECT * FROM achievements WHERE user_id=?',
        [userId],
      );
      final goals = _db.raw.select(
        "SELECT * FROM goals WHERE user_id=? AND status='active'",
        [userId],
      );

      final communityRows = _db.raw.select(
        'SELECT * FROM community_profiles WHERE user_id=? LIMIT 1',
        [userId],
      );
      final relations = _db.raw.select(
        "SELECT * FROM social_relations WHERE (user_id_a=? OR user_id_b=?) AND status='accepted'",
        [userId, userId],
      );
      final workoutShares = _db.raw.select(
        'SELECT * FROM workout_shares WHERE owner_user_id=? ORDER BY created_at DESC LIMIT 50',
        [userId],
      );

      final programShares = _db.raw.select(
        'SELECT * FROM program_shares WHERE owner_user_id=? ORDER BY created_at DESC LIMIT 50',
        [userId],
      );

      return jsonResponse({
        'userId': userId,
        'generatedAt': dbNow(),
        'workouts': workoutList,
        'exercises': exercises.map((e) => _exerciseRowToJson(e)).toList(),
        'programs': programList,
        'sessionTemplates': sessionTemplateList,
        'weightHistory': weightHistory.map((r) => {
          'id': r['id'],
          'localId': r['local_id'],
          'weightKg': r['weight_kg'],
          'effectiveDate': r['effective_date'],
          'notes': r['notes'],
          'createdAt': r['created_at'],
        }).toList(),
        'bodyMeasurements': measurements.map((r) => {
          'id': r['id'],
          'localId': r['local_id'],
          'measurementType': r['measurement_type'],
          'valueCm': r['value_cm'],
          'measuredDate': r['measured_date'],
          'notes': r['notes'],
          'createdAt': r['created_at'],
        }).toList(),
        'gamification': gamRows.isEmpty ? null : {
          'totalXp': gamRows.first['total_xp'],
          'totalWorkouts': gamRows.first['total_workouts'],
          'totalVolumeKg': gamRows.first['total_volume_kg'],
          'totalSets': gamRows.first['total_sets'],
          'currentStreak': gamRows.first['current_streak'],
          'longestStreak': gamRows.first['longest_streak'],
          'totalPrsEver': gamRows.first['total_prs_ever'],
          'lastWorkoutDate': gamRows.first['last_workout_date'],
          'achievements': achievements.map((a) => {'id': a['id'], 'unlockedAt': a['unlocked_at']}).toList(),
          'goals': goals.map((g) => {
            'id': g['id'],
            'type': g['type'],
            'title': g['title'],
            'target': g['target'],
            'currentValue': g['current_value'],
            'startDate': g['start_date'],
            'dueDate': g['due_date'],
            'status': g['status'],
          }).toList(),
        },
        'communityProfile': communityRows.isEmpty ? null : {
          'displayName': communityRows.first['display_name'],
          'avatarPresetId': communityRows.first['avatar_preset_id'],
          'level': communityRows.first['level'],
          'tier': communityRows.first['tier'],
          'totalXp': communityRows.first['total_xp'],
          'currentStreak': communityRows.first['current_streak'],
          'totalWorkouts': communityRows.first['total_workouts'],
          'totalVolumeKg': communityRows.first['total_volume_kg'],
          'totalPrs': communityRows.first['total_prs'],
          'badgeIds': communityRows.first['badge_ids'],
          'privacyJson': jsonDecode(communityRows.first['privacy_json'] as String? ?? '{}'),
        },
        'relations': relations.map((r) => {
          'id': r['id'],
          'userIdA': r['user_id_a'],
          'userIdB': r['user_id_b'],
          'status': r['status'],
        }).toList(),
        'workoutShares': workoutShares.map((r) => {
          'id': r['id'],
          'workoutId': r['workout_id'],
          'title': r['title'],
          'snapshotJson': jsonDecode(r['snapshot_json'] as String? ?? '{}'),
          'visibility': r['visibility'],
          'createdAt': r['created_at'],
        }).toList(),
        'programShares': programShares.map((r) => {
          'id': r['id'],
          'programId': r['program_id'],
          'title': r['title'],
          'snapshotJson': jsonDecode(r['snapshot_json'] as String? ?? '{}'),
          'visibility': r['visibility'] ?? 'friendsOnly',
          'createdAt': r['created_at'],
        }).toList(),
      });
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── POST /workouts/batch ─────────────────────────────────────────────────

  Future<Response> pushWorkoutBatch(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;
      final body = await readJsonBody(request);
      final items = (body['workouts'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      final now = dbNow();
      final ids = <String>[];

      for (final item in items) {
        final id = _resolveScopedId('workouts', userId, item['localId']);
        _db.raw.execute(
          'INSERT OR REPLACE INTO workouts (id, user_id, local_id, workout_date, start_time, end_time, duration_seconds, bodyweight_kg_snapshot, notes, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM workouts WHERE id=?), ?), ?)',
          [
            id, userId, item['localId'],
            item['workoutDate'] ?? now.substring(0, 10),
            item['startTime'], item['endTime'],
            item['durationSeconds'] ?? 0,
            item['bodyweightKgSnapshot'], item['notes'],
            id, now, now,
          ],
        );

        // Les exercices/séries sont toujours envoyés en intégralité à chaque
        // push : on repart d'une table enfant vide (cascade) puis on
        // ré-insère avec des UUID frais, ce qui évite toute collision d'id
        // enfant entre deux comptes différents.
        _db.raw.execute('DELETE FROM workout_exercises WHERE workout_id=?', [id]);
        final exercises = (item['exercises'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        for (final ex in exercises) {
          final weId = _uuid.v4();
          _db.raw.execute(
            'INSERT INTO workout_exercises (id, workout_id, exercise_id, exercise_name_snapshot, muscle_group_name_snapshot, exercise_order, notes, created_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            [weId, id, ex['exerciseId'], ex['exerciseNameSnapshot'], ex['muscleGroupNameSnapshot'], ex['exerciseOrder'] ?? 0, ex['notes'], now],
          );
          final sets = (ex['sets'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          for (final s in sets) {
            final wsId = _uuid.v4();
            _db.raw.execute(
              'INSERT INTO workout_sets (id, workout_exercise_id, set_number, weight_kg, reps, volume_reps, rpe, rest_time_seconds, estimated_1rm, bodyweight_kg, added_weight_kg, set_type, created_at) '
              'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
              [wsId, weId, s['setNumber'] ?? 1, s['weightKg'] ?? 0, s['reps'] ?? 0, s['volumeReps'] ?? s['reps'] ?? 0, s['rpe'], s['restTimeSeconds'], s['estimated1Rm'], s['bodyweightKg'], s['addedWeightKg'], s['setType'] ?? 'normal', now],
            );
            final sides = (s['sides'] as List?)?.cast<Map<String, dynamic>>() ?? [];
            for (final side in sides) {
              _db.raw.execute(
                'INSERT INTO workout_set_sides (id, workout_set_id, side, reps, rpe, created_at) '
                'VALUES (?, ?, ?, ?, ?, ?)',
                [_uuid.v4(), wsId, side['side'], side['reps'] ?? 0, side['rpe'], now],
              );
            }
          }
        }
        ids.add(id);
      }

      return jsonResponse({'synced': ids.length, 'ids': ids, 'syncedAt': now});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── POST /workouts ────────────────────────────────────────────────────────

  Future<Response> pushWorkout(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;
      final body = await readJsonBody(request);

      final id = _resolveScopedId('workouts', userId, body['localId']);
      final now = dbNow();

      _db.raw.execute(
        'INSERT OR REPLACE INTO workouts (id, user_id, local_id, workout_date, start_time, end_time, duration_seconds, bodyweight_kg_snapshot, notes, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM workouts WHERE id=?), ?), ?)',
        [
          id, userId,
          body['localId'],
          body['workoutDate'] ?? now.substring(0, 10),
          body['startTime'],
          body['endTime'],
          body['durationSeconds'] ?? 0,
          body['bodyweightKgSnapshot'],
          body['notes'],
          id, now, now,
        ],
      );

      _db.raw.execute('DELETE FROM workout_exercises WHERE workout_id=?', [id]);
      final exercises = (body['exercises'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      for (final ex in exercises) {
        final weId = _uuid.v4();
        _db.raw.execute(
          'INSERT INTO workout_exercises (id, workout_id, exercise_id, exercise_name_snapshot, muscle_group_name_snapshot, exercise_order, notes, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          [weId, id, ex['exerciseId'], ex['exerciseNameSnapshot'], ex['muscleGroupNameSnapshot'], ex['exerciseOrder'] ?? 0, ex['notes'], now],
        );

        final sets = (ex['sets'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        for (final s in sets) {
          final wsId = _uuid.v4();
          _db.raw.execute(
            'INSERT INTO workout_sets (id, workout_exercise_id, set_number, weight_kg, reps, rpe, rest_time_seconds, estimated_1rm, bodyweight_kg, added_weight_kg, set_type, created_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [wsId, weId, s['setNumber'] ?? 1, s['weightKg'] ?? 0, s['reps'] ?? 0, s['rpe'], s['restTimeSeconds'], s['estimated1Rm'], s['bodyweightKg'], s['addedWeightKg'], s['setType'] ?? 'normal', now],
          );
          final sides = (s['sides'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          for (final side in sides) {
            _db.raw.execute(
              'INSERT INTO workout_set_sides (id, workout_set_id, side, reps, rpe, created_at) '
              'VALUES (?, ?, ?, ?, ?, ?)',
              [_uuid.v4(), wsId, side['side'], side['reps'] ?? 0, side['rpe'], now],
            );
          }
        }
      }

      return jsonResponse({'id': id, 'syncedAt': now});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // localId est l'id SQLite local du device (non globalement unique) ; on
  // résout l'UUID backend via (user_id, local_id) avant suppression.
  Future<Response> deleteWorkout(Request request, String localId) async {
    try {
      final session = requireAuth(request, _repo);
      _db.raw.execute(
        'DELETE FROM workouts WHERE user_id=? AND local_id=?',
        [session.user.id, localId],
      );
      return Response(204);
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── POST /exercises/batch ─────────────────────────────────────────────────

  Future<Response> pushExerciseBatch(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;
      final body = await readJsonBody(request);
      final entries = (body['exercises'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      final now = dbNow();
      final ids = <String>[];

      for (final e in entries) {
        final localId = e['localId'] ?? e['local_id'];
        final id = _resolveScopedId('exercises', userId, localId);
        _db.raw.execute(
          'INSERT OR REPLACE INTO exercises (id, user_id, local_id, name, muscle_group_name, exercise_type, is_unilateral, equipment, description, performance_type, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM exercises WHERE id=?), ?), ?)',
          [
            id, userId, localId,
            e['name'] ?? e['name'] ?? 'Exercice',
            e['muscleGroupName'] ?? e['muscle_group_name'],
            e['exerciseType'] ?? e['exercise_type'] ?? 'strength',
            ((e['isUnilateral'] ?? e['is_unilateral']) == true || (e['isUnilateral'] ?? e['is_unilateral']) == 1) ? 1 : 0,
            e['equipment'],
            e['description'],
            e['performanceType'] ?? e['performance_type'] ?? 'strength',
            id, now, now,
          ],
        );
        ids.add(id);
      }

      return jsonResponse({'synced': ids.length, 'ids': ids, 'syncedAt': now});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── POST /exercises ───────────────────────────────────────────────────────

  Future<Response> pushExercise(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;
      final body = await readJsonBody(request);

      final id = _resolveScopedId('exercises', userId, body['localId']);
      final now = dbNow();

      _db.raw.execute(
        'INSERT OR REPLACE INTO exercises (id, user_id, local_id, name, muscle_group_name, exercise_type, is_unilateral, equipment, description, performance_type, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM exercises WHERE id=?), ?), ?)',
        [
          id, userId, body['localId'],
          body['name'] ?? 'Exercice',
          body['muscleGroupName'],
          body['exerciseType'] ?? 'strength',
          (body['isUnilateral'] == true) ? 1 : 0,
          body['equipment'],
          body['description'],
          body['performanceType'] ?? 'strength',
          id, now, now,
        ],
      );

      return jsonResponse({'id': id, 'syncedAt': now});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── POST /programs/batch ─────────────────────────────────────────────────

  Future<Response> pushProgramBatch(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;
      final body = await readJsonBody(request);
      final items = (body['programs'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      final now = dbNow();
      final ids = <String>[];

      for (final item in items) {
        final id = _resolveScopedId('programs', userId, item['localId']);
        _db.raw.execute(
          'INSERT OR REPLACE INTO programs (id, user_id, local_id, name, description, days_per_week, deload_every_n_weeks, progression_step_kg, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM programs WHERE id=?), ?), ?)',
          [
            id, userId, item['localId'],
            item['name'] ?? 'Programme', item['description'],
            item['daysPerWeek'], item['deloadEveryNWeeks'], item['progressionStepKg'],
            id, now, now,
          ],
        );

        // Séances/exercices toujours envoyés en intégralité : on repart
        // d'une table enfant vide (cascade) puis on ré-insère avec des UUID
        // frais, ce qui évite toute collision d'id enfant entre comptes.
        _db.raw.execute('DELETE FROM program_sessions WHERE program_id=?', [id]);
        final sessions = (item['sessions'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        for (final s in sessions) {
          final psId = _uuid.v4();
          _db.raw.execute(
            'INSERT INTO program_sessions (id, program_id, name, session_order, day_of_week, created_at) '
            'VALUES (?, ?, ?, ?, ?, ?)',
            [psId, id, s['name'] ?? 'Séance', s['sessionOrder'] ?? 0, s['dayOfWeek'], now],
          );
          final exercises = (s['exercises'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          for (final ex in exercises) {
            final peId = _uuid.v4();
            _db.raw.execute(
              'INSERT INTO program_exercises (id, program_session_id, exercise_id, exercise_name_snapshot, exercise_order, target_sets, target_reps_min, target_reps_max, target_rpe, progression_step_kg, created_at) '
              'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
              [peId, psId, ex['exerciseId'], ex['exerciseNameSnapshot'], ex['exerciseOrder'] ?? 0, ex['targetSets'], ex['targetRepsMin'], ex['targetRepsMax'], ex['targetRpe'], ex['progressionStepKg'], now],
            );
          }
        }
        ids.add(id);
      }

      return jsonResponse({'synced': ids.length, 'ids': ids, 'syncedAt': now});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── POST /programs ────────────────────────────────────────────────────────

  Future<Response> pushProgram(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;
      final body = await readJsonBody(request);

      final id = _resolveScopedId('programs', userId, body['localId']);
      final now = dbNow();

      _db.raw.execute(
        'INSERT OR REPLACE INTO programs (id, user_id, local_id, name, description, days_per_week, deload_every_n_weeks, progression_step_kg, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM programs WHERE id=?), ?), ?)',
        [
          id, userId, body['localId'],
          body['name'] ?? 'Programme',
          body['description'],
          body['daysPerWeek'],
          body['deloadEveryNWeeks'],
          body['progressionStepKg'],
          id, now, now,
        ],
      );

      _db.raw.execute('DELETE FROM program_sessions WHERE program_id=?', [id]);
      final sessions = (body['sessions'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      for (final s in sessions) {
        final psId = _uuid.v4();
        _db.raw.execute(
          'INSERT INTO program_sessions (id, program_id, name, session_order, day_of_week, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?)',
          [psId, id, s['name'] ?? 'Séance', s['sessionOrder'] ?? 0, s['dayOfWeek'], now],
        );

        final exercises = (s['exercises'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        for (final ex in exercises) {
          final peId = _uuid.v4();
          _db.raw.execute(
            'INSERT INTO program_exercises (id, program_session_id, exercise_id, exercise_name_snapshot, exercise_order, target_sets, target_reps_min, target_reps_max, target_rpe, progression_step_kg, created_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [peId, psId, ex['exerciseId'], ex['exerciseNameSnapshot'], ex['exerciseOrder'] ?? 0, ex['targetSets'], ex['targetRepsMin'], ex['targetRepsMax'], ex['targetRpe'], ex['progressionStepKg'], now],
          );
        }
      }

      return jsonResponse({'id': id, 'syncedAt': now});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // localId est l'id SQLite local du device (non globalement unique) ; on
  // résout l'UUID backend via (user_id, local_id) avant suppression.
  Future<Response> deleteProgram(Request request, String localId) async {
    try {
      final session = requireAuth(request, _repo);
      _db.raw.execute(
        'DELETE FROM programs WHERE user_id=? AND local_id=?',
        [session.user.id, localId],
      );
      return Response(204);
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── POST /session-templates/batch ─────────────────────────────────────────

  Future<Response> pushSessionTemplateBatch(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;
      final body = await readJsonBody(request);
      final items = (body['templates'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      final now = dbNow();
      final ids = <String>[];

      for (final item in items) {
        final localId = item['localId'] ?? item['local_id'];
        String id;
        if (localId != null) {
          final existing = _db.raw.select(
            'SELECT id FROM session_templates WHERE user_id=? AND local_id=? LIMIT 1',
            [userId, localId],
          );
          id = existing.isNotEmpty ? existing.first['id'] as String : _uuid.v4();
        } else {
          id = _uuid.v4();
        }

        _db.raw.execute(
          'INSERT OR REPLACE INTO session_templates (id, user_id, local_id, name, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, COALESCE((SELECT created_at FROM session_templates WHERE id=?), ?), ?)',
          [id, userId, localId, item['name'] ?? 'Séance', id, now, now],
        );

        _db.raw.execute('DELETE FROM session_template_exercises WHERE session_template_id=?', [id]);
        final exercises = (item['exercises'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        for (final ex in exercises) {
          final teId = _uuid.v4();
          _db.raw.execute(
            'INSERT INTO session_template_exercises (id, session_template_id, exercise_id, exercise_name_snapshot, display_order, created_at) '
            'VALUES (?, ?, ?, ?, ?, ?)',
            [teId, id, ex['exerciseId'], ex['exerciseNameSnapshot'], ex['displayOrder'] ?? 0, now],
          );
        }
        ids.add(id);
      }

      return jsonResponse({'synced': ids.length, 'ids': ids, 'syncedAt': now});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── DELETE /session-templates/<localId> ───────────────────────────────────
  // localId est l'id SQLite local du device (non globalement unique) ; on
  // résout l'UUID backend via (user_id, local_id) avant suppression.

  Future<Response> deleteSessionTemplate(Request request, String localId) async {
    try {
      final session = requireAuth(request, _repo);
      _db.raw.execute(
        'DELETE FROM session_templates WHERE user_id=? AND local_id=?',
        [session.user.id, localId],
      );
      return Response(204);
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── POST /weight-history/batch ────────────────────────────────────────────

  Future<Response> pushWeightBatch(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;
      final body = await readJsonBody(request);
      final entries = (body['entries'] as List?)?.cast<Map<String, dynamic>>() ?? [];

      for (final e in entries) {
        final localId = e['localId'] ?? e['local_id'] ?? e['id'];
        final id = _resolveScopedId('weight_history', userId, localId);
        final now = dbNow();
        _db.raw.execute(
          'INSERT OR REPLACE INTO weight_history (id, user_id, local_id, weight_kg, effective_date, notes, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM weight_history WHERE id=?), ?))',
          [id, userId, localId, e['weightKg'] ?? 0, e['effectiveDate'] ?? now.substring(0, 10), e['notes'], id, e['createdAt'] ?? now],
        );
      }

      return jsonResponse({'synced': entries.length, 'syncedAt': dbNow()});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── POST /body-measurements/batch ─────────────────────────────────────────

  Future<Response> pushMeasurementBatch(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;
      final body = await readJsonBody(request);
      final entries = (body['entries'] as List?)?.cast<Map<String, dynamic>>() ?? [];

      for (final e in entries) {
        final localId = e['localId'] ?? e['local_id'] ?? e['id'];
        final id = _resolveScopedId('body_measurements', userId, localId);
        final now = dbNow();
        _db.raw.execute(
          'INSERT OR REPLACE INTO body_measurements (id, user_id, local_id, measurement_type, value_cm, measured_date, notes, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM body_measurements WHERE id=?), ?))',
          [id, userId, localId, e['measurementType'] ?? 'unknown', e['valueCm'] ?? 0, e['measuredDate'] ?? now.substring(0, 10), e['notes'], id, e['createdAt'] ?? now],
        );
      }

      return jsonResponse({'synced': entries.length, 'syncedAt': dbNow()});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── PUT /me/gamification ──────────────────────────────────────────────────

  Future<Response> pushGamification(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;
      final body = await readJsonBody(request);
      final now = dbNow();

      _db.raw.execute(
        'INSERT OR REPLACE INTO gamification_profiles (user_id, total_xp, total_workouts, total_volume_kg, total_sets, current_streak, longest_streak, total_prs_ever, last_workout_date, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          userId,
          body['totalXp'] ?? 0,
          body['totalWorkouts'] ?? 0,
          body['totalVolumeKg'] ?? 0,
          body['totalSets'] ?? 0,
          body['currentStreak'] ?? 0,
          body['longestStreak'] ?? 0,
          body['totalPrsEver'] ?? 0,
          body['lastWorkoutDate'],
          now,
        ],
      );

      final achievements = (body['achievements'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      for (final a in achievements) {
        _db.raw.execute(
          'INSERT OR IGNORE INTO achievements (id, user_id, unlocked_at) VALUES (?, ?, ?)',
          [a['id'], userId, a['unlockedAt'] ?? now],
        );
      }

      final goals = (body['goals'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      for (final g in goals) {
        final id = g['id']?.toString() ?? _uuid.v4();
        _db.raw.execute(
          'INSERT OR REPLACE INTO goals (id, user_id, type, title, target, current_value, start_date, due_date, status, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM goals WHERE id=?), ?), ?)',
          [id, userId, g['type'] ?? 'custom', g['title'] ?? 'Objectif', g['target'] ?? 0, g['currentValue'] ?? 0, g['startDate'] ?? now.substring(0, 10), g['dueDate'], g['status'] ?? 'active', id, now, now],
        );
      }

      return jsonResponse({'syncedAt': now});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── PUT /me/community-profile ─────────────────────────────────────────────

  Future<Response> pushCommunityProfile(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;
      final body = await readJsonBody(request);
      final now = dbNow();

      _db.raw.execute(
        'INSERT OR REPLACE INTO community_profiles (user_id, display_name, avatar_preset_id, level, tier, total_xp, current_streak, total_workouts, total_volume_kg, total_prs, badge_ids, privacy_json, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          userId,
          body['displayName'] ?? session.user.displayName,
          body['avatarPresetId'] ?? 'warrior',
          body['level'] ?? 1,
          body['tier'] ?? 'Rookie',
          body['totalXp'] ?? 0,
          body['currentStreak'] ?? 0,
          body['totalWorkouts'] ?? 0,
          body['totalVolumeKg'] ?? 0,
          body['totalPrs'] ?? 0,
          body['badgeIds'] ?? '[]',
          // Le client envoie déjà privacyJson comme une chaîne JSON
          // pré-sérialisée (CommunityPrivacySettings.toJson()) — la
          // ré-encoder avec jsonEncode() la double-encoderait (une chaîne
          // JSON contenant une chaîne JSON échappée au lieu de l'objet).
          body['privacyJson'] is String
              ? body['privacyJson'] as String
              : jsonEncode(body['privacyJson'] ?? {}),
          now,
        ],
      );

      return jsonResponse({'syncedAt': now});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── POST /community/shares/workout ────────────────────────────────────────

  Future<Response> pushWorkoutShare(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;
      final body = await readJsonBody(request);

      final id = body['id']?.toString() ?? _uuid.v4();
      final now = dbNow();

      _db.raw.execute(
        'INSERT OR REPLACE INTO workout_shares (id, owner_user_id, workout_id, title, snapshot_json, visibility, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM workout_shares WHERE id=?), ?))',
        [id, userId, body['workoutId'], body['title'] ?? 'Séance', jsonEncode(body['snapshotJson'] ?? {}), body['visibility'] ?? 'friendsOnly', id, now],
      );

      return jsonResponse({'id': id, 'syncedAt': now});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── GET /community/users/lookup ─────────────────────────────────────────

  Future<Response> lookupUserByDisplayName(Request request) async {
    try {
      requireAuth(request, _repo);
      final displayName = request.url.queryParameters['displayName']?.trim() ?? '';
      if (displayName.isEmpty) {
        throw ApiException('displayName is required.', statusCode: 400);
      }
      final user = _repo.findByDisplayName(displayName);
      if (user == null) throw ApiException('User not found.', statusCode: 404);
      return jsonResponse({'id': user.id, 'displayName': user.displayName});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── POST /community/relations ─────────────────────────────────────────────

  Future<Response> pushRelation(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final userIdA = session.user.id;
      final body = await readJsonBody(request);
      final userIdB = body['userIdB']?.toString() ?? '';
      if (userIdB.isEmpty) throw ApiException('userIdB is required.', statusCode: 400);
      if (userIdA == userIdB) throw ApiException('Cannot add yourself.', statusCode: 400);

      // Verify target user exists
      final targetRows = _db.raw.select('SELECT id FROM users WHERE id=? AND is_deleted=0', [userIdB]);
      if (targetRows.isEmpty) throw ApiException('User not found.', statusCode: 404);

      final now = dbNow();
      final status = body['status']?.toString() ?? 'friend';
      final requestStatus = body['requestStatus']?.toString() ?? 'pending';

      final existing = _db.raw.select(
        'SELECT id, request_status FROM social_relations '
        'WHERE (user_id_a=? AND user_id_b=?) OR (user_id_a=? AND user_id_b=?)',
        [userIdA, userIdB, userIdB, userIdA],
      );

      if (existing.isNotEmpty) {
        final existingStatus = existing.first['request_status'] as String? ?? 'pending';
        if (existingStatus == 'accepted') {
          throw ApiException('Vous êtes déjà amis.', statusCode: 409);
        }
        if (existingStatus == 'pending') {
          throw ApiException('Une demande est déjà en attente.', statusCode: 409);
        }
      }

      final id = _uuid.v4();

      _db.raw.execute(
        'INSERT OR REPLACE INTO social_relations (id, user_id_a, user_id_b, status, request_status, notes, is_public, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          id, userIdA, userIdB, status, requestStatus,
          body['notes'], (body['isPublic'] == true) ? 1 : 0,
          now, now,
        ],
      );

      return jsonResponse({'id': id, 'status': status, 'requestStatus': requestStatus, 'syncedAt': now});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── PATCH /community/relations/<id> ───────────────────────────────────────

  Future<Response> patchRelation(Request request, String relationId) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;
      final body = await readJsonBody(request);

      final rows = _db.raw.select(
        'SELECT * FROM social_relations WHERE id=?',
        [relationId],
      );
      if (rows.isEmpty) throw ApiException('Relation not found.', statusCode: 404);
      final rel = rows.first;

      // Only userIdB (the recipient) can accept/decline
      if (rel['user_id_b'] != userId) {
        throw ApiException('Forbidden.', statusCode: 403);
      }

      final newRequestStatus = body['requestStatus']?.toString();
      if (newRequestStatus == null ||
          !['accepted', 'declined'].contains(newRequestStatus)) {
        throw ApiException('requestStatus must be accepted or declined.', statusCode: 400);
      }

      final now = dbNow();
      _db.raw.execute(
        'UPDATE social_relations SET request_status=?, updated_at=? WHERE id=?',
        [newRequestStatus, now, relationId],
      );

      return jsonResponse({'id': relationId, 'requestStatus': newRequestStatus, 'updatedAt': now});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Future<Response> getRelations(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;

      final rows = _db.raw.select(
        'SELECT * FROM social_relations WHERE user_id_a=? OR user_id_b=? ORDER BY updated_at DESC',
        [userId, userId],
      );

      Map<String, dynamic> _profile(String uid) {
        final cp = _db.raw.select(
          'SELECT display_name, avatar_preset_id, level, tier, total_xp, current_streak, '
          'total_workouts, total_volume_kg, total_prs, badge_ids, privacy_json '
          'FROM community_profiles WHERE user_id=?',
          [uid],
        );
        final up = _db.raw.select(
          'SELECT display_name FROM user_profiles WHERE user_id=?',
          [uid],
        );
        // user_profiles.display_name est toujours à jour (réécrit en lockstep
        // par upsertProfile()/AuthController.updateDisplayName()) —
        // community_profiles.display_name est un instantané pris à la
        // création du profil communauté, jamais resynchronisé si l'utilisateur
        // renomme son pseudo ensuite dans "Mon compte". Sans cette priorité,
        // les amis voient un pseudo obsolète et la recherche par pseudo (qui
        // interroge le pseudo réel du compte) ne trouve jamais ce nom affiché.
        final displayName = (up.isNotEmpty ? up.first['display_name'] : null)
            ?? (cp.isNotEmpty ? cp.first['display_name'] : null)
            ?? uid;
        return {
          'userId': uid,
          'displayName': displayName,
          'avatarPresetId': cp.isNotEmpty ? (cp.first['avatar_preset_id'] ?? 'warrior') : 'warrior',
          'level': cp.isNotEmpty ? (cp.first['level'] ?? 1) : 1,
          'tier': cp.isNotEmpty ? (cp.first['tier'] ?? 'Rookie') : 'Rookie',
          'totalXp': cp.isNotEmpty ? (cp.first['total_xp'] ?? 0) : 0,
          'currentStreak': cp.isNotEmpty ? (cp.first['current_streak'] ?? 0) : 0,
          'totalWorkouts': cp.isNotEmpty ? (cp.first['total_workouts'] ?? 0) : 0,
          'totalVolumeKg': cp.isNotEmpty ? (cp.first['total_volume_kg'] ?? 0) : 0,
          'totalPrs': cp.isNotEmpty ? (cp.first['total_prs'] ?? 0) : 0,
          'badgeIds': cp.isNotEmpty ? (cp.first['badge_ids'] ?? '[]') : '[]',
          'privacyJson': cp.isNotEmpty ? (cp.first['privacy_json'] ?? '{}') : '{}',
        };
      }

      return jsonResponse({
        'relations': rows.map((r) {
          final uidA = r['user_id_a'] as String?;
          final uidB = r['user_id_b'] as String?;
          final otherUid = uidA == userId ? uidB : uidA;
          return {
            'id': r['id'],
            'userIdA': uidA,
            'userIdB': uidB,
            'status': r['status'],
            'requestStatus': r['request_status'] ?? 'pending',
            'notes': r['notes'],
            'isPublic': (r['is_public'] as int? ?? 0) != 0,
            'createdAt': r['created_at'],
            'updatedAt': r['updated_at'],
            'otherProfile': otherUid != null ? _profile(otherUid) : null,
          };
        }).toList(),
      });
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── DELETE /community/relations/<id> ─────────────────────────────────────

  Future<Response> deleteRelation(Request request, String relationId) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;

      final rows = _db.raw.select(
        'SELECT id FROM social_relations WHERE id=? AND (user_id_a=? OR user_id_b=?)',
        [relationId, userId, userId],
      );
      if (rows.isEmpty) throw ApiException('Relation not found.', statusCode: 404);

      _db.raw.execute('DELETE FROM social_relations WHERE id=?', [relationId]);
      return jsonResponse({'deleted': relationId});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── POST /community/shares/program ────────────────────────────────────────

  Future<Response> pushProgramShare(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;
      final body = await readJsonBody(request);

      final id = body['id']?.toString() ?? _uuid.v4();
      final now = dbNow();

      _db.raw.execute(
        'INSERT OR REPLACE INTO program_shares (id, owner_user_id, program_id, title, snapshot_json, created_at) '
        'VALUES (?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM program_shares WHERE id=?), ?))',
        [id, userId, body['programId'], body['title'] ?? 'Programme', jsonEncode(body['snapshotJson'] ?? {}), id, now],
      );

      return jsonResponse({'id': id, 'syncedAt': now});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── GET /community/friends/shares ────────────────────────────────────────

  Future<Response> getFriendsShares(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;

      final relations = _db.raw.select(
        "SELECT user_id_a, user_id_b FROM social_relations WHERE (user_id_a=? OR user_id_b=?) AND request_status='accepted'",
        [userId, userId],
      );

      final friendIds = <String>[];
      for (final r in relations) {
        final a = r['user_id_a'] as String;
        final b = r['user_id_b'] as String;
        friendIds.add(a == userId ? b : a);
      }

      if (friendIds.isEmpty) {
        return jsonResponse({'workoutShares': [], 'programShares': []});
      }

      // Récupère le statut de relation pour chaque ami
      final Map<String, String> friendRelationStatus = {};
      for (final friendId in friendIds) {
        final rel = _db.raw.select(
          "SELECT status FROM social_relations WHERE ((user_id_a=? AND user_id_b=?) OR (user_id_a=? AND user_id_b=?)) AND request_status='accepted' LIMIT 1",
          [userId, friendId, friendId, userId],
        );
        if (rel.isNotEmpty) {
          friendRelationStatus[friendId] = rel.first['status'] as String? ?? 'friend';
        }
      }

      // Filtre les workout_shares selon la visibilité et le type de relation
      bool _canSeeWorkoutShare(String ownerUserId, String visibility) {
        if (visibility == 'private') return false;
        if (visibility == 'public' || visibility == 'allRelations') return true;
        final status = friendRelationStatus[ownerUserId] ?? 'friend';
        return switch (visibility) {
          'friendsOnly' => status == 'friend',
          'rivals' => status == 'rival',
          'programPartners' => status == 'programPartner',
          _ => true,
        };
      }

      final placeholders = List.filled(friendIds.length, '?').join(',');

      final allWorkoutShares = _db.raw.select(
        // COALESCE(up.display_name, cp.display_name) : user_profiles est
        // toujours à jour, community_profiles peut être un pseudo obsolète
        // (jamais resynchronisé après un renommage dans "Mon compte").
        'SELECT ws.*, COALESCE(up.display_name, cp.display_name) as owner_display_name, '
        'cp.avatar_preset_id as owner_avatar '
        'FROM workout_shares ws '
        'LEFT JOIN community_profiles cp ON cp.user_id = ws.owner_user_id '
        'LEFT JOIN user_profiles up ON up.user_id = ws.owner_user_id '
        "WHERE ws.owner_user_id IN ($placeholders) "
        'ORDER BY ws.created_at DESC LIMIT 200',
        friendIds,
      );
      final workoutShares = allWorkoutShares.where((r) =>
        _canSeeWorkoutShare(r['owner_user_id'] as String, r['visibility'] as String? ?? 'friendsOnly')
      ).take(100).toList();

      final programShares = _db.raw.select(
        'SELECT ps.*, COALESCE(up.display_name, cp.display_name) as owner_display_name, '
        'cp.avatar_preset_id as owner_avatar '
        'FROM program_shares ps '
        'LEFT JOIN community_profiles cp ON cp.user_id = ps.owner_user_id '
        'LEFT JOIN user_profiles up ON up.user_id = ps.owner_user_id '
        "WHERE ps.owner_user_id IN ($placeholders) "
        'ORDER BY ps.created_at DESC LIMIT 50',
        friendIds,
      );

      return jsonResponse({
        'workoutShares': workoutShares.map((r) => {
          'id': r['id'],
          'ownerUserId': r['owner_user_id'],
          'ownerDisplayName': r['owner_display_name'] ?? r['owner_user_id'],
          'ownerAvatar': r['owner_avatar'] ?? 'warrior',
          'workoutId': r['workout_id'],
          'title': r['title'],
          'snapshotJson': jsonDecode(r['snapshot_json'] as String? ?? '{}'),
          'visibility': r['visibility'] ?? 'friendsOnly',
          'createdAt': r['created_at'],
          'challengeMessage': r['challenge_message'],
        }).toList(),
        'programShares': programShares.map((r) => {
          'id': r['id'],
          'ownerUserId': r['owner_user_id'],
          'ownerDisplayName': r['owner_display_name'] ?? r['owner_user_id'],
          'ownerAvatar': r['owner_avatar'] ?? 'warrior',
          'programId': r['program_id'],
          'title': r['title'],
          'snapshotJson': jsonDecode(r['snapshot_json'] as String? ?? '{}'),
          'createdAt': r['created_at'],
        }).toList(),
      });
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── GET /community/friends/<friendUserId>/exercise-stats ─────────────────
  //
  // Stats agrégées (meilleur 1RM estimé par exercice, volume par groupe
  // musculaire) pour un ami sur une période donnée. Accessible uniquement
  // si une relation acceptée existe entre l'appelant et friendUserId —
  // aucune donnée brute de séance n'est exposée, seulement les agrégats.

  Future<Response> getFriendExerciseStats(
      Request request, String friendUserId) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;

      final relation = _db.raw.select(
        "SELECT id FROM social_relations WHERE ((user_id_a=? AND user_id_b=?) OR (user_id_a=? AND user_id_b=?)) AND request_status='accepted' LIMIT 1",
        [userId, friendUserId, friendUserId, userId],
      );
      if (relation.isEmpty) {
        throw ApiException('Not authorized to view this athlete.', statusCode: 403);
      }

      final days = int.tryParse(
              request.url.queryParameters['days'] ?? '30') ??
          30;
      final since = DateTime.now()
          .toUtc()
          .subtract(Duration(days: days))
          .toIso8601String()
          .substring(0, 10);

      final rows = _db.raw.select(
        'SELECT COALESCE(e.name, we.exercise_name_snapshot) as exercise_name, '
        'COALESCE(e.muscle_group_name, we.muscle_group_name_snapshot) as muscle_group_name, '
        'ws.weight_kg as weight_kg, ws.reps as reps, COALESCE(ws.volume_reps, ws.reps) as volume_reps '
        'FROM workouts w '
        'JOIN workout_exercises we ON we.workout_id = w.id '
        'JOIN workout_sets ws ON ws.workout_exercise_id = we.id '
        'LEFT JOIN exercises e ON e.id = we.exercise_id '
        'WHERE w.user_id=? AND w.workout_date >= ?',
        [friendUserId, since],
      );

      // Regroupement insensible à la casse (deux comptes peuvent nommer un
      // exercice custom différemment en casse) tout en conservant le premier
      // libellé rencontré pour l'affichage.
      final best1RmByExerciseKey = <String, double>{};
      final exerciseDisplayNames = <String, String>{};
      final volumeByMuscle = <String, double>{};

      for (final r in rows) {
        final rawExerciseName = (r['exercise_name'] as String?)?.trim();
        final exerciseKey = rawExerciseName?.toLowerCase();
        final weight = (r['weight_kg'] as num?)?.toDouble() ?? 0;
        final reps = (r['reps'] as num?)?.toInt() ?? 0;
        final volumeReps = (r['volume_reps'] as num?)?.toInt() ?? reps;
        if (weight <= 0 || reps <= 0) continue;

        final estimated1Rm = weight * (1 + reps / 30.0);
        if (exerciseKey != null && exerciseKey.isNotEmpty) {
          exerciseDisplayNames.putIfAbsent(exerciseKey, () => rawExerciseName!);
          final current = best1RmByExerciseKey[exerciseKey];
          if (current == null || estimated1Rm > current) {
            best1RmByExerciseKey[exerciseKey] = estimated1Rm;
          }
        }

        final muscleGroup = (r['muscle_group_name'] as String?)?.trim();
        if (muscleGroup != null && muscleGroup.isNotEmpty) {
          volumeByMuscle[muscleGroup] =
              (volumeByMuscle[muscleGroup] ?? 0) + weight * volumeReps;
        }
      }

      return jsonResponse({
        'friendUserId': friendUserId,
        'sinceDate': since,
        'exercises': best1RmByExerciseKey.entries
            .map((e) => {
                  'name': exerciseDisplayNames[e.key] ?? e.key,
                  'best1RmKg': e.value,
                })
            .toList(),
        'muscles': volumeByMuscle.entries
            .map((e) => {'name': e.key, 'volumeKg': e.value})
            .toList(),
      });
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── GET /community/relations/<relationUserId>/session-detail ─────────────
  //
  // Dernières séances détaillées (poids/reps par série) d'une relation
  // acceptée. Contrairement à getFriendExerciseStats (agrégats, ouvert à
  // toute relation acceptée), ceci expose des données brutes de séance —
  // en plus de la relation acceptée, il faut donc que le propriétaire ait
  // explicitement autorisé ce type de relation via
  // CommunityPrivacySettings.sessionDetailVisibleTo (stocké dans
  // community_profiles.privacy_json), sinon 403.

  Future<Response> getRelationSessionDetail(
      Request request, String relationUserId) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;

      final relationRows = _db.raw.select(
        "SELECT status FROM social_relations WHERE ((user_id_a=? AND user_id_b=?) OR (user_id_a=? AND user_id_b=?)) AND request_status='accepted' LIMIT 1",
        [userId, relationUserId, relationUserId, userId],
      );
      if (relationRows.isEmpty) {
        throw ApiException('Not authorized to view this athlete.', statusCode: 403);
      }
      final relationStatus = relationRows.first['status'] as String;

      final profileRows = _db.raw.select(
        'SELECT display_name, privacy_json FROM community_profiles WHERE user_id=? LIMIT 1',
        [relationUserId],
      );
      if (profileRows.isEmpty) {
        throw ApiException('Not authorized to view this athlete.', statusCode: 403);
      }
      // user_profiles.display_name est toujours à jour (cf. getRelations) —
      // community_profiles.display_name reste utilisé pour l'autorisation
      // (privacy_json), mais pas comme source du nom affiché.
      final userProfileRows = _db.raw.select(
        'SELECT display_name FROM user_profiles WHERE user_id=? LIMIT 1',
        [relationUserId],
      );
      final displayName = (userProfileRows.isNotEmpty ? userProfileRows.first['display_name'] as String? : null)
          ?? profileRows.first['display_name'] as String?
          ?? 'Athlète';

      var allowedRelations = const <dynamic>[];
      try {
        final privacyRaw = profileRows.first['privacy_json'] as String? ?? '{}';
        var decoded = jsonDecode(privacyRaw);
        if (decoded is String) decoded = jsonDecode(decoded);
        if (decoded is Map<String, dynamic>) {
          allowedRelations =
              decoded['sessionDetailVisibleTo'] as List<dynamic>? ?? const [];
        }
      } catch (_) {
        // privacy_json corrompu — on retombe sur "rien d'autorisé" (fail-closed).
      }
      if (!allowedRelations.contains(relationStatus)) {
        throw ApiException('Not authorized to view this athlete.', statusCode: 403);
      }

      final workoutRows = _db.raw.select(
        "SELECT id, workout_date FROM workouts WHERE user_id=? AND end_time IS NOT NULL ORDER BY workout_date DESC LIMIT 3",
        [relationUserId],
      );

      final recentWorkouts = <Map<String, dynamic>>[];
      for (final w in workoutRows) {
        final workoutId = w['id'] as String;
        final exerciseRows = _db.raw.select(
          'SELECT we.id, we.exercise_order, COALESCE(we.exercise_name_snapshot, e.name, we.exercise_id) as name, '
          'ws.set_number, ws.weight_kg, ws.reps, ws.rpe '
          'FROM workout_exercises we '
          'LEFT JOIN exercises e ON e.id = we.exercise_id '
          'LEFT JOIN workout_sets ws ON ws.workout_exercise_id = we.id '
          'WHERE we.workout_id=? ORDER BY we.exercise_order, ws.set_number',
          [workoutId],
        );

        // Regroupe par workout_exercise (we.id) — un exercice peut apparaître
        // deux fois dans la même séance (ex: superset), il ne faut donc pas
        // dédupliquer par nom (même logique que getAthleteDetail côté coach).
        final exercisesById = <String, Map<String, dynamic>>{};
        final exerciseOrder = <String>[];
        for (final e in exerciseRows) {
          final weId = e['id'] as String;
          if (!exercisesById.containsKey(weId)) {
            exerciseOrder.add(weId);
            exercisesById[weId] = {
              'name': e['name'] as String? ?? 'Exercice',
              'sets': <Map<String, dynamic>>[],
            };
          }
          final weight = (e['weight_kg'] as num?)?.toDouble();
          final reps = e['reps'] as int?;
          if (weight != null && reps != null) {
            (exercisesById[weId]!['sets'] as List<Map<String, dynamic>>).add({
              'setNumber': e['set_number'],
              'weightKg': weight,
              'reps': reps,
              'rpe': (e['rpe'] as num?)?.toDouble(),
            });
          }
        }
        final exercises = exerciseOrder.map((id) => exercisesById[id]!).toList();

        recentWorkouts.add({
          'workoutId': workoutId,
          'workoutDate': w['workout_date'],
          'exercises': exercises,
        });
      }

      return jsonResponse({
        'athleteUserId': relationUserId,
        'displayName': displayName,
        'recentWorkouts': recentWorkouts,
      });
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── DELETE /community/shares/workout/:shareId ────────────────────────────

  Future<Response> deleteWorkoutShare(Request request, String shareId) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;
      _db.raw.execute(
        'DELETE FROM workout_shares WHERE id=? AND owner_user_id=?',
        [shareId, userId],
      );
      return jsonResponse({'deleted': true});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── DELETE /community/shares/program/:shareId ────────────────────────────

  Future<Response> deleteProgramShare(Request request, String shareId) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;
      _db.raw.execute(
        'DELETE FROM program_shares WHERE id=? AND owner_user_id=?',
        [shareId, userId],
      );
      return jsonResponse({'deleted': true});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Map<String, dynamic> _exerciseRowToJson(Map<String, Object?> row) => {
    'id': row['id'],
    'localId': row['local_id'],
    'name': row['name'],
    'muscleGroupName': row['muscle_group_name'],
    'exerciseType': row['exercise_type'],
    'isUnilateral': (row['is_unilateral'] as int? ?? 0) == 1,
    'equipment': row['equipment'],
    'description': row['description'],
    'performanceType': row['performance_type'],
    'createdAt': row['created_at'],
    'updatedAt': row['updated_at'],
  };
}
