import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/src/app.dart';
import '../lib/src/repositories/moderation_repository.dart';
import 'test_config.dart';

class _User {
  _User(this.id, this.displayName, this.token);

  final String id;
  final String displayName;
  final String token;
}

void main() {
  late GymTrackBackend backend;

  setUp(() {
    backend = GymTrackBackend(testConfig());
  });

  tearDown(() => backend.close());

  // ── Helpers ────────────────────────────────────────────────────────────────

  Future<Response> call(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? token,
    String? adminSecret,
  }) async =>
      await backend.handler(Request(
        method,
        Uri.parse('http://localhost$path'),
        body: body == null ? null : jsonEncode(body),
        headers: {
          if (body != null) 'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
          if (adminSecret != null) 'Authorization': 'Bearer $adminSecret',
        },
      ));

  Future<Map<String, dynamic>> json(Response res) async =>
      jsonDecode(await res.readAsString()) as Map<String, dynamic>;

  Future<_User> register(String name) async {
    final res = await call('POST', '/auth/register', body: {
      'email': '${name.toLowerCase()}@example.com',
      'password': 'password123',
      'displayName': name,
    });
    final body = await json(res);
    return _User(body['user']['id'] as String, name, body['accessToken'] as String);
  }

  Future<Response> block(_User by, _User target) =>
      call('POST', '/community/blocks', body: {'userId': target.id}, token: by.token);

  Future<Response> lookup(_User by, _User target) => call(
        'GET',
        '/community/users/lookup?displayName=${Uri.encodeQueryComponent(target.displayName)}',
        token: by.token,
      );

  Future<Response> requestFriend(_User from, _User to) => call(
        'POST',
        '/community/relations',
        body: {'userIdB': to.id, 'status': 'friend', 'requestStatus': 'pending'},
        token: from.token,
      );

  /// Rend [a] et [b] amis (demande + acceptation).
  Future<void> makeFriends(_User a, _User b) async {
    final sent = await json(await requestFriend(a, b));
    final accepted = await call(
      'PATCH',
      '/community/relations/${sent['id']}',
      body: {'requestStatus': 'accepted'},
      token: b.token,
    );
    expect(accepted.statusCode, 200);
  }

  Future<List<dynamic>> relationsOf(_User user) async {
    final res = await call('GET', '/community/relations', token: user.token);
    return (await json(res))['relations'] as List<dynamic>;
  }

  Future<Response> report(_User by, _User target, {String reason = 'harassment', String? details}) =>
      call(
        'POST',
        '/community/reports',
        body: {'userId': target.id, 'reason': reason, if (details != null) 'details': details},
        token: by.token,
      );

  // ── Blocage ────────────────────────────────────────────────────────────────

  group('blocking', () {
    test('lists the people you blocked, and only them', () async {
      final alice = await register('Alice');
      final bob = await register('Bobby');

      expect((await block(alice, bob)).statusCode, 200);

      final listed = (await json(await call('GET', '/community/blocks', token: alice.token)))['blocked'] as List;
      expect(listed.map((b) => b['userId']), [bob.id]);
      expect(listed.single['displayName'], 'Bobby');
      final seenByBob = (await json(await call('GET', '/community/blocks', token: bob.token)))['blocked'] as List;
      expect(seenByBob, isEmpty);
    });

    test('is idempotent', () async {
      final alice = await register('Alice');
      final bob = await register('Bobby');

      await block(alice, bob);
      expect((await block(alice, bob)).statusCode, 200);

      expect(backend.moderationRepository.listBlockedBy(alice.id), hasLength(1));
    });

    test('ends an existing friendship for both people', () async {
      final alice = await register('Alice');
      final bob = await register('Bobby');
      await makeFriends(alice, bob);
      expect(await relationsOf(bob), isNotEmpty);

      await block(alice, bob);

      expect(await relationsOf(alice), isEmpty);
      expect(await relationsOf(bob), isEmpty);
    });

    test('cancels a pending friend request', () async {
      final alice = await register('Alice');
      final bob = await register('Bobby');
      await requestFriend(bob, alice);

      await block(alice, bob);

      expect(await relationsOf(alice), isEmpty);
    });

    test('hides each person from the other in the search, both ways', () async {
      final alice = await register('Alice');
      final bob = await register('Bobby');
      expect((await lookup(bob, alice)).statusCode, 200);

      await block(alice, bob);

      expect((await lookup(bob, alice)).statusCode, 404);
      expect((await lookup(alice, bob)).statusCode, 404);
    });

    test('prevents friend requests in both directions, without revealing the block', () async {
      final alice = await register('Alice');
      final bob = await register('Bobby');
      await block(alice, bob);

      final fromBlocked = await requestFriend(bob, alice);
      final toBlocked = await requestFriend(alice, bob);

      expect(fromBlocked.statusCode, 404);
      expect(toBlocked.statusCode, 404);
      expect((await json(fromBlocked))['message'], 'User not found.');
    });

    test('cannot be bypassed with an invite code', () async {
      final alice = await register('Alice');
      final bob = await register('Bobby');
      final code = (await json(await call('POST', '/invites', token: alice.token)))['code'];
      await block(alice, bob);

      final redeem = await call('POST', '/invites/$code/redeem', token: bob.token);

      expect(redeem.statusCode, 404);
      expect(await relationsOf(bob), isEmpty);
    });

    test('can be undone, and friendship is possible again', () async {
      final alice = await register('Alice');
      final bob = await register('Bobby');
      await block(alice, bob);

      final res = await call('DELETE', '/community/blocks/${bob.id}', token: alice.token);

      expect(res.statusCode, 200);
      expect((await lookup(bob, alice)).statusCode, 200);
      expect((await requestFriend(bob, alice)).statusCode, 200);
    });

    test('rejects blocking yourself, an unknown user and anonymous calls', () async {
      final alice = await register('Alice');

      expect((await block(alice, alice)).statusCode, 400);
      final unknown = await call('POST', '/community/blocks',
          body: {'userId': 'no-such-user'}, token: alice.token);
      expect(unknown.statusCode, 404);
      final anonymous = await call('POST', '/community/blocks', body: {'userId': alice.id});
      expect(anonymous.statusCode, 401);
      final missing = await call('POST', '/community/blocks', body: {}, token: alice.token);
      expect(missing.statusCode, 400);
    });

    test('is removed when either account is deleted', () async {
      final alice = await register('Alice');
      final bob = await register('Bobby');
      await block(alice, bob);

      await call('DELETE', '/me', token: bob.token);

      expect(
        backend.database.raw.select('SELECT 1 FROM user_blocks'),
        isEmpty,
      );
    });
  });

  // ── Signalement ────────────────────────────────────────────────────────────

  group('reporting', () {
    test('stores the report with its reason and details', () async {
      final alice = await register('Alice');
      final bob = await register('Bobby');

      final res = await report(alice, bob, reason: 'spam', details: '  Pseudo trompeur  ');

      expect(res.statusCode, 200);
      final rows = backend.database.raw.select('SELECT * FROM user_reports');
      expect(rows, hasLength(1));
      expect(rows.single['reporter_id'], alice.id);
      expect(rows.single['reported_id'], bob.id);
      expect(rows.single['reason'], 'spam');
      expect(rows.single['details'], 'Pseudo trompeur');
      expect(rows.single['status'], 'open');
    });

    test('accepts every documented reason, and no other', () async {
      final alice = await register('Alice');
      final bob = await register('Bobby');

      for (final reason in reportReasons) {
        expect((await report(alice, bob, reason: reason)).statusCode, 200, reason: reason);
      }
      expect((await report(alice, bob, reason: 'because')).statusCode, 400);
      final noReason = await call('POST', '/community/reports',
          body: {'userId': bob.id}, token: alice.token);
      expect(noReason.statusCode, 400);
    });

    test('rejects oversized details, self-reports, unknown users and anonymous calls', () async {
      final alice = await register('Alice');
      final bob = await register('Bobby');

      expect((await report(alice, bob, details: 'x' * 501)).statusCode, 400);
      expect((await report(alice, alice)).statusCode, 400);
      final unknown = await call('POST', '/community/reports',
          body: {'userId': 'ghost', 'reason': 'spam'}, token: alice.token);
      expect(unknown.statusCode, 404);
      final anonymous = await call('POST', '/community/reports',
          body: {'userId': bob.id, 'reason': 'spam'});
      expect(anonymous.statusCode, 401);
    });

    test('throttles a reporter who floods the system', () async {
      final alice = await register('Alice');
      final bob = await register('Bobby');

      for (var i = 0; i < ModerationRepository.maxReportsPerHour; i++) {
        expect((await report(alice, bob)).statusCode, 200);
      }

      expect((await report(alice, bob)).statusCode, 429);
    });
  });

  // ── Administration ─────────────────────────────────────────────────────────

  group('admin', () {
    const secret = 'test-admin-secret';

    test('requires the admin secret', () async {
      expect((await call('GET', '/admin/reports')).statusCode, 401);
      expect((await call('GET', '/admin/reports', adminSecret: 'wrong')).statusCode, 401);
      expect((await call('DELETE', '/admin/users/x', adminSecret: 'wrong')).statusCode, 401);
    });

    test('lists open reports with the names of both people', () async {
      final alice = await register('Alice');
      final bob = await register('Bobby');
      await report(alice, bob, reason: 'harassment', details: 'Messages répétés');

      final body = await json(await call('GET', '/admin/reports', adminSecret: secret));

      expect(body['total'], 1);
      final entry = (body['reports'] as List).single as Map;
      expect(entry['reporterName'], 'Alice');
      expect(entry['reportedName'], 'Bobby');
      expect(entry['reportedId'], bob.id);
      expect(entry['reason'], 'harassment');
      expect(entry['details'], 'Messages répétés');
    });

    test('moves a report from open to resolved', () async {
      final alice = await register('Alice');
      final bob = await register('Bobby');
      final id = (await json(await report(alice, bob)))['id'];

      final resolved = await call('POST', '/admin/reports/$id/resolve', adminSecret: secret);

      expect(resolved.statusCode, 200);
      final open = await json(await call('GET', '/admin/reports', adminSecret: secret));
      expect(open['total'], 0);
      final done = await json(await call('GET', '/admin/reports?status=resolved', adminSecret: secret));
      expect(done['total'], 1);
      expect((await call('POST', '/admin/reports/nope/resolve', adminSecret: secret)).statusCode, 404);
    });

    test('deletes a reported account for good, with its data', () async {
      final alice = await register('Alice');
      final bob = await register('Bobby');
      await report(alice, bob);

      final res = await call('DELETE', '/admin/users/${bob.id}', adminSecret: secret);

      expect(res.statusCode, 200);
      expect(backend.database.raw.select('SELECT id FROM users WHERE id=?', [bob.id]), isEmpty);
      expect(backend.database.raw.select('SELECT id FROM user_reports'), isEmpty);
      expect((await call('GET', '/me', token: bob.token)).statusCode, 401);
      expect((await call('DELETE', '/admin/users/${bob.id}', adminSecret: secret)).statusCode, 404);
    });
  });
}
