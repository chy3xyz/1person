#!/usr/bin/env bash
# End-to-end HTTP regression test for the role module.
#
# Boots a fresh zserver (no-DB mode), authenticates a dev user,
# creates a scratch workspace, and exercises the public endpoints
# in src/modules/role/routes.zig:
#   - RoleConfig CRUD (defs)
#   - MemberRole assign + update + delete (members)
#   - Hierarchical queries (downline / upline)
#
# Usage:
#   MULTICA_DEV_VERIFICATION_CODE=000000 \
#   JWT_SECRET=test-secret \
#   ./scripts/role_e2e.sh
#
# Override the port with PORT=<n>.

set -euo pipefail

PORT="${PORT:-18096}"
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

# Build
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "==> building zserver"
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }

# Start server
echo "==> starting zserver on port ${PORT}"
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-role-e2e.log 2>&1 &
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
    tail -50 /tmp/zserver-role-e2e.log
    exit 1
fi

# ─── Authenticate dev user ───────────────────────────────────────────
EMAIL="role-e2e-$(date +%s)@example.com"
http_status -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${EMAIL}\"}" "${BASE}/auth/send-code" >/dev/null
code="${MULTICA_DEV_VERIFICATION_CODE:-000000}"
auth_body=$(http_body -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${EMAIL}\",\"code\":\"${code}\"}" "${BASE}/auth/verify-code")
TOKEN=$(echo "${auth_body}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null || true)
if [[ -z "${TOKEN}" ]]; then
    warn "auth failed: ${auth_body}"
    exit 1
fi
AUTH="Authorization: Bearer ${TOKEN}"

# ─── Workspace ───────────────────────────────────────────────────────
ws_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
    -d "{\"name\":\"Role E2E\",\"slug\":\"role-e2e-$(date +%s)\"}" \
    "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
if [[ -z "${WS_ID}" ]]; then
    warn "workspace creation failed: ${ws_body}"
    exit 1
fi
HWS="X-Workspace-Id: ${WS_ID}"

# ─── 01. createRoleConfig (admin) ─────────────────────────────────────
admin_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{"name":"admin","permissions":"read,write,delete","upgrade_conditions":"reports>=5","level":3}' \
    "${BASE}/api/roles/defs")
ADMIN_ID=$(jget "${admin_body}" id)
ADMIN_NAME=$(jget "${admin_body}" name)
if [[ -n "${ADMIN_ID}" && "${ADMIN_NAME}" == "admin" ]]; then
    pass "01 createRoleConfig (admin)"
else
    fail "01 createRoleConfig (admin): ${admin_body}"
fi

# ─── 02. createRoleConfig (member) ────────────────────────────────────
member_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{"name":"member","permissions":"read","upgrade_conditions":"tasks>=10","level":1}' \
    "${BASE}/api/roles/defs")
MEMBER_ID=$(jget "${member_body}" id)
MEMBER_NAME=$(jget "${member_body}" name)
if [[ -n "${MEMBER_ID}" && "${MEMBER_NAME}" == "member" ]]; then
    pass "02 createRoleConfig (member)"
else
    fail "02 createRoleConfig (member): ${member_body}"
fi

# ─── 03. listRoleConfigs ──────────────────────────────────────────────
list_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/roles/defs")
LIST_COUNT=$(echo "${list_body}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("defs",[])))' 2>/dev/null || echo 0)
if [[ "${LIST_COUNT}" -ge 2 ]]; then
    pass "03 listRoleConfigs (count=${LIST_COUNT})"
else
    fail "03 listRoleConfigs: ${list_body}"
fi

# ─── 04. getRoleConfig ────────────────────────────────────────────────
get_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/roles/defs/${ADMIN_ID}")
GOT_NAME=$(jget "${get_body}" name)
GOT_LEVEL=$(jget "${get_body}" level)
if [[ "${GOT_NAME}" == "admin" && "${GOT_LEVEL}" == "3" ]]; then
    pass "04 getRoleConfig (admin)"
else
    fail "04 getRoleConfig: ${get_body}"
fi

# ─── 05. updateRoleConfig ─────────────────────────────────────────────
upd_body=$(http_body -X PATCH -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{"permissions":"read,write","level":2}' \
    "${BASE}/api/roles/defs/${MEMBER_ID}")
UPD_PERM=$(jget "${upd_body}" permissions)
UPD_LEVEL=$(jget "${upd_body}" level)
if [[ "${UPD_PERM}" == "read,write" && "${UPD_LEVEL}" == "2" ]]; then
    pass "05 updateRoleConfig (member)"
else
    fail "05 updateRoleConfig: ${upd_body}"
fi

# ─── 06. assignRole A (admin) ─────────────────────────────────────────
assign_a_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"user_id\":\"user-a\",\"role\":\"admin\",\"level\":3}" \
    "${BASE}/api/roles/members")
A_ROLE=$(jget "${assign_a_body}" role)
A_UID=$(jget "${assign_a_body}" user_id)
if [[ "${A_ROLE}" == "admin" && "${A_UID}" == "user-a" ]]; then
    pass "06 assignRole (user-a = admin)"
else
    fail "06 assignRole (user-a): ${assign_a_body}"
fi

# ─── 07. assignRole B with parent A ───────────────────────────────────
assign_b_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"user_id\":\"user-b\",\"role\":\"member\",\"level\":1,\"parent_id\":\"user-a\"}" \
    "${BASE}/api/roles/members")
B_ROLE=$(jget "${assign_b_body}" role)
B_PARENT=$(jget "${assign_b_body}" parent_id)
if [[ "${B_ROLE}" == "member" && "${B_PARENT}" == "user-a" ]]; then
    pass "07 assignRole (user-b = member, parent=user-a)"
else
    fail "07 assignRole (user-b): ${assign_b_body}"
fi

# ─── 08. getDownlineTree (user-a → should include user-b) ─────────────
down_body=$(http_body -H "${AUTH}" -H "${HWS}" \
    "${BASE}/api/roles/members/user-a/downline")
DOWN_COUNT=$(echo "${down_body}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("downline",[])))' 2>/dev/null || echo 0)
DOWN_FIRST=$(echo "${down_body}" | python3 -c 'import sys,json; items=json.load(sys.stdin).get("downline",[]); print(items[0]["user_id"] if len(items)>0 else "")' 2>/dev/null || echo "")
if [[ "${DOWN_COUNT}" == "1" && "${DOWN_FIRST}" == "user-b" ]]; then
    pass "08 getDownlineTree (user-a → [user-b])"
else
    fail "08 getDownlineTree: ${down_body}"
fi

# ─── 09. getUplineChain (user-b → should include user-a) ──────────────
up_body=$(http_body -H "${AUTH}" -H "${HWS}" \
    "${BASE}/api/roles/members/user-b/upline")
UP_COUNT=$(echo "${up_body}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("upline",[])))' 2>/dev/null || echo 0)
UP_FIRST=$(echo "${up_body}" | python3 -c 'import sys,json; items=json.load(sys.stdin).get("upline",[]); print(items[0]["user_id"] if len(items)>0 else "")' 2>/dev/null || echo "")
if [[ "${UP_COUNT}" == "1" && "${UP_FIRST}" == "user-a" ]]; then
    pass "09 getUplineChain (user-b → [user-a])"
else
    fail "09 getUplineChain: ${up_body}"
fi

# ─── 10. deleteMemberRole ─────────────────────────────────────────────
del_status=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" \
    "${BASE}/api/roles/members/user-b")
if [[ "${del_status}" == "200" || "${del_status}" == "204" ]]; then
    pass "10 deleteMemberRole (user-b, status=${del_status})"
else
    fail "10 deleteMemberRole (user-b): ${del_status}"
fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All role endpoints responded correctly (10 PASS)${RESET}"
    exit 0
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
