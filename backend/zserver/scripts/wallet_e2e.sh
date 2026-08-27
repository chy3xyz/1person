#!/usr/bin/env bash
# End-to-end HTTP regression test for the wallet module.
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
jget() { echo "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); [None for k in '$2'.split('.') if not (d:=d.get(k,{}))]; print(d if not isinstance(d,(dict,list)) else json.dumps(d))" 2>/dev/null || true; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-wallet-e2e.log 2>&1 &
SERVER_PID=$!
cleanup() { kill "${SERVER_PID}" >/dev/null 2>&1 || true; wait "${SERVER_PID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
for i in $(seq 1 30); do if [[ $(http_status "${BASE}/health") == "200" ]]; then break; fi; sleep 0.5; done

EMAIL="wallet-e2e-$(date +%s)@example.com"
http_status -X POST -d "{\"email\":\"${EMAIL}\"}" -H "Content-Type: application/json" "${BASE}/auth/send-code" >/dev/null
auth_body=$(http_body -X POST -d "{\"email\":\"${EMAIL}\",\"code\":\"${MULTICA_DEV_VERIFICATION_CODE:-000000}\"}" -H "Content-Type: application/json" "${BASE}/auth/verify-code")
TOKEN=$(jget "${auth_body}" token)
AUTH="Authorization: Bearer ${TOKEN}"

ws_body=$(http_body -X POST -d "{\"name\":\"Wallet E2E\",\"slug\":\"wallet-e2e-$(date +%s)\"}" -H "Content-Type: application/json" -H "${AUTH}" "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
HWS="X-Workspace-Id: ${WS_ID}"

# 1. create wallet
w1=$(http_body -X POST -d '{}' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/wallet/create")
WID=$(jget "${w1}" wallet.id)
[[ -n "${WID}" ]] && pass "01 create wallet" || fail "01 create wallet: ${w1}"

# 2. deposit 500
w2=$(http_body -X POST -d '{"amount":500}' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/wallet/deposit")
BAL_FIAT=$(jget "${w2}" wallet.balance_fiat)
[[ "${BAL_FIAT}" == "500" ]] && pass "02 deposit 500 (balance_fiat=${BAL_FIAT})" || fail "02 deposit 500: ${w2}"

# 3. check balance after deposit
w3=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/wallet/me")
BAL3=$(jget "${w3}" wallet.balance_fiat)
[[ "${BAL3}" == "500" ]] && pass "03 check balance=500" || fail "03 check balance=500: ${w3}"

# 4. withdraw 200
w4=$(http_body -X POST -d '{"amount":200}' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/wallet/withdraw")
BAL4=$(jget "${w4}" wallet.balance_fiat)
[[ "${BAL4}" == "300" ]] && pass "04 withdraw 200 (balance_fiat=${BAL4})" || fail "04 withdraw 200: ${w4}"

# 5. check balance=300
w5=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/wallet/me")
BAL5=$(jget "${w5}" wallet.balance_fiat)
[[ "${BAL5}" == "300" ]] && pass "05 check balance=300" || fail "05 check balance=300: ${w5}"

# 6. add reward 50
w6=$(http_body -X POST -d '{"amount":50}' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/wallet/reward")
BAL_R=$(jget "${w6}" wallet.balance_reward)
[[ "${BAL_R}" == "50" ]] && pass "06 add reward 50 (balance_reward=${BAL_R})" || fail "06 add reward 50: ${w6}"

# 7. check balance=350 total (300 fiat + 50 reward)
w7=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/wallet/me")
BF7=$(jget "${w7}" wallet.balance_fiat)
BR7=$(jget "${w7}" wallet.balance_reward)
[[ "${BF7}" == "300" && "${BR7}" == "50" ]] && pass "07 check balance=350 (fiat=${BF7}, reward=${BR7})" || fail "07 check balance=350: ${w7}"

# 8. list transactions
w8=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/wallet/transactions")
TXN_COUNT=$(jget "${w8}" total)
[[ "${TXN_COUNT}" -eq 3 ]] && pass "08 list transactions (count=${TXN_COUNT})" || fail "08 list transactions: ${w8}"

echo
if [[ ${failures} -eq 0 ]]; then echo -e "${GREEN}All wallet endpoints passed${RESET}"; exit 0; else echo -e "${RED}${failures} failed${RESET}"; exit 1; fi
