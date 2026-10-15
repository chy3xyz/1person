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

# The dev snapshot this codebase is built and tested against, not the 0.17.0
# release. Two constraints, both verified:
#
#   - ziglang.org prunes dev builds once a release ships, so the previously
#     pinned `0.17.0-dev.1567+f0354179a` 404s and no job that installs this
#     toolchain can run.
#   - The 0.17.0 release changed `std.Io.net.Stream.read` to return
#     `ReadResult` instead of a tuple, and `src/cli/ws.zig` /
#     `src/modules/realtime/service.zig` still destructure the old shape, so
#     the release does not compile either.
#
# dev.2131 is the newest snapshot this tree builds clean against; keep CI on
# the same one local development uses, or CI stops verifying anything real.
ZIG_VERSION="0.17.0-dev.2131+d08989840"
PREFIX="${1:-$HOME/.local}"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)   ARCH="x86_64-linux" ;;
  Linux-aarch64)  ARCH="aarch64-linux" ;;
  Darwin-x86_64)  ARCH="x86_64-macos" ;;
  Darwin-arm64)   ARCH="aarch64-macos" ;;
  *) echo "unsupported platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

URL="https://ziglang.org/builds/zig-${ARCH}-${ZIG_VERSION}.tar.xz"
echo "==> downloading ${URL}"
mkdir -p "${PREFIX}"
curl -fsSL -o /tmp/zig.tar.xz "${URL}"
tar -xJf /tmp/zig.tar.xz -C "${PREFIX}" --strip-components=1
rm -f /tmp/zig.tar.xz
echo "==> zig ${ZIG_VERSION} installed at ${PREFIX}/zig"
"${PREFIX}/zig" version
