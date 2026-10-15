import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/src/app.dart';
import '../lib/src/services/google_token_service.dart';
import 'fake_apple.dart';
import 'test_config.dart';

void main() {
  const nonce = 'raw-nonce-value-0123456789';
  const relayEmail = 'x7k2q9@privaterelay.appleid.com';

  late FakeApple apple;
  late GymTrackBackend backend;

  setUp(() {
    apple = FakeApple();
    backend = GymTrackBackend(testConfig(), appleTokenService: apple.service());
  });

  tearDown(() => backend.close());

  // ── Helpers ────────────────────────────────────────────────────────────────

  Future<Response> post(String path, Map<String, dynamic> body) async =>
      await backend.handler(Request(
        'POST',
        Uri.parse('http://localhost$path'),
        body: jsonEncode(body),
        headers: {'Content-Type': 'application/json'},
      ));

  Future<Response> authedRequest(String method, String path, String accessToken) async =>
      await backend.handler(Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: {'Authorization': 'Bearer $accessToken'},
      ));

  /// POST /auth/apple avec un token valide signé par le faux Apple.
  Future<Response> signInWithApple({
    String sub = 'apple-sub-1',
    String? email = 'user@example.com',
    Object isPrivateEmail = 'false',
    Object? fullName,
  }) =>
      post('/auth/apple', {
        'identityToken': apple.identityToken(
          rawNonce: nonce,
          sub: sub,
          email: email,
          isPrivateEmail: isPrivateEmail,
        ),
        'nonce': nonce,
        if (fullName != null) 'fullName': fullName,
      });

  Future<Map<String, dynamic>> bodyOf(Response res) async =>
      jsonDecode(await res.readAsString()) as Map<String, dynamic>;

  int countUsers() =>
      backend.database.raw.select('SELECT COUNT(*) AS n FROM users').first['n'] as int;

  // ── Création et reconnexion ────────────────────────────────────────────────

  group('POST /auth/apple — accounts', () {
    test('creates an account from a valid token, named after the client hint', () async {
      final res = await signInWithApple(
        email: 'new@example.com',
        fullName: 'Jean Dupont',
      );

      expect(res.statusCode, 200);
      final body = await bodyOf(res);
      expect(body['accessToken'], isA<String>());
      expect(body['refreshToken'], isA<String>());
      expect(body['user']['email'], 'new@example.com');
      expect(body['user']['displayName'], 'Jean Dupont');
      expect(body['profile']['onboardingCompleted'], false);
    });

    test('signs the same user back in and keeps the chosen pseudo', () async {
      final first = await bodyOf(await signInWithApple(fullName: 'Jean Dupont'));

      // Apple ne renvoie plus le nom aux connexions suivantes ; et même s'il
      // arrivait, le pseudo d'un profil existant ne doit jamais être écrasé.
      final second = await bodyOf(await signInWithApple(fullName: 'Autre Nom'));

      expect(second['user']['id'], first['user']['id']);
      expect(second['user']['displayName'], 'Jean Dupont');
      expect(countUsers(), 1);
    });

    test('links to an existing email/password account with the same email', () async {
      final registered = await bodyOf(await post('/auth/register', {
        'email': 'user@example.com',
        'password': 'password123',
        'displayName': 'Existing',
      }));

      final res = await signInWithApple(email: 'user@example.com');

      expect(res.statusCode, 200);
      final body = await bodyOf(res);
      expect(body['user']['id'], registered['user']['id']);
      expect(body['user']['displayName'], 'Existing');
      expect(countUsers(), 1);

      final providers = backend.database.raw
          .select('SELECT provider FROM user_auth_accounts WHERE user_id=? ORDER BY provider',
              [registered['user']['id']])
          .map((row) => row['provider'])
          .toList();
      expect(providers, ['apple', 'gymtrack']);
    });

    test('does not attach a hidden relay address to someone else', () async {
      await post('/auth/register', {
        'email': 'user@example.com',
        'password': 'password123',
      });

      final res = await signInWithApple(
        sub: 'apple-sub-hidden',
        email: relayEmail,
        isPrivateEmail: 'true',
      );

      expect(res.statusCode, 200);
      expect((await bodyOf(res))['user']['email'], relayEmail);
      expect(countUsers(), 2);
    });

    test('lets the same Apple user come back with a different email', () async {
      final first = await bodyOf(await signInWithApple(email: 'user@example.com'));

      final second = await bodyOf(await signInWithApple(email: relayEmail));

      expect(second['user']['id'], first['user']['id']);
      // L'email du compte n'est pas réécrit par Apple.
      expect(second['user']['email'], 'user@example.com');
    });

    test('does not erase the photo that Google set', () async {
      backend.userRepository.signInWithGoogle(GoogleTokenPayload(
        subject: 'google-sub-1',
        email: 'user@example.com',
        displayName: 'Google User',
        photoUrl: 'https://example.com/p.png',
        emailVerified: true,
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      ));

      final body = await bodyOf(await signInWithApple(email: 'user@example.com'));

      expect(body['user']['photoUrl'], 'https://example.com/p.png');
      expect(countUsers(), 1);
    });
  });

  // ── Pseudo par défaut ──────────────────────────────────────────────────────

  group('POST /auth/apple — default pseudo', () {
    test('uses the real email local part when no name is sent', () async {
      final body = await bodyOf(await signInWithApple(email: 'sam.lifter@example.com'));

      expect(body['user']['displayName'], 'sam.lifter');
    });

    test('falls back to a neutral pseudo behind a hidden relay address', () async {
      final body = await bodyOf(await signInWithApple(
        email: relayEmail,
        isPrivateEmail: 'true',
      ));

      expect(body['user']['displayName'], 'Athlète');
    });

    test('adds a numeric suffix when the pseudo is already taken', () async {
      await signInWithApple(sub: 'sub-a', email: 'a@example.com', fullName: 'Alex');

      final body = await bodyOf(await signInWithApple(
        sub: 'sub-b',
        email: 'b@example.com',
        fullName: 'Alex',
      ));

      expect(body['user']['displayName'], 'Alex2');
    });

    test('ignores an unusable name instead of failing the sign-in', () async {
      final body = await bodyOf(await signInWithApple(
        email: 'ctrl@example.com',
        fullName: 'Bad\u0007Name',
      ));

      expect(body['user']['displayName'], 'ctrl');
    });
  });

  // ── Email absent ───────────────────────────────────────────────────────────

  group('POST /auth/apple — token without email', () {
    test('refuses to create an account and says how to recover', () async {
      final res = await signInWithApple(sub: 'sub-no-email', email: null);

      expect(res.statusCode, 400);
      expect((await bodyOf(res))['message'], contains('Sign in with Apple'));
      expect(countUsers(), 0);
    });

    test('still signs in a user Apple already linked', () async {
      final first = await bodyOf(await signInWithApple(sub: 'sub-1', email: 'user@example.com'));

      final res = await signInWithApple(sub: 'sub-1', email: null);

      expect(res.statusCode, 200);
      expect((await bodyOf(res))['user']['id'], first['user']['id']);
    });
  });

  // ── Requêtes invalides ─────────────────────────────────────────────────────

  group('POST /auth/apple — bad requests', () {
    test('requires an identityToken', () async {
      final res = await post('/auth/apple', {'nonce': nonce});

      expect(res.statusCode, 400);
      expect((await bodyOf(res))['message'], 'identityToken is required.');
    });

    test('requires a nonce', () async {
      final res = await post('/auth/apple', {
        'identityToken': apple.identityToken(rawNonce: nonce),
      });

      expect(res.statusCode, 400);
      expect((await bodyOf(res))['message'], 'nonce is required.');
    });

    test('rejects a token bound to another nonce with 401', () async {
      final res = await post('/auth/apple', {
        'identityToken': apple.identityToken(rawNonce: nonce),
        'nonce': 'replayed-from-another-attempt',
      });

      expect(res.statusCode, 401);
      expect(countUsers(), 0);
    });

    test('rejects a forged token with 401', () async {
      final res = await post('/auth/apple', {
        'identityToken': apple.identityToken(
          rawNonce: nonce,
          signWith: FakeApple.generateKey('key-1'),
        ),
        'nonce': nonce,
      });

      expect(res.statusCode, 401);
      expect(countUsers(), 0);
    });
  });

  // ── Suppression de compte ──────────────────────────────────────────────────

  group('account deletion', () {
    test('removes the Apple link: the next sign-in starts a fresh account', () async {
      final first = await bodyOf(await signInWithApple(email: 'user@example.com'));

      final deleted = await authedRequest('DELETE', '/me', first['accessToken'] as String);
      expect(deleted.statusCode, anyOf(200, 204));
      expect(countUsers(), 0);

      final again = await bodyOf(await signInWithApple(email: 'user@example.com'));
      expect(again['user']['id'], isNot(first['user']['id']));
    });

    test('the session issued by Apple sign-in can read /me', () async {
      final session = await bodyOf(await signInWithApple());

      final me = await authedRequest('GET', '/me', session['accessToken'] as String);

      expect(me.statusCode, 200);
      expect((await bodyOf(me))['user']['id'], session['user']['id']);
    });
  });
}
