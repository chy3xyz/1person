#!/usr/bin/env bash
set -euo pipefail

# I18n module end-to-end test — exercises all three endpoints
# (/api/i18n/locales, /api/i18n/translations) against a running
# zserver in no-DB mode.
#
# Usage: MULTICA_DEV_VERIFICATION_CODE=<code> ./scripts/i18n_e2e.sh

PORT="${PORT:-18099}"
BASE="http://127.0.0.1:${PORT}"
JWT_SECRET="${JWT_SECRET:-test-secret}"
export JWT_SECRET
export DATABASE_URL="${DATABASE_URL:-}"

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
"$(dirname "$0")/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-i18n-e2e.log 2>&1 &
SERVER_PID=$!

cleanup() {
    echo "==> stopping zserver"
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Wait for it to be ready
echo "==> waiting for server to be ready"
for i in $(seq 1 30); do
    if [[ $(http_status "${BASE}/health") == "200" ]]; then
        break
    fi
    sleep 0.5
done

echo "==> running i18n checks"

# ── Auth: obtain a JWT token via the dev verification code ──────
DEV_CODE="${MULTICA_DEV_VERIFICATION_CODE:-${DEV_AUTH_CODE:-}}"
if [[ -z "${DEV_CODE}" ]]; then
    echo "SKIP: i18n endpoints require auth (set MULTICA_DEV_VERIFICATION_CODE)"
    exit 0
fi

email="i18n-e2e-$(date +%s)@example.com"

# Send verification code (no-DB mode returns 200)
send_status=$(http_status -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${email}\"}" "${BASE}/auth/send-code")
if [[ "${send_status}" != "200" ]]; then
    fail "POST /auth/send-code (got ${send_status})"
    exit 1
fi

# Verify code and get token
body=$(http_body -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${email}\",\"code\":\"${DEV_CODE}\"}" "${BASE}/auth/verify-code")
TOKEN=$(echo "${body}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)
if [[ -z "${TOKEN}" ]]; then
    fail "POST /auth/verify-code: could not extract token from ${body}"
    exit 1
fi
echo "  got auth token"

AUTH="Authorization: Bearer ${TOKEN}"

# ── Create workspace (needed for RequireWorkspaceMember) ────────
ws_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
    -d "{\"name\":\"I18n E2E Workspace\",\"slug\":\"i18n-e2e-$(date +%s)\"}" "${BASE}/api/workspaces")
WS_ID=$(echo "${ws_body}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
if [[ -z "${WS_ID}" ]]; then
    fail "POST /api/workspaces: ${ws_body}"
    exit 1
fi
echo "  workspace id: ${WS_ID}"

WS_HDR="X-Workspace-ID: ${WS_ID}"

# ── Test 1: listLocales — GET /api/i18n/locales ─────────────────
echo ""
echo "=== Test 1: GET /api/i18n/locales ==="
locales_body=$(http_body -H "${AUTH}" -H "${WS_HDR}" "${BASE}/api/i18n/locales")
locales_status=$(http_status -H "${AUTH}" -H "${WS_HDR}" "${BASE}/api/i18n/locales")

if [[ "${locales_status}" != "200" ]]; then
    fail "GET /api/i18n/locales (status ${locales_status})"
else
    has_zh=$(echo "${locales_body}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
locs = [l['locale'] for l in data.get('locales', [])]
print('zh' in locs and 'en' in locs)" 2>/dev/null || echo "False")
    if [[ "${has_zh}" == "True" ]]; then
        pass "GET /api/i18n/locales — zh and en present"
    else
        fail "GET /api/i18n/locales — missing zh/en: ${locales_body}"
    fi
fi

# ── Test 2: setTranslation — POST /api/i18n/translations ────────
echo ""
echo "=== Test 2: POST /api/i18n/translations (set en greeting) ==="
set_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${WS_HDR}" \
    -d '{"locale":"en","key":"greeting","value":"Hello"}' "${BASE}/api/i18n/translations")
set_status=$(http_status -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${WS_HDR}" \
    -d '{"locale":"en","key":"greeting","value":"Hello"}' "${BASE}/api/i18n/translations")

if [[ "${set_status}" == "200" || "${set_status}" == "201" ]]; then
    pass "POST /api/i18n/translations (status ${set_status})"
else
    fail "POST /api/i18n/translations (status ${set_status}): ${set_body}"
fi

# ── Test 3: getTranslations — GET /api/i18n/translations?locale=en ─
echo ""
echo "=== Test 3: GET /api/i18n/translations?locale=en ==="
get_body=$(http_body -H "${AUTH}" -H "${WS_HDR}" "${BASE}/api/i18n/translations?locale=en")
get_status=$(http_status -H "${AUTH}" -H "${WS_HDR}" "${BASE}/api/i18n/translations?locale=en")

if [[ "${get_status}" != "200" ]]; then
    fail "GET /api/i18n/translations?locale=en (status ${get_status})"
else
    pass "GET /api/i18n/translations?locale=en (status ${get_status})"
fi

# ── Test 4: verify greeting value ────────────────────────────────
echo ""
echo "=== Test 4: verify greeting value ==="
greeting_val=$(echo "${get_body}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data.get('translations', []):
    if t.get('key') == 'greeting':
        print(t.get('value', ''))
        break
" 2>/dev/null || echo "")

if [[ "${greeting_val}" == "Hello" ]]; then
    pass "verify greeting value = 'Hello'"
else
    fail "verify greeting value: expected 'Hello', got '${greeting_val}'"
fi

# ── Test 5: get translations for zh (should be empty) ────────────
echo ""
echo "=== Test 5: GET /api/i18n/translations?locale=zh (empty) ==="
zh_body=$(http_body -H "${AUTH}" -H "${WS_HDR}" "${BASE}/api/i18n/translations?locale=zh")
zh_total=$(echo "${zh_body}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total', -1))" 2>/dev/null || echo "-1")

if [[ "${zh_total}" == "0" ]]; then
    pass "GET /api/i18n/translations?locale=zh returns 0 translations"
else
    fail "GET /api/i18n/translations?locale=zh expected 0, got ${zh_total}"
fi

# ── Summary ─────────────────────────────────────────────────────
echo ""
if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All 5 checks passed${RESET}"
    exit 0
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
