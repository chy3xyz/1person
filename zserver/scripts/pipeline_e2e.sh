#!/usr/bin/env bash
# End-to-end HTTP regression test for the pipeline module.
#
# Usage:
#   MULTICA_DEV_VERIFICATION_CODE=000000 \
#   JWT_SECRET=test-secret \
#   ./scripts/pipeline_e2e.sh

set -euo pipefail

PORT="${PORT:-18089}"
BASE="http://127.0.0.1:${PORT}"
JWT_SECRET="${JWT_SECRET:-test-secret}"
export JWT_SECRET
export DATABASE_URL="${DATABASE_URL:-}"

RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; RESET="\033[0m"
failures=0
pass() { echo -e "${GREEN}PASS${RESET}: $1"; }
fail() { echo -e "${RED}FAIL${RESET}: $1"; ((failures++)) || true; }

http_status() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
http_body() { curl -s "$@"; }
jget() { echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$2',''))" 2>/dev/null || true; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "==> building zserver"
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }

echo "==> starting zserver on port ${PORT}"
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-pipeline-e2e.log 2>&1 &
SERVER_PID=$!
cleanup() { kill "${SERVER_PID}" >/dev/null 2>&1 || true; wait "${SERVER_PID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

for i in $(seq 1 30); do
    if [[ $(http_status "${BASE}/health") == "200" ]]; then break; fi; sleep 0.5
done

EMAIL="pipe-e2e-$(date +%s)@example.com"
http_status -X POST -H "Content-Type: application/json" -d "{\"email\":\"${EMAIL}\"}" "${BASE}/auth/send-code" >/dev/null
code="${MULTICA_DEV_VERIFICATION_CODE:-000000}"
auth_body=$(http_body -X POST -H "Content-Type: application/json" -d "{\"email\":\"${EMAIL}\",\"code\":\"${code}\"}" "${BASE}/auth/verify-code")
TOKEN=$(jget "${auth_body}" token)
AUTH="Authorization: Bearer ${TOKEN}"

ws_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -d "{\"name\":\"Pipeline E2E\",\"slug\":\"pipe-e2e-$(date +%s)\"}" "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
HWS="X-Workspace-Id: ${WS_ID}"

# 1. createPipelineConfig
c1=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
  -d '{"name":"Test Pipeline","description":"e2e test","phases":[{"id":"p1","name":"Phase 1","agent":"test-agent","depends_on":[],"timeout_seconds":3600,"max_retries":3,"approval_gate":false,"artifact_pattern":""},{"id":"p2","name":"Phase 2","agent":"test-agent","depends_on":["p1"],"timeout_seconds":1800,"max_retries":2,"approval_gate":true,"artifact_pattern":"docs/*"}]}' \
  "${BASE}/api/pipelines")
PIPE_ID=$(jget "${c1}" id)
[[ -n "${PIPE_ID}" ]] && pass "01 create" || fail "01 create: ${c1}"

# 2. listPipelineConfigs
c2=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/pipelines")
P2_COUNT=$(echo "${c2}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("pipelines",[])))' 2>/dev/null || echo 0)
[[ "${P2_COUNT}" -ge 1 ]] && pass "02 list (n=${P2_COUNT})" || fail "02 list: ${c2}"

# 3. getPipelineConfig
c3=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/pipelines/${PIPE_ID}")
P3_NAME=$(jget "${c3}" name)
[[ "${P3_NAME}" == "Test Pipeline" ]] && pass "03 get" || fail "03 get: ${c3}"

# 4. updatePipelineConfig
c4=$(http_body -X PATCH -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" -d '{"name":"Updated","description":"updated desc","phases":[{"id":"p1","name":"Only","agent":"x","depends_on":[],"timeout_seconds":60,"max_retries":1,"approval_gate":false,"artifact_pattern":""}]}' "${BASE}/api/pipelines/${PIPE_ID}")
P4_NAME=$(jget "${c4}" name)
[[ "${P4_NAME}" == "Updated" ]] && pass "04 update" || fail "04 update: ${c4}"

# 5. startPipeline
c5=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" -d '{}' "${BASE}/api/pipelines/${PIPE_ID}/start")
R_ID=$(jget "${c5}" id)
[[ -n "${R_ID}" ]] && pass "05 start (run=${R_ID})" || fail "05 start: ${c5}"

# 6. listPipelineRuns
c6=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/pipelines/${PIPE_ID}/runs")
R6_COUNT=$(echo "${c6}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("runs",[])))' 2>/dev/null || echo 0)
[[ "${R6_COUNT}" -ge 1 ]] && pass "06 list runs (n=${R6_COUNT})" || fail "06 list runs: ${c6}"

# 7. getPipelineRun
c7=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/pipelines/${PIPE_ID}/runs/${R_ID}")
R7_STATUS=$(jget "${c7}" status)
[[ "${R7_STATUS}" == "running" ]] && pass "07 get run (${R7_STATUS})" || fail "07 get run: ${c7}"

# 8. completePhase
c8=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" -d '{}' "${BASE}/api/pipelines/${PIPE_ID}/runs/${R_ID}/phases/p1/complete")
R8_STATUS=$(jget "${c8}" status)
[[ "${R8_STATUS}" == "done" ]] && pass "08 complete phase (${R8_STATUS})" || fail "08 complete phase: ${c8}"

# 9. deletePipelineConfig
c9=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" "${BASE}/api/pipelines/${PIPE_ID}")
[[ "${c9}" == "200" || "${c9}" == "204" ]] && pass "09 delete (${c9})" || fail "09 delete (${c9})"

# 10. get after delete → 404
c10=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/pipelines/${PIPE_ID}")
[[ "${c10}" == "404" ]] && pass "10 get 404 (deleted)" || fail "10 get 404 (${c10})"

echo
if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All pipeline endpoints responded correctly${RESET}"; exit 0
else
    echo -e "${RED}${failures} check(s) failed${RESET}"; exit 1
fi
