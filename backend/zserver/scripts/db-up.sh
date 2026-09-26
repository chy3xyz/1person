#!/usr/bin/env bash
# Bring up a local Postgres for zserver via docker compose, wait until it's
# ready, and ensure the configured database exists.
#
# Usage: ./scripts/db-up.sh
# Honors POSTGRES_DB / POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_PORT from
# the environment (or .env at the repo root). DATABASE_URL is preferred when
# set, in which case docker is only used for local hosts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZSERVER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ZSERVER_DIR/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/docker-compose.yml"

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "==> docker-compose.yml not found at $COMPOSE_FILE; skipping docker bring-up."
    exit 0
fi

# Probe the docker daemon so we degrade gracefully on hosts where the
# `docker` binary is on PATH but the daemon isn't running (e.g. a CI
# runner without a docker socket, or a developer machine that hasn't
# started colima/orbstack yet). `docker info` exits non-zero on a
# disconnected daemon.
if ! command -v docker >/dev/null 2>&1; then
    echo "==> docker not available, skipping make db-up"
    exit 0
fi
if ! docker info >/dev/null 2>&1; then
    echo "==> docker daemon unreachable, skipping make db-up (start colima/orbstack or run a real PG to enable)"
    exit 0
fi

# Best-effort load of repo-root .env so DATABASE_URL and POSTGRES_* are honored.
if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$REPO_ROOT/.env"
    set +a
fi

POSTGRES_DB="${POSTGRES_DB:-1person}"
POSTGRES_USER="${POSTGRES_USER:-1person}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-1person}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"

echo "==> Bringing up local PostgreSQL via docker compose (port ${POSTGRES_PORT})..."
docker compose -f "$COMPOSE_FILE" up -d postgres

echo "==> Waiting for PostgreSQL to be ready..."
until docker compose -f "$COMPOSE_FILE" exec -T postgres \
    pg_isready -U "$POSTGRES_USER" -d postgres > /dev/null 2>&1; do
    sleep 1
done

echo "==> Ensuring database '$POSTGRES_DB' exists..."
db_exists="$(docker compose -f "$COMPOSE_FILE" exec -T postgres \
    psql -U "$POSTGRES_USER" -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname = '$POSTGRES_DB'")"

if [ "$db_exists" != "1" ]; then
    docker compose -f "$COMPOSE_FILE" exec -T postgres \
        psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE \"$POSTGRES_DB\"" > /dev/null
fi

echo "✓ PostgreSQL ready. Database: $POSTGRES_DB"