#!/usr/bin/env bash
# End-to-end HTTP regression test for the training module.
set -euo pipefail
PORT="${PORT:-18091}"
BASE="http://127.0.0.1:${PORT}"
export JWT_SECRET="${JWT_SECRET:-test-secret}"
export ONEPERSON_DEV_VERIFICATION_CODE="${ONEPERSON_DEV_VERIFICATION_CODE:-000000}"
RED="\033[0;31m"; GREEN="\033[0;32m"; RESET="\033[0m"
failures=0
pass() { echo -e "${GREEN}PASS${RESET}: $1"; }
fail() { echo -e "${RED}FAIL${RESET}: $1"; ((failures++)) || true; }
http_status() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
http_body() { curl -s "$@"; }
jget() { echo "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',d).get('$2',''))" 2>/dev/null || true; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-training-e2e.log 2>&1 &
SERVER_PID=$!
cleanup() { kill "${SERVER_PID}" >/dev/null 2>&1 || true; wait "${SERVER_PID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
for i in $(seq 1 30); do if [[ $(http_status "${BASE}/health") == "200" ]]; then break; fi; sleep 0.5; done

EMAIL="tr-e2e-$(date +%s)@example.com"
http_status -X POST -d "{\"email\":\"${EMAIL}\"}" -H "Content-Type: application/json" "${BASE}/auth/send-code" >/dev/null
auth_body=$(http_body -X POST -d "{\"email\":\"${EMAIL}\",\"code\":\"${ONEPERSON_DEV_VERIFICATION_CODE:-000000}\"}" -H "Content-Type: application/json" "${BASE}/auth/verify-code")
TOKEN=$(python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null <<< "${auth_body}")
AUTH="Authorization: Bearer ${TOKEN}"

ws_body=$(http_body -X POST -d "{\"name\":\"Training E2E\",\"slug\":\"tr-e2e-$(date +%s)\"}" -H "Content-Type: application/json" -H "${AUTH}" "${BASE}/api/workspaces")
WS_ID=$(python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null <<< "${ws_body}")
HWS="X-Workspace-Id: ${WS_ID}"
USER_A=$(python3 -c "import sys,json; print(json.load(sys.stdin).get('user',{}).get('id',''))" 2>/dev/null <<< "${auth_body}" || echo "${TOKEN:0:8}")

# Fallback: use token prefix as user_id if the auth body doesn't contain user info
if [[ -z "${USER_A}" ]]; then
    USER_A="user-a-$(date +%s)"
fi

# 1. Create course
b1=$(http_body -X POST -d '{"name":"Safety Training"}' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/training/courses")
COURSE_ID=$(jget "${b1}" id)
[[ -n "${COURSE_ID}" ]] && pass "01 createCourse" || fail "01 createCourse: ${b1}"

# 2. Create lesson 1
b2=$(http_body -X POST -d '{"title":"Lesson 1: Introduction","content":"Content of lesson 1","quiz":"{\"question\":\"What is safety?\",\"options\":[\"A\",\"B\",\"C\"],\"correct_index\":0}"}' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/training/courses/${COURSE_ID}/lessons")
L1_ID=$(jget "${b2}" id)
[[ -n "${L1_ID}" ]] && pass "02 createLesson 1" || fail "02 createLesson 1: ${b2}"

# 3. Create lesson 2
b3=$(http_body -X POST -d '{"title":"Lesson 2: Advanced Safety","content":"Content of lesson 2","quiz":"{\"question\":\"What is advanced safety?\",\"options\":[\"X\",\"Y\",\"Z\"],\"correct_index\":1}"}' -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/training/courses/${COURSE_ID}/lessons")
L2_ID=$(jget "${b3}" id)
[[ -n "${L2_ID}" ]] && pass "03 createLesson 2" || fail "03 createLesson 2: ${b3}"

# 4. Enroll user-A
b4=$(http_body -X POST -d "{\"user_id\":\"${USER_A}\",\"course_id\":\"${COURSE_ID}\"}" -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/training/enroll")
ENROLL_STATUS=$(jget "${b4}" status)
[[ "${ENROLL_STATUS}" == "enrolled" ]] && pass "04 enrollUser (status=enrolled)" || fail "04 enrollUser: ${b4}"

# 5. Complete lesson 1
b5=$(http_body -X POST -d "{\"user_id\":\"${USER_A}\",\"lesson_id\":\"${L1_ID}\"}" -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/training/complete-lesson")
S5_STATUS=$(jget "${b5}" status)
[[ "${S5_STATUS}" == "in_progress" ]] && pass "05 completeLesson 1 (status=in_progress)" || fail "05 completeLesson 1: ${b5}"

# 6. Complete lesson 2
b6=$(http_body -X POST -d "{\"user_id\":\"${USER_A}\",\"lesson_id\":\"${L2_ID}\"}" -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/training/complete-lesson")
COMPLETED_COUNT=$(echo "${b6}" | python3 -c "import sys,json; d=json.load(sys.stdin).get('data',{}); print(len(d.get('completed_lessons',[])))" 2>/dev/null || echo 0)
[[ "${COMPLETED_COUNT}" == "2" ]] && pass "06 completeLesson 2 (completed_lessons=2)" || fail "06 completeLesson 2: ${b6}"

# 7. Complete course (award certificate)
b7=$(http_body -X POST -d "{\"user_id\":\"${USER_A}\",\"course_id\":\"${COURSE_ID}\"}" -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" "${BASE}/api/training/complete-course")
CERT_ID=$(echo "${b7}" | python3 -c "import sys,json; d=json.load(sys.stdin).get('data',{}); print(d.get('certificate_id',''))" 2>/dev/null || true)
E7_STATUS=$(echo "${b7}" | python3 -c "import sys,json; d=json.load(sys.stdin).get('data',{}).get('enrollment',{}); print(d.get('status',''))" 2>/dev/null || true)
[[ -n "${CERT_ID}" && "${E7_STATUS}" == "completed" ]] && pass "07 completeCourse (certificate=${CERT_ID}, status=completed)" || fail "07 completeCourse: ${b7}"

# 8. List enrollments for user
b8=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/training/enrollments?user_id=${USER_A}")
E8_COUNT=$(echo "${b8}" | python3 -c "import sys,json; d=json.load(sys.stdin).get('data',{}); print(len(d.get('enrollments',[])))" 2>/dev/null || echo 0)
E8_STATUS=$(echo "${b8}" | python3 -c "import sys,json; d=json.load(sys.stdin).get('data',{}).get('enrollments',[]); print(d[0].get('status','') if d else '')" 2>/dev/null || true)
[[ "${E8_COUNT}" -ge 1 && "${E8_STATUS}" == "completed" ]] && pass "08 listEnrollments (count=${E8_COUNT}, status=completed)" || fail "08 listEnrollments: ${b8}"

echo
if [[ ${failures} -eq 0 ]]; then echo -e "${GREEN}All training endpoints passed${RESET}"; exit 0; else echo -e "${RED}${failures} failed${RESET}"; exit 1; fi
