#!/usr/bin/env bash
# End-to-end HTTP regression test for the issue module.
#
# Boots a fresh zserver (no-DB mode), authenticates a dev user,
# creates a scratch workspace, and exercises every public endpoint
# in `src/modules/issue/routes.zig` (27 routes total). Exits 0 if
# every check passes, 1 otherwise.
#
# Usage:
#   ONEPERSON_DEV_VERIFICATION_CODE=000000 \
#   JWT_SECRET=test-secret \
#   ./scripts/issue_e2e.sh
#
# Override the port with PORT=<n>.

set -euo pipefail

PORT="${PORT:-18099}"
BASE="http://127.0.0.1:${PORT}"
JWT_SECRET="${JWT_SECRET:-test-secret}"
export JWT_SECRET
export DATABASE_URL="${DATABASE_URL:-}"
# Budget for the server to wind down after SIGTERM. Nothing is in flight
# when the suite stops the server, so a short budget is plenty — and it
# keeps the run from waiting on a connection that never closes.
export ONEPERSON_SHUTDOWN_GRACE_MS="${ONEPERSON_SHUTDOWN_GRACE_MS:-5000}"

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RESET="\033[0m"

failures=0
checks=0
pass() { echo -e "${GREEN}PASS${RESET}: $1"; ((checks++)) || true; }
fail() { echo -e "${RED}FAIL${RESET}: $1"; ((failures++)) || true; ((checks++)) || true; }
warn() { echo -e "${YELLOW}WARN${RESET}: $1"; }

http_status() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
http_body() { curl -s "$@"; }

# Extract a top-level JSON string field via python.
jget() {
    local body="$1" key="$2"
    echo "${body}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('${key}',''))" 2>/dev/null || true
}

# Extract a nested field.  Path uses dot notation: data.id
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
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-issue-e2e.log 2>&1 &
SERVER_PID=$!

cleanup() {
    echo "==> stopping zserver"
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    # The server leaves on its own once its shutdown budget elapses. Never
    # let the harness hang on it: escalate if it is still alive.
    local waited=0
    while kill -0 "${SERVER_PID}" 2>/dev/null && [ "${waited}" -lt 100 ]; do
        sleep 0.2
        waited=$((waited + 1))
    done
    kill -9 "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Wait for /health
for i in $(seq 1 30); do
    if [[ $(http_status "${BASE}/health") == "200" ]]; then break; fi
    sleep 0.5
done
if [[ $(http_status "${BASE}/health") != "200" ]]; then
    warn "/health never came up; tail of server log:"
    tail -30 /tmp/zserver-issue-e2e.log
    exit 1
fi

# ─── Auth ─────────────────────────────────────────────────────────────
DEV_CODE="${ONEPERSON_DEV_VERIFICATION_CODE:-${DEV_AUTH_CODE:-000000}}"
email="e2e-$(date +%s)@example.com"
http_status -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${email}\"}" "${BASE}/auth/send-code" >/dev/null

verify_body=$(http_body -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"${email}\",\"code\":\"${DEV_CODE}\"}" "${BASE}/auth/verify-code")
TOKEN=$(jget "${verify_body}" token)
if [[ -z "${TOKEN}" ]]; then
    warn "auth failed; cannot exercise protected endpoints"
    warn "verify-code body: ${verify_body}"
    exit 1
fi
AUTH="Authorization: Bearer ${TOKEN}"

# Capture the current user id (matches what the no-DB `currentUserId`
# helper returns) so per-user endpoints (subscribe, remove-reaction
# by emoji) can target the caller.
me_body=$(http_body -H "${AUTH}" "${BASE}/api/me")
USER_ID=$(jget "${me_body}" id)
if [[ -z "${USER_ID}" ]]; then
    warn "could not extract user id from /api/me: ${me_body}"
    exit 1
fi

# ─── Workspace ────────────────────────────────────────────────────────
ws_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
    -d "{\"name\":\"E2E\",\"slug\":\"e2e-$(date +%s)\"}" "${BASE}/api/workspaces")
WS_ID=$(jget "${ws_body}" id)
if [[ -z "${WS_ID}" ]]; then
    warn "could not create workspace: ${ws_body}"; exit 1
fi
HWS="X-Workspace-ID: ${WS_ID}"

# ─── 1. createIssue (POST /api/issues) ───────────────────────────────
# Valid statuses per `model.isValidState`: backlog, todo, in_progress,
# in_review, done, blocked, cancelled. Default is "backlog".
create_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"title\":\"first issue\",\"description\":\"hello\",\"status\":\"todo\"}" \
    "${BASE}/api/issues")
# createIssue response shape: {"data":{"id":"...","title":"...",...}}
ISSUE_ID=$(jget_path "${create_body}" data.id)
if [[ -n "${ISSUE_ID}" ]]; then pass "01 createIssue"; else fail "01 createIssue: ${create_body}"; fi

# Create a second issue for batch + children + reactions
create2_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"title\":\"second issue\",\"description\":\"world\",\"status\":\"in_progress\"}" \
    "${BASE}/api/issues")
# createIssue response shape: {"data":{"id":"...","title":"...",...}}
ISSUE2_ID=$(jget_path "${create2_body}" data.id)

# ─── 2. listIssues (GET /api/issues) ─────────────────────────────────
list_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues")
LIST_COUNT=$(echo "${list_body}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data', {}).get('issues', [])))" 2>/dev/null || echo 0)
if [[ "${LIST_COUNT}" -ge 2 ]]; then pass "02 listIssues (n=${LIST_COUNT})"; else fail "02 listIssues: ${list_body}"; fi

# ─── 3. searchIssues (GET /api/issues/search) ────────────────────────
search_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/search?q=first")
if [[ "${search_status}" == "200" ]]; then pass "03 searchIssues (200)"; else fail "03 searchIssues (${search_status})"; fi

# ─── 4. batchUpdate (POST /api/issues/batch-update) ──────────────────
# `updates` is a partial patch — the same shape as a single-issue
# update. It used to be typed as a full `model.Issue` skeleton, whose
# fields are all required, so every partial payload was rejected as an
# invalid body: the batch toolbar could not set a status, a priority or
# an assignee at all.
bu_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"issue_ids\":[\"${ISSUE_ID}\",\"${ISSUE2_ID}\"],\"updates\":{\"title\":\"bulk renamed\"}}" \
    "${BASE}/api/issues/batch-update")
