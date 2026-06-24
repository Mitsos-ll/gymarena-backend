import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../db/app_database.dart';
import '../utils/http_json.dart';

class AdminRoutes {
  AdminRoutes({required this.database, required this.adminSecret});

  final AppDatabase database;
  final String adminSecret;

  Response statsHandler(Request request) {
    final auth = request.headers['authorization'] ?? '';
    if (auth != 'Bearer $adminSecret') {
      return Response(401,
          body: '{"message":"Unauthorized"}',
          headers: {'Content-Type': 'application/json'});
    }

    final db = database.raw;

    final totalUsers = (db.select(
      'SELECT COUNT(*) as c FROM users WHERE is_deleted = 0',
    ).first['c'] as int?) ?? 0;

    final activeUsers7d = (db.select(
      "SELECT COUNT(*) as c FROM users WHERE is_deleted = 0 AND last_login_at >= datetime('now', '-7 days')",
    ).first['c'] as int?) ?? 0;

    final activeUsers30d = (db.select(
      "SELECT COUNT(*) as c FROM users WHERE is_deleted = 0 AND last_login_at >= datetime('now', '-30 days')",
    ).first['c'] as int?) ?? 0;

    final newToday = (db.select(
      "SELECT COUNT(*) as c FROM users WHERE is_deleted = 0 AND created_at >= datetime('now', 'start of day')",
    ).first['c'] as int?) ?? 0;

    final newThisWeek = (db.select(
      "SELECT COUNT(*) as c FROM users WHERE is_deleted = 0 AND created_at >= datetime('now', '-7 days')",
    ).first['c'] as int?) ?? 0;

    final activeSessions = (db.select(
      "SELECT COUNT(*) as c FROM auth_sessions WHERE revoked_at IS NULL AND refresh_expires_at > datetime('now')",
    ).first['c'] as int?) ?? 0;

    return jsonResponse({
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'users': {
        'total': totalUsers,
        'new_today': newToday,
        'new_this_week': newThisWeek,
        'active_7d': activeUsers7d,
        'active_30d': activeUsers30d,
      },
      'sessions': {
        'active': activeSessions,
      },
    });
  }
}
