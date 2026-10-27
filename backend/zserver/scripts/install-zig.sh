#!/usr/bin/env bash
# Install the pinned Zig toolchain straight from the official ziglang.org
# builds (no third-party version manager). Used by the Dockerfile, CI
# workflows, and local dev — one source of truth for the Zig pin.
#
# Usage: bash zserver/scripts/install-zig.sh [prefix]   (default: ~/.local)
#
# Installs the compiler into <prefix> (zig binary at <prefix>/zig) and
# prints the version.
set -euo pipefail

# The Zig release this codebase is built and tested against, not a
# 0.17.0-dev snapshot. Two constraints, both verified:
#
#   - ziglang.org prunes dev builds once a release ships. Every 0.17.0-dev
#     snapshot this project pinned (dev.1567, then dev.2131) has since been
#     deleted, so a pinned snapshot eventually 404s and takes down every job
#     that installs this toolchain. Release tarballs are kept forever.
#   - The 0.17.0 release changed the `net_read` payload from a plain byte
#     count to a `ReadResult` struct, and `std.Io.net.Stream.read` in the
#     release still destructures the old tuple shape — so the release needs
#     the two call sites in this tree adapted (src/cli/ws.zig and
#     src/modules/realtime/service.zig).
#
# The release also matches the `minimum_zig_version` in build.zig.zon and
# zfinal v0.28.1+, which adapted to it.
ZIG_VERSION="0.17.0"
PREFIX="${1:-$HOME/.local}"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)   ARCH="x86_64-linux" ;;
  Linux-aarch64)  ARCH="aarch64-linux" ;;
  Darwin-x86_64)  ARCH="x86_64-macos" ;;
  Darwin-arm64)   ARCH="aarch64-macos" ;;
  *) echo "unsupported platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

# Release tarballs live under download/<version>/; dev snapshots under builds/.
case "${ZIG_VERSION}" in
  *-dev.*) URL="https://ziglang.org/builds/zig-${ARCH}-${ZIG_VERSION}.tar.xz" ;;
  *)      URL="https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-${ZIG_VERSION}.tar.xz" ;;
esac

echo "==> downloading ${URL}"
mkdir -p "${PREFIX}"
curl -fsSL -o /tmp/zig.tar.xz "${URL}"
tar -xJf /tmp/zig.tar.xz -C "${PREFIX}" --strip-components=1
rm -f /tmp/zig.tar.xz
echo "==> zig ${ZIG_VERSION} installed at ${PREFIX}/zig"
"${PREFIX}/zig" version
