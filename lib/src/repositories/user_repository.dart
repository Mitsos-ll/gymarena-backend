import 'dart:math';

import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../models/api_profile.dart';
import '../models/api_session.dart';
import '../models/api_user.dart';
import '../models/oauth_identity.dart';
import '../services/apple_token_service.dart';
import '../services/google_token_service.dart';
import '../services/session_service.dart';
import '../utils/api_exception.dart';
import '../utils/password_hash.dart';
import '../utils/token_hash.dart';

class UserRepository {
  UserRepository({
    required AppDatabase database,
    required SessionService sessionService,
  })  : _database = database,
        _sessionService = sessionService;

  final AppDatabase _database;
  final SessionService _sessionService;
  final _uuid = const Uuid();
  final _random = Random.secure();

  static const _resetCodeValidityMinutes = 15;

  // ── OAuth (Google, Apple) ───────────────────────────────────────────────────

  ApiSession signInWithGoogle(GoogleTokenPayload google) =>
      _signInWithOAuth(OAuthIdentity(
        provider: OAuthProvider.google,
        subject: google.subject,
        email: google.email,
        emailVerified: google.emailVerified,
        displayName: google.displayName,
        photoUrl: google.photoUrl,
      ));

  /// [fullName] vient du client : Apple ne le met pas dans le token et ne le
  /// donne qu'à la toute première autorisation de l'app.
  ApiSession signInWithApple(AppleTokenPayload apple, {String? fullName}) =>
      _signInWithOAuth(OAuthIdentity(
        provider: OAuthProvider.apple,
        subject: apple.subject,
        email: apple.email,
        emailVerified: apple.emailVerified,
        displayName: _appleDefaultDisplayName(apple, fullName),
      ));

  ApiSession _signInWithOAuth(OAuthIdentity identity) {
    final now = dbNow();

    final linkedUserId =
        _findUserIdByProviderSubject(identity.provider, identity.subject);
    if (linkedUserId != null) {
      return _reuseExistingUserSession(linkedUserId, identity, now);
    }

    // users.email est NOT NULL UNIQUE : sans adresse, on ne peut ni rattacher
    // ni créer de compte. Apple peut en omettre une si l'utilisateur a déjà
    // autorisé l'app puis l'a retirée de ses réglages.
    final email = identity.email;
    if (email == null) {
      throw ApiException(
        'Apple did not share an email address. Remove GymArena from the '
        'Sign in with Apple settings of your Apple Account, then try again.',
        statusCode: 400,
      );
    }

    // Aucun compte lié à ce subject : un utilisateur peut néanmoins déjà
    // exister avec cet email (inscription gymtrack email/mdp, ou compte antérieur).
    // On rattache le provider au user existant plutôt que d'insérer un
    // doublon — sinon violation UNIQUE(users.email).
    final existingByEmail = _getUserByEmail(email);
    if (existingByEmail != null) {
      _linkOAuthAccount(existingByEmail.id, identity, now);
      return _reuseExistingUserSession(existingByEmail.id, identity, now);
    }

    return _createNewUserSession(identity, email, now);
  }

