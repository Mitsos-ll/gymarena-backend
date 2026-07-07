import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/src/app.dart';
import 'test_config.dart';

void main() {
  late GymTrackBackend backend;

  setUp(() {
    backend = GymTrackBackend(testConfig());
  });

  tearDown(() => backend.close());

  Future<Response> post(String path, Map<String, dynamic> body) async {
    return backend.handler(
      Request(
        'POST',
        Uri.parse('http://localhost$path'),
        body: jsonEncode(body),
        headers: {'Content-Type': 'application/json'},
      ),
    );
  }

  Future<Response> delete(String path, {String? bearerToken}) async {
    return backend.handler(
      Request(
        'DELETE',
        Uri.parse('http://localhost$path'),
        headers: {
          if (bearerToken != null) 'Authorization': 'Bearer $bearerToken',
        },
      ),
    );
  }

  group('DELETE /me', () {
    test('deletes the account and cascades its workouts', () async {
      final registerRes = await post('/auth/register', {
        'email': 'todelete@example.com',
        'password': 'password123',
        'displayName': 'To Delete',
      });
      final registerBody = jsonDecode(await registerRes.readAsString()) as Map;
      final accessToken = registerBody['accessToken'] as String;

      final workoutRes = await backend.handler(Request(
        'POST',
        Uri.parse('http://localhost/workouts'),
        body: jsonEncode({
          'localId': 1,
          'workoutDate': '2026-01-01',
          'durationSeconds': 600,
          'exercises': [],
        }),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
      ));
      expect(workoutRes.statusCode, 200);

      final deleteRes = await delete('/me', bearerToken: accessToken);
      expect(deleteRes.statusCode, 200);

      final meAfterDelete = await backend.handler(Request(
        'GET',
        Uri.parse('http://localhost/me'),
        headers: {'Authorization': 'Bearer $accessToken'},
      ));
      expect(meAfterDelete.statusCode, 401);

      final db = backend.database.raw;
      final userRows = db.select(
        'SELECT * FROM users WHERE email = ?',
        ['todelete@example.com'],
      );
      expect(userRows, isEmpty);

      final workoutRows = db.select(
        "SELECT * FROM workouts WHERE workout_date = '2026-01-01'",
      );
      expect(workoutRows, isEmpty);
    });

    test('rejects without a valid token', () async {
      final res = await delete('/me', bearerToken: 'not-a-real-token');
      expect(res.statusCode, 401);
    });

    test('rejects without any token', () async {
      final res = await delete('/me');
      expect(res.statusCode, 401);
    });
  });
}
