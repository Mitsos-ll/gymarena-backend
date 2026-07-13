import 'dart:collection';
import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../utils/client_ip.dart';

/// Token-bucket rate limiter in-memory par IP (ou clé custom).
/// Paramètres séparables par route — instanciez un limiter par groupe.
class RateLimiter {
  RateLimiter({
    required this.maxRequests,
    required this.windowDuration,
  });

  final int maxRequests;
  final Duration windowDuration;

  // LinkedHashMap pour préserver l'ordre d'insertion → cleanup efficace.
  final _buckets = LinkedHashMap<String, _Bucket>();

  bool allow(String key) {
    _evictExpired();
    final now = DateTime.now();
    final bucket = _buckets[key];

    if (bucket == null || now.difference(bucket.windowStart) >= windowDuration) {
      _buckets[key] = _Bucket(count: 1, windowStart: now);
      return true;
    }

    if (bucket.count >= maxRequests) return false;
    bucket.count++;
    return true;
  }

  void _evictExpired() {
    final cutoff = DateTime.now().subtract(windowDuration);
    _buckets.removeWhere((_, b) => b.windowStart.isBefore(cutoff));
  }

  Middleware asMiddleware({
    String Function(Request)? keyExtractor,
  }) {
    return (Handler inner) {
      return (Request request) async {
        final key = keyExtractor?.call(request) ?? clientIp(request);
        if (!allow(key)) {
          return Response(
            429,
            body: jsonEncode({'message': 'Too many requests. Please slow down.'}),
            headers: {
              'Content-Type': 'application/json',
              'Retry-After': windowDuration.inSeconds.toString(),
            },
          );
        }
        return inner(request);
      };
    };
  }
}

class _Bucket {
  _Bucket({required this.count, required this.windowStart});
  int count;
  final DateTime windowStart;
}
