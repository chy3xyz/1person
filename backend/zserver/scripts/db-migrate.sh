#!/usr/bin/env bash
# Apply SQL migrations via the zserver binary's `migrate` subcommand.
#
# Usage: ./scripts/db-migrate.sh
# Requires DATABASE_URL (or ONEPERSON_DATABASE_URL). Builds the binary first if
# it's missing. This is the no-DB-fallback-friendly entrypoint: when no
# DATABASE_URL is configured, `zserver migrate` exits 0 with a clear message.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZSERVER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BIN="$ZSERVER_DIR/zig-out/bin/zserver"
if [ ! -x "$BIN" ]; then
    echo "==> zserver binary not found at $BIN; running 'zig build' first."
    ( cd "$ZSERVER_DIR" && zig build )
fi

cd "$ZSERVER_DIR"

if [ -z "${DATABASE_URL:-${ONEPERSON_DATABASE_URL:-}}" ]; then
    # Provide a sensible local default so this script works out of the box.
    export DATABASE_URL="postgres://1person:1person@localhost:5432/1person?sslmode=disable"
fi

echo "==> Running: $BIN migrate --db_url=\$DATABASE_URL"
"$BIN" migrate --db_url="$DATABASE_URL"