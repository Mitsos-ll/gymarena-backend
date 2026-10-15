import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/src/app.dart';
import '../lib/src/services/apple_rest_service.dart';
import 'fake_apple.dart';
import 'test_config.dart';

/// Faux serveur REST d'Apple (échange de code + révocation).
class FakeAppleRestServer {
  final tokenRequests = <http.Request>[];
  final revokeRequests = <http.Request>[];

  int tokenStatus = 200;
  int revokeStatus = 200;
  String refreshToken = 'apple-refresh-1';

  /// `sub` de l'id_token renvoyé ; doit être celui du compte qui se connecte.
  String idTokenSubject = 'apple-sub-1';

  late final http.Client client = MockClient((request) async {
    if (request.url.path == '/auth/token') {
      tokenRequests.add(request);
      if (tokenStatus != 200) return http.Response('{"error":"invalid_grant"}', tokenStatus);
      return http.Response(
        jsonEncode({
          'access_token': 'access',
          'refresh_token': refreshToken,
          'id_token': fakeIdToken(idTokenSubject),
        }),
        200,
      );
    }
    if (request.url.path == '/auth/revoke') {
      revokeRequests.add(request);
      return http.Response('', revokeStatus);
    }
    return http.Response('unexpected', 404);
  });

  AppleRestService service({bool configured = true}) => AppleRestService(
        clientId: 'com.gymarena.app',
        teamId: configured ? 'S869NWC695' : '',
        keyId: configured ? 'D3GYYWRJJ7' : '',
        privateKey: configured ? testApplePem : '',
        client: client,
      );
}

void main() {
  const nonce = 'raw-nonce-value-0123456789';

  late FakeApple apple;
  late FakeAppleRestServer appleRest;
  late GymTrackBackend backend;

  GymTrackBackend backendWith(AppleRestService rest) => GymTrackBackend(
        testConfig(),
        appleTokenService: apple.service(),
        appleRestService: rest,
      );

  setUp(() {
    apple = FakeApple();
    appleRest = FakeAppleRestServer();
    backend = backendWith(appleRest.service());
  });

  tearDown(() => backend.close());

  Future<Response> post(String path, Map<String, dynamic> body) async =>
      await backend.handler(Request(
        'POST',
        Uri.parse('http://localhost$path'),
        body: jsonEncode(body),
        headers: {'Content-Type': 'application/json'},
      ));

  Future<Response> deleteMe(String accessToken) async =>
      await backend.handler(Request(
        'DELETE',
        Uri.parse('http://localhost/me'),
        headers: {'Authorization': 'Bearer $accessToken'},
      ));

  Future<Map<String, dynamic>> signInWithApple({
    String sub = 'apple-sub-1',
    String? authorizationCode = 'auth-code-1',
  }) async {
    final res = await post('/auth/apple', {
      'identityToken': apple.identityToken(rawNonce: nonce, sub: sub),
      'nonce': nonce,
      if (authorizationCode != null) 'authorizationCode': authorizationCode,
    });
    expect(res.statusCode, 200);
    return jsonDecode(await res.readAsString()) as Map<String, dynamic>;
  }

  String? storedRefreshToken(String userId) {
    final rows = backend.database.raw.select(
      "SELECT provider_refresh_token FROM user_auth_accounts WHERE user_id=? AND provider='apple'",
      [userId],
    );
    return rows.isEmpty ? null : rows.first['provider_refresh_token'] as String?;
  }

  group('sign-in with an authorization code', () {
    test('exchanges the code and keeps the refresh token for later revocation', () async {
      final session = await signInWithApple();

      expect(appleRest.tokenRequests, hasLength(1));
      expect(appleRest.tokenRequests.single.bodyFields['code'], 'auth-code-1');
      expect(storedRefreshToken(session['user']['id'] as String), 'apple-refresh-1');
    });

    test('does not call Apple when the app sent no code', () async {
      final session = await signInWithApple(authorizationCode: null);

      expect(appleRest.tokenRequests, isEmpty);
      expect(storedRefreshToken(session['user']['id'] as String), isNull);
    });

    test('still signs in when Apple refuses the code', () async {
      appleRest.tokenStatus = 400;

      final session = await signInWithApple();

      expect(session['accessToken'], isA<String>());
      expect(storedRefreshToken(session['user']['id'] as String), isNull);
    });

    test('ignores a code that belongs to another Apple account', () async {
      appleRest.idTokenSubject = 'someone-else';

      final session = await signInWithApple();

      expect(storedRefreshToken(session['user']['id'] as String), isNull);
    });

    test('does nothing when the server has no Apple key configured', () async {
      await backend.close();
      backend = backendWith(appleRest.service(configured: false));

      final session = await signInWithApple();

      expect(appleRest.tokenRequests, isEmpty);
      expect(storedRefreshToken(session['user']['id'] as String), isNull);
    });
  });

  group('account deletion', () {
    test('revokes the Apple token and then deletes the account', () async {
      final session = await signInWithApple();

      final res = await deleteMe(session['accessToken'] as String);

      expect(res.statusCode, 200);
      expect(appleRest.revokeRequests, hasLength(1));
      expect(appleRest.revokeRequests.single.bodyFields['token'], 'apple-refresh-1');
      expect(
        backend.database.raw.select('SELECT id FROM users WHERE id=?', [session['user']['id']]),
        isEmpty,
      );
    });

    test('does not call Apple for an account without an Apple token', () async {
      final registered = await post('/auth/register', {
        'email': 'plain@example.com',
        'password': 'password123',
      });
      final body = jsonDecode(await registered.readAsString()) as Map;

      final res = await deleteMe(body['accessToken'] as String);

      expect(res.statusCode, 200);
      expect(appleRest.revokeRequests, isEmpty);
    });

    test('still deletes the account when Apple refuses the revocation', () async {
      final session = await signInWithApple();
      appleRest.revokeStatus = 500;

      final res = await deleteMe(session['accessToken'] as String);

      expect(res.statusCode, 200);
      expect(appleRest.revokeRequests, hasLength(1));
      expect(
        backend.database.raw.select('SELECT id FROM users WHERE id=?', [session['user']['id']]),
        isEmpty,
      );
    });
  });
}