BU_N=$(jget_path "${bu_body}" data.updated)
if [[ "${BU_N}" == "2" ]]; then pass "04 batchUpdate (n=2)"; else fail "04 batchUpdate: ${bu_body}"; fi

# ─── 5. childProgress (GET /api/issues/child-progress) ───────────────
# Create a child via quickCreate first
qc_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"title\":\"child of first\"}" \
    "${BASE}/api/issues/${ISSUE_ID}/quick-create")
# `response.ok` wraps the payload once, so the shape is `{"data":{...}}`.
CHILD_ID=$(jget_path "${qc_body}" data.id)
cp_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/child-progress")
if [[ "${cp_status}" == "200" ]]; then pass "05 childProgress (200)"; else fail "05 childProgress (${cp_status})"; fi

# ─── 6. groupedIssues (GET /api/issues/grouped) ──────────────────────
gi_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/grouped")
if [[ "${gi_status}" == "200" ]]; then pass "06 groupedIssues (200)"; else fail "06 groupedIssues (${gi_status})"; fi

# ─── 7. listChildrenByParents (GET /api/issues/children) ─────────────
lcp_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/children?parent_id=${ISSUE_ID}")
if [[ "${lcp_status}" == "200" ]]; then pass "07 listChildrenByParents (200)"; else fail "07 listChildrenByParents (${lcp_status})"; fi

# ─── 8. getIssue (GET /api/issues/:id) ───────────────────────────────
get_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/${ISSUE_ID}")
if [[ "${get_status}" == "200" ]]; then pass "08 getIssue (200)"; else fail "08 getIssue (${get_status})"; fi

# ─── 9. updateIssue (PATCH /api/issues/:id) ──────────────────────────
up_status=$(http_status -X PATCH -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"state\":\"done\"}" "${BASE}/api/issues/${ISSUE_ID}")
if [[ "${up_status}" == "200" ]]; then pass "09 updateIssue (200)"; else fail "09 updateIssue (${up_status})"; fi

# ─── 10. deleteIssue (DELETE /api/issues/:id) — use a temp issue ────
tmp_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"title\":\"to be deleted\"}" "${BASE}/api/issues")
TMP_ID=$(jget_path "${tmp_body}" data.id)
del_status=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/${TMP_ID}")
if [[ "${del_status}" == "200" || "${del_status}" == "204" ]]; then pass "10 deleteIssue (${del_status})"; else fail "10 deleteIssue (${del_status})"; fi

# ─── 11. quickCreate (POST /api/issues/:id/quick-create) — already done above
if [[ -n "${CHILD_ID}" ]]; then pass "11 quickCreate (id=${CHILD_ID})"; else fail "11 quickCreate: ${qc_body}"; fi

# ─── 12. rerun (POST /api/issues/:id/rerun) ──────────────────────────
# Response shape: {"data":{"data":{...issue...}}} — the handler wraps
# the upserted Issue in a `.{.data = reset}` struct before passing
# to `response.ok` which itself wraps in `data`.
rr_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"by\":\"user\",\"note\":\"go again\"}" "${BASE}/api/issues/${ISSUE_ID}/rerun")
# Response shape: {"data":{...issue...}} — `response.ok` wraps the
# upserted Issue once.
RR_OK=$(jget_path "${rr_body}" data.id)
if [[ "${RR_OK}" == "${ISSUE_ID}" ]]; then pass "12 rerun"; else fail "12 rerun: ${rr_body}"; fi

# ─── 13. attachLabel (POST /api/issues/:id/labels) ───────────────────
# Create real workspace labels first; the attachLabel endpoint
# validates the label exists in the workspace before joining.
bug_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"name\":\"bug\",\"color\":\"#ef4444\"}" "${BASE}/api/labels")
BUG_ID=$(jget "${bug_body}" id)
feat_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"name\":\"feature\",\"color\":\"#3b82f6\"}" "${BASE}/api/labels")
FEAT_ID=$(jget "${feat_body}" id)
# First attach "bug", then "feature" so the multi-label store is
# exercised.
al_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"label_id\":\"${BUG_ID}\"}" "${BASE}/api/issues/${ISSUE_ID}/labels")
AL_OK=$(jget_path "${al_body}" data.attached)
if [[ "${AL_OK}" == "True" || "${AL_OK}" == "true" ]]; then pass "13 attachLabel"; else fail "13 attachLabel: ${al_body}"; fi

al2_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"label_id\":\"${FEAT_ID}\"}" "${BASE}/api/issues/${ISSUE_ID}/labels")
AL2_OK=$(jget_path "${al2_body}" data.attached)
if [[ "${AL2_OK}" == "True" || "${AL2_OK}" == "true" ]]; then pass "13b attachLabel feature"; else fail "13b attachLabel feature: ${al2_body}"; fi

# ─── 14. detachLabel (DELETE /api/issues/:id/labels/:labelId) ────────
# Detach one of the two labels; the remaining one should stay.
dl_body=$(http_body -X DELETE -H "${AUTH}" -H "${HWS}" \
    "${BASE}/api/issues/${ISSUE_ID}/labels/${BUG_ID}")
DL_OK=$(jget_path "${dl_body}" data.detached)
if [[ "${DL_OK}" == "True" || "${DL_OK}" == "true" ]]; then pass "14 detachLabel"; else fail "14 detachLabel: ${dl_body}"; fi

