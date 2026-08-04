#!/usr/bin/env bash
# End-to-end HTTP regression test for the cloud_runtime module.
#
# Boots a fresh zserver (no-DB mode), authenticates a dev user,
# creates a scratch workspace, then exercises the public endpoints
# in `src/modules/cloud_runtime/routes.zig`.
#
# Usage:
#   MULTICA_DEV_VERIFICATION_CODE=000000 \
#   JWT_SECRET=test-secret \
#   ./scripts/cloud_runtime_e2e.sh
#
# Override the port with PORT=<n>.

set -euo pipefail

PORT="${PORT:-18092}"
BASE="http://127.0.0.1:${PORT}"
JWT_SECRET="${JWT_SECRET:-test-secret}"
export JWT_SECRET

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
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }

# Start server
echo "==> starting zserver on port ${PORT}"
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-cloud-runtime-e2e.log 2>&1 &
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
    tail -50 /tmp/zserver-cloud-runtime-e2e.log
    exit 1
fi

# ─── Authenticate dev user ───────────────────────────────────────────
EMAIL="cloud-runtime-e2e-$(date +%s)@example.com"
http_status -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${EMAIL}\"}" "${BASE}/auth/send-code" >/dev/null
code="${MULTICA_DEV_VERIFICATION_CODE:-000000}"
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
    -d "{\"name\":\"Cloud Runtime E2E\",\"slug\":\"cloud-runtime-e2e-$(date +%s)\"}" \
    "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
HWS="X-Workspace-Id: ${WS_ID}"

# ─── 1. createCloudNode (POST /api/cloud-runtime/nodes) ──────────
cn_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"name\":\"node-a\",\"region\":\"us-east-1\",\"size\":\"small\"}" \
    "${BASE}/api/cloud-runtime/nodes")
NODE_ID=$(jget "${cn_body}" id)
NODE_STATUS=$(jget "${cn_body}" status)
if [[ -n "${NODE_ID}" && "${NODE_STATUS}" == "provisioning" ]]; then
    pass "01 createCloudNode (id=${NODE_ID})"
else
    fail "01 createCloudNode: ${cn_body}"
fi

# ─── 2. listCloudNodes (GET /api/cloud-runtime/nodes) ────────────
ln_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/cloud-runtime/nodes")
LN_COUNT=$(echo "${ln_body}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("nodes",[])))' 2>/dev/null || echo 0)
if [[ "${LN_COUNT}" -ge 1 ]]; then pass "02 listCloudNodes (n=${LN_COUNT})"; else fail "02 listCloudNodes: ${ln_body}"; fi

# ─── 3. getCloudNodeStatus (initial = provisioning) ────────────
gs_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/cloud-runtime/nodes/${NODE_ID}/status")
GS_STATUS=$(jget "${gs_body}" status)
if [[ "${GS_STATUS}" == "provisioning" ]]; then pass "03 initial status provisioning"; else fail "03 status: ${gs_body}"; fi

# ─── 4. startCloudNode (POST /:id/start) ─────────────────────────
st_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{}' "${BASE}/api/cloud-runtime/nodes/${NODE_ID}/start")
ST_STATUS=$(jget "${st_body}" status)
if [[ "${ST_STATUS}" == "running" ]]; then pass "04 startCloudNode (running)"; else fail "04 start: ${st_body}"; fi

# ─── 5. status reflects running ─────────────────────────────────
gs2_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/cloud-runtime/nodes/${NODE_ID}/status")
GS2_STATUS=$(jget "${gs2_body}" status)
if [[ "${GS2_STATUS}" == "running" ]]; then pass "05 status after start (running)"; else fail "05 status: ${gs2_body}"; fi

# ─── 6. execOnCloudNode (POST /:id/exec) ─────────────────────────
ex_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{"command":"ls","args":["-la","/"]}' "${BASE}/api/cloud-runtime/nodes/${NODE_ID}/exec")
EX_CODE=$(jget "${ex_body}" exit_code)
if [[ "${EX_CODE}" == "0" ]]; then pass "06 execOnCloudNode (exit_code=0)"; else fail "06 exec: ${ex_body}"; fi

# ─── 7. stopCloudNode (POST /:id/stop) ─────────────────────────
sp_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{}' "${BASE}/api/cloud-runtime/nodes/${NODE_ID}/stop")
SP_STATUS=$(jget "${sp_body}" status)
if [[ "${SP_STATUS}" == "stopped" ]]; then pass "07 stopCloudNode (stopped)"; else fail "07 stop: ${sp_body}"; fi

# ─── 8. rebootCloudNode (POST /:id/reboot) ──────────────────────
rb_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{}' "${BASE}/api/cloud-runtime/nodes/${NODE_ID}/reboot")
RB_STATUS=$(jget "${rb_body}" status)
if [[ "${RB_STATUS}" == "rebooting" ]]; then pass "08 rebootCloudNode (rebooting)"; else fail "08 reboot: ${rb_body}"; fi

# ─── 9. unknown id 404 on status ────────────────────────────────
nf_status=$(http_status -H "${AUTH}" -H "${HWS}" \
    "${BASE}/api/cloud-runtime/nodes/does-not-exist/status")
if [[ "${nf_status}" == "404" ]]; then pass "09 status unknown id (404)"; else fail "09 status unknown (${nf_status})"; fi

# ─── 9b. missing node_id path param (start) 400 ─────────────────
nb_status=$(http_status -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{}' "${BASE}/api/cloud-runtime/nodes//start")
# Some servers respond 404 for empty path segments; accept both.
if [[ "${nb_status}" == "400" || "${nb_status}" == "404" ]]; then pass "09b start empty id (${nb_status})"; else fail "09b start empty (${nb_status})"; fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All cloud runtime endpoints responded correctly${RESET}"
    exit 0
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
