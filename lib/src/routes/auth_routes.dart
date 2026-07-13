import 'package:shelf/shelf.dart';

import '../middleware/rate_limit_middleware.dart';
import '../repositories/user_repository.dart';
import '../services/email_service.dart';
import '../services/google_token_service.dart';
import '../utils/api_exception.dart';
import '../utils/client_ip.dart';
import '../utils/http_json.dart';
import '../utils/validator.dart';

class AuthRoutes {
  AuthRoutes({
    required GoogleTokenService googleTokenService,
    required UserRepository userRepository,
    required RateLimiter authLimiter,
    required EmailService emailService,
  })  : _googleTokenService = googleTokenService,
        _userRepository = userRepository,
        _authLimiter = authLimiter,
        _emailService = emailService;

  final GoogleTokenService _googleTokenService;
  final UserRepository _userRepository;
  final RateLimiter _authLimiter;
  final EmailService _emailService;

  Future<Response> signInGoogle(Request request) async {
    try {
      _enforceAuthLimit(request);
      final body = await readJsonBody(request);
      final idToken = validateIdToken(body['idToken']?.toString());

      final google = await _googleTokenService.verifyIdToken(idToken);
      final session = _userRepository.signInWithGoogle(google);
      return jsonResponse(session.toJson());
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Future<Response> register(Request request) async {
    try {
      _enforceAuthLimit(request);
      final body = await readJsonBody(request);
      final email = validateEmail(body['email']?.toString());
      _enforceAuthLimit(request, accountKey: email);
      final password = validatePassword(body['password']?.toString());
      final displayName =
          validateDisplayName(body['displayName']?.toString(), required: false);

      final session = _userRepository.registerWithGymTrack(
        email: email,
        password: password,
        displayName: displayName,
      );
      return jsonResponse(session.toJson());
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Future<Response> login(Request request) async {
    try {
      _enforceAuthLimit(request);
      final body = await readJsonBody(request);
      final email = validateEmail(body['email']?.toString());
      // Limite dédiée par compte ciblé, en plus de la limite par IP : une
      // IP falsifiée (X-Forwarded-For) ne suffit plus à elle seule à
      // contourner la protection contre le credential-stuffing sur un email
      // donné.
      _enforceAuthLimit(request, accountKey: email);
      // Login: skip complexity check — user may have an old password
      final password =
          validatePassword(body['password']?.toString(), skipComplexity: true);

      final session = _userRepository.signInWithGymTrack(
        email: email,
        password: password,
      );
      return jsonResponse(session.toJson());
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Future<Response> refresh(Request request) async {
    try {
      _enforceAuthLimit(request);
      final body = await readJsonBody(request);
      final refreshToken = validateRefreshToken(body['refreshToken']?.toString());

      final session = _userRepository.refreshSession(refreshToken);
      return jsonResponse(session.toJson());
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Future<Response> logout(Request request) async {
    try {
      final bearer = bearerToken(request);
      if (bearer != null && bearer.isNotEmpty) {
        _userRepository.logoutByBearerToken(bearer);
      }
      return jsonResponse({'ok': true});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Future<Response> forgotPassword(Request request) async {
    try {
      _enforceAuthLimit(request);
      final body = await readJsonBody(request);
      final email = validateEmail(body['email']?.toString());
      _enforceAuthLimit(request, accountKey: email);

      final result = _userRepository.requestPasswordReset(email);
      if (result.email != null && result.code != null) {
        await _emailService.sendPasswordResetCode(
          toEmail: result.email!,
          code: result.code!,
        );
      }

      // Réponse toujours identique, que le compte existe ou non — on ne
      // révèle jamais quels emails sont enregistrés.
      return jsonResponse({
        'ok': true,
        'message': 'If an account exists for this email, a reset code has been sent.',
      });
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  Future<Response> resetPassword(Request request) async {
    try {
      _enforceAuthLimit(request);
      final body = await readJsonBody(request);
      final email = validateEmail(body['email']?.toString());
      // Le point le plus sensible au bruteforce (code à 6 chiffres) : la
      // limite par IP seule est contournable en falsifiant X-Forwarded-For,
      // celle par compte ne l'est pas.
      _enforceAuthLimit(request, accountKey: email);
      final code = validateResetCode(body['code']?.toString());
      final newPassword = validatePassword(body['newPassword']?.toString());

      _userRepository.resetPasswordWithCode(
        email: email,
        code: code,
        newPassword: newPassword,
      );

      return jsonResponse({'ok': true});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    }
  }

  /// Applique la limite par IP, et si [accountKey] (email) est fourni, une
  /// seconde limite indépendante par compte ciblé — préfixées pour ne jamais
  /// collisionner dans le même bucket store.
  void _enforceAuthLimit(Request request, {String? accountKey}) {
    final ip = clientIp(request);
    if (!_authLimiter.allow('ip:$ip')) {
      throw ApiException('Too many auth attempts. Please slow down.',
          statusCode: 429);
    }
    if (accountKey != null &&
        !_authLimiter.allow('acct:${accountKey.toLowerCase()}')) {
      throw ApiException('Too many auth attempts. Please slow down.',
          statusCode: 429);
    }
  }
}
