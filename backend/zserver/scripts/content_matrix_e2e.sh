#!/usr/bin/env bash
# End-to-end HTTP regression test for the content_matrix module.
set -euo pipefail
PORT="${PORT:-18091}"
BASE="http://127.0.0.1:${PORT}"
export JWT_SECRET="${JWT_SECRET:-test-secret}"
export ONEPERSON_DEV_VERIFICATION_CODE="${ONEPERSON_DEV_VERIFICATION_CODE:-000000}"
RED="\033[0;31m"; GREEN="\033[0;32m"; RESET="\033[0m"
failures=0
pass() { echo -e "${GREEN}PASS${RESET}: $1"; }
fail() { echo -e "${RED}FAIL${RESET}: $1"; ((failures++)) || true; }
http_status() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
http_body() { curl -s "$@"; }
jget() { echo "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',d).get('$2',''))" 2>/dev/null || true; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-content-matrix-e2e.log 2>&1 &
SERVER_PID=$!
cleanup() { kill "${SERVER_PID}" >/dev/null 2>&1 || true; wait "${SERVER_PID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
for i in $(seq 1 30); do if [[ $(http_status "${BASE}/health") == "200" ]]; then break; fi; sleep 0.5; done

EMAIL="cm-e2e-$(date +%s)@example.com"
http_status -X POST -d "{\"email\":\"${EMAIL}\"}" -H "Content-Type: application/json" "${BASE}/auth/send-code" >/dev/null
auth_body=$(http_body -X POST -d "{\"email\":\"${EMAIL}\",\"code\":\"${ONEPERSON_DEV_VERIFICATION_CODE:-000000}\"}" -H "Content-Type: application/json" "${BASE}/auth/verify-code")
TOKEN=$(python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null <<< "${auth_body}")
AUTH="Authorization: Bearer ${TOKEN}"

ws_body=$(http_body -X POST -d "{\"name\":\"Content Matrix E2E\",\"slug\":\"cm-e2e-$(date +%s)\"}" -H "Content-Type: application/json" -H "${AUTH}" "${BASE}/api/workspaces")
WS_ID=$(python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null <<< "${ws_body}")
HWS="X-Workspace-Id: ${WS_ID}"

# 1. createPlatform "blog"
b1=$(http_body -X POST -d '{"name":"Blog","adapter_type":"blog"}' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/content-matrix/platforms")
BLOG_ID=$(jget "${b1}" id)
[[ -n "${BLOG_ID}" ]] && pass "01 createPlatform blog" || fail "01 createPlatform blog: ${b1}"

# 2. createPlatform "twitter"
b2=$(http_body -X POST -d '{"name":"Twitter","adapter_type":"twitter"}' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/content-matrix/platforms")
TW_ID=$(jget "${b2}" id)
[[ -n "${TW_ID}" ]] && pass "02 createPlatform twitter" || fail "02 createPlatform twitter: ${b2}"

# 3. listPlatforms
b3=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/content-matrix/platforms")
TOTAL=$(echo "${b3}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('total',0))" 2>/dev/null || echo 0)
[[ "${TOTAL}" -ge 2 ]] && pass "03 listPlatforms (total=${TOTAL})" || fail "03 listPlatforms: ${b3}"

# 4. distributeContent to 'blog' and 'twitter'
b4=$(http_body -X POST -d "{\"original_content\":\"# Hello World\\n\\nThis is a test post.\",\"platforms\":[\"${BLOG_ID}\",\"${TW_ID}\"]}" -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/content-matrix/distribute")
R4_COUNT=$(echo "${b4}" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',{}).get('results',[])))" 2>/dev/null || echo 0)
[[ "${R4_COUNT}" == "2" ]] && pass "04 distributeContent (count=${R4_COUNT})" || fail "04 distributeContent: ${b4}"

# 5. verify 2 results in listResults
b5=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/content-matrix/results")
R5_COUNT=$(echo "${b5}" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',{}).get('results',[])))" 2>/dev/null || echo 0)
[[ "${R5_COUNT}" -ge 2 ]] && pass "05 listResults (count=${R5_COUNT})" || fail "05 listResults: ${b5}"

# 6. getResult for first result
FIRST_RESULT_ID=$(echo "${b5}" | python3 -c "import sys,json; r=json.load(sys.stdin).get('data',{}).get('results',[]); print(r[0].get('id','') if r else '')" 2>/dev/null || true)
if [[ -n "${FIRST_RESULT_ID}" ]]; then
    b6=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/content-matrix/results/${FIRST_RESULT_ID}")
    R6_STATUS=$(jget "${b6}" status)
    [[ -n "${R6_STATUS}" ]] && pass "06 getResult (status=${R6_STATUS})" || fail "06 getResult: ${b6}"
else
    fail "06 getResult: no result ID found"
fi

echo
if [[ ${failures} -eq 0 ]]; then echo -e "${GREEN}All content-matrix endpoints passed${RESET}"; exit 0; else echo -e "${RED}${failures} failed${RESET}"; exit 1; fi
