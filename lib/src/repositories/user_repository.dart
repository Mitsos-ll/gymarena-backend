import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../models/api_profile.dart';
import '../models/api_session.dart';
import '../models/api_user.dart';
import '../services/google_token_service.dart';
import '../services/session_service.dart';
import '../utils/api_exception.dart';
import '../utils/password_hash.dart';

class UserRepository {
  UserRepository({
    required AppDatabase database,
    required SessionService sessionService,
  })  : _database = database,
        _sessionService = sessionService;

  final AppDatabase _database;
  final SessionService _sessionService;
  final _uuid = const Uuid();

  // ── Google OAuth ────────────────────────────────────────────────────────────

  ApiSession signInWithGoogle(GoogleTokenPayload google) {
    final now = dbNow();
    final existingUserId = _findUserIdByGoogleSubject(google.subject);
    if (existingUserId == null) {
      return _createNewUserSession(google, now);
    }
    return _reuseExistingUserSession(existingUserId, google, now);
  }

  // ── Registration / Login ────────────────────────────────────────────────────

  ApiSession registerWithGymTrack({
    required String email,
    required String password,
    String? displayName,
  }) {
    final normalizedEmail = email.trim().toLowerCase();
    final now = dbNow();

    if (_getUserByEmail(normalizedEmail) != null) {
      throw ApiException('Email already used.', statusCode: 409);
    }

    final userId = _uuid.v4();
    final passwordHash = hashPassword(password); // BCrypt
    final finalDisplayName = _normalizeDisplayName(displayName, normalizedEmail);
    final tokens = _sessionService.issueTokens();

    _database.raw.execute(
      'INSERT INTO users (id, email, display_name, photo_url, created_at, updated_at, last_login_at, is_deleted) '
      'VALUES (?, ?, ?, NULL, ?, ?, ?, 0)',
      [userId, normalizedEmail, finalDisplayName, now, now, now],
    );

    _database.raw.execute(
      'INSERT INTO user_auth_accounts '
      '(user_id, provider, provider_subject, email, email_verified, password_hash, password_salt, created_at, updated_at) '
      "VALUES (?, 'gymtrack', NULL, ?, NULL, ?, NULL, ?, ?)",
      [userId, normalizedEmail, passwordHash, now, now],
    );

    _database.raw.execute(
      'INSERT INTO user_profiles (user_id, display_name, weight_kg, height_cm, sex, onboarding_completed, created_at, updated_at) '
      'VALUES (?, ?, NULL, NULL, ?, 0, ?, ?)',
      [userId, finalDisplayName, UserSex.unspecified.name, now, now],
    );

    _insertSession(userId: userId, tokens: tokens, now: now);
    return _buildSession(userId, tokens.accessToken, tokens.refreshToken);
  }

  ApiSession signInWithGymTrack({
    required String email,
    required String password,
  }) {
    final normalizedEmail = email.trim().toLowerCase();
    final now = dbNow();

    final account = _findGymTrackAuthAccountByEmail(normalizedEmail);
    if (account == null) {
      throw ApiException('Invalid credentials.', statusCode: 401);
    }

    final storedHash = account['password_hash'] as String?;
    final storedSalt = account['password_salt'] as String?;
    if (storedHash == null) {
      throw ApiException('Invalid credentials.', statusCode: 401);
    }

    final (isValid, needsMigration) = verifyPassword(password, storedHash, storedSalt);
    if (!isValid) {
      throw ApiException('Invalid credentials.', statusCode: 401);
    }

    final userId = account['user_id'] as String;

    // Migration lazy SHA-256 → BCrypt
    if (needsMigration) {
      final newHash = hashPassword(password);
      _database.raw.execute(
        "UPDATE user_auth_accounts SET password_hash = ?, password_salt = NULL WHERE user_id = ? AND provider = 'gymtrack'",
        [newHash, userId],
      );
    }

    _database.raw.execute(
      'UPDATE users SET last_login_at = ?, updated_at = ?, is_deleted = 0 WHERE id = ?',
      [now, now, userId],
    );

    final user = _getUserById(userId);
    if (user == null) throw ApiException('User not found.', statusCode: 404);

    final profile = _findProfileByUserId(userId);
    final tokens = _sessionService.issueTokens();
    _insertSession(userId: userId, tokens: tokens, now: now);

    return ApiSession(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      user: user,
      profile: profile,
    );
  }

