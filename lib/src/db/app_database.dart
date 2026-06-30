import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite3;

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
    instance._migrateRelationsIfNeeded();
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

    _db.execute('''
      CREATE TABLE IF NOT EXISTS auth_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT NOT NULL,
        access_token TEXT NOT NULL UNIQUE,
        refresh_token TEXT NOT NULL UNIQUE,
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
    _db.execute('CREATE INDEX IF NOT EXISTS idx_auth_sessions_access_token ON auth_sessions(access_token);');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_auth_sessions_refresh_token ON auth_sessions(refresh_token);');

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
        program_id TEXT NOT NULL,
        assigned_at TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'active',
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
        exercise_order INTEGER NOT NULL,
        notes TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (workout_id) REFERENCES workouts(id) ON DELETE CASCADE
      );
    ''');

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
  }

  void _addColumnIfMissing(String table, String column, String definition) {
    final cols = _db.select('PRAGMA table_info($table);');
    final exists = cols.any((r) => r['name'] == column);
    if (!exists) {
      _db.execute('ALTER TABLE $table ADD COLUMN $column $definition;');
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
