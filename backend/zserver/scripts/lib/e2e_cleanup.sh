#!/usr/bin/env bash
# Shared teardown for the e2e scripts.
#
# Every e2e run signs up a throwaway account (`<prefix>-<epoch>@<domain>`)
# and creates one or more workspaces with it. The scripts used to stop the
# server and leave those rows behind: in the shared development database the
# workspace list grew into a wall of test residue (76 stale workspaces and
# 55 stale accounts after a few dozen local runs), and every run made the
# list slower to load and harder to tell apart from real work.
#
# `e2e_cleanup_user <email> [<email> ...]` removes everything that belongs
# to those accounts: first the workspaces (the foreign keys cascade), then
# the rows that would otherwise block the account delete, then the account
# itself.
#
# It removes the rows from the database the server actually used, and it
# never fails the calling script: a cleanup problem must not turn a
# passing run into a failing one.
#
# Which database that is depends on how DATABASE_URL was set: unset means
# the server's built-in default database, the empty string means it ran
# without a database at all (and then nothing was persisted). The
# helpers in `e2e_db.sh` resolve that the same way `src/config.zig`
# does — a plain `-n "${DATABASE_URL:-}"` test cannot tell the two apart
# and used to skip the cleanup while the server had written to the
# default database.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e2e_db.sh"

# The account's workspaces. Their children (issues, comments, agents, …)
# cascade from here.
e2e_cleanup_workspaces() {
    local db_url
    db_url="$(e2e_database_url)"
    [[ -n "${db_url}" ]] || return 0
    psql "${db_url}" -v ON_ERROR_STOP=1 -v e2e_email="${1:-}" -q <<'SQL' >/dev/null 2>&1 || true
DELETE FROM workspace
 WHERE id IN (
    SELECT w.id
      FROM workspace w
      JOIN "member" m ON m.workspace_id = w.id AND m.role = 'owner'
      JOIN "user" u ON u.id = m.user_id
     WHERE u.email = :'e2e_email'
 );
SQL
}

# Rows that reference the account directly and are declared NO ACTION, so
# they have to go before the account does.
e2e_cleanup_account_refs() {
    local db_url
    db_url="$(e2e_database_url)"
    [[ -n "${db_url}" ]] || return 0
    psql "${db_url}" -v ON_ERROR_STOP=1 -v e2e_email="${1:-}" -q <<'SQL' >/dev/null 2>&1 || true
DELETE FROM workspace_invitation WHERE invitee_user_id IN (SELECT id FROM "user" WHERE email = :'e2e_email')
                                    OR inviter_id     IN (SELECT id FROM "user" WHERE email = :'e2e_email');
DELETE FROM agent_runtime        WHERE owner_id       IN (SELECT id FROM "user" WHERE email = :'e2e_email');
DELETE FROM agent                WHERE owner_id       IN (SELECT id FROM "user" WHERE email = :'e2e_email')
                                    OR archived_by     IN (SELECT id FROM "user" WHERE email = :'e2e_email');
DELETE FROM skill                WHERE created_by     IN (SELECT id FROM "user" WHERE email = :'e2e_email');
DELETE FROM lark_installation    WHERE installer_user_id IN (SELECT id FROM "user" WHERE email = :'e2e_email');
SQL
}

# The account itself. Everything else cascades from here.
e2e_cleanup_account() {
    local db_url
    db_url="$(e2e_database_url)"
    [[ -n "${db_url}" ]] || return 0
    psql "${db_url}" -v ON_ERROR_STOP=1 -v e2e_email="${1:-}" -q <<'SQL' >/dev/null 2>&1 || true
DELETE FROM "user" WHERE email = :'e2e_email';
SQL
}

# Remove everything an e2e run created for one or more accounts.
#
# Usage: e2e_cleanup_user "$EMAIL" ["$EMAIL2" ...]
#
# Takes a list of accounts on purpose. A suite with two members calls it
# once with both addresses; writing two separate calls instead would put
# them on one line, where bash reads the second call as extra arguments of
# the first one and silently skips the second account.
e2e_cleanup_user() {
    local email
    local db_url
    # Resolve the database the way the server does: an unset DATABASE_URL
    # is the built-in default database, an empty one means the server ran
    # without a database and nothing was persisted.
    db_url="$(e2e_database_url)"
    [[ -n "${db_url}" ]] || return 0
    command -v psql >/dev/null 2>&1 || return 0
    for email in "$@"; do
        # An address is what a lookup can match; anything else (an empty
        # variable, a stray word) is not an account and must not be run
        # through the database.
        [[ "${email}" == *@* ]] || continue
        e2e_cleanup_workspaces "${email}"
        e2e_cleanup_account_refs "${email}"
        e2e_cleanup_account "${email}"
    done
    return 0
}