  // ── Sessions ────────────────────────────────────────────────────────────────

  ApiSession getSessionByAccessToken(String accessToken) {
    final sessionRow = _findActiveSessionByAccessToken(accessToken);
    if (sessionRow == null) throw ApiException('Unauthorized.', statusCode: 401);

    final userId = sessionRow['user_id'] as String;
    final user = _getUserById(userId);
    if (user == null) throw ApiException('User not found.', statusCode: 404);

    return ApiSession(
      accessToken: sessionRow['access_token'] as String,
      refreshToken: sessionRow['refresh_token'] as String,
      user: user,
      profile: _findProfileByUserId(userId),
    );
  }

  ApiSession upsertProfile(String accessToken, ApiProfileInput input) {
    final sessionRow = _findActiveSessionByAccessToken(accessToken);
    if (sessionRow == null) throw ApiException('Unauthorized.', statusCode: 401);

    final userId = sessionRow['user_id'] as String;
    final now = dbNow();

    final existingProfile = _findProfileByUserId(userId);
    if (existingProfile == null) {
      _database.raw.execute(
        'INSERT INTO user_profiles (user_id, display_name, weight_kg, height_cm, sex, fitness_goal, onboarding_completed, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)',
        [userId, input.displayName, input.weightKg, input.heightCm, input.sex.name, input.fitnessGoal, now, now],
      );
    } else {
      _database.raw.execute(
        'UPDATE user_profiles SET display_name=?, weight_kg=?, height_cm=?, sex=?, fitness_goal=?, onboarding_completed=1, updated_at=? WHERE user_id=?',
        [input.displayName, input.weightKg, input.heightCm, input.sex.name, input.fitnessGoal, now, userId],
      );
    }

    _database.raw.execute(
      'UPDATE users SET display_name=?, updated_at=?, last_login_at=? WHERE id=?',
      [input.displayName, now, now, userId],
    );

    return getSessionByAccessToken(accessToken);
  }

  ApiSession updateFitnessGoal(String accessToken, String? fitnessGoal) {
    final sessionRow = _findActiveSessionByAccessToken(accessToken);
    if (sessionRow == null) throw ApiException('Unauthorized.', statusCode: 401);

    final userId = sessionRow['user_id'] as String;
    final now = dbNow();

    _database.raw.execute(
      'UPDATE user_profiles SET fitness_goal=?, updated_at=? WHERE user_id=?',
      [fitnessGoal, now, userId],
    );

    return getSessionByAccessToken(accessToken);
  }

  ApiSession refreshSession(String refreshToken) {
    final sessionRow = _findActiveSessionByRefreshToken(refreshToken);
    if (sessionRow == null) throw ApiException('Unauthorized.', statusCode: 401);

    final refreshExpiresAt = DateTime.parse(sessionRow['refresh_expires_at'] as String);
    if (refreshExpiresAt.isBefore(DateTime.now().toUtc())) {
      throw ApiException('Refresh token expired.', statusCode: 401);
    }

    final userId = sessionRow['user_id'] as String;
    _database.raw.execute(
      'UPDATE auth_sessions SET revoked_at=?, updated_at=? WHERE id=?',
      [dbNow(), dbNow(), sessionRow['id']],
    );

    final user = _getUserById(userId);
    if (user == null) throw ApiException('User not found.', statusCode: 404);

    return _createSessionForUser(user, _findProfileByUserId(userId));
  }

