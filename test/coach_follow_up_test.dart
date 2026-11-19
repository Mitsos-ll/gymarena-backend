import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/src/app.dart';
import 'test_config.dart';

/// Suivi d'un athlète par son coach : progression par exercice et par séance,
/// chiffres clés, réglages, et refus d'accès sans lien actif.
void main() {
  late GymTrackBackend backend;
  late ({String token, String id}) coach;
  late ({String token, String id}) athlete;
  late ({String token, String id}) stranger;

  Future<Response> send(String method, String path, {String? token, Object? body}) async {
    return backend.handler(Request(
      method,
      Uri.parse('http://localhost$path'),
      body: body == null ? null : jsonEncode(body),
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
    ));
  }

  Future<Map<String, dynamic>> json(Response res) async {
    final text = await res.readAsString();
    expect(res.statusCode, 200, reason: text);
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<({String token, String id})> register(String name) async {
    final body = await json(await send('POST', '/auth/register', body: {
      'email': '${name.toLowerCase()}@example.com',
      'password': 'password123',
      'displayName': name,
    }));
    return (token: body['accessToken'] as String, id: (body['user'] as Map)['id'] as String);
  }

  Map<String, dynamic> strengthSet(int n, double kg, int reps, {String type = 'normal'}) =>
      {'setNumber': n, 'weightKg': kg, 'reps': reps, 'setType': type};

  Map<String, dynamic> workout(
    int localId,
    String date,
    List<Map<String, dynamic>> exercises, {
    String? program,
    String? programSession,
    String? template,
  }) =>
      {
        'localId': localId,
        'workoutDate': date,
        'startTime': '${date}T18:00:00.000',
        'endTime': '${date}T19:00:00.000',
        'durationSeconds': 3600,
        if (program != null) 'programName': program,
        if (programSession != null) 'programSessionName': programSession,
        if (template != null) 'sessionTemplateName': template,
        'exercises': [
          for (final (i, e) in exercises.indexed) {...e, 'exerciseOrder': i + 1},
        ],
      };

  Map<String, dynamic> bench(String name, List<Map<String, dynamic>> sets) =>
      {'exerciseNameSnapshot': name, 'sets': sets};

  Map<String, dynamic> plank(int seconds) => {
        'exerciseNameSnapshot': 'Planche',
        'sets': [
          {'setNumber': 1, 'weightKg': 0, 'reps': 0, 'effortSeconds': seconds, 'setType': 'normal'},
        ],
      };

  setUp(() async {
    backend = GymTrackBackend(testConfig());
    coach = await register('Coach');
    athlete = await register('Athlete');
    stranger = await register('Stranger');

    final Response admin = await backend.handler(Request(
      'PUT',
      Uri.parse('http://localhost/admin/users/${coach.id}/set-coach'),
      body: jsonEncode({'isCoach': true}),
      headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer test-admin-secret'},
    ));
    expect(admin.statusCode, 200);

    final code = (await json(await send('POST', '/coach/invite-codes', token: coach.token)))['code'];
    await json(await send('POST', '/coach/invite-codes/redeem', token: athlete.token, body: {'code': code}));

    await json(await send('POST', '/workouts/batch', token: athlete.token, body: {
      'workouts': [
        workout(1, '2026-11-02', [
          bench('Développé couché', [for (var n = 1; n <= 3; n++) strengthSet(n, 100, 10)]),
          plank(40),
        ], program: 'PPL', programSession: 'Push'),
        workout(2, '2026-11-05', [
          bench('Squat', [for (var n = 1; n <= 3; n++) strengthSet(n, 120, 5)]),
        ], template: 'Jambes'),
        // Même séance de programme, noms saisis autrement : l'appariement
        // ignore la casse (accents compris) et les espaces autour.
        workout(3, '2026-11-09', [
          bench('DÉVELOPPÉ COUCHÉ ', [
            for (var n = 1; n <= 3; n++) strengthSet(n, 105, 10),
            strengthSet(4, 50, 6, type: 'drop_set'),
          ]),
          plank(50),
        ], program: 'ppl', programSession: ' push'),
        // Séance libre : pas de séance équivalente à comparer.
        workout(4, '2026-11-12', [
          bench('Développé couché', [strengthSet(1, 100, 5)]),
        ]),
      ],
    }));
  });

  tearDown(() => backend.close());

  Future<Map<String, dynamic>> detail({int offset = 0, int limit = 2}) async => json(await send(
        'GET',
        '/coach/athletes/${athlete.id}/detail?offset=$offset&limit=$limit&today=2026-11-19',
        token: coach.token,
      ));

  test('écart par exercice et par séance, sur une page plus courte que la référence', () async {
    final page1 = await detail();
    expect(page1['hasMore'], isTrue);
    final workouts = (page1['recentWorkouts'] as List).cast<Map<String, dynamic>>();
    expect(workouts.map((w) => w['workoutDate']), ['2026-11-12', '2026-11-09']);

    final free = workouts[0];
    expect(free['progress'], isNull);
    // 500 kg contre 3 450 kg à la séance du 9 (hors de la page suivante).
    expect((free['exercises'] as List).single['progress'],
        {'trend': 'down', 'volumePct': -86, 'previousDate': '2026-11-09'});

    final push = workouts[1];
    expect(push['programSessionName'], ' push');
    // Le drop set compte dans le volume : 3 150 + 300 contre 3 000.
    expect(push['progress'], {'trend': 'up', 'volumePct': 15, 'previousDate': '2026-11-02'});
    final exercises = (push['exercises'] as List).cast<Map<String, dynamic>>();
    expect(exercises[0]['progress'], {'trend': 'up', 'volumePct': 15, 'previousDate': '2026-11-02'});
    expect((exercises[0]['sets'] as List).last['setType'], 'drop_set');
    expect(exercises[1]['progress'], {'trend': 'up', 'durationPct': 25, 'previousDate': '2026-11-02'});
    expect((exercises[1]['sets'] as List).single['effortSeconds'], 50);

    final page2 = await detail(offset: 2);
    expect(page2['hasMore'], isFalse);
    final older = (page2['recentWorkouts'] as List).cast<Map<String, dynamic>>();
    expect(older.map((w) => w['workoutDate']), ['2026-11-05', '2026-11-02']);
    // Première séance « Jambes » : rien à comparer.
    expect(older[0]['progress'], isNull);
    expect((older[0]['exercises'] as List).single['progress'], isNull);
  });

  test("un renvoi sans origine (ancienne app, séance restaurée) garde l'origine connue", () async {
    final res = await send('POST', '/workouts', token: athlete.token, body: workout(3, '2026-11-09', [
      bench('Développé couché', [strengthSet(1, 105, 10)]),
    ]));
    expect(res.statusCode, 200);
    final push = ((await detail())['recentWorkouts'] as List)[1] as Map<String, dynamic>;
    expect(push['programName'], 'ppl');
    expect(push['programSessionName'], ' push');
  });

  test('chiffres clés et objectif hebdo : programme, puis réglage propre à l’athlète', () async {
    var body = await detail();
    expect(body['kpis'], {
      // Suivi depuis aujourd'hui : aucune semaine complète à juger.
      'attendance': null,
      'volumeTrendPct': null,
      'sessionsLast28Days': 4,
    });
    expect(body['settings'], {
      'targetSessionsPerWeek': 3,
      'targetSessionsPerWeekIsCustom': false,
      'targetSessionsPerWeekDefault': 3,
      'inactivityAlertDays': 7,
      'inactivityAlertDaysIsCustom': false,
      'inactivityAlertDaysDefault': 7,
    });

    await json(await send('PUT', '/coach/athletes/${athlete.id}/program', token: coach.token, body: {
      'type': 'builtin',
      'code': 'upper_lower',
      'name': 'Upper Lower',
      'sessionCount': 4,
    }));
    expect((await detail())['settings']['targetSessionsPerWeek'], 4);

    await json(await send('PUT', '/coach/athletes/${athlete.id}/settings',
        token: coach.token, body: {'targetSessionsPerWeek': 2, 'inactivityAlertDays': 3}));
    body = await detail();
    expect(body['settings'], {
      'targetSessionsPerWeek': 2,
      'targetSessionsPerWeekIsCustom': true,
      // Les valeurs par défaut restent connues, pour « revenir au défaut ».
      'targetSessionsPerWeekDefault': 4,
      'inactivityAlertDays': 3,
      'inactivityAlertDaysIsCustom': true,
      'inactivityAlertDaysDefault': 7,
    });

    // null rend la valeur par défaut ; une clé absente n'est pas touchée.
    await json(await send('PUT', '/coach/athletes/${athlete.id}/settings',
        token: coach.token, body: {'targetSessionsPerWeek': null}));
    body = await detail();
    expect(body['settings']['targetSessionsPerWeek'], 4);
    expect(body['settings']['inactivityAlertDays'], 3);

    final invalid = await send('PUT', '/coach/athletes/${athlete.id}/settings',
        token: coach.token, body: {'inactivityAlertDays': 0});
    expect(invalid.statusCode, 400);
  });

  test("délai d'alerte : réglage du coach, sauf athlète réglé à part", () async {
    await json(await send('PUT', '/coach/settings', token: coach.token, body: {'inactivityAlertDays': 10}));
    var list = await json(await send('GET', '/coach/athletes', token: coach.token));
    expect(list['settings'], {'inactivityAlertDays': 10});
    final row = (list['athletes'] as List).single as Map<String, dynamic>;
    expect(row['inactivityAlertDays'], 10);
    expect(row['inactivityAlertDaysIsCustom'], isFalse);
    expect(row['lastWorkoutDate'], '2026-11-12');
    expect(row['linkedAt'], isNotNull);

    await json(await send('PUT', '/coach/athletes/${athlete.id}/settings',
        token: coach.token, body: {'inactivityAlertDays': 4}));
    list = await json(await send('GET', '/coach/athletes', token: coach.token));
    expect(((list['athletes'] as List).single as Map)['inactivityAlertDays'], 4);
  });

  test('sans lien actif, le coach ne lit ni n’écrit rien', () async {
    final workoutId = (((await detail())['recentWorkouts'] as List).first as Map)['workoutId'];

    expect((await send('GET', '/coach/athletes/${stranger.id}/detail', token: coach.token)).statusCode, 404);
    expect(
      (await send('PUT', '/coach/athletes/${stranger.id}/program',
              token: coach.token, body: {'type': 'builtin', 'code': 'x', 'name': 'X'}))
          .statusCode,
      404,
    );
    // Séance de l'athlète suivi, mais annoncée comme celle d'un autre compte.
    expect(
      (await send('PUT', '/coach/athletes/${stranger.id}/workouts/$workoutId/note',
              token: coach.token, body: {'noteText': 'x'}))
          .statusCode,
      404,
    );
    expect(
      (await send('PUT', '/coach/athletes/${athlete.id}/workouts/$workoutId/note',
              token: coach.token, body: {'noteText': 'Bonne séance'}))
          .statusCode,
      200,
    );
  });

  group("retour vers l'athlète", () {
    Future<Map<String, dynamic>> snapshot() async =>
        json(await send('GET', '/me/snapshot', token: athlete.token));

    Future<String> workoutIdOf(String date) async {
      final all = await detail(limit: 10);
      return ((all['recentWorkouts'] as List).firstWhere((w) => w['workoutDate'] == date) as Map)['workoutId']
          as String;
    }

    test('séance ouverte puis commentée : vue et note dans le snapshot, première ouverture conservée', () async {
      final push = await workoutIdOf('2026-11-09');
      final legs = await workoutIdOf('2026-11-05');
      expect((await snapshot())['coachFeedback'], isEmpty);

      final seen = await json(await send('POST', '/coach/athletes/${athlete.id}/workouts/$legs/seen', token: coach.token));
      await json(await send('PUT', '/coach/athletes/${athlete.id}/workouts/$push/note',
          token: coach.token, body: {'noteText': 'Garde les coudes serrés'}));
      final again = await json(await send('POST', '/coach/athletes/${athlete.id}/workouts/$legs/seen', token: coach.token));
      expect(again['seenAt'], seen['seenAt']);

      final feedback = ((await snapshot())['coachFeedback'] as List).cast<Map<String, dynamic>>()
        ..sort((a, b) => (a['workoutLocalId'] as int).compareTo(b['workoutLocalId'] as int));
      expect(feedback, hasLength(2));
      expect(feedback[0], {
        'workoutLocalId': 2,
        'coachUserId': coach.id,
        'coachName': 'Coach',
        'noteText': null,
        'noteUpdatedAt': null,
        'seenAt': seen['seenAt'],
      });
      expect(feedback[1]['workoutLocalId'], 3);
      expect(feedback[1]['noteText'], 'Garde les coudes serrés');
      // Écrire une note, c'est avoir vu la séance.
      expect(feedback[1]['seenAt'], isNotNull);

      // Le coach sait quelles séances il a déjà ouvertes.
      final sessions = ((await detail(limit: 10))['recentWorkouts'] as List).cast<Map<String, dynamic>>();
      expect(sessions.where((w) => w['seenAt'] != null).map((w) => w['workoutDate']),
          unorderedEquals(['2026-11-09', '2026-11-05']));
    });

    test("vue refusée sans lien ou sur la séance d'un autre compte ; supprimée avec la séance", () async {
      final legs = await workoutIdOf('2026-11-05');
      expect((await send('POST', '/coach/athletes/${stranger.id}/workouts/$legs/seen', token: coach.token)).statusCode,
          404);
      expect((await send('POST', '/coach/athletes/${athlete.id}/workouts/$legs/seen', token: stranger.token)).statusCode,
          403);

      await json(await send('POST', '/coach/athletes/${athlete.id}/workouts/$legs/seen', token: coach.token));
      await json(await send('PUT', '/coach/athletes/${athlete.id}/workouts/$legs/note',
          token: coach.token, body: {'noteText': 'Top'}));
      expect((await send('DELETE', '/workouts/2', token: athlete.token)).statusCode, 204);
      expect((await snapshot())['coachFeedback'], isEmpty);
      expect(backend.database.raw.select('SELECT 1 FROM coach_workout_notes'), isEmpty);
    });

    test('programme : consignes, repos cible, reps en texte et origine survivent à la synchro', () async {
      await json(await send('POST', '/programs', token: athlete.token, body: {
        'localId': 7,
        'code': 'coach_abc_ppl',
        'name': 'PPL',
        'sessions': [
          {
            'name': 'Push',
            'sessionOrder': 0,
            'exercises': [
              {
                'exerciseId': 12,
                'exerciseNameSnapshot': 'Développé couché',
                'exerciseOrder': 0,
                'targetSets': 4,
                'targetReps': '6-8',
                'notes': 'Tempo 3-1-1',
                'restSeconds': 150,
                'progressionStepKg': 2.5,
              },
            ],
          },
        ],
      }));
      final program = ((await snapshot())['programs'] as List).single as Map<String, dynamic>;
      expect(program['code'], 'coach_abc_ppl');
      final exercise = (((program['sessions'] as List).single as Map)['exercises'] as List).single as Map;
      expect(exercise['targetReps'], '6-8');
      expect(exercise['notes'], 'Tempo 3-1-1');
      expect(exercise['restSeconds'], 150);
      expect(exercise['progressionStepKg'], 2.5);
    });

    test("programme assigné : le nom du coach accompagne l'assignation", () async {
      await json(await send('PUT', '/coach/athletes/${athlete.id}/program',
          token: coach.token, body: {'type': 'builtin', 'code': 'fullBody', 'name': 'Full Body'}));
      final assignment = (await json(await send('GET', '/athlete/assigned-program', token: athlete.token)))['assignment'];
      expect(assignment['coachName'], 'Coach');
      expect(assignment['programCode'], 'fullBody');
    });
  });
}
