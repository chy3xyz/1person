import { describe, it, expect } from "vitest";
import {
  checkQuickCreateCliVersion,
  MIN_QUICK_CREATE_CLI_VERSION,
} from "./cli-version";

describe("checkQuickCreateCliVersion", () => {
  it("gates on this fork's own release line, not upstream's", () => {
    // Upstream's floor is 0.2.21 in upstream's line. This fork ships
    // its own line starting at 0.1.0 — keeping upstream's number would
    // reject every 1person release the fork ships.
    expect(MIN_QUICK_CREATE_CLI_VERSION).toBe("0.1.0");
  });

  it("returns ok for a tagged release at or above the minimum", () => {
    expect(checkQuickCreateCliVersion("v0.1.0").state).toBe("ok");
    expect(checkQuickCreateCliVersion("0.1.0").state).toBe("ok");
    expect(checkQuickCreateCliVersion("v0.4.2").state).toBe("ok");
    expect(checkQuickCreateCliVersion("1.0.0").state).toBe("ok");
  });

  it("returns too_old for a tagged release below the minimum", () => {
    expect(checkQuickCreateCliVersion("v0.0.9").state).toBe("too_old");
    expect(checkQuickCreateCliVersion("0.0.1").state).toBe("too_old");
  });

  it("returns missing for empty or unparsable input", () => {
    expect(checkQuickCreateCliVersion("").state).toBe("missing");
    expect(checkQuickCreateCliVersion(undefined).state).toBe("missing");
    expect(checkQuickCreateCliVersion("not-a-version").state).toBe("missing");
    // Six hex characters is too short to be a commit hash, and it is
    // not a semver either — it stays "missing".
    expect(checkQuickCreateCliVersion("abcdef").state).toBe("missing");
  });

  it("treats tagged git-describe dev builds as ok regardless of base tag", () => {
    expect(checkQuickCreateCliVersion("v0.2.15-235-gdaf0e935").state).toBe("ok");
    expect(checkQuickCreateCliVersion("v0.2.15-235-gdaf0e935-dirty").state).toBe("ok");
    expect(checkQuickCreateCliVersion("0.1.0-1-gabc1234").state).toBe("ok");
  });

  it("treats untagged git-describe dev builds as ok — this fork has no tags", () => {
    // `git describe --tags --always --dirty` on a checkout with no
    // release tags prints the bare commit hash. Without this exemption
    // every local daemon looked "missing" and the modal refused to
    // submit.
    expect(checkQuickCreateCliVersion("e22060811").state).toBe("ok");
    expect(checkQuickCreateCliVersion("e22060811-dirty").state).toBe("ok");
    expect(checkQuickCreateCliVersion("0a1b2c3d4e5f6071").state).toBe("ok");
  });

  it("does not mistake a bare semver for an untagged commit hash", () => {
    // "0.1.0" starts with one hex character, not seven — it is judged by
    // the semver rules, not exempted as a dev build.
    expect(checkQuickCreateCliVersion("0.1.0").state).toBe("ok");
    expect(checkQuickCreateCliVersion("0.0.1").state).toBe("too_old");
  });
});