  void logoutByBearerToken(String accessToken) {
    final sessionRow = _findActiveSessionByAccessToken(accessToken);
    if (sessionRow == null) return;
    _database.raw.execute(
      'UPDATE auth_sessions SET revoked_at=?, updated_at=? WHERE id=?',
      [dbNow(), dbNow(), sessionRow['id']],
    );
  }

  // ── Private helpers ─────────────────────────────────────────────────────────

  ApiSession _createNewUserSession(GoogleTokenPayload google, String now) {
    final userId = _uuid.v4();
    final tokens = _sessionService.issueTokens();

    _database.raw.execute(
      'INSERT INTO users (id, email, display_name, photo_url, created_at, updated_at, last_login_at, is_deleted) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, 0)',
      [userId, google.email, google.displayName, google.photoUrl, now, now, now],
    );

    _database.raw.execute(
      'INSERT INTO user_auth_accounts (user_id, provider, provider_subject, email, email_verified, created_at, updated_at) '
      "VALUES (?, 'google', ?, ?, ?, ?, ?)",
      [userId, google.subject, google.email, google.emailVerified ? 1 : 0, now, now],
    );

    _database.raw.execute(
      'INSERT INTO user_profiles (user_id, display_name, weight_kg, height_cm, sex, onboarding_completed, created_at, updated_at) '
      'VALUES (?, ?, NULL, NULL, ?, 0, ?, ?)',
      [userId, google.displayName, UserSex.unspecified.name, now, now],
    );

    _insertSession(userId: userId, tokens: tokens, now: now);
    return _buildSession(userId, tokens.accessToken, tokens.refreshToken);
  }

  ApiSession _reuseExistingUserSession(
      String userId, GoogleTokenPayload google, String now) {
    _database.raw.execute(
      'UPDATE users SET email=?, display_name=?, photo_url=?, updated_at=?, last_login_at=?, is_deleted=0 WHERE id=?',
      [google.email, google.displayName, google.photoUrl, now, now, userId],
    );
    _database.raw.execute(
      "UPDATE user_auth_accounts SET email=?, email_verified=?, updated_at=? WHERE user_id=? AND provider='google'",
      [google.email, google.emailVerified ? 1 : 0, now, userId],
    );

    if (_findProfileByUserId(userId) == null) {
      _database.raw.execute(
        'INSERT INTO user_profiles (user_id, display_name, weight_kg, height_cm, sex, onboarding_completed, created_at, updated_at) '
        'VALUES (?, ?, NULL, NULL, ?, 0, ?, ?)',
        [userId, google.displayName, UserSex.unspecified.name, now, now],
      );
    }

    final tokens = _sessionService.issueTokens();
    _insertSession(userId: userId, tokens: tokens, now: now);
    return _buildSession(userId, tokens.accessToken, tokens.refreshToken);
  }

  void _insertSession({
    required String userId,
    required SessionTokens tokens,
    required String now,
  }) {
    _database.raw.execute(
      'INSERT INTO auth_sessions '
      '(user_id, access_token, refresh_token, device_name, access_expires_at, refresh_expires_at, revoked_at, created_at, updated_at) '
      'VALUES (?, ?, ?, NULL, ?, ?, NULL, ?, ?)',
      [
        userId,
        tokens.accessToken,
        tokens.refreshToken,
        tokens.accessExpiresAt.toIso8601String(),
        tokens.refreshExpiresAt.toIso8601String(),
        now,
        now,
      ],
    );
  }

  ApiSession _createSessionForUser(ApiUser user, ApiProfile? profile) {
    final now = dbNow();
    final tokens = _sessionService.issueTokens();
    _insertSession(userId: user.id, tokens: tokens, now: now);
    return ApiSession(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      user: user,
      profile: profile,
    );
  }

