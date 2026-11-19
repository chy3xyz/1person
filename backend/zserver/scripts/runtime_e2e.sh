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
#   ONEPERSON_DEV_VERIFICATION_CODE=000000 JWT_SECRET=test-secret \
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
code="${ONEPERSON_DEV_VERIFICATION_CODE:-000000}"
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

        # 3d. a runtime whose daemon died is marked offline by the sweeper.
        # The daemon writes a heartbeat on every round; a runtime whose
        # heartbeat went stale belongs to a daemon that is gone. Without
        # the sweeper the row would claim to be online forever, and the UI
        # would queue work that no daemon ever picks up.
        STALE_ID=$(psql "${DATABASE_URL}" -tAc "INSERT INTO agent_runtime (workspace_id, owner_id, name, runtime_mode, provider, status, last_seen_at) VALUES ('${WS_ID}'::uuid, '${USER_ID}'::uuid, 'rt-e2e-stale', 'local', 'local', 'online', now() - interval '1 hour') RETURNING id" 2>/dev/null | head -1 || echo "")
        if [[ -z "${STALE_ID}" ]]; then
            warn "could not insert the stale runtime; skipping the sweeper check"
        else
            # The sweeper runs every 30s; give it two rounds to be sure.
            SWEPT=""
            for _ in $(seq 1 30); do
                sleep 2
                ST=$(psql "${DATABASE_URL}" -tAc "SELECT status FROM agent_runtime WHERE id = '${STALE_ID}'::uuid" 2>/dev/null | head -1)
                if [[ "${ST}" == "offline" ]]; then SWEPT="yes"; break; fi
            done
            if [[ "${SWEPT}" == "yes" ]]; then
                pass "06 a stale runtime is marked offline by the sweeper"
            else
                fail "06 a stale runtime is marked offline by the sweeper (status=${ST:-unknown})"
            fi
            psql "${DATABASE_URL}" -tAc "DELETE FROM agent_runtime WHERE id = '${STALE_ID}'::uuid" >/dev/null 2>&1 || true
        fi

        # 3e. the daemon lifecycle: register → heartbeat → deregister.
        # The in-memory daemon registry is keyed by the identity the
        # daemon's token carries, because that is the id the heartbeat
        # and the deregister look the daemon up by. A registry keyed by
        # anything else is a registry nobody finds: the heartbeat stamps
        # nothing and a graceful shutdown leaves the runtime "online".
        MINT=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
            -d "{\"workspace_id\":\"${WS_ID}\",\"ttl_days\":1}" "${BASE}/api/daemon/tokens")
        DTOKEN=$(jget "${MINT}" token)
        if [[ -z "${DTOKEN}" ]]; then
            warn "could not mint a daemon token; skipping the daemon lifecycle check"
        else
            DRT_ID="77777777-2222-3333-4444-555555555555"
            REG=$(http_body -X POST -H "Content-Type: application/json" -H "Authorization: Bearer ${DTOKEN}" \
                -d "{\"runtime_id\":\"${DRT_ID}\",\"name\":\"rt-e2e-daemon\",\"cli_version\":\"0.0.1\",\"capabilities\":[\"agent_tasks\"]}" \
                "${BASE}/api/daemon/register")
            if [[ -n "$(jget "${REG}" daemon_id)" ]]; then
                pass "07 daemon register (200)"
            else
                fail "07 daemon register: ${REG}"
            fi

            # The heartbeat has to reach the row: liveness is decided by
            # the age of agent_runtime.last_seen_at. The registration
            # stamped it too, so clear it first — otherwise this check
            # would pass even if the heartbeat stamped nothing.
            psql "${DATABASE_URL}" -tAc "UPDATE agent_runtime SET last_seen_at = NULL WHERE id = '${DRT_ID}'::uuid" >/dev/null 2>&1 || true
            HB=$(http_status -X POST -H "Authorization: Bearer ${DTOKEN}" "${BASE}/api/daemon/heartbeat")
            if [[ "${HB}" == "200" ]]; then
                pass "08 daemon heartbeat (200)"
            else
                fail "08 daemon heartbeat (${HB})"
            fi

            SEEN=$(psql "${DATABASE_URL}" -tAc "SELECT (last_seen_at IS NOT NULL)::text FROM agent_runtime WHERE id = '${DRT_ID}'::uuid" 2>/dev/null | head -1)
            if [[ "${SEEN}" == "t" || "${SEEN}" == "true" ]]; then
                pass "09 the heartbeat reached the runtime row"
            else
                fail "09 the heartbeat reached the runtime row (last_seen_at=${SEEN:-null})"
            fi

            DG=$(http_status -X POST -H "Authorization: Bearer ${DTOKEN}" "${BASE}/api/daemon/deregister")
            if [[ "${DG}" == "200" || "${DG}" == "204" ]]; then
                pass "10 daemon deregister (${DG})"
            else
                fail "10 daemon deregister (${DG})"
            fi

            RST=$(psql "${DATABASE_URL}" -tAc "SELECT status FROM agent_runtime WHERE id = '${DRT_ID}'::uuid" 2>/dev/null | head -1)
            if [[ "${RST}" == "offline" ]]; then
                pass "11 a deregistered daemon leaves its runtime offline"
            else
                fail "11 a deregistered daemon leaves its runtime offline (status=${RST:-unknown})"
            fi

            # 12. The heartbeat has to bring a dead-looking runtime back.
            # The sweeper marks a runtime whose heartbeat went stale as
            # offline, and the daemon that outlives that window — a
            # laptop that was asleep, a network that was partitioned — has
            # to be able to report in again. The body names the runtime
            # (upstream's `DaemonHeartbeatRequest.RuntimeID`), so the beat
            # still lands after the deregister dropped the registry
            # entry: the server must not depend on its own memory to find
            # the row.
            psql "${DATABASE_URL}" -tAc "UPDATE agent_runtime SET status = 'offline', last_seen_at = now() - interval '1 hour' WHERE id = '${DRT_ID}'::uuid" >/dev/null 2>&1 || true
            HB2=$(http_status -X POST -H "Content-Type: application/json" -H "Authorization: Bearer ${DTOKEN}" \
                -d "{\"runtime_id\":\"${DRT_ID}\"}" "${BASE}/api/daemon/heartbeat")
            RST2=$(psql "${DATABASE_URL}" -tAc "SELECT status FROM agent_runtime WHERE id = '${DRT_ID}'::uuid" 2>/dev/null | head -1)
            if [[ "${HB2}" == "200" && "${RST2}" == "online" ]]; then
                pass "12 a heartbeat brings a stale runtime back online (${HB2})"
            else
                fail "12 a heartbeat brings a stale runtime back online (http=${HB2}, status=${RST2:-unknown})"
            fi

            # 13. A daemon token is bound to one workspace and must not be
            # able to keep another workspace's runtime alive.
            WS2_BODY=$(http_body -X POST -H "Content-Type: application/json" -H "${AUTH}" \
                -d "{\"name\":\"E2E2\",\"slug\":\"rt2-$(date +%s)\"}" "${BASE}/api/workspaces")
            WS2_ID=$(jget "${WS2_BODY}" id)
            if [[ -z "${WS2_ID}" ]]; then
                warn "could not create the second workspace; skipping the cross-workspace check"
            else
                RID2=$(psql "${DATABASE_URL}" -tAc "INSERT INTO agent_runtime (workspace_id, owner_id, name, runtime_mode, provider, status, last_seen_at) VALUES ('${WS2_ID}'::uuid, '${USER_ID}'::uuid, 'rt-e2e-other', 'local', 'local', 'online', now() - interval '1 hour') RETURNING id" 2>/dev/null | head -1 || echo "")
                if [[ -z "${RID2}" ]]; then
                    warn "could not insert the foreign runtime; skipping the cross-workspace check"
                else
                    HBX=$(http_status -X POST -H "Content-Type: application/json" -H "Authorization: Bearer ${DTOKEN}" \
                        -d "{\"runtime_id\":\"${RID2}\"}" "${BASE}/api/daemon/heartbeat")
                    if [[ "${HBX}" == "400" ]]; then
                        pass "13 a heartbeat for another workspace's runtime is refused (${HBX})"
                    else
                        fail "13 a heartbeat for another workspace's runtime is refused (expected 400, got ${HBX})"
                    fi
                    psql "${DATABASE_URL}" -tAc "DELETE FROM agent_runtime WHERE id = '${RID2}'::uuid" >/dev/null 2>&1 || true
                fi
                http_status -X DELETE -H "${AUTH}" "${BASE}/api/workspaces/${WS2_ID}" >/dev/null 2>&1 || true
            fi
            psql "${DATABASE_URL}" -tAc "DELETE FROM agent_runtime WHERE id = '${DRT_ID}'::uuid" >/dev/null 2>&1 || true

            # 14. The sweeper has to tell the clients. A status that
            # changed in the database but never reaches the UI leaves the
            # workspace showing a machine that is gone — the frontend
            # invalidates the runtime queries on a `daemon:*` event, so
            # the sweeper has to publish one.
            ws14=$(python3 -c "import websocket" 2>/dev/null && echo "ok" || echo "missing")
            if [[ "${ws14}" != "ok" ]]; then
                warn "websocket-client not installed; skipping the sweeper event check"
            else
                WS_STALE_ID=$(psql "${DATABASE_URL}" -tAc "INSERT INTO agent_runtime (workspace_id, owner_id, name, runtime_mode, provider, status, last_seen_at) VALUES ('${WS_ID}'::uuid, '${USER_ID}'::uuid, 'rt-e2e-swept', 'local', 'local', 'online', now() - interval '1 hour') RETURNING id" 2>/dev/null | head -1 || echo "")
                if [[ -z "${WS_STALE_ID}" ]]; then
                    warn "could not insert the stale runtime; skipping the sweeper event check"
                else
                    ws_out=$(python3 - <<PYEOF 2>&1 || true
import threading, time
import websocket
WS = "ws://127.0.0.1:${PORT}/ws?workspace_id=${WS_ID}&token=${TOKEN}"
hit = threading.Event()
def on_msg(ws, msg):
    if '"type":"daemon:status_changed"' in msg:
        hit.set()
def on_err(ws, e):
    pass
def on_close(ws, *a):
    pass
wsa = websocket.WebSocketApp(WS, on_message=on_msg, on_error=on_err, on_close=on_close)
t = threading.Thread(target=wsa.run_forever, daemon=True); t.start()
time.sleep(0.8)
# The sweeper runs every 30s; give it two rounds.
hit.wait(timeout=70)
print("SWEEP_EVENT=" + ("HIT" if hit.is_set() else "MISS"))
wsa.close()
PYEOF
)
                    if echo "${ws_out}" | grep -q "SWEEP_EVENT=HIT"; then
                        pass "14 the sweeper tells the workspace that a runtime went offline"
                    else
                        fail "14 the sweeper tells the workspace that a runtime went offline: ${ws_out}"
                    fi
                    psql "${DATABASE_URL}" -tAc "DELETE FROM agent_runtime WHERE id = '${WS_STALE_ID}'::uuid" >/dev/null 2>&1 || true
                fi
            fi
        fi
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
