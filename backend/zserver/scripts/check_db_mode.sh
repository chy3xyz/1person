#!/usr/bin/env bash
# Assert the database-mode rules the scripts and the server must agree on.
#
# `src/config.zig` resolves DATABASE_URL like this:
#
#   --db-url flag      → that URL
#   DATABASE_URL set   → that value, even the empty string
#   DATABASE_URL unset → the built-in default connection string
#
# The e2e scripts used to read the variable with `${DATABASE_URL:-}`,
# which cannot tell "unset" from "empty" and so disagreed with the
# server about which database was in play. Two failures came out of
# that: the teardown skipped the cleanup and left test accounts behind,
# and the smoke test demanded a 503 from a server that was connected.
#
# This script pins the rules down, so the next script that reaches for
# the variable by hand fails here instead of in a leftover test account.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/e2e_db.sh"

failures=0

check() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        echo "ok - ${label}"
    else
        echo "not ok - ${label}: expected '${expected}', got '${actual}'" >&2
        failures=$((failures + 1))
    fi
}

# Each case runs in a subshell so the cases stay independent of each
# other and of the environment the script was started with.

result="$(unset DATABASE_URL; e2e_database_url)"
check "an unset DATABASE_URL resolves to the default database" \
    "${E2E_DEFAULT_DATABASE_URL}" "${result}"

result="$(unset DATABASE_URL; e2e_database_enabled && echo yes || echo no)"
check "an unset DATABASE_URL means database mode" "yes" "${result}"

result="$(export DATABASE_URL=''; e2e_database_url)"
check "an empty DATABASE_URL resolves to no database" "" "${result}"

result="$(export DATABASE_URL=''; e2e_database_enabled && echo yes || echo no)"
check "an empty DATABASE_URL means no-DB mode" "no" "${result}"

result="$(export DATABASE_URL='postgres://example.test/db'; e2e_database_url)"
check "a set DATABASE_URL resolves to that URL" "postgres://example.test/db" "${result}"

result="$(export DATABASE_URL='postgres://example.test/db'; e2e_database_enabled && echo yes || echo no)"
check "a set DATABASE_URL means database mode" "yes" "${result}"

if [[ ${failures} -eq 0 ]]; then
    echo "check-db-mode: the database-mode rules hold"
    exit 0
fi

echo "check-db-mode: ${failures} rule(s) broken" >&2
exit 1
