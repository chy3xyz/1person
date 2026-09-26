#!/usr/bin/env bash
set -euo pipefail

# Smoke test for zserver against a local Postgres + Redis.
# Usage: JWT_SECRET=... DATABASE_URL=... REDIS_URL=... ./scripts/smoke_test.sh

# Default port 18099 to avoid colliding with zetl (18080) or other
# dev servers on the host. Override with PORT=<n> to use a different
# free port.
PORT="${PORT:-18099}"
BASE="http://127.0.0.1:${PORT}"
JWT_SECRET="${JWT_SECRET:-test-secret}"
export JWT_SECRET

RED="\033[0;31m"
GREEN="\033[0;32m"
RESET="\033[0m"

failures=0

pass() {
    echo -e "${GREEN}PASS${RESET}: $1"
}

fail() {
    echo -e "${RED}FAIL${RESET}: $1"
    ((failures++)) || true
}

http_status() {
    curl -s -o /dev/null -w "%{http_code}" "$@"
}

http_body() {
    curl -s "$@"
}

# Build
echo "==> building zserver"
( cd "$(dirname "$0")/.." && zig build ) || { echo "build failed"; exit 1; }

# Start server
echo "==> starting zserver on port ${PORT}"
"$(dirname "$0")/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-smoke.log 2>&1 &
SERVER_PID=$!

cleanup() {
    echo "==> stopping zserver"
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Wait for it to be ready
for i in $(seq 1 30); do
    if [[ $(http_status "${BASE}/health") == "200" ]]; then
        break
    fi
    sleep 0.5
done

echo "==> running checks"

# Health / liveness
if [[ $(http_status "${BASE}/health") == "200" ]]; then
    pass "GET /health"
else
    fail "GET /health"
fi

# Readiness includes the migration check. When a database is configured this
# must be a hard 200 -- accepting 503 here would let a broken or un-migrated
# schema pass the smoke test silently.
ready_status=$(http_status "${BASE}/readyz")
if [[ -n "${DATABASE_URL:-}" ]]; then
    if [[ "${ready_status}" == "200" ]]; then
        pass "GET /readyz (200)"
    else
        fail "GET /readyz (expected 200, got ${ready_status}): $(http_body "${BASE}/readyz")"
        echo "      hint: apply migrations first: zig-out/bin/zserver migrate --db_url \"\${DATABASE_URL}\""
    fi
elif [[ "${ready_status}" == "503" ]]; then
    echo "SKIP: /readyz (no DATABASE_URL; server correctly reports not_ready)"
else
    fail "GET /readyz (no DATABASE_URL, expected 503, got ${ready_status})"
fi

# Public config
if [[ $(http_status "${BASE}/api/config") == "200" ]]; then
    pass "GET /api/config"
else
    fail "GET /api/config"
fi

# Auth flow (no-DB mode will still return valid responses)
email="smoke-$(date +%s)@example.com"
send_status=$(http_status -X POST -H "Content-Type: application/json" -d "{\"email\":\"${email}\"}" "${BASE}/auth/send-code")
if [[ "${send_status}" == "200" ]]; then
    pass "POST /auth/send-code"
else
    fail "POST /auth/send-code (${send_status})"
fi

# Verification code is logged when no SMTP is configured; use the no-DB fallback path
# with the deterministic ONEPERSON_DEV_VERIFICATION_CODE if available, otherwise skip.
TOKEN=""
DEV_CODE="${ONEPERSON_DEV_VERIFICATION_CODE:-${DEV_AUTH_CODE:-}}"
if [[ -n "${DEV_CODE}" ]]; then
    body=$(http_body -X POST -H "Content-Type: application/json" \
        -d "{\"email\":\"${email}\",\"code\":\"${DEV_CODE}\"}" "${BASE}/auth/verify-code")
    TOKEN=$(echo "${body}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)
    if [[ -n "${TOKEN}" ]]; then
        pass "POST /auth/verify-code"
    else
        fail "POST /auth/verify-code: ${body}"
    fi
else
    echo "SKIP: /auth/verify-code (set ONEPERSON_DEV_VERIFICATION_CODE to test)"
fi

if [[ -n "${TOKEN}" ]]; then
    AUTH="Authorization: Bearer ${TOKEN}"

    # /api/me
    me_body=$(http_body -H "${AUTH}" "${BASE}/api/me")
    if echo "${me_body}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'id' in d else 1)" 2>/dev/null; then
        pass "GET /api/me"
    else
        fail "GET /api/me: ${me_body}"
    fi

    # Workspace CRUD
    ws_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
        -d "{\"name\":\"Smoke Workspace\",\"slug\":\"smoke-$(date +%s)\"}" "${BASE}/api/workspaces")
    WS_ID=$(echo "${ws_body}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
    if [[ -n "${WS_ID}" ]]; then
        pass "POST /api/workspaces"
    else
        fail "POST /api/workspaces: ${ws_body}"
    fi

    if [[ -n "${WS_ID}" ]]; then
        if [[ $(http_status -H "${AUTH}" -H "X-Workspace-ID: ${WS_ID}" "${BASE}/api/workspaces/${WS_ID}") == "200" ]]; then
            pass "GET /api/workspaces/:id"
        else
            fail "GET /api/workspaces/:id"
        fi

        if [[ $(http_status -H "${AUTH}" -H "X-Workspace-ID: ${WS_ID}" "${BASE}/api/workspaces") == "200" ]]; then
            pass "GET /api/workspaces"
        else
            fail "GET /api/workspaces"
        fi

        # Invitations
        invite_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "X-Workspace-ID: ${WS_ID}" \
            -d "{\"email\":\"invite-$(date +%s)@example.com\",\"role\":\"member\"}" "${BASE}/api/workspaces/${WS_ID}/invitations")
        INVITE_ID=$(echo "${invite_body}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
        if [[ -n "${INVITE_ID}" ]]; then
            pass "POST /api/workspaces/:id/invitations"
        else
            fail "POST /api/workspaces/:id/invitations: ${invite_body}"
        fi

        if [[ $(http_status -H "${AUTH}" -H "X-Workspace-ID: ${WS_ID}" "${BASE}/api/workspaces/${WS_ID}/invitations") == "200" ]]; then
            pass "GET /api/workspaces/:id/invitations"
        else
            fail "GET /api/workspaces/:id/invitations"
        fi
    fi

    # WebSocket upgrade (no actual echo without a websocket client, just verify 101)
    if [[ -n "${WS_ID}" ]]; then
        ws_upgrade=$(curl -s -o /dev/null -w "%{http_code}" -m 2 \
            -H "Upgrade: websocket" -H "Connection: Upgrade" \
            -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \
            "${BASE}/ws?workspace_id=${WS_ID}&token=${TOKEN}" || true)
        if [[ "${ws_upgrade}" == "101" ]]; then
            pass "GET /ws (101 upgrade)"
        else
            fail "GET /ws (expected 101, got ${ws_upgrade})"
        fi
    fi
else
    echo "SKIP: protected endpoints (no token)"
fi

if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All checks passed${RESET}"
    exit 0
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
