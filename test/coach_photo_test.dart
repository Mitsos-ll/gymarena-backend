import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/src/app.dart';
import '../lib/src/config.dart';
import 'test_config.dart';

/// Photo du profil public d'un coach : nouvelle adresse à chaque envoi (pas
/// d'ancienne image gardée en cache par l'app), suppression.
void main() {
  late Directory dataDir;
  late GymTrackBackend backend;

  setUp(() {
    // Les photos vont à côté de la base : un dossier temporaire plutôt que le
    // dépôt.
    dataDir = Directory.systemTemp.createTempSync('coach_photo_test');
    final base = testConfig();
    backend = GymTrackBackend(AppConfig(
      port: base.port,
      env: base.env,
      databasePath: p.join(dataDir.path, 'gymtrack.db'),
      googleWebClientId: base.googleWebClientId,
      appleBundleId: base.appleBundleId,
      accessTokenTtlDays: base.accessTokenTtlDays,
      refreshTokenTtlDays: base.refreshTokenTtlDays,
      corsAllowedOrigins: base.corsAllowedOrigins,
      rateLimitMaxRequests: base.rateLimitMaxRequests,
      rateLimitWindowSeconds: base.rateLimitWindowSeconds,
      authRateLimitMaxRequests: base.authRateLimitMaxRequests,
      authRateLimitWindowSeconds: base.authRateLimitWindowSeconds,
      adminSecret: base.adminSecret,
      resendApiKey: base.resendApiKey,
      resendFromEmail: base.resendFromEmail,
      workoutXApiKey: base.workoutXApiKey,
      workoutXBaseUrl: base.workoutXBaseUrl,
    ));
  });

  tearDown(() async {
    await backend.close();
    dataDir.deleteSync(recursive: true);
  });

  Future<Response> send(String method, String path, {String? token, Object? body}) async {
    return backend.handler(Request(
      method,
      Uri.parse('http://localhost$path'),
      body: body == null ? null : jsonEncode(body),
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
    ));
  }

  Future<Map<String, dynamic>> json(Response res) async {
    final text = await res.readAsString();
    expect(res.statusCode, 200, reason: text);
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<String> coachToken() async {
    final body = await json(await send('POST', '/auth/register', body: {
      'email': 'coach@example.com',
      'password': 'password123',
      'displayName': 'Coach',
    }));
    final id = (body['user'] as Map)['id'] as String;
    await json(await send('PUT', '/admin/users/$id/set-coach',
        token: 'test-admin-secret', body: {'isCoach': true}));
    return body['accessToken'] as String;
  }

  Future<String> upload(String token, List<int> bytes) async {
    final profile = await json(await send('PUT', '/coach/public-profile/photo',
        token: token, body: {'imageBase64': base64Encode(bytes)}));
    return profile['photoUrl'] as String;
  }

  test('nouvelle adresse à chaque envoi, même fichier servi', () async {
    final token = await coachToken();
    final first = await upload(token, [1, 2, 3]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final second = await upload(token, [4, 5, 6]);

    expect(first, startsWith('/coach-photos/'));
    expect(first, contains('?v='));
    expect(second, isNot(first));

    final served = await send('GET', second);
    expect(served.statusCode, 200);
    expect(await served.read().expand((chunk) => chunk).toList(), [4, 5, 6]);
  });

  test('suppression : photo retirée du profil et fichier effacé', () async {
    final token = await coachToken();
    final url = await upload(token, [1, 2, 3]);

    final deleted = await json(await send('DELETE', '/coach/public-profile/photo', token: token));
    expect((deleted['profile'] as Map)['photoUrl'], isNull);
    expect((await send('GET', url)).statusCode, 404);

    final profile = await json(await send('GET', '/coach/public-profile', token: token));
    expect((profile['profile'] as Map)['photoUrl'], isNull);
  });

  test('réservé aux coachs', () async {
    final body = await json(await send('POST', '/auth/register', body: {
      'email': 'athlete@example.com',
      'password': 'password123',
      'displayName': 'Athlete',
    }));
    final res = await send('DELETE', '/coach/public-profile/photo', token: body['accessToken'] as String);
    expect(res.statusCode, 403);
  });
}
