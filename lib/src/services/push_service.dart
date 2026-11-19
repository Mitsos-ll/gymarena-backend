import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:jose/jose.dart';

import '../db/app_database.dart';
import '../utils/logger.dart';

/// Envoi d'une notification à un téléphone. `false` : l'identifiant n'est
/// plus valide (app désinstallée, autorisation retirée…) et doit être oublié.
abstract class PushSender {
  Future<bool> send({
    required String token,
    required String title,
    required String body,
    required Map<String, String> data,
  });
}

/// Firebase Cloud Messaging (API v1), authentifié avec le compte de service
/// du projet Firebase.
class FcmPushSender implements PushSender {
  FcmPushSender._(this._account, this._client, this._now);

  /// [value] : le JSON du compte de service, brut ou en base64 (secret Fly
  /// `FIREBASE_SERVICE_ACCOUNT_B64`). `null` s'il est absent ou illisible :
  /// les notifications sont alors simplement désactivées.
  static FcmPushSender? fromServiceAccount(
    String value, {
    http.Client? client,
    DateTime Function()? now,
  }) {
    if (value.trim().isEmpty) return null;
    try {
      final text = value.trimLeft().startsWith('{') ? value : utf8.decode(base64.decode(value.trim()));
      final account = jsonDecode(text) as Map<String, dynamic>;
      for (final key in ['project_id', 'client_email', 'private_key']) {
        if (account[key] is! String) return null;
      }
      return FcmPushSender._(account, client ?? http.Client(), now ?? DateTime.now);
    } on FormatException catch (e, s) {
      logError('Firebase service account unreadable', e, s);
      return null;
    }
  }

  static const _scope = 'https://www.googleapis.com/auth/firebase.messaging';

  final Map<String, dynamic> _account;
  final http.Client _client;
  final DateTime Function() _now;
  String? _accessToken;
  DateTime _accessTokenExpiry = DateTime.fromMillisecondsSinceEpoch(0);

  String get projectId => _account['project_id'] as String;

  /// Jeton d'accès OAuth obtenu en échange d'un JWT signé avec la clé du
  /// compte de service ; gardé jusqu'à une minute avant son expiration.
  Future<String> _token() async {
    final now = _now();
    final cached = _accessToken;
    if (cached != null && _accessTokenExpiry.isAfter(now.add(const Duration(minutes: 1)))) return cached;

    final tokenUri = _account['token_uri'] as String? ?? 'https://oauth2.googleapis.com/token';
    final issuedAt = now.millisecondsSinceEpoch ~/ 1000;
    final key = JsonWebKey.fromPem(_account['private_key'] as String, keyId: _account['private_key_id'] as String?);
    final assertion = (JsonWebSignatureBuilder()
          ..jsonContent = {
            'iss': _account['client_email'],
            'scope': _scope,
            'aud': tokenUri,
            'iat': issuedAt,
            'exp': issuedAt + 3600,
          }
          ..addRecipient(key, algorithm: 'RS256'))
        .build()
        .toCompactSerialization();

    final response = await _client.post(Uri.parse(tokenUri), body: {
      'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      'assertion': assertion,
    });
    if (response.statusCode != 200) {
      throw StateError('Firebase OAuth HTTP ${response.statusCode}: ${response.body}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    _accessToken = json['access_token'] as String;
    _accessTokenExpiry = now.add(Duration(seconds: (json['expires_in'] as num?)?.toInt() ?? 3600));
    return _accessToken!;
  }

  @override
  Future<bool> send({
    required String token,
    required String title,
    required String body,
    required Map<String, String> data,
  }) async {
    final response = await _client.post(
      Uri.parse('https://fcm.googleapis.com/v1/projects/$projectId/messages:send'),
      headers: {
        'Authorization': 'Bearer ${await _token()}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'message': {
          'token': token,
          'notification': {'title': title, 'body': body},
          'data': data,
          // Canal « Coach » déjà créé par l'app pour ses notifications locales.
          'android': {
            'priority': 'HIGH',
            'notification': {'channel_id': 'coach_v1'},
          },
          'apns': {
            'payload': {
              'aps': {'sound': 'default'},
            },
          },
        },
      }),
    );
    if (response.statusCode == 200) return true;
    // Identifiant périmé ou inconnu. Une autre erreur 400 (message mal formé)
    // ne doit pas faire oublier un téléphone valide.
    if (response.statusCode == 404 ||
        response.body.contains('UNREGISTERED') ||
        response.body.contains('not a valid FCM registration token')) {
      return false;
    }
    logError('FCM send failed', 'HTTP ${response.statusCode}: ${response.body}', null);
    return true;
  }
}

