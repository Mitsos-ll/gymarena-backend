import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../utils/api_exception.dart';

/// Motifs de signalement acceptés (liste fermée : évite le texte libre non
/// borné et permet de trier les signalements).
const reportReasons = {'inappropriate', 'harassment', 'spam', 'other'};

class BlockedUser {
  BlockedUser({required this.userId, required this.displayName, required this.blockedAt});

  final String userId;
  final String displayName;
  final String blockedAt;

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'displayName': displayName,
        'blockedAt': blockedAt,
      };
}

/// Signalement et blocage d'utilisateurs (guideline App Store 1.2).
class ModerationRepository {
  ModerationRepository({required AppDatabase database}) : _db = database;

  final AppDatabase _db;
  final _uuid = const Uuid();

  /// Au-delà, un compte qui signale est probablement en train d'abuser du
  /// mécanisme lui-même.
  static const maxReportsPerHour = 10;

  /// Vrai si l'un des deux a bloqué l'autre, quelle que soit la direction :
  /// un blocage coupe la relation dans les deux sens.
  bool areBlocked(String userIdA, String userIdB) {
    final rows = _db.raw.select(
      'SELECT 1 FROM user_blocks '
      'WHERE (blocker_id=? AND blocked_id=?) OR (blocker_id=? AND blocked_id=?) LIMIT 1',
      [userIdA, userIdB, userIdB, userIdA],
    );
    return rows.isNotEmpty;
  }

  /// Bloque [blockedId] et supprime toute relation (ami, rival, demande en
  /// attente) entre les deux. Idempotent.
  void block(String blockerId, String blockedId) {
    _requireOtherExistingUser(blockerId, blockedId);

    _db.raw.execute(
      'INSERT OR IGNORE INTO user_blocks (blocker_id, blocked_id, created_at) VALUES (?, ?, ?)',
      [blockerId, blockedId, dbNow()],
    );
    _db.raw.execute(
      'DELETE FROM social_relations '
      'WHERE (user_id_a=? AND user_id_b=?) OR (user_id_a=? AND user_id_b=?)',
      [blockerId, blockedId, blockedId, blockerId],
    );
  }

  void unblock(String blockerId, String blockedId) {
    _db.raw.execute(
      'DELETE FROM user_blocks WHERE blocker_id=? AND blocked_id=?',
      [blockerId, blockedId],
    );
  }

  List<BlockedUser> listBlockedBy(String blockerId) {
    final rows = _db.raw.select(
      'SELECT b.blocked_id, b.created_at, u.display_name '
      'FROM user_blocks b JOIN users u ON u.id = b.blocked_id '
      'WHERE b.blocker_id=? AND u.is_deleted=0 ORDER BY b.created_at DESC',
      [blockerId],
    );
    return [
      for (final row in rows)
        BlockedUser(
          userId: row['blocked_id'] as String,
          displayName: row['display_name'] as String,
          blockedAt: row['created_at'] as String,
        ),
    ];
  }

  /// Enregistre un signalement et retourne son id.
  String report({
    required String reporterId,
    required String reportedId,
    required String reason,
    String? details,
  }) {
    if (!reportReasons.contains(reason)) {
      throw ApiException('reason must be one of: ${reportReasons.join(', ')}.', statusCode: 400);
    }
    _requireOtherExistingUser(reporterId, reportedId);

    final since = DateTime.now().toUtc().subtract(const Duration(hours: 1)).toIso8601String();
    final recent = _db.raw.select(
      'SELECT COUNT(*) AS n FROM user_reports WHERE reporter_id=? AND created_at>?',
      [reporterId, since],
    ).first['n'] as int;
    if (recent >= maxReportsPerHour) {
      throw ApiException('Too many reports. Please try again later.', statusCode: 429);
    }

    final id = _uuid.v4();
    _db.raw.execute(
      'INSERT INTO user_reports (id, reporter_id, reported_id, reason, details, status, created_at) '
      "VALUES (?, ?, ?, ?, ?, 'open', ?)",
      [id, reporterId, reportedId, reason, details, dbNow()],
    );
    return id;
  }

  /// Pour l'administrateur : signalements avec les noms des deux parties.
  List<Map<String, dynamic>> listReports({String status = 'open', int limit = 200}) {
    final rows = _db.raw.select(
      'SELECT r.id, r.reporter_id, r.reported_id, r.reason, r.details, r.status, r.created_at, '
      'reporter.display_name AS reporter_name, reported.display_name AS reported_name '
      'FROM user_reports r '
      'JOIN users reporter ON reporter.id = r.reporter_id '
      'JOIN users reported ON reported.id = r.reported_id '
      'WHERE r.status=? ORDER BY r.created_at DESC LIMIT ?',
      [status, limit],
    );
    return [
      for (final row in rows)
        {
          'id': row['id'],
          'reporterId': row['reporter_id'],
          'reporterName': row['reporter_name'],
          'reportedId': row['reported_id'],
          'reportedName': row['reported_name'],
          'reason': row['reason'],
          'details': row['details'],
          'status': row['status'],
          'createdAt': row['created_at'],
        },
    ];
  }

  /// Retourne faux si le signalement n'existe pas.
  bool resolveReport(String reportId) {
    _db.raw.execute(
      "UPDATE user_reports SET status='resolved' WHERE id=?",
      [reportId],
    );
    return _db.raw.updatedRows > 0;
  }

  void _requireOtherExistingUser(String actorId, String targetId) {
    if (actorId == targetId) {
      throw ApiException('You cannot target yourself.', statusCode: 400);
    }
    final rows = _db.raw.select(
      'SELECT 1 FROM users WHERE id=? AND is_deleted=0',
      [targetId],
    );
    if (rows.isEmpty) throw ApiException('User not found.', statusCode: 404);
  }
}
