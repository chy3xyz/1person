#!/usr/bin/env bash
# End-to-end HTTP test for workspace multi-tenancy V2 endpoints.
#
# Boots a fresh zserver (no-DB mode), authenticates a dev user,
# creates a root workspace, then exercises:
#   1. POST /api/workspaces/children   – create child workspace
#   2. POST /api/workspaces/children   – create 2nd child
#   3. GET  /api/workspaces/:id/children – list children
#   4. GET  /api/workspaces/tree       – full hierarchy
#   5. PUT  /api/workspaces/:id/limits – set limits
#   6. GET  /api/workspaces/:id/limits – get limits
#
# Usage:
#   MULTICA_DEV_VERIFICATION_CODE=000000 \
#   JWT_SECRET=test-secret \
#   ./scripts/workspace_tree_e2e.sh
#
# Override the port with PORT=<n>.

set -euo pipefail

PORT="${PORT:-18099}"
BASE="http://127.0.0.1:${PORT}"
JWT_SECRET="${JWT_SECRET:-test-secret}"
# Force no-DB mode so we exercise the in-memory fallback.
export JWT_SECRET
export DATABASE_URL=""

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

jget_path() {
    local body="$1" path="$2"
    echo "${body}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for k in '${path}'.split('.'):
    if isinstance(d, dict) and k in d:
        d = d[k]
    elif isinstance(d, list) and k.isdigit() and int(k) < len(d):
        d = d[int(k)]
    else:
        print(''); sys.exit(0)
print(d if not isinstance(d, (dict, list)) else json.dumps(d))
" 2>/dev/null || true
}

jlen() {
    local body="$1"
    echo "${body}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0
}

# Build
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "==> building zserver"
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }

# Start server
echo "==> starting zserver on port ${PORT}"
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-workspace-tree-e2e.log 2>&1 &
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
    tail -50 /tmp/zserver-workspace-tree-e2e.log
    exit 1
fi

# ─── Authenticate dev user ───────────────────────────────────────────
EMAIL="wstree-e2e-$(date +%s)@example.com"
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

# ─── Create root workspace ────────────────────────────────────────────
ws_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
    -d "{\"name\":\"Root Workspace\",\"slug\":\"root-ws-$(date +%s)\",\"description\":\"root for tree e2e\"}" \
    "${BASE}/api/workspaces")
ROOT_ID=$(jget_path "${ws_body}" id)
if [[ -z "${ROOT_ID}" ]]; then
    warn "failed to create root workspace: ${ws_body}"
    exit 1
fi
echo "root workspace id: ${ROOT_ID}"
HROOT="X-Workspace-Id: ${ROOT_ID}"

# ─── 1. POST /api/workspaces/children  – create child A ────────────────
CHILD_A_SLUG="child-a-$(date +%s)"
child_a_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HROOT}" \
    -d "{\"parent_id\":\"${ROOT_ID}\",\"name\":\"Child A\",\"slug\":\"${CHILD_A_SLUG}\"}" \
    "${BASE}/api/workspaces/children")
CHILD_A_ID=$(jget_path "${child_a_body}" id)
if [[ -n "${CHILD_A_ID}" ]]; then pass "01 createChildWorkspace A (id=${CHILD_A_ID:0:8}...)"; else fail "01 createChildWorkspace A: ${child_a_body}"; fi

# ─── 2. POST /api/workspaces/children  – create child B ────────────────
CHILD_B_SLUG="child-b-$(date +%s)"
child_b_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HROOT}" \
    -d "{\"parent_id\":\"${ROOT_ID}\",\"name\":\"Child B\",\"slug\":\"${CHILD_B_SLUG}\"}" \
    "${BASE}/api/workspaces/children")
CHILD_B_ID=$(jget_path "${child_b_body}" id)
if [[ -n "${CHILD_B_ID}" ]]; then pass "02 createChildWorkspace B (id=${CHILD_B_ID:0:8}...)"; else fail "02 createChildWorkspace B: ${child_b_body}"; fi

# ─── 3. GET /api/workspaces/:id/children – list children ────────────────
children_body=$(http_body -H "${AUTH}" -H "${HROOT}" "${BASE}/api/workspaces/${ROOT_ID}/children")
CHILDREN_COUNT=$(jlen "${children_body}")
if [[ "${CHILDREN_COUNT}" -ge 2 ]]; then pass "03 getChildren (count=${CHILDREN_COUNT})"; else fail "03 getChildren (count=${CHILDREN_COUNT}): ${children_body}"; fi

# ─── 4. GET /api/workspaces/tree – full hierarchy ──────────────────────
tree_body=$(http_body -H "${AUTH}" "${BASE}/api/workspaces/tree")
TREE_LEN=$(jlen "${tree_body}")
# Tree should have at least the root workspace as a top-level node
ROOT_IN_TREE=$(jget_path "${tree_body}" "0.id")
if [[ -n "${ROOT_IN_TREE}" ]]; then pass "04 getWorkspaceTree (root_nodes=${TREE_LEN})"; else fail "04 getWorkspaceTree: ${tree_body}"; fi

# ─── 5. PUT /api/workspaces/:id/limits – set limits ────────────────────
limit_body=$(http_body -X PUT -H "Content-Type: application/json" -H "${AUTH}" -H "${HROOT}" \
    -d "{\"max_members\":50,\"max_storage\":107374182400,\"max_api_calls\":10000}" \
    "${BASE}/api/workspaces/${ROOT_ID}/limits")
MAX_MEMBERS=$(jget_path "${limit_body}" max_members)
if [[ "${MAX_MEMBERS}" == "50" ]]; then pass "05 setLimit (max_members=50)"; else fail "05 setLimit: ${limit_body}"; fi

# ─── 6. GET /api/workspaces/:id/limits – get limits ─────────────────────
get_limit_body=$(http_body -H "${AUTH}" -H "${HROOT}" "${BASE}/api/workspaces/${ROOT_ID}/limits")
LIMIT_MEMBERS=$(jget_path "${get_limit_body}" max_members)
LIMIT_STORAGE=$(jget_path "${get_limit_body}" max_storage)
if [[ "${LIMIT_MEMBERS}" == "50" && "${LIMIT_STORAGE}" == "107374182400" ]]; then
    pass "06 getLimit (max_members=${LIMIT_MEMBERS}, max_storage=${LIMIT_STORAGE})"
else
    fail "06 getLimit: ${get_limit_body}"
fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All workspace multi-tenancy V2 endpoints responded correctly${RESET}"
    exit 0
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
