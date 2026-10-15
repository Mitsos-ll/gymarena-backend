import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:jose/jose.dart';

import '../utils/logger.dart';

/// Résultat de l'échange d'un `authorizationCode` Sign in with Apple.
class AppleTokenExchange {
  AppleTokenExchange({required this.refreshToken, required this.subject});

  final String refreshToken;

  /// `sub` de l'`id_token` renvoyé par Apple : permet de vérifier que le code
  /// appartient bien au compte Apple qui est en train de se connecter.
  final String? subject;
}

/// Accepte la clé `.p8` telle quelle (PEM, éventuellement avec des `\n`
/// littéraux) ou encodée en base64 — pratique pour un secret Fly sur une seule
/// ligne. Retourne une chaîne vide si la valeur est vide ou illisible.
String normalizeApplePrivateKey(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return '';
  if (value.contains('BEGIN')) return value.replaceAll(r'\n', '\n');
  try {
    return utf8.decode(base64.decode(value)).trim();
  } on FormatException {
    return '';
  }
}

/// Appels REST « Sign in with Apple » faits au nom du serveur : échange du
/// code d'autorisation (pour obtenir un refresh token) et révocation de ce
/// token quand un compte est supprimé — exigée par Apple (TN3194).
///
/// Tout est en « meilleur effort » : sans configuration, ou si Apple répond en
/// erreur, ces méthodes retournent `null` / `false` sans jamais lever, pour ne
/// jamais bloquer une connexion ni une suppression de compte.
class AppleRestService {
  AppleRestService({
    required this.clientId,
    this.teamId = '',
    this.keyId = '',
    String privateKey = '',
    http.Client? client,
    DateTime Function()? now,
  })  : _privateKeyPem = normalizeApplePrivateKey(privateKey),
        _client = client ?? http.Client(),
        _now = now ?? (() => DateTime.now().toUtc());

  static final _tokenUri = Uri.https('appleid.apple.com', '/auth/token');
  static final _revokeUri = Uri.https('appleid.apple.com', '/auth/revoke');
  static const _audience = 'https://appleid.apple.com';
  static const _clientSecretTtl = Duration(minutes: 5);
  static const _timeout = Duration(seconds: 10);

  /// Bundle ID de l'app iOS (flux natif : il tient lieu de `client_id`).
  final String clientId;
  final String teamId;
  final String keyId;
  final String _privateKeyPem;
  final http.Client _client;
  final DateTime Function() _now;

  bool get isConfigured =>
      teamId.isNotEmpty && keyId.isNotEmpty && _privateKeyPem.isNotEmpty;

  /// JWT signé en ES256 avec la clé `.p8`, que l'API d'Apple exige à la place
  /// d'un secret client statique. Validité courte : on en refait un par appel.
  String buildClientSecret() {
    final issuedAt = _now().millisecondsSinceEpoch ~/ 1000;
    final key = JsonWebKey.fromPem(_privateKeyPem, keyId: keyId);
    final builder = JsonWebSignatureBuilder()
      ..jsonContent = {
        'iss': teamId,
        'iat': issuedAt,
        'exp': issuedAt + _clientSecretTtl.inSeconds,
        'aud': _audience,
        'sub': clientId,
      }
      ..addRecipient(key, algorithm: 'ES256');
    return builder.build().toCompactSerialization();
  }

  Future<AppleTokenExchange?> exchangeAuthorizationCode(String code) async {
    if (!isConfigured) return null;
    try {
      final response = await _client.post(_tokenUri, body: {
        'client_id': clientId,
        'client_secret': buildClientSecret(),
        'code': code,
        'grant_type': 'authorization_code',
      }).timeout(_timeout);
      if (response.statusCode != 200) {
        logWarn('Apple token exchange refused (HTTP ${response.statusCode})');
        return null;
      }
      final json = jsonDecode(response.body);
      if (json is! Map<String, dynamic>) return null;
      final refreshToken = json['refresh_token']?.toString() ?? '';
      if (refreshToken.isEmpty) return null;
      return AppleTokenExchange(
        refreshToken: refreshToken,
        subject: _subjectOf(json['id_token']?.toString()),
      );
    } catch (e) {
      logWarn('Apple token exchange failed', error: e);
      return null;
    }
  }

  Future<bool> revokeRefreshToken(String refreshToken) async {
    if (!isConfigured) return false;
    try {
      final response = await _client.post(_revokeUri, body: {
        'client_id': clientId,
        'client_secret': buildClientSecret(),
        'token': refreshToken,
        'token_type_hint': 'refresh_token',
      }).timeout(_timeout);
      if (response.statusCode != 200) {
        logWarn('Apple token revocation refused (HTTP ${response.statusCode})');
        return false;
      }
      return true;
    } catch (e) {
      logWarn('Apple token revocation failed', error: e);
      return false;
    }
  }

  void close() {
    _client.close();
  }

  /// Lit le `sub` du payload d'un JWT reçu directement d'Apple en TLS (pas de
  /// vérification de signature nécessaire : on ne s'en sert que pour
  /// recouper l'identité).
  String? _subjectOf(String? jwt) {
    if (jwt == null) return null;
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final decoded = jsonDecode(payload);
      return decoded is Map<String, dynamic> ? decoded['sub']?.toString() : null;
    } catch (_) {
      return null;
    }
  }
}
