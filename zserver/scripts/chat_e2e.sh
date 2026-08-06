#!/usr/bin/env bash
# End-to-end HTTP regression test for the chat module.
#
# Boots a fresh zserver (no-DB mode), authenticates a dev user,
# creates a scratch workspace, and exercises the public endpoints
# in `src/modules/chat/routes.zig`.
#
# Usage:
#   MULTICA_DEV_VERIFICATION_CODE=000000 JWT_SECRET=test-secret \
#   ./scripts/chat_e2e.sh
#
# Override the port with PORT=<n>.

set -euo pipefail

PORT="${PORT:-18096}"
BASE="http://127.0.0.1:${PORT}"
JWT_SECRET="${JWT_SECRET:-test-secret}"
export JWT_SECRET
export DATABASE_URL=""

RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; RESET="\033[0m"
failures=0
pass() { echo -e "${GREEN}PASS${RESET}: $1"; }
fail() { echo -e "${RED}FAIL${RESET}: $1"; ((failures++)) || true; }
warn() { echo -e "${YELLOW}WARN${RESET}: $1"; }
http_status() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
http_body() { curl -s "$@"; }
jget() { echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$2',''))" 2>/dev/null || true; }
jget_path() {
    echo "$1" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for k in '$2'.split('.'):
    if isinstance(d, dict) and k in d:
        d = d[k]
    else:
        print(''); sys.exit(0)
print(d if not isinstance(d, (dict, list)) else json.dumps(d))
" 2>/dev/null || true
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "==> building zserver"
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }

echo "==> starting zserver on port ${PORT}"
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-chat-e2e.log 2>&1 &
SERVER_PID=$!
cleanup() { echo "==> stopping zserver"; kill "${SERVER_PID}" >/dev/null 2>&1 || true; wait "${SERVER_PID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

for i in $(seq 1 30); do
    [[ $(http_status "${BASE}/health") == "200" ]] && break
    sleep 0.5
done
[[ $(http_status "${BASE}/health") == "200" ]] || { warn "/health never came up"; tail -20 /tmp/zserver-chat-e2e.log; exit 1; }

# ─── Authenticate ─────────────────────────────────────────────────────
EMAIL="chat-e2e-$(date +%s)@example.com"
http_status -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${EMAIL}\"}" "${BASE}/auth/send-code" >/dev/null
code="${MULTICA_DEV_VERIFICATION_CODE:-000000}"
AUTH_BODY=$(http_body -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${EMAIL}\",\"code\":\"${code}\"}" "${BASE}/auth/verify-code")
TOKEN=$(jget "${AUTH_BODY}" token)
if [[ -z "${TOKEN}" ]]; then warn "auth failed: ${AUTH_BODY}"; exit 1; fi
AUTH="Authorization: Bearer ${TOKEN}"

WS_BODY=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
    -d "{\"name\":\"E2E\",\"slug\":\"chat-$(date +%s)\"}" "${BASE}/api/workspaces")
WS_ID=$(jget "${WS_BODY}" id)
[[ -n "${WS_ID}" ]] || { warn "could not create workspace: ${WS_BODY}"; exit 1; }
HWS="X-Workspace-ID: ${WS_ID}"

# ─── 1. listChatSessions (GET /api/chat) ──────────────────────────────
st=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/chat/sessions")
[[ "${st}" == "200" ]] && pass "01 listChatSessions (200)" || fail "01 listChatSessions (${st})"

# ─── 2. createChatSession (needs an agent) ────────────────────────────
# no-DB mode has no runtime-create endpoint; a syntactically valid
# runtime UUID suffices (createAgent's no-DB branch does not resolve it).
RT_ID="11111111-2222-3333-4444-555555555555"
AG_BODY=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"name\":\"chat-agent\",\"runtime_id\":\"${RT_ID}\"}" "${BASE}/api/agents")
AG_ID=$(jget "${AG_BODY}" id)
if [[ -z "${AG_ID}" ]]; then AG_ID=$(jget_path "${AG_BODY}" data.id); fi
CH_BODY=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"title\":\"e2e-chat\",\"agent_id\":\"${AG_ID}\"}" "${BASE}/api/chat/sessions")
CH_ID=$(jget_path "${CH_BODY}" data.id)
if [[ -z "${CH_ID}" ]]; then CH_ID=$(jget "${CH_BODY}" id); fi
if [[ -n "${CH_ID}" ]]; then pass "02 createChatSession (id=${CH_ID:0:8})"; else fail "02 createChatSession: ${CH_BODY}"; fi

# ─── 3. getChatSession ────────────────────────────────────────────────
st=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/chat/sessions/${CH_ID}")
[[ "${st}" == "200" ]] && pass "03 getChatSession (200)" || fail "03 getChatSession (${st})"

# ─── 4. messages ──────────────────────────────────────────────────────
st=$(http_status -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{"content":"hello"}' "${BASE}/api/chat/sessions/${CH_ID}/messages")
[[ "${st}" == "200" || "${st}" == "201" ]] && pass "04 sendChatMessage (${st})" || fail "04 sendChatMessage (${st})"
st=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/chat/sessions/${CH_ID}/messages")
[[ "${st}" == "200" ]] && pass "05 listChatMessages (200)" || fail "05 listChatMessages (${st})"
st=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/chat/sessions/${CH_ID}/messages/page?limit=10")
[[ "${st}" == "200" ]] && pass "06 messages/page (200)" || fail "06 messages/page (${st})"

# ─── 5. read / pending-task ───────────────────────────────────────────
st=$(http_status -X POST -H "${AUTH}" -H "${HWS}" "${BASE}/api/chat/sessions/${CH_ID}/read")
[[ "${st}" == "204" || "${st}" == "200" ]] && pass "07 markRead (${st})" || fail "07 markRead (${st})"
st=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/chat/sessions/${CH_ID}/pending-task")
[[ "${st}" == "200" ]] && pass "08 pending-task (200)" || fail "08 pending-task (${st})"

# ─── 6. deleteChatSession ─────────────────────────────────────────────
st=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" "${BASE}/api/chat/sessions/${CH_ID}")
[[ "${st}" == "204" || "${st}" == "200" ]] && pass "09 deleteChatSession (${st})" || fail "09 deleteChatSession (${st})"

# ─── summary ──────────────────────────────────────────────────────────
if [[ "${failures}" -eq 0 ]]; then
    echo -e "${GREEN}All chat e2e checks passed${RESET}"
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