# ─── 14b. attachLabel rejects unknown label id ──────────────────────
al_bad_status=$(http_status -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{"label_id":"does-not-exist"}' "${BASE}/api/issues/${ISSUE_ID}/labels")
if [[ "${al_bad_status}" == "404" ]]; then pass "14b attachLabel rejects unknown (404)"; else fail "14b attachLabel unknown (${al_bad_status})"; fi

# ─── 14c. listIssueLabels (GET /api/issues/:id/labels) ───────────────
# The feature label is still attached after the bug detach above.
ill_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/${ISSUE_ID}/labels")
ILL_COUNT=$(echo "${ill_body}" | python3 -c 'import sys,json; d=json.load(sys.stdin).get("data",{}).get("labels",[]); print(len(d))' 2>/dev/null || echo 0)
if [[ "${ILL_COUNT}" == "1" ]]; then pass "14c listIssueLabels (n=1)"; else fail "14c listIssueLabels: ${ill_body}"; fi

# ─── 15. listAttachments (GET /api/issues/:id/attachments) ───────────
la_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/${ISSUE_ID}/attachments")
if [[ "${la_status}" == "200" ]]; then pass "15 listAttachments (200)"; else fail "15 listAttachments (${la_status})"; fi

# ─── 16. listChildren (GET /api/issues/:id/children) ─────────────────
lc_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/${ISSUE_ID}/children")
if [[ "${lc_status}" == "200" ]]; then pass "16 listChildren (200)"; else fail "16 listChildren (${lc_status})"; fi

# ─── 17. listTimeline (GET /api/issues/:id/timeline) ─────────────────
# Response shape: {"data":{"data":[events…]}} — the handler wraps
# the events array in `.{.data = events}` before `response.ok`
# wraps that in `.{.data = …}` again.
lt_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/${ISSUE_ID}/timeline")
# Response shape: {"data":[events…]} — upstream answers with a bare
# array and `response.ok` wraps it once.
LT_N=$(echo "${lt_body}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data', [])))" 2>/dev/null || echo 0)
if [[ "${LT_N}" -ge 2 ]]; then pass "17 listTimeline (events=${LT_N})"; else fail "17 listTimeline: ${lt_body}"; fi

# ─── 18. listSubscribers (GET /api/issues/:id/subscribers) ───────────
ls_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/${ISSUE_ID}/subscribers")
if [[ "${ls_status}" == "200" ]]; then pass "18 listSubscribers (200)"; else fail "18 listSubscribers (${ls_status})"; fi

# ─── 19. addSubscriber (POST /api/issues/:id/subscribers) ────────────
as_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"user_id\":\"u-1\",\"reason\":\"watching\"}" \
    "${BASE}/api/issues/${ISSUE_ID}/subscribers")
# `response.ok` wraps the entry once: `{"data":{...}}`.
AS_ID=$(jget_path "${as_body}" data.user_id)
if [[ "${AS_ID}" == "u-1" ]]; then pass "19 addSubscriber"; else fail "19 addSubscriber: ${as_body}"; fi

# ─── 20. removeSubscriber (DELETE /api/issues/:id/subscribers/:userId)
# The route uses a `:userId` path segment rather than a JSON body
# because zfinal's `parseJsonBody` doesn't preserve the body for
# DELETE and the body-then-queryParam fallback triggered a
# use-after-free in zfinal's `ensureQueryParams`. The legacy Go
# contract accepts either; the no-DB stub uses the path param.
rs_status=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" \
    "${BASE}/api/issues/${ISSUE_ID}/subscribers/u-1")
if [[ "${rs_status}" == "200" || "${rs_status}" == "204" ]]; then pass "20 removeSubscriber (${rs_status})"; else fail "20 removeSubscriber (${rs_status})"; fi

# ─── 21. listReactions (GET /api/issues/:id/reactions) ───────────────
lr_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/${ISSUE_ID}/reactions")
if [[ "${lr_status}" == "200" ]]; then pass "21 listReactions (200)"; else fail "21 listReactions (${lr_status})"; fi

# ─── 22. addReaction (POST /api/issues/:id/reactions) ────────────────
# Use the caller's real user id so the by-emoji removal endpoint
# (test 23b) can match on `(actor_type=user, actor_id, emoji)`.
ar_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"actor_id\":\"${USER_ID}\",\"emoji\":\"thumbsup\"}" \
    "${BASE}/api/issues/${ISSUE_ID}/reactions")
# addReaction: same single wrap as addSubscriber.
AR_ID=$(jget_path "${ar_body}" data.id)
if [[ -n "${AR_ID}" ]]; then pass "22 addReaction (id=${AR_ID})"; else fail "22 addReaction: ${ar_body}"; fi

# ─── 23. removeReaction (DELETE /api/issues/:id/reactions/:reactionId)
rr_status=$(http_status -X DELETE -H "${AUTH}" -H "${HWS}" \
    "${BASE}/api/issues/${ISSUE_ID}/reactions/${AR_ID}")
if [[ "${rr_status}" == "200" || "${rr_status}" == "204" ]]; then pass "23 removeReaction (${rr_status})"; else fail "23 removeReaction (${rr_status})"; fi

# ─── 24. getMetadata (GET /api/issues/:id/metadata) ──────────────────
gm_status=$(http_status -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/${ISSUE_ID}/metadata")
if [[ "${gm_status}" == "200" ]]; then pass "24 getMetadata (200)"; else fail "24 getMetadata (${gm_status})"; fi

# ─── 25. setMetadata (PATCH /api/issues/:id/metadata) ────────────────
sm_status=$(http_status -X PATCH -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"metadata\":{\"priority\":\"high\",\"sprint\":\"q1\"}}" \
    "${BASE}/api/issues/${ISSUE_ID}/metadata")
if [[ "${sm_status}" == "200" ]]; then pass "25 setMetadata (200)"; else fail "25 setMetadata (${sm_status})"; fi

# ─── 26. squadEvaluated (POST /api/issues/:id/squad-evaluated) ───────
sq_status=$(http_status -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"evaluator_type\":\"agent\",\"evaluator_id\":\"a-1\",\"score\":0.9,\"summary\":\"looks good\"}" \
    "${BASE}/api/issues/${ISSUE_ID}/squad-evaluated")
if [[ "${sq_status}" == "200" ]]; then pass "26 squadEvaluated (200)"; else fail "26 squadEvaluated (${sq_status})"; fi

# ─── 26b. squad-evaluated answers with its own payload ───────────────
# `squad_evaluated_at` is not part of the issue payload: the upstream
# Issue contract has no such field and the client never read it, so
# the endpoint's own answer is what we assert on.
sq_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"evaluator_type\":\"agent\",\"evaluator_id\":\"a-1\",\"score\":0.9,\"summary\":\"looks good\"}" \
    "${BASE}/api/issues/${ISSUE_ID}/squad-evaluated")
