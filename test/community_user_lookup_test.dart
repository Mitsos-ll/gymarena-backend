import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/src/app.dart';
import 'test_config.dart';

void main() {
  late GymTrackBackend backend;

  setUp(() {
    backend = GymTrackBackend(testConfig());
  });

  tearDown(() => backend.close());

  Future<Response> post(String path, Map<String, dynamic> body) async {
    return backend.handler(Request(
      'POST',
      Uri.parse('http://localhost$path'),
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json'},
    ));
  }

  Future<Response> get(String path, {String? bearerToken}) async {
    return backend.handler(Request(
      'GET',
      Uri.parse('http://localhost$path'),
      headers: bearerToken == null ? {} : {'Authorization': 'Bearer $bearerToken'},
    ));
  }

  Future<String> registerAndGetToken(String email, {String? displayName}) async {
    final res = await post('/auth/register', {
      'email': email,
      'password': 'password123',
      if (displayName != null) 'displayName': displayName,
    });
    final body = jsonDecode(await res.readAsString()) as Map;
    return body['accessToken'] as String;
  }

  group('GET /community/users/lookup', () {
    test('trouve un utilisateur par pseudo exact', () async {
      await registerAndGetToken('lookup-a@example.com', displayName: 'leo');
      final callerToken = await registerAndGetToken('lookup-b@example.com', displayName: 'other');

      final res = await get('/community/users/lookup?displayName=leo', bearerToken: callerToken);
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString()) as Map;
      expect(body['displayName'], 'leo');
      expect(body['id'], isNotEmpty);
    });

    test('la résolution est insensible à la casse (y compris sur des noms accentués)', () async {
      await registerAndGetToken('lookup-c@example.com', displayName: 'École');
      final callerToken = await registerAndGetToken('lookup-d@example.com', displayName: 'caller1');
      final res =
          await get('/community/users/lookup?displayName=école', bearerToken: callerToken);
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString()) as Map;
      expect(body['displayName'], 'École');
    });

    test('renvoie 404 si le pseudo est inconnu', () async {
      final callerToken = await registerAndGetToken('lookup-e@example.com', displayName: 'caller2');
      final res = await get('/community/users/lookup?displayName=inconnu999',
          bearerToken: callerToken);
      expect(res.statusCode, 404);
    });

    test('renvoie 400 si displayName est vide', () async {
      final callerToken = await registerAndGetToken('lookup-f@example.com', displayName: 'caller3');
      final res = await get('/community/users/lookup?displayName=', bearerToken: callerToken);
      expect(res.statusCode, 400);
    });

    test('exige une authentification (401 sans token)', () async {
      final res = await get('/community/users/lookup?displayName=leo');
      expect(res.statusCode, 401);
    });
  });
}
