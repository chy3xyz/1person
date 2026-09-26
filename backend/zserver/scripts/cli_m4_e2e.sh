#!/usr/bin/env bash
set -euo pipefail
cd /Users/n0x/w4_proj/dev_machine/1person/zserver
BASE="http://127.0.0.1:18086"
CFG="/tmp/1p-m4-config.json"
rm -f "$CFG"
DATABASE_URL="postgres://1person:1person@localhost:5432/1person?sslmode=disable" \
  ONEPERSON_DEV_VERIFICATION_CODE=000000 JWT_SECRET=test-secret \
  ./zig-out/bin/zserver server --port 18086 > /tmp/m4-server.log 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null' EXIT
for i in $(seq 1 30); do curl -sf $BASE/health > /dev/null 2>&1 && break; sleep 0.5; done

echo "== [1] setup =="
./zig-out/bin/1p login --server_url "$BASE" --email "m4-$(date +%s)@test.local" --code 000000 --path "$CFG" > /dev/null
TOKEN=$(python3 -c "import json; print(json.load(open('$CFG'))['token'])")
SLUG="m4-ws-$(date +%s)"
WS=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -d "{\"name\":\"m4-ws\",\"slug\":\"$SLUG\"}" $BASE/api/workspaces | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")
RUNTIME=$(uuidgen | tr 'A-Z' 'a-z')
curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -H "X-Workspace-ID: $WS" -d "{\"name\":\"m4-agent\",\"runtime_id\":\"$RUNTIME\"}" $BASE/api/agents > /dev/null
./zig-out/bin/1p pair --workspace_id "$WS" --path "$CFG" > /dev/null
./zig-out/bin/1p daemon --runtime_id "$RUNTIME" --workspace_id "$WS" --path "$CFG" --claim_ms 2000 --heartbeat_ms 5000 > /tmp/m4-daemon.log 2>&1 &
DAEMON_PID=$!
sleep 3
grep -q "daemon registered" /tmp/m4-daemon.log && echo "PASS: setup (daemon registered)" || { echo "FAIL: setup"; exit 1; }

echo "== [2] models task -> real exec + result report =="
REQ=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -H "X-Workspace-ID: $WS" $BASE/api/runtimes/$RUNTIME/models)
REQ_ID=$(echo "$REQ" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")
sleep 5
grep -q "models: no local model runtime" /tmp/m4-daemon.log && echo "PASS: daemon executed models task" || { echo "FAIL: models exec"; cat /tmp/m4-daemon.log; exit 1; }
ST=$(curl -s -H "Authorization: Bearer $TOKEN" -H "X-Workspace-ID: $WS" $BASE/api/runtimes/$RUNTIME/models/$REQ_ID)
echo "$ST" | grep -q '"status":"completed"' && echo "PASS: models request completed" || { echo "FAIL: models status $ST"; exit 1; }

echo "== [3] update task -> version check result =="
UPD=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -H "X-Workspace-ID: $WS" -d '{"target_version":"9.9.9"}' $BASE/api/runtimes/$RUNTIME/update)
UPD_ID=$(echo "$UPD" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")
sleep 5
grep -q "update: local 1p" /tmp/m4-daemon.log && echo "PASS: daemon executed update task" || { echo "FAIL: update exec"; exit 1; }
UST=$(curl -s -H "Authorization: Bearer $TOKEN" -H "X-Workspace-ID: $WS" $BASE/api/runtimes/$RUNTIME/update/$UPD_ID)
echo "$UST" | grep -q '"status":"completed"' && echo "PASS: update request completed" || { echo "FAIL: update status $UST"; exit 1; }

echo "== [4] read-only commands =="
./zig-out/bin/1p workspaces --path "$CFG" | grep -q "m4-ws" && echo "PASS: 1p workspaces" || { echo "FAIL: workspaces"; exit 1; }
./zig-out/bin/1p agents --workspace_id "$WS" --path "$CFG" | grep -q "m4-agent" && echo "PASS: 1p agents" || { echo "FAIL: agents"; exit 1; }
./zig-out/bin/1p issues --workspace_id "$WS" --path "$CFG" > /tmp/m4-issues.log 2>&1 && echo "PASS: 1p issues (runs)" || { echo "FAIL: issues"; cat /tmp/m4-issues.log; exit 1; }

kill -TERM $DAEMON_PID 2>/dev/null; sleep 1; wait $DAEMON_PID 2>/dev/null || true
echo "--- daemon execution log ---"
grep -E "CLAIMED|executing|models:|update:|local_skills:|completed" /tmp/m4-daemon.log
echo "ALL_M4_TESTS_PASSED"