  /// Le relais « Masquer mon e-mail » est une suite aléatoire : un mauvais
  /// pseudo par défaut. Une chaîne vide laisse `_resolveUniqueDisplayName`
  /// retomber sur « Athlète ».
  String _appleDefaultDisplayName(AppleTokenPayload apple, String? fullName) {
    final name = fullName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final email = apple.email;
    if (email != null && !apple.isPrivateEmail) return email.split('@').first;
    return '';
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
    if (_isDisplayNameTaken(finalDisplayName)) {
      throw ApiException('This display name is already taken.', statusCode: 409);
    }
    final tokens = _sessionService.issueTokens();

    _database.raw.execute(
      'INSERT INTO users (id, email, display_name, display_name_normalized, photo_url, created_at, updated_at, last_login_at, is_deleted) '
      'VALUES (?, ?, ?, ?, NULL, ?, ?, ?, 0)',
      [userId, normalizedEmail, finalDisplayName, finalDisplayName.toLowerCase(), now, now, now],
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

  // ── Mot de passe oublié ──────────────────────────────────────────────────────

  /// Génère un code de reset si un compte gymtrack existe pour cet email.
  /// Retourne `email: null` si aucun compte ne correspond, pour que la route
  /// puisse répondre de façon générique sans révéler quels emails existent.
  PasswordResetRequest requestPasswordReset(String email) {
    final normalizedEmail = email.trim().toLowerCase();
    final account = _findGymTrackAuthAccountByEmail(normalizedEmail);
    if (account == null) {
      return PasswordResetRequest(email: null, code: null);
    }

    final userId = account['user_id'] as String;
    final now = dbNow();
    final code = _generateResetCode();
    final expiresAt = DateTime.now()
        .toUtc()
        .add(const Duration(minutes: _resetCodeValidityMinutes))
        .toIso8601String();

    _database.raw.execute(
      'INSERT INTO password_reset_codes (id, user_id, code, expires_at, used_at, created_at) '
      'VALUES (?, ?, ?, ?, NULL, ?)',
      [_uuid.v4(), userId, code, expiresAt, now],
    );

    return PasswordResetRequest(email: normalizedEmail, code: code);
  }

  void resetPasswordWithCode({
    required String email,
    required String code,
    required String newPassword,
  }) {
    final normalizedEmail = email.trim().toLowerCase();
    final account = _findGymTrackAuthAccountByEmail(normalizedEmail);
    if (account == null) {
      throw ApiException('Invalid or expired code.', statusCode: 400);
    }

    final userId = account['user_id'] as String;
    final now = dbNow();

    final rows = _database.raw.select(
      'SELECT id FROM password_reset_codes '
      'WHERE user_id=? AND code=? AND used_at IS NULL AND expires_at > ? '
      'ORDER BY created_at DESC LIMIT 1',
      [userId, code, now],
    );
    if (rows.isEmpty) {
      throw ApiException('Invalid or expired code.', statusCode: 400);
    }

    final newHash = hashPassword(newPassword);
    _database.raw.execute(
      "UPDATE user_auth_accounts SET password_hash=?, password_salt=NULL, updated_at=? "
      "WHERE user_id=? AND provider='gymtrack'",
      [newHash, now, userId],
    );

    _database.raw.execute(
      'UPDATE password_reset_codes SET used_at=? WHERE id=?',
      [now, rows.first['id']],
    );

    // Comme pour tout changement de mot de passe : on invalide les sessions
    // actives, au cas où le mot de passe précédent était compromis.
    _database.raw.execute(
      'UPDATE auth_sessions SET revoked_at=?, updated_at=? WHERE user_id=? AND revoked_at IS NULL',
      [now, now, userId],
    );
  }

  String _generateResetCode() =>
      _random.nextInt(1000000).toString().padLeft(6, '0');

  // ── Suppression de compte ─────────────────────────────────────────────────

  /// Supprime définitivement le compte associé à [accessToken] et toutes ses
  /// données (workouts, programmes, partages, liens coach/athlète...) via les
  /// contraintes ON DELETE CASCADE déclarées sur users(id). Irréversible.
  ///
  /// Retourne le refresh token Sign in with Apple du compte s'il en a un : il
  /// disparaît avec la ligne supprimée, et l'appelant doit le révoquer chez
  /// Apple (exigence de l'App Store).
  String? deleteAccount(String accessToken) {
    final sessionRow = _findActiveSessionByAccessToken(accessToken);
    if (sessionRow == null) throw ApiException('Unauthorized.', statusCode: 401);

    final userId = sessionRow['user_id'] as String;
    final appleRefreshToken = findProviderRefreshToken(userId, OAuthProvider.apple);
    _database.raw.execute('DELETE FROM users WHERE id = ?', [userId]);
    return appleRefreshToken;
  }

  void saveProviderRefreshToken(String userId, OAuthProvider provider, String refreshToken) {
    _database.raw.execute(
      'UPDATE user_auth_accounts SET provider_refresh_token=?, updated_at=? WHERE user_id=? AND provider=?',
      [refreshToken, dbNow(), userId, provider.name],
    );
  }

  String? findProviderRefreshToken(String userId, OAuthProvider provider) {
    final rows = _database.raw.select(
      'SELECT provider_refresh_token FROM user_auth_accounts WHERE user_id=? AND provider=? LIMIT 1',
      [userId, provider.name],
    );
    if (rows.isEmpty) return null;
    final token = rows.first['provider_refresh_token'] as String?;
    return (token == null || token.isEmpty) ? null : token;
  }

  // ── Sessions ────────────────────────────────────────────────────────────────

  // Le token n'étant plus jamais stocké en clair (seul son hash l'est), on
  // ne peut plus le "relire" en base pour le renvoyer au client : accessToken
  // vient du paramètre déjà connu de l'appelant, et refreshToken est
  // volontairement `null` (impossible à reconstituer depuis un hash). Le
  // client doit conserver son propre refreshToken déjà en main plutôt que
  // d'écraser sa session stockée avec cette valeur absente — voir
  // AuthController._preserveRefreshToken côté app.
  ApiSession getSessionByAccessToken(String accessToken) {
    final sessionRow = _findActiveSessionByAccessToken(accessToken);
    if (sessionRow == null) throw ApiException('Unauthorized.', statusCode: 401);

    final userId = sessionRow['user_id'] as String;
    final user = _getUserById(userId);
    if (user == null) throw ApiException('User not found.', statusCode: 404);

    return ApiSession(
      accessToken: accessToken,
      refreshToken: null,
      user: user,
      profile: _findProfileByUserId(userId),
    );
  }

  ApiSession upsertProfile(String accessToken, ApiProfileInput input) {
    final sessionRow = _findActiveSessionByAccessToken(accessToken);
    if (sessionRow == null) throw ApiException('Unauthorized.', statusCode: 401);

    final userId = sessionRow['user_id'] as String;
    final now = dbNow();

    if (_isDisplayNameTaken(input.displayName, excludeUserId: userId)) {
      throw ApiException('This display name is already taken.', statusCode: 409);
    }

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
      'UPDATE users SET display_name=?, display_name_normalized=?, updated_at=?, last_login_at=? WHERE id=?',
      [input.displayName, input.displayName.trim().toLowerCase(), now, now, userId],
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

  ApiSession _createNewUserSession(
      OAuthIdentity identity, String email, String now) {
    final userId = _uuid.v4();
    final tokens = _sessionService.issueTokens();
    // Pas d'étape interactive à la création d'un compte OAuth (contrairement
    // à l'inscription/l'édition manuelle) : en cas de collision, on suffixe
    // silencieusement plutôt que d'échouer la connexion.
    final finalDisplayName = _resolveUniqueDisplayName(identity.displayName);

    _database.raw.execute(
      'INSERT INTO users (id, email, display_name, display_name_normalized, photo_url, created_at, updated_at, last_login_at, is_deleted) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)',
      [userId, email, finalDisplayName, finalDisplayName.toLowerCase(), identity.photoUrl, now, now, now],
    );

    _database.raw.execute(
      'INSERT INTO user_auth_accounts (user_id, provider, provider_subject, email, email_verified, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [userId, identity.provider.name, identity.subject, email, identity.emailVerified ? 1 : 0, now, now],
    );

    _database.raw.execute(
      'INSERT INTO user_profiles (user_id, display_name, weight_kg, height_cm, sex, onboarding_completed, created_at, updated_at) '
      'VALUES (?, ?, NULL, NULL, ?, 0, ?, ?)',
      [userId, finalDisplayName, UserSex.unspecified.name, now, now],
    );

    _insertSession(userId: userId, tokens: tokens, now: now);
    return _buildSession(userId, tokens.accessToken, tokens.refreshToken);
  }

  /// Rattache un provider OAuth à un utilisateur existant (trouvé par email).
  /// Idempotent : si une ligne de ce provider existe déjà pour ce user, on met
  /// à jour le subject/email au lieu de violer UNIQUE(user_id, provider).
  void _linkOAuthAccount(String userId, OAuthIdentity identity, String now) {
    _database.raw.execute(
      'INSERT INTO user_auth_accounts '
      '(user_id, provider, provider_subject, email, email_verified, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(user_id, provider) DO UPDATE SET '
      'provider_subject=excluded.provider_subject, email=excluded.email, '
      'email_verified=excluded.email_verified, updated_at=excluded.updated_at',
      [userId, identity.provider.name, identity.subject, identity.email, identity.emailVerified ? 1 : 0, now, now],
    );
  }

  ApiSession _reuseExistingUserSession(
      String userId, OAuthIdentity identity, String now) {
    // display_name est désormais un pseudo unique choisi par l'utilisateur
    // (éditable dans "Mon compte") — une fois le profil créé, une
    // reconnexion OAuth ne doit plus jamais l'écraser avec le nom du
    // fournisseur du moment : sinon un pseudo personnalisé se ferait
    // silencieusement remplacer, voire re-suffixer si quelqu'un d'autre a
    // entre-temps pris ce nom (ex. "Alex" personnalisé en "AlexTheLegend",
    // puis un tiers prend "Alex" : la reconnexion renommerait le compte en
    // "Alex2" sans que l'utilisateur n'ait rien demandé).
    final hasProfile = _findProfileByUserId(userId) != null;

    if (identity.refreshesUserProfile) {
      _database.raw.execute(
        'UPDATE users SET email=?, photo_url=?, updated_at=?, last_login_at=?, is_deleted=0 WHERE id=?',
        [identity.email, identity.photoUrl, now, now, userId],
      );
    } else {
      _database.raw.execute(
        'UPDATE users SET updated_at=?, last_login_at=?, is_deleted=0 WHERE id=?',
        [now, now, userId],
      );
    }

    if (!hasProfile) {
      // Pas de profil existant (ex. compte email/mdp historique jamais
      // complété) : aucun pseudo à préserver, on résout un nom par défaut
      // comme à la création — excludeUserId pour ne pas se re-suffixer
      // soi-même si le nom du fournisseur est inchangé.
      final finalDisplayName =
          _resolveUniqueDisplayName(identity.displayName, excludeUserId: userId);
      _database.raw.execute(
        'UPDATE users SET display_name=?, display_name_normalized=? WHERE id=?',
        [finalDisplayName, finalDisplayName.toLowerCase(), userId],
      );
      _database.raw.execute(
        'INSERT INTO user_profiles (user_id, display_name, weight_kg, height_cm, sex, onboarding_completed, created_at, updated_at) '
        'VALUES (?, ?, NULL, NULL, ?, 0, ?, ?)',
        [userId, finalDisplayName, UserSex.unspecified.name, now, now],
      );
    }

    // Apple n'envoie pas toujours l'email : ne pas écraser celui déjà connu.
    final email = identity.email;
    if (email != null) {
      _database.raw.execute(
        'UPDATE user_auth_accounts SET email=?, email_verified=?, updated_at=? WHERE user_id=? AND provider=?',
        [email, identity.emailVerified ? 1 : 0, now, userId, identity.provider.name],
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
      '(user_id, access_token_hash, refresh_token_hash, device_name, access_expires_at, refresh_expires_at, revoked_at, created_at, updated_at) '
      'VALUES (?, ?, ?, NULL, ?, ?, NULL, ?, ?)',
      [
        userId,
        tokens.accessTokenHash,
        tokens.refreshTokenHash,
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

  String? _findUserIdByProviderSubject(OAuthProvider provider, String subject) {
    final rows = _database.raw.select(
        'SELECT user_id FROM user_auth_accounts WHERE provider=? AND provider_subject=? LIMIT 1',
        [provider.name, subject]);
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
        'SELECT * FROM auth_sessions WHERE access_token_hash=? AND revoked_at IS NULL LIMIT 1',
        [hashToken(accessToken)]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    final exp = DateTime.parse(row['access_expires_at'] as String);
    if (exp.isBefore(DateTime.now().toUtc())) return null;
    return row;
  }

  dynamic _findActiveSessionByRefreshToken(String refreshToken) {
    final rows = _database.raw.select(
        'SELECT * FROM auth_sessions WHERE refresh_token_hash=? AND revoked_at IS NULL LIMIT 1',
        [hashToken(refreshToken)]);
    if (rows.isEmpty) return null;
    return rows.first;
  }

  String _normalizeDisplayName(String? displayName, String email) {
    final value = displayName?.trim();
    if (value != null && value.isNotEmpty) return value;
    final localPart = email.split('@').first.trim();
    return localPart.isEmpty ? 'Athlète' : localPart;
  }

  // ── Unicité du pseudo (display_name) ────────────────────────────────────────

  /// Vérifie `display_name_normalized` (insensible casse/accents, cf.
  /// `_migrateDisplayNameUniquenessIfNeeded`), pas `LOWER(display_name)` en
  /// SQL — `LOWER()` de SQLite est ASCII-only.
  bool _isDisplayNameTaken(String displayName, {String? excludeUserId}) {
    final key = displayName.trim().toLowerCase();
    final rows = excludeUserId == null
        ? _database.raw.select(
            'SELECT id FROM users WHERE display_name_normalized=? AND is_deleted=0 LIMIT 1',
            [key],
          )
        : _database.raw.select(
            'SELECT id FROM users WHERE display_name_normalized=? AND is_deleted=0 AND id!=? LIMIT 1',
            [key, excludeUserId],
          );
    return rows.isNotEmpty;
  }

  /// Utilisé sur les chemins non-interactifs (connexion/inscription OAuth) :
  /// pas d'étape où demander un autre nom à l'utilisateur, donc on résout
  /// silencieusement une variante libre par suffixe numérique.
  String _resolveUniqueDisplayName(String candidate, {String? excludeUserId}) {
    final base = candidate.trim().isEmpty ? 'Athlète' : candidate.trim();
    if (!_isDisplayNameTaken(base, excludeUserId: excludeUserId)) return base;
    var suffix = 2;
    while (_isDisplayNameTaken('$base$suffix', excludeUserId: excludeUserId)) {
      suffix++;
    }
    return '$base$suffix';
  }

  /// Utilisé par la route `GET /auth/display-name-available` (vérification
  /// en direct côté client, avant soumission).
  bool isDisplayNameAvailable(String displayName) => !_isDisplayNameTaken(displayName);

  /// Utilisé par la route `GET /community/users/lookup` (ajout d'ami par
  /// pseudo) — résolution insensible casse/accents via la même colonne
  /// `display_name_normalized` que les vérifications d'unicité ci-dessus.
  ApiUser? findByDisplayName(String displayName) {
    final key = displayName.trim().toLowerCase();
    final rows = _database.raw.select(
      'SELECT * FROM users WHERE display_name_normalized=? AND is_deleted=0 LIMIT 1',
      [key],
    );
    if (rows.isEmpty) return null;
    return _userFromRow(rows.first);
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

class PasswordResetRequest {
  PasswordResetRequest({required this.email, required this.code});

  /// null si aucun compte gymtrack ne correspond à l'email fourni.
  final String? email;
  final String? code;
}