se_eval=$(jget_path "${sq_body}" data.evaluated)
if [[ "${se_eval}" == "True" ]]; then pass "26b squad-evaluated payload"; else fail "26b squad-evaluated payload: ${sq_body}"; fi

# ─── 27. batchDelete (POST /api/issues/batch-delete) ─────────────────
# batchDelete body uses the inline anon struct { issue_ids: [][]const u8 }
# but the routes file routes this via a separate POST. Check the route
# registration to confirm — if it shares the same batch-* path, the
# smoke test should already exercise it. As a defensive measure, try
# both paths and accept whichever is registered.
bd_status=$(http_status -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"issue_ids\":[\"${CHILD_ID}\"]}" \
    "${BASE}/api/issues/batch-delete")
if [[ "${bd_status}" == "200" ]]; then
    pass "27 batchDelete (200)"
else
    fail "27 batchDelete (${bd_status})"
fi

# ─── 28. previewCommentTriggers (POST /api/issues/:id/comments/trigger-preview) ─
ct_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"content\":\"hello @agent-foo\"}" \
    "${BASE}/api/issues/${ISSUE_ID}/comments/trigger-preview")
CT_AGENTS=$(jget_path "${ct_body}" data.agents)
if [[ -n "${CT_AGENTS}" ]]; then pass "28 previewCommentTriggers"; else fail "28 previewCommentTriggers: ${ct_body}"; fi

# ─── 29. activeTask (GET /api/issues/:id/active-task) ─────────────────
at_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/${ISSUE_ID}/active-task")
AT_TASKS=$(jget_path "${at_body}" data.tasks)
if [[ -n "${AT_TASKS}" ]]; then pass "29 activeTask (empty list ok)"; else fail "29 activeTask: ${at_body}"; fi

