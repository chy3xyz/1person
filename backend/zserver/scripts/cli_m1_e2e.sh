#!/usr/bin/env bash
set -euo pipefail
cd /Users/n0x/w4_proj/dev_machine/1person/zserver
BASE="http://127.0.0.1:18093"
CFG="/tmp/1p-m1-config.json"
rm -f "$CFG"
DATABASE_URL="postgres://1person:1person@localhost:5432/1person?sslmode=disable" \
  ONEPERSON_DEV_VERIFICATION_CODE=000000 JWT_SECRET=test-secret \
  ./zig-out/bin/zserver server --port 18093 > /tmp/m1-server.log 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null' EXIT
for i in $(seq 1 30); do curl -sf $BASE/health > /dev/null 2>&1 && break; sleep 0.5; done

EMAIL="m1-$(date +%s)@test.local"
echo "== [1] 1p login =="
./zig-out/bin/1p login --server_url "$BASE" --email "$EMAIL" --code 000000 --path "$CFG"
grep -q '"token"' "$CFG" && echo "PASS: token stored in config" || { echo "FAIL: no token in config"; cat "$CFG"; exit 1; }

echo "== [2] workspace via API =="
TOKEN=$(python3 -c "import json; print(json.load(open('$CFG'))['token'])")
SLUG="m1-ws-$(date +%s)"
WS=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -d "{\"name\":\"m1-ws\",\"slug\":\"$SLUG\"}" $BASE/api/workspaces | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")
[ -n "$WS" ] && echo "PASS: workspace $WS" || { echo "FAIL: workspace"; exit 1; }

echo "== [3] 1p pair =="
./zig-out/bin/1p pair --workspace_id "$WS" --path "$CFG"
python3 -c "import json; c=json.load(open('$CFG')); assert len(c['daemon_tokens'])==1, c" && echo "PASS: daemon token stored"

echo "== [4] minted token works for daemon register =="
DT=$(python3 -c "import json; c=json.load(open('$CFG')); print(c['daemon_tokens'][0]['token'])")
REG=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $DT" -d '{"runtime_id":"rt-m1"}' $BASE/api/daemon/register)
echo "$REG" | grep -q daemon_id && echo "PASS: daemon registered with 1p-minted token" || { echo "FAIL: register $REG"; exit 1; }

echo "== [5] config perms =="
PERMS=$(stat -f "%Lp" "$CFG")
[ "$PERMS" = "600" ] && echo "PASS: config perms $PERMS" || { echo "FAIL: perms $PERMS"; exit 1; }

echo "== [6] 1p config summary =="
./zig-out/bin/1p config --path "$CFG"
echo "ALL_M1_TESTS_PASSED"
