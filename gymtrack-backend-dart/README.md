# GymTrack Backend (Dart)

Backend minimal prêt pour :
- `POST /auth/google`
- `GET /me`
- `PUT /me/profile`
- `POST /auth/refresh`
- `POST /auth/logout`

## Structure

```txt
bin/
  server.dart
lib/
  src/
    app.dart
    config.dart
    db/
      app_database.dart
    models/
      api_profile.dart
      api_session.dart
      api_user.dart
    repositories/
      user_repository.dart
    routes/
      auth_routes.dart
      me_routes.dart
    services/
      google_token_service.dart
      session_service.dart
    utils/
      api_exception.dart
      http_json.dart
```

## Variables d'environnement

- `GOOGLE_WEB_CLIENT_ID` : obligatoire
- `PORT` : optionnel, défaut `3000`
- `DATABASE_PATH` : optionnel, défaut `data/gymtrack.db`
- `ACCESS_TOKEN_TTL_DAYS` : optionnel, défaut `30`
- `REFRESH_TOKEN_TTL_DAYS` : optionnel, défaut `90`

## Lancer le backend sur Windows PowerShell

Depuis la racine du dossier backend :

```powershell
$env:GOOGLE_WEB_CLIENT_ID="698060491101-il1esdiu6u7asos3mmqbkboeumor3bhm.apps.googleusercontent.com"
$env:PORT="3000"
C:\flutter\flutter\bin\dart.bat pub get
C:\flutter\flutter\bin\dart.bat run bin/server.dart
```

## Vérification

Quand le serveur tourne, teste :

```text
http://192.168.68.54:3000/health
```

Si ton téléphone et ton PC sont sur le même réseau, l'app Flutter peut appeler :

```text
http://192.168.68.54:3000/auth/google
```

## Remarque

Ce backend est minimal et pratique pour le développement local. Pour une version production, on pourra ensuite renforcer la gestion des sessions et vérifier les tokens Google de manière encore plus stricte.
