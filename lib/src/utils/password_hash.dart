import 'dart:convert';

import 'package:bcrypt/bcrypt.dart';
import 'package:crypto/crypto.dart';

const _bcryptRounds = 12;

/// Hache un mot de passe avec BCrypt (coût 12).
/// À utiliser pour tout nouveau compte ou changement de mot de passe.
String hashPassword(String password) {
  return BCrypt.hashpw(password, BCrypt.gensalt(logRounds: _bcryptRounds));
}

/// Vérifie un mot de passe contre le hash stocké.
/// Supporte les deux formats :
///   - BCrypt  : commence par `$2a$` ou `$2b$`  → vérification native
///   - Legacy  : SHA-256(salt:password)          → vérification + migration signalée
///
/// Retourne `(isValid, needsMigration)`.
(bool isValid, bool needsMigration) verifyPassword(
  String password,
  String storedHash,
  String? storedSalt,
) {
  if (_isBcryptHash(storedHash)) {
    return (BCrypt.checkpw(password, storedHash), false);
  }

  // Legacy SHA-256 — vérification et signal de migration
  if (storedSalt == null) return (false, false);
  final legacyHash = _sha256Legacy(password, storedSalt);
  return (legacyHash == storedHash, true);
}

bool _isBcryptHash(String hash) =>
    hash.startsWith(r'$2a$') || hash.startsWith(r'$2b$');

String _sha256Legacy(String password, String salt) =>
    sha256.convert(utf8.encode('$salt:$password')).toString();
