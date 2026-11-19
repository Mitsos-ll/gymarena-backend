import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/src/app.dart';
import 'test_config.dart';

/// Distance, durée, vitesse, calories et niveau de la machine d'une série doivent revenir telles
/// quelles dans le snapshot : sans elles, une séance de cardio ou de gainage
/// restaurée sur un nouvel appareil revient vide.
void main() {
  late GymTrackBackend backend;
  late String token;

  setUp(() async {
    backend = GymTrackBackend(testConfig());
    final res = await backend.handler(Request(
      'POST',
      Uri.parse('http://localhost/auth/register'),
      body: jsonEncode({
        'email': 'cardio@example.com',
        'password': 'password123',
        'displayName': 'Cardio',
      }),
      headers: {'Content-Type': 'application/json'},
    ));
    token = (jsonDecode(await res.readAsString()) as Map)['accessToken'] as String;
  });

  tearDown(() => backend.close());

  Future<Response> send(String method, String path, [Object? body]) async {
    return backend.handler(Request(
      method,
      Uri.parse('http://localhost$path'),
      body: body == null ? null : jsonEncode(body),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    ));
  }

  Map<String, dynamic> workout(int localId) => {
        'localId': localId,
        'workoutDate': '2026-11-18',
        'durationSeconds': 1800,
        'exercises': [
          {
            'exerciseNameSnapshot': 'Running extérieur',
            'exerciseOrder': 1,
            'sets': [
              {
                'setNumber': 1,
                'weightKg': 0,
                'reps': 0,
                'distanceM': 5000.0,
                'effortSeconds': 1500,
                'speedMs': 3.33,
                'calories': 350.0,
                'level': 2.5,
                'setType': 'normal',
              },
            ],
          },
          {
            'exerciseNameSnapshot': 'Copenhagen Plank',
            'exerciseOrder': 2,
            'sets': [
              {
                'setNumber': 1,
                'weightKg': 0,
                'reps': 12,
                'volumeReps': 24,
                'effortSeconds': 45,
                'setType': 'normal',
              },
            ],
          },
        ],
      };

  Future<List<Map<String, dynamic>>> snapshotSets() async {
    final res = await send('GET', '/me/snapshot');
    expect(res.statusCode, 200);
    final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
    final workouts = (body['workouts'] as List).cast<Map<String, dynamic>>();
    expect(workouts, hasLength(1));
    final exercises = (workouts.single['exercises'] as List).cast<Map<String, dynamic>>()
      ..sort((a, b) => (a['exerciseOrder'] as int).compareTo(b['exerciseOrder'] as int));
    return [
      for (final ex in exercises) ((ex['sets'] as List).single as Map<String, dynamic>),
    ];
  }

  void expectRoundTrip(List<Map<String, dynamic>> sets) {
    final run = sets[0];
    expect(run['distanceM'], 5000.0);
    expect(run['effortSeconds'], 1500);
    expect(run['speedMs'], 3.33);
    expect(run['calories'], 350.0);
    expect(run['level'], 2.5);

    final plank = sets[1];
    expect(plank['effortSeconds'], 45);
    expect(plank['distanceM'], isNull);
    expect(plank['level'], isNull);
    expect(plank['volumeReps'], 24);
  }

  test('envoi groupé : les métriques cardio reviennent dans le snapshot', () async {
    final res = await send('POST', '/workouts/batch', {'workouts': [workout(1)]});
    expect(res.statusCode, 200);
    expectRoundTrip(await snapshotSets());
  });

  test('envoi unitaire : idem, volume_reps compris', () async {
    final res = await send('POST', '/workouts', workout(1));
    expect(res.statusCode, 200);
    expectRoundTrip(await snapshotSets());
  });
}
