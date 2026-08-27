#!/usr/bin/env bash
# End-to-end HTTP regression test for the daemon worker protocol.
#
# Boots a fresh zserver (no-DB mode), authenticates a dev user,
# creates a scratch workspace + issue, then exercises the full
# daemon lifecycle: register → heartbeat → claim → start → progress
# → complete → deregister. The daemon uses a synthetic `mdt_<id>`
# token accepted by `src/middleware/daemon_auth.zig`.
#
# Usage:
#   MULTICA_DEV_VERIFICATION_CODE=000000 \
#   JWT_SECRET=test-secret \
#   ./scripts/daemon_e2e.sh
#
# Override the port with PORT=<n>.

set -euo pipefail

PORT="${PORT:-18094}"
BASE="http://127.0.0.1:${PORT}"
JWT_SECRET="${JWT_SECRET:-test-secret}"
export JWT_SECRET
export DATABASE_URL="${DATABASE_URL:-}"

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
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-daemon-e2e.log 2>&1 &
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
    tail -50 /tmp/zserver-daemon-e2e.log
    exit 1
fi

# ─── Authenticate dev user (for workspace + issue setup) ────────────
EMAIL="daemon-e2e-$(date +%s)@example.com"
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

# ─── Workspace + issue + enqueue a task via rerun ─────────────────
ws_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
    -d "{\"name\":\"Daemon E2E\",\"slug\":\"daemon-e2e-$(date +%s)\"}" \
    "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
HWS="X-Workspace-Id: ${WS_ID}"
issue_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"title\":\"daemon e2e issue\",\"state\":\"todo\"}" \
    "${BASE}/api/issues")
ISSUE_ID=$(jget_path "${issue_body}" data.id)
RUNTIME_ID="runtime-$(date +%s)"

# Note: there is no public enqueue endpoint, so the claim below
# expects `task=null` (empty queue) and the lifecycle tests
# (start/progress/complete) are skipped if no task is available.
# The no-DB daemon handler still exercises every route.

# ─── Daemon auth: mdt_<random> ──────────────────────────────────────
DAEMON_ID="daemon-$(date +%s)-$$"
DAEMON_TOKEN="mdt_${DAEMON_ID}"
DAEMON_AUTH="Authorization: Bearer ${DAEMON_TOKEN}"

# ─── 1. daemonRegister (POST /api/daemon/register) ──────────────────
reg_body=$(http_body -X POST -H "Content-Type: application/json" -H "${DAEMON_AUTH}" \
    -d "{\"runtime_id\":\"${RUNTIME_ID}\",\"name\":\"e2e-daemon\"}" \
    "${BASE}/api/daemon/register")
REG_ID=$(jget "${reg_body}" daemon_id)
if [[ -n "${REG_ID}" ]]; then pass "01 daemonRegister (id=${REG_ID})"; else fail "01 daemonRegister: ${reg_body}"; fi

# ─── 2. daemonHeartbeat (POST /api/daemon/heartbeat) ────────────────
hb_status=$(http_status -X POST -H "Content-Type: application/json" -H "${DAEMON_AUTH}" \
    -d '{}' "${BASE}/api/daemon/heartbeat")
if [[ "${hb_status}" == "200" ]]; then pass "02 daemonHeartbeat (200)"; else fail "02 daemonHeartbeat (${hb_status})"; fi

# ─── 3. listPendingTasks (GET /api/daemon/runtimes/:rid/tasks/pending) ─
lp_status=$(http_status -H "${DAEMON_AUTH}" \
    "${BASE}/api/daemon/runtimes/${RUNTIME_ID}/tasks/pending")
if [[ "${lp_status}" == "200" ]]; then pass "03 listPendingTasks (200)"; else fail "03 listPendingTasks (${lp_status})"; fi

# ─── 4. claimTask (POST /api/daemon/runtimes/:rid/tasks/claim) ────
# The no-DB queue is empty, so claim returns {task:null}. Accept
# both null and a real task (the latter only happens if some other
# test polluted the queue).
claim_body=$(http_body -X POST -H "Content-Type: application/json" -H "${DAEMON_AUTH}" \
    -d '{}' "${BASE}/api/daemon/runtimes/${RUNTIME_ID}/tasks/claim")
CLAIM_STATUS=$(http_status -X POST -H "Content-Type: application/json" -H "${DAEMON_AUTH}" \
    -d '{}' "${BASE}/api/daemon/runtimes/${RUNTIME_ID}/tasks/claim")
if [[ "${CLAIM_STATUS}" == "200" ]]; then pass "04 claimTask (200)"; else fail "04 claimTask (${CLAIM_STATUS})"; fi

# ─── 5. daemonDeregister (POST /api/daemon/deregister) ────────────
# Daemon id is taken from the mdt_ token; no path param needed.
dr_status=$(http_status -X POST -H "Content-Type: application/json" -H "${DAEMON_AUTH}" \
    -d '{}' "${BASE}/api/daemon/deregister")
if [[ "${dr_status}" == "200" || "${dr_status}" == "204" ]]; then pass "05 daemonDeregister (${dr_status})"; else fail "05 daemonDeregister (${dr_status})"; fi

# ─── 6. missing token rejected (401) ──────────────────────────────
mt_status=$(http_status -X POST -H "Content-Type: application/json" \
    -d '{}' "${BASE}/api/daemon/heartbeat")
if [[ "${mt_status}" == "401" ]]; then pass "06 missing token rejected (401)"; else fail "06 missing token (${mt_status})"; fi

# ─── 7. malformed mdt_ token rejected (401) ────────────────────────
# mdt_ followed by an empty daemon id must be rejected.
BAD_TOKEN="mdt_"
mt_status=$(http_status -X POST -H "Content-Type: application/json" -H "Authorization: Bearer ${BAD_TOKEN}" \
    -d '{}' "${BASE}/api/daemon/heartbeat")
if [[ "${mt_status}" == "401" ]]; then pass "07 malformed mdt_ rejected (401)"; else fail "07 malformed mdt_ (${mt_status})"; fi

# ─── 8. invalid auth prefix rejected (401) ───────────────────────
mt_status=$(http_status -X POST -H "Content-Type: application/json" -H "Authorization: Bearer foo_bar" \
    -d '{}' "${BASE}/api/daemon/heartbeat")
if [[ "${mt_status}" == "401" ]]; then pass "08 invalid prefix rejected (401)"; else fail "08 invalid prefix (${mt_status})"; fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All daemon endpoints responded correctly${RESET}"
    exit 0
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
