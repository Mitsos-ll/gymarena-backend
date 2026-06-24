import 'dart:convert';

import 'package:shelf/shelf.dart';

import 'api_exception.dart';

const _jsonHeaders = {
  'content-type': 'application/json; charset=utf-8',
};

Response jsonResponse(Object body, {int statusCode = 200}) {
  return Response(
    statusCode,
    headers: _jsonHeaders,
    body: jsonEncode(body),
  );
}

Response errorResponse(String message, {int statusCode = 400}) {
  return jsonResponse({'message': message}, statusCode: statusCode);
}

Future<Map<String, dynamic>> readJsonBody(Request request) async {
  final raw = await request.readAsString();
  if (raw.trim().isEmpty) return <String, dynamic>{};

  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw ApiException('JSON body must be an object.', statusCode: 400);
  }
  return decoded;
}

String? bearerToken(Request request) {
  final authHeader = request.headers['authorization'];
  if (authHeader == null || authHeader.isEmpty) return null;
  if (!authHeader.startsWith('Bearer ')) return null;
  return authHeader.substring(7).trim();
}
