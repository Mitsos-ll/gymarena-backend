import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Hash SHA-256 d'un token de session. Fonction partagée entre
/// [SessionService] (émission) et la migration de [AppDatabase] qui hashe
/// les tokens existants — les deux doivent produire strictement le même
/// résultat pour qu'une session déjà émise reste valide après migration.
String hashToken(String token) => sha256.convert(utf8.encode(token)).toString();
