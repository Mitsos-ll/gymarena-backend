import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jose/jose.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/src/app.dart';
import '../lib/src/services/push_service.dart';
import 'test_config.dart';

/// Clé RSA jetable, générée pour ces tests uniquement.
const _testKey = '''-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDw1aOGT1shYlm3
SZ5eyftt6XTQe8JwJNOeG1t2qeIdzWgrXvwxAB8SFtg2zHg4Djq1zMdIUKzcBh+0
FuWksfTeAjdAFRxlrp8dkwLSYUgGqCzpwCmDmVBf+of+YXQaaqktSnN2qiHfUuCN
bFytIE2ELn0DgeRgk98o522Zxn3MSfD0p1sRN9CCGVRIJYP2NLMDb5WO2/DnvJhU
SkLdNUTNDCZvRXzyNlLSEUfwnXmSX+IZyGFPMUNaowlMmjmA7isZ/yJ/4tJ+ghGB
x2NMRlIB6Yaq6TS0aamooMxx5oEAoUNqY/ojwI5qnCTuHYuFIuxxTjOWpkDTwyVm
dXBu7bN3AgMBAAECggEAHfMTcOJxfMdUTNzU2wjXQaXkpwCc/4E059aTG0CpI/el
Wq9nQVi4hHFe1gG7eY0bc/xRVAbkWEBStPyb9k1DHFC+OjPl4idDFlRv52W9pUZI
v5DsGLd6LVVkkBfibl6RR1aY4UrrB3CxCCVPqR/5Q9TcKxF+Kxx4hgexs4vhnQPf
NeG7nSOo6s7Hsw08FXMDQ9rp42RXKeimx88Gj54bJOhFoHrLYJky0zWA5+iWjsu6
wLS14+jRVWwGeeETc3cDtVm7bvjzU63uysVEmmmIqjEregTsfWNtBYDPlzUG3aOR
IroEDdH3fuzrvJ1w3e4lcFJYJ4tchSR4+gLq6x9+sQKBgQD7twkCfFMgZyzVvA5p
432Yn0kS0tkaogP70p5Jdcb1K8I99iixaQXuxlhSiYpM0PsO/HdFf1IIcD7o3DSp
kmYlau3IQ0nsIvmxvq+Tz3i4TTNHFKrl4YRFaabpSCl9S0GLPOu/7vcUIsmZogzy
sp18LHki1RWdLLYUJAEPUe3D2wKBgQD07y/bmeEK3k9cQGxQ1R17DBF5LQVVGjD0
8hELGYK0TVBcq5uzPilPXVFsmDe4/mKTxrO4eIbtEk2jvX5Vzel8N7kwP9oZiarZ
POc0tDU5GBoFMBUEjuzawxiixRP1PQ5XK8zS/qI8P0P64jxGSzvEn84z8KJKTb/r
DG5RuHivlQKBgQCupyywNdVz2UMJtmeF31wJJxSL5BLR4PLEqzo7HGaFPOyVE5Te
rFF6gNNNybNVY3efyVt0tEgWJNPxvMEpm7QWaGA+oTnMh+QbCYVIGR/ZOW/H9TYz
NUwS4aD3oqNvFWWQGCA317ZGmXCqkf9L8tVFEJKosZNCsIBR7z1xBNbmGwKBgQCF
VV+cD9xt6i8RbRCJwDnYLe2lJVjtxuA3tz6H6E86j4vbpp+Pp5sdVRNqJkLPNcu7
3kMffJ0WmQwiwpjvZLRhpoPtPBUiKcsTjw/dpOwENJaVlGMcpCFTxTi4Asimi6Iu
2e0aPvtaCKadAGMHcRUMKGI77BaslD6RWacEXYN1MQKBgF3I4zMzO6DsYCnLsIiu
HzVWQJqgV/ZduT6cvMjtlKRpfIZmWvfHvz0v4oHuLrmh6Rv+du+vYVW/jq2o8rk3
WeX07iad6NA8sKyyv+4r6/CqH5fN8oyGKMIfOV0eta9X5woLhqhW4ot3oKI0a8Pq
Zj051RgdZavHEgKaHplgtTfp
-----END PRIVATE KEY-----''';

final _account = {
  'type': 'service_account',
  'project_id': 'gymarena-test',
  'private_key_id': 'k1',
  'private_key': _testKey,
  'client_email': 'push@gymarena-test.iam.gserviceaccount.com',
  'token_uri': 'https://oauth2.googleapis.com/token',
};

class _FakeSender implements PushSender {
  final sent = <({String token, String title, String body, Map<String, String> data})>[];
  final expired = <String>{};

