#!/usr/bin/env bash
# End-to-end HTTP regression test for the scheduler module.
set -euo pipefail
PORT="${PORT:-18091}"
BASE="http://127.0.0.1:${PORT}"
export JWT_SECRET="${JWT_SECRET:-test-secret}"
export MULTICA_DEV_VERIFICATION_CODE="${MULTICA_DEV_VERIFICATION_CODE:-000000}"
export APP_ENV="${APP_ENV:-development}"
RED="\033[0;31m"; GREEN="\033[0;32m"; RESET="\033[0m"
failures=0
pass() { echo -e "${GREEN}PASS${RESET}: $1"; }
fail() { echo -e "${RED}FAIL${RESET}: $1"; ((failures++)) || true; }
http_status() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
http_body() { curl -s "$@"; }
jget() { echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$2',''))" 2>/dev/null || true; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-scheduler-e2e.log 2>&1 &
SERVER_PID=$!
cleanup() { kill "${SERVER_PID}" >/dev/null 2>&1 || true; wait "${SERVER_PID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
for i in $(seq 1 30); do if [[ $(http_status "${BASE}/health") == "200" ]]; then break; fi; sleep 0.5; done

EMAIL="sched-e2e-$(date +%s)@example.com"
http_status -X POST -d "{\"email\":\"${EMAIL}\"}" -H "Content-Type: application/json" "${BASE}/auth/send-code" >/dev/null
auth_body=$(http_body -X POST -d "{\"email\":\"${EMAIL}\",\"code\":\"${MULTICA_DEV_VERIFICATION_CODE:-000000}\"}" -H "Content-Type: application/json" "${BASE}/auth/verify-code")
TOKEN=$(jget "${auth_body}" token)
AUTH="Authorization: Bearer ${TOKEN}"

ws_body=$(http_body -X POST -d "{\"name\":\"Scheduler E2E\",\"slug\":\"sched-e2e-$(date +%s)\"}" -H "Content-Type: application/json" -H "${AUTH}" "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
HWS="X-Workspace-Id: ${WS_ID}"

NOW_TS=$(date +%s)
FUTURE_TS=$((NOW_TS + 3600))

# 1. Schedule task for now — verify created
c1=$(http_body -X POST \
    -d "{\"name\":\"Immediate Task\",\"payload_json\":\"{\\\"action\\\":\\\"test\\\"}\",\"run_at_ts\":${NOW_TS}}" \
    -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    "${BASE}/api/scheduler")
T1_ID=$(jget "${c1}" id)
T1_STATUS=$(jget "${c1}" status)
[[ -n "${T1_ID}" && "${T1_STATUS}" == "pending" ]] && pass "01 schedule (id=${T1_ID})" || fail "01 schedule: ${c1}"

# 2. Get task by ID — verify fields
c2=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/scheduler/${T1_ID}")
T2_NAME=$(jget "${c2}" name)
[[ "${T2_NAME}" == "Immediate Task" ]] && pass "02 getTask" || fail "02 getTask: ${c2}"

# 3. Execute immediately — verify status=done
c3=$(http_body -X POST -d '' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/scheduler/execute?id=${T1_ID}")
T3_STATUS=$(jget "${c3}" status)
[[ "${T3_STATUS}" == "done" ]] && pass "03 executeNow -> done" || fail "03 executeNow: ${c3}"

# 4. Schedule future task — verify status=pending
c4=$(http_body -X POST \
    -d "{\"name\":\"Future Task\",\"run_at_ts\":${FUTURE_TS}}" \
    -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    "${BASE}/api/scheduler")
T4_ID=$(jget "${c4}" id)
T4_STATUS=$(jget "${c4}" status)
[[ "${T4_STATUS}" == "pending" ]] && pass "04 schedule future -> pending" || fail "04 schedule future: ${c4}"

# 5. List by status=pending — verify filter
c5=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/scheduler?status=pending")
T5_COUNT=$(echo "${c5}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("total",0))' 2>/dev/null || echo 0)
[[ "${T5_COUNT}" -ge 1 ]] && pass "05 listByStatus pending (count=${T5_COUNT})" || fail "05 listByStatus pending: ${c5}"

# 6. Cancel the future task — verify status=cancelled
c6=$(http_body -X POST -d '' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/scheduler/cancel?id=${T4_ID}")
T6_STATUS=$(jget "${c6}" status)
[[ "${T6_STATUS}" == "cancelled" ]] && pass "06 cancel -> cancelled" || fail "06 cancel: ${c6}"

# 7. Create task, execute with fail, verify status=failed
c7=$(http_body -X POST \
    -d "{\"name\":\"Fail Task\",\"run_at_ts\":${NOW_TS},\"max_retries\":3}" \
    -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    "${BASE}/api/scheduler")
T7_ID=$(jget "${c7}" id)
c7b=$(http_body -X POST -d '' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/scheduler/execute?id=${T7_ID}&fail=1")
T7B_STATUS=$(jget "${c7b}" status)
[[ "${T7B_STATUS}" == "failed" ]] && pass "07 execute with fail -> failed" || fail "07 execute fail: ${c7b}"

# 8. Retry failed task — verify status=pending and retries=1
c8=$(http_body -X POST -d '' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/scheduler/retry?id=${T7_ID}")
T8_STATUS=$(jget "${c8}" status)
T8_RETRIES=$(echo "${c8}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('retries',-1))" 2>/dev/null || echo -1)
[[ "${T8_STATUS}" == "pending" && "${T8_RETRIES}" == "1" ]] && pass "08 retry -> pending (retries=${T8_RETRIES})" || fail "08 retry: ${c8}"

echo
if [[ ${failures} -eq 0 ]]; then echo -e "${GREEN}All scheduler endpoints passed${RESET}"; exit 0; else echo -e "${RED}${failures} failed${RESET}"; exit 1; fi
