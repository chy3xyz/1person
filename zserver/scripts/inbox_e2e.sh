#!/usr/bin/env bash
# End-to-end HTTP regression test for the inbox module.
#
# Boots a fresh zserver (no-DB mode), authenticates a dev user,
# creates a scratch workspace, and exercises the public endpoints
# in `src/modules/inbox/routes.zig`.
#
# Usage:
#   MULTICA_DEV_VERIFICATION_CODE=000000 JWT_SECRET=test-secret \
#   ./scripts/inbox_e2e.sh
#
# Override the port with PORT=<n>.

set -euo pipefail

PORT="${PORT:-18096}"
BASE="http://127.0.0.1:${PORT}"
JWT_SECRET="${JWT_SECRET:-test-secret}"
export JWT_SECRET
export DATABASE_URL=""

RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; RESET="\033[0m"
failures=0
pass() { echo -e "${GREEN}PASS${RESET}: $1"; }
fail() { echo -e "${RED}FAIL${RESET}: $1"; ((failures++)) || true; }
warn() { echo -e "${YELLOW}WARN${RESET}: $1"; }
http_status() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
http_body() { curl -s "$@"; }
jget() { echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$2',''))" 2>/dev/null || true; }
jget_path() {
    echo "$1" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for k in '$2'.split('.'):
    if isinstance(d, dict) and k in d:
        d = d[k]
    else:
        print(''); sys.exit(0)
print(d if not isinstance(d, (dict, list)) else json.dumps(d))
" 2>/dev/null || true
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "==> building zserver"
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }

echo "==> starting zserver on port ${PORT}"
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-inbox-e2e.log 2>&1 &
SERVER_PID=$!
cleanup() { echo "==> stopping zserver"; kill "${SERVER_PID}" >/dev/null 2>&1 || true; wait "${SERVER_PID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

for i in $(seq 1 30); do
    [[ $(http_status "${BASE}/health") == "200" ]] && break
    sleep 0.5
done
[[ $(http_status "${BASE}/health") == "200" ]] || { warn "/health never came up"; tail -20 /tmp/zserver-inbox-e2e.log; exit 1; }

# ─── Authenticate ─────────────────────────────────────────────────────
EMAIL="inbox-e2e-$(date +%s)@example.com"
http_status -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${EMAIL}\"}" "${BASE}/auth/send-code" >/dev/null
code="${MULTICA_DEV_VERIFICATION_CODE:-000000}"
AUTH_BODY=$(http_body -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${EMAIL}\",\"code\":\"${code}\"}" "${BASE}/auth/verify-code")
TOKEN=$(jget "${AUTH_BODY}" token)
if [[ -z "${TOKEN}" ]]; then warn "auth failed: ${AUTH_BODY}"; exit 1; fi
AUTH="Authorization: Bearer ${TOKEN}"

WS_BODY=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
    -d "{\"name\":\"E2E\",\"slug\":\"inbox-$(date +%s)\"}" "${BASE}/api/workspaces")
WS_ID=$(jget "${WS_BODY}" id)
[[ -n "${WS_ID}" ]] || { warn "could not create workspace: ${WS_BODY}"; exit 1; }
HWS="X-Workspace-ID: ${WS_ID}"

# ─── 1. listInbox (GET /api/inbox) ────────────────────────────────────
st=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/inbox")
[[ "${st}" == "200" ]] && pass "01 listInbox (200)" || fail "01 listInbox (${st})"

# ─── 2. since / unread-count ──────────────────────────────────────────
st=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/inbox/since?seq=0")
[[ "${st}" == "200" ]] && pass "02 inbox since (200)" || fail "02 inbox since (${st})"
st=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/inbox/unread-count")
[[ "${st}" == "200" ]] && pass "03 unread-count (200)" || fail "03 unread-count (${st})"

# ─── 3. bulk actions ──────────────────────────────────────────────────
for ep in "mark-all-read" "archive-all" "archive-all-read" "archive-completed"; do
    st=$(http_status -X POST -H "${AUTH}" -H "${HWS}" "${BASE}/api/inbox/${ep}")
    [[ "${st}" == "200" ]] && pass "04 POST /${ep} (200)" || fail "04 POST /${ep} (${st})"
done

# ─── 4. per-item (no items in no-DB → 404) ────────────────────────────
st=$(http_status -X POST -H "${AUTH}" -H "${HWS}" "${BASE}/api/inbox/00000000-0000-0000-0000-000000000000/read")
[[ "${st}" == "404" ]] && pass "05 POST /:id/read → 404" || fail "05 POST /:id/read (${st})"

# ─── summary ──────────────────────────────────────────────────────────
if [[ "${failures}" -eq 0 ]]; then
    echo -e "${GREEN}All inbox e2e checks passed${RESET}"
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
