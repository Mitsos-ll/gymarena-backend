import 'api_exception.dart';

final _emailRegex = RegExp(r'^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$');

/// Valide et nettoie un email. Lance [ApiException] 400 si invalide.
String validateEmail(String? raw) {
  final email = raw?.trim().toLowerCase() ?? '';
  if (email.isEmpty) throw ApiException('email is required.', statusCode: 400);
  if (email.length > 254) throw ApiException('email is too long.', statusCode: 400);
  if (!_emailRegex.hasMatch(email)) {
    throw ApiException('email format is invalid.', statusCode: 400);
  }
  return email;
}

/// Valide un mot de passe. Lance [ApiException] 400 si trop court ou trop long.
/// [skipComplexity] : désactive la vérification de longueur minimale (pour login).
String validatePassword(String? raw, {bool skipComplexity = false}) {
  final password = raw ?? '';
  if (password.isEmpty) throw ApiException('password is required.', statusCode: 400);
  if (!skipComplexity && password.length < 8) {
    throw ApiException('password must be at least 8 characters.', statusCode: 400);
  }
  if (password.length > 128) {
    throw ApiException('password must be 128 characters or fewer.', statusCode: 400);
  }
  return password;
}

/// Valide un displayName. Si [required] est false, retourne null si absent/vide.
String? validateDisplayName(String? raw, {bool required = false}) {
  final name = raw?.trim();
  if (name == null || name.isEmpty) {
    if (required) throw ApiException('displayName is required.', statusCode: 400);
    return null;
  }
  if (name.length > 100) {
    throw ApiException('displayName must be 100 characters or fewer.', statusCode: 400);
  }
  return name;
}

/// Valide un idToken Google (non-vide, longueur raisonnable).
String validateIdToken(String? raw) {
  final token = raw?.trim() ?? '';
  if (token.isEmpty) throw ApiException('idToken is required.', statusCode: 400);
  if (token.length > 4096) throw ApiException('idToken is too long.', statusCode: 400);
  return token;
}

/// Valide un refreshToken (non-vide).
String validateRefreshToken(String? raw) {
  final token = raw?.trim() ?? '';
  if (token.isEmpty) throw ApiException('refreshToken is required.', statusCode: 400);
  return token;
}

/// Valide une valeur numérique optionnelle dans une fourchette.
double? validateOptionalDouble(
  dynamic raw, {
  required String field,
  double min = 0,
  double max = 9999,
}) {
  if (raw == null) return null;
  final value = (raw is num) ? raw.toDouble() : double.tryParse(raw.toString());
  if (value == null) throw ApiException('$field must be a number.', statusCode: 400);
  if (value < min || value > max) {
    throw ApiException('$field must be between $min and $max.', statusCode: 400);
  }
  return value;
}
