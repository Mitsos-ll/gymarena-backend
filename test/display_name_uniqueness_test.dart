import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:test/test.dart';

import '../lib/src/app.dart';
import '../lib/src/config.dart';
import '../lib/src/db/app_database.dart';
import '../lib/src/models/api_profile.dart';
import '../lib/src/repositories/user_repository.dart';
import '../lib/src/services/google_token_service.dart';
import '../lib/src/utils/api_exception.dart';
import '../lib/src/utils/validator.dart';
import 'test_config.dart';

void main() {
  late GymTrackBackend backend;

  setUp(() {
    backend = GymTrackBackend(testConfig());
  });

  tearDown(() => backend.close());

  // ── Helpers ────────────────────────────────────────────────────────────────

  Future<Response> post(String path, Map<String, dynamic> body) async {
    return backend.handler(Request(
      'POST',
      Uri.parse('http://localhost$path'),
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json'},
    ));
  }

  Future<Response> put(String path, Map<String, dynamic> body,
      {required String bearerToken}) async {
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

  Future<Response> get(String path) async {
    return backend.handler(Request('GET', Uri.parse('http://localhost$path')));
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

  // ── Inscription ────────────────────────────────────────────────────────────

  group('POST /auth/register — unicité du pseudo', () {
    test('rejette un pseudo déjà pris (409)', () async {
      await post('/auth/register', {
        'email': 'reg-a@example.com',
        'password': 'password123',
        'displayName': 'leo',
      });
      final res = await post('/auth/register', {
        'email': 'reg-b@example.com',
        'password': 'password123',
        'displayName': 'leo',
      });
      expect(res.statusCode, 409);
    });

    test('la comparaison est insensible à la casse', () async {
      await post('/auth/register', {
        'email': 'reg-c@example.com',
        'password': 'password123',
        'displayName': 'Leo',
      });
      final res = await post('/auth/register', {
        'email': 'reg-d@example.com',
        'password': 'password123',
        'displayName': 'LEO',
      });
      expect(res.statusCode, 409);
    });
  });

  // ── Édition du profil ────────────────────────────────────────────────────────

  group('PUT /me/profile — unicité du pseudo', () {
    test('un utilisateur peut resauvegarder son propre nom inchangé', () async {
      final token = await registerAndGetToken('me-a@example.com', displayName: 'sami');
      final res = await put('/me/profile', {'displayName': 'sami', 'sex': 'male'},
          bearerToken: token);
      expect(res.statusCode, 200);
    });

    test('un utilisateur peut juste changer la casse de son propre nom', () async {
      final token = await registerAndGetToken('me-b@example.com', displayName: 'sami');
      final res = await put('/me/profile', {'displayName': 'Sami', 'sex': 'male'},
          bearerToken: token);
      expect(res.statusCode, 200);
    });

    test('rejette le nom déjà pris par un autre utilisateur (409)', () async {
      await post('/auth/register', {
        'email': 'me-c@example.com',
        'password': 'password123',
        'displayName': 'takenname',
      });
      final token = await registerAndGetToken('me-d@example.com', displayName: 'other');
      final res = await put('/me/profile', {'displayName': 'takenname', 'sex': 'male'},
          bearerToken: token);
      expect(res.statusCode, 409);
    });
  });

  // ── Connexion Google ───────────────────────────────────────────────────────

  group('Google sign-in — unicité du pseudo', () {
    GoogleTokenPayload payload(String email, String displayName, {required String subject}) =>
        GoogleTokenPayload(
          subject: subject,
          email: email,
          displayName: displayName,
          photoUrl: null,
          emailVerified: true,
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        );

    test('deux comptes distincts avec le même nom sont auto-suffixés', () {
      final s1 = backend.userRepository
          .signInWithGoogle(payload('g1@example.com', 'Alex', subject: 'sub-a'));
      final s2 = backend.userRepository
          .signInWithGoogle(payload('g2@example.com', 'Alex', subject: 'sub-b'));
      expect(s1.user.displayName, 'Alex');
      expect(s2.user.displayName, 'Alex2');
    });

    test('une reconnexion sans changement de nom n\'est pas re-suffixée', () {
      final first = backend.userRepository
          .signInWithGoogle(payload('g3@example.com', 'Sam', subject: 'sub-c'));
      expect(first.user.displayName, 'Sam');

      // Régression : sans l'exclusion de soi, ce second appel re-suffixerait
      // "Sam" en "Sam2" puisque le premier compte "détient" déjà "sam".
      final second = backend.userRepository
          .signInWithGoogle(payload('g3@example.com', 'Sam', subject: 'sub-c'));
      expect(second.user.displayName, 'Sam');
    });

    test('un nom Google qui entre en collision au retour est auto-suffixé', () {
      backend.userRepository
          .signInWithGoogle(payload('g4@example.com', 'Robin', subject: 'sub-d'));

      final first = backend.userRepository
          .signInWithGoogle(payload('g5@example.com', 'Robin', subject: 'sub-e'));
      expect(first.user.displayName, 'Robin2');

      // Reconnexion : reste sur son nom déjà résolu, pas re-suffixé une 2e fois.
      final second = backend.userRepository
          .signInWithGoogle(payload('g5@example.com', 'Robin', subject: 'sub-e'));
      expect(second.user.displayName, 'Robin2');
    });

    test(
        'un pseudo personnalisé après coup n\'est pas écrasé par une reconnexion Google '
        '(même si le nom Google original est entre-temps pris par un tiers)', () {
      final session = backend.userRepository
          .signInWithGoogle(payload('g6@example.com', 'Alex', subject: 'sub-f'));
      expect(session.user.displayName, 'Alex');

      backend.userRepository.upsertProfile(
        session.accessToken,
        ApiProfileInput(
          displayName: 'AlexTheLegend',
          weightKg: null,
          heightCm: null,
          sex: UserSex.unspecified,
        ),
      );

      // Un tiers prend maintenant "Alex", le nom Google d'origine du 1er compte.
      backend.userRepository
          .signInWithGoogle(payload('g7@example.com', 'Alex', subject: 'sub-g'));

      // Régression : avant le correctif, cette reconnexion re-résolvait le nom
      // Google ("Alex", pris par le tiers) et écrasait silencieusement le
      // pseudo personnalisé en le re-suffixant ("Alex2").
      final reconnected = backend.userRepository
          .signInWithGoogle(payload('g6@example.com', 'Alex', subject: 'sub-f'));
      expect(reconnected.user.displayName, 'AlexTheLegend');
    });
  });

  // ── Vérification de disponibilité ─────────────────────────────────────────

  group('GET /auth/display-name-available', () {
    test('signale un pseudo libre', () async {
      final res = await get('/auth/display-name-available?displayName=libre123');
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString()) as Map;
      expect(body['available'], true);
    });

    test('signale un pseudo déjà pris', () async {
      await post('/auth/register', {
        'email': 'avail-a@example.com',
        'password': 'password123',
        'displayName': 'pris123',
      });
      final res = await get('/auth/display-name-available?displayName=pris123');
      final body = jsonDecode(await res.readAsString()) as Map;
      expect(body['available'], false);
    });

    test('rejette une valeur vide (400)', () async {
      final res = await get('/auth/display-name-available?displayName=');
      expect(res.statusCode, 400);
    });

    test(
        'n\'est pas soumise à la limite register/login (régression : la frappe live '
        'épuisait le budget en quelques secondes et faisait échouer le check en silence)',
        () async {
      // Config dédiée avec une limite auth très basse pour rendre le test
      // rapide et déterministe, plutôt que de dépendre du défaut de testConfig()
      // (1000 req/60s, jamais atteint en pratique dans un test unitaire).
      final tightConfig = AppConfig(
        port: 0,
        env: 'test',
        databasePath: ':memory:',
        googleWebClientId: 'test-client-id',
        accessTokenTtlDays: 1,
        refreshTokenTtlDays: 7,
        corsAllowedOrigins: ['*'],
        rateLimitMaxRequests: 1000,
        rateLimitWindowSeconds: 60,
        authRateLimitMaxRequests: 2,
        authRateLimitWindowSeconds: 60,
        adminSecret: 'test-admin-secret',
        resendApiKey: '',
        resendFromEmail: 'onboarding@resend.dev',
        workoutXApiKey: 'test-workoutx-key',
        workoutXBaseUrl: 'https://api.workoutxapp.com/v1',
      );
      final tightBackend = GymTrackBackend(tightConfig);
      addTearDown(tightBackend.close);

      Future<Response> checkAvailability() async => await tightBackend.handler(Request(
            'GET',
            Uri.parse('http://localhost/auth/display-name-available?displayName=libre456'),
          ));

      // Bien au-delà de la limite auth (2) : toutes doivent réussir puisque
      // cette route n'est plus couverte par _enforceAuthLimit.
      for (var i = 0; i < 5; i++) {
        final res = await checkAvailability();
        expect(res.statusCode, 200, reason: 'appel ${i + 1}/5');
      }

      // Sanity check : la limite auth est bien active sur cette config
      // (register, lui, la respecte toujours) — sinon le test ne prouverait rien.
      Future<Response> registerAttempt(String email) async => await tightBackend.handler(Request(
            'POST',
            Uri.parse('http://localhost/auth/register'),
            body: jsonEncode({'email': email, 'password': 'password123'}),
            headers: {'Content-Type': 'application/json'},
          ));
      await registerAttempt('tight-a@example.com');
      await registerAttempt('tight-b@example.com');
      final blocked = await registerAttempt('tight-c@example.com');
      expect(blocked.statusCode, 429);
    });
  });

  // ── Validation de format ─────────────────────────────────────────────────────

  group('validateDisplayName — caractères de contrôle', () {
    test('rejette les caractères de contrôle', () {
      expect(
        () => validateDisplayName('abc\x00def', required: true),
        throwsA(isA<ApiException>()),
      );
    });

    test('accepte les noms accentués (pas de restriction de charset)', () {
      expect(validateDisplayName('Léa', required: true), 'Léa');
      expect(validateDisplayName('François', required: true), 'François');
    });
  });

  // ── Migration de dédoublonnage (base pré-existante) ───────────────────────────

  group('Migration display_name_normalized (base pré-existante)', () {
    late String dbPath;

    setUp(() {
      dbPath = '${Directory.systemTemp.path}/'
          'gymtrack_dedup_test_${DateTime.now().microsecondsSinceEpoch}.db';
    });

    tearDown(() {
      final file = File(dbPath);
      if (file.existsSync()) file.deleteSync();
    });

    void seedPreMigrationUsers(List<(String, String, String, String)> users) {
      final raw = sqlite3.sqlite3.open(dbPath);
      raw.execute('''
        CREATE TABLE users (
          id TEXT PRIMARY KEY,
          email TEXT NOT NULL UNIQUE,
          display_name TEXT NOT NULL,
          photo_url TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          last_login_at TEXT,
          is_deleted INTEGER NOT NULL DEFAULT 0
        );
      ''');
      for (final (id, email, displayName, createdAt) in users) {
        raw.execute(
          'INSERT INTO users (id, email, display_name, created_at, updated_at, is_deleted) '
          'VALUES (?, ?, ?, ?, ?, 0)',
          [id, email, displayName, createdAt, createdAt],
        );
      }
      raw.dispose();
    }

    test('suffixe les doublons existants, le plus ancien garde son nom', () {
      seedPreMigrationUsers([
        ('u1', 'a@x.com', 'Leo', '2026-01-01T00:00:00.000Z'),
        ('u2', 'b@x.com', 'leo', '2026-01-02T00:00:00.000Z'),
        ('u3', 'c@x.com', 'LEO', '2026-01-03T00:00:00.000Z'),
      ]);

      final appDb = AppDatabase.open(dbPath);
      addTearDown(appDb.close);
      final rows =
          appDb.raw.select('SELECT id, display_name FROM users ORDER BY created_at ASC;');
      expect(rows[0]['display_name'], 'Leo');
      expect(rows[1]['display_name'], 'leo2');
      // Le suffixe préserve la casse propre à chaque compte ("LEO" tapé par
      // u3), il ne réutilise pas celle du premier arrivé ("Leo") — seule
      // l'unicité (insensible à la casse) est garantie, pas une casse commune.
      expect(rows[2]['display_name'], 'LEO3');
    });

    test('idempotent : ré-ouvrir la base ne rejoue pas le dédoublonnage', () {
      seedPreMigrationUsers([
        ('u1', 'a@x.com', 'Mila', '2026-01-01T00:00:00.000Z'),
        ('u2', 'b@x.com', 'mila', '2026-01-02T00:00:00.000Z'),
      ]);

      AppDatabase.open(dbPath).close();

      final appDb2 = AppDatabase.open(dbPath);
      addTearDown(appDb2.close);
      final rows =
          appDb2.raw.select('SELECT id, display_name FROM users ORDER BY created_at ASC;');
      expect(rows[0]['display_name'], 'Mila');
      expect(rows[1]['display_name'], 'mila2');
    });
  });

  // ── Réconciliation users vs user_profiles (base pré-existante) ───────────────

  group('Réconciliation users.display_name / user_profiles.display_name', () {
    late String dbPath;

    setUp(() {
      dbPath = '${Directory.systemTemp.path}/'
          'gymtrack_reconcile_test_${DateTime.now().microsecondsSinceEpoch}.db';
    });

    tearDown(() {
      final file = File(dbPath);
      if (file.existsSync()) file.deleteSync();
    });

    void seedMismatchedUsers(
      List<(String, String, String, String, String)> users, // id, email, usersName, profileName, createdAt
    ) {
      final raw = sqlite3.sqlite3.open(dbPath);
      raw.execute('''
        CREATE TABLE users (
          id TEXT PRIMARY KEY,
          email TEXT NOT NULL UNIQUE,
          display_name TEXT NOT NULL,
          photo_url TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          last_login_at TEXT,
          is_deleted INTEGER NOT NULL DEFAULT 0
        );
      ''');
      raw.execute('''
        CREATE TABLE user_profiles (
          user_id TEXT PRIMARY KEY,
          display_name TEXT NOT NULL,
          weight_kg REAL,
          height_cm REAL,
          sex TEXT NOT NULL DEFAULT 'unspecified',
          onboarding_completed INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''');
      for (final (id, email, usersName, profileName, createdAt) in users) {
        raw.execute(
          'INSERT INTO users (id, email, display_name, created_at, updated_at, is_deleted) '
          'VALUES (?, ?, ?, ?, ?, 0)',
          [id, email, usersName, createdAt, createdAt],
        );
        raw.execute(
          'INSERT INTO user_profiles (user_id, display_name, created_at, updated_at) '
          'VALUES (?, ?, ?, ?)',
          [id, profileName, createdAt, createdAt],
        );
      }
      raw.dispose();
    }

    test(
        'aligne users.display_name sur user_profiles.display_name quand ils divergent '
        '(régression : la recherche par pseudo ne trouvait jamais le nom réellement affiché '
        'à l\'utilisateur dans "Mon compte")', () {
      seedMismatchedUsers([
        ('u1', 'a@x.com', 'Antonin Pangrani', 'Rhumcha', '2026-01-01T00:00:00.000Z'),
      ]);

      final appDb = AppDatabase.open(dbPath);
      addTearDown(appDb.close);

      final userRow = appDb.raw
          .select('SELECT display_name, display_name_normalized FROM users WHERE id=?', ['u1'])
          .first;
      expect(userRow['display_name'], 'Rhumcha');
      expect(userRow['display_name_normalized'], 'rhumcha');
    });

    test('ne touche pas les comptes déjà cohérents', () {
      seedMismatchedUsers([
        ('u1', 'a@x.com', 'Vinke', 'Vinke', '2026-01-01T00:00:00.000Z'),
      ]);

      final appDb = AppDatabase.open(dbPath);
      addTearDown(appDb.close);

      final userRow =
          appDb.raw.select('SELECT display_name FROM users WHERE id=?', ['u1']).first;
      expect(userRow['display_name'], 'Vinke');
    });

    test('résout la collision si le nom réconcilié est déjà pris par un autre compte', () {
      seedMismatchedUsers([
        ('u1', 'a@x.com', 'Alex', 'Alex', '2026-01-01T00:00:00.000Z'),
        ('u2', 'b@x.com', 'Robin Ancien', 'Alex', '2026-01-02T00:00:00.000Z'),
      ]);

      final appDb = AppDatabase.open(dbPath);
      addTearDown(appDb.close);

      final rows =
          appDb.raw.select('SELECT id, display_name FROM users ORDER BY created_at ASC;');
      expect(rows[0]['display_name'], 'Alex');
      // u2 voulait aussi devenir "Alex" (sa valeur user_profiles) mais u1 l'a
      // déjà — suffixage plutôt que violation de l'index unique.
      expect(rows[1]['display_name'], 'Alex2');
    });

    test('idempotent : ré-ouvrir la base ne rejoue pas la réconciliation', () {
      seedMismatchedUsers([
        ('u1', 'a@x.com', 'Ancien Nom', 'Nouveau Nom', '2026-01-01T00:00:00.000Z'),
      ]);

      AppDatabase.open(dbPath).close();

      final appDb2 = AppDatabase.open(dbPath);
      addTearDown(appDb2.close);
      final userRow =
          appDb2.raw.select('SELECT display_name FROM users WHERE id=?', ['u1']).first;
      expect(userRow['display_name'], 'Nouveau Nom');
    });
  });
}
