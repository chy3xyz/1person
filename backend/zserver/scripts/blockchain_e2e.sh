#!/usr/bin/env bash
# End-to-end HTTP regression test for the blockchain module.
#
# Boots a fresh zserver (no-DB mode), authenticates a dev user,
# creates a scratch workspace, and exercises the public endpoints
# in `src/modules/blockchain/routes.zig`:
#   create EVM chain config / create wallet / send fake tx /
#   verify tx_hash + confirmed / get balance mock / list txs
#
# Usage:
#   ONEPERSON_DEV_VERIFICATION_CODE=000000 \
#   JWT_SECRET=test-secret \
#   ./scripts/blockchain_e2e.sh
#
# Override the port with PORT=<n>.

set -euo pipefail

PORT="${PORT:-18097}"
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
( cd "${SCRIPT_DIR}/.." && ZIG_LOCAL_CACHE_DIR=/tmp/zig-local ZIG_GLOBAL_CACHE_DIR=/tmp/zig-global zig build ) || { echo "build failed"; exit 1; }

# Start server
echo "==> starting zserver on port ${PORT}"
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-blockchain-e2e.log 2>&1 &
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
    tail -50 /tmp/zserver-blockchain-e2e.log
    exit 1
fi

# ─── Authenticate dev user ───────────────────────────────────────────
EMAIL="bc-e2e-$(date +%s)@example.com"
http_status -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${EMAIL}\"}" "${BASE}/auth/send-code" >/dev/null
code="${ONEPERSON_DEV_VERIFICATION_CODE:-000000}"
auth_body=$(http_body -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${EMAIL}\",\"code\":\"${code}\"}" "${BASE}/auth/verify-code")
TOKEN=$(jget_path "${auth_body}" token)
if [[ -z "${TOKEN}" ]]; then
    warn "auth failed: ${auth_body}"
    exit 1
fi
AUTH="Authorization: Bearer ${TOKEN}"

# ─── Workspace ───────────────────────────────────────────────────────
ws_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
    -d "{\"name\":\"Blockchain E2E\",\"slug\":\"bc-e2e-$(date +%s)\"}" \
    "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
HWS="X-Workspace-Id: ${WS_ID}"

# ─── 01. Create EVM chain config (POST /api/blockchain/configs) ─────
cc_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{"name":"Ethereum Mainnet","rpc_url":"https://eth-mainnet.example.com","chain_id":1}' \
    "${BASE}/api/blockchain/configs")
CFG_ID=$(jget_path "${cc_body}" data.id)
CFG_NAME=$(jget_path "${cc_body}" data.name)
if [[ -n "${CFG_ID}" && "${CFG_NAME}" == "Ethereum Mainnet" ]]; then
    pass "01 createConfig (id=${CFG_ID})"
else
    fail "01 createConfig: ${cc_body}"
fi

# ─── 02. Create wallet (POST /api/blockchain/wallets) ──────────────
cw_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"address\":\"0xDeadBeefCafe0000000000000000000000000001\",\"private_key_encrypted\":\"aes-encrypted-key-data\",\"chain\":\"${CFG_ID}\"}" \
    "${BASE}/api/blockchain/wallets")
WLT_ID=$(jget_path "${cw_body}" data.id)
WLT_ADDR=$(jget_path "${cw_body}" data.address)
if [[ -n "${WLT_ID}" && "${WLT_ADDR}" == "0xDeadBeefCafe0000000000000000000000000001" ]]; then
    pass "02 createWallet (id=${WLT_ID})"
else
    fail "02 createWallet: ${cw_body}"
fi

# ─── 03. Send fake transaction (POST /api/blockchain/transactions) ─
st_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"wallet_id\":\"${WLT_ID}\",\"method\":\"transfer\",\"params_json\":\"{\\\"to\\\":\\\"0x1234\\\",\\\"value\\\":\\\"0.1\\\"}\"}" \
    "${BASE}/api/blockchain/transactions")
TX_ID=$(jget_path "${st_body}" data.id)
TX_HASH=$(jget_path "${st_body}" data.tx_hash)
TX_STATUS=$(jget_path "${st_body}" data.status)
if [[ -n "${TX_ID}" && -n "${TX_HASH}" && "${TX_STATUS}" == "confirmed" ]]; then
    pass "03 sendTransaction (id=${TX_ID}, hash=${TX_HASH})"
else
    fail "03 sendTransaction: ${st_body}"
fi

# ─── 04. Verify tx_hash and confirmed status (GET /:id) ────────────
gt_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/blockchain/transactions/${TX_ID}")
GT_HASH=$(jget_path "${gt_body}" data.tx_hash)
GT_STATUS=$(jget_path "${gt_body}" data.status)
if [[ "${GT_HASH}" == "${TX_HASH}" && "${GT_STATUS}" == "confirmed" ]]; then
    pass "04 verify tx (hash=${GT_HASH}, status=${GT_STATUS})"
else
    fail "04 verify tx: ${gt_body}"
fi

# ─── 05. Get balance mock (GET /api/blockchain/wallets/:id/balance)
bal_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/blockchain/wallets/${WLT_ID}/balance")
BAL_BALANCE=$(jget_path "${bal_body}" data.balance)
BAL_SYMBOL=$(jget_path "${bal_body}" data.symbol)
if [[ "${BAL_BALANCE}" == "1.5" && "${BAL_SYMBOL}" == "ETH" ]]; then
    pass "05 getBalance (${BAL_BALANCE} ${BAL_SYMBOL})"
else
    fail "05 getBalance: ${bal_body}"
fi

# ─── 06. List transactions (GET /api/blockchain/transactions) ──────
lt_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/blockchain/transactions")
LT_COUNT=$(echo "${lt_body}" | python3 -c 'import sys,json; d=json.load(sys.stdin).get("data",[]); print(len(d))' 2>/dev/null || echo 0)
LT_FIRST_HASH=$(echo "${lt_body}" | python3 -c 'import sys,json; d=json.load(sys.stdin).get("data",[]); print(d[0]["tx_hash"] if len(d)>0 else "")' 2>/dev/null || echo "")
if [[ "${LT_COUNT}" -ge 1 && "${LT_FIRST_HASH}" == "${TX_HASH}" ]]; then
    pass "06 listTransactions (n=${LT_COUNT})"
else
    fail "06 listTransactions: ${lt_body}"
fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All 6 blockchain e2e tests passed${RESET}"
    exit 0
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