/// Événements qui déclenchent une notification. [wireName] part dans les
/// données du message : l'app s'en sert pour ouvrir le bon écran.
enum PushEvent {
  coachNote('coach_note'),
  programAssigned('program_assigned'),
  inviteRequest('invite_request'),
  inviteAccepted('invite_accepted'),
  coachApproved('coach_approved');

  const PushEvent(this.wireName);
  final String wireName;
}

/// Langues des notifications ; une autre langue de téléphone reçoit le
/// français, langue source de l'app.
const pushLocales = {'fr', 'en', 'es'};

/// Titre et texte d'une notification, dans la langue du téléphone.
({String title, String body}) pushText(PushEvent event, String locale, Map<String, String> args) {
  String a(String key) => args[key] ?? '';
  final lang = pushLocales.contains(locale) ? locale : 'fr';
  return switch ((event, lang)) {
    (PushEvent.coachNote, 'en') => (title: 'Note from ${a('coach')}', body: a('note')),
    (PushEvent.coachNote, 'es') => (title: 'Nota de ${a('coach')}', body: a('note')),
    (PushEvent.coachNote, _) => (title: 'Note de ${a('coach')}', body: a('note')),
    (PushEvent.programAssigned, 'en') =>
      (title: 'New program', body: '${a('coach')} assigned you "${a('program')}"'),
    (PushEvent.programAssigned, 'es') =>
      (title: 'Nuevo programa', body: '${a('coach')} te asignó «${a('program')}»'),
    (PushEvent.programAssigned, _) =>
      (title: 'Nouveau programme', body: '${a('coach')} vous a assigné « ${a('program')} »'),
    (PushEvent.inviteRequest, 'en') => (title: 'New request', body: '${a('athlete')} wants to join you'),
    (PushEvent.inviteRequest, 'es') => (title: 'Nueva solicitud', body: '${a('athlete')} quiere unirse a ti'),
    (PushEvent.inviteRequest, _) => (title: 'Nouvelle demande', body: '${a('athlete')} souhaite vous rejoindre'),
    (PushEvent.inviteAccepted, 'en') => (title: 'Request accepted', body: '${a('coach')} accepted your request'),
    (PushEvent.inviteAccepted, 'es') => (title: 'Solicitud aceptada', body: '${a('coach')} aceptó tu solicitud'),
    (PushEvent.inviteAccepted, _) => (title: 'Demande acceptée', body: '${a('coach')} a accepté votre demande'),
    (PushEvent.coachApproved, 'en') =>
      (title: 'Coach profile approved', body: 'Open GymArena to start following your athletes.'),
    (PushEvent.coachApproved, 'es') =>
      (title: 'Perfil de entrenador aprobado', body: 'Abre GymArena para empezar a seguir a tus atletas.'),
    (PushEvent.coachApproved, _) =>
      (title: 'Profil coach validé', body: 'Ouvrez GymArena pour commencer à suivre vos athlètes.'),
  };
}

/// Notifie tous les téléphones d'un compte. Ne bloque ni ne fait échouer la
/// requête qui l'a déclenché (appeler sans `await`) ; sans compte de service
/// configuré, ne fait rien.
class PushNotifier {
  PushNotifier({required AppDatabase database, PushSender? sender})
      : _db = database,
        _sender = sender;

  final AppDatabase _db;
  final PushSender? _sender;

  /// Texte d'une note limité pour tenir dans une notification.
  static const maxNoteLength = 180;

  Future<void> notify(
    String userId,
    PushEvent event, {
    Map<String, String> args = const {},
    Map<String, String> data = const {},
  }) async {
    final sender = _sender;
    if (sender == null) return;
    final rows = _db.raw.select('SELECT token, locale FROM push_tokens WHERE user_id=?', [userId]);
    for (final row in rows) {
      final token = row['token'] as String;
      final text = pushText(event, row['locale'] as String? ?? 'fr', args);
      try {
        final valid = await sender.send(
          token: token,
          title: text.title,
          body: text.body,
          data: {'type': event.wireName, ...data},
        );
        if (!valid) _db.raw.execute('DELETE FROM push_tokens WHERE token=?', [token]);
      } catch (e, s) {
        logError('Push ${event.wireName} not sent', e, s);
      }
    }
  }

  static String clip(String text) =>
      text.length <= maxNoteLength ? text : '${text.substring(0, maxNoteLength - 1)}…';
}
