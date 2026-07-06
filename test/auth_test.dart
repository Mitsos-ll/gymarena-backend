import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/src/app.dart';
import '../lib/src/services/google_token_service.dart';
import 'test_config.dart';

void main() {
  late GymTrackBackend backend;

  setUp(() {
    backend = GymTrackBackend(testConfig());
  });

  tearDown(() => backend.close());

  // ── Helpers ────────────────────────────────────────────────────────────────

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

  // ── Forgot / reset password ──────────────────────────────────────────────────

  group('POST /auth/forgot-password + /auth/reset-password', () {
    test('forgot-password returns ok for both existing and unknown emails', () async {
      await post('/auth/register', {
        'email': 'forgot@example.com',
        'password': 'password123',
      });

      final known = await post('/auth/forgot-password', {'email': 'forgot@example.com'});
      final unknown = await post('/auth/forgot-password', {'email': 'nobody@example.com'});

      expect(known.statusCode, 200);
      expect(unknown.statusCode, 200);
      final knownBody = jsonDecode(await known.readAsString()) as Map;
      final unknownBody = jsonDecode(await unknown.readAsString()) as Map;
      expect(knownBody['ok'], true);
      expect(unknownBody['ok'], true);
    });

    test('reset-password with a valid code changes the password and revokes sessions', () async {
      final regRes = await post('/auth/register', {
        'email': 'reset@example.com',
        'password': 'oldpassword123',
      });
      final accessToken =
          (jsonDecode(await regRes.readAsString()) as Map)['accessToken'] as String;

      final result = backend.userRepository.requestPasswordReset('reset@example.com');
      expect(result.code, isNotNull);

      final resetRes = await post('/auth/reset-password', {
        'email': 'reset@example.com',
        'code': result.code,
        'newPassword': 'newpassword456',
      });
      expect(resetRes.statusCode, 200);

      // L'ancien access token doit être révoqué.
      final meRes = await backend.handler(
        Request('GET', Uri.parse('http://localhost/me'),
            headers: {'Authorization': 'Bearer $accessToken'}),
      );
      expect(meRes.statusCode, 401);

      // L'ancien mot de passe ne fonctionne plus, le nouveau oui.
      final oldLogin = await post('/auth/login', {
        'email': 'reset@example.com',
        'password': 'oldpassword123',
      });
      expect(oldLogin.statusCode, 401);

      final newLogin = await post('/auth/login', {
        'email': 'reset@example.com',
        'password': 'newpassword456',
      });
      expect(newLogin.statusCode, 200);
    });

    test('reset-password rejects an invalid code with 400', () async {
      await post('/auth/register', {
        'email': 'badcode@example.com',
        'password': 'password123',
      });

      final res = await post('/auth/reset-password', {
        'email': 'badcode@example.com',
        'code': '000000',
        'newPassword': 'newpassword456',
      });
      expect(res.statusCode, 400);
    });

    test('reset-password rejects reusing an already-used code with 400', () async {
      await post('/auth/register', {
        'email': 'reuse@example.com',
        'password': 'password123',
      });
      final result = backend.userRepository.requestPasswordReset('reuse@example.com');

      final first = await post('/auth/reset-password', {
        'email': 'reuse@example.com',
        'code': result.code,
        'newPassword': 'newpassword456',
      });
      expect(first.statusCode, 200);

      final second = await post('/auth/reset-password', {
        'email': 'reuse@example.com',
        'code': result.code,
        'newPassword': 'anotherpassword789',
      });
      expect(second.statusCode, 400);
    });
  });

  // ── Google sign-in ───────────────────────────────────────────────────────────

  group('signInWithGoogle', () {
    GoogleTokenPayload payload(String email, {String subject = 'google-sub-1'}) =>
        GoogleTokenPayload(
          subject: subject,
          email: email,
          displayName: 'Google User',
          photoUrl: 'https://example.com/p.png',
          emailVerified: true,
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        );

    test('links Google to an existing email/password account instead of crashing',
        () async {
      // Un compte gymtrack existe déjà avec cet email (cas du testeur : 500).
      await post('/auth/register', {
        'email': 'collide@example.com',
        'password': 'password123',
      });

      // Le login Google sur le même email doit rattacher, pas violer UNIQUE(email).
      final session = backend.userRepository
          .signInWithGoogle(payload('collide@example.com'));

      expect(session.user.email, 'collide@example.com');
      expect(session.accessToken, isA<String>());

      // Un second login Google (même subject) réutilise le même compte.
      final again = backend.userRepository
          .signInWithGoogle(payload('collide@example.com'));
      expect(again.user.id, session.user.id);
    });

    test('creates a fresh account when the email is unknown', () async {
      final session = backend.userRepository
          .signInWithGoogle(payload('brandnew@example.com', subject: 'sub-new'));
      expect(session.user.email, 'brandnew@example.com');
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
