import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

const _reqIdHeader = 'x-request-id';
const requestIdKey = 'gymtrack.requestId';

final _uuid = Uuid();

/// Attache un UUID à chaque requête et le renvoie dans le header de réponse.
/// Accessible dans les handlers via `request.context[requestIdKey]`.
Middleware requestIdMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      final id = request.headers[_reqIdHeader] ?? _uuid.v4();
      final updated = request.change(context: {requestIdKey: id});
      final response = await inner(updated);
      return response.change(headers: {_reqIdHeader: id});
    };
  };
}

/// Récupère le request-ID depuis le contexte Shelf.
String? requestId(Request request) =>
    request.context[requestIdKey] as String?;
