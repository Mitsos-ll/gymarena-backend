import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../middleware/rate_limit_middleware.dart';
import '../repositories/user_repository.dart';
import '../services/athlete_progress.dart';
import '../services/email_service.dart';
import '../utils/api_exception.dart';
import '../utils/auth_helper.dart';
import '../utils/http_json.dart';

class CoachRoutes {
  CoachRoutes({
    required UserRepository userRepository,
    required AppDatabase database,
    required String photosDir,
    required EmailService emailService,
    required String adminNotifyEmail,
  })  : _repo = userRepository,
        _db = database,
        _photosDir = photosDir,
        _email = emailService,
        _adminNotifyEmail = adminNotifyEmail;

  final UserRepository _repo;
  final AppDatabase _db;
  final String _photosDir;
  final EmailService _email;
  final String _adminNotifyEmail;

  /// Par compte : codes d'invitation générés et demandes envoyées.
  final _actionLimiter = RateLimiter(maxRequests: 10, windowDuration: const Duration(hours: 1));

  /// Par compte : candidatures « devenir coach ».
  final _applicationLimiter = RateLimiter(maxRequests: 3, windowDuration: const Duration(days: 1));

  /// Une demande d'invitation sans réponse expire : elle bloquait l'athlète,
  /// qui ne peut en avoir qu'une en attente.
  static const inviteRequestTtl = Duration(days: 14);

  /// Spécialités proposées (clés, traduites par l'app), filtrables dans
  /// l'annuaire.
  static const specialities = {
    'strength',
    'powerlifting',
    'hyrox_crossfit',
    'weight_loss',
    'fitness',
    'athletic_prep',
    'running',
  };

  void _throttle(RateLimiter limiter, String key) {
    if (!limiter.allow(key)) {
      throw ApiException('Too many requests. Please slow down.', statusCode: 429);
    }
  }
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
      _throttle(_actionLimiter, 'invite-code:$coachUserId');
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
      final coachAlertDays = _coachInactivityAlertDays(coachUserId);

      final links = _db.raw.select(
        "SELECT athlete_user_id, linked_at, inactivity_alert_days FROM coach_athlete_links WHERE coach_user_id=? AND status='active'",
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

        final customAlertDays = link['inactivity_alert_days'] as int?;
        athletes.add({
          'athleteUserId': athleteId,
          'displayName': displayName,
          'lastWorkoutDate': lastWorkoutDate,
          'activeProgramName': activeProgramName,
          'linkedAt': link['linked_at'],
          'inactivityAlertDays': customAlertDays ?? coachAlertDays,
          'inactivityAlertDaysIsCustom': customAlertDays != null,
        });
      }

      return jsonResponse({
        'athletes': athletes,
        'settings': {'inactivityAlertDays': coachAlertDays},
      });
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

