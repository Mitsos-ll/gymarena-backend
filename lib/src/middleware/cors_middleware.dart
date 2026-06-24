import 'package:shelf/shelf.dart';

/// Middleware CORS configurable par liste d'origines.
/// Passe `['*']` en dev, liste explicite en prod.
Middleware corsMiddleware(List<String> allowedOrigins) {
  const exposedHeaders = 'Content-Type, Authorization';
  const allowHeaders = 'Origin, Content-Type, Authorization, Accept, X-Request-Id';
  const allowMethods = 'GET, POST, PUT, PATCH, DELETE, OPTIONS';
  const maxAge = '600';

  String resolveOrigin(String? requestOrigin) {
    if (allowedOrigins.contains('*')) return '*';
    if (requestOrigin != null && allowedOrigins.contains(requestOrigin)) {
      return requestOrigin;
    }
    return allowedOrigins.isNotEmpty ? allowedOrigins.first : '*';
  }

  return (Handler inner) {
    return (Request request) async {
      final origin = request.headers['origin'];
      final corsOrigin = resolveOrigin(origin);

      final corsHeaders = {
        'Access-Control-Allow-Origin': corsOrigin,
        'Access-Control-Allow-Methods': allowMethods,
        'Access-Control-Allow-Headers': allowHeaders,
        'Access-Control-Expose-Headers': exposedHeaders,
        'Access-Control-Max-Age': maxAge,
        if (corsOrigin != '*') 'Vary': 'Origin',
      };

      // Pre-flight OPTIONS
      if (request.method == 'OPTIONS') {
        return Response.ok(null, headers: corsHeaders);
      }

      final response = await inner(request);
      return response.change(headers: corsHeaders);
    };
  };
}
