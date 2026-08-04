#!/usr/bin/env bash
# End-to-end HTTP regression test for the agent_template module.
#
# Boots a fresh zserver (no-DB mode), authenticates a dev user,
# creates a scratch workspace, and exercises the public endpoints
# in `src/modules/agent_template/routes.zig`:
#   list / create / get / update / delete
#
# Usage:
#   MULTICA_DEV_VERIFICATION_CODE=000000 \
#   JWT_SECRET=test-secret \
#   ./scripts/agent_template_e2e.sh
#
# Override the port with PORT=<n>.

set -euo pipefail

PORT="${PORT:-18090}"
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
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-agent-template-e2e.log 2>&1 &
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
    tail -50 /tmp/zserver-agent-template-e2e.log
    exit 1
fi

# ─── Authenticate dev user ───────────────────────────────────────────
EMAIL="agent-template-e2e-$(date +%s)@example.com"
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
    -d "{\"name\":\"AgentTemplate E2E\",\"slug\":\"agent-template-e2e-$(date +%s)\"}" \
    "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
HWS="X-Workspace-Id: ${WS_ID}"

# ─── 1. listTemplates (initial — may include seed data) ──────────
lt_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/agent-templates")
LT_COUNT=$(echo "${lt_body}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d, list) else len(d.get("templates", d.get("data", d.get("items", [])))))' 2>/dev/null || echo 0)
if [[ "${LT_COUNT}" -ge 0 ]]; then pass "01 listTemplates (n=${LT_COUNT})"; else fail "01 listTemplates: ${lt_body}"; fi

SLUG="custom-$(date +%s)-$RANDOM"

# ─── 2. createTemplate (POST /api/agent-templates) ──────────────
ct_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"slug\":\"${SLUG}\",\"name\":\"Custom Template\",\"description\":\"template e2e\",\"icon\":\"🚀\",\"category\":\"productivity\"}" \
    "${BASE}/api/agent-templates")
T_SLUG=$(jget "${ct_body}" slug)
T_NAME=$(jget "${ct_body}" name)
if [[ "${T_SLUG}" == "${SLUG}" && "${T_NAME}" == "Custom Template" ]]; then
    pass "02 createTemplate (slug=${T_SLUG})"
else
    fail "02 createTemplate: ${ct_body}"
fi

# ─── 3. getTemplate (GET /:slug) ──────────────────────────────
gt_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/agent-templates/${SLUG}")
GT_NAME=$(jget "${gt_body}" name)
if [[ "${GT_NAME}" == "Custom Template" ]]; then pass "03 getTemplate"; else fail "03 getTemplate: ${gt_body}"; fi

# ─── 4. updateTemplate (PATCH /:slug) ────────────────────────
ut_body=$(http_body -X PATCH -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{"description":"updated description","category":"engineering"}' "${BASE}/api/agent-templates/${SLUG}")
UT_DESC=$(jget "${ut_body}" description)
if [[ "${UT_DESC}" == "updated description" ]]; then pass "04 updateTemplate"; else fail "04 updateTemplate: ${ut_body}"; fi

# ─── 5. listTemplates after create (count +1) ───────────────
lt2_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/agent-templates")
LT2_COUNT=$(echo "${lt2_body}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d, list) else len(d.get("templates", d.get("data", d.get("items", [])))))' 2>/dev/null || echo 0)
if [[ "${LT2_COUNT}" -gt "${LT_COUNT}" ]]; then pass "05 listTemplates grew"; else fail "05 listTemplates: ${lt2_body}"; fi

# ─── 6. deleteTemplate (DELETE /:slug) ──────────────────────
dt_status=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" "${BASE}/api/agent-templates/${SLUG}")
if [[ "${dt_status}" == "200" || "${dt_status}" == "204" ]]; then pass "06 deleteTemplate (${dt_status})"; else fail "06 deleteTemplate (${dt_status})"; fi

# ─── 7. getTemplate after delete → 404 ─────────────────────
nf_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/agent-templates/${SLUG}")
if [[ "${nf_status}" == "404" ]]; then pass "07 getTemplate 404 (deleted)"; else fail "07 getTemplate 404 (${nf_status})"; fi

# ─── 8. createTemplate invalid slug (empty) → 400 ───────────
is_status=$(http_status -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{"slug":"","name":"bad"}' "${BASE}/api/agent-templates")
if [[ "${is_status}" == "400" ]]; then pass "08 createTemplate empty slug (400)"; else fail "08 createTemplate empty (${is_status})"; fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All agent template endpoints responded correctly${RESET}"
    exit 0
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
