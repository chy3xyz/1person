#!/usr/bin/env bash
# Provision the pinned zfinal + zcli checkouts into <repo>/zig_ws/.
#
# zserver's build.zig.zon resolves both framework deps relative to the
# repo (zserver/../zig_ws), so the build is reproducible from a clean
# checkout at any depth. This script is what makes that true:
#
#   bash zserver/scripts/provision-zig-deps.sh
#
# - zfinal @ ${ZFINAL_REF} (v0.24.0) — HTTP framework + DB pool
# - zcli  @ ${ZCLI_REF}   — CLI parsing used by src/main.zig
#
# Idempotent: skips any checkout that already has a .git dir. Run it
# before the first zig build on a fresh checkout (CI workflows do).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ZIG_WS="${REPO_ROOT}/zig_ws"

# Pinned commits — bump deliberately, then update this file and re-run.
ZFINAL_REF="6f5e08c5cc484c05b9b2aae5221b19f39b8b342a"  # v0.24.0
ZCLI_REF="3c466eeb4c5c4644e2f96db124235e3e79fd04d5"    # v0.2.0-2

clone_pin() {
  local name="$1" url="$2" ref="$3"
  local dir="${ZIG_WS}/${name}"
  if [ -d "${dir}/.git" ]; then
    echo "==> ${name}: already present at ${dir}"
    return
  fi
  echo "==> cloning ${name} @ ${ref}"
  git clone --quiet "${url}" "${dir}"
  git -C "${dir}" checkout --quiet "${ref}"
  echo "==> ${name} pinned at $(git -C "${dir}" rev-parse --short HEAD)"
}

mkdir -p "${ZIG_WS}"
clone_pin zfinal https://github.com/chy3xyz/zfinal.git "${ZFINAL_REF}"
clone_pin zcli https://github.com/chy3xyz/zcli.git "${ZCLI_REF}"
echo "==> zig deps ready under ${ZIG_WS}"
