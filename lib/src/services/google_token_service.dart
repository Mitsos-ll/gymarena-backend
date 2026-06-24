import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api_exception.dart';

class GoogleTokenPayload {
  GoogleTokenPayload({
    required this.subject,
    required this.email,
    required this.displayName,
    required this.photoUrl,
    required this.emailVerified,
    required this.expiresAt,
  });

  final String subject;
  final String email;
  final String displayName;
  final String? photoUrl;
  final bool emailVerified;
  final DateTime expiresAt;
}

class GoogleTokenService {
  GoogleTokenService({
    required this.webClientId,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String webClientId;
  final http.Client _client;

  Future<GoogleTokenPayload> verifyIdToken(String idToken) async {
    final uri = Uri.https(
      'oauth2.googleapis.com',
      '/tokeninfo',
      {'id_token': idToken},
    );

    final response = await _client.get(uri).timeout(
          const Duration(seconds: 10),
        );

    if (response.statusCode != 200) {
      throw ApiException(
        'Invalid Google ID token.',
        statusCode: 401,
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw ApiException('Invalid Google token response.', statusCode: 401);
    }

    final aud = decoded['aud']?.toString() ?? '';
    final iss = decoded['iss']?.toString() ?? '';
    final exp = int.tryParse(decoded['exp']?.toString() ?? '') ?? 0;
    final emailVerified = _parseBool(decoded['email_verified']);

    if (aud != webClientId) {
      throw ApiException('Google token audience mismatch.', statusCode: 401);
    }

    if (iss != 'accounts.google.com' && iss != 'https://accounts.google.com') {
      throw ApiException('Google token issuer mismatch.', statusCode: 401);
    }

    final expiresAt = DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
    if (expiresAt.isBefore(DateTime.now().toUtc())) {
      throw ApiException('Google token expired.', statusCode: 401);
    }

    if (!emailVerified) {
      throw ApiException('Google email is not verified.', statusCode: 401);
    }

    final subject = decoded['sub']?.toString() ?? '';
    final email = decoded['email']?.toString() ?? '';
    final name = decoded['name']?.toString().trim() ?? '';
    final picture = decoded['picture']?.toString();

    if (subject.isEmpty || email.isEmpty) {
      throw ApiException('Google token missing required claims.', statusCode: 401);
    }

    return GoogleTokenPayload(
      subject: subject,
      email: email,
      displayName: name.isNotEmpty ? name : email.split('@').first,
      photoUrl: picture?.isEmpty == true ? null : picture,
      emailVerified: emailVerified,
      expiresAt: expiresAt,
    );
  }

  void close() {
    _client.close();
  }

  bool _parseBool(dynamic value) {
    if (value is bool) return value;
    final text = value?.toString().toLowerCase();
    return text == 'true' || text == '1';
  }
}
