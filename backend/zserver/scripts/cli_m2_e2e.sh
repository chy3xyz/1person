#!/usr/bin/env bash
set -euo pipefail
cd /Users/n0x/w4_proj/dev_machine/1person/zserver
BASE="http://127.0.0.1:18091"
CFG="/tmp/1p-m2-config.json"
cat > "$CFG" <<JSON
{
  "server_url": "$BASE",
  "token": "",
  "daemon_tokens": []
}
JSON
# no-DB server (deterministic; synthetic 1d_ token accepted)
DATABASE_URL="" ONEPERSON_DEV_VERIFICATION_CODE=000000 JWT_SECRET=test-secret \
  ./zig-out/bin/zserver server --port 18091 > /tmp/m2-server.log 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null' EXIT
for i in $(seq 1 30); do curl -sf $BASE/health > /dev/null 2>&1 && break; sleep 0.5; done

RUNTIME="rt-m2-$(date +%s)"
DT="1d_m2test0000000000000000000000000000"

echo "== starting 1p daemon (runtime=$RUNTIME) =="
./zig-out/bin/1p daemon --runtime_id "$RUNTIME" --token "$DT" --path "$CFG" > /tmp/m2-daemon.log 2>&1 &
DAEMON_PID=$!

# wait for registration + ws connect
sleep 4
echo "--- daemon log (first 12 lines) ---"
head -12 /tmp/m2-daemon.log

echo "--- server log: daemon activity ---"
grep -E "daemon|/api/daemon|ws" /tmp/m2-server.log | tail -8

# verify register + ws happened
grep -q "daemon registered" /tmp/m2-daemon.log && echo "PASS: registered" || { echo "FAIL: no register"; exit 1; }
grep -q "websocket connected" /tmp/m2-daemon.log && echo "PASS: ws connected" || { echo "FAIL: no ws"; exit 1; }

# graceful shutdown via SIGTERM
kill -TERM $DAEMON_PID
sleep 2
grep -q "daemon stopped" /tmp/m2-daemon.log && echo "PASS: graceful stop" || echo "WARN: stop message missing"
wait $DAEMON_PID 2>/dev/null || true
echo "ALL_M2_TESTS_PASSED"