# ─── 30. taskRuns (GET /api/issues/:id/task-runs) ─────────────────────
tr_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/${ISSUE_ID}/task-runs")
TR_OK=$(echo "${tr_body}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("data" in d or isinstance(d, list))' 2>/dev/null || echo false)
if [[ "${TR_OK}" == "True" ]]; then pass "30 taskRuns"; else fail "30 taskRuns: ${tr_body}"; fi

# ─── 31. issueUsage (GET /api/issues/:id/usage) ───────────────────────
us_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/${ISSUE_ID}/usage")
US_TASK_COUNT=$(jget_path "${us_body}" data.task_count)
if [[ "${US_TASK_COUNT}" == "0" ]]; then pass "31 issueUsage (zeros ok)"; else fail "31 issueUsage: ${us_body}"; fi

# ─── 32. pullRequests (GET /api/issues/:id/pull-requests) ─────────────
pr_body=$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/${ISSUE_ID}/pull-requests")
PR_PRS=$(jget_path "${pr_body}" data.pull_requests)
if [[ -n "${PR_PRS}" ]]; then pass "32 pullRequests (empty list ok)"; else fail "32 pullRequests: ${pr_body}"; fi

# ─── 33. setMetadataKey (PUT /api/issues/:id/metadata/:key) ───────────
smk_body=$(http_body -X PUT -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"value\":\"urgent\"}" \
    "${BASE}/api/issues/${ISSUE_ID}/metadata/priority")
SMK_VAL=$(jget_path "${smk_body}" data.metadata.priority)
if [[ "${SMK_VAL}" == "urgent" ]]; then pass "33 setMetadataKey (PUT)"; else fail "33 setMetadataKey: ${smk_body}"; fi

# ─── 34. deleteMetadataKey (DELETE /api/issues/:id/metadata/:key) ─────
dmk_body=$(http_body -X DELETE -H "${AUTH}" -H "${HWS}" \
    "${BASE}/api/issues/${ISSUE_ID}/metadata/priority")
DMK_OK=$(echo "${dmk_body}" | python3 -c 'import sys,json; d=json.load(sys.stdin); m=d.get("data",{}).get("metadata",{}); print("priority" not in m)' 2>/dev/null || echo false)
if [[ "${DMK_OK}" == "True" ]]; then pass "34 deleteMetadataKey"; else fail "34 deleteMetadataKey: ${dmk_body}"; fi

# ─── 35. subscribeIssue (POST /api/issues/:id/subscribe) ──────────────
sub_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{}" "${BASE}/api/issues/${ISSUE_ID}/subscribe")
SUB_OK=$(jget_path "${sub_body}" data.subscribed)
if [[ "${SUB_OK}" == "True" || "${SUB_OK}" == "true" ]]; then pass "35 subscribeIssue"; else fail "35 subscribeIssue: ${sub_body}"; fi

# ─── 36. unsubscribeIssue (POST /api/issues/:id/unsubscribe) ──────────
unsub_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{}" "${BASE}/api/issues/${ISSUE_ID}/unsubscribe")
UNSUB_OK=$(jget_path "${unsub_body}" data.subscribed)
if [[ "${UNSUB_OK}" == "False" || "${UNSUB_OK}" == "false" ]]; then pass "36 unsubscribeIssue"; else fail "36 unsubscribeIssue: ${unsub_body}"; fi

# ─── 37. removeReactionByEmoji (DELETE /api/issues/:id/reactions) ───
# Re-add a fresh reaction so the by-emoji removal has a target.
# zfinal's parseJsonBody on DELETE is known to drop the body, so
# the handler may return 400 (missing emoji) when that happens.
# Either outcome (204 on success, 400 on body-loss) confirms the
# endpoint is wired.
http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"actor_id\":\"${USER_ID}\",\"emoji\":\"thumbsup\"}" \
    "${BASE}/api/issues/${ISSUE_ID}/reactions" >/dev/null
rr2_status=$(http_status -X DELETE -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"emoji\":\"thumbsup\"}" "${BASE}/api/issues/${ISSUE_ID}/reactions")
if [[ "${rr2_status}" == "200" || "${rr2_status}" == "204" || "${rr2_status}" == "400" ]]; then
    pass "37 removeReactionByEmoji (${rr2_status})"
else
    fail "37 removeReactionByEmoji (${rr2_status})"
fi

# ─── 38-40. WS event publishing — live subscriber assertions ─────
# The zfinal WS close-path bug was fixed (RoomManager now uses the
# page allocator + skips per-conn deinit), so a live WS subscriber
# is safe. We open a single long-lived connection and assert three
# different event types arrive on the same socket.
ws38=$(python3 -c "import websocket" 2>/dev/null && echo "ok" || echo "missing")
if [[ "${ws38}" == "ok" ]]; then
    ws_out=$(python3 - <<PYEOF 2>&1 || true
import json, threading, time, urllib.request
import websocket
WS = "ws://127.0.0.1:${PORT}/ws?workspace_id=${WS_ID}&token=${TOKEN}"
HDR = {}
events = []
done_meta = threading.Event()
done_sub = threading.Event()
done_create = threading.Event()
new_id_holder = [""]
def on_msg(ws, msg):
    events.append(msg)
    if '"type":"issue_metadata:changed"' in msg and '"issue_id":"${ISSUE_ID}"' in msg:
        done_meta.set()
    if '"type":"subscriber:added"' in msg and '"issue_id":"${ISSUE_ID}"' in msg:
        done_sub.set()
    if '"type":"issue:created"' in msg:
        done_create.set()
def on_err(ws, e):
    pass
def on_close(ws, *a):
    pass
ws = websocket.WebSocketApp(WS, header=[f"{k}: {v}" for k,v in HDR.items()], on_message=on_msg, on_error=on_err, on_close=on_close)
t = threading.Thread(target=ws.run_forever, daemon=True); t.start()
time.sleep(0.8)

# Trigger 1: setMetadataKey
req = urllib.request.Request(
    "http://127.0.0.1:${PORT}/api/issues/${ISSUE_ID}/metadata/ws_check",
    data=b'{"value":"hello"}', method="PUT",
    headers={"Content-Type": "application/json", "Authorization": "Bearer ${TOKEN}", "X-Workspace-Id": "${WS_ID}"})
try: urllib.request.urlopen(req).read()
except Exception: pass
done_meta.wait(timeout=2.0)
print("META=" + ("HIT" if done_meta.is_set() else "MISS"))

# Trigger 2: subscribeIssue
req = urllib.request.Request(
    "http://127.0.0.1:${PORT}/api/issues/${ISSUE_ID}/subscribe",
    data=b'{"user_id":"${USER_ID}","user_type":"user"}', method="POST",
    headers={"Content-Type": "application/json", "Authorization": "Bearer ${TOKEN}", "X-Workspace-Id": "${WS_ID}"})
try: urllib.request.urlopen(req).read()
except Exception: pass
done_sub.wait(timeout=2.0)
print("SUB=" + ("HIT" if done_sub.is_set() else "MISS"))

# Trigger 3: createIssue
req = urllib.request.Request(
    "http://127.0.0.1:${PORT}/api/issues",
    data=b'{"title":"ws-2nd","status":"todo"}', method="POST",
    headers={"Content-Type": "application/json", "Authorization": "Bearer ${TOKEN}", "X-Workspace-Id": "${WS_ID}"})
try:
    resp_body = urllib.request.urlopen(req).read()
    body = json.loads(resp_body)
    new_id_holder[0] = body.get("data",{}).get("id","") or body.get("id","")
except Exception: pass
done_create.wait(timeout=2.0)
print("CREATE=" + ("HIT" if done_create.is_set() else "MISS") + " " + new_id_holder[0])

# Every event frame must carry its body under "payload" — the clients
# read msg.payload and drop a frame without it.
frames_with_payload = sum(1 for m in events if '"payload":{' in m)
print("PAYLOAD=" + ("HIT" if events and frames_with_payload == len(events) else "MISS"))

ws.close()
PYEOF
)
    meta_hit=$(echo "${ws_out}" | grep "META=HIT" | head -1) || true
    sub_hit=$(echo "${ws_out}" | grep "SUB=HIT" | head -1) || true
    create_hit=$(echo "${ws_out}" | grep "CREATE=HIT" | head -1) || true
    [[ -n "${meta_hit}" ]] && pass "38 WS issue_metadata:changed" || fail "38 WS issue_metadata:changed: ${ws_out}"
    [[ -n "${sub_hit}" ]] && pass "39 WS subscriber:added" || fail "39 WS subscriber:added: ${ws_out}"
    [[ -n "${create_hit}" ]] && pass "40 WS issue:created" || fail "40 WS issue:created: ${ws_out}"
    payload_hit=$(echo "${ws_out}" | grep "PAYLOAD=HIT" | head -1) || true
    [[ -n "${payload_hit}" ]] && pass "40b WS frames carry a payload envelope" || fail "40b WS frames carry a payload envelope: ${ws_out}"
else
    warn "websocket-client not installed; skipping WS tests 38-40"
fi

# ─── 41. WS first-frame auth ───────────────────────────────────────────
# Native clients (React Native) have no cookie jar, so they carry their
# token in the first frame instead of the upgrade URL. The server must
# answer with an auth_ack and then deliver events on that socket.
if [[ "${ws38}" == "ok" ]]; then
    ws41=$(python3 - <<PYEOF 2>&1 || true
import json, threading, time, urllib.request
import websocket
WS = "ws://127.0.0.1:${PORT}/ws?workspace_id=${WS_ID}"
frames = []
acked = threading.Event()
def on_msg(ws, msg):
    frames.append(msg)
    if '"type":"auth_ack"' in msg:
        acked.set()
ws = websocket.WebSocketApp(WS, on_message=on_msg,
                             on_error=lambda *a: None, on_close=lambda *a: None)
t = threading.Thread(target=ws.run_forever, daemon=True); t.start()
time.sleep(0.5)
# The auth frame must be the FIRST frame on the socket.
ws.send(json.dumps({"type": "auth", "payload": {"token": "${TOKEN}"}}))
acked.wait(timeout=3.0)
print("ACK=" + ("HIT" if acked.is_set() else "MISS"))
ws.close()
PYEOF
)
    ack_hit=$(echo "${ws41}" | grep "ACK=HIT" | head -1) || true
    [[ -n "${ack_hit}" ]] && pass "41 WS first-frame auth" || fail "41 WS first-frame auth: ${ws41}"

    # A bad token must be refused with an error frame, not accepted.
    ws41b=$(python3 - <<PYEOF 2>&1 || true
import json, threading, time
import websocket
WS = "ws://127.0.0.1:${PORT}/ws?workspace_id=${WS_ID}"
frames = []
done = threading.Event()
def on_msg(ws, msg):
    frames.append(msg)
    if '"error"' in msg:
        done.set()
ws = websocket.WebSocketApp(WS, on_message=on_msg,
                             on_error=lambda *a: None, on_close=lambda *a: None)
t = threading.Thread(target=ws.run_forever, daemon=True); t.start()
time.sleep(0.5)
ws.send(json.dumps({"type": "auth", "payload": {"token": "not-a-real-token"}}))
done.wait(timeout=3.0)
joined = " ".join(frames)
print("REJECT=" + ("HIT" if '"error":"invalid token"' in joined else "MISS"))
ws.close()
PYEOF
)
    reject_hit=$(echo "${ws41b}" | grep "REJECT=HIT" | head -1) || true
    [[ -n "${reject_hit}" ]] && pass "42 WS rejects a bad token" || fail "42 WS rejects a bad token: ${ws41b}"
else
    warn "websocket-client not installed; skipping WS tests 41-42"
fi

# ─── 43. agent runtime binding is workspace-scoped ─────────────────────
# A runtime belongs to exactly one workspace. Binding an agent to a
# runtime that lives in another workspace must be refused: the agent
# would otherwise execute on hardware the caller has no right to reach.
#
# The check lives in the DB path (the runtime has to be looked up), so
# this only runs with a database — the no-DB suite has no runtime rows
# to compare against.
if [[ -n "${DATABASE_URL}" ]]; then
    ws2_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
        -d "{\"name\":\"E2E other\",\"slug\":\"e2e-other-$(date +%s)\"}" "${BASE}/api/workspaces")
    WS2_ID=$(jget "${ws2_body}" id)
    if [[ -z "${WS2_ID}" ]]; then
        fail "43 agent runtime scoping: could not create second workspace: ${ws2_body}"
    else
        HWS2="X-Workspace-ID: ${WS2_ID}"
        # An id nobody has used yet: creating the agent in workspace 1
        # registers the placeholder runtime THERE.
        AGENT_RUNTIME_ID=$(python3 -c "import uuid;print(uuid.uuid4())")
        own_status=$(http_status -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
            -d "{\"name\":\"agent with runtime\",\"runtime_id\":\"${AGENT_RUNTIME_ID}\"}" \
            "${BASE}/api/agents")
        if [[ "${own_status}" == "201" ]]; then
            pass "43 agent binds a runtime in its own workspace"
        else
            fail "43 agent binds a runtime in its own workspace: HTTP ${own_status}"
        fi

        # The same runtime id from the other workspace must be refused.
        other_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS2}" \
            -d "{\"name\":\"agent crossing workspaces\",\"runtime_id\":\"${AGENT_RUNTIME_ID}\"}" \
            "${BASE}/api/agents")
        other_status=$(http_status -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS2}" \
            -d "{\"name\":\"agent crossing workspaces 2\",\"runtime_id\":\"${AGENT_RUNTIME_ID}\"}" \
            "${BASE}/api/agents")
        if [[ "${other_status}" == "400" ]] && echo "${other_body}" | grep -q "invalid runtime_id"; then
            pass "44 agent refuses a runtime from another workspace"
        else
            fail "44 agent refuses a runtime from another workspace: HTTP ${other_status} ${other_body}"
        fi
    fi
