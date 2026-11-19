import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:test/test.dart';

import '../lib/src/app.dart';
import '../lib/src/config.dart';
import '../lib/src/db/app_database.dart';
import '../lib/src/services/email_service.dart';
import 'test_config.dart';

/// Accès au coaching : candidature validée par l'administrateur (prévenu par
/// mail), annuaire limité aux coachs validés, demandes d'invitation qui
/// expirent ou s'annulent, limites de fréquence.
void main() {
  late GymTrackBackend backend;
  late List<http.Request> mails;

  AppConfig config() {
    final base = testConfig();
    return AppConfig(
      port: base.port,
      env: base.env,
      databasePath: base.databasePath,
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
      adminNotifyEmail: 'admin@example.com',
    );
  }

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

  Future<Response> admin(String method, String path) => send(method, path, token: 'test-admin-secret');

  Future<({String token, String id})> register(String name) async {
    final body = await json(await send('POST', '/auth/register', body: {
      'email': '${name.toLowerCase()}@example.com',
      'password': 'password123',
      'displayName': name,
    }));
    return (token: body['accessToken'] as String, id: (body['user'] as Map)['id'] as String);
  }

  Map<String, dynamic> profile({List<String> specialities = const ['strength', 'running']}) => {
        'bio': 'Coach de force',
        'specialities': specialities,
        'location': 'Lyon',
        'languages': ['Français', 'English'],
        'isPublic': true,
      };

  setUp(() async {
    mails = [];
    backend = GymTrackBackend(
      config(),
      emailService: EmailService(
        apiKey: 're_test',
        fromEmail: 'onboarding@resend.dev',
        client: MockClient((request) async {
          mails.add(request);
          return http.Response('{"id":"mail"}', 200);
        }),
      ),
    );
  });

  tearDown(() => backend.close());

  test("candidature : mail à l'administrateur, invisible avant validation, coach une fois validée", () async {
    final karim = await register('Karim');
    final submitted = await json(await send('POST', '/coach/application', token: karim.token, body: profile()));
    expect(submitted['status'], 'pending');
    await Future<void>.delayed(Duration.zero);

    expect(mails, hasLength(1));
    final mail = jsonDecode(mails.single.body) as Map<String, dynamic>;
    expect(mail['to'], ['admin@example.com']);
    expect(mail['subject'], contains('Karim'));
    expect(mail['html'], contains('/admin/coach-applications/${submitted['id']}/approve'));
    expect(mail['html'], contains('running, strength'));

    expect((await send('POST', '/coach/application', token: karim.token, body: profile())).statusCode, 409);
    expect((await json(await send('GET', '/coaches/public', token: karim.token)))['coaches'], isEmpty);
    expect((await json(await admin('GET', '/admin/stats')))['coaches']['pending_applications'], 1);

    final pending = await json(await admin('GET', '/admin/coach-applications'));
    expect((pending['applications'] as List).single['email'], 'karim@example.com');

    await json(await admin('POST', '/admin/coach-applications/${submitted['id']}/approve'));
    final me = await json(await send('GET', '/me', token: karim.token));
    expect(me['profile']['isCoach'], isTrue);
    expect((await json(await send('GET', '/coach/application', token: karim.token)))['application']['status'],
        'approved');

    final directory = (await json(await send('GET', '/coaches/public', token: karim.token)))['coaches'] as List;
    expect(directory.single['specialities'], ['running', 'strength']);
    expect((await send('POST', '/coach/application', token: karim.token, body: profile())).statusCode, 409);
  });

  test('candidature refusée : une nouvelle est possible ; spécialité inconnue refusée', () async {
    final lea = await register('Lea');
    expect(
      (await send('POST', '/coach/application', token: lea.token, body: profile(specialities: ['93']))).statusCode,
      400,
    );
    final first = await json(await send('POST', '/coach/application', token: lea.token, body: profile()));
    await json(await admin('POST', '/admin/coach-applications/${first['id']}/reject'));
    expect((await admin('POST', '/admin/coach-applications/${first['id']}/approve')).statusCode, 404);
    expect((await json(await send('GET', '/me', token: lea.token)))['profile']['isCoach'], isFalse);

    final second = await json(await send('POST', '/coach/application', token: lea.token, body: profile()));
    expect(second['status'], 'pending');
    expect((await send('POST', '/admin/coach-applications/x/approve')).statusCode, 401);
  });

  group("demandes d'invitation", () {
    late ({String token, String id}) coach;
    late ({String token, String id}) athlete;

    setUp(() async {
      coach = await register('Coach');
      athlete = await register('Athlete');
      final application = await json(await send('POST', '/coach/application', token: coach.token, body: profile()));
      await json(await admin('POST', '/admin/coach-applications/${application['id']}/approve'));
    });

    test("vers un compte qui n'est pas coach : refusée", () async {
      final other = await register('Other');
      expect((await send('POST', '/coach/${other.id}/invite-requests', token: athlete.token)).statusCode, 404);
    });

    test("l'athlète voit sa demande, l'annule, puis peut en renvoyer une", () async {
      await json(await send('POST', '/coach/${coach.id}/invite-requests', token: athlete.token));
      final mine = (await json(await send('GET', '/athlete/invite-request', token: athlete.token)))['request'];
      expect(mine['coachName'], 'Coach');
      expect(DateTime.parse(mine['expiresAt'] as String).difference(DateTime.parse(mine['createdAt'] as String)),
          const Duration(days: 14));

      expect((await send('DELETE', '/athlete/invite-request', token: athlete.token)).statusCode, 204);
      expect((await json(await send('GET', '/athlete/invite-request', token: athlete.token)))['request'], isNull);
      expect((await json(await send('GET', '/coach/invite-requests', token: coach.token)))['requests'], isEmpty);
      expect((await send('DELETE', '/athlete/invite-request', token: athlete.token)).statusCode, 404);
      await json(await send('POST', '/coach/${coach.id}/invite-requests', token: athlete.token));
    });

    test('une demande sans réponse depuis 14 jours expire et ne bloque plus', () async {
      final request = await json(await send('POST', '/coach/${coach.id}/invite-requests', token: athlete.token));
      backend.database.raw.execute(
        'UPDATE coach_invite_requests SET created_at=? WHERE id=?',
        [DateTime.now().toUtc().subtract(const Duration(days: 15)).toIso8601String(), request['id']],
      );

      expect((await json(await send('GET', '/coach/invite-requests', token: coach.token)))['requests'], isEmpty);
      expect((await send('POST', '/coach/invite-requests/${request['id']}/approve', token: coach.token)).statusCode,
          404);
      await json(await send('POST', '/coach/${coach.id}/invite-requests', token: athlete.token));
    });

    test('limite de fréquence sur les codes générés', () async {
      for (var i = 0; i < 10; i++) {
        await json(await send('POST', '/coach/invite-codes', token: coach.token));
      }
      expect((await send('POST', '/coach/invite-codes', token: coach.token)).statusCode, 429);
    });
  });

  test("les notes d'un coach partent avec son compte", () async {
    final coach = await register('Coach');
    final athlete = await register('Athlete');
    final application = await json(await send('POST', '/coach/application', token: coach.token, body: profile()));
    await json(await admin('POST', '/admin/coach-applications/${application['id']}/approve'));
    final code = (await json(await send('POST', '/coach/invite-codes', token: coach.token)))['code'];
    await json(await send('POST', '/coach/invite-codes/redeem', token: athlete.token, body: {'code': code}));
    await json(await send('POST', '/workouts', token: athlete.token, body: {
      'localId': 1,
      'workoutDate': '2026-11-18',
      'exercises': const [],
    }));
    final workoutId = backend.database.raw.select('SELECT id FROM workouts').single['id'];
    await json(await send('PUT', '/coach/athletes/${athlete.id}/workouts/$workoutId/note',
        token: coach.token, body: {'noteText': 'Bien'}));

    expect((await admin('DELETE', '/admin/users/${coach.id}')).statusCode, 200);
    expect(backend.database.raw.select('SELECT 1 FROM coach_workout_notes'), isEmpty);
  });

  test("migration : clés étrangères ajoutées aux notes, notes orphelines retirées", () {
    final dir = Directory.systemTemp.createTempSync('notes_fk');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/old.db';
    sqlite3.sqlite3.open(path)
      ..execute('''
        CREATE TABLE users (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, display_name TEXT NOT NULL,
          photo_url TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, last_login_at TEXT,
          is_deleted INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE coach_workout_notes (id TEXT PRIMARY KEY, coach_user_id TEXT NOT NULL,
          athlete_user_id TEXT NOT NULL, workout_id TEXT NOT NULL, note_text TEXT NOT NULL,
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL, UNIQUE(coach_user_id, workout_id));
        INSERT INTO users VALUES ('c', 'c@x.com', 'C', NULL, 't', 't', NULL, 0), ('a', 'a@x.com', 'A', NULL, 't', 't', NULL, 0);
        INSERT INTO coach_workout_notes VALUES ('n1', 'c', 'a', 'w1', 'Bien', 't', 't'), ('n2', 'gone', 'a', 'w2', 'Orpheline', 't', 't');
      ''')
      ..dispose();

    final db = AppDatabase.open(path);
    addTearDown(db.close);
    expect(db.raw.select('PRAGMA foreign_key_list(coach_workout_notes)'), hasLength(2));
    expect(db.raw.select('SELECT id FROM coach_workout_notes').map((r) => r['id']), ['n1']);
  });

  test("l'app lit le réglage du coaching sans compte", () async {
    expect(await json(await send('GET', '/config')), {'coachEnabled': true});
  });
}
