import 'dart:convert';
import 'dart:math';

import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../repositories/user_repository.dart';
import '../utils/api_exception.dart';
import '../utils/auth_helper.dart';
import '../utils/http_json.dart';

class CoachRoutes {
  CoachRoutes({required UserRepository userRepository, required AppDatabase database})
      : _repo = userRepository,
        _db = database;

  final UserRepository _repo;
  final AppDatabase _db;
  final _uuid = const Uuid();
  final _random = Random.secure();

  static const _codeChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

  String _generateCode() =>
      List.generate(8, (_) => _codeChars[_random.nextInt(_codeChars.length)]).join();

  // ── Invite codes ──────────────────────────────────────────────────────────

  Future<Response> generateInviteCode(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      requireCoach(session);
      final coachUserId = session.user.id;
      final now = dbNow();
      final code = _generateCode();
      final expiresAt = DateTime.now().add(const Duration(days: 7)).toUtc().toIso8601String();

      _db.raw.execute(
        'INSERT OR REPLACE INTO coach_invite_codes (code, coach_user_id, expires_at, created_at) VALUES (?, ?, ?, ?)',
        [code, coachUserId, expiresAt, now],
      );

      return jsonResponse({'code': code, 'expiresAt': expiresAt, 'coachUserId': coachUserId});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Future<Response> redeemCode(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final athleteUserId = session.user.id;
      final body = await readJsonBody(request);
      final code = body['code']?.toString().trim().toUpperCase() ?? '';
      if (code.isEmpty) throw ApiException('code is required.', statusCode: 400);

      final rows = _db.raw.select(
        "SELECT * FROM coach_invite_codes WHERE code=? AND used_by_user_id IS NULL AND expires_at > ?",
        [code, dbNow()],
      );
      if (rows.isEmpty) throw ApiException('Invalid or expired code.', statusCode: 404);

      final codeRow = rows.first;
      final coachUserId = codeRow['coach_user_id'] as String;

      if (coachUserId == athleteUserId) {
        throw ApiException('You cannot redeem your own code.', statusCode: 400);
      }

      final now = dbNow();
      final linkId = _uuid.v4();

      _db.raw.execute(
        'UPDATE coach_invite_codes SET used_by_user_id=? WHERE code=?',
        [athleteUserId, code],
      );

      _db.raw.execute(
        'INSERT OR REPLACE INTO coach_athlete_links (id, coach_user_id, athlete_user_id, status, linked_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
        [linkId, coachUserId, athleteUserId, 'active', now, now],
      );

      return jsonResponse({
        'link': {
          'id': linkId,
          'coachUserId': coachUserId,
          'athleteUserId': athleteUserId,
          'linkedAt': now,
          'status': 'active',
          'updatedAt': now,
        },
      });
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── Athletes list ─────────────────────────────────────────────────────────

  Future<Response> getAthletes(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      requireCoach(session);
      final coachUserId = session.user.id;

      final links = _db.raw.select(
        "SELECT athlete_user_id FROM coach_athlete_links WHERE coach_user_id=? AND status='active'",
        [coachUserId],
      );

      final athletes = <Map<String, dynamic>>[];
      for (final link in links) {
        final athleteId = link['athlete_user_id'] as String;
        final profileRows = _db.raw.select(
          'SELECT display_name FROM user_profiles WHERE user_id=? LIMIT 1',
          [athleteId],
        );
        final displayName = profileRows.isEmpty ? 'Utilisateur' : profileRows.first['display_name'] as String;

        final lastWorkoutRows = _db.raw.select(
          "SELECT workout_date FROM workouts WHERE user_id=? AND end_time IS NOT NULL ORDER BY workout_date DESC LIMIT 1",
          [athleteId],
        );
        final lastWorkoutDate = lastWorkoutRows.isEmpty ? null : lastWorkoutRows.first['workout_date'] as String?;

        final programRows = _db.raw.select(
          "SELECT p.name FROM coach_program_assignments cpa JOIN programs p ON p.id=cpa.program_id WHERE cpa.athlete_user_id=? AND cpa.status='active' LIMIT 1",
          [athleteId],
        );
        final activeProgramName = programRows.isEmpty ? null : programRows.first['name'] as String?;

        athletes.add({
          'athleteUserId': athleteId,
          'displayName': displayName,
          'lastWorkoutDate': lastWorkoutDate,
          'activeProgramName': activeProgramName,
        });
      }

      return jsonResponse({'athletes': athletes});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Future<Response> removeAthlete(Request request, String athleteUserId) async {
    try {
      final session = requireAuth(request, _repo);
      requireCoach(session);
      final coachUserId = session.user.id;

      _db.raw.execute(
        "UPDATE coach_athlete_links SET status='revoked', updated_at=? WHERE coach_user_id=? AND athlete_user_id=?",
        [dbNow(), coachUserId, athleteUserId],
      );

      return jsonResponse({'ok': true});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── Athlete detail ────────────────────────────────────────────────────────

  Future<Response> getAthleteDetail(Request request, String athleteUserId) async {
    try {
      final session = requireAuth(request, _repo);
      requireCoach(session);
      final coachUserId = session.user.id;

      final linkRows = _db.raw.select(
        "SELECT id FROM coach_athlete_links WHERE coach_user_id=? AND athlete_user_id=? AND status='active' LIMIT 1",
        [coachUserId, athleteUserId],
      );
      if (linkRows.isEmpty) throw ApiException('Athlete not found.', statusCode: 404);

      final profileRows = _db.raw.select(
        'SELECT display_name FROM user_profiles WHERE user_id=? LIMIT 1',
        [athleteUserId],
      );
      final displayName = profileRows.isEmpty ? 'Utilisateur' : profileRows.first['display_name'] as String;

      final workoutRows = _db.raw.select(
        "SELECT id, workout_date FROM workouts WHERE user_id=? AND end_time IS NOT NULL ORDER BY workout_date DESC LIMIT 5",
        [athleteUserId],
      );

      final recentWorkouts = <Map<String, dynamic>>[];
      for (final w in workoutRows) {
        final workoutId = w['id'] as String;
        final exerciseRows = _db.raw.select(
          'SELECT we.id, COALESCE(we.exercise_name_snapshot, e.name, we.exercise_id) as name, ws.weight_kg, ws.reps '
          'FROM workout_exercises we '
          'LEFT JOIN exercises e ON e.id = we.exercise_id '
          'LEFT JOIN workout_sets ws ON ws.workout_exercise_id = we.id '
          'WHERE we.workout_id=? ORDER BY we.exercise_order, ws.weight_kg DESC',
          [workoutId],
        );

        // Top set par exercice
        final seen = <String>{};
        final exercises = <Map<String, dynamic>>[];
        for (final e in exerciseRows) {
          final name = e['name'] as String? ?? 'Exercice';
          if (!seen.contains(name)) {
            seen.add(name);
            final weight = (e['weight_kg'] as num?)?.toDouble();
            final reps = e['reps'] as int?;
            String? topSet;
            if (weight != null && reps != null && weight > 0) {
              topSet = '${weight % 1 == 0 ? weight.toInt() : weight}kg x $reps';
            }
            exercises.add({'name': name, 'topSet': topSet});
          }
        }

        // Note du coach sur ce workout
        final noteRows = _db.raw.select(
          'SELECT note_text FROM coach_workout_notes WHERE coach_user_id=? AND workout_id=? LIMIT 1',
          [coachUserId, workoutId],
        );
        final coachNote = noteRows.isEmpty ? null : noteRows.first['note_text'] as String?;

        recentWorkouts.add({
          'workoutId': workoutId,
          'workoutDate': w['workout_date'],
          'exercises': exercises,
          'coachNote': coachNote,
        });
      }

      final programRows = _db.raw.select(
        "SELECT p.id, p.name FROM coach_program_assignments cpa JOIN programs p ON p.id=cpa.program_id WHERE cpa.athlete_user_id=? AND cpa.status='active' LIMIT 1",
        [athleteUserId],
      );
      final activeProgramName = programRows.isEmpty ? null : programRows.first['name'] as String?;
      final activeProgramId = programRows.isEmpty ? null : programRows.first['id'] as String?;

      return jsonResponse({
        'athleteUserId': athleteUserId,
        'displayName': displayName,
        'recentWorkouts': recentWorkouts,
        'activeProgramName': activeProgramName,
        'activeProgramId': activeProgramId,
      });
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── Workout notes ─────────────────────────────────────────────────────────

  Future<Response> saveNote(Request request, String athleteUserId, String workoutId) async {
    try {
      final session = requireAuth(request, _repo);
      requireCoach(session);
      final coachUserId = session.user.id;

      final body = await readJsonBody(request);
      final noteText = body['noteText']?.toString().trim() ?? '';
      if (noteText.isEmpty) throw ApiException('noteText is required.', statusCode: 400);

      final now = dbNow();
      final id = _uuid.v4();

      _db.raw.execute(
        'INSERT OR REPLACE INTO coach_workout_notes (id, coach_user_id, athlete_user_id, workout_id, note_text, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [id, coachUserId, athleteUserId, workoutId, noteText, now, now],
      );

      return jsonResponse({
        'id': id,
        'coachUserId': coachUserId,
        'athleteUserId': athleteUserId,
        'workoutId': workoutId,
        'noteText': noteText,
        'createdAt': now,
        'updatedAt': now,
      });
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── Program assignment ────────────────────────────────────────────────────

  Future<Response> assignProgram(Request request, String athleteUserId) async {
    try {
      final session = requireAuth(request, _repo);
      requireCoach(session);
      final coachUserId = session.user.id;

      final body = await readJsonBody(request);
      final programId = body['programId']?.toString() ?? '';
      if (programId.isEmpty) throw ApiException('programId is required.', statusCode: 400);

      final now = dbNow();
      final id = _uuid.v4();

      _db.raw.execute(
        'INSERT OR REPLACE INTO coach_program_assignments (id, coach_user_id, athlete_user_id, program_id, assigned_at, status) VALUES (?, ?, ?, ?, ?, ?)',
        [id, coachUserId, athleteUserId, programId, now, 'active'],
      );

      return jsonResponse({'assignmentId': id, 'programId': programId, 'assignedAt': now});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Future<Response> removeProgram(Request request, String athleteUserId) async {
    try {
      final session = requireAuth(request, _repo);
      requireCoach(session);
      final coachUserId = session.user.id;

      _db.raw.execute(
        "UPDATE coach_program_assignments SET status='removed' WHERE coach_user_id=? AND athlete_user_id=?",
        [coachUserId, athleteUserId],
      );

      return Response(204);
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── Public profile ────────────────────────────────────────────────────────

  Future<Response> upsertPublicProfile(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      requireCoach(session);
      final coachUserId = session.user.id;
      final displayName = session.profile?.displayName ?? 'Coach';

      final body = await readJsonBody(request);
      final now = dbNow();

      _db.raw.execute(
        'INSERT OR REPLACE INTO coach_public_profiles (coach_user_id, display_name, bio, speciality, location, languages, is_public, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM coach_public_profiles WHERE coach_user_id=?), ?), ?)',
        [
          coachUserId,
          displayName,
          body['bio'],
          body['speciality'],
          body['location'],
          jsonEncode(body['languages'] ?? []),
          (body['isPublic'] == true) ? 1 : 0,
          coachUserId,
          now,
          now,
        ],
      );

      final rows = _db.raw.select(
        'SELECT * FROM coach_public_profiles WHERE coach_user_id=? LIMIT 1',
        [coachUserId],
      );

      return jsonResponse(_profileRowToJson(rows.first));
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Future<Response> getPublicCoaches(Request request) async {
    try {
      requireAuth(request, _repo);

      final rows = _db.raw.select(
        'SELECT * FROM coach_public_profiles WHERE is_public=1 ORDER BY display_name ASC',
      );

      return jsonResponse({'coaches': rows.map(_profileRowToJson).toList()});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── Athlete side: revoke coach ────────────────────────────────────────────

  Future<Response> revokeCoach(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final athleteUserId = session.user.id;

      _db.raw.execute(
        "UPDATE coach_athlete_links SET status='revoked', updated_at=? WHERE athlete_user_id=? AND status='active'",
        [dbNow(), athleteUserId],
      );

      return Response(204);
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Map<String, dynamic> _profileRowToJson(Map<String, Object?> row) {
    return {
      'coachUserId': row['coach_user_id'],
      'displayName': row['display_name'],
      'bio': row['bio'],
      'speciality': row['speciality'],
      'location': row['location'],
      'languages': jsonDecode(row['languages'] as String? ?? '[]'),
      'isPublic': (row['is_public'] as int? ?? 0) == 1,
      'createdAt': row['created_at'],
      'updatedAt': row['updated_at'],
    };
  }
}
