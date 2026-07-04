import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/logger.dart';

/// Envoi d'emails transactionnels via l'API Resend (https://resend.com).
///
/// Si [apiKey] est vide (non configuré), [sendPasswordResetCode] devient un
/// no-op silencieux côté appelant : on logue l'absence de config plutôt que
/// de faire planter le flux de reset (le code reste valide en base, il ne
/// sera juste jamais livré tant que RESEND_API_KEY n'est pas renseignée).
class EmailService {
  EmailService({
    required String apiKey,
    required String fromEmail,
    http.Client? client,
  })  : _apiKey = apiKey,
        _fromEmail = fromEmail,
        _client = client ?? http.Client();

  static const _endpoint = 'https://api.resend.com/emails';

  final String _apiKey;
  final String _fromEmail;
  final http.Client _client;

  bool get isConfigured => _apiKey.isNotEmpty;

  Future<void> sendPasswordResetCode({
    required String toEmail,
    required String code,
  }) async {
    if (!isConfigured) {
      logInfo('EmailService not configured (RESEND_API_KEY missing) — '
          'skipping password reset email to $toEmail');
      return;
    }

    final response = await _client.post(
      Uri.parse(_endpoint),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'from': _fromEmail,
        'to': [toEmail],
        'subject': 'GymArena — Réinitialisation de votre mot de passe',
        'html': _buildHtml(code),
      }),
    );

    if (response.statusCode >= 400) {
      logError(
        'Resend API error while sending password reset email',
        'HTTP ${response.statusCode}: ${response.body}',
        null,
      );
    }
  }

  String _buildHtml(String code) => '''
<div style="font-family:-apple-system,Roboto,Arial,sans-serif;max-width:480px;margin:0 auto;padding:24px;">
  <h2 style="color:#111827;">Réinitialisation de mot de passe</h2>
  <p style="color:#374151;font-size:15px;line-height:1.5;">
    Voici votre code de réinitialisation. Il est valable 15 minutes et ne peut être utilisé qu'une seule fois.
  </p>
  <div style="display:inline-block;margin:16px 0;padding:14px 22px;font-size:28px;letter-spacing:6px;
              font-weight:700;background:#F3F4F6;border-radius:12px;color:#111827;">
    $code
  </div>
  <p style="color:#6B7280;font-size:13px;">
    Si vous n'êtes pas à l'origine de cette demande, ignorez simplement cet email.
  </p>
</div>
''';
}
