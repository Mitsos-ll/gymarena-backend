import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../utils/token_hash.dart';

class AppDatabase {
  AppDatabase._(this._db);

  final sqlite3.Database _db;

  static AppDatabase open(String databasePath) {
    final sqlite3.Database db;
    if (databasePath == ':memory:') {
      db = sqlite3.sqlite3.openInMemory();
    } else {
      final file = File(databasePath);
      file.parent.createSync(recursive: true);
      db = sqlite3.sqlite3.open(file.path);
    }
    db.execute('PRAGMA foreign_keys = ON;');

    final instance = AppDatabase._(db);
    instance._createSchema();
    instance._migrateUserAuthAccountsIfNeeded();
    instance._migrateAuthSessionsToHashedTokensIfNeeded();
    instance._migrateRelationsIfNeeded();
    instance._migrateCoachInviteRequestsIfNeeded();
    instance._migrateCoachProgramAssignmentsIfNeeded();
    instance._backfillRevokedCoachProgramAssignments();
    return instance;
  }

  sqlite3.Database get raw => _db;

  void _createSchema() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS users (
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

    _db.execute('''
      CREATE TABLE IF NOT EXISTS user_auth_accounts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        provider_subject TEXT,
        email TEXT,
        email_verified INTEGER,
        password_hash TEXT,
        password_salt TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
        UNIQUE(provider, provider_subject),
        UNIQUE(user_id, provider)
      );
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS user_profiles (
        user_id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        weight_kg REAL,
        height_cm REAL,
        sex TEXT,
        onboarding_completed INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    ''');

    // access_token_hash/refresh_token_hash : jamais le token en clair — une
    // fuite de la base (backup, volume compromis) ne doit pas permettre de
    // rejouer directement une session active. Le client garde le seul
    // exemplaire en clair (secure storage) ; le serveur ne connaît/ne
    // compare que le hash.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS auth_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT NOT NULL,
        access_token_hash TEXT NOT NULL UNIQUE,
        refresh_token_hash TEXT NOT NULL UNIQUE,
        device_name TEXT,
        access_expires_at TEXT NOT NULL,
        refresh_expires_at TEXT NOT NULL,
        revoked_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    ''');

    _db.execute('CREATE INDEX IF NOT EXISTS idx_user_auth_accounts_subject ON user_auth_accounts(provider, provider_subject);');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_auth_sessions_user_id ON auth_sessions(user_id);');
    // Sur une base existante (pré-hash), `CREATE TABLE IF NOT EXISTS`
    // ci-dessus est un no-op puisque auth_sessions existe déjà avec l'ancien
    // schéma (access_token/refresh_token) — access_token_hash n'existe pas
    // encore à ce stade, la migration qui l'ajoute ne tourne qu'après
    // _createSchema(). Sans ce garde, ces deux index crashaient le
    // démarrage en boucle sur toute base déjà peuplée.
    if (_columnExists('auth_sessions', 'access_token_hash')) {
      _db.execute('CREATE INDEX IF NOT EXISTS idx_auth_sessions_access_token_hash ON auth_sessions(access_token_hash);');
      _db.execute('CREATE INDEX IF NOT EXISTS idx_auth_sessions_refresh_token_hash ON auth_sessions(refresh_token_hash);');
    }

    // ── is_coach sur user_profiles ──────────────────────────────────────────
    _addColumnIfMissing('user_profiles', 'is_coach', 'INTEGER NOT NULL DEFAULT 0');
    _addColumnIfMissing('user_profiles', 'fitness_goal', 'TEXT');

    // ── Coach ───────────────────────────────────────────────────────────────
    _db.execute('''
      CREATE TABLE IF NOT EXISTS coach_invite_codes (
        code TEXT PRIMARY KEY,
        coach_user_id TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        used_by_user_id TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (coach_user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS coach_athlete_links (
        id TEXT PRIMARY KEY,
        coach_user_id TEXT NOT NULL,
        athlete_user_id TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'active',
        linked_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (coach_user_id) REFERENCES users(id) ON DELETE CASCADE,
        FOREIGN KEY (athlete_user_id) REFERENCES users(id) ON DELETE CASCADE,
        UNIQUE(coach_user_id, athlete_user_id)
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_cal_coach ON coach_athlete_links(coach_user_id);');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_cal_athlete ON coach_athlete_links(athlete_user_id);');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS coach_workout_notes (
        id TEXT PRIMARY KEY,
        coach_user_id TEXT NOT NULL,
        athlete_user_id TEXT NOT NULL,
        workout_id TEXT NOT NULL,
        note_text TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(coach_user_id, workout_id)
      );
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS coach_program_assignments (
        id TEXT PRIMARY KEY,
        coach_user_id TEXT NOT NULL,
        athlete_user_id TEXT NOT NULL,
        program_type TEXT NOT NULL,
        program_code TEXT,
        program_name TEXT NOT NULL,
        snapshot_json TEXT,
        assigned_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'active',
        FOREIGN KEY (coach_user_id) REFERENCES users(id) ON DELETE CASCADE,
        FOREIGN KEY (athlete_user_id) REFERENCES users(id) ON DELETE CASCADE,
        UNIQUE(coach_user_id, athlete_user_id)
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_cpa_athlete ON coach_program_assignments(athlete_user_id);');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS coach_public_profiles (
        coach_user_id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        bio TEXT,
        speciality TEXT,
        location TEXT,
        languages TEXT NOT NULL DEFAULT '[]',
        is_public INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (coach_user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_cpp_public ON coach_public_profiles(is_public);');
    _addColumnIfMissing('coach_public_profiles', 'photo_url', 'TEXT');
    _addColumnIfMissing('coach_public_profiles', 'whatsapp', 'TEXT');
    _addColumnIfMissing('coach_public_profiles', 'instagram', 'TEXT');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS coach_invite_requests (
        id TEXT PRIMARY KEY,
        coach_user_id TEXT NOT NULL,
        athlete_user_id TEXT NOT NULL,
        athlete_display_name TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (coach_user_id) REFERENCES users(id) ON DELETE CASCADE,
        FOREIGN KEY (athlete_user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_cir_coach ON coach_invite_requests(coach_user_id, status);');
    // Un seul index UNIQUE partiel (pending uniquement) : une paire coach/
    // athlète peut avoir plusieurs lignes historiques (declined/approved),
    // contrairement à une UNIQUE(coach_user_id, athlete_user_id, status)
    // qui provoque une violation de contrainte dès qu'un 2e refus/acceptation
    // survient pour la même paire.
    _db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_cir_unique_pending
      ON coach_invite_requests(coach_user_id, athlete_user_id)
      WHERE status='pending';
    ''');

    // ── Invitations d'amis (lien / QR) ──────────────────────────────────────
    // Contrairement au code coach (usage unique), un code d'invitation ami
    // est réutilisable par plusieurs destinataires jusqu'à expiration.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS friend_invite_codes (
        code TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_fic_user ON friend_invite_codes(user_id);');

    // ── Réinitialisation de mot de passe ────────────────────────────────────
    _db.execute('''
      CREATE TABLE IF NOT EXISTS password_reset_codes (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        code TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        used_at TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_prc_user ON password_reset_codes(user_id);');

    // ── Sync — Workouts ─────────────────────────────────────────────────────
    _db.execute('''
      CREATE TABLE IF NOT EXISTS workouts (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        local_id INTEGER,
        workout_date TEXT NOT NULL,
        start_time TEXT,
        end_time TEXT,
        duration_seconds INTEGER NOT NULL DEFAULT 0,
        bodyweight_kg_snapshot REAL,
        notes TEXT,
        source_app TEXT,
        source_record_id TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_workouts_user ON workouts(user_id);');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_workouts_date ON workouts(user_id, workout_date);');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS workout_exercises (
        id TEXT PRIMARY KEY,
        workout_id TEXT NOT NULL,
        exercise_id TEXT,
        exercise_name_snapshot TEXT,
        muscle_group_name_snapshot TEXT,
        exercise_order INTEGER NOT NULL,
        notes TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (workout_id) REFERENCES workouts(id) ON DELETE CASCADE
      );
    ''');
    _addColumnIfMissing('workout_exercises', 'muscle_group_name_snapshot', 'TEXT');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS workout_sets (
        id TEXT PRIMARY KEY,
        workout_exercise_id TEXT NOT NULL,
        set_number INTEGER NOT NULL,
        weight_kg REAL NOT NULL DEFAULT 0,
        reps INTEGER NOT NULL DEFAULT 0,
        rpe REAL,
        rest_time_seconds INTEGER,
        estimated_1rm REAL,
        is_secondary INTEGER NOT NULL DEFAULT 0,
        set_type TEXT NOT NULL DEFAULT 'normal',
        distance_m REAL,
        effort_seconds INTEGER,
        pace_sec_per_km REAL,
        calories REAL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (workout_exercise_id) REFERENCES workout_exercises(id) ON DELETE CASCADE
      );
    ''');
    // Volume réel de la série (gauche+droite pour un exercice unilatéral) —
    // distinct de `reps` qui reste le max des deux côtés (affichage, 1RM).
    _addColumnIfMissing('workout_sets', 'volume_reps', 'INTEGER');
    // Poids du corps / charge additionnelle (exercices bodyweight) — sans ça
    // ces séries revenaient vides après un push/pull (reinstall, nouveau
    // device) car jamais persistées côté serveur.
    _addColumnIfMissing('workout_sets', 'bodyweight_kg', 'REAL');
    _addColumnIfMissing('workout_sets', 'added_weight_kg', 'REAL');

    // Détail gauche/droite pour les exercices unilatéraux — même besoin que
    // ci-dessus, cette table n'existait pas du tout côté serveur.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS workout_set_sides (
        id TEXT PRIMARY KEY,
        workout_set_id TEXT NOT NULL,
        side TEXT NOT NULL,
        reps INTEGER NOT NULL,
        rpe REAL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (workout_set_id) REFERENCES workout_sets(id) ON DELETE CASCADE
      );
    ''');

    // ── Sync — Exercices custom ─────────────────────────────────────────────
    _db.execute('''
      CREATE TABLE IF NOT EXISTS exercises (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        local_id INTEGER,
        name TEXT NOT NULL,
        muscle_group_name TEXT,
        exercise_type TEXT NOT NULL DEFAULT 'strength',
        is_unilateral INTEGER NOT NULL DEFAULT 0,
        equipment TEXT,
        description TEXT,
        performance_type TEXT NOT NULL DEFAULT 'strength',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_exercises_user ON exercises(user_id);');

    // ── Sync — Programmes custom ────────────────────────────────────────────
    _db.execute('''
      CREATE TABLE IF NOT EXISTS programs (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        local_id INTEGER,
        name TEXT NOT NULL,
        description TEXT,
        days_per_week INTEGER,
        deload_every_n_weeks INTEGER,
        progression_step_kg REAL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_programs_user ON programs(user_id);');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS program_sessions (
        id TEXT PRIMARY KEY,
        program_id TEXT NOT NULL,
        name TEXT NOT NULL,
        session_order INTEGER NOT NULL,
        day_of_week INTEGER,
        created_at TEXT NOT NULL,
        FOREIGN KEY (program_id) REFERENCES programs(id) ON DELETE CASCADE
      );
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS program_exercises (
        id TEXT PRIMARY KEY,
        program_session_id TEXT NOT NULL,
        exercise_id TEXT,
        exercise_name_snapshot TEXT,
        exercise_order INTEGER NOT NULL,
        target_sets INTEGER,
        target_reps_min INTEGER,
        target_reps_max INTEGER,
        target_rpe REAL,
        progression_step_kg REAL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (program_session_id) REFERENCES program_sessions(id) ON DELETE CASCADE
      );
    ''');

    // ── Sync — Modèles de séance ─────────────────────────────────────────────
    _db.execute('''
      CREATE TABLE IF NOT EXISTS session_templates (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        local_id INTEGER,
        name TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_session_templates_user ON session_templates(user_id);');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS session_template_exercises (
        id TEXT PRIMARY KEY,
        session_template_id TEXT NOT NULL,
        exercise_id TEXT,
        exercise_name_snapshot TEXT,
        display_order INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        FOREIGN KEY (session_template_id) REFERENCES session_templates(id) ON DELETE CASCADE
      );
    ''');

    // ── Sync — Poids & mesures ──────────────────────────────────────────────
    _db.execute('''
      CREATE TABLE IF NOT EXISTS weight_history (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        local_id INTEGER,
        weight_kg REAL NOT NULL,
        effective_date TEXT NOT NULL,
        notes TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_weight_user ON weight_history(user_id);');
    _addColumnIfMissing('weight_history', 'local_id', 'INTEGER');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS body_measurements (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        local_id INTEGER,
        measurement_type TEXT NOT NULL,
        value_cm REAL NOT NULL,
        measured_date TEXT NOT NULL,
        notes TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_measurements_user ON body_measurements(user_id);');
    _addColumnIfMissing('body_measurements', 'local_id', 'INTEGER');

    // ── Sync — Gamification ─────────────────────────────────────────────────
    _db.execute('''
      CREATE TABLE IF NOT EXISTS gamification_profiles (
        user_id TEXT PRIMARY KEY,
        total_xp INTEGER NOT NULL DEFAULT 0,
        total_workouts INTEGER NOT NULL DEFAULT 0,
        total_volume_kg REAL NOT NULL DEFAULT 0,
        total_sets INTEGER NOT NULL DEFAULT 0,
        current_streak INTEGER NOT NULL DEFAULT 0,
        longest_streak INTEGER NOT NULL DEFAULT 0,
        total_prs_ever INTEGER NOT NULL DEFAULT 0,
        last_workout_date TEXT,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS achievements (
        id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        unlocked_at TEXT NOT NULL,
        PRIMARY KEY (user_id, id),
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS goals (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        type TEXT NOT NULL,
        title TEXT NOT NULL,
        target REAL NOT NULL,
        current_value REAL NOT NULL DEFAULT 0,
        start_date TEXT NOT NULL,
        due_date TEXT,
        status TEXT NOT NULL DEFAULT 'active',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_goals_user ON goals(user_id);');

    // ── Communauté ──────────────────────────────────────────────────────────
    _db.execute('''
      CREATE TABLE IF NOT EXISTS community_profiles (
        user_id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        avatar_preset_id TEXT NOT NULL DEFAULT 'warrior',
        level INTEGER NOT NULL DEFAULT 1,
        tier TEXT NOT NULL DEFAULT 'Rookie',
        total_xp INTEGER NOT NULL DEFAULT 0,
        current_streak INTEGER NOT NULL DEFAULT 0,
        total_workouts INTEGER NOT NULL DEFAULT 0,
        total_volume_kg REAL NOT NULL DEFAULT 0,
        privacy_json TEXT NOT NULL DEFAULT '{}',
        updated_at TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    ''');
    _addColumnIfMissing('community_profiles', 'total_prs', 'INTEGER NOT NULL DEFAULT 0');
    _addColumnIfMissing('community_profiles', 'badge_ids', "TEXT NOT NULL DEFAULT '[]'");

    _db.execute('''
      CREATE TABLE IF NOT EXISTS social_relations (
        id TEXT PRIMARY KEY,
        user_id_a TEXT NOT NULL,
        user_id_b TEXT NOT NULL,
        status TEXT NOT NULL,
        request_status TEXT NOT NULL DEFAULT 'pending',
        notes TEXT,
        is_public INTEGER NOT NULL DEFAULT 0,
        last_interaction_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (user_id_a) REFERENCES users(id) ON DELETE CASCADE,
        FOREIGN KEY (user_id_b) REFERENCES users(id) ON DELETE CASCADE,
        UNIQUE(user_id_a, user_id_b)
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_relations_a ON social_relations(user_id_a);');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_relations_b ON social_relations(user_id_b);');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS workout_shares (
        id TEXT PRIMARY KEY,
        owner_user_id TEXT NOT NULL,
        workout_id TEXT,
        title TEXT NOT NULL,
        snapshot_json TEXT NOT NULL,
        visibility TEXT NOT NULL DEFAULT 'friendsOnly',
        created_at TEXT NOT NULL,
        FOREIGN KEY (owner_user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_wshares_owner ON workout_shares(owner_user_id);');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS program_shares (
        id TEXT PRIMARY KEY,
        owner_user_id TEXT NOT NULL,
        program_id TEXT,
        title TEXT NOT NULL,
        snapshot_json TEXT NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (owner_user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_pshares_owner ON program_shares(owner_user_id);');

    // ── Catalogue d'exercices par défaut (GIFs WorkoutX) ────────────────────
    // Table globale en lecture seule, distincte de `exercises` (custom par
    // utilisateur, avec sync) — un seul jeu de données partagé par tous.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS exercise_catalog (
        slug TEXT PRIMARY KEY,
        workoutx_id TEXT NOT NULL,
        name TEXT NOT NULL,
        target_muscles TEXT NOT NULL DEFAULT '[]',
        secondary_muscles TEXT NOT NULL DEFAULT '[]',
        equipment TEXT,
        difficulty TEXT,
        instructions TEXT NOT NULL DEFAULT '[]',
        gif_path TEXT,
        cached_at TEXT,
        active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_exercise_catalog_workoutx_id ON exercise_catalog(workoutx_id);');
  }

  void _addColumnIfMissing(String table, String column, String definition) {
    if (_columnExists(table, column)) return;
    _db.execute('ALTER TABLE $table ADD COLUMN $column $definition;');
  }

  bool _columnExists(String table, String column) {
    final cols = _db.select('PRAGMA table_info($table);');
    return cols.any((r) => r['name'] == column);
  }

  void _migrateCoachProgramAssignmentsIfNeeded() {
    final columns = _db.select('PRAGMA table_info(coach_program_assignments);');
    if (columns.isEmpty) return;
    final hasNewSchema = columns.any((r) => r['name'] == 'program_type');
    if (hasNewSchema) return;

    // Ancienne colonne program_id (référence à programs.id) jamais réellement
    // utilisée en production (fonctionnalité inaccessible depuis l'UI) —
    // aucune donnée à préserver, on recrée la table avec le nouveau schéma
    // (program_type/program_code/program_name/snapshot_json).
    _db.execute('BEGIN TRANSACTION;');
    try {
      _db.execute('DROP TABLE coach_program_assignments;');
      _db.execute('''
        CREATE TABLE coach_program_assignments (
          id TEXT PRIMARY KEY,
          coach_user_id TEXT NOT NULL,
          athlete_user_id TEXT NOT NULL,
          program_type TEXT NOT NULL,
          program_code TEXT,
          program_name TEXT NOT NULL,
          snapshot_json TEXT,
          assigned_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'active',
          FOREIGN KEY (coach_user_id) REFERENCES users(id) ON DELETE CASCADE,
          FOREIGN KEY (athlete_user_id) REFERENCES users(id) ON DELETE CASCADE,
          UNIQUE(coach_user_id, athlete_user_id)
        );
      ''');
      _db.execute('CREATE INDEX IF NOT EXISTS idx_cpa_athlete ON coach_program_assignments(athlete_user_id);');
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  /// Backfill ponctuel (idempotent, sans coût si rien à corriger) : avant le
  /// fix de revokeCoach(), révoquer un coach ne nettoyait jamais son
  /// assignation de programme — elle restait 'active' et se réappliquait
  /// indéfiniment côté athlète à chaque restauration (réinstall). Nettoie
  /// tous les cas déjà orphelins en base, pas seulement les futurs.
  void _backfillRevokedCoachProgramAssignments() {
    final columns = _db.select('PRAGMA table_info(coach_program_assignments);');
    if (columns.isEmpty) return;
    _db.execute('''
      UPDATE coach_program_assignments
      SET status = 'removed'
      WHERE status = 'active'
        AND EXISTS (
          SELECT 1 FROM coach_athlete_links l
          WHERE l.coach_user_id = coach_program_assignments.coach_user_id
            AND l.athlete_user_id = coach_program_assignments.athlete_user_id
            AND l.status = 'revoked'
        );
    ''');
  }

  void _migrateCoachInviteRequestsIfNeeded() {
    final indexes = _db.select("PRAGMA index_list(coach_invite_requests);");
    // La table a été créée avec un UNIQUE(coach_user_id, athlete_user_id,
    // status) qui provoque une violation de contrainte dès qu'une 2e demande
    // refusée/acceptée existe pour la même paire coach/athlète. Cet index
    // "sqlite_autoindex" disparaît une fois la table recréée sans cette
    // contrainte — sa présence signale qu'une migration est nécessaire.
    final hasOldConstraint = indexes.any((r) => (r['origin'] as String?) == 'u');
    if (!hasOldConstraint) return;

    _db.execute('BEGIN TRANSACTION;');
    try {
      _db.execute('ALTER TABLE coach_invite_requests RENAME TO coach_invite_requests_old;');
      _db.execute('''
        CREATE TABLE coach_invite_requests (
          id TEXT PRIMARY KEY,
          coach_user_id TEXT NOT NULL,
          athlete_user_id TEXT NOT NULL,
          athlete_display_name TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          FOREIGN KEY (coach_user_id) REFERENCES users(id) ON DELETE CASCADE,
          FOREIGN KEY (athlete_user_id) REFERENCES users(id) ON DELETE CASCADE
        );
      ''');
      _db.execute('''
        INSERT INTO coach_invite_requests
          (id, coach_user_id, athlete_user_id, athlete_display_name, status, created_at, updated_at)
        SELECT id, coach_user_id, athlete_user_id, athlete_display_name, status, created_at, updated_at
        FROM coach_invite_requests_old;
      ''');
      _db.execute('DROP TABLE coach_invite_requests_old;');
      _db.execute('CREATE INDEX IF NOT EXISTS idx_cir_coach ON coach_invite_requests(coach_user_id, status);');
      _db.execute('''
        CREATE UNIQUE INDEX IF NOT EXISTS idx_cir_unique_pending
        ON coach_invite_requests(coach_user_id, athlete_user_id)
        WHERE status='pending';
      ''');
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  /// Migre `auth_sessions` du stockage en clair (`access_token`/
  /// `refresh_token`) vers un stockage par hash uniquement
  /// (`access_token_hash`/`refresh_token_hash`). Transparent pour les
  /// utilisateurs déjà connectés : on hashe la valeur en clair déjà en base
  /// (le client garde toujours le token en clair côté secure storage), donc
  /// une session existante reste valide après migration — pas de
  /// déconnexion forcée.
  void _migrateAuthSessionsToHashedTokensIfNeeded() {
    final columns = _db.select('PRAGMA table_info(auth_sessions);');
    if (columns.isEmpty) return;
    final alreadyMigrated = columns.any((r) => r['name'] == 'access_token_hash');
    if (alreadyMigrated) return;

    _db.execute('BEGIN TRANSACTION;');
    try {
      final rows = _db.select('SELECT * FROM auth_sessions;');

      _db.execute('ALTER TABLE auth_sessions RENAME TO auth_sessions_old;');
      _db.execute('''
        CREATE TABLE auth_sessions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          user_id TEXT NOT NULL,
          access_token_hash TEXT NOT NULL UNIQUE,
          refresh_token_hash TEXT NOT NULL UNIQUE,
          device_name TEXT,
          access_expires_at TEXT NOT NULL,
          refresh_expires_at TEXT NOT NULL,
          revoked_at TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
        );
      ''');

      for (final row in rows) {
        _db.execute(
          'INSERT INTO auth_sessions '
          '(id, user_id, access_token_hash, refresh_token_hash, device_name, access_expires_at, refresh_expires_at, revoked_at, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [
            row['id'],
            row['user_id'],
            hashToken(row['access_token'] as String),
            hashToken(row['refresh_token'] as String),
            row['device_name'],
            row['access_expires_at'],
            row['refresh_expires_at'],
            row['revoked_at'],
            row['created_at'],
            row['updated_at'],
          ],
        );
      }

      _db.execute('DROP TABLE auth_sessions_old;');
      _db.execute('CREATE INDEX IF NOT EXISTS idx_auth_sessions_user_id ON auth_sessions(user_id);');
      _db.execute('CREATE INDEX IF NOT EXISTS idx_auth_sessions_access_token_hash ON auth_sessions(access_token_hash);');
      _db.execute('CREATE INDEX IF NOT EXISTS idx_auth_sessions_refresh_token_hash ON auth_sessions(refresh_token_hash);');
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _migrateRelationsIfNeeded() {
    _addColumnIfMissing('social_relations', 'request_status', "TEXT NOT NULL DEFAULT 'pending'");
    _addColumnIfMissing('social_relations', 'notes', 'TEXT');
    _addColumnIfMissing('social_relations', 'is_public', 'INTEGER NOT NULL DEFAULT 0');
    _addColumnIfMissing('social_relations', 'last_interaction_at', 'TEXT');
  }

  void _migrateUserAuthAccountsIfNeeded() {
    final columns = _db.select('PRAGMA table_info(user_auth_accounts);');
    if (columns.isEmpty) return;

    bool hasColumn(String name) => columns.any((row) => row['name'] == name);
    final providerSubjectRow = columns.where((row) => row['name'] == 'provider_subject').toList();
    final providerSubjectNotNull = providerSubjectRow.isNotEmpty &&
        ((providerSubjectRow.first['notnull'] as int?) ?? 0) == 1;

    final needsMigration =
        !hasColumn('password_hash') || !hasColumn('password_salt') || providerSubjectNotNull;
    if (!needsMigration) return;

    _db.execute('BEGIN TRANSACTION;');
    try {
      _db.execute('ALTER TABLE user_auth_accounts RENAME TO user_auth_accounts_old;');
      _db.execute('''
        CREATE TABLE user_auth_accounts (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          user_id TEXT NOT NULL,
          provider TEXT NOT NULL,
          provider_subject TEXT,
          email TEXT,
          email_verified INTEGER,
          password_hash TEXT,
          password_salt TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
          UNIQUE(provider, provider_subject),
          UNIQUE(user_id, provider)
        );
      ''');
      _db.execute('''
        INSERT INTO user_auth_accounts (
          id, user_id, provider, provider_subject, email, email_verified,
          password_hash, password_salt, created_at, updated_at
        )
        SELECT
          id, user_id, provider, provider_subject, email, email_verified,
          NULL, NULL, created_at, updated_at
        FROM user_auth_accounts_old;
      ''');
      _db.execute('DROP TABLE user_auth_accounts_old;');
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void close() {
    _db.dispose();
  }
}

String dbNow() => DateTime.now().toUtc().toIso8601String();
