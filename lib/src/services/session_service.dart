import 'dart:convert';
import 'dart:math';

import '../utils/token_hash.dart' as token_hash;

class SessionTokens {
  SessionTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.accessTokenHash,
    required this.refreshTokenHash,
    required this.accessExpiresAt,
    required this.refreshExpiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final String accessTokenHash;
  final String refreshTokenHash;
  final DateTime accessExpiresAt;
  final DateTime refreshExpiresAt;
}

class SessionService {
  SessionService({
    required this.accessTokenTtlDays,
    required this.refreshTokenTtlDays,
  });

  final int accessTokenTtlDays;
  final int refreshTokenTtlDays;
  final Random _random = Random.secure();

  SessionTokens issueTokens() {
    final accessToken = _randomToken();
    final refreshToken = _randomToken();
    final now = DateTime.now().toUtc();

    return SessionTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
      accessTokenHash: hashToken(accessToken),
      refreshTokenHash: hashToken(refreshToken),
      accessExpiresAt: now.add(Duration(days: accessTokenTtlDays)),
      refreshExpiresAt: now.add(Duration(days: refreshTokenTtlDays)),
    );
  }

  String hashToken(String token) => token_hash.hashToken(token);

  String _randomToken() {
    final bytes = List<int>.generate(48, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
