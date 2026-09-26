#!/usr/bin/env bash
set -euo pipefail
PORT="${PORT:-18086}"
BASE="http://127.0.0.1:${PORT}"
export JWT_SECRET="${JWT_SECRET:-test-secret}"
RED="\033[0;31m"; GREEN="\033[0;32m"; RESET="\033[0m"
failures=0
pass() { echo -e "${GREEN}PASS${RESET}: $1"; }
fail() { echo -e "${RED}FAIL${RESET}: $1"; ((failures++)) || true; }
http_status() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
http_body() { curl -s "$@"; }
jget() { echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$2',''))" 2>/dev/null || true; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-community-e2e.log 2>&1 &
SERVER_PID=$!
cleanup() { kill "${SERVER_PID}" >/dev/null 2>&1 || true; wait "${SERVER_PID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
for i in $(seq 1 30); do if [[ $(http_status "${BASE}/health") == "200" ]]; then break; fi; sleep 0.5; done

EMAIL="community-$(date +%s)@e.com"
http_status -X POST -d "{\"email\":\"${EMAIL}\"}" -H "Content-Type: application/json" "${BASE}/auth/send-code" >/dev/null
TOKEN=$(http_body -X POST -d "{\"email\":\"${EMAIL}\",\"code\":\"${ONEPERSON_DEV_VERIFICATION_CODE:-000000}\"}" -H "Content-Type: application/json" "${BASE}/auth/verify-code" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
AUTH="Authorization: Bearer ${TOKEN}"
WS=$(http_body -X POST -d "{\"name\":\"Community\",\"slug\":\"community-$(date +%s)\"}" -H "Content-Type: application/json" -H "${AUTH}" "${BASE}/api/workspaces")
WS_ID=$(echo "$WS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
HWS="X-Workspace-Id: ${WS_ID}"

# 1. createGroup
c1=$(http_body -X POST -d '{"name":"Test Group"}' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/community/groups")
GID=$(jget "${c1}" id)
[[ -n "${GID}" ]] && pass "01 createGroup" || fail "01: ${c1}"

# 2. addMember (route: POST /groups/:id/add-member)
c2=$(http_body -X POST -d '{}' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/community/groups/${GID}/add-member")
[[ -n "${c2}" ]] && pass "02 addMember" || fail "02: ${c2}"

# 3. verify member count
c3=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/community/groups/${GID}")
MC=$(jget "${c3}" member_count)
[[ "${MC}" -ge 1 ]] && pass "03 member_count=${MC}" || fail "03: ${c3}"

# 4. createAnnouncement (route: POST /groups/:id/announcements)
c4=$(http_body -X POST -d '{"content":"Hello Community"}' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/community/groups/${GID}/announcements")
AID=$(jget "${c4}" id)
[[ -n "${AID}" ]] && pass "04 createAnnouncement" || fail "04: ${c4}"

# 5. publishAnnouncement (route: POST /groups/:id/announcements/:aid/publish)
c5=$(http_body -X POST -d '{}' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/community/groups/${GID}/announcements/${AID}/publish")
[[ -n "${c5}" ]] && pass "05 publishAnnouncement" || fail "05: ${c5}"

# 6. getDailyDigest (route: GET /groups/:id/digest)
c6=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/community/groups/${GID}/digest")
[[ -n "${c6}" ]] && pass "06 getDailyDigest" || fail "06: ${c6}"

# 7. removeMember (route: POST /groups/:id/remove-member)
c7=$(http_body -X POST -d '{}' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/community/groups/${GID}/remove-member")
[[ -n "${c7}" ]] && pass "07 removeMember" || fail "07: ${c7}"

echo
if [[ ${failures} -eq 0 ]]; then echo -e "${GREEN}All community ops endpoints passed${RESET}"; exit 0; else echo -e "${RED}${failures} failed${RESET}"; exit 1; fi
