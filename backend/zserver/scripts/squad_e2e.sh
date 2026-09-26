#!/usr/bin/env bash
# End-to-end HTTP regression test for the squad module.
#
# Boots a fresh zserver (no-DB mode), authenticates a dev user,
# creates a scratch workspace, and exercises the public endpoints
# in `src/modules/squad/routes.zig`.
#
# Usage:
#   ONEPERSON_DEV_VERIFICATION_CODE=000000 JWT_SECRET=test-secret \
#   ./scripts/squad_e2e.sh
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
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-squad-e2e.log 2>&1 &
SERVER_PID=$!
cleanup() { echo "==> stopping zserver"; kill "${SERVER_PID}" >/dev/null 2>&1 || true; wait "${SERVER_PID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

for i in $(seq 1 30); do
    [[ $(http_status "${BASE}/health") == "200" ]] && break
    sleep 0.5
done
[[ $(http_status "${BASE}/health") == "200" ]] || { warn "/health never came up"; tail -20 /tmp/zserver-squad-e2e.log; exit 1; }

# ─── Authenticate ─────────────────────────────────────────────────────
EMAIL="squad-e2e-$(date +%s)@example.com"
http_status -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${EMAIL}\"}" "${BASE}/auth/send-code" >/dev/null
code="${ONEPERSON_DEV_VERIFICATION_CODE:-000000}"
AUTH_BODY=$(http_body -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${EMAIL}\",\"code\":\"${code}\"}" "${BASE}/auth/verify-code")
TOKEN=$(jget "${AUTH_BODY}" token)
if [[ -z "${TOKEN}" ]]; then warn "auth failed: ${AUTH_BODY}"; exit 1; fi
AUTH="Authorization: Bearer ${TOKEN}"

WS_BODY=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
    -d "{\"name\":\"E2E\",\"slug\":\"squad-$(date +%s)\"}" "${BASE}/api/workspaces")
WS_ID=$(jget "${WS_BODY}" id)
[[ -n "${WS_ID}" ]] || { warn "could not create workspace: ${WS_BODY}"; exit 1; }
HWS="X-Workspace-ID: ${WS_ID}"

# ─── 1. listSquads (GET /api/squads) ──────────────────────────────────
st=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/squads")
[[ "${st}" == "200" ]] && pass "01 listSquads (200)" || fail "01 listSquads (${st})"

# ─── 2. createSquad ───────────────────────────────────────────────────
USER_ID=$(jget "$(http_body -H "${AUTH}" "${BASE}/api/me")" id)
SQ_BODY=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"name\":\"e2e-squad\",\"description\":\"test\",\"leader_id\":\"${USER_ID}\"}" "${BASE}/api/squads")
SQ_ID=$(jget "${SQ_BODY}" id)
if [[ -n "${SQ_ID}" ]]; then pass "02 createSquad (id=${SQ_ID:0:8})"; else fail "02 createSquad: ${SQ_BODY}"; fi

# ─── 3. getSquad ──────────────────────────────────────────────────────
st=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/squads/${SQ_ID}")
[[ "${st}" == "200" ]] && pass "03 getSquad (200)" || fail "03 getSquad (${st})"

# ─── 4. updateSquad (PUT) ─────────────────────────────────────────────
st=$(http_status -X PUT -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{"name":"e2e-squad-renamed"}' "${BASE}/api/squads/${SQ_ID}")
[[ "${st}" == "200" ]] && pass "04 updateSquad (200)" || fail "04 updateSquad (${st})"

# ─── 5. members ───────────────────────────────────────────────────────
st=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/squads/${SQ_ID}/members")
[[ "${st}" == "200" ]] && pass "05 listMembers (200)" || fail "05 listMembers (${st})"
st=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/squads/${SQ_ID}/members/status")
[[ "${st}" == "200" ]] && pass "06 memberStatus (200)" || fail "06 memberStatus (${st})"

# ─── 6. deleteSquad ───────────────────────────────────────────────────
st=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" "${BASE}/api/squads/${SQ_ID}")
[[ "${st}" == "204" || "${st}" == "200" ]] && pass "07 deleteSquad (${st})" || fail "07 deleteSquad (${st})"

# ─── summary ──────────────────────────────────────────────────────────
if [[ "${failures}" -eq 0 ]]; then
    echo -e "${GREEN}All squad e2e checks passed${RESET}"
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
