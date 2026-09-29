#!/usr/bin/env bash
# End-to-end test for dashboard V2 configurable analytics endpoints
# (/dashboard/config, /dashboard/widget/:name — served by
# src/modules/dashboard/routes.zig; the standalone dashboard_v2 module was
# folded into dashboard).
set -euo pipefail
PORT="${PORT:-18087}"
BASE="http://127.0.0.1:${PORT}"
export JWT_SECRET="${JWT_SECRET:-test-secret}"
RED="\033[0;31m"; GREEN="\033[0;32m"; RESET="\033[0m"
failures=0
pass() { echo -e "${GREEN}PASS${RESET}: $1"; }
fail() { echo -e "${RED}FAIL${RESET}: $1"; ((failures++)) || true; }
http_status() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
http_body() { curl -s "$@"; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-dashv2-e2e.log 2>&1 &
SERVER_PID=$!
cleanup() { kill "${SERVER_PID}" >/dev/null 2>&1 || true; wait "${SERVER_PID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
for i in $(seq 1 30); do if [[ $(http_status "${BASE}/health") == "200" ]]; then break; fi; sleep 0.5; done

# Auth
EMAIL="dv2-$(date +%s)@e.com"
http_status -X POST -d "{\"email\":\"${EMAIL}\"}" -H "Content-Type: application/json" "${BASE}/auth/send-code" >/dev/null
TOKEN=$(http_body -X POST -d "{\"email\":\"${EMAIL}\",\"code\":\"${ONEPERSON_DEV_VERIFICATION_CODE:-000000}\"}" -H "Content-Type: application/json" "${BASE}/auth/verify-code" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
AUTH="Authorization: Bearer ${TOKEN}"
WS=$(http_body -X POST -d "{\"name\":\"DashV2\",\"slug\":\"dv2-$(date +%s)\"}" -H "Content-Type: application/json" -H "${AUTH}" "${BASE}/api/workspaces")
WS_ID=$(echo "$WS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
HWS="X-Workspace-Id: ${WS_ID}"

# 1. getDashboardConfig
c1=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/dashboard/config")
WIDGETS=$(echo "$c1" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("widgets",[])))' 2>/dev/null || echo 0)
[[ "${WIDGETS}" -ge 1 ]] && pass "01 config (${WIDGETS} widgets)" || fail "01 config: ${c1}"

# 2. getDashboardData revenue
c2=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/dashboard/widget/revenue")
R2_LABELS=$(echo "$c2" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("labels",[])))' 2>/dev/null || echo 0)
[[ "${R2_LABELS}" -ge 1 ]] && pass "02 widget revenue (${R2_LABELS} labels)" || fail "02 widget revenue: ${c2}"

# 3. getDashboardData users
c3=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/dashboard/widget/users")
R3_LABELS=$(echo "$c3" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("labels",[])))' 2>/dev/null || echo 0)
[[ "${R3_LABELS}" -ge 1 ]] && pass "03 widget users (${R3_LABELS} labels)" || fail "03 widget users: ${c3}"

# 4. unknown widget 404
c4=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/dashboard/widget/nope")
[[ "${c4}" == "404" ]] && pass "04 widget 404" || fail "04 widget 404: ${c4}"

echo
if [[ ${failures} -eq 0 ]]; then echo -e "${GREEN}All dashboard V2 endpoints passed${RESET}"; exit 0; else echo -e "${RED}${failures} failed${RESET}"; exit 1; fi
