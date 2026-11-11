// The `runtime_config.local_path` binding: the local git repository an
// agent works in.
//
// Stored under `agent.runtime_config` as freeform JSONB. The daemon reads
// it when it picks a task up: the task gets its own git worktree inside
// that repository, the agent edits the worktree, and the platform commits
// the result onto a `1p/<agent>/<task>` branch the user merges by hand.
//
// The daemon's counterpart is `readLocalPath` in
// `backend/zserver/src/modules/daemon/agent_task.zig` — keep both sides in
// lockstep when changing the key name.

// The key inside `runtime_config` that holds the path.
export const LOCAL_PATH_KEY = "local_path";

// Runtime providers a paired daemon on a user's machine can execute.
//
// The daemon detects the CLI it can run and registers the runtime under
// that provider's name; a runtime it does not recognise lands as "auto",
// which is a hosted runtime that never touches a local checkout. Only the
// providers below ever read `runtime_config.local_path` — the daemon reads
// it when it claims the task, so a runtime served elsewhere would ignore
// the binding.
//
// Keep in sync with `Provider.fromName` in
// `backend/zserver/src/cli/agent_exec.zig`.
const LOCAL_DIRECTORY_PROVIDERS = new Set(["claude", "codex", "opencode"]);

export function providerSupportsLocalDirectory(
  provider: string | undefined | null,
): boolean {
  if (!provider) return false;
  return LOCAL_DIRECTORY_PROVIDERS.has(provider);
}

// Read the bound path out of an agent's `runtime_config`.
//
// A malformed config collapses to an empty path rather than throwing: the
// form must render whatever the server sent, and the user can correct it.
export function parseLocalPath(raw: unknown): string {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return "";
  const value = (raw as Record<string, unknown>)[LOCAL_PATH_KEY];
  return typeof value === "string" ? value : "";
}

// Put a path into an agent's `runtime_config`, keeping every other key.
//
// `runtime_config` is shared with provider-specific schemas — openclaw's
// gateway routing lives in the same bag — and the update endpoint replaces
// the whole column. Rebuilding the bag from scratch would drop keys the
// platform still needs, so the merge keeps the rest untouched.
//
// An empty path removes the key: "no directory" is the absence of the
// binding, not a path pointing at the current directory.
export function withLocalPath(
  raw: unknown,
  path: string,
): Record<string, unknown> {
  const base: Record<string, unknown> =
    raw && typeof raw === "object" && !Array.isArray(raw)
      ? { ...(raw as Record<string, unknown>) }
      : {};
  const trimmed = path.trim();
  if (trimmed === "") {
    delete base[LOCAL_PATH_KEY];
  } else {
    base[LOCAL_PATH_KEY] = trimmed;
  }
  return base;
}

// Whether the bound path changed, used by the form's dirty detector.
//
// The comparison is on the trimmed value: trailing whitespace in a path
// pasted from a terminal is noise, and a save that only drops it is not
// worth a "you have unsaved changes" notice.
export function localPathEquals(a: unknown, b: unknown): boolean {
  return parseLocalPath(a).trim() === parseLocalPath(b).trim();
}
