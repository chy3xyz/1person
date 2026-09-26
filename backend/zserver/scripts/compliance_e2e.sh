#!/usr/bin/env bash
# End-to-end HTTP regression test for the compliance module.
set -euo pipefail
PORT="${PORT:-18088}"
BASE="http://127.0.0.1:${PORT}"
export JWT_SECRET="${JWT_SECRET:-test-secret}"
RED="\033[0;31m"; GREEN="\033[0;32m"; RESET="\033[0m"
failures=0
pass() { echo -e "${GREEN}PASS${RESET}: $1"; }
fail() { echo -e "${RED}FAIL${RESET}: $1"; ((failures++)) || true; }
http_status() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
http_body() { curl -s "$@"; }
jget() { echo "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',d).get('$2',''))" 2>/dev/null || true; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }
ONEPERSON_DEV_VERIFICATION_CODE="${ONEPERSON_DEV_VERIFICATION_CODE:-000000}" "${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-compliance-e2e.log 2>&1 &
SERVER_PID=$!
cleanup() { kill "${SERVER_PID}" >/dev/null 2>&1 || true; wait "${SERVER_PID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
for i in $(seq 1 30); do if [[ $(http_status "${BASE}/health") == "200" ]]; then break; fi; sleep 0.5; done

EMAIL="comp-e2e-$(date +%s)@example.com"
http_status -X POST -d "{\"email\":\"${EMAIL}\"}" -H "Content-Type: application/json" "${BASE}/auth/send-code" >/dev/null
auth_body=$(http_body -X POST -d "{\"email\":\"${EMAIL}\",\"code\":\"${ONEPERSON_DEV_VERIFICATION_CODE:-000000}\"}" -H "Content-Type: application/json" "${BASE}/auth/verify-code")
TOKEN=$(jget "${auth_body}" token)
AUTH="Authorization: Bearer ${TOKEN}"

ws_body=$(http_body -X POST -d "{\"name\":\"Compliance E2E\",\"slug\":\"comp-e2e-$(date +%s)\"}" -H "Content-Type: application/json" -H "${AUTH}" "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
HWS="X-Workspace-Id: ${WS_ID}"

# 1. createRule
c1=$(http_body -X POST -d '{"name":"Password Policy Check","description":"Verify password meets minimum requirements","check_type":"manual"}' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/compliance/rules")
RID=$(jget "${c1}" id)
[[ -n "${RID}" ]] && pass "01 createRule" || fail "01 createRule: ${c1}"

# 2. getRule
c2=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/compliance/rules/${RID}")
[[ $(jget "${c2}" name) == "Password Policy Check" ]] && pass "02 getRule" || fail "02 getRule: ${c2}"

# 3. runAudit
c3=$(http_body -X POST -d "{\"rule_id\":\"${RID}\"}" -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/compliance/run")
LSTATUS=$(jget "${c3}" status)
[[ "${LSTATUS}" == "pass" ]] && pass "03 runAudit (status=${LSTATUS})" || fail "03 runAudit: ${c3}"

# 4. listAuditLogs — verify the log we just created appears
c4=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/compliance/logs")
L4_COUNT=$(echo "${c4}" | python3 -c 'import sys,json; d=json.load(sys.stdin); d=d.get("data",d); print(len(d.get("logs",[])))' 2>/dev/null || echo 0)
[[ "${L4_COUNT}" -ge 1 ]] && pass "04 listAuditLogs (count=${L4_COUNT})" || fail "04 listAuditLogs: ${c4}"

# 5. deleteRule
c5=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" "${BASE}/api/compliance/rules/${RID}")
[[ "${c5}" == "200" || "${c5}" == "204" ]] && pass "05 deleteRule (${c5})" || fail "05 deleteRule: ${c5}"

# 6. deleted rule returns 404
c6=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/compliance/rules/${RID}")
[[ "${c6}" == "404" ]] && pass "06 getRule 404" || fail "06 getRule 404: ${c6}"

echo
if [[ ${failures} -eq 0 ]]; then echo -e "${GREEN}All compliance endpoints passed${RESET}"; exit 0; else echo -e "${RED}${failures} failed${RESET}"; exit 1; fi
