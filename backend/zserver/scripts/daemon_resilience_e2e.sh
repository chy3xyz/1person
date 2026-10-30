#!/usr/bin/env bash
# Daemon resilience: the local agent worker must survive a server outage.
#
# Before the fix, `claimPoll` used a bare `try` on the HTTP request, so a
# server that went away (restart, crash, reboot) turned into a
# `ConnectionRefused` that propagated out of `run()` and killed the
# process. Every server restart silently killed the daemon, and the
# runtime stayed offline until somebody noticed and restarted it by hand.
# The same applied to the initial registration: a daemon started before
# the server was up died immediately instead of waiting for it.
#
# The script walks the whole lifecycle:
#   1. start the daemon against a port with nothing on it  → stays alive
#   2. start the server                                   → registers
#   3. kill the server                                    → stays alive
#   4. start the server again                             → reconnects
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=18093
BASE="http://localhost:$PORT"
CFG="/tmp/1p-resilience-config.json"
SERVER_LOG="/tmp/daemon-resilience-server.log"
DAEMON_LOG="/tmp/daemon-resilience-daemon.log"
RUNTIME="rt-resilience-$$"
DT="1d_resilience000000000000000000000000"

fail() {
  echo "FAIL: $1"
  [ -f "$DAEMON_LOG" ] && { echo "--- daemon log ---"; cat "$DAEMON_LOG"; }
  exit 1
}

cleanup() {
  [ -n "${DAEMON_PID:-}" ] && kill -TERM "$DAEMON_PID" 2>/dev/null || true
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT

# A crashed child stays behind as a zombie until it is reaped, and
# `kill -0` succeeds for a zombie — so the process state has to be
# inspected to tell "still running" from "already dead".
daemon_alive() {
  kill -0 "$DAEMON_PID" 2>/dev/null || return 1
  case "$(ps -o stat= -p "$DAEMON_PID" 2>/dev/null)" in
    Z*) return 1 ;;
    *) return 0 ;;
  esac
}

# Wait until the log contains a pattern (or time out).
wait_for_log() {
  local pattern="$1" tries="$2" i
  for i in $(seq 1 "$tries"); do
    grep -q "$pattern" "$DAEMON_LOG" && return 0
    sleep 1
  done
  return 1
}

start_server() {
  for attempt in 1 2 3; do
    DATABASE_URL="" ONEPERSON_DEV_VERIFICATION_CODE=000000 JWT_SECRET=test-secret \
      ./zig-out/bin/zserver server --port $PORT >> "$SERVER_LOG" 2>&1 &
    SERVER_PID=$!
    for _ in $(seq 1 40); do
      if curl -sf "$BASE/health" >/dev/null 2>&1; then return 0; fi
      # The server may have died on a bind conflict (TIME_WAIT after the
      # previous instance was killed) — try again.
      if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
      sleep 0.5
    done
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
    sleep 1
  done
  return 1
}

cat > "$CFG" <<JSON
{
  "server_url": "$BASE",
  "token": "",
  "daemon_tokens": []
}
JSON
: > "$SERVER_LOG"
: > "$DAEMON_LOG"

echo "== starting the daemon against a port with no server on it =="
# Short claim/heartbeat cadences, so several attempts land inside the
# outage windows and the test stays quick.
./zig-out/bin/1p daemon --runtime_id "$RUNTIME" --token "$DT" --path "$CFG" \
  --claim_ms 2000 --heartbeat_ms 2000 > "$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

sleep 4
daemon_alive || fail "daemon exited instead of waiting for the server"
grep -q "register failed" "$DAEMON_LOG" || fail "daemon did not report the unreachable server"
echo "PASS: daemon waited for the server instead of exiting"

echo "== starting the server =="
start_server || fail "server did not come up"
wait_for_log "daemon registered" 30 || fail "daemon did not register once the server was up"
grep -q "websocket connected" "$DAEMON_LOG" || fail "daemon did not connect the websocket"
echo "PASS: daemon registered and connected"

echo "== killing the server (simulating a restart) =="
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

# The claim poll fires every 2s, so the outage has to outlive several
# attempts: before the fix, the first one took the process down.
sleep 8

daemon_alive || fail "daemon exited when the server went away"
grep -q "server unreachable" "$DAEMON_LOG" || fail "daemon did not report the outage"
echo "PASS: daemon survived the outage"

echo "== restarting the server =="
start_server || fail "server did not come back"

# The WebSocket reconnect uses an exponential backoff (1s, 2s, 4s, ...),
# so give it room to notice that the server is back.
for _ in $(seq 1 40); do
  [ "$(grep -c 'websocket connected' "$DAEMON_LOG")" -ge 2 ] && break
  sleep 1
done
[ "$(grep -c 'websocket connected' "$DAEMON_LOG")" -ge 2 ] \
  || fail "daemon did not reconnect after the server came back"
echo "PASS: daemon reconnected"

kill -TERM "$DAEMON_PID" 2>/dev/null || true
sleep 2
wait "$DAEMON_PID" 2>/dev/null || true
DAEMON_PID=""

echo "ALL_RESILIENCE_TESTS_PASSED"
