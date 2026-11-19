import 'package:shelf/shelf.dart';

import '../db/app_database.dart';
import '../repositories/user_repository.dart';
import '../services/push_service.dart';
import '../utils/api_exception.dart';
import '../utils/auth_helper.dart';
import '../utils/http_json.dart';

/// Téléphones du compte connecté qui reçoivent les notifications push.
class PushRoutes {
  PushRoutes({required UserRepository userRepository, required AppDatabase database})
      : _repo = userRepository,
        _db = database;

  final UserRepository _repo;
  final AppDatabase _db;

  static const _platforms = {'android', 'ios'};

  /// Enregistre (ou rafraîchit) le téléphone. Un téléphone qui change de
  /// compte passe au nouveau : l'ancien ne doit plus rien y recevoir.
  Future<Response> registerToken(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final body = await readJsonBody(request);
      final token = body['token']?.toString().trim() ?? '';
      final platform = body['platform']?.toString() ?? '';
      if (token.isEmpty || token.length > 4096) throw ApiException('token is required.', statusCode: 400);
      if (!_platforms.contains(platform)) throw ApiException('platform must be android or ios.', statusCode: 400);
      final locale = body['locale']?.toString() ?? '';

      final now = dbNow();
      _db.raw.execute(
        'INSERT INTO push_tokens (token, user_id, platform, locale, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(token) DO UPDATE SET user_id=excluded.user_id, platform=excluded.platform, '
        'locale=excluded.locale, updated_at=excluded.updated_at',
        [token, session.user.id, platform, pushLocales.contains(locale) ? locale : 'fr', now, now],
      );
      return Response(204);
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  /// Déconnexion ou notifications coupées dans l'app.
  Future<Response> unregisterToken(Request request) async {
    try {
      final session = requireAuth(request, _repo);
      final body = await readJsonBody(request);
      _db.raw.execute(
        'DELETE FROM push_tokens WHERE token=? AND user_id=?',
        [body['token']?.toString() ?? '', session.user.id],
      );
      return Response(204);
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }
}
