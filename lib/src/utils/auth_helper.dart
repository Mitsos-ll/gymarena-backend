import 'package:shelf/shelf.dart';

import '../models/api_session.dart';
import '../repositories/user_repository.dart';
import '../utils/api_exception.dart';
import '../utils/http_json.dart';

/// Extrait et valide le Bearer token, retourne la session complète.
/// Lance [ApiException] 401 si absent ou invalide.
ApiSession requireAuth(Request request, UserRepository repo) {
  final token = bearerToken(request);
  if (token == null || token.isEmpty) {
    throw ApiException('Unauthorized.', statusCode: 401);
  }
  return repo.getSessionByAccessToken(token);
}

/// Vérifie que l'utilisateur est coach, sinon 403.
void requireCoach(ApiSession session) {
  if (session.profile?.isCoach != true) {
    throw ApiException('Forbidden. Coach access required.', statusCode: 403);
  }
}
