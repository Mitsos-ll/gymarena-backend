import 'package:shelf/shelf.dart';

/// Résout l'IP cliente à partir de l'en-tête positionné par le edge Fly.io
/// (`Fly-Client-IP`), qui n'est pas falsifiable côté client puisqu'il est
/// écrasé par le proxy Fly avant d'atteindre l'app.
///
/// `X-Forwarded-For`/`X-Real-Ip` restent en repli pour un environnement hors
/// Fly.io (dev local), mais NE DOIVENT PAS être utilisés seuls pour du
/// rate-limiting en production : un proxy standard ajoute l'IP réelle à la
/// suite d'une valeur déjà présente sans la remplacer, donc un client peut
/// fournir n'importe quelle valeur en tête de liste pour obtenir un nouveau
/// "bucket" de rate-limit à chaque requête.
String clientIp(Request request) {
  final flyIp = request.headers['fly-client-ip'];
  if (flyIp != null && flyIp.isNotEmpty) return flyIp;

  return request.headers['x-forwarded-for']?.split(',').first.trim() ??
      request.headers['x-real-ip'] ??
      'unknown';
}