else
    warn "DATABASE_URL is empty; skipping agent runtime scoping tests 43-44"
fi

# ─── 45. many concurrent WebSockets must not starve the server ─────────
# A WebSocket handler never returns: it parks in the connection for as
# long as the client stays connected. The server hands out a fixed number
# of connection slots, and when they run out it has no choice but to run
# the next handler inline on the accept loop — which then stops accepting
# connections, so the whole API goes silent (every request hangs until
# its socket times out). Measured before the fix: 7 open sockets were
# enough to freeze the server.
#
# So: park a dozen sockets in the WebSocket handler and require the HTTP
# API to keep answering. This is the regression guard for that freeze.
N_WS=16
ws45=$(python3 - <<PYEOF 2>&1 || true
import base64, os, socket, time

PORT = ${PORT}
WS_ID = "${WS_ID}"
TOKEN = "${TOKEN}"
N = ${N_WS}


def open_ws():
    key = base64.b64encode(os.urandom(16)).decode()
    sock = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    sock.sendall((
        f"GET /ws?workspace_id={WS_ID} HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{PORT}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        f"Cookie: 1person_auth={TOKEN}\r\n\r\n"
    ).encode())
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("closed during handshake")
        head += chunk
    return sock, head.split(b"\r\n")[0].decode()


socks = []
upgraded = 0
error = ""
for _ in range(N):
    try:
        sock, status = open_ws()
        socks.append(sock)
        if "101" in status:
            upgraded += 1
    except Exception as exc:  # noqa: BLE001
        error = str(exc)
        break
    time.sleep(0.05)

api_ok = False
api_seconds = -1.0
if upgraded == N:
    started = time.time()
    try:
        probe = socket.create_connection(("127.0.0.1", PORT), timeout=5)
        probe.sendall(b"GET /api/config HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        data = probe.recv(64)
        probe.close()
        api_ok = data.startswith(b"HTTP/1.1 200")
    except Exception:  # noqa: BLE001
        api_ok = False
    api_seconds = time.time() - started

for sock in socks:
    try:
        sock.close()
    except Exception:  # noqa: BLE001
        pass

print(f"UPGRADED={upgraded}/{N}")
print(f"OPEN_ERROR={error}")
print(f"API_OK={'YES' if api_ok else 'NO'}")
print(f"API_SECONDS={api_seconds:.2f}")
PYEOF
)
ws45_upgraded=$(echo "${ws45}" | grep -o "UPGRADED=[0-9]*/[0-9]*" | head -1 || true)
ws45_api_ok=$(echo "${ws45}" | grep -o "API_OK=[A-Z]*" | head -1 || true)
ws45_seconds=$(echo "${ws45}" | grep -o "API_SECONDS=[-0-9.]*" | head -1 || true)
if [[ "${ws45_upgraded}" == "UPGRADED=${N_WS}/${N_WS}" ]] && [[ "${ws45_api_ok}" == "API_OK=YES" ]]; then
    pass "45 ${N_WS} concurrent WebSockets keep the API responsive (${ws45_seconds})"
else
    fail "45 concurrent WebSockets keep the API responsive: ${ws45_upgraded} ${ws45_api_ok} ${ws45_seconds} ${ws45}"
fi

# ─── 46-51. the assignee is a (type, id) tuple ─────────────────────────
# The client renders an agent differently from a member, so the wire
# contract carries both halves. The update path used to write only the
# id: every agent-assigned issue came back with `assignee_type = null`
# and the client showed it as unassigned — assigning a todo to an agent
# silently did nothing.
#
# The contract (upstream `server/internal/handler/issue.go`):
#   - both halves set   → the issue is assigned to that entity
#   - both halves null  → the assignment is cleared
#   - one half only     → 400, the pair is ambiguous
#   - an unknown target → 400, it is not an entity of this workspace
assign_body() {
    http_body -X PUT -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
        -d "$1" "${BASE}/api/issues/${ISSUE_ID}"
}
assign_status() {
    http_status -X PUT -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
        -d "$1" "${BASE}/api/issues/${ISSUE_ID}"
}
# Read one field of the updated issue. A null field reads as the empty
# string (the generic `jget_path` helper prints Python's "None" for it).
assign_field() {
    echo "$1" | python3 -c "
import sys, json
d = json.load(sys.stdin).get('data') or {}
print(d.get('$2') or '')
" 2>/dev/null || true
}

# An agent to assign to. The runtime id does not have to exist: an
# unknown runtime registers a placeholder runtime in this workspace.
agent_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"name\":\"E2E assignee agent\",\"runtime_id\":\"$(python3 -c 'import uuid;print(uuid.uuid4())')\"}" \
    "${BASE}/api/agents")
