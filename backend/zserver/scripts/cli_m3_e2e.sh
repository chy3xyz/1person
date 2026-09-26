#!/usr/bin/env bash
set -euo pipefail
cd /Users/n0x/w4_proj/dev_machine/1person/zserver
BASE="http://127.0.0.1:18088"
CFG="/tmp/1p-m3-config.json"
rm -f "$CFG"
DATABASE_URL="postgres://1person:1person@localhost:5432/1person?sslmode=disable" \
  ONEPERSON_DEV_VERIFICATION_CODE=000000 JWT_SECRET=test-secret \
  ./zig-out/bin/zserver server --port 18088 > /tmp/m3-server.log 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null' EXIT
for i in $(seq 1 30); do curl -sf $BASE/health > /dev/null 2>&1 && break; sleep 0.5; done

echo "== [1] login =="
./zig-out/bin/1p login --server_url "$BASE" --email "m3-$(date +%s)@test.local" --code 000000 --path "$CFG"
TOKEN=$(python3 -c "import json; print(json.load(open('$CFG'))['token'])")
echo "PASS: login"

echo "== [2] workspace + agent(runtime) =="
SLUG="m3-ws-$(date +%s)"
WS=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -d "{\"name\":\"m3-ws\",\"slug\":\"$SLUG\"}" $BASE/api/workspaces | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")
[ -n "$WS" ] || { echo "FAIL: workspace"; exit 1; }
RUNTIME=$(uuidgen | tr 'A-Z' 'a-z')
AGENT=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -H "X-Workspace-ID: $WS" -d "{\"name\":\"m3-agent\",\"runtime_id\":\"$RUNTIME\"}" $BASE/api/agents)
echo "$AGENT" | grep -q '"id"' && echo "PASS: agent created (runtime=$RUNTIME)" || { echo "FAIL: agent $AGENT"; exit 1; }

echo "== [3] pair =="
./zig-out/bin/1p pair --workspace_id "$WS" --path "$CFG" > /dev/null
echo "PASS: paired"

echo "== [4] start daemon =="
./zig-out/bin/1p daemon --runtime_id "$RUNTIME" --workspace_id "$WS" --path "$CFG" --claim_ms 2000 --heartbeat_ms 5000 > /tmp/m3-daemon.log 2>&1 &
DAEMON_PID=$!
sleep 3
grep -q "daemon registered" /tmp/m3-daemon.log && echo "PASS: daemon registered" || { echo "FAIL: daemon"; exit 1; }

echo "== [5] enqueue models task =="
MODELS=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -H "X-Workspace-ID: $WS" $BASE/api/runtimes/$RUNTIME/models)
echo "$MODELS" | grep -q '"status":"pending"' && echo "PASS: models task enqueued" || { echo "FAIL: models $MODELS"; exit 1; }

echo "== [6] wait for claim+execute =="
sleep 6
grep -q "CLAIMED task" /tmp/m3-daemon.log && echo "PASS: task claimed" || { echo "FAIL: no claim"; cat /tmp/m3-daemon.log; exit 1; }
grep -q "task .* completed" /tmp/m3-daemon.log && echo "PASS: task executed+completed" || { echo "FAIL: no completion"; cat /tmp/m3-daemon.log; exit 1; }

echo "== [7] task completion =="
DT=$(python3 -c "import json; c=json.load(open('$CFG')); print(c['daemon_tokens'][0]['token'])")
TASK_ID=$(grep -oE 'CLAIMED task id=[0-9a-f]+' /tmp/m3-daemon.log | head -1 | sed 's/CLAIMED task id=//')
grep -q "task .* completed" /tmp/m3-daemon.log && echo "PASS: task completed in daemon log" || { echo "FAIL: no completion"; exit 1; }


kill -TERM $DAEMON_PID 2>/dev/null; sleep 1; wait $DAEMON_PID 2>/dev/null || true
echo "--- daemon execution log ---"
grep -E "CLAIMED|executing|progress|completed" /tmp/m3-daemon.log
echo "ALL_M3_TESTS_PASSED"
