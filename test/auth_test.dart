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

  // ── Helpers ────────────────────────────────────────────────────────────────

  Future<Response> post(String path, Map<String, dynamic> body) {
    return backend.handler(
      Request(
        'POST',
        Uri.parse('http://localhost$path'),
        body: jsonEncode(body),
        headers: {'Content-Type': 'application/json'},
      ),
    );
  }

  // ── Register ───────────────────────────────────────────────────────────────

  group('POST /auth/register', () {
    test('creates a new user and returns tokens', () async {
      final res = await post('/auth/register', {
        'email': 'test@example.com',
        'password': 'password123',
        'displayName': 'Test User',
      });

      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString()) as Map;
      expect(body['accessToken'], isA<String>());
      expect(body['refreshToken'], isA<String>());
      expect(body['user']['email'], 'test@example.com');
    });

    test('rejects duplicate email with 409', () async {
      await post('/auth/register', {
        'email': 'dup@example.com',
        'password': 'password123',
      });
      final res = await post('/auth/register', {
        'email': 'dup@example.com',
        'password': 'password123',
      });
      expect(res.statusCode, 409);
    });

    test('rejects missing email with 400', () async {
      final res = await post('/auth/register', {'password': 'password123'});
      expect(res.statusCode, 400);
    });

    test('rejects short password with 400', () async {
      final res = await post('/auth/register', {
        'email': 'short@example.com',
        'password': '1234567',
      });
      expect(res.statusCode, 400);
    });

    test('rejects invalid email format with 400', () async {
      final res = await post('/auth/register', {
        'email': 'not-an-email',
        'password': 'password123',
      });
      expect(res.statusCode, 400);
    });
  });

  // ── Login ──────────────────────────────────────────────────────────────────

  group('POST /auth/login', () {
    setUp(() async {
      await post('/auth/register', {
        'email': 'login@example.com',
        'password': 'password123',
      });
    });

    test('returns tokens for valid credentials', () async {
      final res = await post('/auth/login', {
        'email': 'login@example.com',
        'password': 'password123',
      });
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString()) as Map;
      expect(body['accessToken'], isA<String>());
    });

    test('rejects wrong password with 401', () async {
      final res = await post('/auth/login', {
        'email': 'login@example.com',
        'password': 'wrongpassword',
      });
      expect(res.statusCode, 401);
    });

    test('rejects unknown email with 401', () async {
      final res = await post('/auth/login', {
        'email': 'nobody@example.com',
        'password': 'password123',
      });
      expect(res.statusCode, 401);
    });
  });

  // ── Refresh ────────────────────────────────────────────────────────────────

  group('POST /auth/refresh', () {
    test('issues new tokens for valid refresh token', () async {
      final regRes = await post('/auth/register', {
        'email': 'refresh@example.com',
        'password': 'password123',
      });
      final regBody = jsonDecode(await regRes.readAsString()) as Map;
      final refreshToken = regBody['refreshToken'] as String;

      final res = await post('/auth/refresh', {'refreshToken': refreshToken});
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString()) as Map;
      expect(body['accessToken'], isA<String>());
    });

    test('rejects invalid refresh token with 401', () async {
      final res = await post('/auth/refresh', {'refreshToken': 'bad-token'});
      expect(res.statusCode, 401);
    });
  });

  // ── Logout ─────────────────────────────────────────────────────────────────

  group('POST /auth/logout', () {
    test('succeeds and invalidates the access token', () async {
      final regRes = await post('/auth/register', {
        'email': 'logout@example.com',
        'password': 'password123',
      });
      final accessToken =
          (jsonDecode(await regRes.readAsString()) as Map)['accessToken'] as String;

      final logoutRes = await backend.handler(
        Request('POST', Uri.parse('http://localhost/auth/logout'),
            headers: {'Authorization': 'Bearer $accessToken'}),
      );
      expect(logoutRes.statusCode, 200);

      // /me should now return 401
      final meRes = await backend.handler(
        Request('GET', Uri.parse('http://localhost/me'),
            headers: {'Authorization': 'Bearer $accessToken'}),
      );
      expect(meRes.statusCode, 401);
    });
  });
}
