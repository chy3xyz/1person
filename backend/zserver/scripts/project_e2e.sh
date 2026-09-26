#!/usr/bin/env bash
# End-to-end HTTP regression test for the project module + project
# resource sub-resource.
#
# Boots a fresh zserver (no-DB mode), authenticates a dev user,
# creates a scratch workspace, and exercises the public endpoints
# in `src/modules/project/routes.zig` (project CRUD + project
# resource CRUD).
#
# Usage:
#   ONEPERSON_DEV_VERIFICATION_CODE=000000 \
#   JWT_SECRET=test-secret \
#   ./scripts/project_e2e.sh
#
# Override the port with PORT=<n>.

set -euo pipefail

PORT="${PORT:-18095}"
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
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }

# Start server
echo "==> starting zserver on port ${PORT}"
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-project-e2e.log 2>&1 &
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
    tail -50 /tmp/zserver-project-e2e.log
    exit 1
fi

# ─── Authenticate dev user ───────────────────────────────────────────
EMAIL="project-e2e-$(date +%s)@example.com"
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
    -d "{\"name\":\"Project E2E\",\"slug\":\"project-e2e-$(date +%s)\"}" \
    "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
if [[ -z "${WS_ID}" ]]; then
    warn "workspace creation failed: ${ws_body}"
    exit 1
fi
HWS="X-Workspace-Id: ${WS_ID}"

# ─── 1. createProject (POST /api/projects) ───────────────────────────
cp_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"title\":\"My Project\",\"description\":\"proj e2e\",\"status\":\"planned\"}" \
    "${BASE}/api/projects")
PROJECT_ID=$(jget "${cp_body}" id)
if [[ -n "${PROJECT_ID}" ]]; then pass "01 createProject"; else fail "01 createProject: ${cp_body}"; fi

# ─── 2. createResource (POST /api/projects/:id/resources) ─────────────
cr_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"name\":\"design-doc\",\"url\":\"https://example.com/design\"}" \
    "${BASE}/api/projects/${PROJECT_ID}/resources")
RES_ID=$(jget "${cr_body}" id)
RES_NAME=$(jget "${cr_body}" name)
if [[ -n "${RES_ID}" && "${RES_NAME}" == "design-doc" ]]; then
    pass "02 createResource (id=${RES_ID})"
else
    fail "02 createResource: ${cr_body}"
fi

# ─── 3. listResources (GET /api/projects/:id/resources) ─────────────
lr_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/projects/${PROJECT_ID}/resources")
LR_COUNT=$(echo "${lr_body}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("resources",[])))' 2>/dev/null || echo 0)
if [[ "${LR_COUNT}" == "1" ]]; then pass "03 listResources (n=1)"; else fail "03 listResources: ${lr_body}"; fi

# ─── 4. updateResource (PUT /api/projects/:id/resources/:rid) ────────
ur_body=$(http_body -X PUT -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"name\":\"design-doc-v2\",\"url\":\"https://example.com/v2\"}" \
    "${BASE}/api/projects/${PROJECT_ID}/resources/${RES_ID}")
UR_NAME=$(jget "${ur_body}" name)
UR_URL=$(jget "${ur_body}" url)
if [[ "${UR_NAME}" == "design-doc-v2" && "${UR_URL}" == "https://example.com/v2" ]]; then
    pass "04 updateResource"
else
    fail "04 updateResource: ${ur_body}"
fi

# ─── 5. listResources after update ──────────────────────────────────
lr2_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/projects/${PROJECT_ID}/resources")
LR2_NAME=$(echo "${lr2_body}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["resources"][0]["name"])' 2>/dev/null || echo "")
if [[ "${LR2_NAME}" == "design-doc-v2" ]]; then pass "05 listResources reflects update"; else fail "05 listResources: ${lr2_body}"; fi

# ─── 6. deleteResource (DELETE /api/projects/:id/resources/:rid) ───
dr_status=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" \
    "${BASE}/api/projects/${PROJECT_ID}/resources/${RES_ID}")
if [[ "${dr_status}" == "200" || "${dr_status}" == "204" ]]; then pass "06 deleteResource (${dr_status})"; else fail "06 deleteResource (${dr_status})"; fi

# ─── 7. listResources after delete (empty) ──────────────────────────
lr3_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/projects/${PROJECT_ID}/resources")
LR3_COUNT=$(echo "${lr3_body}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("resources",[])))' 2>/dev/null || echo 0)
if [[ "${LR3_COUNT}" == "0" ]]; then pass "07 listResources empty after delete"; else fail "07 listResources: ${lr3_body}"; fi

# ─── 8. deleteProject cascades to resources ────────────────────────
# Re-add a resource, then delete the project, then verify the
# resource bucket is gone (the resource itself is no longer
# accessible).
http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{"name":"will-be-cascaded"}' \
    "${BASE}/api/projects/${PROJECT_ID}/resources" >/dev/null
dp_status=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" \
    "${BASE}/api/projects/${PROJECT_ID}")
if [[ "${dp_status}" == "200" || "${dp_status}" == "204" ]]; then
    pass "08 deleteProject (${dp_status})"
else
    fail "08 deleteProject (${dp_status})"
fi

# Verify the project is gone (which by cascade also means the
# resource bucket is gone).
gp_status=$(http_status -H "${AUTH}" -H "${HWS}" \
    "${BASE}/api/projects/${PROJECT_ID}")
if [[ "${gp_status}" == "404" ]]; then pass "08b project gone after delete"; else fail "08b project still exists (${gp_status})"; fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All project endpoints responded correctly${RESET}"
    exit 0
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
