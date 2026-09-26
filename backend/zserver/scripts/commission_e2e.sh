#!/usr/bin/env bash
# End-to-end HTTP regression test for the commission module.
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
jget() { echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$2',''))" 2>/dev/null || true; }
jget_path() { echo "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); [None for k in '$2'.split('.') if not (d:=d.get(k,{}))]; print(d if not isinstance(d,(dict,list)) else json.dumps(d))" 2>/dev/null || true; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-commission-e2e.log 2>&1 &
SERVER_PID=$!
cleanup() { kill "${SERVER_PID}" >/dev/null 2>&1 || true; wait "${SERVER_PID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
for i in $(seq 1 30); do if [[ $(http_status "${BASE}/health") == "200" ]]; then break; fi; sleep 0.5; done

EMAIL="comm-e2e-$(date +%s)@example.com"
http_status -X POST -d "{\"email\":\"${EMAIL}\"}" -H "Content-Type: application/json" "${BASE}/auth/send-code" >/dev/null
auth_body=$(http_body -X POST -d "{\"email\":\"${EMAIL}\",\"code\":\"${ONEPERSON_DEV_VERIFICATION_CODE:-000000}\"}" -H "Content-Type: application/json" "${BASE}/auth/verify-code")
TOKEN=$(jget "${auth_body}" token)
AUTH="Authorization: Bearer ${TOKEN}"

ws_body=$(http_body -X POST -d "{\"name\":\"Commission E2E\",\"slug\":\"comm-e2e-$(date +%s)\"}" -H "Content-Type: application/json" -H "${AUTH}" "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
HWS="X-Workspace-Id: ${WS_ID}"

# 1. createRule
c1=$(http_body -X POST -d '{"name":"3-Level Split","levels":[{"depth":1,"rate":0.1},{"depth":2,"rate":0.05},{"depth":3,"rate":0.02}]}' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/commissions/rules")
RID=$(jget "${c1}" id)
[[ -n "${RID}" ]] && pass "01 createRule" || fail "01 createRule: ${c1}"

# 2. listRules
c2=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/commissions/rules")
[[ -n "${c2}" ]] && pass "02 listRules" || fail "02 listRules: ${c2}"

# 3. getRule
c3=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/commissions/rules/${RID}")
[[ $(jget "${c3}" name) == "3-Level Split" ]] && pass "03 getRule" || fail "03 getRule: ${c3}"

# 4. calculateCommission
c4=$(http_body -X POST -d "{\"rule_id\":\"${RID}\",\"transaction_id\":\"tx-001\",\"amount\":1000,\"from_user_id\":\"user-c\",\"upline_chain\":[\"user-b\",\"user-a\"]}" -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/commissions/calculate")
R4_COUNT=$(echo "${c4}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("records",[])))' 2>/dev/null || echo 0)
[[ "${R4_COUNT}" -ge 1 ]] && pass "04 calculate (n=${R4_COUNT})" || fail "04 calculate: ${c4}"

# 5. deleteRule
c5=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" "${BASE}/api/commissions/rules/${RID}")
[[ "${c5}" == "200" || "${c5}" == "204" ]] && pass "05 deleteRule (${c5})" || fail "05 deleteRule: ${c5}"

# 6. unknown rule 404
c6=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/commissions/rules/${RID}")
[[ "${c6}" == "404" ]] && pass "06 getRule 404" || fail "06 getRule 404: ${c6}"

echo
if [[ ${failures} -eq 0 ]]; then echo -e "${GREEN}All commission endpoints passed${RESET}"; exit 0; else echo -e "${RED}${failures} failed${RESET}"; exit 1; fi
