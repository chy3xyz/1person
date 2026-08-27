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

ZIG_VERSION="0.17.0-dev.1567+f0354179a"
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
