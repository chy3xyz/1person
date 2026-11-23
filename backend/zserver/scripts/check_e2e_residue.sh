#!/usr/bin/env bash
# Fail when the e2e suites left test data behind.
#
# Every e2e run signs up a throwaway account on a test-fixture domain and
# creates workspaces with it. The scripts delete that data again in their
# teardown (see scripts/lib/e2e_cleanup.sh), so a finished suite must leave
# no account and no workspace behind — the shared development database
# used to accumulate them until the workspace list was mostly residue.
#
# Usage:
#   DATABASE_URL=postgres://... ./scripts/check_e2e_residue.sh
#
# The check runs against the database the server would use: an unset
# DATABASE_URL means the built-in default database (the server connected
# to it), the empty string means the server ran without a database and
# there is nothing to check.
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/e2e_db.sh"

db_url="$(e2e_database_url)"
if [[ -z "${db_url}" ]]; then
    echo "check-e2e-residue: DATABASE_URL is empty — the server ran without a database, nothing persisted"
    exit 0
fi
command -v psql >/dev/null 2>&1 || { echo "check-e2e-residue: psql not available"; exit 0; }

# The domains the e2e scripts sign up on. A developer account never lives
# here, so anything left on them is residue.
read -r -d '' DOMAIN_FILTER <<'SQL' || true
email LIKE '%@example.com'
   OR email LIKE '%@e.com'
   OR email LIKE '%@test.local'
SQL

LEFTOVER_WORKSPACES=$(psql "${db_url}" -v ON_ERROR_STOP=1 -tAc "
    SELECT count(*)
      FROM workspace w
      JOIN \"member\" m ON m.workspace_id = w.id AND m.role = 'owner'
      JOIN \"user\" u ON u.id = m.user_id
     WHERE ${DOMAIN_FILTER};" 2>/dev/null || echo "?")

LEFTOVER_USERS=$(psql "${db_url}" -v ON_ERROR_STOP=1 -tAc "
    SELECT count(*) FROM \"user\" u WHERE ${DOMAIN_FILTER};" 2>/dev/null || echo "?")

if [[ "${LEFTOVER_WORKSPACES}" == "0" && "${LEFTOVER_USERS}" == "0" ]]; then
    echo "check-e2e-residue: clean — no test workspace or account left behind"
    exit 0
fi

# A query that could not run says nothing about residue, but it also
# cannot prove there is none — so the check still fails, with a message
# that names the real problem instead of counting "?".
if [[ "${LEFTOVER_WORKSPACES}" == "?" || "${LEFTOVER_USERS}" == "?" ]]; then
    echo "check-e2e-residue: FAILED — could not query the database, so residue could not be ruled out" >&2
    psql "${db_url}" -c "SELECT 1" >&2 || true
    exit 1
fi

echo "check-e2e-residue: FAILED — the e2e suites left ${LEFTOVER_WORKSPACES} workspace(s) and ${LEFTOVER_USERS} account(s) behind" >&2
psql "${db_url}" -v ON_ERROR_STOP=1 -tAc "
    SELECT w.slug || '  (' || u.email || ')'
      FROM workspace w
      JOIN \"member\" m ON m.workspace_id = w.id AND m.role = 'owner'
      JOIN \"user\" u ON u.id = m.user_id
     WHERE ${DOMAIN_FILTER};" >&2 2>/dev/null || true
echo "check-e2e-residue: every e2e script must call e2e_cleanup_user in its teardown" >&2
exit 1
