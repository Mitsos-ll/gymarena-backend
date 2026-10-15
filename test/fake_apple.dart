import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jose/jose.dart';

import '../lib/src/services/apple_token_service.dart';

String sha256Hex(String value) => sha256.convert(utf8.encode(value)).toString();

/// Simule Apple côté tests : génère des clés RSA, publie leur jeu de clés
/// (JWKS) et signe des `identityToken`, sans aucun accès réseau.
class FakeApple {
  FakeApple({this.bundleId = 'com.gymarena.app'}) {
    addKey('key-1');
  }

  final String bundleId;
  final Map<String, JsonWebKey> _privateKeys = {};
  final Set<String> _published = {};

  int keysRequestCount = 0;

  /// Passer à autre chose que 200 simule une panne de l'endpoint de clés.
  int keysStatusCode = 200;

  /// Génère une clé RSA identifiée par [kid]. [publish] false la garde hors du
  /// JWKS, comme une clé qu'Apple n'a pas (encore) mise en ligne.
  JsonWebKey addKey(String kid, {bool publish = true}) {
    final key = generateKey(kid);
    _privateKeys[kid] = key;
    if (publish) _published.add(kid);
    return key;
  }

  void publish(String kid) => _published.add(kid);

  void unpublish(String kid) => _published.remove(kid);

  /// Clé RSA indépendante de ce faux Apple (ex. celle d'un attaquant).
  static JsonWebKey generateKey(String kid) {
    final raw = JsonWebKey.generate('RS256').toJson();
    return JsonWebKey.fromJson({
      for (final field in const ['kty', 'n', 'e', 'd', 'p', 'q']) field: raw[field],
      'kid': kid,
      'use': 'sig',
      'alg': 'RS256',
    });
  }

  late final http.Client client = MockClient((request) async {
    if (request.url.toString() != 'https://appleid.apple.com/auth/keys') {
      return http.Response('unexpected url', 404);
    }
    keysRequestCount++;
    if (keysStatusCode != 200) return http.Response('unavailable', keysStatusCode);

    final keys = [
      for (final kid in _published)
        {
          for (final field in const ['kty', 'n', 'e', 'kid', 'use', 'alg'])
            field: _privateKeys[kid]!.toJson()[field],
        },
    ];
    return http.Response(
      jsonEncode({'keys': keys}),
      200,
      headers: {'content-type': 'application/json'},
    );
  });

  AppleTokenService service({DateTime Function()? now}) =>
      AppleTokenService(bundleId: bundleId, client: client, now: now);

  /// Signe un `identityToken` conforme à ce qu'Apple émet. Les paramètres
  /// permettent de fabriquer chaque variante invalide testée.
  String identityToken({
    required String rawNonce,
    String sub = 'apple-sub-1',
    String? email = 'user@example.com',
    Object emailVerified = 'true',
    Object isPrivateEmail = 'false',
    String iss = AppleTokenService.issuer,
    Object? aud,
    Duration expiresIn = const Duration(minutes: 10),
    DateTime? now,
    bool includeNonce = true,
    String? nonceClaim,
    JsonWebKey? signWith,
    String kid = 'key-1',
  }) {
    final issuedAt = (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch ~/ 1000;
    final claims = <String, Object?>{
      'iss': iss,
      'aud': aud ?? bundleId,
      'iat': issuedAt,
      'exp': issuedAt + expiresIn.inSeconds,
      if (sub.isNotEmpty) 'sub': sub,
      if (includeNonce) 'nonce': nonceClaim ?? sha256Hex(rawNonce),
      'nonce_supported': true,
      if (email != null) 'email': email,
      if (email != null) 'email_verified': emailVerified,
      'is_private_email': isPrivateEmail,
    };
    return _sign(claims, signWith ?? _privateKeys[kid]!, 'RS256');
  }

  /// Token HS256 dont le `kid` désigne une vraie clé RSA : tentative de
  /// confusion d'algorithme.
  String hmacToken({required String rawNonce, String kid = 'key-1'}) {
    final secret = JsonWebKey.fromJson({
      'kty': 'oct',
      'k': base64Url.encode(utf8.encode('a-shared-secret-that-is-long-enough!!')),
      'kid': kid,
    });
    final claims = <String, Object?>{
      'iss': AppleTokenService.issuer,
      'aud': bundleId,
      'exp': DateTime.now().toUtc().add(const Duration(minutes: 10)).millisecondsSinceEpoch ~/ 1000,
      'sub': 'apple-sub-1',
      'nonce': sha256Hex(rawNonce),
    };
    return _sign(claims, secret, 'HS256');
  }

  /// Token « alg: none » : aucune signature.
  String unsignedToken({required String rawNonce, String kid = 'key-1'}) {
    String encode(Map<String, Object?> value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final header = encode({'alg': 'none', 'kid': kid});
    final payload = encode({
      'iss': AppleTokenService.issuer,
      'aud': bundleId,
      'exp': DateTime.now().toUtc().add(const Duration(minutes: 10)).millisecondsSinceEpoch ~/ 1000,
      'sub': 'apple-sub-1',
      'nonce': sha256Hex(rawNonce),
    });
    return '$header.$payload.';
  }

  String _sign(Map<String, Object?> claims, JsonWebKey key, String algorithm) {
    final builder = JsonWebSignatureBuilder()
      ..jsonContent = claims
      ..addRecipient(key, algorithm: algorithm);
    return builder.build().toCompactSerialization();
  }
}
