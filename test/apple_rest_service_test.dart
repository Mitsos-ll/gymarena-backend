import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jose/jose.dart';
import 'package:test/test.dart';

import '../lib/src/services/apple_rest_service.dart';
import 'fake_apple.dart';

void main() {
  final fixedNow = DateTime.utc(2026, 10, 15, 12);

  AppleRestService service({
    String teamId = 'S869NWC695',
    String keyId = 'D3GYYWRJJ7',
    String privateKey = testApplePem,
    http.Client? client,
  }) =>
      AppleRestService(
        clientId: 'com.gymarena.app',
        teamId: teamId,
        keyId: keyId,
        privateKey: privateKey,
        client: client ?? MockClient((_) async => throw StateError('no network expected')),
        now: () => fixedNow,
      );

  group('normalizeApplePrivateKey', () {
    test('keeps a PEM as is', () {
      expect(normalizeApplePrivateKey(testApplePem), testApplePem);
    });

    test('restores line breaks written as \\n', () {
      final flattened = testApplePem.replaceAll('\n', r'\n');

      expect(normalizeApplePrivateKey(flattened), testApplePem);
    });

    test('decodes a base64-encoded PEM (single-line secret)', () {
      final encoded = base64.encode(utf8.encode(testApplePem));

      expect(normalizeApplePrivateKey(encoded), testApplePem);
    });

    test('returns an empty string for empty or unreadable values', () {
      expect(normalizeApplePrivateKey(''), '');
      expect(normalizeApplePrivateKey('   '), '');
      expect(normalizeApplePrivateKey('%%% not base64 %%%'), '');
    });
  });

  group('isConfigured', () {
    test('requires team id, key id and a readable key', () {
      expect(service().isConfigured, isTrue);
      expect(service(teamId: '').isConfigured, isFalse);
      expect(service(keyId: '').isConfigured, isFalse);
      expect(service(privateKey: '').isConfigured, isFalse);
    });

    test('never calls Apple when it is not configured', () async {
      final unconfigured = service(privateKey: '');

      expect(await unconfigured.exchangeAuthorizationCode('code'), isNull);
      expect(await unconfigured.revokeRefreshToken('token'), isFalse);
    });
  });

  group('client secret', () {
    Future<(JoseHeader, Map<String, dynamic>)> verified(String secret) async {
      final jws = JsonWebSignature.fromCompactSerialization(secret);
      final store = JsonWebKeyStore()
        ..addKey(JsonWebKey.fromPem(testApplePem, keyId: 'D3GYYWRJJ7'));
      final payload = await jws.getPayload(store, allowedAlgorithms: const ['ES256']);
      return (jws.commonProtectedHeader, payload.jsonContent as Map<String, dynamic>);
    }

    test('is an ES256 JWT with the key id, signed by the .p8 key', () async {
      final (header, _) = await verified(service().buildClientSecret());

      expect(header.algorithm, 'ES256');
      expect(header.keyId, 'D3GYYWRJJ7');
    });

    test('has a raw 64-byte signature (R || S), as JOSE requires — not DER', () {
      final signature = service().buildClientSecret().split('.')[2];

      expect(base64Url.decode(base64Url.normalize(signature)), hasLength(64));
    });

    test('carries the claims Apple expects', () async {
      final (_, claims) = await verified(service().buildClientSecret());

      expect(claims['iss'], 'S869NWC695');
      expect(claims['sub'], 'com.gymarena.app');
      expect(claims['aud'], 'https://appleid.apple.com');
      expect(claims['iat'], fixedNow.millisecondsSinceEpoch ~/ 1000);
      expect(claims['exp'] - claims['iat'], 300);
    });
  });

  group('exchangeAuthorizationCode', () {
    test('posts the code with a valid client secret and returns the refresh token', () async {
      late http.Request seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode({
            'access_token': 'a',
            'refresh_token': 'refresh-1',
            'id_token': fakeIdToken('apple-sub-1'),
          }),
          200,
        );
      });

      final result = await service(client: client).exchangeAuthorizationCode('the-code');

      expect(seen.url.toString(), 'https://appleid.apple.com/auth/token');
      expect(seen.bodyFields['grant_type'], 'authorization_code');
      expect(seen.bodyFields['code'], 'the-code');
      expect(seen.bodyFields['client_id'], 'com.gymarena.app');
      expect(seen.bodyFields['client_secret'], isNotEmpty);
      expect(result?.refreshToken, 'refresh-1');
      expect(result?.subject, 'apple-sub-1');
    });

    test('returns null when Apple refuses the code', () async {
      final client = MockClient((_) async => http.Response('{"error":"invalid_grant"}', 400));

      expect(await service(client: client).exchangeAuthorizationCode('bad'), isNull);
    });

    test('returns null when the answer has no refresh token or is not JSON', () async {
      for (final body in ['{"access_token":"a"}', 'oops', '[]']) {
        final client = MockClient((_) async => http.Response(body, 200));

        expect(await service(client: client).exchangeAuthorizationCode('c'), isNull,
            reason: 'body: $body');
      }
    });

    test('returns null instead of throwing on a network failure', () async {
      final client = MockClient((_) async => throw http.ClientException('offline'));

      expect(await service(client: client).exchangeAuthorizationCode('c'), isNull);
    });
  });

  group('revokeRefreshToken', () {
    test('posts the token as a refresh_token to the revoke endpoint', () async {
      late http.Request seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response('', 200);
      });

      final revoked = await service(client: client).revokeRefreshToken('refresh-1');

      expect(revoked, isTrue);
      expect(seen.url.toString(), 'https://appleid.apple.com/auth/revoke');
      expect(seen.bodyFields['token'], 'refresh-1');
      expect(seen.bodyFields['token_type_hint'], 'refresh_token');
      expect(seen.bodyFields['client_id'], 'com.gymarena.app');
      expect(seen.bodyFields['client_secret'], isNotEmpty);
    });

    test('returns false when Apple refuses or is unreachable', () async {
      final refusing = MockClient((_) async => http.Response('', 400));
      final offline = MockClient((_) async => throw http.ClientException('offline'));

      expect(await service(client: refusing).revokeRefreshToken('t'), isFalse);
      expect(await service(client: offline).revokeRefreshToken('t'), isFalse);
    });
  });
}
