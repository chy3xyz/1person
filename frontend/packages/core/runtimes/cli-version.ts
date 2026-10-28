/**
 * Frontend mirror of the server's daemon CLI version gate.
 *
 * The agent-create flow (Quick Create modal) requires the daemon's
 * bundled 1person CLI to be new enough to serve the task. The daemon
 * reports its CLI version when it registers; the server stores it on the
 * runtime row's `metadata.cli_version` and the modal reads it from
 * there.
 *
 * Both this pre-validation and the server's
 * `/api/issues/quick-create` handler apply the same rules, so frontend
 * and server agree by construction: the server is the authoritative
 * trust boundary, the frontend just tells the user "your daemon needs an
 * upgrade" before they hit submit.
 *
 * Server mirror: `backend/zserver/src/common/cli_version.zig`.
 */

/**
 * The first 1person CLI release of THIS fork that can serve a
 * quick-create task.
 *
 * Upstream's floor is `0.2.21` — a number in *upstream's* release line.
 * This fork ships its own line, starting at `0.1.0`, and the
 * quick-create protocol is part of its first release, so the floor
 * lives in the fork's line. Keeping upstream's number here would reject
 * every 1person release the fork ever ships.
 */
export const MIN_QUICK_CREATE_CLI_VERSION = "0.1.0";

export type CliVersionState = "ok" | "too_old" | "missing";

export interface CliVersionCheck {
  state: CliVersionState;
  /** What the daemon reported, or empty if missing/unparsable. */
  current: string;
  /** The hard minimum we gate on. */
  min: string;
}

const SEMVER_RE = /v?(\d+)\.(\d+)\.(\d+)/;

// Matches the `git describe --tags --always --dirty` output for a build past
// the latest tag, e.g. `v0.2.15-235-gdaf0e935` or `v0.2.15-235-gdaf0e935-dirty`.
// Daemons built from source (Makefile `make build` / `make daemon`) report this
// shape; tagged releases are bare semver. Treating dev-described daemons as OK
// is what keeps `pnpm dev:desktop` + `make daemon` unblocked without weakening
// the gate for staging or production users running stale stable releases.
const TAGGED_DESCRIBE_RE = /^v?\d+\.\d+\.\d+-\d+-g[0-9a-fA-F]+/;

// The same command on a checkout with NO release tags prints the bare commit
// hash instead (`e22060811-dirty`). This fork has no tags yet, so every local
// build lands here and would otherwise look "missing" — blocking the modal
// for a daemon that is perfectly capable. A commit hash is at least 7 hex
// characters, which keeps a bare semver like `0.1.0` out of this branch (one
// leading hex character, and dots are not hex).
const UNTAGGED_DESCRIBE_RE = /^[0-9a-fA-F]{7,40}(-dirty)?$/;

function parseSemver(raw: string): [number, number, number] | null {
  const m = SEMVER_RE.exec(raw.trim());
  if (!m) return null;
  return [Number(m[1]), Number(m[2]), Number(m[3])];
}

function lessThan(a: [number, number, number], b: [number, number, number]) {
  if (a[0] !== b[0]) return a[0] < b[0];
  if (a[1] !== b[1]) return a[1] < b[1];
  return a[2] < b[2];
}

/**
 * Check a daemon-reported CLI version string against the minimum. Returns
 * `"missing"` for empty/unparsable input (fail closed — same policy as the
 * server) and `"too_old"` for a parsable version below the threshold.
 * Dev-built daemons (git-describe shape, tagged or not) are always OK — the
 * version string itself is the shared signal, so frontend and server agree by
 * construction.
 */
export function checkQuickCreateCliVersion(detected: string | undefined | null): CliVersionCheck {
  const current = (detected ?? "").trim();
  if (TAGGED_DESCRIBE_RE.test(current) || UNTAGGED_DESCRIBE_RE.test(current)) {
    return { state: "ok", current, min: MIN_QUICK_CREATE_CLI_VERSION };
  }
  const parsed = current ? parseSemver(current) : null;
  if (!parsed) {
    return { state: "missing", current, min: MIN_QUICK_CREATE_CLI_VERSION };
  }
  const min = parseSemver(MIN_QUICK_CREATE_CLI_VERSION)!;
  if (lessThan(parsed, min)) {
    return { state: "too_old", current, min: MIN_QUICK_CREATE_CLI_VERSION };
  }
  return { state: "ok", current, min: MIN_QUICK_CREATE_CLI_VERSION };
}

/** Pull `cli_version` off a runtime row's loosely-typed metadata bag. */
export function readRuntimeCliVersion(metadata: Record<string, unknown> | undefined): string {
  const v = metadata?.cli_version;
  return typeof v === "string" ? v : "";
}
