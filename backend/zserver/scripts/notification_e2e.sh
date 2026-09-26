#!/usr/bin/env bash
# End-to-end HTTP regression test for the notification module.
set -euo pipefail
PORT="${PORT:-18089}"
BASE="http://127.0.0.1:${PORT}"
export JWT_SECRET="${JWT_SECRET:-test-secret}"
export ONEPERSON_DEV_VERIFICATION_CODE="${ONEPERSON_DEV_VERIFICATION_CODE:-000000}"
RED="\033[0;31m"; GREEN="\033[0;32m"; RESET="\033[0m"
failures=0
pass() { echo -e "${GREEN}PASS${RESET}: $1"; }
fail() { echo -e "${RED}FAIL${RESET}: $1"; ((failures++)) || true; }
http_status() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
http_body() { curl -s "$@"; }
jget() { echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$2',''))" 2>/dev/null || true; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-notification-e2e.log 2>&1 &
SERVER_PID=$!
cleanup() { kill "${SERVER_PID}" >/dev/null 2>&1 || true; wait "${SERVER_PID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
for i in $(seq 1 30); do if [[ $(http_status "${BASE}/health") == "200" ]]; then break; fi; sleep 0.5; done

EMAIL="notif-e2e-$(date +%s)@example.com"
http_status -X POST -d "{\"email\":\"${EMAIL}\"}" -H "Content-Type: application/json" "${BASE}/auth/send-code" >/dev/null
auth_body=$(http_body -X POST -d "{\"email\":\"${EMAIL}\",\"code\":\"${ONEPERSON_DEV_VERIFICATION_CODE:-000000}\"}" -H "Content-Type: application/json" "${BASE}/auth/verify-code")
TOKEN=$(jget "${auth_body}" token)
AUTH="Authorization: Bearer ${TOKEN}"

ws_body=$(http_body -X POST -d "{\"name\":\"Notification E2E\",\"slug\":\"notif-e2e-$(date +%s)\"}" -H "Content-Type: application/json" -H "${AUTH}" "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
HWS="X-Workspace-Id: ${WS_ID}"

# 1. createTemplate (email)
c1=$(http_body -X POST -d '{"name":"Welcome Email","channel":"email","subject_template":"Welcome, {{name}}","body_template":"Hello {{name}}, thanks for joining!"}' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/notifications/templates")
TID=$(jget "${c1}" id)
[[ -n "${TID}" ]] && pass "01 createTemplate" || fail "01 createTemplate: ${c1}"

# 2. send notification (simulated — creates log with status=sent)
c2=$(http_body -X POST -d "{\"template_id\":\"${TID}\",\"user_id\":\"user-001\",\"variables\":{\"name\":\"Alice\"}}" -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/notifications/send")
LID=$(jget "${c2}" id)
LSTATUS=$(jget "${c2}" status)
[[ "${LSTATUS}" == "sent" ]] && pass "02 send (status=${LSTATUS})" || fail "02 send: ${c2}"

# 3. verify log created (getLogs for user)
c3=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/notifications/logs?user_id=user-001")
LCOUNT=$(echo "${c3}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("logs",[])))' 2>/dev/null || echo 0)
[[ "${LCOUNT}" -ge 1 ]] && pass "03 getLogs (count=${LCOUNT})" || fail "03 getLogs: ${c3}"

# 4. listTemplates
c4=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/notifications/templates")
TCOUNT=$(echo "${c4}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("templates",[])))' 2>/dev/null || echo 0)
[[ "${TCOUNT}" -ge 1 ]] && pass "04 listTemplates (count=${TCOUNT})" || fail "04 listTemplates: ${c4}"

# 5. getTemplate
c5=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/notifications/templates/${TID}")
[[ $(jget "${c5}" name) == "Welcome Email" ]] && pass "05 getTemplate" || fail "05 getTemplate: ${c5}"

# 6. listChannels
c6=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/notifications/channels")
CC=$(echo "${c6}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("channels",[])))' 2>/dev/null || echo 0)
[[ "${CC}" -ge 7 ]] && pass "06 listChannels (count=${CC})" || fail "06 listChannels: ${c6}"

# 7. deleteTemplate
c7=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" "${BASE}/api/notifications/templates/${TID}")
[[ "${c7}" == "200" || "${c7}" == "204" ]] && pass "07 deleteTemplate (${c7})" || fail "07 deleteTemplate: ${c7}"

echo
if [[ ${failures} -eq 0 ]]; then echo -e "${GREEN}All notification endpoints passed${RESET}"; exit 0; else echo -e "${RED}${failures} failed${RESET}"; exit 1; fi
