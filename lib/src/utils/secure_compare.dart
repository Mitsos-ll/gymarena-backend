import 'dart:convert';

/// Compare deux chaînes en temps constant (indépendant du point de première
/// différence), pour éviter une attaque temporelle sur la comparaison d'un
/// secret (ex: `ADMIN_SECRET`). Une comparaison `==` standard sort dès le
/// premier octet différent, ce qui fuit — en théorie, sur un grand nombre de
/// requêtes — la position du préfixe correct.
bool constantTimeEquals(String a, String b) {
  final bytesA = utf8.encode(a);
  final bytesB = utf8.encode(b);

  // La longueur elle-même n'est pas secrète ici (ADMIN_SECRET a une longueur
  // fixe connue), donc renvoyer tôt sur une longueur différente ne réintroduit
  // pas de canal utile — seule la comparaison octet-par-octet d'un secret de
  // même longueur doit être à temps constant.
  if (bytesA.length != bytesB.length) return false;

  var diff = 0;
  for (var i = 0; i < bytesA.length; i++) {
    diff |= bytesA[i] ^ bytesB[i];
  }
  return diff == 0;
}
