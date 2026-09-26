#!/usr/bin/env bash
# End-to-end HTTP regression test for the referral module.
# Target: 8 PASS
set -euo pipefail
PORT="${PORT:-18087}"
BASE="http://127.0.0.1:${PORT}"
export JWT_SECRET="${JWT_SECRET:-test-secret}"
export ONEPERSON_DEV_VERIFICATION_CODE="${ONEPERSON_DEV_VERIFICATION_CODE:-000000}"
RED="\033[0;31m"; GREEN="\033[0;32m"; RESET="\033[0m"
failures=0
pass() { echo -e "${GREEN}PASS${RESET}: $1"; }
fail() { echo -e "${RED}FAIL${RESET}: $1"; ((failures++)) || true; }
http_status() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
http_body() { curl -s "$@"; }
jget() { echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$2',''))" 2>/dev/null || true; }
jget_path() { echo "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); [None for k in '$2'.split('.') if not (d:=d.get(k,{}))]; print(d if not isinstance(d,(dict,list)) else json.dumps(d))" 2>/dev/null || true; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-referral-e2e.log 2>&1 &
SERVER_PID=$!
cleanup() { kill "${SERVER_PID}" >/dev/null 2>&1 || true; wait "${SERVER_PID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
for i in $(seq 1 30); do if [[ $(http_status "${BASE}/health") == "200" ]]; then break; fi; sleep 0.5; done

# -------------------------------------------------------------------
# Auth as user-A (the referrer)
# -------------------------------------------------------------------
EMAIL_A="ref-e2e-a-$(date +%s)@example.com"
http_status -X POST -d "{\"email\":\"${EMAIL_A}\"}" -H "Content-Type: application/json" "${BASE}/auth/send-code" >/dev/null
auth_body_a=$(http_body -X POST -d "{\"email\":\"${EMAIL_A}\",\"code\":\"${ONEPERSON_DEV_VERIFICATION_CODE:-000000}\"}" -H "Content-Type: application/json" "${BASE}/auth/verify-code")
TOKEN_A=$(jget "${auth_body_a}" token)
AUTH_A="Authorization: Bearer ${TOKEN_A}"
USER_A_ID=$(jget_path "${auth_body_a}" "user.id")

# Auth as user-B (the referee)
EMAIL_B="ref-e2e-b-$(date +%s)@example.com"
http_status -X POST -d "{\"email\":\"${EMAIL_B}\"}" -H "Content-Type: application/json" "${BASE}/auth/send-code" >/dev/null
auth_body_b=$(http_body -X POST -d "{\"email\":\"${EMAIL_B}\",\"code\":\"${ONEPERSON_DEV_VERIFICATION_CODE:-000000}\"}" -H "Content-Type: application/json" "${BASE}/auth/verify-code")
TOKEN_B=$(jget "${auth_body_b}" token)
AUTH_B="Authorization: Bearer ${TOKEN_B}"
USER_B_ID=$(jget_path "${auth_body_b}" "user.id")

# Create workspace and get shared workspace context
ws_body=$(http_body -X POST -d "{\"name\":\"Referral E2E\",\"slug\":\"ref-e2e-$(date +%s)\"}" -H "Content-Type: application/json" -H "${AUTH_A}" "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
HWS="X-Workspace-Id: ${WS_ID}"

# -------------------------------------------------------------------
# 01 – Create a referral code for user-A
# -------------------------------------------------------------------
REF_CODE="FRIEND-$(date +%s)"
c1=$(http_body -X POST -d "{\"code\":\"${REF_CODE}\"}" -H "Content-Type: application/json" -H "${AUTH_A}" -H "${HWS}" "${BASE}/api/referrals/codes")
C1_CODE=$(jget "${c1}" code)
[[ "${C1_CODE}" == "${REF_CODE}" ]] && pass "01 createCode (${C1_CODE})" || fail "01 createCode: ${c1}"

# -------------------------------------------------------------------
# 02 – user-B registers via the referral code (trackReferral)
# -------------------------------------------------------------------
c2=$(http_body -X POST -d "{\"code\":\"${REF_CODE}\",\"referee_user_id\":\"${USER_B_ID}\"}" -H "Content-Type: application/json" -H "${AUTH_A}" -H "${HWS}" "${BASE}/api/referrals/track")
C2_STATUS=$(jget "${c2}" status)
[[ "${C2_STATUS}" == "registered" ]] && pass "02 trackReferral (status=${C2_STATUS})" || fail "02 trackReferral: ${c2}"

# -------------------------------------------------------------------
# 03 – Verify record status is "registered"
# -------------------------------------------------------------------
c3=$(http_body -H "${AUTH_A}" -H "${HWS}" "${BASE}/api/referrals/records")
C3_TOTAL=$(echo "${c3}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("total",0))' 2>/dev/null || echo 0)
[[ "${C3_TOTAL}" -ge 1 ]] && pass "03 listRecords (total=${C3_TOTAL})" || fail "03 listRecords: ${c3}"

# -------------------------------------------------------------------
# 04 – Activate user-B (activateReferral → status=paid)
# -------------------------------------------------------------------
c4=$(http_body -X POST -d "{\"referee_user_id\":\"${USER_B_ID}\"}" -H "Content-Type: application/json" -H "${AUTH_A}" -H "${HWS}" "${BASE}/api/referrals/activate")
C4_STATUS=$(jget "${c4}" status)
[[ "${C4_STATUS}" == "paid" ]] && pass "04 activateReferral (status=${C4_STATUS})" || fail "04 activateReferral: ${c4}"

# -------------------------------------------------------------------
# 05 – Verify status is now "paid"
# -------------------------------------------------------------------
c5=$(http_body -H "${AUTH_A}" -H "${HWS}" "${BASE}/api/referrals/records")
C5_HAS_PAID=$(echo "${c5}" | python3 -c 'import sys,json; records=json.load(sys.stdin).get("records",[]); print(any(r.get("status")=="paid" for r in records))' 2>/dev/null || echo False)
[[ "${C5_HAS_PAID}" == "True" ]] && pass "05 status=paid confirmed" || fail "05 status=paid: ${c5}"

# -------------------------------------------------------------------
# 06 – Get user-A's referral tree (list all referrals by user-A)
# -------------------------------------------------------------------
c6=$(http_body -H "${AUTH_A}" -H "${HWS}" "${BASE}/api/referrals/tree/${USER_A_ID}")
C6_TOTAL=$(echo "${c6}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("total",0))' 2>/dev/null || echo 0)
[[ "${C6_TOTAL}" -ge 1 ]] && pass "06 getReferralTree (total=${C6_TOTAL})" || fail "06 getReferralTree: ${c6}"

# -------------------------------------------------------------------
# 07 – Delete the referral code
# -------------------------------------------------------------------
c7=$(http_status -X DELETE -H "${AUTH_A}" -H "${HWS}" "${BASE}/api/referrals/codes/${REF_CODE}")
[[ "${c7}" == "200" || "${c7}" == "204" ]] && pass "07 deleteCode (${c7})" || fail "07 deleteCode: ${c7}"

# -------------------------------------------------------------------
# 08 – Verify code is gone (404)
# -------------------------------------------------------------------
c8=$(http_status -H "${AUTH_A}" -H "${HWS}" "${BASE}/api/referrals/codes/${REF_CODE}")
[[ "${c8}" == "404" ]] && pass "08 getCode 404" || fail "08 getCode 404: ${c8}"

echo
if [[ ${failures} -eq 0 ]]; then echo -e "${GREEN}All 8 referral tests passed${RESET}"; exit 0; else echo -e "${RED}${failures} failed${RESET}"; exit 1; fi
