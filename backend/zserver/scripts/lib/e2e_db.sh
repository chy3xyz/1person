#!/usr/bin/env bash
# The database the zserver actually talks to.
#
# `src/config.zig` resolves DATABASE_URL like this:
#
#   --db-url flag      → that URL
#   DATABASE_URL set   → that value, even when it is the empty string
#   DATABASE_URL unset → the built-in default connection string
#
# So "unset" and "set to the empty string" mean two different things:
# unset means the default database, the empty string means no database at
# all (`src/server.zig` treats an empty db_url as no-DB mode).
#
# Reading the variable with `${DATABASE_URL:-}` collapses the two — `:-`
# substitutes the fallback for an empty value just as it does for a
# missing one. A script that does that believes the server runs without
# a database while it is happily writing to the default one. Two failures
# came out of that:
#
#   - the e2e teardown skipped the cleanup and left test accounts and
#     workspaces behind in the shared development database;
#   - the smoke test demanded a 503 from a server that was connected,
#     healthy and reporting ready.
#
# Use these helpers instead of reading DATABASE_URL directly:
#
#   e2e_database_url      → the URL the server connects to (empty = no DB)
#   e2e_database_enabled  → true when the server runs with a database
#
# A script that launches the server may pin the mode itself (the e2e
# suites set DATABASE_URL to the empty string to force no-DB mode). The
# helpers report whatever the server is going to see, so a pin that is
# applied before the call is respected automatically.

# The same default `src/config.zig` falls back to. Overridable so a test
# harness can point the helpers at a different one.
E2E_DEFAULT_DATABASE_URL="${E2E_DEFAULT_DATABASE_URL:-postgres://1person:1person@localhost:5432/1person?sslmode=disable}"

# Print the URL the server connects to, or nothing when it runs without a
# database.
e2e_database_url() {
    if [[ -z "${DATABASE_URL+x}" ]]; then
        printf '%s' "${E2E_DEFAULT_DATABASE_URL}"
        return 0
    fi
    printf '%s' "${DATABASE_URL}"
}

# True when the server runs with a database.
e2e_database_enabled() {
    [[ -n "$(e2e_database_url)" ]]
}