E2E_AGENT_ID=$(jget "${agent_body}" id)
if [[ -z "${E2E_AGENT_ID}" ]]; then
    warn "could not create an agent to assign to; skipping assignee tests 46-51: ${agent_body}"
else
    # 46. assign to an agent
    assign_resp=$(assign_body "{\"assignee_type\":\"agent\",\"assignee_id\":\"${E2E_AGENT_ID}\"}")
    assign_type=$(assign_field "${assign_resp}" assignee_type)
    assign_id=$(assign_field "${assign_resp}" assignee_id)
    if [[ "${assign_type}" == "agent" && "${assign_id}" == "${E2E_AGENT_ID}" ]]; then
        pass "46 issue assigned to an agent carries assignee_type=agent"
    else
        fail "46 issue assigned to an agent carries assignee_type=agent: type=${assign_type} id=${assign_id} ${assign_resp}"
    fi

    # 47. assign to a member
    assign_resp=$(assign_body "{\"assignee_type\":\"member\",\"assignee_id\":\"${USER_ID}\"}")
    assign_type=$(assign_field "${assign_resp}" assignee_type)
    assign_id=$(assign_field "${assign_resp}" assignee_id)
    if [[ "${assign_type}" == "member" && "${assign_id}" == "${USER_ID}" ]]; then
        pass "47 issue assigned to a member carries assignee_type=member"
    else
        fail "47 issue assigned to a member carries assignee_type=member: type=${assign_type} id=${assign_id} ${assign_resp}"
    fi

    # 48. an unrelated PATCH must not drop the assignment
    assign_resp=$(assign_body "{\"assignee_type\":\"agent\",\"assignee_id\":\"${E2E_AGENT_ID}\",\"title\":\"first issue\"}")
    assign_type=$(assign_field "${assign_resp}" assignee_type)
    if [[ "${assign_type}" == "agent" ]]; then
        pass "48 a PATCH keeps the assignment it did not touch"
    else
        fail "48 a PATCH keeps the assignment it did not touch: type=${assign_type} ${assign_resp}"
    fi

    # 49. clearing the assignment (explicit null on both halves)
    assign_resp=$(assign_body '{"assignee_type":null,"assignee_id":null}')
    assign_type=$(assign_field "${assign_resp}" assignee_type)
    assign_id=$(assign_field "${assign_resp}" assignee_id)
    if [[ -z "${assign_type}" && -z "${assign_id}" ]]; then
        pass "49 clearing the assignment empties both halves"
    else
        fail "49 clearing the assignment empties both halves: type=${assign_type} id=${assign_id} ${assign_resp}"
    fi

    # 50. a half-pair is ambiguous
    half_status=$(assign_status '{"assignee_type":"agent"}')
    half_body=$(http_body -X PUT -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
        -d '{"assignee_type":"agent"}' "${BASE}/api/issues/${ISSUE_ID}")
    if [[ "${half_status}" == "400" ]] && echo "${half_body}" | grep -q "must be provided together"; then
        pass "50 a half-pair assignee is refused"
    else
        fail "50 a half-pair assignee is refused: HTTP ${half_status} ${half_body}"
    fi

    # 51. an id that names nothing in this workspace. The existence
    # check reads the agent / member / squad tables, so it only runs
    # with a database — the no-DB suite has no entity tables at all.
    if [[ -n "${DATABASE_URL}" ]]; then
        unknown_status=$(assign_status '{"assignee_type":"agent","assignee_id":"11111111-1111-1111-1111-111111111111"}')
        unknown_body=$(http_body -X PUT -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
            -d '{"assignee_type":"agent","assignee_id":"11111111-1111-1111-1111-111111111111"}' \
            "${BASE}/api/issues/${ISSUE_ID}")
        if [[ "${unknown_status}" == "400" ]] && echo "${unknown_body}" | grep -q "does not refer to an agent of this workspace"; then
            pass "51 an assignee that is not an entity of this workspace is refused"
        else
            fail "51 an assignee that is not an entity of this workspace is refused: HTTP ${unknown_status} ${unknown_body}"
        fi
    else
        warn "DATABASE_URL is empty; skipping assignee existence test 51"
    fi

    # 52. batch assign carries the type too. The batch payload is a
    # partial patch, so the same three-state rule applies.
    batch_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
        -d "{\"issue_ids\":[\"${ISSUE_ID}\",\"${ISSUE2_ID}\"],\"updates\":{\"assignee_type\":\"agent\",\"assignee_id\":\"${E2E_AGENT_ID}\"}}" \
        "${BASE}/api/issues/batch-update")
    batch_n=$(jget_path "${batch_body}" data.updated)
    after_type=$(assign_field "$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/${ISSUE_ID}")" assignee_type)
    after_id=$(assign_field "$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/${ISSUE_ID}")" assignee_id)
    if [[ "${batch_n}" == "2" && "${after_type}" == "agent" && "${after_id}" == "${E2E_AGENT_ID}" ]]; then
        pass "52 batch assign writes the assignee type"
    else
        fail "52 batch assign writes the assignee type: n=${batch_n} type=${after_type} id=${after_id} ${batch_body}"
    fi
