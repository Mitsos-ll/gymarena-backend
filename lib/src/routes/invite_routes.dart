import 'dart:math';

import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../repositories/user_repository.dart';
import '../utils/api_exception.dart';
import '../utils/auth_helper.dart';
import '../utils/http_json.dart';

/// Invitations d'amis partageables par lien ou QR code.
/// Contrairement au code coach (usage unique par athlète), un code d'ami est
/// réutilisable par plusieurs destinataires jusqu'à expiration : la personne
/// qui invite le partage une seule fois à tout son entourage.
class InviteRoutes {
  InviteRoutes({required UserRepository userRepository, required AppDatabase database})
      : _repo = userRepository,
        _db = database;

  final UserRepository _repo;
  final AppDatabase _db;
  final _uuid = const Uuid();
  final _random = Random.secure();

  static const _codeChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  static const _codeLength = 8;
  static const _validityDays = 30;

  String _generateCode() =>
      List.generate(_codeLength, (_) => _codeChars[_random.nextInt(_codeChars.length)]).join();

  // ── POST /invites — génère (ou réutilise) le code de l'utilisateur ────────

  Future<Response> generateInviteCode(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final userId = session.user.id;
      final now = dbNow();

      final existing = _db.raw.select(
        'SELECT code, expires_at FROM friend_invite_codes WHERE user_id=? AND expires_at > ? '
        'ORDER BY created_at DESC LIMIT 1',
        [userId, now],
      );
      if (existing.isNotEmpty) {
        return jsonResponse({
          'code': existing.first['code'],
          'expiresAt': existing.first['expires_at'],
        });
      }

      final code = _generateCode();
      final expiresAt =
          DateTime.now().add(const Duration(days: _validityDays)).toUtc().toIso8601String();

      _db.raw.execute(
        'INSERT INTO friend_invite_codes (code, user_id, expires_at, created_at) VALUES (?, ?, ?, ?)',
        [code, userId, expiresAt, now],
      );

      return jsonResponse({'code': code, 'expiresAt': expiresAt});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── GET /invites/<code> — infos publiques de l'inviteur (app, authentifié) ─

  Future<Response> getInviteInfo(Request request, String code) async {
    try {
      requireAuth(request, _repo);
      final info = _resolveCode(code);
      if (info == null) throw ApiException('Code invalide ou expiré.', statusCode: 404);

      return jsonResponse({
        'code': code,
        'inviterUserId': info.userId,
        'inviterDisplayName': info.displayName,
        'expiresAt': info.expiresAt,
      });
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── POST /invites/<code>/redeem — crée la relation d'amitié ───────────────

  Future<Response> redeemInviteCode(Request request, String code) async {
    try {
      final session = requireAuth(request, _repo);
      final redeemerUserId = session.user.id;

      final info = _resolveCode(code);
      if (info == null) throw ApiException('Code invalide ou expiré.', statusCode: 404);
      final inviterUserId = info.userId;

      if (inviterUserId == redeemerUserId) {
        throw ApiException('Vous ne pouvez pas utiliser votre propre code.', statusCode: 400);
      }

      final now = dbNow();
      final existing = _db.raw.select(
        'SELECT id, request_status FROM social_relations '
        'WHERE (user_id_a=? AND user_id_b=?) OR (user_id_a=? AND user_id_b=?)',
        [inviterUserId, redeemerUserId, redeemerUserId, inviterUserId],
      );

      if (existing.isNotEmpty && existing.first['request_status'] == 'accepted') {
        return jsonResponse({
          'id': existing.first['id'],
          'inviterUserId': inviterUserId,
          'status': 'friend',
          'requestStatus': 'accepted',
          'alreadyFriends': true,
        });
      }

      final id = existing.isNotEmpty ? existing.first['id'] as String : _uuid.v4();

      _db.raw.execute(
        'INSERT OR REPLACE INTO social_relations (id, user_id_a, user_id_b, status, request_status, notes, is_public, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM social_relations WHERE id=?), ?), ?)',
        [id, inviterUserId, redeemerUserId, 'friend', 'accepted', null, 0, id, now, now],
      );

      return jsonResponse({
        'id': id,
        'inviterUserId': inviterUserId,
        'status': 'friend',
        'requestStatus': 'accepted',
        'alreadyFriends': false,
      });
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  // ── GET /invite/<code> — page web publique (fallback sans l'app) ──────────

  Future<Response> landingPage(Request request, String code) async {
    final info = _resolveCode(code);
    final name = info == null ? null : _escapeHtml(info.displayName);

    final headline = name != null
        ? '$name t’invite sur GymTrack !'
        : 'Ce lien d’invitation GymTrack est invalide ou a expiré.';
    final subtitle = name != null
        ? 'Installe l’application, puis entre le code ci-dessous pour vous ajouter en amis.'
        : 'Demande à la personne qui t’a envoyé ce lien de t’en partager un nouveau.';

    final html = '''
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>GymTrack — Invitation</title>
<style>
  body { font-family: -apple-system, Roboto, Arial, sans-serif; background:#0F1720; color:#fff;
         margin:0; padding:32px 20px; text-align:center; }
  h1 { font-size:22px; margin-bottom:8px; }
  p { color:#B7C0CC; font-size:15px; line-height:1.5; }
  .code { display:inline-block; margin:24px 0; padding:14px 22px; font-size:24px; letter-spacing:4px;
          font-weight:700; background:#1C2733; border-radius:12px; }
  .badges { margin-top:24px; display:flex; gap:12px; justify-content:center; flex-wrap:wrap; }
  .badges a { color:#fff; background:#2563EB; padding:12px 20px; border-radius:10px;
              text-decoration:none; font-weight:600; font-size:14px; }
</style>
</head>
<body>
  <h1>$headline</h1>
  <p>$subtitle</p>
  ${info != null ? '<div class="code">${_escapeHtml(code)}</div>' : ''}
  <div class="badges">
    <a href="https://play.google.com/store/apps/details?id=com.gymtrack.app">Android</a>
    <a href="https://apps.apple.com/app/id0000000000">iOS</a>
  </div>
</body>
</html>
''';

    return Response.ok(html, headers: {'content-type': 'text/html; charset=utf-8'});
  }

  _InviteInfo? _resolveCode(String rawCode) {
    final code = rawCode.trim().toUpperCase();
    if (code.isEmpty) return null;

    final rows = _db.raw.select(
      'SELECT user_id, expires_at FROM friend_invite_codes WHERE code=? AND expires_at > ?',
      [code, dbNow()],
    );
    if (rows.isEmpty) return null;

    final userId = rows.first['user_id'] as String;
    final profileRows = _db.raw.select(
      'SELECT display_name FROM user_profiles WHERE user_id=? LIMIT 1',
      [userId],
    );
    final displayName =
        profileRows.isEmpty ? 'Un ami' : (profileRows.first['display_name'] as String? ?? 'Un ami');

    return _InviteInfo(
      userId: userId,
      displayName: displayName,
      expiresAt: rows.first['expires_at'] as String,
    );
  }

  String _escapeHtml(String input) => input
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}

class _InviteInfo {
  _InviteInfo({required this.userId, required this.displayName, required this.expiresAt});

  final String userId;
  final String displayName;
  final String expiresAt;
}
