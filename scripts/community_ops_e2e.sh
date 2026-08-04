#!/usr/bin/env bash
# End-to-end HTTP regression test for the community_ops module.
#
# Usage:
#   MULTICA_DEV_VERIFICATION_CODE=000000 \
#   JWT_SECRET=test-secret \
#   ./scripts/community_ops_e2e.sh

set -euo pipefail

PORT="${PORT:-18091}"
BASE="http://127.0.0.1:${PORT}"
JWT_SECRET="${JWT_SECRET:-test-secret}"
export JWT_SECRET

RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; RESET="\033[0m"
failures=0
pass() { echo -e "${GREEN}PASS${RESET}: $1"; }
fail() { echo -e "${RED}FAIL${RESET}: $1"; ((failures++)) || true; }

http_status() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
http_body() { curl -s "$@"; }
jget() { echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$2',''))" 2>/dev/null || true; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "==> building zserver"
( cd "${SCRIPT_DIR}/../zserver" && zig build ) || { echo "build failed"; exit 1; }

echo "==> starting zserver on port ${PORT}"
"${SCRIPT_DIR}/../zserver/zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-community-ops-e2e.log 2>&1 &
SERVER_PID=$!
cleanup() { kill "${SERVER_PID}" >/dev/null 2>&1 || true; wait "${SERVER_PID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

for i in $(seq 1 30); do
    if [[ $(http_status "${BASE}/health") == "200" ]]; then break; fi; sleep 0.5
done

EMAIL="com-ops-e2e-$(date +%s)@example.com"
http_status -X POST -H "Content-Type: application/json" -d "{\"email\":\"${EMAIL}\"}" "${BASE}/auth/send-code" >/dev/null
code="${MULTICA_DEV_VERIFICATION_CODE:-000000}"
auth_body=$(http_body -X POST -H "Content-Type: application/json" -d "{\"email\":\"${EMAIL}\",\"code\":\"${code}\"}" "${BASE}/auth/verify-code")
TOKEN=$(jget "${auth_body}" token)
AUTH="Authorization: Bearer ${TOKEN}"

ws_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -d "{\"name\":\"Community Ops E2E\",\"slug\":\"com-ops-e2e-$(date +%s)\"}" "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
HWS="X-Workspace-Id: ${WS_ID}"

# ── 1. createGroup ───────────────────────────────────────────────
c1=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
  -d '{"name":"Beta Testers"}' \
  "${BASE}/api/community/groups")
GROUP_ID=$(jget "${c1}" id)
[[ -n "${GROUP_ID}" ]] && pass "01 createGroup (id=${GROUP_ID})" || fail "01 createGroup: ${c1}"

# ── 2. addMember ─────────────────────────────────────────────────
c2=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
  -d '{}' \
  "${BASE}/api/community/groups/${GROUP_ID}/add-member")
P2_COUNT=$(jget "${c2}" member_count)
[[ "${P2_COUNT}" == "1" ]] && pass "02 addMember (count=${P2_COUNT})" || fail "02 addMember: ${c2}"

# ── 3. verify member count after add ─────────────────────────────
c3=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/community/groups/${GROUP_ID}")
P3_COUNT=$(jget "${c3}" member_count)
[[ "${P3_COUNT}" == "1" ]] && pass "03 verify member count (${P3_COUNT})" || fail "03 verify member count: ${c3}"

# ── 4. createAnnouncement ────────────────────────────────────────
c4=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
  -d '{"content":"Welcome to the Beta Testers group!"}' \
  "${BASE}/api/community/groups/${GROUP_ID}/announcements")
ANN_ID=$(jget "${c4}" id)
[[ -n "${ANN_ID}" ]] && pass "04 createAnnouncement (id=${ANN_ID})" || fail "04 createAnnouncement: ${c4}"

# ── 5. publishAnnouncement ───────────────────────────────────────
c5=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
  -d '{}' \
  "${BASE}/api/community/announcements/${ANN_ID}/publish")
P5_PUB=$(jget "${c5}" published_at)
[[ -n "${P5_PUB}" ]] && pass "05 publishAnnouncement (published_at=${P5_PUB})" || fail "05 publishAnnouncement: ${c5}"

# ── 6. getDailyDigest ────────────────────────────────────────────
c6=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/community/groups/${GROUP_ID}/digest")
P6_MEMBERS=$(jget "${c6}" member_count)
P6_ACTIVITY=$(echo "${c6}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('recent_activity',[])))" 2>/dev/null || echo 0)
[[ "${P6_MEMBERS}" == "1" && "${P6_ACTIVITY}" -ge 1 ]] && pass "06 getDailyDigest (members=${P6_MEMBERS}, activity=${P6_ACTIVITY})" || fail "06 getDailyDigest: ${c6}"

# ── 7. removeMember then verify ──────────────────────────────────
c7=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
  -d '{}' \
  "${BASE}/api/community/groups/${GROUP_ID}/remove-member")
P7_COUNT=$(jget "${c7}" member_count)
[[ "${P7_COUNT}" == "0" ]] && pass "07 removeMember (count=${P7_COUNT})" || fail "07 removeMember: ${c7}"

echo
if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All community_ops endpoints responded correctly${RESET}"; exit 0
else
    echo -e "${RED}${failures} check(s) failed${RESET}"; exit 1
fi
