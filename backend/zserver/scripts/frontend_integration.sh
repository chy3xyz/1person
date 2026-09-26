#!/usr/bin/env bash
# Frontend integration smoke test for zserver.
#
# Boots a fresh zserver (no-DB mode) and runs a Node.js script
# (`integration.mjs`) that exercises the same HTTP call patterns
# the Next.js frontend uses (see packages/core/api/client.ts).
# This is the zserver equivalent of running apps/web against the
# Go server: every code path the script walks is the one the real
# frontend would walk.
#
# Usage:
#   ONEPERSON_DEV_VERIFICATION_CODE=000000 \
#   JWT_SECRET=test-secret \
#   ./scripts/frontend_integration.sh
#
# Override the port with PORT=<n>.

set -euo pipefail

PORT="${PORT:-18099}"
BASE="http://127.0.0.1:${PORT}"
JWT_SECRET="${JWT_SECRET:-test-secret}"
export JWT_SECRET

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> building zserver"
( cd "${SCRIPT_DIR}/.." && zig build ) || { echo "build failed"; exit 1; }

echo "==> starting zserver on port ${PORT}"
"${SCRIPT_DIR}/../zig-out/bin/zserver" server --port "${PORT}" >/tmp/zserver-frontend-integration.log 2>&1 &
SERVER_PID=$!

cleanup() {
    echo "==> stopping zserver"
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for i in $(seq 1 30); do
    if [[ $(curl -s -o /dev/null -w "%{http_code}" "${BASE}/health") == "200" ]]; then break; fi
    sleep 0.5
done
if [[ $(curl -s -o /dev/null -w "%{http_code}" "${BASE}/health") != "200" ]]; then
    echo "zserver never came up; tail of log:"
    tail -50 /tmp/zserver-frontend-integration.log
    exit 1
fi

echo "==> running frontend integration script"
ONEPERSON_DEV_VERIFICATION_CODE="${ONEPERSON_DEV_VERIFICATION_CODE:-000000}" \
node "${SCRIPT_DIR}/integration.mjs" "${BASE}"
