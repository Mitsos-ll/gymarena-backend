/// Fournisseur d'identité externe. `name` est la valeur stockée dans
/// `user_auth_accounts.provider`.
enum OAuthProvider { google, apple }

/// Identité déjà vérifiée par le service de token du fournisseur, normalisée
/// pour que la connexion/inscription soit la même quel que soit le fournisseur.
class OAuthIdentity {
  const OAuthIdentity({
    required this.provider,
    required this.subject,
    required this.email,
    required this.emailVerified,
    required this.displayName,
    this.photoUrl,
  });

  final OAuthProvider provider;
  final String subject;

  /// Toujours présent avec Google. Apple peut ne pas en fournir.
  final String? email;
  final bool emailVerified;

  /// Pseudo par défaut, utilisé uniquement à la création du profil.
  final String displayName;
  final String? photoUrl;

  /// Google fait foi pour l'email et la photo à chaque connexion. Apple ne
  /// fournit pas de photo et peut masquer l'email derrière un relais : il ne
  /// doit jamais écraser ceux déjà enregistrés.
  bool get refreshesUserProfile => provider == OAuthProvider.google;
}
