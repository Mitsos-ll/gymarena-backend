import 'package:shelf/shelf.dart';

import '../repositories/moderation_repository.dart';
import '../repositories/user_repository.dart';
import '../utils/api_exception.dart';
import '../utils/auth_helper.dart';
import '../utils/http_json.dart';

class ModerationRoutes {
  ModerationRoutes({
    required UserRepository userRepository,
    required ModerationRepository moderation,
  })  : _users = userRepository,
        _moderation = moderation;

  final UserRepository _users;
  final ModerationRepository _moderation;

  static const _maxDetailsLength = 500;

  Future<Response> block(Request request) async {
    try {
      final session = requireAuth(request, _users);
      final body = await readJsonBody(request);
      final userId = _requireUserId(body['userId']);

      _moderation.block(session.user.id, userId);
      return jsonResponse({'ok': true});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Future<Response> unblock(Request request, String userId) async {
    try {
      final session = requireAuth(request, _users);
      _moderation.unblock(session.user.id, userId);
      return jsonResponse({'ok': true});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Future<Response> listBlocked(Request request) async {
    try {
      final session = requireAuth(request, _users);
      final blocked = _moderation.listBlockedBy(session.user.id);
      return jsonResponse({'blocked': blocked.map((b) => b.toJson()).toList()});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Future<Response> report(Request request) async {
    try {
      final session = requireAuth(request, _users);
      final body = await readJsonBody(request);
      final userId = _requireUserId(body['userId']);
      final reason = body['reason']?.toString() ?? '';

      var details = body['details']?.toString().trim();
      if (details != null && details.isEmpty) details = null;
      if (details != null && details.length > _maxDetailsLength) {
        throw ApiException(
          'details must be $_maxDetailsLength characters or fewer.',
          statusCode: 400,
        );
      }

      final id = _moderation.report(
        reporterId: session.user.id,
        reportedId: userId,
        reason: reason,
        details: details,
      );
      return jsonResponse({'ok': true, 'id': id});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  String _requireUserId(Object? raw) {
    final userId = raw?.toString().trim() ?? '';
    if (userId.isEmpty) throw ApiException('userId is required.', statusCode: 400);
    return userId;
  }
}
