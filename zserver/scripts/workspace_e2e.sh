#!/usr/bin/env bash
# End-to-end HTTP regression test for the workspace module.
#
# Boots a fresh zserver (no-DB mode), authenticates a dev user,
# creates a scratch workspace, and exercises the public endpoints
# in `src/modules/workspace/routes.zig`.
#
# Usage:
#   MULTICA_DEV_VERIFICATION_CODE=000000 \
#   JWT_SECRET=test-secret \
#   ./scripts/workspace_e2e.sh
#
# Override the port with PORT=<n>.

set -euo pipefail

PORT="${PORT:-18098}"
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
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-workspace-e2e.log 2>&1 &
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
    tail -50 /tmp/zserver-workspace-e2e.log
    exit 1
fi

# ─── Authenticate dev user ───────────────────────────────────────────
EMAIL="workspace-e2e-$(date +%s)@example.com"
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

# ─── 1. createWorkspace (POST /api/workspaces) ───────────────────────
ws_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
    -d "{\"name\":\"E2E Workspace\",\"slug\":\"e2e-workspace-$(date +%s)\",\"description\":\"workspace e2e\"}" \
    "${BASE}/api/workspaces")
WS_ID=$(jget_path "${ws_body}" id)
if [[ -n "${WS_ID}" ]]; then pass "01 createWorkspace"; else fail "01 createWorkspace: ${ws_body}"; fi
HWS="X-Workspace-Id: ${WS_ID}"

# ─── 2. listWorkspaces (GET /api/workspaces) ─────────────────────────
lw_body=$(http_body -H "${AUTH}" "${BASE}/api/workspaces")
LW_COUNT=$(echo "${lw_body}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
if [[ "${LW_COUNT}" -ge 1 ]]; then pass "02 listWorkspaces (n=${LW_COUNT})"; else fail "02 listWorkspaces: ${lw_body}"; fi

# ─── 3. getWorkspace (GET /api/workspaces/:id) ───────────────────────
gw_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/workspaces/${WS_ID}")
GW_ID=$(jget_path "${gw_body}" id)
if [[ "${GW_ID}" == "${WS_ID}" ]]; then pass "03 getWorkspace"; else fail "03 getWorkspace: ${gw_body}"; fi

# ─── 4. updateWorkspace (PATCH /api/workspaces/:id) ──────────────────
uw_body=$(http_body -X PATCH -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"name\":\"E2E Workspace Updated\"}" "${BASE}/api/workspaces/${WS_ID}")
UW_NAME=$(jget_path "${uw_body}" name)
if [[ "${UW_NAME}" == "E2E Workspace Updated" ]]; then pass "04 updateWorkspace"; else fail "04 updateWorkspace: ${uw_body}"; fi

# ─── 5. listMembers (GET /api/workspaces/:id/members) ────────────────
lm_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/workspaces/${WS_ID}/members")
if [[ "${lm_status}" == "200" ]]; then pass "05 listMembers (200)"; else fail "05 listMembers (${lm_status})"; fi

# ─── 6. addMember (POST /api/workspaces/:id/members) ─────────────────
# In no-DB mode this creates a pending invitation.
am_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"email\":\"invitee-$(date +%s)@example.com\",\"role\":\"member\"}" \
    "${BASE}/api/workspaces/${WS_ID}/members")
INV_ID=$(jget_path "${am_body}" id)
if [[ -n "${INV_ID}" ]]; then pass "06 addMember (invitation id=${INV_ID})"; else fail "06 addMember: ${am_body}"; fi

# ─── 7. listInvitations (GET /api/workspaces/:id/invitations) ────────
li_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/workspaces/${WS_ID}/invitations")
if [[ "${li_status}" == "200" ]]; then pass "07 listInvitations (200)"; else fail "07 listInvitations (${li_status})"; fi

# ─── 8. deleteInvitation (DELETE /api/workspaces/:id/invitations/:invitationId)
di_status=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" \
    "${BASE}/api/workspaces/${WS_ID}/invitations/${INV_ID}")
if [[ "${di_status}" == "200" || "${di_status}" == "204" ]]; then pass "08 deleteInvitation (${di_status})"; else fail "08 deleteInvitation (${di_status})"; fi

# ─── 9. listGithubInstallations (GET /api/workspaces/:id/github/installations)
lg_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/workspaces/${WS_ID}/github/installations")
if [[ "${lg_status}" == "200" ]]; then pass "09 listGithubInstallations (200)"; else fail "09 listGithubInstallations (${lg_status})"; fi

# ─── 10. listLarkInstallations (GET /api/workspaces/:id/lark/installations)
ll_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/workspaces/${WS_ID}/lark/installations")
if [[ "${ll_status}" == "200" ]]; then pass "10 listLarkInstallations (200)"; else fail "10 listLarkInstallations (${ll_status})"; fi

# ─── 11. deleteWorkspace (DELETE /api/workspaces/:id) ────────────────
dw_status=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" "${BASE}/api/workspaces/${WS_ID}")
if [[ "${dw_status}" == "200" || "${dw_status}" == "204" ]]; then pass "11 deleteWorkspace (${dw_status})"; else fail "11 deleteWorkspace (${dw_status})"; fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All workspace endpoints responded correctly${RESET}"
    exit 0
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
