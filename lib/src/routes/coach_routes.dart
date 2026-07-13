import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../repositories/user_repository.dart';
import '../utils/api_exception.dart';
import '../utils/auth_helper.dart';
import '../utils/http_json.dart';

class CoachRoutes {
  CoachRoutes({
    required UserRepository userRepository,
    required AppDatabase database,
    required String photosDir,
  })  : _repo = userRepository,
        _db = database,
        _photosDir = photosDir;

  final UserRepository _repo;
  final AppDatabase _db;
  final String _photosDir;
  final _uuid = const Uuid();
  final _random = Random.secure();

  static final _safeFilename = RegExp(r'^[a-zA-Z0-9_-]+\.jpg$');
  static const _maxPhotoBytes = 4 * 1024 * 1024;

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

      return jsonResponse({
        'code': code,
        'expiresAt': expiresAt,
        'coachUserId': coachUserId,
        'createdAt': now,
      });
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
          "SELECT program_name FROM coach_program_assignments WHERE coach_user_id=? AND athlete_user_id=? AND status='active' LIMIT 1",
          [coachUserId, athleteId],
        );
        final activeProgramName = programRows.isEmpty ? null : programRows.first['program_name'] as String?;

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
        // dédupliquer par nom.
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
        "SELECT id, program_name FROM coach_program_assignments WHERE coach_user_id=? AND athlete_user_id=? AND status='active' LIMIT 1",
        [coachUserId, athleteUserId],
      );
      final activeProgramName = programRows.isEmpty ? null : programRows.first['program_name'] as String?;
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
      final type = body['type']?.toString() ?? '';
      final name = body['name']?.toString() ?? '';
      if (type != 'builtin' && type != 'custom') {
        throw ApiException('type must be "builtin" or "custom".', statusCode: 400);
      }
      if (name.isEmpty) throw ApiException('name is required.', statusCode: 400);

      final code = body['code']?.toString();
      if (type == 'builtin' && (code == null || code.isEmpty)) {
        throw ApiException('code is required for a builtin program.', statusCode: 400);
      }

      final snapshot = body['snapshot'];
      if (type == 'custom' && snapshot == null) {
        throw ApiException('snapshot is required for a custom program.', statusCode: 400);
      }

      final now = dbNow();
      final id = _uuid.v4();

      _db.raw.execute(
        'INSERT OR REPLACE INTO coach_program_assignments '
        '(id, coach_user_id, athlete_user_id, program_type, program_code, program_name, snapshot_json, assigned_at, updated_at, status) '
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'active')",
        [
          id,
          coachUserId,
          athleteUserId,
          type,
          code,
          name,
          snapshot != null ? jsonEncode(snapshot) : null,
          now,
          now,
        ],
      );

      return jsonResponse({
        'id': id,
        'coachUserId': coachUserId,
        'athleteUserId': athleteUserId,
        'programType': type,
        'programCode': code,
        'programName': name,
        'assignedAt': now,
      });
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Future<Response> getAssignedProgram(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final athleteUserId = session.user.id;

      final rows = _db.raw.select(
        "SELECT * FROM coach_program_assignments WHERE athlete_user_id=? AND status='active' LIMIT 1",
        [athleteUserId],
      );
      if (rows.isEmpty) return jsonResponse({'assignment': null});

      final row = rows.first;
      return jsonResponse({
        'assignment': {
          'id': row['id'],
          'coachUserId': row['coach_user_id'],
          'athleteUserId': row['athlete_user_id'],
          'programType': row['program_type'],
          'programCode': row['program_code'],
          'programName': row['program_name'],
          'snapshot': row['snapshot_json'] != null ? jsonDecode(row['snapshot_json'] as String) : null,
          'assignedAt': row['assigned_at'],
          'updatedAt': row['updated_at'],
        },
      });
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
        'INSERT OR REPLACE INTO coach_public_profiles (coach_user_id, display_name, bio, speciality, location, languages, is_public, photo_url, whatsapp, instagram, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, (SELECT photo_url FROM coach_public_profiles WHERE coach_user_id=?), ?, ?, COALESCE((SELECT created_at FROM coach_public_profiles WHERE coach_user_id=?), ?), ?)',
        [
          coachUserId,
          displayName,
          body['bio'],
          body['speciality'],
          body['location'],
          jsonEncode(body['languages'] ?? []),
          (body['isPublic'] == true) ? 1 : 0,
          coachUserId,
          body['whatsapp'],
          body['instagram'],
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

  Future<Response> getMyPublicProfile(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      requireCoach(session);
      final coachUserId = session.user.id;

      final rows = _db.raw.select(
        'SELECT * FROM coach_public_profiles WHERE coach_user_id=? LIMIT 1',
        [coachUserId],
      );
      if (rows.isEmpty) return jsonResponse({'profile': null});

      return jsonResponse({'profile': _profileRowToJson(rows.first)});
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

  // ── Public profile photo ──────────────────────────────────────────────────

  Future<Response> uploadProfilePhoto(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      requireCoach(session);
      final coachUserId = session.user.id;
      final displayName = session.profile?.displayName ?? 'Coach';

      final body = await readJsonBody(request);
      final base64Image = body['imageBase64']?.toString() ?? '';
      if (base64Image.isEmpty) {
        throw ApiException('imageBase64 is required.', statusCode: 400);
      }

      final Uint8List bytes;
      try {
        bytes = base64Decode(base64Image);
      } on FormatException {
        throw ApiException('imageBase64 is not valid base64.', statusCode: 400);
      }
      if (bytes.length > _maxPhotoBytes) {
        throw ApiException('Image too large.', statusCode: 400);
      }

      final dir = Directory(_photosDir);
      dir.createSync(recursive: true);
      final filename = '$coachUserId.jpg';
      File(p.join(dir.path, filename)).writeAsBytesSync(bytes);

      final photoUrl = '/coach-photos/$filename';
      final now = dbNow();

      _db.raw.execute(
        'INSERT INTO coach_public_profiles (coach_user_id, display_name, languages, is_public, photo_url, created_at, updated_at) '
        "VALUES (?, ?, '[]', 0, ?, ?, ?) "
        'ON CONFLICT(coach_user_id) DO UPDATE SET photo_url=excluded.photo_url, updated_at=excluded.updated_at',
        [coachUserId, displayName, photoUrl, now, now],
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

  Response servePhoto(Request request, String filename) {
    if (!_safeFilename.hasMatch(filename)) {
      return errorResponse('Not found.', statusCode: 404);
    }
    final file = File(p.join(_photosDir, filename));
    if (!file.existsSync()) {
      return errorResponse('Not found.', statusCode: 404);
    }
    return Response.ok(
      file.readAsBytesSync(),
      headers: {'Content-Type': 'image/jpeg'},
    );
  }

  // ── Invite requests (athlète → coach depuis l'annuaire public) ───────────

  Future<Response> requestInvite(Request request, String coachUserId) async {
    try {
      final session = requireAuth(request, _repo);
      final athleteUserId = session.user.id;
      final athleteDisplayName = session.profile?.displayName ?? 'Athlète';

      if (coachUserId == athleteUserId) {
        throw ApiException('You cannot request yourself as coach.', statusCode: 400);
      }

      final existingCoachRows = _db.raw.select(
        "SELECT id FROM coach_athlete_links WHERE athlete_user_id=? AND status='active' LIMIT 1",
        [athleteUserId],
      );
      if (existingCoachRows.isNotEmpty) {
        throw ApiException('You already have a coach.', statusCode: 409);
      }

      final pendingRows = _db.raw.select(
        "SELECT id FROM coach_invite_requests WHERE athlete_user_id=? AND status='pending' LIMIT 1",
        [athleteUserId],
      );
      if (pendingRows.isNotEmpty) {
        throw ApiException('You already have a pending request.', statusCode: 409);
      }

      final now = dbNow();
      _db.raw.execute(
        'INSERT OR IGNORE INTO coach_invite_requests '
        '(id, coach_user_id, athlete_user_id, athlete_display_name, status, created_at, updated_at) '
        "VALUES (?, ?, ?, ?, 'pending', ?, ?)",
        [_uuid.v4(), coachUserId, athleteUserId, athleteDisplayName, now, now],
      );

      final rows = _db.raw.select(
        "SELECT * FROM coach_invite_requests WHERE coach_user_id=? AND athlete_user_id=? AND status='pending' LIMIT 1",
        [coachUserId, athleteUserId],
      );

      return jsonResponse(_requestRowToJson(rows.first));
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Future<Response> getInviteRequests(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      requireCoach(session);
      final coachUserId = session.user.id;

      final rows = _db.raw.select(
        "SELECT * FROM coach_invite_requests WHERE coach_user_id=? AND status='pending' ORDER BY created_at DESC",
        [coachUserId],
      );

      return jsonResponse({'requests': rows.map(_requestRowToJson).toList()});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Future<Response> approveInviteRequest(Request request, String requestId) async {
    try {
      final session = requireAuth(request, _repo);
      requireCoach(session);
      final coachUserId = session.user.id;

      final rows = _db.raw.select(
        "SELECT * FROM coach_invite_requests WHERE id=? AND coach_user_id=? AND status='pending' LIMIT 1",
        [requestId, coachUserId],
      );
      if (rows.isEmpty) throw ApiException('Request not found.', statusCode: 404);
      final athleteUserId = rows.first['athlete_user_id'] as String;

      final now = dbNow();
      final linkId = _uuid.v4();

      _db.raw.execute(
        "UPDATE coach_invite_requests SET status='approved', updated_at=? WHERE id=?",
        [now, requestId],
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

  Future<Response> declineInviteRequest(Request request, String requestId) async {
    try {
      final session = requireAuth(request, _repo);
      requireCoach(session);
      final coachUserId = session.user.id;

      final rows = _db.raw.select(
        "SELECT id FROM coach_invite_requests WHERE id=? AND coach_user_id=? AND status='pending' LIMIT 1",
        [requestId, coachUserId],
      );
      if (rows.isEmpty) throw ApiException('Request not found.', statusCode: 404);

      _db.raw.execute(
        "UPDATE coach_invite_requests SET status='declined', updated_at=? WHERE id=?",
        [dbNow(), requestId],
      );

      return jsonResponse({'ok': true});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Map<String, dynamic> _requestRowToJson(Map<String, Object?> row) {
    return {
      'id': row['id'],
      'coachUserId': row['coach_user_id'],
      'athleteUserId': row['athlete_user_id'],
      'athleteDisplayName': row['athlete_display_name'],
      'status': row['status'],
      'createdAt': row['created_at'],
      'updatedAt': row['updated_at'],
    };
  }

  // ── Athlete side: my coach / revoke ───────────────────────────────────────

  Future<Response> getMyCoach(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final athleteUserId = session.user.id;

      final linkRows = _db.raw.select(
        "SELECT coach_user_id FROM coach_athlete_links WHERE athlete_user_id=? AND status='active' LIMIT 1",
        [athleteUserId],
      );
      if (linkRows.isEmpty) return jsonResponse({'coach': null});

      final coachUserId = linkRows.first['coach_user_id'] as String;
      final profileRows = _db.raw.select(
        'SELECT display_name FROM user_profiles WHERE user_id=? LIMIT 1',
        [coachUserId],
      );
      final displayName = profileRows.isEmpty ? 'Coach' : profileRows.first['display_name'] as String;

      final publicProfileRows = _db.raw.select(
        'SELECT photo_url FROM coach_public_profiles WHERE coach_user_id=? LIMIT 1',
        [coachUserId],
      );
      final photoUrl = publicProfileRows.isEmpty ? null : publicProfileRows.first['photo_url'] as String?;

      return jsonResponse({
        'coach': {'coachUserId': coachUserId, 'displayName': displayName, 'photoUrl': photoUrl},
      });
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Future<Response> revokeCoach(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final athleteUserId = session.user.id;

      _db.raw.execute(
        "UPDATE coach_athlete_links SET status='revoked', updated_at=? WHERE athlete_user_id=? AND status='active'",
        [dbNow(), athleteUserId],
      );
      // Sans ça, coach_program_assignments reste 'active' indéfiniment et
      // getAssignedProgram() continue de le renvoyer — le programme du
      // coach révoqué se réapplique alors automatiquement côté athlète à
      // chaque fois que l'état local est vidé (réinstall, nouvel appareil).
      _db.raw.execute(
        "UPDATE coach_program_assignments SET status='removed' WHERE athlete_user_id=? AND status='active'",
        [athleteUserId],
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
      'photoUrl': row['photo_url'],
      'whatsapp': row['whatsapp'],
      'instagram': row['instagram'],
      'createdAt': row['created_at'],
      'updatedAt': row['updated_at'],
    };
  }
}
