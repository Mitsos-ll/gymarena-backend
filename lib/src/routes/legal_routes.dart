import 'package:shelf/shelf.dart';

/// Pages légales publiques (aucune authentification).
///
/// La politique de confidentialité est servie ici plutôt que sur un
/// hébergement tiers pour qu'elle reste versionnée avec le code qui décrit
/// réellement le traitement des données : un rejet Play Store (« Data
/// retention policy not specified ») vient d'une divergence entre les deux.
class LegalRoutes {
  static const contactEmail = 'dimitri.evanghelou@gmail.com';
  static const lastUpdated = '16 août 2026';

  Future<Response> privacyPolicy(Request request) async {
    return Response.ok(_html, headers: {'content-type': 'text/html; charset=utf-8'});
  }

  static const _style = '''
  body { font-family: -apple-system, Roboto, Arial, sans-serif; background:#0F1720; color:#E6EAF0;
         margin:0 auto; padding:40px 22px 80px; max-width:760px; line-height:1.65; font-size:16px; }
  h1 { font-size:26px; margin-bottom:4px; }
  h2 { font-size:19px; margin-top:36px; color:#fff; border-bottom:1px solid #24303D; padding-bottom:6px; }
  h3 { font-size:16px; margin-top:24px; color:#fff; }
  p, li { color:#B7C0CC; }
  a { color:#60A5FA; }
  .meta { color:#7C8899; font-size:14px; margin-top:0; }
  table { width:100%; border-collapse:collapse; margin-top:12px; font-size:15px; }
  th, td { text-align:left; padding:10px 8px; border-bottom:1px solid #24303D; vertical-align:top; }
  th { color:#fff; }
  hr { border:0; border-top:1px solid #24303D; margin:56px 0 40px; }
''';

