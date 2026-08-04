#!/usr/bin/env bash
# End-to-end HTTP regression test for the token economy module.
# Target: 8 PASS
set -euo pipefail
PORT="${PORT:-18089}"
BASE="http://127.0.0.1:${PORT}"
export JWT_SECRET="${JWT_SECRET:-test-secret}"
export MULTICA_DEV_VERIFICATION_CODE="${MULTICA_DEV_VERIFICATION_CODE:-000000}"
RED="\033[0;31m"; GREEN="\033[0;32m"; RESET="\033[0m"
failures=0
pass() { echo -e "${GREEN}PASS${RESET}: $1"; }
fail() { echo -e "${RED}FAIL${RESET}: $1"; ((failures++)) || true; }
http_status() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
http_body() { curl -s "$@"; }
jget() { echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$2',''))" 2>/dev/null || true; }
jget_path() { echo "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); [None for k in '$2'.split('.') if not (d:=d.get(k,{}))]; print(d if not isinstance(d,(dict,list)) else json.dumps(d))" 2>/dev/null || true; }
jnum() { echo "$1" | python3 -c "import sys,json; v=json.load(sys.stdin).get('$2'); print(v if v is not None else 0)" 2>/dev/null || true; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-token-economy-e2e.log 2>&1 &
SERVER_PID=$!
cleanup() { kill "${SERVER_PID}" >/dev/null 2>&1 || true; wait "${SERVER_PID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
for i in $(seq 1 30); do if [[ $(http_status "${BASE}/health") == "200" ]]; then break; fi; sleep 0.5; done

# -------------------------------------------------------------------
# Auth as user-A
# -------------------------------------------------------------------
EMAIL_A="tke-e2e-a-$(date +%s)@example.com"
http_status -X POST -d "{\"email\":\"${EMAIL_A}\"}" -H "Content-Type: application/json" "${BASE}/auth/send-code" >/dev/null
auth_body_a=$(http_body -X POST -d "{\"email\":\"${EMAIL_A}\",\"code\":\"${MULTICA_DEV_VERIFICATION_CODE:-000000}\"}" -H "Content-Type: application/json" "${BASE}/auth/verify-code")
TOKEN_A=$(jget "${auth_body_a}" token)
AUTH_A="Authorization: Bearer ${TOKEN_A}"
USER_A_ID=$(jget_path "${auth_body_a}" "user.id")

# -------------------------------------------------------------------
# Auth as user-B
# -------------------------------------------------------------------
EMAIL_B="tke-e2e-b-$(date +%s)@example.com"
http_status -X POST -d "{\"email\":\"${EMAIL_B}\"}" -H "Content-Type: application/json" "${BASE}/auth/send-code" >/dev/null
auth_body_b=$(http_body -X POST -d "{\"email\":\"${EMAIL_B}\",\"code\":\"${MULTICA_DEV_VERIFICATION_CODE:-000000}\"}" -H "Content-Type: application/json" "${BASE}/auth/verify-code")
TOKEN_B=$(jget "${auth_body_b}" token)
AUTH_B="Authorization: Bearer ${TOKEN_B}"
USER_B_ID=$(jget_path "${auth_body_b}" "user.id")

# -------------------------------------------------------------------
# Create workspace and get shared workspace context
# -------------------------------------------------------------------
ws_body=$(http_body -X POST -d "{\"name\":\"Token Economy E2E\",\"slug\":\"tke-e2e-$(date +%s)\"}" -H "Content-Type: application/json" -H "${AUTH_A}" "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
HWS="X-Workspace-Id: ${WS_ID}"

# -------------------------------------------------------------------
# 01 – Create token config
# -------------------------------------------------------------------
c1=$(http_body -X POST -d '{"name":"Points","total_supply":100000}' -H "Content-Type: application/json" -H "${AUTH_A}" -H "${HWS}" "${BASE}/api/token-economy")
C1_NAME=$(jget "${c1}" name)
[[ "${C1_NAME}" == "Points" ]] && pass "01 createConfig (name=${C1_NAME})" || fail "01 createConfig: ${c1}"

# -------------------------------------------------------------------
# 02 – Earn 100 tokens for user-A
# -------------------------------------------------------------------
c2=$(http_body -X POST -d "{\"user_id\":\"${USER_A_ID}\",\"amount\":100,\"reason\":\"signup bonus\"}" -H "Content-Type: application/json" -H "${AUTH_A}" -H "${HWS}" "${BASE}/api/token-economy/earn")
C2_TYPE=$(jget_path "${c2}" "transaction.type")
[[ "${C2_TYPE}" == "earn" ]] && pass "02 earnTokens (type=${C2_TYPE})" || fail "02 earnTokens: ${c2}"

# -------------------------------------------------------------------
# 03 – Check user-A balance = 100
# -------------------------------------------------------------------
c3=$(http_body -H "${AUTH_A}" -H "${HWS}" "${BASE}/api/token-economy/balance?user_id=${USER_A_ID}")
C3_BAL=$(jnum "${c3}" balance)
[[ "${C3_BAL}" == "100.0" || "${C3_BAL}" == "100" ]] && pass "03 getBalance A = ${C3_BAL}" || fail "03 getBalance A: ${c3} (expected 100, got ${C3_BAL})"

# -------------------------------------------------------------------
# 04 – Spend 30 tokens from user-A
# -------------------------------------------------------------------
c4=$(http_body -X POST -d "{\"user_id\":\"${USER_A_ID}\",\"amount\":30,\"reason\":\"purchase item\"}" -H "Content-Type: application/json" -H "${AUTH_A}" -H "${HWS}" "${BASE}/api/token-economy/spend")
C4_TYPE=$(jget_path "${c4}" "transaction.type")
[[ "${C4_TYPE}" == "spend" ]] && pass "04 spendTokens (type=${C4_TYPE})" || fail "04 spendTokens: ${c4}"

# -------------------------------------------------------------------
# 05 – Check user-A balance = 70
# -------------------------------------------------------------------
c5=$(http_body -H "${AUTH_A}" -H "${HWS}" "${BASE}/api/token-economy/balance?user_id=${USER_A_ID}")
C5_BAL=$(jnum "${c5}" balance)
[[ "${C5_BAL}" == "70.0" || "${C5_BAL}" == "70" ]] && pass "05 getBalance A = ${C5_BAL}" || fail "05 getBalance A: ${c5} (expected 70, got ${C5_BAL})"

# -------------------------------------------------------------------
# 06 – Transfer 20 tokens from user-A to user-B
# -------------------------------------------------------------------
c6=$(http_body -X POST -d "{\"from_user_id\":\"${USER_A_ID}\",\"to_user_id\":\"${USER_B_ID}\",\"amount\":20,\"reason\":\"gift\"}" -H "Content-Type: application/json" -H "${AUTH_A}" -H "${HWS}" "${BASE}/api/token-economy/transfer")
C6_TYPE=$(jget_path "${c6}" "transaction.type")
[[ "${C6_TYPE}" == "transfer" ]] && pass "06 transferTokens (type=${C6_TYPE})" || fail "06 transferTokens: ${c6}"

# -------------------------------------------------------------------
# 07 – Check user-B balance = 20
# -------------------------------------------------------------------
c7=$(http_body -H "${AUTH_A}" -H "${HWS}" "${BASE}/api/token-economy/balance?user_id=${USER_B_ID}")
C7_BAL=$(jnum "${c7}" balance)
[[ "${C7_BAL}" == "20.0" || "${C7_BAL}" == "20" ]] && pass "07 getBalance B = ${C7_BAL}" || fail "07 getBalance B: ${c7} (expected 20, got ${C7_BAL})"

# -------------------------------------------------------------------
# 08 – List transactions for user-A (earn + spend + transfer = 3)
# -------------------------------------------------------------------
c8=$(http_body -H "${AUTH_A}" -H "${HWS}" "${BASE}/api/token-economy/transactions?user_id=${USER_A_ID}")
C8_TOTAL=$(echo "${c8}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("total",0))' 2>/dev/null || echo 0)
[[ "${C8_TOTAL}" -ge 3 ]] && pass "08 listTransactions (total=${C8_TOTAL})" || fail "08 listTransactions: ${c8} (expected >=3, got ${C8_TOTAL})"

echo
if [[ ${failures} -eq 0 ]]; then echo -e "${GREEN}All 8 token economy tests passed${RESET}"; exit 0; else echo -e "${RED}${failures} failed${RESET}"; exit 1; fi
