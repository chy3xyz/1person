#!/usr/bin/env bash
# End-to-end HTTP regression test for the commission module.
#
# Usage:
#   MULTICA_DEV_VERIFICATION_CODE=000000 \
#   JWT_SECRET=test-secret \
#   ./scripts/commission_e2e.sh

set -euo pipefail

PORT="${PORT:-18090}"
BASE="http://127.0.0.1:${PORT}"
JWT_SECRET="${JWT_SECRET:-test-secret}"
export JWT_SECRET

RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; RESET="\033[0m"
failures=0
pass() { echo -e "${GREEN}PASS${RESET}: $1"; }
fail() { echo -e "${RED}FAIL${RESET}: $1"; ((failures++)) || true; }

http_status() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
http_body() { curl -s "$@"; }
jget() { echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$2',''))" 2>/dev/null || true; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "==> building zserver"
( cd "${SCRIPT_DIR}/../zserver" && zig build ) || { echo "build failed"; exit 1; }

echo "==> starting zserver on port ${PORT}"
"${SCRIPT_DIR}/../zserver/zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-commission-e2e.log 2>&1 &
SERVER_PID=$!
cleanup() { kill "${SERVER_PID}" >/dev/null 2>&1 || true; wait "${SERVER_PID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

for i in $(seq 1 30); do
    if [[ $(http_status "${BASE}/health") == "200" ]]; then break; fi; sleep 0.5
done

EMAIL="comm-e2e-$(date +%s)@example.com"
http_status -X POST -H "Content-Type: application/json" -d "{\"email\":\"${EMAIL}\"}" "${BASE}/auth/send-code" >/dev/null
code="${MULTICA_DEV_VERIFICATION_CODE:-000000}"
auth_body=$(http_body -X POST -H "Content-Type: application/json" -d "{\"email\":\"${EMAIL}\",\"code\":\"${code}\"}" "${BASE}/auth/verify-code")
TOKEN=$(jget "${auth_body}" token)
AUTH="Authorization: Bearer ${TOKEN}"

ws_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -d "{\"name\":\"Commission E2E\",\"slug\":\"comm-e2e-$(date +%s)\"}" "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
HWS="X-Workspace-Id: ${WS_ID}"

# ── 1. createRule ─────────────────────────────────────────────
c1=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
  -d '{"name":"Standard Split","levels":[{"depth":1,"rate":0.10},{"depth":2,"rate":0.05},{"depth":3,"rate":0.02}]}' \
  "${BASE}/api/commissions/rules")
RULE_ID=$(jget "${c1}" id)
[[ -n "${RULE_ID}" ]] && pass "01 createRule (id=${RULE_ID})" || fail "01 createRule: ${c1}"

# ── 2. listRules ──────────────────────────────────────────────
c2=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/commissions/rules")
P2_COUNT=$(echo "${c2}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("rules",[])))' 2>/dev/null || echo 0)
[[ "${P2_COUNT}" -ge 1 ]] && pass "02 listRules (n=${P2_COUNT})" || fail "02 listRules: ${c2}"

# ── 3. getRule ────────────────────────────────────────────────
c3=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/commissions/rules/${RULE_ID}")
P3_NAME=$(jget "${c3}" name)
[[ "${P3_NAME}" == "Standard Split" ]] && pass "03 getRule" || fail "03 getRule: ${c3}"

# ── 4. calculateCommission ────────────────────────────────────
# Hierarchy A→B→C: C initiates transaction of $1000.
# Upline chain is [B, A] so depth1(10%)→B=$100, depth2(5%)→A=$50.
c4=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
  -d "{\"rule_id\":\"${RULE_ID}\",\"transaction_id\":\"txn-001\",\"amount\":1000.0,\"from_user_id\":\"user-c\",\"upline_chain\":[\"user-b\",\"user-a\"]}" \
  "${BASE}/api/commissions/calculate")
P4_TOTAL=$(jget "${c4}" total)
[[ "${P4_TOTAL}" == "2" ]] && pass "04 calculateCommission (${P4_TOTAL} records)" || fail "04 calculateCommission: ${c4}"

# ── 5. verify records via list + check amounts ────────────────
c5=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/commissions/records")
P5_COUNT=$(echo "${c5}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("records",[])))' 2>/dev/null || echo 0)
[[ "${P5_COUNT}" == "2" ]] && pass "05 listRecords (n=${P5_COUNT})" || fail "05 listRecords: ${c5}"

# Extract record IDs and verify amounts
REC1_ID=$(echo "${c5}" | python3 -c "
import sys,json
recs=json.load(sys.stdin).get('records',[])
for r in recs:
    if r.get('to_user_id')=='user-b' and r.get('amount')==100.0 and r.get('rate')==0.1 and r.get('level')==1:
        print(r.get('id',''))
" 2>/dev/null)
REC2_ID=$(echo "${c5}" | python3 -c "
import sys,json
recs=json.load(sys.stdin).get('records',[])
for r in recs:
    if r.get('to_user_id')=='user-a' and r.get('amount')==50.0 and r.get('rate')==0.05 and r.get('level')==2:
        print(r.get('id',''))
" 2>/dev/null)
[[ -n "${REC1_ID}" && -n "${REC2_ID}" ]] && pass "05b verify record amounts (B=\$100, A=\$50)" || fail "05b verify record amounts"

# ── 6. settle ─────────────────────────────────────────────────
c6=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
  -d "{\"record_ids\":[\"${REC1_ID}\",\"${REC2_ID}\"]}" \
  "${BASE}/api/commissions/settle")
P6_COUNT=$(jget "${c6}" total)
[[ "${P6_COUNT}" == "2" ]] && pass "06 settle (${P6_COUNT} settled)" || fail "06 settle: ${c6}"

# ── 7. check settled status ───────────────────────────────────
c7=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/commissions/records/${REC1_ID}")
P7_STATUS=$(jget "${c7}" status)
P7_SETTLED=$(jget "${c7}" settled_at)
[[ "${P7_STATUS}" == "settled" && -n "${P7_SETTLED}" ]] && pass "07 record settled (status=${P7_STATUS})" || fail "07 record settled: ${c7}"

# ── 8. deleteRule ─────────────────────────────────────────────
c8_status=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" "${BASE}/api/commissions/rules/${RULE_ID}")
[[ "${c8_status}" == "200" || "${c8_status}" == "204" ]] && pass "08 deleteRule (${c8_status})" || fail "08 deleteRule (${c8_status})"

echo
if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All commission endpoints responded correctly${RESET}"; exit 0
else
    echo -e "${RED}${failures} check(s) failed${RESET}"; exit 1
fi
