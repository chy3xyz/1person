#!/usr/bin/env bash
# End-to-end HTTP regression test for the media module.
#
# Boots a fresh zserver (no-DB mode), authenticates a dev user,
# creates a scratch workspace, and exercises the public endpoints
# in `src/modules/media/routes.zig`.
#
# Usage:
#   MULTICA_DEV_VERIFICATION_CODE=000000 \
#   JWT_SECRET=test-secret \
#   ./scripts/media_e2e.sh
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

jget() {
    local body="$1" key="$2"
    echo "${body}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('${key}',''))" 2>/dev/null || true
}

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
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-media-e2e.log 2>&1 &
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
    tail -50 /tmp/zserver-media-e2e.log
    exit 1
fi

# ─── Authenticate dev user ───────────────────────────────────────────
EMAIL="media-e2e-$(date +%s)@example.com"
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

# ─── Create workspace for media tests ────────────────────────────────
ws_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
    -d "{\"name\":\"Media E2E\",\"slug\":\"media-e2e-$(date +%s)\"}" \
    "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
if [[ -z "${WS_ID}" ]]; then
    warn "workspace creation failed: ${ws_body}"
    exit 1
fi
HWS="X-Workspace-Id: ${WS_ID}"

# ─── 1. upload (mock) — POST /api/media ──────────────────────────────
up_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"filename\":\"test-photo.png\",\"mime_type\":\"image/png\",\"size_bytes\":102400,\"caption\":\"A test image\"}" \
    "${BASE}/api/media")
ASSET_ID=$(jget "${up_body}" id)
ASSET_FILENAME=$(jget "${up_body}" filename)
ASSET_URL=$(jget "${up_body}" url)
if [[ -n "${ASSET_ID}" && "${ASSET_FILENAME}" == "test-photo.png" && -n "${ASSET_URL}" ]]; then
    pass "01 upload (id=${ASSET_ID})"
else
    fail "01 upload: ${up_body}"
fi

# ─── 2. list — GET /api/media ────────────────────────────────────────
ls_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/media")
LS_COUNT=$(echo "${ls_body}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("assets",[])))' 2>/dev/null || echo 0)
if [[ "${LS_COUNT}" -ge 1 ]]; then
    pass "02 list (n=${LS_COUNT})"
else
    fail "02 list: ${ls_body}"
fi

# ─── 3. get — GET /api/media/:id ─────────────────────────────────────
ge_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/media/${ASSET_ID}")
GE_ID=$(jget "${ge_body}" id)
GE_FILENAME=$(jget "${ge_body}" filename)
if [[ "${GE_ID}" == "${ASSET_ID}" && "${GE_FILENAME}" == "test-photo.png" ]]; then
    pass "03 get"
else
    fail "03 get: ${ge_body}"
fi

# ─── 4. delete — DELETE /api/media/:id ───────────────────────────────
dl_status=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" "${BASE}/api/media/${ASSET_ID}")
if [[ "${dl_status}" == "200" ]]; then
    pass "04 delete (${dl_status})"
else
    fail "04 delete (${dl_status})"
fi

# ─── 5. verify 404 after delete — GET /api/media/:id ─────────────────
g2_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/media/${ASSET_ID}")
if [[ "${g2_status}" == "404" ]]; then
    pass "05 verify 404 after delete (${g2_status})"
else
    fail "05 verify 404 after delete (${g2_status})"
fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All media endpoints responded correctly${RESET}"
    exit 0
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
