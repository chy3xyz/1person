import { describe, it, expect } from "vitest";
import {
  LOCAL_PATH_KEY,
  localPathEquals,
  parseLocalPath,
  providerSupportsLocalDirectory,
  withLocalPath,
} from "./local-directory";

describe("parseLocalPath", () => {
  it("reads the path out of the runtime config", () => {
    expect(parseLocalPath({ local_path: "/Users/me/lab" })).toBe("/Users/me/lab");
  });

  it("collapses a malformed config to an empty path", () => {
    // The form must render whatever the server sent instead of throwing —
    // a broken config is something the user has to be able to correct.
    expect(parseLocalPath(null)).toBe("");
    expect(parseLocalPath("not an object")).toBe("");
    expect(parseLocalPath([1, 2])).toBe("");
    expect(parseLocalPath({})).toBe("");
    expect(parseLocalPath({ local_path: 42 })).toBe("");
  });
});

describe("withLocalPath", () => {
  it("sets the path and keeps the other keys of the config bag", () => {
    // `runtime_config` is shared with provider-specific schemas (openclaw's
    // gateway routing) and the update endpoint replaces the whole column —
    // a save that rebuilt it would drop keys the platform still needs.
    const merged = withLocalPath(
      { mode: "gateway", gateway: { host: "gw.internal" } },
      "/Users/me/lab",
    );
    expect(merged).toEqual({
      mode: "gateway",
      gateway: { host: "gw.internal" },
      local_path: "/Users/me/lab",
    });
  });

  it("removes the key when the path is cleared", () => {
    // "No directory" is the absence of the binding, not a path pointing at
    // the current directory.
    const merged = withLocalPath({ local_path: "/Users/me/lab", mode: "local" }, "");
    expect(merged).toEqual({ mode: "local" });
    expect(LOCAL_PATH_KEY in merged).toBe(false);
  });

  it("trims the path it stores", () => {
    expect(withLocalPath({}, "  /Users/me/lab  ")).toEqual({
      local_path: "/Users/me/lab",
    });
  });

  it("survives a malformed config bag", () => {
    expect(withLocalPath(null, "/Users/me/lab")).toEqual({
      local_path: "/Users/me/lab",
    });
    expect(withLocalPath("nonsense", "")).toEqual({});
  });

  it("does not mutate the config it was given", () => {
    const original: Record<string, unknown> = { mode: "local" };
    withLocalPath(original, "/Users/me/lab");
    expect(original).toEqual({ mode: "local" });
  });
});

describe("localPathEquals", () => {
  it("ignores trailing whitespace", () => {
    // A path pasted from a terminal often carries a trailing newline; a
    // save that only drops it is not worth an "unsaved changes" notice.
    expect(localPathEquals({ local_path: "/a" }, { local_path: "/a " })).toBe(true);
  });

  it("sees a real change", () => {
    expect(localPathEquals({ local_path: "/a" }, { local_path: "/b" })).toBe(false);
    expect(localPathEquals({ local_path: "/a" }, {})).toBe(false);
  });
});

describe("providerSupportsLocalDirectory", () => {
  it.each(["claude", "codex", "opencode"])(
    "accepts the %s provider, which a daemon on the user's machine runs",
    (provider) => {
      expect(providerSupportsLocalDirectory(provider)).toBe(true);
    },
  );

  it("rejects the hosted provider", () => {
    // "auto" is what a runtime the daemon cannot run is registered as. A
    // binding saved on such a runtime would be silently ignored.
    expect(providerSupportsLocalDirectory("auto")).toBe(false);
  });

  it("rejects a missing provider", () => {
    expect(providerSupportsLocalDirectory(undefined)).toBe(false);
    expect(providerSupportsLocalDirectory(null)).toBe(false);
    expect(providerSupportsLocalDirectory("")).toBe(false);
  });
});
