# GymTrack Backend — Guide de déploiement

## Prérequis

- Docker + Docker Compose (prod)
- Dart SDK ≥ 3.4 (dev local)

---

## Dev local

```bash
# Copier le fichier d'env et renseigner les valeurs
cp .env.example .env

# Installer les dépendances
dart pub get

# Lancer le serveur (mode dev, logs verbeux)
dart run bin/server.dart

# Tester
dart test
```

---

## Docker (production)

```bash
# 1. Préparer l'env
cp .env.example .env
# Éditer .env : GOOGLE_WEB_CLIENT_ID, CORS_ALLOWED_ORIGINS, etc.

# 2. Builder l'image
docker compose build

# 3. Démarrer
docker compose up -d

# 4. Vérifier
curl http://localhost:3000/health
```

La base SQLite est persistée dans un volume Docker (`gymtrack_data`).

---

## Variables d'environnement

| Variable | Défaut | Requis |
|---|---|---|
| `GOOGLE_WEB_CLIENT_ID` | — | ✅ |
| `ENV` | `development` | |
| `PORT` | `3000` | |
| `DATABASE_PATH` | `data/gymtrack.db` | |
| `CORS_ALLOWED_ORIGINS` | `*` | |
| `ACCESS_TOKEN_TTL_DAYS` | `30` | |
| `REFRESH_TOKEN_TTL_DAYS` | `90` | |
| `RATE_LIMIT_MAX_REQUESTS` | `60` | |
| `RATE_LIMIT_WINDOW_SECONDS` | `60` | |
| `AUTH_RATE_LIMIT_MAX_REQUESTS` | `10` | |
| `AUTH_RATE_LIMIT_WINDOW_SECONDS` | `60` | |

---

## Routes

| Méthode | Path | Auth | Description |
|---|---|---|---|
| GET | `/health` | Non | Status du serveur |
| POST | `/auth/google` | Non | Connexion Google OAuth |
| POST | `/auth/register` | Non | Inscription email/password |
| POST | `/auth/login` | Non | Connexion email/password |
| POST | `/auth/refresh` | Non | Renouveler les tokens |
| POST | `/auth/logout` | Bearer | Révoquer la session |
| GET | `/me` | Bearer | Profil courant |
| PUT | `/me/profile` | Bearer | Mettre à jour le profil |

---

## Migration BCrypt (automatique)

Les utilisateurs existants avec des mots de passe SHA-256 sont migrés transparentement au premier login réussi. Aucune action requise.

---

## Mise à jour

```bash
git pull
docker compose build --no-cache
docker compose up -d
```

Le volume SQLite est préservé entre les mises à jour.

---

## Logs

Les logs sont en JSON structuré sur stdout :

```json
{"level":"INFO","time":"...","message":"POST /auth/login 200 42ms","req_id":"...","status":200,"ms":42}
```

Pour les agréger : Datadog, Papertrail, Loki, ou `docker logs gymtrack-backend-1 --follow`.
