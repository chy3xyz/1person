#!/usr/bin/env bash
# End-to-end HTTP regression test for the connector module.
#
# Boots a fresh zserver (no-DB mode), authenticates a dev user,
# creates a scratch workspace, and exercises the public endpoints
# in `src/modules/connector/routes.zig`.
#
# Usage:
#   MULTICA_DEV_VERIFICATION_CODE=000000 \
#   JWT_SECRET=test-secret \
#   ./scripts/connector_e2e.sh
#
# Override the port with PORT=<n>.

set -euo pipefail

PORT="${PORT:-18098}"
BASE="http://127.0.0.1:${PORT}"
JWT_SECRET="${JWT_SECRET:-test-secret}"
export JWT_SECRET

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RESET="\033[0m"

failures=0
pass() { echo -e "${GREEN}PASS${RESET}: $1"; }
fail() { echo -e "${RED}FAIL${RESET}: $1"; ((failures++)) || true; }
warn() { echo -e "${YELLOW}WARN${RESET}: $1"; }

http_status() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
http_body() { curl -s "$@"; }

jget_path() {
    local body="$1" path="$2"
    echo "${body}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for k in '${path}'.split('.'):
    if isinstance(d, dict) and k in d:
        d = d[k]
    else:
        print(''); sys.exit(0)
print(d if not isinstance(d, (dict, list)) else json.dumps(d))
" 2>/dev/null || true
}

# Build
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "==> building zserver"
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }

# Start server
echo "==> starting zserver on port ${PORT}"
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-connector-e2e.log 2>&1 &
SERVER_PID=$!

cleanup() {
    echo "==> stopping zserver"
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for i in $(seq 1 30); do
    if [[ $(http_status "${BASE}/health") == "200" ]]; then break; fi
    sleep 0.5
done
if [[ $(http_status "${BASE}/health") != "200" ]]; then
    warn "/health never came up; tail of server log:"
    tail -50 /tmp/zserver-connector-e2e.log
    exit 1
fi

# ─── Authenticate dev user ───────────────────────────────────────────
EMAIL="connector-e2e-$(date +%s)@example.com"
http_status -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${EMAIL}\"}" "${BASE}/auth/send-code" >/dev/null
code="${MULTICA_DEV_VERIFICATION_CODE:-000000}"
auth_body=$(http_body -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${EMAIL}\",\"code\":\"${code}\"}" "${BASE}/auth/verify-code")
TOKEN=$(jget_path "${auth_body}" token)
if [[ -z "${TOKEN}" ]]; then
    warn "auth failed: ${auth_body}"
    exit 1
fi
AUTH="Authorization: Bearer ${TOKEN}"

# ─── Create workspace for connector tests ───────────────────────────
ws_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
    -d "{\"name\":\"Connector E2E\",\"slug\":\"connector-e2e-$(date +%s)\"}" \
    "${BASE}/api/workspaces")
WS_ID=$(jget_path "${ws_body}" id)
if [[ -z "${WS_ID}" ]]; then
    warn "workspace creation failed: ${ws_body}"
    exit 1
fi
HWS="X-Workspace-Id: ${WS_ID}"

# ─── 1. createConfig with bearer auth (POST /api/connectors) ────────
cc_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"name\":\"Test API\",\"base_url\":\"https://api.example.com\",\"auth_type\":\"bearer\",\"auth_value\":\"test-token-123\"}" \
    "${BASE}/api/connectors")
CONFIG_ID=$(jget_path "${cc_body}" id)
CONFIG_NAME=$(jget_path "${cc_body}" name)
CONFIG_AUTH=$(jget_path "${cc_body}" auth_type)
if [[ -n "${CONFIG_ID}" && "${CONFIG_NAME}" == "Test API" && "${CONFIG_AUTH}" == "bearer" ]]; then
    pass "01 createConfig with bearer auth (id=${CONFIG_ID})"
else
    fail "01 createConfig: ${cc_body}"
fi

# ─── 2. listConfigs (GET /api/connectors) ────────────────────────────
lc_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/connectors")
LC_COUNT=$(echo "${lc_body}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("connectors",[])))' 2>/dev/null || echo 0)
LC_TOTAL=$(jget_path "${lc_body}" total)
if [[ "${LC_COUNT}" -ge 1 && "${LC_TOTAL}" -ge 1 ]]; then
    pass "02 listConfigs (n=${LC_COUNT})"
else
    fail "02 listConfigs: ${lc_body}"
fi

# ─── 3. call mock endpoint (POST /api/connectors/:id/call) ──────────
call_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"method\":\"POST\",\"path\":\"/api/v1/users\",\"body\":\"{\\\"name\\\":\\\"test\\\"}\"}" \
    "${BASE}/api/connectors/${CONFIG_ID}/call")
CALL_STATUS=$(jget_path "${call_body}" status)
CALL_LOG_ID=$(jget_path "${call_body}" log_id)
CALL_MOCK_OK=$(jget_path "${call_body}" mock_response.ok)
if [[ "${CALL_STATUS}" == "200" && -n "${CALL_LOG_ID}" && "${CALL_MOCK_OK}" == "True" ]]; then
    pass "03 call mock endpoint (log_id=${CALL_LOG_ID})"
else
    fail "03 call mock endpoint: ${call_body}"
fi

# ─── 4. verify log created (GET /api/connectors/:id/logs) ───────────
ll_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/connectors/${CONFIG_ID}/logs")
LL_COUNT=$(echo "${ll_body}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("logs",[])))' 2>/dev/null || echo 0)
LL_FIRST_METHOD=$(jget_path "${ll_body}" "logs[0].method" 2>/dev/null || echo "")
# Use python to extract first log method, since jget_path with index is fragile
LL_FIRST_METHOD=$(echo "${ll_body}" | python3 -c 'import sys,json; logs=json.load(sys.stdin).get("logs",[]); print(logs[0]["method"] if logs else "")' 2>/dev/null || echo "")
if [[ "${LL_COUNT}" -ge 1 && "${LL_FIRST_METHOD}" == "POST" ]]; then
    pass "04 verify log created (n=${LL_COUNT}, method=${LL_FIRST_METHOD})"
else
    fail "04 verify log created: ${ll_body}"
fi

# ─── 5. list configs confirms still one config ──────────────────────
lc2_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/connectors")
LC2_TOTAL=$(jget_path "${lc2_body}" total)
if [[ "${LC2_TOTAL}" -ge 1 ]]; then
    pass "05 listConfigs after call (total=${LC2_TOTAL})"
else
    fail "05 listConfigs after call: ${lc2_body}"
fi

# ─── 6. deleteConfig (DELETE /api/connectors/:id) ───────────────────
dc_status=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" \
    "${BASE}/api/connectors/${CONFIG_ID}")
if [[ "${dc_status}" == "200" || "${dc_status}" == "204" ]]; then
    pass "06 deleteConfig (${dc_status})"
else
    fail "06 deleteConfig (${dc_status})"
fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All connector endpoints responded correctly${RESET}"
    exit 0
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
