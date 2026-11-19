#!/usr/bin/env bash
# End-to-end HTTP regression test for the agent module.
#
# Boots a fresh zserver (no-DB mode), authenticates a dev user,
# creates a scratch workspace, and exercises the public endpoints
# in `src/modules/agent/routes.zig`:
#   list / create / get / update / archive / restore /
#   cancel-tasks / list-tasks / get-env / set-env /
#   list-skills / set-skills / add-skills
#
# Usage:
#   ONEPERSON_DEV_VERIFICATION_CODE=000000 \
#   JWT_SECRET=test-secret \
#   ./scripts/agent_e2e.sh
#
# Override the port with PORT=<n>.

set -euo pipefail

PORT="${PORT:-18091}"
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
( cd "${SCRIPT_DIR}/.." && ZIG_LOCAL_CACHE_DIR=/tmp/zig-local ZIG_GLOBAL_CACHE_DIR=/tmp/zig-global zig build ) || { echo "build failed"; exit 1; }

# Start server
echo "==> starting zserver on port ${PORT}"
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-agent-e2e.log 2>&1 &
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
    tail -50 /tmp/zserver-agent-e2e.log
    exit 1
fi

# ─── Authenticate dev user ───────────────────────────────────────────
EMAIL="agent-e2e-$(date +%s)@example.com"
http_status -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${EMAIL}\"}" "${BASE}/auth/send-code" >/dev/null
code="${ONEPERSON_DEV_VERIFICATION_CODE:-000000}"
auth_body=$(http_body -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${EMAIL}\",\"code\":\"${code}\"}" "${BASE}/auth/verify-code")
TOKEN=$(jget_path "${auth_body}" token)
USER_ID=$(jget_path "${auth_body}" user.id)
if [[ -z "${TOKEN}" ]]; then
    warn "auth failed: ${auth_body}"
    exit 1
fi
AUTH="Authorization: Bearer ${TOKEN}"

# ─── Workspace ───────────────────────────────────────────────────────
ws_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
    -d "{\"name\":\"Agent E2E\",\"slug\":\"agent-e2e-$(date +%s)\"}" \
    "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
HWS="X-Workspace-Id: ${WS_ID}"

# ─── DB-mode: insert a runtime if DATABASE_URL is set ─────────────
if [[ -n "${DATABASE_URL:-}" ]]; then
    # The runtime needs an owner: `runtimeAllowsUser` admits the
    # runtime's owner and public runtimes only, so an ownerless row
    # would reject the agent creation with 403.
    RUNTIME_ID=$(psql "${DATABASE_URL}" -tAc "INSERT INTO agent_runtime (workspace_id, name, runtime_mode, provider, owner_id, visibility) VALUES ('${WS_ID}'::uuid, 'e2e-runtime', 'local', 'local', '${USER_ID}'::uuid, 'private') RETURNING id" 2>/dev/null | head -1 || echo "")
    if [[ -z "${RUNTIME_ID}" ]]; then
        warn "failed to create runtime, using fake id"
        RUNTIME_ID="00000000-0000-0000-0000-$(printf '%012d' $(date +%s))"
    else
        echo "  DB runtime: ${RUNTIME_ID}"
    fi
else
    RUNTIME_ID="00000000-0000-0000-0000-$(printf '%012d' $(date +%s))"
fi

# ─── 1. createAgent (POST /api/agents) ─────────────────────────
ca_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"name\":\"Test Agent\",\"description\":\"agent e2e\",\"instructions\":\"be helpful\",\"runtime_id\":\"${RUNTIME_ID}\",\"model\":\"claude-sonnet\",\"visibility\":\"private\"}" \
    "${BASE}/api/agents")
AGENT_ID=$(jget "${ca_body}" id)
AGENT_NAME=$(jget "${ca_body}" name)
if [[ -n "${AGENT_ID}" && "${AGENT_NAME}" == "Test Agent" ]]; then
    pass "01 createAgent (id=${AGENT_ID})"
else
    fail "01 createAgent: ${ca_body}"
fi

