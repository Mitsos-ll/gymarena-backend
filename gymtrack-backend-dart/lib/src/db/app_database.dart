import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite3;

class AppDatabase {
  AppDatabase._(this._db);

  final sqlite3.Database _db;

  static AppDatabase open(String databasePath) {
    final file = File(databasePath);
    file.parent.createSync(recursive: true);

    final db = sqlite3.sqlite3.open(file.path);
    db.execute('PRAGMA foreign_keys = ON;');

    final instance = AppDatabase._(db);
    instance._createSchema();
    instance._migrateUserAuthAccountsIfNeeded();
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
