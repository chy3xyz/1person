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
source "${SCRIPT_DIR}/lib/e2e_db.sh"

BIN="$ZSERVER_DIR/zig-out/bin/zserver"
if [ ! -x "$BIN" ]; then
    echo "==> zserver binary not found at $BIN; running 'zig build' first."
    ( cd "$ZSERVER_DIR" && zig build )
fi

cd "$ZSERVER_DIR"

# Resolve the database to migrate.
#
# `zserver migrate` does NOT fall back to a default the way the server
# does: an unset DATABASE_URL means "no database" there and the command
# exits 0 without touching anything. So this script fills in the local
# default itself — but only when the variable is genuinely unset. An
# explicitly empty DATABASE_URL is the "no-DB mode" switch and has to
# reach the binary as it is, otherwise the migration silently runs
# against the default database instead of doing nothing.
if [[ -n "${DATABASE_URL+x}" ]]; then
    : # set — including the empty string, which means "no database"
elif [[ -n "${ONEPERSON_DATABASE_URL+x}" ]]; then
    export DATABASE_URL="${ONEPERSON_DATABASE_URL}"
else
    export DATABASE_URL="${E2E_DEFAULT_DATABASE_URL}"
fi

echo "==> Running: $BIN migrate --db_url=\$DATABASE_URL"
"$BIN" migrate --db_url="$DATABASE_URL"