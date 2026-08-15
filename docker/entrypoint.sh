#!/bin/sh
set -e

# zserver backend container entrypoint: apply SQL migrations (idempotent,
# fails fast on connection problems), then start the API server.
# DATABASE_URL must be provided by the environment.
cd /app

echo "Running database migrations..."
./zserver migrate

echo "Starting server..."
exec ./zserver server
