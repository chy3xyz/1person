#!/usr/bin/env bash
# End-to-end HTTP regression test for the autopilot module +
# deliveries + rotate-webhook-token endpoints.
#
# Boots a fresh zserver (no-DB mode), authenticates a dev user,
# creates a scratch workspace, then exercises the public
# autopilot endpoints including the four new ones:
# `GET /:id/deliveries`, `GET /:id/deliveries/:did`,
# `POST /:id/deliveries/:did/replay`, and
# `POST /:id/triggers/:tid/rotate-webhook-token`.
#
# Usage:
#   MULTICA_DEV_VERIFICATION_CODE=000000 \
#   JWT_SECRET=test-secret \
#   ./scripts/autopilot_e2e.sh
#
# Override the port with PORT=<n>.

set -euo pipefail

PORT="${PORT:-18093}"
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
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-autopilot-e2e.log 2>&1 &
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
    tail -50 /tmp/zserver-autopilot-e2e.log
    exit 1
fi

# ─── Authenticate dev user ───────────────────────────────────────────
EMAIL="autopilot-e2e-$(date +%s)@example.com"
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
    -d "{\"name\":\"Autopilot E2E\",\"slug\":\"autopilot-e2e-$(date +%s)\"}" \
    "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
HWS="X-Workspace-Id: ${WS_ID}"

# ─── Seed DB data when running against PostgreSQL ──────────────────
# The zserver auto-connects to a local postgres instance via its
# hardcoded default URL, so we seed unconditionally and fall back
# to a fake assignee_id only when psql is unavailable.
AGENT_RUNTIME_ID="e2e00000-0000-0000-0000-000000000001"
AGENT_ID="e2e00000-0000-0000-0000-000000000002"
PG_CONN="${DATABASE_URL:-postgres://n0x@localhost:5432/multica?sslmode=disable}"
if psql "${PG_CONN}" -c "SELECT 1" >/dev/null 2>&1; then
    psql "${PG_CONN}" -c "INSERT INTO agent_runtime (id, workspace_id, name, runtime_mode, provider, daemon_id, status, visibility) VALUES ('${AGENT_RUNTIME_ID}'::uuid, '${WS_ID}'::uuid, 'e2e-runtime', 'local', 'e2e', 'e2e-daemon', 'online', 'private') ON CONFLICT (id) DO UPDATE SET workspace_id = EXCLUDED.workspace_id" >/dev/null 2>&1 || true
    psql "${PG_CONN}" -c "INSERT INTO agent (id, workspace_id, name, runtime_id, runtime_mode, visibility, status, description, instructions) VALUES ('${AGENT_ID}'::uuid, '${WS_ID}'::uuid, 'e2e-agent', '${AGENT_RUNTIME_ID}'::uuid, 'local', 'workspace', 'idle', '', '') ON CONFLICT (id) DO UPDATE SET workspace_id = EXCLUDED.workspace_id" >/dev/null 2>&1 || true
    ASSIGNEE_ID="${AGENT_ID}"
else
    ASSIGNEE_ID="00000000-0000-0000-0000-000000000001"
fi

# ─── 1. createAutopilot (POST /api/autopilots) ──────────────────
ap_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"title\":\"Test Autopilot\",\"description\":\"autopilot e2e\",\"assignee_id\":\"${ASSIGNEE_ID}\",\"execution_mode\":\"create_issue\",\"issue_title_template\":\"Auto: {{title}}\"}" \
    "${BASE}/api/autopilots")
AP_ID=$(jget "${ap_body}" id)
if [[ -n "${AP_ID}" ]]; then pass "01 createAutopilot"; else fail "01 createAutopilot: ${ap_body}"; fi

# ─── 2. createTrigger (POST /:id/triggers) — webhook ────────────
ct_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"kind\":\"webhook\",\"enabled\":true,\"label\":\"incoming\"}" \
    "${BASE}/api/autopilots/${AP_ID}/triggers")
T_ID=$(jget "${ct_body}" id)
if [[ -n "${T_ID}" ]]; then pass "02 createTrigger"; else fail "02 createTrigger: ${ct_body}"; fi

# ─── 3. triggerAutopilot (POST /:id/trigger) ─────────────────────
ta_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{}' "${BASE}/api/autopilots/${AP_ID}/trigger")
RUN_ID=$(jget_path "${ta_body}" run_id)
TA_STATUS=$(http_status -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{}' "${BASE}/api/autopilots/${AP_ID}/trigger")
if [[ "${TA_STATUS}" == "202" && -n "${RUN_ID}" ]]; then pass "03 triggerAutopilot (202)"; else fail "03 triggerAutopilot (${TA_STATUS})"; fi

# ─── 4. listDeliveries (GET /:id/deliveries) ────────────────────
ld_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/autopilots/${AP_ID}/deliveries")
LD_COUNT=$(echo "${ld_body}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("deliveries",[])))' 2>/dev/null || echo 0)
if [[ "${LD_COUNT}" -ge 2 ]]; then pass "04 listDeliveries (n=${LD_COUNT})"; else fail "04 listDeliveries: ${ld_body}"; fi

# ─── 5. getDelivery (GET /:id/deliveries/:did) ───────────────────
gd_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/autopilots/${AP_ID}/deliveries/${RUN_ID}")
GD_ID=$(jget "${gd_body}" id)
GD_STATUS=$(jget "${gd_body}" response_status)
if [[ "${GD_ID}" == "${RUN_ID}" && "${GD_STATUS}" == "202" ]]; then pass "05 getDelivery"; else fail "05 getDelivery: ${gd_body}"; fi

# ─── 6. replayDelivery (POST /:id/deliveries/:did/replay) ───────
rd_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{}' "${BASE}/api/autopilots/${AP_ID}/deliveries/${RUN_ID}/replay")
RD_STATUS=$(jget "${rd_body}" status)
if [[ "${RD_STATUS}" == "queued" ]]; then pass "06 replayDelivery"; else fail "06 replayDelivery: ${rd_body}"; fi

# After replay, the deliveries list should have one more entry.
ld2_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/autopilots/${AP_ID}/deliveries")
LD2_COUNT=$(echo "${ld2_body}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("deliveries",[])))' 2>/dev/null || echo 0)
if [[ "${LD2_COUNT}" -gt "${LD_COUNT}" ]]; then pass "06b deliveries list grows after replay"; else fail "06b deliveries: ${ld2_body}"; fi

# ─── 7. rotateWebhookToken (POST /:id/triggers/:tid/rotate-webhook-token) ─
rt_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{}' "${BASE}/api/autopilots/${AP_ID}/triggers/${T_ID}/rotate-webhook-token")
NEW_TOKEN=$(jget "${rt_body}" webhook_token)
if [[ -n "${NEW_TOKEN}" ]]; then pass "07 rotateWebhookToken"; else fail "07 rotateWebhookToken: ${rt_body}"; fi

# ─── 7b. deliveries unknown id returns 404 ──────────────────────
nf_status=$(http_status -H "${AUTH}" -H "${HWS}" \
    "${BASE}/api/autopilots/${AP_ID}/deliveries/does-not-exist")
if [[ "${nf_status}" == "404" ]]; then pass "07b getDelivery 404 (unknown id)"; else fail "07b getDelivery 404 (${nf_status})"; fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All autopilot endpoints responded correctly${RESET}"
    exit 0
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
