#!/usr/bin/env bash
# End-to-end HTTP regression test for the task_queue_v2 module.
#
# Boots a fresh zserver (no-DB mode), authenticates a dev user,
# creates a scratch workspace, and exercises the task queue endpoints.
#
# Usage:
#   MULTICA_DEV_VERIFICATION_CODE=000000 \
#   JWT_SECRET=test-secret \
#   ./scripts/task_queue_v2_e2e.sh
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
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-task-queue-v2-e2e.log 2>&1 &
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
    tail -50 /tmp/zserver-task-queue-v2-e2e.log
    exit 1
fi

# ─── Authenticate dev user ───────────────────────────────────────────
EMAIL="tqv2-e2e-$(date +%s)@example.com"
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

# ─── Create workspace for tests ──────────────────────────────────────
ws_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
    -d "{\"name\":\"TaskQueueV2 E2E\",\"slug\":\"tqv2-e2e-$(date +%s)\"}" \
    "${BASE}/api/workspaces")
WS_ID=$(jget_path "${ws_body}" id)
if [[ -z "${WS_ID}" ]]; then
    warn "workspace creation failed: ${ws_body}"
    exit 1
fi
HWS="X-Workspace-Id: ${WS_ID}"

# ─── 1. enqueue high-priority task ───────────────────────────────────
eh_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"name\":\"high-priority-job\",\"payload_json\":\"{\\\"key\\\":\\\"val1\\\"}\",\"priority\":\"high\",\"max_retries\":3}" \
    "${BASE}/api/task-queue")
H_TASK_ID=$(jget_path "${eh_body}" id)
H_PRIORITY=$(jget_path "${eh_body}" priority)
H_STATUS=$(jget_path "${eh_body}" status)
if [[ -n "${H_TASK_ID}" && "${H_PRIORITY}" == "high" && "${H_STATUS}" == "pending" ]]; then
    pass "01 enqueue high-priority task (id=${H_TASK_ID})"
else
    fail "01 enqueue high-priority task: ${eh_body}"
fi

# ─── 2. enqueue low-priority task ────────────────────────────────────
el_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"name\":\"low-priority-job\",\"payload_json\":\"{\\\"key\\\":\\\"val2\\\"}\",\"priority\":\"low\",\"max_retries\":1}" \
    "${BASE}/api/task-queue")
L_TASK_ID=$(jget_path "${el_body}" id)
L_PRIORITY=$(jget_path "${el_body}" priority)
if [[ -n "${L_TASK_ID}" && "${L_PRIORITY}" == "low" ]]; then
    pass "02 enqueue low-priority task (id=${L_TASK_ID})"
else
    fail "02 enqueue low-priority task: ${el_body}"
fi

# ─── 3. claim → gets high-priority task first ────────────────────────
claim_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{}' "${BASE}/api/task-queue/claim")
CLAIM_ID=$(jget_path "${claim_body}" id)
CLAIM_PRIORITY=$(jget_path "${claim_body}" priority)
CLAIM_STATUS=$(jget_path "${claim_body}" status)
if [[ "${CLAIM_ID}" == "${H_TASK_ID}" && "${CLAIM_PRIORITY}" == "high" && "${CLAIM_STATUS}" == "running" ]]; then
    pass "03 claim → gets high-priority task first"
else
    fail "03 claim: expected high task ${H_TASK_ID}, got id=${CLAIM_ID} priority=${CLAIM_PRIORITY} status=${CLAIM_STATUS} body=${claim_body}"
fi

# ─── 4. start → running ──────────────────────────────────────────────
st_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{}' "${BASE}/api/task-queue/${H_TASK_ID}/start")
ST_STATUS=$(jget_path "${st_body}" status)
if [[ "${ST_STATUS}" == "running" ]]; then
    pass "04 start → running (${H_TASK_ID})"
else
    fail "04 start: ${st_body}"
fi

# ─── 5. complete → done ──────────────────────────────────────────────
co_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"duration_ms\":1500}" "${BASE}/api/task-queue/${H_TASK_ID}/complete")
CO_STATUS=$(jget_path "${co_body}" status)
CO_DURATION=$(jget_path "${co_body}" duration_ms)
if [[ "${CO_STATUS}" == "done" && "${CO_DURATION}" == "1500" ]]; then
    pass "05 complete → done (duration_ms=${CO_DURATION})"
else
    fail "05 complete: ${co_body}"
fi

# ─── 6. verify stats (pending=1, running=0, done=1) ──────────────────
stats_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/task-queue/stats")
PENDING=$(jget_path "${stats_body}" pending)
RUNNING=$(jget_path "${stats_body}" running)
DONE=$(jget_path "${stats_body}" done)
TOTAL=$(jget_path "${stats_body}" total)
if [[ "${PENDING}" == "1" && "${RUNNING}" == "0" && "${DONE}" == "1" && "${TOTAL}" == "2" ]]; then
    pass "06 verify stats (pending=1 running=0 done=1 total=2)"
else
    fail "06 stats: pending=${PENDING} running=${RUNNING} done=${DONE} total=${TOTAL} body=${stats_body}"
fi

# ─── 7. list tasks ───────────────────────────────────────────────────
list_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/task-queue")
LIST_COUNT=$(echo "${list_body}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
if [[ "${LIST_COUNT}" -ge 2 ]]; then
    pass "07 list tasks (n=${LIST_COUNT})"
else
    fail "07 list tasks: ${list_body}"
fi

# ─── 8. fail → failed + retries incremented ──────────────────────────
# Claim the remaining low-priority task first, then fail it.
claim2_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{}' "${BASE}/api/task-queue/claim")
CLAIM2_ID=$(jget_path "${claim2_body}" id)
if [[ "${CLAIM2_ID}" == "${L_TASK_ID}" ]]; then
    # Now fail it
    fl_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
        -d "{\"duration_ms\":500}" "${BASE}/api/task-queue/${L_TASK_ID}/fail")
    FL_STATUS=$(jget_path "${fl_body}" status)
    FL_RETRIES=$(jget_path "${fl_body}" retries)
    FL_DURATION=$(jget_path "${fl_body}" duration_ms)
    if [[ "${FL_STATUS}" == "failed" && "${FL_RETRIES}" == "1" && "${FL_DURATION}" == "500" ]]; then
        pass "08 fail → failed (retries=${FL_RETRIES} duration_ms=${FL_DURATION})"
    else
        fail "08 fail: ${fl_body}"
    fi
else
    fail "08 claim2 → expected ${L_TASK_ID}, got ${CLAIM2_ID}: ${claim2_body}"
fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All task_queue_v2 endpoints responded correctly${RESET}"
    exit 0
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
