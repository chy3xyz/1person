#!/usr/bin/env bash
# End-to-end HTTP regression test for the label module + issue/label
# interactions.
#
# Boots a fresh zserver (no-DB mode), authenticates a dev user,
# creates a scratch workspace, and exercises the public endpoints
# in `src/modules/label/routes.zig` plus the per-issue label
# attach/detach/list endpoints.
#
# Usage:
#   MULTICA_DEV_VERIFICATION_CODE=000000 \
#   JWT_SECRET=test-secret \
#   ./scripts/label_e2e.sh
#
# Override the port with PORT=<n>.

set -euo pipefail

PORT="${PORT:-18096}"
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
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-label-e2e.log 2>&1 &
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
    tail -50 /tmp/zserver-label-e2e.log
    exit 1
fi

# ─── Authenticate dev user ───────────────────────────────────────────
EMAIL="label-e2e-$(date +%s)@example.com"
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
    -d "{\"name\":\"Label E2E\",\"slug\":\"label-e2e-$(date +%s)\"}" \
    "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
if [[ -z "${WS_ID}" ]]; then
    warn "workspace creation failed: ${ws_body}"
    exit 1
fi
HWS="X-Workspace-Id: ${WS_ID}"

# ─── 1. createLabel (POST /api/labels) ──────────────────────────────
cl_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"name\":\"bug\",\"color\":\"#ef4444\"}" "${BASE}/api/labels")
LABEL_ID=$(jget "${cl_body}" id)
LABEL_NAME=$(jget "${cl_body}" name)
if [[ -n "${LABEL_ID}" && "${LABEL_NAME}" == "bug" ]]; then pass "01 createLabel (id=${LABEL_ID})"; else fail "01 createLabel: ${cl_body}"; fi

# ─── 2. listLabels (GET /api/labels) ─────────────────────────────────
ll_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/labels")
LL_COUNT=$(echo "${ll_body}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("labels",[])))' 2>/dev/null || echo 0)
if [[ "${LL_COUNT}" -ge 1 ]]; then pass "02 listLabels (n=${LL_COUNT})"; else fail "02 listLabels: ${ll_body}"; fi

# ─── 3. getLabel (GET /api/labels/:id) ───────────────────────────────
gl_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/labels/${LABEL_ID}")
GL_NAME=$(jget "${gl_body}" name)
if [[ "${GL_NAME}" == "bug" ]]; then pass "03 getLabel"; else fail "03 getLabel: ${gl_body}"; fi

# ─── 4. updateLabel (PATCH /api/labels/:id) ──────────────────────────
ul_body=$(http_body -X PATCH -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"name\":\"bug-fixed\",\"color\":\"#22c55e\"}" "${BASE}/api/labels/${LABEL_ID}")
UL_NAME=$(jget "${ul_body}" name)
UL_COLOR=$(jget "${ul_body}" color)
if [[ "${UL_NAME}" == "bug-fixed" && "${UL_COLOR}" == "#22c55e" ]]; then pass "04 updateLabel"; else fail "04 updateLabel: ${ul_body}"; fi

# ─── 5. invalid color rejected (400) ─────────────────────────────────
ic_status=$(http_status -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"name\":\"bad\",\"color\":\"not-a-color\"}" "${BASE}/api/labels")
if [[ "${ic_status}" == "400" ]]; then pass "05 invalid color (400)"; else fail "05 invalid color (${ic_status})"; fi

# ─── 6. duplicate name rejected (409) ───────────────────────────────
dup_status=$(http_status -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"name\":\"bug-fixed\",\"color\":\"#000000\"}" "${BASE}/api/labels")
if [[ "${dup_status}" == "409" ]]; then pass "06 duplicate name (409)"; else fail "06 duplicate name (${dup_status})"; fi

# ─── Create a scratch issue to exercise the issue/label join ───────
issue_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"title\":\"label e2e issue\",\"state\":\"todo\"}" "${BASE}/api/issues")
ISSUE_ID=$(jget_path "${issue_body}" data.id)
if [[ -z "${ISSUE_ID}" ]]; then
    warn "issue creation failed: ${issue_body}"
    exit 1
fi

# ─── 7. attachLabel (POST /api/issues/:id/labels) ───────────────────
al_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"label_id\":\"${LABEL_ID}\"}" "${BASE}/api/issues/${ISSUE_ID}/labels")
AL_OK=$(jget_path "${al_body}" data.attached)
if [[ "${AL_OK}" == "True" || "${AL_OK}" == "true" ]]; then pass "07 attachLabel"; else fail "07 attachLabel: ${al_body}"; fi

# ─── 8. attachLabel rejects unknown label id (404) ──────────────────
al_bad_status=$(http_status -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{"label_id":"nonexistent"}' "${BASE}/api/issues/${ISSUE_ID}/labels")
if [[ "${al_bad_status}" == "404" ]]; then pass "08 attachLabel unknown (404)"; else fail "08 attachLabel unknown (${al_bad_status})"; fi

# ─── 9. listIssueLabels (GET /api/issues/:id/labels) ─────────────────
ill_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/${ISSUE_ID}/labels")
ILL_NAMES=$(echo "${ill_body}" | python3 -c 'import sys,json; d=json.load(sys.stdin).get("data",{}).get("labels",[]); print(",".join(l["name"] for l in d))' 2>/dev/null || echo "")
if [[ "${ILL_NAMES}" == "bug-fixed" ]]; then pass "09 listIssueLabels"; else fail "09 listIssueLabels: ${ill_body}"; fi

# ─── 10. deleteLabel cascades: removes from issue list too ─────────
dl_status=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" \
    "${BASE}/api/labels/${LABEL_ID}")
if [[ "${dl_status}" == "200" || "${dl_status}" == "204" ]]; then pass "10 deleteLabel (${dl_status})"; else fail "10 deleteLabel (${dl_status})"; fi

# Verify cascade: the issue's label list is now empty.
ill2_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/${ISSUE_ID}/labels")
ILL2_COUNT=$(echo "${ill2_body}" | python3 -c 'import sys,json; d=json.load(sys.stdin).get("data",{}).get("labels",[]); print(len(d))' 2>/dev/null || echo 0)
if [[ "${ILL2_COUNT}" == "0" ]]; then pass "10b cascade removed label from issue"; else fail "10b cascade: ${ill2_body}"; fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All label endpoints responded correctly${RESET}"
    exit 0
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
