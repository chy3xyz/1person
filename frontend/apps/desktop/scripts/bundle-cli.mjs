#!/usr/bin/env node
// Builds the Zig `1p` CLI from backend/zserver and copies the binary into
// frontend/apps/desktop/resources/bin/ as `1person` (+ `.exe` on Windows) so
// electron-vite (dev) and electron-builder (prod) pick it up. Running this on
// every dev/build/package invocation keeps the bundled CLI in step with the
// Zig source.
//
// The build is host-only: `zig build` produces a binary for the machine it
// runs on. When package.mjs asks for a different target platform/arch, we log
// that and skip the bundle — the desktop app then falls back to auto-installing
// the matching CLI at runtime.
//
// Graceful: if `zig` is not installed (e.g. frontend-only contributor), we skip
// the build and fall through to auto-install at runtime. A genuine Zig compile
// error is fatal — you want that to block dev, not hide.

import { access, chmod, copyFile, mkdir } from "node:fs/promises";
import { constants } from "node:fs";
import { execSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
// here = frontend/apps/desktop/scripts → repo root lives four levels up.
const repoRoot = resolve(here, "..", "..", "..", "..");
const zserverDir = join(repoRoot, "backend", "zserver");
const destDir = join(here, "..", "resources", "bin");

function argValue(argv, flag) {
  const index = argv.indexOf(flag);
  return index === -1 ? null : (argv[index + 1] ?? "");
}

const targetPlatform = argValue(process.argv.slice(2), "--target-platform");
const targetArch = argValue(process.argv.slice(2), "--target-arch");

async function exists(path) {
  try {
    await access(path, constants.F_OK);
    return true;
  } catch {
    return false;
  }
}

function hasZig() {
  try {
    execSync("zig version", { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

// `zig build` only produces a binary for the host. Cross-target packaging still
// bundles the Electron app; the CLI is installed at runtime on first launch.
if (
  (targetPlatform && targetPlatform !== process.platform) ||
  (targetArch && targetArch !== process.arch)
) {
  console.warn(
    `[bundle-cli] skipping CLI bundle for ${targetPlatform ?? process.platform}/` +
      `${targetArch ?? process.arch} (host is ${process.platform}/${process.arch}). ` +
      "Desktop will auto-install the matching CLI at runtime.",
  );
  process.exit(0);
}

const exeSuffix = process.platform === "win32" ? ".exe" : "";
const binName = `1person${exeSuffix}`;
const destBinary = join(destDir, binName);
const zigSrcBin = join(zserverDir, "zig-out", "bin", `1p${exeSuffix}`);

if (!hasZig()) {
  console.warn(
    "[bundle-cli] `zig` not found in PATH — skipping CLI bundle. " +
      "Desktop will use whatever is already in resources/bin/, or fall back " +
      "to auto-installing the latest release at runtime.",
  );
  process.exit(0);
}

console.log("[bundle-cli] zig build 1p ...");
execSync("zig build", { cwd: zserverDir, stdio: "inherit" });

if (!(await exists(zigSrcBin))) {
  throw new Error(
    `[bundle-cli] zig build produced no ${zigSrcBin} — check backend/zserver/build.zig`,
  );
}

await mkdir(destDir, { recursive: true });
await copyFile(zigSrcBin, destBinary);
await chmod(destBinary, 0o755);
console.log(`[bundle-cli] bundled Zig 1p → ${destBinary}`);

// macOS: ad-hoc sign so Gatekeeper doesn't complain when the parent app
// (which itself may be unsigned in dev) spawns the child.
if (process.platform === "darwin") {
  try {
    execSync(`codesign -s - --force ${JSON.stringify(destBinary)}`, {
      stdio: "pipe",
    });
  } catch {
    // Non-fatal. Unsigned binaries still run when the parent app is trusted.
  }
}