  /// Fiche d'un athlète : chiffres clés (assiduité, tendance du volume,
  /// séances sur 4 semaines) et séances paginées (`offset`, `limit`), chacune
  /// avec son écart par rapport à la précédente de la même origine et celui
  /// de chaque exercice par rapport à la dernière fois où il a été fait.
  ///
  /// `today` (YYYY-MM-DD) : date locale du coach, pour que les semaines et
  /// les 28 derniers jours tombent sur son calendrier et non sur l'UTC.
  Future<Response> getAthleteDetail(Request request, String athleteUserId) async {
    try {
      final session = requireAuth(request, _repo);
      requireCoach(session);
      final coachUserId = session.user.id;
      final link = _requireActiveLink(coachUserId, athleteUserId);

      final query = request.url.queryParameters;
      final offset = max(0, int.tryParse(query['offset'] ?? '') ?? 0);
      final limit = (int.tryParse(query['limit'] ?? '') ?? 5).clamp(1, 20);
      final today = parseWorkoutDay(query['today']) ?? calendarDay(DateTime.now().toUtc());

      final profileRows = _db.raw.select(
        'SELECT display_name FROM user_profiles WHERE user_id=? LIMIT 1',
        [athleteUserId],
      );
      final displayName = profileRows.isEmpty ? 'Utilisateur' : profileRows.first['display_name'] as String;

      // Tout l'historique, du plus récent au plus ancien : la séance de
      // référence d'un exercice peut être bien plus ancienne que la page.
      final workoutRows = _db.raw.select(
        'SELECT id, workout_date, program_name, program_session_name, session_template_name FROM workouts '
        'WHERE user_id=? AND end_time IS NOT NULL '
        'ORDER BY workout_date DESC, start_time DESC, created_at DESC',
        [athleteUserId],
      );
      final totalsByWorkout = _exerciseTotalsByWorkout(athleteUserId);
      TrainingTotals sessionTotals(String workoutId) =>
          (totalsByWorkout[workoutId]?.values ?? const <TrainingTotals>[])
              .fold(TrainingTotals.zero, (sum, t) => sum + t);

      final history = <({DateTime day, double volumeKg})>[];
      for (final w in workoutRows) {
        final day = parseWorkoutDay(w['workout_date'] as String?);
        if (day == null) continue;
        history.add((day: day, volumeKg: sessionTotals(w['id'] as String).volumeKg));
      }
      final customTarget = link['target_sessions_per_week'] as int?;
      final defaultTarget = _programTargetSessionsPerWeek(coachUserId, athleteUserId);
      final target = customTarget ?? defaultTarget;
      final customAlertDays = link['inactivity_alert_days'] as int?;
      final defaultAlertDays = _coachInactivityAlertDays(coachUserId);
      final followedSince = DateTime.tryParse(link['linked_at'] as String? ?? '') ?? today;

      final recentWorkouts = <Map<String, dynamic>>[];
      for (var i = offset; i < workoutRows.length && i < offset + limit; i++) {
        final w = workoutRows[i];
        final workoutId = w['id'] as String;
        final totals = totalsByWorkout[workoutId] ?? const <String, TrainingTotals>{};

        Map<String, dynamic>? sessionProgress;
        final origin = _originKey(w);
        if (origin != null) {
          for (var j = i + 1; j < workoutRows.length; j++) {
            final previous = workoutRows[j];
            if (_originKey(previous) != origin) continue;
            sessionProgress = compareSession(
              sessionTotals(workoutId),
              sessionTotals(previous['id'] as String),
            )?.toJson(previousDate: previous['workout_date'] as String?);
            break;
          }
        }

        Map<String, dynamic>? exerciseProgress(String key) {
          final current = totals[key];
          if (current == null) return null;
          for (var j = i + 1; j < workoutRows.length; j++) {
            final previous = workoutRows[j];
            final previousTotals = totalsByWorkout[previous['id'] as String]?[key];
            if (previousTotals == null) continue;
            return compareExercise(current, previousTotals)
                ?.toJson(previousDate: previous['workout_date'] as String?);
          }
          return null;
        }

        final noteRows = _db.raw.select(
          'SELECT note_text FROM coach_workout_notes WHERE coach_user_id=? AND workout_id=? LIMIT 1',
          [coachUserId, workoutId],
        );
        final viewRows = _db.raw.select(
          'SELECT seen_at FROM coach_workout_views WHERE coach_user_id=? AND workout_id=? LIMIT 1',
          [coachUserId, workoutId],
        );

        recentWorkouts.add({
          'workoutId': workoutId,
          'workoutDate': w['workout_date'],
          'programName': w['program_name'],
          'programSessionName': w['program_session_name'],
          'sessionTemplateName': w['session_template_name'],
          'progress': sessionProgress,
          'exercises': _workoutExercises(workoutId, exerciseProgress),
          'coachNote': noteRows.isEmpty ? null : noteRows.first['note_text'] as String?,
          'seenAt': viewRows.isEmpty ? null : viewRows.first['seen_at'] as String?,
        });
      }

      final programRows = _db.raw.select(
        "SELECT id, program_name FROM coach_program_assignments WHERE coach_user_id=? AND athlete_user_id=? AND status='active' LIMIT 1",
        [coachUserId, athleteUserId],
      );

      return jsonResponse({
        'athleteUserId': athleteUserId,
        'displayName': displayName,
        'activeProgramName': programRows.isEmpty ? null : programRows.first['program_name'] as String?,
        'activeProgramId': programRows.isEmpty ? null : programRows.first['id'] as String?,
        'linkedAt': link['linked_at'],
        'settings': {
          'targetSessionsPerWeek': target,
          'targetSessionsPerWeekIsCustom': customTarget != null,
          'targetSessionsPerWeekDefault': defaultTarget,
          'inactivityAlertDays': customAlertDays ?? defaultAlertDays,
          'inactivityAlertDaysIsCustom': customAlertDays != null,
          'inactivityAlertDaysDefault': defaultAlertDays,
        },
        'kpis': {
          'attendance': attendance(
            workoutDays: history.map((h) => h.day),
            today: today,
            targetPerWeek: target,
            followedSince: followedSince,
          )?.toJson(),
          'volumeTrendPct': volumeTrendPct(history, today),
          'sessionsLast28Days': sessionsInLast28Days(history.map((h) => h.day), today),
        },
        'recentWorkouts': recentWorkouts,
        'hasMore': offset + limit < workoutRows.length,
      });
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  /// Nom d'exercice normalisé pour l'appariement entre séances : c'est le nom
  /// figé qui fait foi, l'id d'exercice n'est pas stable d'un appareil à
  /// l'autre. `toLowerCase()` de Dart, et non `LOWER()` de SQLite qui ne
  /// traite que l'ASCII (« Élévations » ≠ « élévations »).
  static String? _nameKey(Object? name) {
    final key = name?.toString().trim().toLowerCase();
    return key == null || key.isEmpty ? null : key;
  }

  /// Origine d'une séance : séance d'un programme, sinon séance enregistrée.
  /// `null` pour une séance libre, qui n'a pas d'équivalent à comparer.
  static String? _originKey(Map<String, dynamic> workout) {
    final program = _nameKey(workout['program_name']);
    final programSession = _nameKey(workout['program_session_name']);
    if (program != null && programSession != null) return 'program\u0000$program\u0000$programSession';
    final template = _nameKey(workout['session_template_name']);
    return template == null ? null : 'template\u0000$template';
  }

  /// Totaux par séance terminée puis par exercice. Un exercice fait deux fois
  /// dans la même séance (superset) y compte comme un seul, comme dans la
  /// saisie côté app.
  Map<String, Map<String, TrainingTotals>> _exerciseTotalsByWorkout(String athleteUserId) {
    final rows = _db.raw.select(
      'SELECT we.workout_id, COALESCE(we.exercise_name_snapshot, e.name, we.exercise_id) AS name, '
      'SUM(ws.weight_kg * COALESCE((SELECT SUM(wss.reps) FROM workout_set_sides wss WHERE wss.workout_set_id = ws.id), ws.volume_reps, ws.reps)) AS volume, '
      'SUM(COALESCE(ws.effort_seconds, 0)) AS duration, '
      'SUM(COALESCE(ws.distance_m, 0)) AS distance '
      'FROM workout_exercises we '
      'JOIN workouts w ON w.id = we.workout_id '
      'LEFT JOIN exercises e ON e.id = we.exercise_id '
      'LEFT JOIN workout_sets ws ON ws.workout_exercise_id = we.id '
      'WHERE w.user_id=? AND w.end_time IS NOT NULL '
      'GROUP BY we.id',
      [athleteUserId],
    );
    final byWorkout = <String, Map<String, TrainingTotals>>{};
    for (final r in rows) {
      final key = _nameKey(r['name']);
      if (key == null) continue;
      final totals = TrainingTotals(
        volumeKg: (r['volume'] as num?)?.toDouble() ?? 0,
        durationSeconds: (r['duration'] as num?)?.toInt() ?? 0,
        distanceM: (r['distance'] as num?)?.toDouble() ?? 0,
      );
      final byKey = byWorkout.putIfAbsent(r['workout_id'] as String, () => {});
      byKey[key] = (byKey[key] ?? TrainingTotals.zero) + totals;
    }
    return byWorkout;
  }

  /// Exercices d'une séance avec le détail de leurs séries. L'écart avec la
  /// fois précédente n'est porté que par la première occurrence d'un
  /// exercice fait deux fois dans la séance.
  List<Map<String, dynamic>> _workoutExercises(
    String workoutId,
    Map<String, dynamic>? Function(String key) progressOf,
  ) {
    final rows = _db.raw.select(
      'SELECT we.id, COALESCE(we.exercise_name_snapshot, e.name, we.exercise_id) AS name, '
      'ws.id AS ws_id, ws.set_number, ws.set_type, ws.weight_kg, ws.reps, ws.rpe, '
      'ws.bodyweight_kg, ws.added_weight_kg, ws.effort_seconds, ws.distance_m '
      'FROM workout_exercises we '
      'LEFT JOIN exercises e ON e.id = we.exercise_id '
      'LEFT JOIN workout_sets ws ON ws.workout_exercise_id = we.id '
      'WHERE we.workout_id=? ORDER BY we.exercise_order, ws.set_number',
      [workoutId],
    );

    // Regroupe par workout_exercise (we.id) et non par nom : un exercice
    // peut apparaître deux fois dans la même séance.
    final exercisesById = <String, Map<String, dynamic>>{};
    final seenKeys = <String>{};
    for (final r in rows) {
      final weId = r['id'] as String;
      final exercise = exercisesById.putIfAbsent(weId, () {
        final name = r['name']?.toString() ?? 'Exercice';
        final key = _nameKey(name);
        return {
          'name': name,
          'progress': key != null && seenKeys.add(key) ? progressOf(key) : null,
          'sets': <Map<String, dynamic>>[],
        };
      });
      if (r['ws_id'] == null) continue;
      (exercise['sets'] as List<Map<String, dynamic>>).add({
        'setNumber': r['set_number'],
        'setType': r['set_type'] ?? 'normal',
        'weightKg': (r['weight_kg'] as num).toDouble(),
        'reps': r['reps'],
        'rpe': (r['rpe'] as num?)?.toDouble(),
        if (r['bodyweight_kg'] != null) 'bodyweightKg': (r['bodyweight_kg'] as num).toDouble(),
        if (r['added_weight_kg'] != null) 'addedWeightKg': (r['added_weight_kg'] as num).toDouble(),
        if (r['effort_seconds'] != null) 'effortSeconds': r['effort_seconds'],
        if (r['distance_m'] != null) 'distanceM': (r['distance_m'] as num).toDouble(),
      });
    }
    return exercisesById.values.toList();
  }

  // ── Follow-up settings ────────────────────────────────────────────────────

  static const _defaultInactivityAlertDays = 7;
  static const _defaultTargetSessionsPerWeek = 3;

  /// Lien actif entre le coach et l'athlète, sinon 404 : toute route qui lit
  /// ou écrit les données d'un athlète passe par là.
  Map<String, dynamic> _requireActiveLink(String coachUserId, String athleteUserId) {
    final rows = _db.raw.select(
      'SELECT id, linked_at, target_sessions_per_week, inactivity_alert_days FROM coach_athlete_links '
      "WHERE coach_user_id=? AND athlete_user_id=? AND status='active' LIMIT 1",
      [coachUserId, athleteUserId],
    );
    if (rows.isEmpty) throw ApiException('Athlete not found.', statusCode: 404);
    return rows.first;
  }

  int _coachInactivityAlertDays(String coachUserId) {
    final rows = _db.raw.select(
      'SELECT inactivity_alert_days FROM coach_settings WHERE coach_user_id=? LIMIT 1',
      [coachUserId],
    );
    return rows.isEmpty ? _defaultInactivityAlertDays : rows.first['inactivity_alert_days'] as int;
  }

  /// Objectif hebdo par défaut : le nombre de séances du programme assigné
  /// (un A/B/C → 3), plafonné à 7.
  int _programTargetSessionsPerWeek(String coachUserId, String athleteUserId) {
    final rows = _db.raw.select(
      "SELECT session_count, snapshot_json FROM coach_program_assignments WHERE coach_user_id=? AND athlete_user_id=? AND status='active' LIMIT 1",
      [coachUserId, athleteUserId],
    );
    if (rows.isEmpty) return _defaultTargetSessionsPerWeek;
    final count = rows.first['session_count'] as int? ??
        _snapshotSessionCount(rows.first['snapshot_json'] as String?);
    return count == null || count < 1 ? _defaultTargetSessionsPerWeek : min(count, 7);
  }

  static int? _snapshotSessionCount(String? snapshotJson) {
    if (snapshotJson == null) return null;
    try {
      final snapshot = jsonDecode(snapshotJson);
      final sessions = snapshot is Map ? snapshot['sessions'] : null;
      return sessions is List ? sessions.length : null;
    } on FormatException {
      return null;
    }
  }

  /// Entier optionnel du corps de requête : `null` (valeur par défaut) ou
  /// compris entre [minValue] et [maxValue], sinon 400.
  static int? _optionalInt(Map<String, dynamic> body, String key, int minValue, int maxValue) {
    final value = body[key];
    if (value == null) return null;
    if (value is! int || value < minValue || value > maxValue) {
      throw ApiException('$key must be an integer between $minValue and $maxValue.', statusCode: 400);
    }
    return value;
  }

  /// PUT /coach/settings `{inactivityAlertDays}` : délai d'alerte appliqué
  /// aux athlètes qui n'ont pas de délai propre.
  Future<Response> updateSettings(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      requireCoach(session);
      final body = await readJsonBody(request);
      final days = _optionalInt(body, 'inactivityAlertDays', 1, 60) ?? _defaultInactivityAlertDays;
      _db.raw.execute(
        'INSERT OR REPLACE INTO coach_settings (coach_user_id, inactivity_alert_days, updated_at) VALUES (?, ?, ?)',
        [session.user.id, days, dbNow()],
      );
      return jsonResponse({'inactivityAlertDays': days});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  /// PUT /coach/athletes/<id>/settings : objectif de séances par semaine et
  /// délai d'alerte propres à l'athlète. Seules les clés présentes sont
  /// modifiées ; `null` rend la valeur par défaut.
  Future<Response> updateAthleteSettings(Request request, String athleteUserId) async {
    try {
      final session = requireAuth(request, _repo);
      requireCoach(session);
      _requireActiveLink(session.user.id, athleteUserId);
      final body = await readJsonBody(request);

      final assignments = <String>[];
      final values = <Object?>[];
      if (body.containsKey('targetSessionsPerWeek')) {
        assignments.add('target_sessions_per_week=?');
        values.add(_optionalInt(body, 'targetSessionsPerWeek', 1, 7));
      }
      if (body.containsKey('inactivityAlertDays')) {
        assignments.add('inactivity_alert_days=?');
        values.add(_optionalInt(body, 'inactivityAlertDays', 1, 60));
      }
      if (assignments.isNotEmpty) {
        _db.raw.execute(
          'UPDATE coach_athlete_links SET ${assignments.join(', ')}, updated_at=? '
          "WHERE coach_user_id=? AND athlete_user_id=? AND status='active'",
          [...values, dbNow(), session.user.id, athleteUserId],
        );
      }
      return jsonResponse({'ok': true});
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
      _requireActiveLink(coachUserId, athleteUserId);
      _requireAthleteWorkout(athleteUserId, workoutId);

      final body = await readJsonBody(request);
      final noteText = body['noteText']?.toString().trim() ?? '';
      if (noteText.isEmpty) throw ApiException('noteText is required.', statusCode: 400);

      final now = dbNow();
      final id = _uuid.v4();

      _db.raw.execute(
        'INSERT OR REPLACE INTO coach_workout_notes (id, coach_user_id, athlete_user_id, workout_id, note_text, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [id, coachUserId, athleteUserId, workoutId, noteText, now, now],
      );
      // Écrire une note, c'est avoir vu la séance.
      _markSeen(coachUserId, athleteUserId, workoutId, now);

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

  /// Le coach a ouvert la séance : l'athlète verra « Vu par votre coach ».
  /// Seule la première ouverture compte.
  Future<Response> markWorkoutSeen(Request request, String athleteUserId, String workoutId) async {
    try {
      final session = requireAuth(request, _repo);
      requireCoach(session);
      final coachUserId = session.user.id;
      _requireActiveLink(coachUserId, athleteUserId);
      _requireAthleteWorkout(athleteUserId, workoutId);
      _markSeen(coachUserId, athleteUserId, workoutId, dbNow());
      final rows = _db.raw.select(
        'SELECT seen_at FROM coach_workout_views WHERE coach_user_id=? AND workout_id=?',
        [coachUserId, workoutId],
      );
      return jsonResponse({'seenAt': rows.first['seen_at']});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  void _requireAthleteWorkout(String athleteUserId, String workoutId) {
    final owned = _db.raw.select(
      'SELECT 1 FROM workouts WHERE id=? AND user_id=? LIMIT 1',
      [workoutId, athleteUserId],
    );
    if (owned.isEmpty) throw ApiException('Workout not found.', statusCode: 404);
  }

  void _markSeen(String coachUserId, String athleteUserId, String workoutId, String now) {
    _db.raw.execute(
      'INSERT OR IGNORE INTO coach_workout_views (coach_user_id, workout_id, athlete_user_id, seen_at) VALUES (?, ?, ?, ?)',
      [coachUserId, workoutId, athleteUserId, now],
    );
  }

  // ── Program assignment ────────────────────────────────────────────────────

  Future<Response> assignProgram(Request request, String athleteUserId) async {
    try {
      final session = requireAuth(request, _repo);
      requireCoach(session);
      final coachUserId = session.user.id;
      _requireActiveLink(coachUserId, athleteUserId);

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

      // Nombre de séances du programme : objectif hebdo par défaut de
      // l'assiduité. Envoyé par l'app, le serveur ne connaissant pas le
      // contenu des programmes intégrés.
      final sessionCount = _optionalInt(body, 'sessionCount', 1, 50);

      final now = dbNow();
      final id = _uuid.v4();

      _db.raw.execute(
        'INSERT OR REPLACE INTO coach_program_assignments '
        '(id, coach_user_id, athlete_user_id, program_type, program_code, program_name, snapshot_json, session_count, assigned_at, updated_at, status) '
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active')",
        [
          id,
          coachUserId,
          athleteUserId,
          type,
          code,
          name,
          snapshot != null ? jsonEncode(snapshot) : null,
          sessionCount,
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
        'SELECT a.*, COALESCE(cp.display_name, u.display_name) AS coach_name '
        'FROM coach_program_assignments a '
        'JOIN users u ON u.id = a.coach_user_id '
        'LEFT JOIN coach_public_profiles cp ON cp.coach_user_id = a.coach_user_id '
        "WHERE a.athlete_user_id=? AND a.status='active' LIMIT 1",
        [athleteUserId],
      );
      if (rows.isEmpty) return jsonResponse({'assignment': null});

      final row = rows.first;
      return jsonResponse({
        'assignment': {
          'id': row['id'],
          'coachUserId': row['coach_user_id'],
          'coachName': row['coach_name'],
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
      final body = await readJsonBody(request);
      return jsonResponse(_writePublicProfile(session.user.id, session.profile?.displayName ?? 'Coach', body));
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Map<String, dynamic> _writePublicProfile(String userId, String displayName, Map<String, dynamic> body) {
    final chosen = (body['specialities'] as List?)?.map((e) => e.toString()).toSet() ?? <String>{};
    if (!specialities.containsAll(chosen)) {
      throw ApiException('Unknown speciality.', statusCode: 400);
    }
    final now = dbNow();
    _db.raw.execute(
      'INSERT OR REPLACE INTO coach_public_profiles (coach_user_id, display_name, bio, speciality, specialities, location, languages, is_public, photo_url, whatsapp, instagram, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, (SELECT photo_url FROM coach_public_profiles WHERE coach_user_id=?), ?, ?, COALESCE((SELECT created_at FROM coach_public_profiles WHERE coach_user_id=?), ?), ?)',
      [
        userId,
        displayName,
        body['bio'],
        body['speciality'],
        jsonEncode(chosen.toList()..sort()),
        body['location'],
        jsonEncode(body['languages'] ?? []),
        (body['isPublic'] == true) ? 1 : 0,
        userId,
        body['whatsapp'],
        body['instagram'],
        userId,
        now,
        now,
      ],
    );
    final rows = _db.raw.select('SELECT * FROM coach_public_profiles WHERE coach_user_id=? LIMIT 1', [userId]);
    return _profileRowToJson(rows.first);
  }

  // ── Candidature « devenir coach » ─────────────────────────────────────────

  /// Profil coach proposé depuis l'app : enregistré (invisible tant que le
  /// compte n'est pas coach) et soumis à l'administrateur, prévenu par mail.
  Future<Response> submitApplication(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;
      if (session.profile?.isCoach == true) {
        throw ApiException('Already a coach.', statusCode: 409);
      }
      final pending = _db.raw.select(
        "SELECT 1 FROM coach_applications WHERE user_id=? AND status='pending' LIMIT 1",
        [userId],
      );
      if (pending.isNotEmpty) throw ApiException('Application already pending.', statusCode: 409);
      _throttle(_applicationLimiter, 'coach-application:$userId');

      final body = await readJsonBody(request);
      final displayName = session.profile?.displayName ?? session.user.displayName;
      final profile = _writePublicProfile(userId, displayName, body);

      final now = dbNow();
      final id = _uuid.v4();
      _db.raw.execute(
        "INSERT INTO coach_applications (id, user_id, status, created_at, updated_at) VALUES (?, ?, 'pending', ?, ?)",
        [id, userId, now, now],
      );

      unawaited(_email.sendAdminNotification(
        toEmail: _adminNotifyEmail,
        subject: 'GymArena — Candidature coach : $displayName',
        html: _applicationEmailHtml(
          applicationId: id,
          displayName: displayName,
          email: session.user.email,
          profile: profile,
        ),
      ));

      return jsonResponse(_applicationRowToJson({
        'id': id,
        'status': 'pending',
        'created_at': now,
        'decided_at': null,
      }));
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  /// Dernière candidature du compte, pour afficher son état dans l'app.
  Future<Response> getMyApplication(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final rows = _db.raw.select(
        'SELECT * FROM coach_applications WHERE user_id=? ORDER BY created_at DESC LIMIT 1',
        [session.user.id],
      );
      return jsonResponse({'application': rows.isEmpty ? null : _applicationRowToJson(rows.first)});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Map<String, dynamic> _applicationRowToJson(Map<String, Object?> row) => {
        'id': row['id'],
        'status': row['status'],
        'createdAt': row['created_at'],
        'decidedAt': row['decided_at'],
      };

  String _applicationEmailHtml({
    required String applicationId,
    required String displayName,
    required String email,
    required Map<String, dynamic> profile,
  }) {
    String esc(Object? value) => const HtmlEscape().convert(value?.toString() ?? '—');
    final specialitiesText = (profile['specialities'] as List).join(', ');
    final languagesText = (profile['languages'] as List).join(', ');
    return '''
<div style="font-family:-apple-system,Roboto,Arial,sans-serif;max-width:560px;margin:0 auto;padding:24px;color:#111827;">
  <h2>Nouvelle candidature coach</h2>
  <p><b>${esc(displayName)}</b> (${esc(email)}) propose son profil de coach.</p>
  <table style="font-size:14px;line-height:1.6;">
    <tr><td style="color:#6B7280;padding-right:12px;">Spécialités</td><td>${esc(specialitiesText.isEmpty ? null : specialitiesText)}</td></tr>
    <tr><td style="color:#6B7280;padding-right:12px;">Ville</td><td>${esc(profile['location'])}</td></tr>
    <tr><td style="color:#6B7280;padding-right:12px;">Langues</td><td>${esc(languagesText.isEmpty ? null : languagesText)}</td></tr>
    <tr><td style="color:#6B7280;padding-right:12px;">Présentation</td><td>${esc(profile['bio'])}</td></tr>
  </table>
  <p style="margin-top:20px;">Pour décider, dans PowerShell (secret admin dans <code>\$env:GYMARENA_ADMIN_SECRET</code>) :</p>
  <pre style="background:#F3F4F6;padding:12px;border-radius:8px;font-size:12px;white-space:pre-wrap;">Invoke-RestMethod -Method Post -Uri "https://gymtrack-backend-2.fly.dev/admin/coach-applications/$applicationId/approve" -Headers @{ Authorization = "Bearer \$env:GYMARENA_ADMIN_SECRET" }

Invoke-RestMethod -Method Post -Uri "https://gymtrack-backend-2.fly.dev/admin/coach-applications/$applicationId/reject" -Headers @{ Authorization = "Bearer \$env:GYMARENA_ADMIN_SECRET" }</pre>
</div>
''';
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

      // Un profil proposé en candidature, ou d'un compte qui n'est plus
      // coach, reste enregistré mais n'apparaît pas.
      final rows = _db.raw.select(
        'SELECT p.* FROM coach_public_profiles p '
        'JOIN user_profiles up ON up.user_id = p.coach_user_id AND up.is_coach = 1 '
        'JOIN users u ON u.id = p.coach_user_id AND u.is_deleted = 0 '
        'WHERE p.is_public = 1 ORDER BY p.display_name ASC',
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
      final coachRows = _db.raw.select(
        'SELECT 1 FROM user_profiles WHERE user_id=? AND is_coach=1 LIMIT 1',
        [coachUserId],
      );
      if (coachRows.isEmpty) throw ApiException('Coach not found.', statusCode: 404);
      _throttle(_actionLimiter, 'invite-request:$athleteUserId');
      _expireStaleInviteRequests();

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
      _expireStaleInviteRequests();

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
      _expireStaleInviteRequests();

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
      _expireStaleInviteRequests();

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

  void _expireStaleInviteRequests() {
    final cutoff = DateTime.now().toUtc().subtract(inviteRequestTtl).toIso8601String();
    _db.raw.execute(
      "UPDATE coach_invite_requests SET status='expired', updated_at=? WHERE status='pending' AND created_at < ?",
      [dbNow(), cutoff],
    );
  }

  /// Demande en attente de l'athlète connecté, avec le nom du coach visé.
  Future<Response> getMyInviteRequest(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      _expireStaleInviteRequests();
      final rows = _db.raw.select(
        'SELECT r.id, r.coach_user_id, r.created_at, COALESCE(cp.display_name, u.display_name) AS coach_name '
        'FROM coach_invite_requests r '
        'JOIN users u ON u.id = r.coach_user_id '
        'LEFT JOIN coach_public_profiles cp ON cp.coach_user_id = r.coach_user_id '
        "WHERE r.athlete_user_id=? AND r.status='pending' LIMIT 1",
        [session.user.id],
      );
      if (rows.isEmpty) return jsonResponse({'request': null});
      final row = rows.first;
      final createdAt = row['created_at'] as String;
      return jsonResponse({
        'request': {
          'id': row['id'],
          'coachUserId': row['coach_user_id'],
          'coachName': row['coach_name'],
          'createdAt': createdAt,
          'expiresAt': DateTime.parse(createdAt).add(inviteRequestTtl).toUtc().toIso8601String(),
        },
      });
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  /// L'athlète retire sa demande, par exemple pour en envoyer une à un autre
  /// coach.
  Future<Response> cancelMyInviteRequest(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      _db.raw.execute(
        "UPDATE coach_invite_requests SET status='cancelled', updated_at=? WHERE athlete_user_id=? AND status='pending'",
        [dbNow(), session.user.id],
      );
      if (_db.raw.updatedRows == 0) throw ApiException('Request not found.', statusCode: 404);
      return Response(204);
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
      'specialities': jsonDecode(row['specialities'] as String? ?? '[]'),
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