  static const _html = '''
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>GymArena — Politique de confidentialité</title>
<style>$_style</style>
</head>
<body>

<h1>Politique de confidentialité — GymArena</h1>
<p class="meta">Dernière mise à jour : $lastUpdated · Application : GymArena (com.gymarena.app)</p>

<p>GymArena est une application de suivi d'entraînement sportif. Cette politique décrit
les données que l'application collecte, l'usage qui en est fait, les personnes avec qui
elles sont partagées, combien de temps elles sont conservées et comment les supprimer.</p>

<h2>1. Responsable du traitement</h2>
<p>GymArena est édité par un développeur indépendant. Pour toute question ou demande
relative à vos données : <a href="mailto:$contactEmail">$contactEmail</a>.</p>

<h2>2. Données collectées et finalités</h2>
<table>
  <tr><th>Catégorie</th><th>Données</th><th>Finalité</th></tr>
  <tr>
    <td>Compte</td>
    <td>Adresse e-mail, pseudo, mot de passe (stocké sous forme de hachage bcrypt, jamais en clair)
        ou identifiant Google si vous utilisez la connexion Google</td>
    <td>Créer et sécuriser votre compte, synchroniser vos données entre vos appareils</td>
  </tr>
  <tr>
    <td>Profil</td>
    <td>Prénom/pseudo affiché, sexe, date de naissance, taille, poids, objectif d'entraînement</td>
    <td>Personnaliser les calculs (calories, niveaux de force, statistiques)</td>
  </tr>
  <tr>
    <td>Entraînement</td>
    <td>Séances, exercices, séries (poids, répétitions, RPE, temps de repos), programmes,
        historique de poids et mensurations, records personnels</td>
    <td>Fonction principale de l'application : enregistrer et analyser votre progression</td>
  </tr>
  <tr>
    <td>Santé (facultatif)</td>
    <td>Fréquence cardiaque, calories actives, pas et sessions d'exercice lus depuis
        Health Connect (Android) ou Apple HealthKit (iOS), uniquement si vous accordez
        explicitement l'autorisation</td>
    <td>Enrichir le récapitulatif de vos séances</td>
  </tr>
  <tr>
    <td>Social (facultatif)</td>
    <td>Relations d'amitié, séances et programmes que vous choisissez de partager,
        liens coach/athlète</td>
    <td>Fonctions communautaires : amis, défis, suivi par un coach</td>
  </tr>
  <tr>
    <td>Photos (facultatif)</td>
    <td>Photos de séance et de progression que vous ajoutez</td>
    <td>Suivi visuel de votre progression et création de visuels partageables</td>
  </tr>
  <tr>
    <td>Technique</td>
    <td>Jetons de session, journaux d'erreurs techniques</td>
    <td>Maintenir votre connexion et diagnostiquer les pannes</td>
  </tr>
</table>

<h3>Données qui ne quittent jamais votre téléphone</h3>
<p>Les <strong>données de santé</strong> (fréquence cardiaque, calories, pas) et vos
<strong>photos</strong> sont stockées uniquement en local, sur votre appareil. Elles ne
sont ni transmises à nos serveurs, ni sauvegardées en ligne, ni partagées avec des tiers.
Elles disparaissent lorsque vous désinstallez l'application ou effacez les données de
l'application depuis les réglages de votre téléphone.</p>

<h3>Ce que nous ne collectons pas</h3>
<p>GymArena ne collecte pas votre position géographique, ne diffuse pas de publicité,
n'utilise pas de traceurs publicitaires et ne revend aucune donnée.</p>

<h2>3. Partage des données</h2>
<ul>
  <li><strong>Autres utilisateurs</strong> : uniquement ce que vous décidez de partager
      (séances, programmes, profil communautaire). Vous contrôlez la visibilité dans les
      réglages de confidentialité de l'application, et vous pouvez retirer un ami à tout moment.</li>
  <li><strong>Votre coach</strong> : si vous acceptez un lien coach/athlète, celui-ci accède
      à vos séances et programmes. Rompre le lien met fin à cet accès.</li>
  <li><strong>Hébergeur</strong> : les données synchronisées sont hébergées sur
      Fly.io, dans un centre de données situé à Paris (France), qui agit comme
      sous-traitant technique.</li>
  <li><strong>Connexion Google</strong> : si vous utilisez la connexion Google, Google nous
      transmet votre adresse e-mail et votre identifiant de compte pour vous authentifier.</li>
  <li><strong>E-mails transactionnels</strong> : le service Resend envoie les e-mails de
      réinitialisation de mot de passe.</li>
</ul>
<p>Aucune donnée n'est vendue, louée ni transmise à des courtiers en données ou à des
régies publicitaires.</p>

<h2>4. Conservation des données</h2>
<p>Nous conservons vos données uniquement le temps nécessaire aux finalités décrites ci-dessus :</p>
<table>
  <tr><th>Donnée</th><th>Durée de conservation</th></tr>
  <tr>
    <td>Compte, profil, séances, programmes, mensurations, données communautaires</td>
    <td>Conservés tant que votre compte existe. Supprimés définitivement dès la suppression
        du compte (voir section 5).</td>
  </tr>
  <tr>
    <td>Jetons de session</td>
    <td>Jeton d'accès : 30 jours. Jeton de rafraîchissement : 90 jours. Purgés automatiquement
        à expiration ou immédiatement à la déconnexion.</td>
  </tr>
  <tr>
    <td>Codes de réinitialisation de mot de passe</td>
    <td>15 minutes, puis expiration et suppression.</td>
  </tr>
  <tr>
    <td>Codes d'invitation entre amis</td>
    <td>30 jours, puis expiration et suppression.</td>
  </tr>
  <tr>
    <td>Données de santé et photos</td>
    <td>Stockage local uniquement, sous votre contrôle. Aucune conservation de notre côté.
        Effacées avec la désinstallation de l'application.</td>
  </tr>
  <tr>
    <td>Journaux techniques d'erreur</td>
    <td>Maximum 30 jours, puis suppression automatique.</td>
  </tr>
  <tr>
    <td>Sauvegardes chiffrées de la base</td>
    <td>Rotation sur 30 jours maximum. Les données d'un compte supprimé disparaissent
        donc au plus tard 30 jours après la suppression.</td>
  </tr>
</table>

<h2>5. Suppression de vos données</h2>
<p>Vous pouvez supprimer votre compte à tout moment, directement depuis l'application :
<strong>Mon compte → Supprimer mon compte</strong>.</p>
<p>Cette action est <strong>immédiate et irréversible</strong> : elle efface votre compte
et l'intégralité des données associées sur nos serveurs (séances, exercices, programmes,
mensurations, historique de poids, relations d'amitié, partages, liens coach). Aucune
période de rétention n'est appliquée, hormis la disparition des sauvegardes chiffrées
sous 30 jours décrite ci-dessus.</p>
<p>Les données stockées localement (santé, photos) s'effacent en désinstallant
l'application ou via « Effacer les données » dans les réglages Android/iOS.</p>
<p>Vous pouvez également demander la suppression par e-mail à
<a href="mailto:$contactEmail">$contactEmail</a> ; nous traitons la demande sous 30 jours.</p>

<h2>6. Vos droits</h2>
<p>Conformément au RGPD, vous disposez d'un droit d'accès, de rectification, d'effacement,
de limitation, d'opposition et de portabilité de vos données. La plupart de ces droits
s'exercent directement dans l'application (modification du profil, suppression du compte).
Pour toute autre demande, écrivez à <a href="mailto:$contactEmail">$contactEmail</a>.
Vous pouvez également introduire une réclamation auprès de la CNIL.</p>

<h2>7. Sécurité</h2>
<p>Les échanges entre l'application et nos serveurs sont chiffrés en HTTPS/TLS. Les mots
de passe sont hachés avec bcrypt et ne sont jamais stockés en clair. Les jetons de session
sont stockés sous forme de hachage côté serveur et dans le stockage sécurisé du système
(Keychain / Keystore) côté application.</p>

<h2>8. Enfants</h2>
<p>GymArena n'est pas destiné aux enfants de moins de 13 ans et ne collecte pas
sciemment leurs données. Si vous constatez qu'un tel compte existe, contactez-nous
et nous le supprimerons.</p>

<h2>9. Modifications</h2>
<p>Cette politique peut évoluer. La date de dernière mise à jour figure en haut de page.
Toute modification substantielle sera signalée dans l'application.</p>

<hr>

<h1>Privacy Policy — GymArena (English)</h1>
<p class="meta">Last updated: August 16, 2026 · App: GymArena (com.gymarena.app)</p>

<p>GymArena is a strength-training tracking app. This policy explains what data the app
collects, why, who it is shared with, how long it is kept, and how to delete it.</p>

<h2>1. Data we collect</h2>
<ul>
  <li><strong>Account</strong>: email address, username, password (stored only as a bcrypt hash),
      or your Google account identifier if you sign in with Google.</li>
  <li><strong>Profile</strong>: display name, sex, date of birth, height, weight, training goal.</li>
  <li><strong>Training data</strong>: workouts, exercises, sets (weight, reps, RPE, rest),
      programs, weight and body-measurement history, personal records.</li>
  <li><strong>Health data (optional)</strong>: heart rate, active calories, steps and exercise
      sessions read from Health Connect (Android) or Apple HealthKit (iOS), only with your
      explicit permission.</li>
  <li><strong>Social data (optional)</strong>: friendships, workouts and programs you choose
      to share, coach/athlete links.</li>
  <li><strong>Photos (optional)</strong>: workout and progress photos you add.</li>
  <li><strong>Technical</strong>: session tokens and error logs.</li>
</ul>
<p><strong>Health data and photos never leave your device.</strong> They are stored locally
only, never uploaded to our servers and never shared with third parties.</p>
<p>We do not collect location data, do not serve ads, do not use advertising trackers,
and never sell your data.</p>

<h2>2. Sharing</h2>
<p>Data is shared only with: other users, strictly limited to what you choose to share;
your coach, if you accept a coach/athlete link; Fly.io, our hosting provider; Google,
if you use Google Sign-In; and Resend, which sends password-reset emails. Nothing is sold
or shared with data brokers or advertisers.</p>

<h2>3. Data retention</h2>
<ul>
  <li><strong>Account, profile, workouts, programs, measurements, social data</strong>:
      kept for as long as your account exists; permanently deleted when you delete your account.</li>
  <li><strong>Session tokens</strong>: access token 30 days, refresh token 90 days; purged
      on expiry or immediately on logout.</li>
  <li><strong>Password-reset codes</strong>: 15 minutes.</li>
  <li><strong>Friend invite codes</strong>: 30 days.</li>
  <li><strong>Health data and photos</strong>: stored on your device only; we retain nothing.</li>
  <li><strong>Technical error logs</strong>: 30 days maximum.</li>
  <li><strong>Encrypted database backups</strong>: rotated within 30 days, so deleted account
      data disappears from backups within 30 days at the latest.</li>
</ul>

<h2>4. Deleting your data</h2>
<p>You can delete your account at any time from the app: <strong>My account →
Delete my account</strong>. Deletion is immediate and irreversible, and erases your account
and all associated server-side data. Locally stored data (health, photos) is removed by
uninstalling the app or clearing app data. You may also request deletion by email at
<a href="mailto:$contactEmail">$contactEmail</a>; we respond within 30 days.</p>

<h2>5. Your rights</h2>
<p>Under the GDPR you have rights of access, rectification, erasure, restriction, objection
and portability. Most can be exercised directly in the app. For anything else, contact
<a href="mailto:$contactEmail">$contactEmail</a>.</p>

<h2>6. Security</h2>
<p>All traffic is encrypted over HTTPS/TLS. Passwords are hashed with bcrypt. Session tokens
are stored hashed on the server and in the platform secure storage (Keychain / Keystore)
on the device.</p>

<h2>7. Children</h2>
<p>GymArena is not intended for children under 13 and does not knowingly collect their data.</p>

<h2>8. Contact</h2>
<p><a href="mailto:$contactEmail">$contactEmail</a></p>

</body>
</html>
''';
}
