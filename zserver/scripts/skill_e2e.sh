#!/usr/bin/env bash
# End-to-end HTTP regression test for the skill module.
#
# Boots a fresh zserver (no-DB mode), authenticates a dev user,
# creates a scratch workspace, and exercises the public endpoints
# in `src/modules/skill/routes.zig`.
#
# Usage:
#   MULTICA_DEV_VERIFICATION_CODE=000000 \
#   JWT_SECRET=test-secret \
#   ./scripts/skill_e2e.sh
#
# Override the port with PORT=<n>.

set -euo pipefail

PORT="${PORT:-18097}"
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
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-skill-e2e.log 2>&1 &
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
    tail -50 /tmp/zserver-skill-e2e.log
    exit 1
fi

# ─── Authenticate dev user ───────────────────────────────────────────
EMAIL="skill-e2e-$(date +%s)@example.com"
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

# ─── Create workspace for skill tests ────────────────────────────────
ws_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
    -d "{\"name\":\"Skill E2E\",\"slug\":\"skill-e2e-$(date +%s)\"}" \
    "${BASE}/api/workspaces")
WS_ID=$(jget_path "${ws_body}" id)
if [[ -z "${WS_ID}" ]]; then
    warn "workspace creation failed: ${ws_body}"
    exit 1
fi
HWS="X-Workspace-Id: ${WS_ID}"

# ─── 1. createSkill (POST /api/skills) ───────────────────────────────
cs_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"name\":\"Test Skill\",\"description\":\"skill e2e\",\"content\":\"# Test\",\"files\":[{\"path\":\"rules.md\",\"content\":\"be nice\"}]}" \
    "${BASE}/api/skills")
SKILL_ID=$(jget_path "${cs_body}" skill.id)
if [[ -n "${SKILL_ID}" ]]; then pass "01 createSkill (id=${SKILL_ID})"; else fail "01 createSkill: ${cs_body}"; fi

# ─── 2. listSkills (GET /api/skills) ─────────────────────────────────
ls_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/skills")
LS_COUNT=$(echo "${ls_body}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
if [[ "${LS_COUNT}" -ge 1 ]]; then pass "02 listSkills (n=${LS_COUNT})"; else fail "02 listSkills: ${ls_body}"; fi

# ─── 3. searchSkills (GET /api/skills/search?q=...) ──────────────────
ss_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/skills/search?q=Test")
if [[ "${ss_status}" == "200" ]]; then pass "03 searchSkills (200)"; else fail "03 searchSkills (${ss_status})"; fi

# ─── 4. getSkill (GET /api/skills/:id) ───────────────────────────────
gs_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/skills/${SKILL_ID}")
GS_ID=$(jget_path "${gs_body}" skill.id)
if [[ "${GS_ID}" == "${SKILL_ID}" ]]; then pass "04 getSkill"; else fail "04 getSkill: ${gs_body}"; fi

# ─── 5. updateSkill (PATCH /api/skills/:id) ──────────────────────────
us_body=$(http_body -X PATCH -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"description\":\"updated description\"}" "${BASE}/api/skills/${SKILL_ID}")
US_DESC=$(jget_path "${us_body}" skill.description)
if [[ "${US_DESC}" == "updated description" ]]; then pass "05 updateSkill"; else fail "05 updateSkill: ${us_body}"; fi

# ─── 6. upsertSkillFile (PUT /api/skills/:id/files) ──────────────────
# The no-DB stub returns the single upserted `SkillFileResponse`.
uf_body=$(http_body -X PUT -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"path\":\"extra.md\",\"content\":\"extra content\"}" "${BASE}/api/skills/${SKILL_ID}/files")
UF_ID=$(jget_path "${uf_body}" id)
if [[ -n "${UF_ID}" ]]; then pass "06 upsertSkillFile"; else fail "06 upsertSkillFile: ${uf_body}"; fi

# ─── 7. listSkillFiles (GET /api/skills/:id/files) ───────────────────
lf_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/skills/${SKILL_ID}/files")
if [[ "${lf_status}" == "200" ]]; then pass "07 listSkillFiles (200)"; else fail "07 listSkillFiles (${lf_status})"; fi

# ─── 8. deleteSkillFile (DELETE /api/skills/:id/files/:path) ────────
df_status=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" \
    "${BASE}/api/skills/${SKILL_ID}/files/extra.md")
if [[ "${df_status}" == "200" || "${df_status}" == "204" ]]; then pass "08 deleteSkillFile (${df_status})"; else fail "08 deleteSkillFile (${df_status})"; fi

# ─── 9. deleteSkill (DELETE /api/skills/:id) ─────────────────────────
ds_status=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" "${BASE}/api/skills/${SKILL_ID}")
if [[ "${ds_status}" == "200" || "${ds_status}" == "204" ]]; then pass "09 deleteSkill (${ds_status})"; else fail "09 deleteSkill (${ds_status})"; fi

# ─── 10. importSkill (POST /api/skills/import) ───────────────────────
# The import endpoint currently supports only github.com/skills.sh/clawhub.ai
# sources. An unsupported/undetectable URL returns 502, which still
# exercises the endpoint wiring and validation.
im_status=$(http_status -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"url\":\"http://example.test/SKILL.md\",\"name\":\"Imported Skill\"}" \
    "${BASE}/api/skills/import")
if [[ "${im_status}" == "502" ]]; then pass "10 importSkill rejects unsupported source (502)"; else fail "10 importSkill (${im_status})"; fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All skill endpoints responded correctly${RESET}"
    exit 0
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
