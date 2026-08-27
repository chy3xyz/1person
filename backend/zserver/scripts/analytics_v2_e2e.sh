#!/usr/bin/env bash
# End-to-end test for analytics_v2 advanced analytics engine.
set -euo pipefail
PORT="${PORT:-18088}"
BASE="http://127.0.0.1:${PORT}"
export JWT_SECRET="${JWT_SECRET:-test-secret}"
export MULTICA_DEV_VERIFICATION_CODE="${MULTICA_DEV_VERIFICATION_CODE:-000000}"
RED="\033[0;31m"; GREEN="\033[0;32m"; RESET="\033[0m"
failures=0
pass() { echo -e "${GREEN}PASS${RESET}: $1"; }
fail() { echo -e "${RED}FAIL${RESET}: $1"; ((failures++)) || true; }
http_status() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
http_body() { curl -s "$@"; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-analyticsv2-e2e.log 2>&1 &
SERVER_PID=$!
cleanup() { kill "${SERVER_PID}" >/dev/null 2>&1 || true; wait "${SERVER_PID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
for i in $(seq 1 30); do if [[ $(http_status "${BASE}/health") == "200" ]]; then break; fi; sleep 0.5; done

# Auth
EMAIL="av2-$(date +%s)@e.com"
http_status -X POST -d "{\"email\":\"${EMAIL}\"}" -H "Content-Type: application/json" "${BASE}/auth/send-code" >/dev/null
TOKEN=$(http_body -X POST -d "{\"email\":\"${EMAIL}\",\"code\":\"${MULTICA_DEV_VERIFICATION_CODE:-000000}\"}" -H "Content-Type: application/json" "${BASE}/auth/verify-code" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
AUTH="Authorization: Bearer ${TOKEN}"
WS=$(http_body -X POST -d "{\"name\":\"AnalyticsV2\",\"slug\":\"av2-$(date +%s)\"}" -H "Content-Type: application/json" -H "${AUTH}" "${BASE}/api/workspaces")
WS_ID=$(echo "$WS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
HWS="X-Workspace-Id: ${WS_ID}"
NOW=$(date +%s)
T1=$((NOW - 100))
T2=$((NOW + 100))

# 1. Track 3 metrics
c1a=$(http_body -X POST -d "{\"name\":\"cpu_usage\",\"value\":42.5,\"labels\":\"{\\\"host\\\":\\\"node-1\\\"}\"}" -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/analytics/track")
OK1A=$(echo "$c1a" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("ok"))' 2>/dev/null || echo false)
[[ "${OK1A}" == "True" ]] && pass "01 track cpu_usage" || fail "01 track cpu_usage: ${c1a}"

c1b=$(http_body -X POST -d "{\"name\":\"mem_usage\",\"value\":67.8}" -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/analytics/track")
OK1B=$(echo "$c1b" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("ok"))' 2>/dev/null || echo false)
[[ "${OK1B}" == "True" ]] && pass "02 track mem_usage" || fail "02 track mem_usage: ${c1b}"

c1c=$(http_body -X POST -d "{\"name\":\"cpu_usage\",\"value\":55.1,\"labels\":\"{\\\"host\\\":\\\"node-2\\\"}\"}" -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/analytics/track")
OK1C=$(echo "$c1c" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("ok"))' 2>/dev/null || echo false)
[[ "${OK1C}" == "True" ]] && pass "03 track cpu_usage (2nd)" || fail "03 track cpu_usage (2nd): ${c1c}"

# 2. Query time series
c2=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/analytics/query?name=cpu_usage&from=${T1}&to=${T2}")
P2_COUNT=$(echo "$c2" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("points",[])))' 2>/dev/null || echo 0)
[[ "${P2_COUNT}" -ge 2 ]] && pass "04 query time series (${P2_COUNT} points)" || fail "04 query time series: ${c2}"

# 3. Generate report
c3=$(http_body -X POST -d "{\"name\":\"test-report\",\"metrics\":[\"cpu_usage\",\"mem_usage\"],\"from_ts\":${T1},\"to_ts\":${T2},\"format\":\"json\"}" -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/analytics/reports")
RPT_ID=$(echo "$c3" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || echo "")
RPT_STATUS=$(echo "$c3" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || echo "")
[[ -n "${RPT_ID}" && "${RPT_STATUS}" == "completed" ]] && pass "05 generate report (${RPT_ID})" || fail "05 generate report: ${c3}"

# 4. List reports
c4=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/analytics/reports")
R4_COUNT=$(echo "$c4" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("reports",[])))' 2>/dev/null || echo 0)
[[ "${R4_COUNT}" -ge 1 ]] && pass "06 list reports (${R4_COUNT})" || fail "06 list reports: ${c4}"

# 5. Get report by id
c5=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/analytics/reports/${RPT_ID}")
R5_NAME=$(echo "$c5" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || echo "")
R5_POINTS=$(echo "$c5" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("points",[])))' 2>/dev/null || echo 0)
[[ "${R5_NAME}" == "test-report" && "${R5_POINTS}" -ge 1 ]] && pass "07 get report (${R5_POINTS} points)" || fail "07 get report: ${c5}"

echo
if [[ ${failures} -eq 0 ]]; then echo -e "${GREEN}All analytics_v2 endpoints passed${RESET}"; exit 0; else echo -e "${RED}${failures} failed${RESET}"; exit 1; fi
