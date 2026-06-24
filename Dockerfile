# ── Stage 1 : build ──────────────────────────────────────────────────────────
FROM --platform=linux/amd64 dart:stable AS builder

WORKDIR /app

# Résoudre les dépendances en premier (layer cache-friendly)
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

# Copier le reste et compiler en exécutable natif AOT
COPY . .
RUN dart compile exe bin/server.dart -o bin/server

# ── Stage 2 : image minimale ──────────────────────────────────────────────────
FROM --platform=linux/amd64 debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libsqlite3-0 \
  && rm -rf /var/lib/apt/lists/* \
  && ln -sf /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 /usr/lib/x86_64-linux-gnu/libsqlite3.so

WORKDIR /app

COPY --from=builder /app/bin/server ./bin/server

# Répertoire pour la base SQLite montée en volume
RUN mkdir -p data

EXPOSE 3000

ENV ENV=production \
    PORT=3000 \
    DATABASE_PATH=/app/data/gymtrack.db

ENTRYPOINT ["./bin/server"]
