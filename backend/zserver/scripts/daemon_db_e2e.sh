#!/usr/bin/env bash
set -euo pipefail
cd /Users/n0x/w4_proj/dev_machine/1person/zserver
BASE="http://127.0.0.1:18097"
DATABASE_URL="postgres://1person:1person@localhost:5432/1person?sslmode=disable" \
  ONEPERSON_DEV_VERIFICATION_CODE=000000 JWT_SECRET=test-secret \
  ./zig-out/bin/zserver server --port 18097 > /tmp/mint-test.log 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null' EXIT
for i in $(seq 1 30); do curl -sf $BASE/health > /dev/null 2>&1 && break; sleep 0.5; done

EMAIL="mint-$(date +%s)@test.local"
curl -s -X POST -H "Content-Type: application/json" -d "{\"email\":\"$EMAIL\"}" $BASE/auth/send-code > /dev/null
TOKEN=$(curl -s -X POST -H "Content-Type: application/json" -d "{\"email\":\"$EMAIL\",\"code\":\"000000\"}" $BASE/auth/verify-code | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))")
[ -n "$TOKEN" ] && echo "PASS: login" || { echo "FAIL: login"; exit 1; }

WSLUG="mint-ws-$(date +%s)"
WS=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -d "{\"name\":\"mint-ws\",\"slug\":\"$WSLUG\"}" $BASE/api/workspaces | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")
[ -n "$WS" ] && echo "PASS: workspace created ($WS)" || { echo "FAIL: workspace"; exit 1; }

MINT=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -d "{\"workspace_id\":\"$WS\"}" $BASE/api/daemon/tokens)
DT=$(echo "$MINT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))")
[ -n "$DT" ] && echo "PASS: minted daemon token" || { echo "FAIL: mint $MINT"; exit 1; }

REG=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $DT" -d '{"runtime_id":"rt-mint-test"}' $BASE/api/daemon/register)
echo "$REG" | grep -q daemon_id && echo "PASS: daemon register with minted token" || { echo "FAIL: register $REG"; exit 1; }

HB=$(curl -s -X POST -H "Authorization: Bearer $DT" $BASE/api/daemon/heartbeat)
echo "$HB" | grep -q '"ok"' && echo "PASS: heartbeat" || { echo "FAIL: heartbeat $HB"; exit 1; }

FORGED=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -H "Authorization: Bearer 1d_deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" -d '{"runtime_id":"x"}' $BASE/api/daemon/register)
[ "$FORGED" = "401" ] && echo "PASS: forged 1d_ rejected (401)" || { echo "FAIL: forged token status=$FORGED"; exit 1; }

NONMEMBER=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -d "{\"workspace_id\":\"00000000-0000-0000-0000-000000000000\"}" $BASE/api/daemon/tokens)
echo "$NONMEMBER" | grep -q "not a workspace member" && echo "PASS: non-member mint rejected" || { echo "FAIL: nonmember $NONMEMBER"; exit 1; }

echo "ALL_MINT_TESTS_PASSED"
