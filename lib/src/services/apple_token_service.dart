import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:jose/jose.dart';

import '../utils/api_exception.dart';
import '../utils/logger.dart';
import '../utils/secure_compare.dart';

class AppleTokenPayload {
  AppleTokenPayload({
    required this.subject,
    required this.email,
    required this.emailVerified,
    required this.isPrivateEmail,
    required this.expiresAt,
  });

  final String subject;

  /// `null` si le token ne porte pas d'email : Apple ne le garantit pas
  /// (l'utilisateur peut avoir révoqué l'app puis s'être reconnecté).
  final String? email;
  final bool emailVerified;

  /// Adresse de relais `@privaterelay.appleid.com` (« Masquer mon e-mail »).
  final bool isPrivateEmail;
  final DateTime expiresAt;
}

/// Vérifie les `identityToken` de Sign in with Apple (JWT signé RS256).
///
/// Contrairement à Google, Apple n'expose pas d'endpoint `tokeninfo` : la
/// signature est vérifiée localement avec le jeu de clés publiques d'Apple,
/// mis en cache puis rafraîchi quand il expire ou qu'un `kid` inconnu apparaît
/// (rotation des clés).
class AppleTokenService {
  AppleTokenService({
    required this.bundleId,
    http.Client? client,
    DateTime Function()? now,
  })  : _client = client ?? http.Client(),
        _now = now ?? (() => DateTime.now().toUtc());

  static const issuer = 'https://appleid.apple.com';
  static final _keysUri = Uri.https('appleid.apple.com', '/auth/keys');
  static const _keysTtl = Duration(hours: 1);

  /// Délai minimal entre deux téléchargements du jeu de clés. Sans lui, un
  /// appelant non authentifié enverrait des tokens à `kid` aléatoire pour
  /// forcer un aller-retour vers Apple à chaque requête.
  static const _refetchCooldown = Duration(minutes: 1);

  /// Audience attendue : le bundle ID de l'app iOS (flux natif).
  final String bundleId;
  final http.Client _client;
  final DateTime Function() _now;

  JsonWebKeyStore? _keyStore;
  Set<String> _knownKeyIds = const {};
  DateTime? _keysFetchedAt;
  DateTime? _lastFetchAttemptAt;
  Future<void>? _inflightRefresh;

  Future<AppleTokenPayload> verifyIdentityToken(
    String identityToken, {
    required String rawNonce,
  }) async {
    final JsonWebSignature jws;
    final String keyId;
    try {
      jws = JsonWebSignature.fromCompactSerialization(identityToken);
      final header = jws.commonProtectedHeader;
      // Liste blanche (et non « pas de none ») : écarte aussi HS256, utilisé
      // dans les attaques par confusion d'algorithme.
      if (header.algorithm != 'RS256') throw const FormatException('alg');
      final kid = header.keyId;
      if (kid == null || kid.isEmpty) throw const FormatException('kid');
      keyId = kid;
    } catch (_) {
      throw _invalid('Malformed Apple identity token.');
    }

    final keyStore = await _keyStoreFor(keyId);

    final JosePayload payload;
    try {
      payload = await jws.getPayload(
        keyStore,
        allowedAlgorithms: const ['RS256'],
      );
    } catch (_) {
      throw _invalid('Invalid Apple identity token signature.');
    }

    final Object? decoded;
    try {
      decoded = payload.jsonContent;
    } catch (_) {
      throw _invalid('Invalid Apple token payload.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw _invalid('Invalid Apple token payload.');
    }

    if (decoded['iss']?.toString() != issuer) {
      throw _invalid('Apple token issuer mismatch.');
    }
    if (!_audienceMatches(decoded['aud'])) {
      throw _invalid('Apple token audience mismatch.');
    }

    final exp = decoded['exp'];
    final expiresAt = exp is num
        ? DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000, isUtc: true)
        : null;
    if (expiresAt == null || !expiresAt.isAfter(_now())) {
      throw _invalid('Apple token expired.');
    }

    // Le client a donné à Apple le SHA-256 du nonce brut ; Apple le recopie
    // tel quel dans le token. Exiger la correspondance lie ce token à la
    // tentative de connexion en cours (anti-rejeu d'un token intercepté).
    final nonceClaim = decoded['nonce']?.toString();
    final expectedNonce = sha256.convert(utf8.encode(rawNonce)).toString();
    if (nonceClaim == null || !constantTimeEquals(nonceClaim, expectedNonce)) {
      throw _invalid('Apple token nonce mismatch.');
    }

    final subject = decoded['sub']?.toString() ?? '';
    if (subject.isEmpty) {
      throw _invalid('Apple token missing required claims.');
    }

    final rawEmail = decoded['email']?.toString().trim().toLowerCase() ?? '';
    final email = rawEmail.isEmpty ? null : rawEmail;
    final emailVerified = _parseBool(decoded['email_verified']);
    // Apple ne renvoie que des adresses vérifiées : un `false` n'est pas un
    // cas légitime, et cet email servirait à rattacher un compte existant.
    if (email != null && !emailVerified) {
      throw _invalid('Apple email is not verified.');
    }

    return AppleTokenPayload(
      subject: subject,
      email: email,
      emailVerified: emailVerified,
      isPrivateEmail: _parseBool(decoded['is_private_email']),
      expiresAt: expiresAt,
    );
  }

  void close() {
    _client.close();
  }

  ApiException _invalid(String message) => ApiException(message, statusCode: 401);

  bool _audienceMatches(Object? aud) {
    if (aud is String) return aud == bundleId;
    if (aud is List) return aud.length == 1 && aud.first == bundleId;
    return false;
  }

  Future<JsonWebKeyStore> _keyStoreFor(String keyId) async {
    final now = _now();
    final stale =
        _keysFetchedAt == null || now.difference(_keysFetchedAt!) > _keysTtl;

    // Le délai minimal vaut aussi après un échec : sans lui, une panne
    // d'Apple ferait un appel réseau par tentative de connexion.
    if (_inflightRefresh == null &&
        (stale || !_knownKeyIds.contains(keyId)) &&
        _canRefetch(now)) {
      _inflightRefresh = _fetchKeys().whenComplete(() {
        _inflightRefresh = null;
      });
    }
    // Les appels simultanés partagent le même téléchargement, même si le délai
    // minimal les empêcherait d'en lancer un eux-mêmes.
    await _inflightRefresh;

    final store = _keyStore;
    if (store == null) {
      throw ApiException(
        'Apple signing keys are temporarily unavailable.',
        statusCode: 503,
      );
    }
    return store;
  }

  bool _canRefetch(DateTime now) =>
      _lastFetchAttemptAt == null ||
      now.difference(_lastFetchAttemptAt!) >= _refetchCooldown;

  Future<void> _fetchKeys() async {
    _lastFetchAttemptAt = _now();
    try {
      final response =
          await _client.get(_keysUri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw StateError('HTTP ${response.statusCode}');
      }
      final keySet = JsonWebKeySet.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
      _keyStore = JsonWebKeyStore()..addKeySet(keySet);
      _knownKeyIds = {
        for (final key in keySet.keys)
          if (key.keyId != null) key.keyId!,
      };
      _keysFetchedAt = _now();
    } catch (e) {
      // On garde l'ancien jeu de clés s'il y en a un : une panne passagère
      // côté Apple ne doit pas bloquer des tokens signés avec une clé déjà
      // connue.
      logWarn('Could not refresh Apple signing keys', error: e);
    }
  }

  bool _parseBool(Object? value) {
    if (value is bool) return value;
    final text = value?.toString().toLowerCase();
    return text == 'true' || text == '1';
  }
}