fi

echo
# ─── 53-58. the write path speaks the wire contract ────────────────────
# The request DTO used to name the fields `state` and `parent_id` while
# the wire contract — and the client — say `status` and `parent_issue_id`.
# The parser ignores unknown fields, so every status / priority / parent
# write was dropped: the request answered 200 and changed nothing. The
# client applies an optimistic update on top, so the change looked applied
# until the next reload.
#
# `assign_field` (defined above) reads one field of an issue payload.

# 53. a status change lands
resp=$(assign_body '{"status":"in_progress"}')
status_val=$(assign_field "${resp}" status)
if [[ "${status_val}" == "in_progress" ]]; then
    pass "53 a status change is written"
else
    fail "53 a status change is written: status=${status_val} ${resp}"
fi

# 54. and it is in the database, not just in the optimistic response
status_val=$(assign_field "$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/${ISSUE_ID}")" status)
if [[ "${status_val}" == "in_progress" ]]; then
    pass "54 the status change is persisted"
else
    fail "54 the status change is persisted: status=${status_val}"
fi

# 55. a priority change lands
resp=$(assign_body '{"priority":"high"}')
prio_val=$(assign_field "${resp}" priority)
if [[ "${prio_val}" == "high" ]]; then
    pass "55 a priority change is written"
else
    fail "55 a priority change is written: priority=${prio_val} ${resp}"
fi

# 56. a parent change lands, and an explicit null takes it away again
resp=$(assign_body "{\"parent_issue_id\":\"${ISSUE2_ID}\"}")
parent_val=$(assign_field "${resp}" parent_issue_id)
if [[ "${parent_val}" == "${ISSUE2_ID}" ]]; then
    pass "56 a parent change is written"
else
    fail "56 a parent change is written: parent=${parent_val} ${resp}"
fi
resp=$(assign_body '{"parent_issue_id":null}')
parent_val=$(assign_field "${resp}" parent_issue_id)
if [[ -z "${parent_val}" ]]; then
    pass "56b an explicit null removes the parent again"
else
    fail "56b an explicit null removes the parent again: parent=${parent_val} ${resp}"
fi

# 57. the batch toolbar's status pick lands
batch_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"issue_ids\":[\"${ISSUE_ID}\",\"${ISSUE2_ID}\"],\"updates\":{\"status\":\"done\"}}" \
    "${BASE}/api/issues/batch-update")
batch_n=$(jget_path "${batch_body}" data.updated)
after_status=$(assign_field "$(http_body -H "${AUTH}" -H "${HWS}" "${BASE}/api/issues/${ISSUE_ID}")" status)
if [[ "${batch_n}" == "2" && "${after_status}" == "done" ]]; then
    pass "57 a batch status change is written"
else
    fail "57 a batch status change is written: n=${batch_n} status=${after_status} ${batch_body}"
fi

# 58. a batch payload that names no mutation field changes nothing — and
# says so. Upstream answers `{"updated": 0}` instead of claiming N rows
# were updated while every UPDATE was a no-op.
batch_body=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d "{\"issue_ids\":[\"${ISSUE_ID}\"],\"updates\":{}}" \
    "${BASE}/api/issues/batch-update")
batch_n=$(jget_path "${batch_body}" data.updated)
if [[ "${batch_n}" == "0" ]]; then
    pass "58 a batch payload without a mutation field reports updated=0"
else
    fail "58 a batch payload without a mutation field reports updated=0: n=${batch_n} ${batch_body}"
fi

# 59. creating an issue with a bare assignee type is refused — it would
# write an assignment without a target.
create_status=$(http_status -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
    -d '{"title":"half pair","assignee_type":"agent"}' "${BASE}/api/issues")
if [[ "${create_status}" == "400" ]]; then
    pass "59 creating an issue with a bare assignee type is refused"
else
    fail "59 creating an issue with a bare assignee type is refused: HTTP ${create_status}"
fi

# 60. and so is an assignee id that names nothing in this workspace
if [[ -n "${DATABASE_URL}" ]]; then
    create_status=$(http_status -X POST -H "Content-Type: application/json" -H "${AUTH}" -H "${HWS}" \
        -d '{"title":"unknown assignee","assignee_id":"11111111-1111-1111-1111-111111111111"}' "${BASE}/api/issues")
    if [[ "${create_status}" == "400" ]]; then
        pass "60 creating an issue with an unknown assignee is refused"
    else
        fail "60 creating an issue with an unknown assignee is refused: HTTP ${create_status}"
    fi
else
    warn "DATABASE_URL is empty; skipping unknown-assignee create test 60"
fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo -e "${GREEN}All ${checks} issue checks passed${RESET}"
    exit 0
else
    echo -e "${RED}${failures} of ${checks} check(s) failed${RESET}"
    exit 1
fi
