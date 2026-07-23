import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/src/app.dart';
import 'test_config.dart';

/// Régression : community_profiles.display_name est un instantané pris à la
/// création du profil communauté (avatar/gamification), jamais resynchronisé
/// quand l'utilisateur renomme son pseudo dans "Mon compte" ensuite. Les
/// routes qui affichent le nom d'un ami (relations, partages) doivent
/// préférer user_profiles.display_name — toujours à jour — plutôt que ce
/// mirroir potentiellement obsolète.
void main() {
  late GymTrackBackend backend;

  setUp(() {
    backend = GymTrackBackend(testConfig());
  });

  tearDown(() => backend.close());

  Future<Response> post(String path, Map<String, dynamic> body, {String? bearerToken}) async {
    return backend.handler(Request(
      'POST',
      Uri.parse('http://localhost$path'),
      body: jsonEncode(body),
      headers: {
        'Content-Type': 'application/json',
        if (bearerToken != null) 'Authorization': 'Bearer $bearerToken',
      },
    ));
  }

  Future<Response> put(String path, Map<String, dynamic> body, {required String bearerToken}) async {
    return backend.handler(Request(
      'PUT',
      Uri.parse('http://localhost$path'),
      body: jsonEncode(body),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $bearerToken',
      },
    ));
  }

  Future<Response> patch(String path, Map<String, dynamic> body, {required String bearerToken}) async {
    return backend.handler(Request(
      'PATCH',
      Uri.parse('http://localhost$path'),
      body: jsonEncode(body),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $bearerToken',
      },
    ));
  }

  Future<Response> get(String path, {required String bearerToken}) async {
    return backend.handler(Request(
      'GET',
      Uri.parse('http://localhost$path'),
      headers: {'Authorization': 'Bearer $bearerToken'},
    ));
  }

  Future<Map<String, dynamic>> registerAndGetSession(String email, {String? displayName}) async {
    final res = await post('/auth/register', {
      'email': email,
      'password': 'password123',
      if (displayName != null) 'displayName': displayName,
    });
    return jsonDecode(await res.readAsString()) as Map<String, dynamic>;
  }

  test(
      'GET /community/relations affiche le pseudo à jour, pas l\'instantané '
      'obsolète de community_profiles', () async {
    final sessionA = await registerAndGetSession('display-fresh-a@example.com', displayName: 'Caller');
    final tokenA = sessionA['accessToken'] as String;

    final sessionB = await registerAndGetSession('display-fresh-b@example.com', displayName: 'Antonin Pangrani');
    final tokenB = sessionB['accessToken'] as String;
    final userIdB = (sessionB['user'] as Map)['id'] as String;

    // B pousse un profil communauté (avatar/gamification) avec le pseudo
    // qu'il avait AU MOMENT de cette création — deviendra l'instantané obsolète.
    await put('/me/community-profile', {'displayName': 'Antonin Pangrani'}, bearerToken: tokenB);

    // A envoie une demande, B l'accepte.
    final relRes = await post('/community/relations', {'userIdB': userIdB, 'status': 'friend'},
        bearerToken: tokenA);
    final relationId = (jsonDecode(await relRes.readAsString()) as Map)['id'] as String;
    await patch('/community/relations/$relationId', {'requestStatus': 'accepted'}, bearerToken: tokenB);

    // B renomme son pseudo réel dans "Mon compte" — mais son community_profile
    // n'est jamais re-poussé avec ce nouveau nom (comportement actuel du client).
    final upsertRes = await put('/me/profile', {'displayName': 'Rhumcha', 'sex': 'male'}, bearerToken: tokenB);
    expect(upsertRes.statusCode, 200);

    // A consulte ses relations : doit voir "Rhumcha" (le pseudo réel et actuel
    // de B), pas "Antonin Pangrani" (l'instantané obsolète de community_profiles).
    final res = await get('/community/relations', bearerToken: tokenA);
    final body = jsonDecode(await res.readAsString()) as Map;
    final relations = body['relations'] as List;
    final otherProfile = (relations.first as Map)['otherProfile'] as Map;
    expect(otherProfile['displayName'], 'Rhumcha');
  });

  test(
      'GET /community/friends/shares affiche le pseudo à jour du propriétaire, '
      'pas l\'instantané obsolète', () async {
    final sessionA = await registerAndGetSession('display-fresh-c@example.com', displayName: 'Caller2');
    final tokenA = sessionA['accessToken'] as String;

    final sessionB = await registerAndGetSession('display-fresh-d@example.com', displayName: 'Rickyyyy');
    final tokenB = sessionB['accessToken'] as String;
    final userIdB = (sessionB['user'] as Map)['id'] as String;

    await put('/me/community-profile', {'displayName': 'Dimitri Evanghelou'}, bearerToken: tokenB);

    final relRes = await post('/community/relations', {'userIdB': userIdB, 'status': 'friend'},
        bearerToken: tokenA);
    final relationId = (jsonDecode(await relRes.readAsString()) as Map)['id'] as String;
    await patch('/community/relations/$relationId', {'requestStatus': 'accepted'}, bearerToken: tokenB);

    // Ici le pseudo réel (user_profiles/users, "Rickyyyy" depuis
    // l'inscription) diverge déjà de l'instantané communauté poussé
    // ci-dessus ("Dimitri Evanghelou") — même mécanique que le scénario 1,
    // sans avoir besoin d'un second renommage.
    await post('/community/shares/workout', {
      'id': 'share-1',
      'workoutId': 1,
      'title': 'Séance test',
      'snapshotJson': {},
      'visibility': 'friendsOnly',
    }, bearerToken: tokenB);

    final res = await get('/community/friends/shares', bearerToken: tokenA);
    final body = jsonDecode(await res.readAsString()) as Map;
    final shares = body['workoutShares'] as List;
    expect(shares, isNotEmpty);
    expect((shares.first as Map)['ownerDisplayName'], 'Rickyyyy');
  });
}