  ApiSession _buildSession(
      String userId, String accessToken, String refreshToken) {
    final user = _getUserById(userId);
    if (user == null) throw ApiException('User not found.', statusCode: 404);
    return ApiSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      user: user,
      profile: _findProfileByUserId(userId),
    );
  }

  ApiUser? _getUserById(String id) {
    final rows = _database.raw
        .select('SELECT * FROM users WHERE id=? AND is_deleted=0 LIMIT 1', [id]);
    if (rows.isEmpty) return null;
    return _userFromRow(rows.first);
  }

  ApiUser? _getUserByEmail(String email) {
    final rows = _database.raw.select(
        'SELECT * FROM users WHERE lower(email)=lower(?) AND is_deleted=0 LIMIT 1',
        [email]);
    if (rows.isEmpty) return null;
    return _userFromRow(rows.first);
  }

  ApiUser _userFromRow(dynamic row) => ApiUser(
        id: row['id'] as String,
        email: row['email'] as String,
        displayName: row['display_name'] as String,
        photoUrl: row['photo_url'] as String?,
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
        lastLoginAt: row['last_login_at'] == null
            ? null
            : DateTime.parse(row['last_login_at'] as String),
        isDeleted: (row['is_deleted'] as int? ?? 0) == 1,
      );

  ApiProfile? _findProfileByUserId(String userId) {
    final rows = _database.raw
        .select('SELECT * FROM user_profiles WHERE user_id=? LIMIT 1', [userId]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return ApiProfile(
      userId: row['user_id'] as String,
      displayName: row['display_name'] as String,
      weightKg: (row['weight_kg'] as num?)?.toDouble(),
      heightCm: (row['height_cm'] as num?)?.toDouble(),
      sex: ApiProfile.sexFromDb(row['sex'] as String?),
      onboardingCompleted: (row['onboarding_completed'] as int? ?? 0) == 1,
      isCoach: (row['is_coach'] as int? ?? 0) == 1,
      fitnessGoal: row['fitness_goal'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }

  String? _findUserIdByGoogleSubject(String subject) {
    final rows = _database.raw.select(
        "SELECT user_id FROM user_auth_accounts WHERE provider='google' AND provider_subject=? LIMIT 1",
        [subject]);
    if (rows.isEmpty) return null;
    return rows.first['user_id'] as String;
  }

  dynamic _findGymTrackAuthAccountByEmail(String email) {
    final rows = _database.raw.select(
        "SELECT * FROM user_auth_accounts WHERE provider='gymtrack' AND lower(email)=lower(?) LIMIT 1",
        [email]);
    if (rows.isEmpty) return null;
    return rows.first;
  }

  dynamic _findActiveSessionByAccessToken(String accessToken) {
    final rows = _database.raw.select(
        'SELECT * FROM auth_sessions WHERE access_token=? AND revoked_at IS NULL LIMIT 1',
        [accessToken]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    final exp = DateTime.parse(row['access_expires_at'] as String);
    if (exp.isBefore(DateTime.now().toUtc())) return null;
    return row;
  }

  dynamic _findActiveSessionByRefreshToken(String refreshToken) {
    final rows = _database.raw.select(
        'SELECT * FROM auth_sessions WHERE refresh_token=? AND revoked_at IS NULL LIMIT 1',
        [refreshToken]);
    if (rows.isEmpty) return null;
    return rows.first;
  }

  String _normalizeDisplayName(String? displayName, String email) {
    final value = displayName?.trim();
    if (value != null && value.isNotEmpty) return value;
    final localPart = email.split('@').first.trim();
    return localPart.isEmpty ? 'Athlète' : localPart;
  }
}

class ApiProfileInput {
  ApiProfileInput({
    required this.displayName,
    required this.weightKg,
    required this.heightCm,
    required this.sex,
    this.fitnessGoal,
  });

  final String displayName;
  final double? weightKg;
  final double? heightCm;
  final UserSex sex;
  final String? fitnessGoal;
}
