import 'package:test/test.dart';

import '../lib/src/services/apple_token_service.dart';
import '../lib/src/utils/api_exception.dart';
import 'fake_apple.dart';

void main() {
  const nonce = 'raw-nonce-value-0123456789';

  late FakeApple apple;
  late AppleTokenService service;
  late DateTime now;

  setUp(() {
    now = DateTime.utc(2026, 10, 14, 12);
    apple = FakeApple();
    service = apple.service(now: () => now);
  });

  tearDown(() => service.close());

  Future<AppleTokenPayload> verify(String token, {String rawNonce = nonce}) =>
      service.verifyIdentityToken(token, rawNonce: rawNonce);

  String validToken({String? email = 'user@example.com'}) =>
      apple.identityToken(rawNonce: nonce, now: now, email: email);

  Matcher rejectedWith(int statusCode, [String? messagePart]) => throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', statusCode)
            .having(
              (e) => e.message,
              'message',
              messagePart == null ? isNotEmpty : contains(messagePart),
            ),
      );

  group('claims', () {
    test('accepts a valid token and returns its claims', () async {
      final payload = await verify(validToken(email: 'User@Example.com'));

      expect(payload.subject, 'apple-sub-1');
      expect(payload.email, 'user@example.com');
      expect(payload.emailVerified, isTrue);
      expect(payload.isPrivateEmail, isFalse);
      expect(payload.expiresAt, now.add(const Duration(minutes: 10)));
    });

    test('reads boolean claims as well as the string form', () async {
      final payload = await verify(apple.identityToken(
        rawNonce: nonce,
        now: now,
        emailVerified: true,
        isPrivateEmail: true,
      ));

      expect(payload.emailVerified, isTrue);
      expect(payload.isPrivateEmail, isTrue);
    });

    test('returns a null email when the token has none', () async {
      final payload = await verify(validToken(email: null));

      expect(payload.email, isNull);
    });

    test('rejects a token for another app (audience)', () async {
      final token = apple.identityToken(
        rawNonce: nonce,
        now: now,
        aud: 'com.someone.else',
      );

      await expectLater(verify(token), rejectedWith(401, 'audience'));
    });

    test('rejects a token from another issuer', () async {
      final token = apple.identityToken(
        rawNonce: nonce,
        now: now,
        iss: 'https://accounts.google.com',
      );

      await expectLater(verify(token), rejectedWith(401, 'issuer'));
    });

    test('rejects an expired token', () async {
      final token = apple.identityToken(
        rawNonce: nonce,
        now: now,
        expiresIn: const Duration(minutes: -1),
      );

      await expectLater(verify(token), rejectedWith(401, 'expired'));
    });

    test('rejects a token without nonce', () async {
      final token = apple.identityToken(
        rawNonce: nonce,
        now: now,
        includeNonce: false,
      );

      await expectLater(verify(token), rejectedWith(401, 'nonce'));
    });

    test('rejects a token whose nonce does not match the raw nonce', () async {
      await expectLater(
        verify(validToken(), rawNonce: 'another-attempt-nonce'),
        rejectedWith(401, 'nonce'),
      );
    });

    test('rejects a nonce that was sent to Apple without hashing', () async {
      final token = apple.identityToken(
        rawNonce: nonce,
        now: now,
        nonceClaim: nonce,
      );

      await expectLater(verify(token), rejectedWith(401, 'nonce'));
    });

    test('rejects an email Apple did not verify', () async {
      final token = apple.identityToken(
        rawNonce: nonce,
        now: now,
        emailVerified: 'false',
      );

      await expectLater(verify(token), rejectedWith(401, 'not verified'));
    });

    test('rejects a token without subject', () async {
      final token = apple.identityToken(rawNonce: nonce, now: now, sub: '');

      await expectLater(verify(token), rejectedWith(401, 'claims'));
    });
  });

  group('signature', () {
    test('rejects a token signed by another key under a known kid', () async {
      final token = apple.identityToken(
        rawNonce: nonce,
        now: now,
        signWith: FakeApple.generateKey('key-1'),
      );

      await expectLater(verify(token), rejectedWith(401, 'signature'));
    });

    test('rejects a token signed with a kid Apple does not publish', () async {
      apple.addKey('key-ghost', publish: false);
      final token = apple.identityToken(
        rawNonce: nonce,
        now: now,
        kid: 'key-ghost',
      );

      await expectLater(verify(token), rejectedWith(401, 'signature'));
    });

    test('rejects an HS256 token (algorithm confusion)', () async {
      await expectLater(
        verify(apple.hmacToken(rawNonce: nonce)),
        rejectedWith(401, 'Malformed'),
      );
    });

    test('rejects an unsigned token (alg none)', () async {
      await expectLater(
        verify(apple.unsignedToken(rawNonce: nonce)),
        rejectedWith(401, 'Malformed'),
      );
    });

    test('rejects a token whose payload was tampered with', () async {
      final parts = validToken().split('.');
      final other = apple
          .identityToken(rawNonce: nonce, now: now, sub: 'someone-else')
          .split('.');
      final forged = '${parts[0]}.${other[1]}.${parts[2]}';

      await expectLater(verify(forged), rejectedWith(401, 'signature'));
    });

    test('rejects malformed tokens', () async {
      for (final garbage in ['', 'abc', 'a.b', 'a.b.c', '....']) {
        await expectLater(verify(garbage), rejectedWith(401, 'Malformed'),
            reason: 'token: "$garbage"');
      }
    });
  });

  group('signing keys', () {
    test('downloads the keys once and reuses them', () async {
      await verify(validToken());
      await verify(validToken());

      expect(apple.keysRequestCount, 1);
    });

    test('downloads the keys once for simultaneous verifications', () async {
      await Future.wait([
        for (var i = 0; i < 5; i++) verify(validToken()),
      ]);

      expect(apple.keysRequestCount, 1);
    });

    test('downloads the keys again after an hour', () async {
      await verify(validToken());

      now = now.add(const Duration(minutes: 59));
      await verify(validToken());
      expect(apple.keysRequestCount, 1);

      now = now.add(const Duration(minutes: 2));
      await verify(validToken());
      expect(apple.keysRequestCount, 2);
    });

    test('picks up a key Apple just published, without hammering Apple', () async {
      await verify(validToken());
      apple.addKey('key-2');
      final rotated = apple.identityToken(rawNonce: nonce, now: now, kid: 'key-2');

      // Dans la minute qui suit le dernier téléchargement : pas d'aller-retour.
      now = now.add(const Duration(seconds: 30));
      await expectLater(verify(rotated), rejectedWith(401, 'signature'));
      expect(apple.keysRequestCount, 1);

      now = now.add(const Duration(seconds: 31));
      final payload = await verify(rotated);
      expect(payload.subject, 'apple-sub-1');
      expect(apple.keysRequestCount, 2);
    });

    test('answers 503 while Apple keys cannot be downloaded, then recovers', () async {
      apple.keysStatusCode = 500;

      await expectLater(verify(validToken()), rejectedWith(503));
      await expectLater(verify(validToken()), rejectedWith(503));
      // Le second essai tombe dans le délai minimal : pas de nouvel appel.
      expect(apple.keysRequestCount, 1);

      apple.keysStatusCode = 200;
      now = now.add(const Duration(minutes: 2));
      final payload = await verify(validToken());

      expect(payload.subject, 'apple-sub-1');
      expect(apple.keysRequestCount, 2);
    });

    test('keeps using cached keys when a refresh fails', () async {
      await verify(validToken());

      now = now.add(const Duration(hours: 2));
      apple.keysStatusCode = 500;
      final payload = await verify(validToken());

      expect(payload.subject, 'apple-sub-1');
      expect(apple.keysRequestCount, 2);
    });
  });
}