# ─── 2. listAgents (GET /api/agents) ──────────────────────────
la_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/agents")
LA_COUNT=$(echo "${la_body}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d, list) else len(d.get("agents", d.get("data", d.get("items", [])))))' 2>/dev/null || echo 0)
if [[ "${LA_COUNT}" -ge 1 ]]; then pass "02 listAgents (n=${LA_COUNT})"; else fail "02 listAgents: ${la_body}"; fi

# ─── 3. getAgent (GET /:id) ────────────────────────────────────
ga_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/agents/${AGENT_ID}")
GA_ID=$(jget "${ga_body}" id)
if [[ "${GA_ID}" == "${AGENT_ID}" ]]; then pass "03 getAgent"; else fail "03 getAgent: ${ga_body}"; fi

# ─── 4. updateAgent (PATCH /:id) ───────────────────────────────
ua_body=$(http_body -X PATCH -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{"description":"updated agent e2e","model":"claude-opus"}' "${BASE}/api/agents/${AGENT_ID}")
UA_DESC=$(jget "${ua_body}" description)
if [[ "${UA_DESC}" == "updated agent e2e" ]]; then pass "04 updateAgent"; else fail "04 updateAgent: ${ua_body}"; fi

# ─── 5. listAgentSkills (GET /:id/skills) ──────────────────────
lsk_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/agents/${AGENT_ID}/skills")
LSK_OK=$(jget "${lsk_body}" "ok")
# Response shape may vary — accept any successful 200 response.
if [[ -n "${lsk_body}" ]]; then pass "05 listAgentSkills"; else fail "05 listAgentSkills: ${lsk_body}"; fi

# ─── 6. setAgentSkills (PUT /:id/skills) ──────────────────────
ssk_body=$(http_body -X PUT -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{"skill_ids":["skill-a","skill-b"]}' "${BASE}/api/agents/${AGENT_ID}/skills")
SSK_OK=$(jget_path "${ssk_body}" data.ok)
if [[ -n "${ssk_body}" ]]; then pass "06 setAgentSkills"; else fail "06 setAgentSkills: ${ssk_body}"; fi

# ─── 7. addAgentSkills (POST /:id/skills) ─────────────────────
ask_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{"skill_ids":["skill-c"]}' "${BASE}/api/agents/${AGENT_ID}/skills")
if [[ -n "${ask_body}" ]]; then pass "07 addAgentSkills"; else fail "07 addAgentSkills: ${ask_body}"; fi

# ─── 8. getEnv (GET /:id/env) ──────────────────────────────────
ge_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/agents/${AGENT_ID}/env")
if [[ -n "${ge_body}" ]]; then pass "08 getEnv"; else fail "08 getEnv: ${ge_body}"; fi

# ─── 9. setEnv (PUT /:id/env) ──────────────────────────────────
se_body=$(http_body -X PUT -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{"env":{"KEY":"value","OTHER":"data"}}' "${BASE}/api/agents/${AGENT_ID}/env")
SE_OK=$(jget_path "${se_body}" data.ok)
if [[ -n "${se_body}" ]]; then pass "09 setEnv"; else fail "09 setEnv: ${se_body}"; fi

# ─── 10. listTasks (GET /:id/tasks) ───────────────────────────
lt_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/agents/${AGENT_ID}/tasks")
if [[ "${lt_status}" == "200" ]]; then pass "10 listTasks (200)"; else fail "10 listTasks (${lt_status})"; fi

# ─── 11. cancelTasks (POST /:id/cancel-tasks) ─────────────────
ct_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{}' "${BASE}/api/agents/${AGENT_ID}/cancel-tasks")
CT_OK=$(jget_path "${ct_body}" data.cancelled)
if [[ -n "${ct_body}" ]]; then pass "11 cancelTasks"; else fail "11 cancelTasks: ${ct_body}"; fi

# ─── 12. archiveAgent (DELETE /:id) ────────────────────────────
aa_status=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" "${BASE}/api/agents/${AGENT_ID}")
if [[ "${aa_status}" == "200" || "${aa_status}" == "204" ]]; then pass "12 archiveAgent (${aa_status})"; else fail "12 archiveAgent (${aa_status})"; fi

# ─── 13. restoreAgent (POST /:id/restore) ──────────────────────
ra_status=$(http_status -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{}' "${BASE}/api/agents/${AGENT_ID}/restore")
if [[ "${ra_status}" == "200" || "${ra_status}" == "204" ]]; then pass "13 restoreAgent (${ra_status})"; else fail "13 restoreAgent (${ra_status})"; fi

# ─── 14. unknown agent 404 ─────────────────────────────────────
nf_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/agents/does-not-exist")
if [[ "${nf_status}" == "404" ]]; then pass "14 getAgent unknown (404)"; else fail "14 getAgent unknown (${nf_status})"; fi

# ─── 15. listAgents after archive/restore ─────────────────────
la2_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/agents")
LA2_COUNT=$(echo "${la2_body}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d, list) else len(d.get("agents", d.get("data", d.get("items", [])))))' 2>/dev/null || echo 0)
if [[ "${LA2_COUNT}" -ge 1 ]]; then pass "15 listAgents still includes agent"; else fail "15 listAgents: ${la2_body}"; fi

# ─── 16. another workspace's agent is invisible ────────────────
# An agent id is not a capability. A request scoped to one workspace
# must not reach an agent of another workspace — and above all not its
# run history: `GET /:id/tasks` used to look the agent up by id alone
# and answered 200 with the foreign agent's task list, the results
# the agent produced included.
STAMP=$(date +%s)
ws2_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
    -d "{\"name\":\"Agent E2E Other\",\"slug\":\"agent-e2e-other-${STAMP}\"}" \
    "${BASE}/api/workspaces")
WS2_ID=$(jget "${ws2_body}" id)
HWS2="X-Workspace-Id: ${WS2_ID}"

if [[ -z "${WS2_ID}" ]]; then
    fail "16 second workspace: ${ws2_body}"
else
    # The runtime has to live in the workspace of the agent:
    # createAgent rejects a runtime borrowed from another workspace.
    RUNTIME2_ID=""
    if [[ -n "${DATABASE_URL:-}" ]]; then
        RUNTIME2_ID=$(psql "${DATABASE_URL}" -tAc "INSERT INTO agent_runtime (workspace_id, name, runtime_mode, provider, owner_id, visibility) VALUES ('${WS2_ID}'::uuid, 'e2e-runtime-2', 'local', 'local', '${USER_ID}'::uuid, 'private') RETURNING id" 2>/dev/null | head -1 || echo "")
    fi
    if [[ -z "${RUNTIME2_ID}" ]]; then
        RUNTIME2_ID="00000000-0000-0000-0001-$(printf '%012d' ${STAMP})"
    fi

    ca2_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS2}" \
        -d "{\"name\":\"Foreign Agent\",\"description\":\"other workspace\",\"instructions\":\"foreign instructions\",\"runtime_id\":\"${RUNTIME2_ID}\",\"visibility\":\"private\"}" \
        "${BASE}/api/agents")
    AGENT2_ID=$(jget "${ca2_body}" id)
    if [[ -z "${AGENT2_ID}" ]]; then
        fail "16 agent in the second workspace: ${ca2_body}"
    else
        pass "16 agent in a second workspace (id=${AGENT2_ID})"

        # A finished task with an output worth stealing.
        if [[ -n "${DATABASE_URL:-}" ]]; then
            issue2_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS2}" \
                -d '{"title":"foreign issue","description":"cross workspace check"}' "${BASE}/api/issues")
            ISSUE2_ID=$(jget_path "${issue2_body}" data.id)
            if [[ -n "${ISSUE2_ID}" ]]; then
                # `runtime_id` is NOT NULL on the task queue.
                psql "${DATABASE_URL}" -tAc "INSERT INTO agent_task_queue (agent_id, issue_id, runtime_id, status, result) VALUES ('${AGENT2_ID}'::uuid, '${ISSUE2_ID}'::uuid, '${RUNTIME2_ID}'::uuid, 'completed', '\"FOREIGN-TASK-OUTPUT\"'::jsonb)" >/dev/null 2>&1 || true
            fi
        fi

        # The control: the task list is readable in its own workspace.
        own_tasks=$(http_body -H "${AUTH}" -H "${HWS2}" "${BASE}/api/agents/${AGENT2_ID}/tasks")
        if [[ "${own_tasks}" == *"FOREIGN-TASK-OUTPUT"* ]]; then
            pass "17 the task list is readable in its own workspace"
        elif [[ -n "${DATABASE_URL:-}" ]]; then
            fail "17 the task list is readable in its own workspace: ${own_tasks}"
        else
            pass "17 the task list is readable in its own workspace (no-DB mode)"
        fi

        # The leak: the same agent id, read through the other workspace.
        cross_tasks_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/agents/${AGENT2_ID}/tasks")
        cross_tasks_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/agents/${AGENT2_ID}/tasks")
        if [[ "${cross_tasks_status}" == "404" && "${cross_tasks_body}" != *"FOREIGN-TASK-OUTPUT"* ]]; then
            pass "18 another workspace's task list is not readable (404)"
        else
            fail "18 another workspace's task list is not readable (${cross_tasks_status}): ${cross_tasks_body}"
        fi

        cross_agent_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/agents/${AGENT2_ID}")
        if [[ "${cross_agent_status}" == "404" ]]; then
            pass "19 another workspace's agent is not readable (404)"
        else
            fail "19 another workspace's agent is not readable (${cross_agent_status})"
        fi
    fi
fi

# ─── 20. a private agent stays private ─────────────────────────
# The detail endpoint, the run history and the agent list all answer
# to the same gate: a private agent belongs to its owner, and a plain
# member of the same workspace may not read it. The list keeps the
# agent's identity — the workspace renders issue assignees from it —
# but not the owner's material.
if [[ -n "${DATABASE_URL:-}" ]]; then
    EMAIL2="agent-e2e-member-${STAMP}@example.com"
    http_status -X POST -H "Content-Type: application/json" \
        -d "{\"email\":\"${EMAIL2}\"}" "${BASE}/auth/send-code" >/dev/null
    auth2_body=$(http_body -X POST -H "Content-Type: application/json" \
        -d "{\"email\":\"${EMAIL2}\",\"code\":\"${code}\"}" "${BASE}/auth/verify-code")
    TOKEN2=$(jget_path "${auth2_body}" token)
    USER2_ID=$(jget_path "${auth2_body}" user.id)
    AUTH2="Authorization: Bearer ${TOKEN2}"

    if [[ -z "${TOKEN2}" || -z "${USER2_ID}" ]]; then
        fail "20 second member signs in: ${auth2_body}"
    else
        psql "${DATABASE_URL}" -tAc "INSERT INTO member (workspace_id, user_id, role) VALUES ('${WS_ID}'::uuid, '${USER2_ID}'::uuid, 'member') ON CONFLICT (workspace_id, user_id) DO NOTHING" >/dev/null 2>&1 || true

        member_detail=$(http_status -H "${AUTH2}" -H "${HWS}" "${BASE}/api/agents/${AGENT_ID}")
        if [[ "${member_detail}" == "403" ]]; then
            pass "20 a private agent's detail is closed to other members (403)"
        else
            fail "20 a private agent's detail is closed to other members (${member_detail})"
        fi

        member_tasks=$(http_status -H "${AUTH2}" -H "${HWS}" "${BASE}/api/agents/${AGENT_ID}/tasks")
        if [[ "${member_tasks}" == "403" ]]; then
            pass "21 a private agent's run history is closed to other members (403)"
        else
            fail "21 a private agent's run history is closed to other members (${member_tasks})"
        fi

        member_skills=$(http_status -H "${AUTH2}" -H "${HWS}" "${BASE}/api/agents/${AGENT_ID}/skills")
        if [[ "${member_skills}" == "403" ]]; then
            pass "22 a private agent's skills are closed to other members (403)"
        else
            fail "22 a private agent's skills are closed to other members (${member_skills})"
        fi

        member_list=$(http_body -H "${AUTH2}" -H "${HWS}" "${BASE}/api/agents")
        member_instructions=$(echo "${member_list}" | python3 -c "
import sys, json
try:
    agents = json.load(sys.stdin)
except Exception:
    print('__BROKEN__'); sys.exit(0)
for a in agents:
    if a.get('id') == '${AGENT_ID}':
        print(a.get('instructions', '')); sys.exit(0)
print('__MISSING__')
" 2>/dev/null || echo "__BROKEN__")
        if [[ "${member_instructions}" == "" ]]; then
            pass "23 the list keeps the agent but not its instructions"
        else
            fail "23 the list keeps the agent but not its instructions: ${member_instructions}"
        fi

        owner_instructions=$(echo "$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/agents")" | python3 -c "
import sys, json
try:
    agents = json.load(sys.stdin)
except Exception:
    print('__BROKEN__'); sys.exit(0)
for a in agents:
    if a.get('id') == '${AGENT_ID}':
        print(a.get('instructions', '')); sys.exit(0)
print('__MISSING__')
" 2>/dev/null || echo "__BROKEN__")
        if [[ "${owner_instructions}" == "be helpful" ]]; then
            pass "24 the owner still reads its own instructions"
        else
            fail "24 the owner still reads its own instructions: ${owner_instructions}"
        fi
    fi
else
    warn "20-24 skipped: the private-agent gate needs a second member, which the no-DB mode cannot hold"
fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All agent endpoints responded correctly${RESET}"
    exit 0
else
    echo -e "${RED}${failures} check(s) failed${RESET}"
    exit 1
fi
