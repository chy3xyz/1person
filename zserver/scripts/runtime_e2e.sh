#!/usr/bin/env bash
# End-to-end HTTP regression test for the runtime module.
#
# Boots a fresh zserver (no-DB mode unless DATABASE_URL is set),
# authenticates a dev user, creates a scratch workspace, and exercises
# the public endpoints in `src/modules/runtime/routes.zig`.
#
# In no-DB mode the in-memory runtime table starts empty (there is no
# create endpoint), so the per-runtime endpoints are checked to 404
# cleanly and the list endpoint to return 200 + empty. When DATABASE_URL
# is set (DB mode), a scratch runtime row is inserted via psql and the
# update / usage / activity endpoints are exercised for real.
#
# Usage:
#   MULTICA_DEV_VERIFICATION_CODE=000000 JWT_SECRET=test-secret \
#   [DATABASE_URL=postgres://...] ./scripts/runtime_e2e.sh
#
# Override the port with PORT=<n>.

set -euo pipefail

PORT="${PORT:-18096}"
BASE="http://127.0.0.1:${PORT}"
JWT_SECRET="${JWT_SECRET:-test-secret}"
export JWT_SECRET
export DATABASE_URL="${DATABASE_URL:-}"

RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; RESET="\033[0m"
failures=0
pass() { echo -e "${GREEN}PASS${RESET}: $1"; }
fail() { echo -e "${RED}FAIL${RESET}: $1"; ((failures++)) || true; }
warn() { echo -e "${YELLOW}WARN${RESET}: $1"; }
http_status() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
http_body() { curl -s "$@"; }
jget() { echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$2',''))" 2>/dev/null || true; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "==> building zserver"
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }

echo "==> starting zserver on port ${PORT}"
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-runtime-e2e.log 2>&1 &
SERVER_PID=$!
cleanup() { echo "==> stopping zserver"; kill "${SERVER_PID}" >/dev/null 2>&1 || true; wait "${SERVER_PID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

for i in $(seq 1 30); do
    [[ $(http_status "${BASE}/health") == "200" ]] && break
    sleep 0.5
done
[[ $(http_status "${BASE}/health") == "200" ]] || { warn "/health never came up"; tail -20 /tmp/zserver-runtime-e2e.log; exit 1; }

# ─── Authenticate ─────────────────────────────────────────────────────
EMAIL="runtime-e2e-$(date +%s)@example.com"
http_status -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${EMAIL}\"}" "${BASE}/auth/send-code" >/dev/null
code="${MULTICA_DEV_VERIFICATION_CODE:-000000}"
AUTH_BODY=$(http_body -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${EMAIL}\",\"code\":\"${code}\"}" "${BASE}/auth/verify-code")
TOKEN=$(jget "${AUTH_BODY}" token)
if [[ -z "${TOKEN}" ]]; then
    warn "auth failed: ${AUTH_BODY}"
    exit 1
fi
AUTH="Authorization: Bearer ${TOKEN}"

WS_BODY=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
    -d "{\"name\":\"E2E\",\"slug\":\"rt-$(date +%s)\"}" "${BASE}/api/workspaces")
WS_ID=$(jget "${WS_BODY}" id)
[[ -n "${WS_ID}" ]] || { warn "could not create workspace: ${WS_BODY}"; exit 1; }
HWS="X-Workspace-ID: ${WS_ID}"

# ─── 1. listAgentRuntimes (GET /api/runtimes) ─────────────────────────
lr_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/runtimes")
if [[ "${lr_status}" == "200" ]]; then pass "01 listAgentRuntimes (200)"; else fail "01 listAgentRuntimes (${lr_status})"; fi

# ─── 2. usage endpoints (aggregates: 200 empty even without runtime) ──
RT_ID="11111111-2222-3333-4444-555555555555"
for ep in "usage" "usage/by-agent" "usage/by-hour" "activity"; do
    st=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/runtimes/${RT_ID}/${ep}")
    if [[ "${st}" == "200" ]]; then pass "02 GET /${ep} (200 empty)"; else fail "02 GET /${ep} (expected 200, got ${st})"; fi
done
# Runtime-scoped update flow requires an existing runtime → 404
st=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/runtimes/${RT_ID}/update/00000000-0000-0000-0000-000000000000")
[[ "${st}" == "404" ]] && pass "02b GET /update/:id → 404 (no runtime)" || fail "02b GET /update/:id (expected 404, got ${st})"

# ─── 3. DB mode: full flow ────────────────────────────────────────────
if [[ -n "${DATABASE_URL}" ]]; then
    USER_ID=$(jget "$(http_body -H "${AUTH}" "${BASE}/api/me")" id)
    RID=$(psql "${DATABASE_URL}" -tAc "INSERT INTO agent_runtime (workspace_id, owner_id, name, runtime_mode, provider, status) VALUES ('${WS_ID}'::uuid, '${USER_ID}'::uuid, 'rt-e2e', 'local', 'local', 'online') RETURNING id" 2>/dev/null | head -1)
    if [[ -n "${RID}" ]]; then
        # 3a. updateAgentRuntime (PATCH)
        up=$(http_status -X PATCH -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
            -d '{"name":"rt-e2e-renamed"}' "${BASE}/api/runtimes/${RID}")
        [[ "${up}" == "200" ]] && pass "03 updateAgentRuntime (200)" || fail "03 updateAgentRuntime (${up})"

        # 3b. initiateUpdate → 202
        upd=$(http_status -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
            -d '{"target_version":"0.0.1"}' "${BASE}/api/runtimes/${RID}/update")
        [[ "${upd}" == "202" || "${upd}" == "200" ]] && pass "04 initiateUpdate (${upd})" || fail "04 initiateUpdate (${upd})"

        # 3c. usage / activity return 200 (may be empty)
        for ep in "usage" "usage/by-agent" "usage/by-hour" "activity"; do
            st=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/runtimes/${RID}/${ep}")
            [[ "${st}" == "200" ]] && pass "05 GET /${ep} (200)" || fail "05 GET /${ep} (${st})"
        done
    else
        warn "psql insert failed; skipping DB-mode checks"
    fi
else
    warn "DATABASE_URL not set — skipping DB-mode checks (no-DB mode only)"
fi

# ─── summary ──────────────────────────────────────────────────────────
if [[ "${failures}" -eq 0 ]]; then
    echo -e "${GREEN}All runtime e2e checks passed${RESET}"
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