  @override
  Future<bool> send({
    required String token,
    required String title,
    required String body,
    required Map<String, String> data,
  }) async {
    sent.add((token: token, title: title, body: body, data: data));
    return !expired.contains(token);
  }
}

void main() {
  group('envoi Firebase', () {
    test('jeton OAuth signé avec la clé du compte de service, gardé entre deux envois', () async {
      final requests = <http.Request>[];
      final sender = FcmPushSender.fromServiceAccount(
        base64.encode(utf8.encode(jsonEncode(_account))),
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.host == 'oauth2.googleapis.com') {
            return http.Response(jsonEncode({'access_token': 'ya29.test', 'expires_in': 3600}), 200);
          }
          return http.Response('{"name":"projects/gymarena-test/messages/1"}', 200);
        }),
      )!;

      expect(await sender.send(token: 'phone-1', title: 'T', body: 'B', data: {'type': 'coach_note'}), isTrue);
      expect(await sender.send(token: 'phone-2', title: 'T', body: 'B', data: const {}), isTrue);
      expect(requests.where((r) => r.url.host == 'oauth2.googleapis.com'), hasLength(1));

      final assertion = requests.first.bodyFields['assertion']!;
      final jws = JsonWebSignature.fromCompactSerialization(assertion);
      final store = JsonWebKeyStore()..addKey(JsonWebKey.fromPem(_testKey, keyId: 'k1'));
      expect(await jws.verify(store), isTrue);
      final claims = jws.unverifiedPayload.jsonContent as Map<String, dynamic>;
      expect(claims['iss'], _account['client_email']);
      expect(claims['scope'], 'https://www.googleapis.com/auth/firebase.messaging');

      final message = requests[1];
      expect(message.url.toString(), 'https://fcm.googleapis.com/v1/projects/gymarena-test/messages:send');
      expect(message.headers['Authorization'], 'Bearer ya29.test');
      final body = jsonDecode(message.body)['message'] as Map<String, dynamic>;
      expect(body['token'], 'phone-1');
      expect(body['data'], {'type': 'coach_note'});
      expect(body['android']['notification']['channel_id'], 'coach_v1');
    });

    test('téléphone inconnu : à oublier ; panne passagère : on le garde', () async {
      var status = 404;
      final sender = FcmPushSender.fromServiceAccount(
        jsonEncode(_account),
        client: MockClient((request) async => request.url.host == 'oauth2.googleapis.com'
            ? http.Response(jsonEncode({'access_token': 'a', 'expires_in': 3600}), 200)
            : status == 404
                ? http.Response('{"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}', 404)
                : http.Response('{"error":{"status":"UNAVAILABLE"}}', status)),
      )!;
      expect(await sender.send(token: 'old', title: 'T', body: 'B', data: const {}), isFalse);
      status = 503;
      expect(await sender.send(token: 'ok', title: 'T', body: 'B', data: const {}), isTrue);
    });

    test('compte de service absent ou illisible : notifications désactivées', () {
      expect(FcmPushSender.fromServiceAccount(''), isNull);
      expect(FcmPushSender.fromServiceAccount('pas du base64 !'), isNull);
      expect(FcmPushSender.fromServiceAccount(jsonEncode({'project_id': 'x'})), isNull);
    });

    test('textes dans la langue du téléphone, français par défaut', () {
      expect(pushText(PushEvent.inviteRequest, 'es', {'athlete': 'Léa'}).body, 'Léa quiere unirse a ti');
      expect(pushText(PushEvent.inviteRequest, 'de', {'athlete': 'Léa'}).body, 'Léa souhaite vous rejoindre');
      expect(PushNotifier.clip('a' * 200), hasLength(PushNotifier.maxNoteLength));
    });
  });

  group('notifications du coaching', () {
    late GymTrackBackend backend;
    late _FakeSender sender;
    late ({String token, String id}) coach;
    late ({String token, String id}) athlete;

    Future<Response> send(String method, String path, {String? token, Object? body}) async => backend.handler(Request(
          method,
          Uri.parse('http://localhost$path'),
          body: body == null ? null : jsonEncode(body),
          headers: {
            'Content-Type': 'application/json',
            if (token != null) 'Authorization': 'Bearer $token',
          },
        ));

    Future<Map<String, dynamic>> json(Response res) async {
      final text = await res.readAsString();
      expect(res.statusCode, 200, reason: text);
      return text.isEmpty ? {} : jsonDecode(text) as Map<String, dynamic>;
    }

    Future<({String token, String id})> register(String name) async {
      final body = await json(await send('POST', '/auth/register', body: {
        'email': '${name.toLowerCase()}@example.com',
        'password': 'password123',
        'displayName': name,
      }));
      return (token: body['accessToken'] as String, id: (body['user'] as Map)['id'] as String);
    }

    Future<void> phone(({String token, String id}) user, String token, String locale) async {
      final res = await send('PUT', '/me/push-tokens',
          token: user.token, body: {'token': token, 'platform': 'android', 'locale': locale});
      expect(res.statusCode, 204);
    }

    setUp(() async {
      sender = _FakeSender();
      backend = GymTrackBackend(testConfig(), pushSender: sender);
      coach = await register('Coach');
      athlete = await register('Athlete');
      final admin = await send('PUT', '/admin/users/${coach.id}/set-coach',
          token: 'test-admin-secret', body: {'isCoach': true});
      expect(admin.statusCode, 200);
      await phone(coach, 'coach-phone', 'fr');
      await phone(athlete, 'athlete-phone', 'en');
    });

    tearDown(() => backend.close());

    test("demande puis acceptation : le coach puis l'athlète sont prévenus", () async {
      final request = await json(await send('POST', '/coach/${coach.id}/invite-requests', token: athlete.token));
      await pumpEventQueue();
      expect(sender.sent.single.token, 'coach-phone');
      expect(sender.sent.single.body, 'Athlete souhaite vous rejoindre');
      expect(sender.sent.single.data, {'type': 'invite_request'});

      await json(await send('POST', '/coach/invite-requests/${request['id']}/approve', token: coach.token));
      await pumpEventQueue();
      expect(sender.sent.last.token, 'athlete-phone');
      expect(sender.sent.last.body, 'Coach accepted your request');
    });

    test('note : prévenu à la création et à la modification, pas pour un même texte ; programme assigné', () async {
      final code = (await json(await send('POST', '/coach/invite-codes', token: coach.token)))['code'];
      await json(await send('POST', '/coach/invite-codes/redeem', token: athlete.token, body: {'code': code}));
      await json(await send('POST', '/workouts', token: athlete.token, body: {
        'localId': 42,
        'workoutDate': '2026-11-18',
        'exercises': const [],
      }));
      final workoutId = backend.database.raw.select('SELECT id FROM workouts').single['id'];
      Future<void> note(String text) async {
        await json(await send('PUT', '/coach/athletes/${athlete.id}/workouts/$workoutId/note',
            token: coach.token, body: {'noteText': text}));
        await pumpEventQueue();
      }

      await note('Bien joué');
      await note('Bien joué');
      await note('Bien joué, descends plus bas');
      expect(sender.sent.map((m) => m.body), ['Bien joué', 'Bien joué, descends plus bas']);
      expect(sender.sent.first.title, 'Note from Coach');
      expect(sender.sent.first.data, {'type': 'coach_note', 'workoutLocalId': '42'});

      await json(await send('PUT', '/coach/athletes/${athlete.id}/program',
          token: coach.token, body: {'type': 'builtin', 'code': 'full_body', 'name': 'Full Body'}));
      await pumpEventQueue();
      expect(sender.sent.last.body, 'Coach assigned you "Full Body"');
    });

    test('candidature validée : le candidat est prévenu', () async {
      final application = await json(await send('POST', '/coach/application', token: athlete.token, body: {
        'specialities': ['running'],
        'languages': ['English'],
        'isPublic': true,
      }));
      final res = await send('POST', '/admin/coach-applications/${application['id']}/approve',
          token: 'test-admin-secret');
      expect(res.statusCode, 200);
      await pumpEventQueue();
      expect(sender.sent.single.token, 'athlete-phone');
      expect(sender.sent.single.data, {'type': 'coach_approved'});
    });

    test('téléphones : périmé oublié, changé de compte, retiré à la déconnexion', () async {
      await phone(athlete, 'second-phone', 'es');
      sender.expired.add('second-phone');
      final request = await json(await send('POST', '/coach/${coach.id}/invite-requests', token: athlete.token));
      await json(await send('POST', '/coach/invite-requests/${request['id']}/approve', token: coach.token));
      await pumpEventQueue();
      List<Object?> phones() =>
          backend.database.raw.select('SELECT token FROM push_tokens ORDER BY token').map((r) => r['token']).toList();
      expect(phones(), ['athlete-phone', 'coach-phone']);

      // Le téléphone du coach sert désormais à l'athlète.
      await phone(athlete, 'coach-phone', 'en');
      expect(backend.database.raw.select("SELECT user_id FROM push_tokens WHERE token='coach-phone'").single['user_id'],
          athlete.id);

      expect(
        (await send('DELETE', '/me/push-tokens', token: athlete.token, body: {'token': 'athlete-phone'})).statusCode,
        204,
      );
      expect(phones(), ['coach-phone']);
      expect(
        (await send('PUT', '/me/push-tokens', token: athlete.token, body: {'token': 'x', 'platform': 'web'})).statusCode,
        400,
      );
    });
  });
}
