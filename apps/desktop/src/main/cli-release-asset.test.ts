import { describe, expect, it } from "vitest";

import { selectPlatformReleaseAssetName } from "./cli-release-asset";

describe("selectPlatformReleaseAssetName", () => {
  it("prefers the versioned archive name when both exist", () => {
    const assetNames = [
      "checksums.txt",
      "1person_darwin_amd64.tar.gz",
      "1person-cli-1.2.3-darwin-amd64.tar.gz",
    ];

    expect(selectPlatformReleaseAssetName(assetNames, "darwin", "x64")).toBe(
      "1person-cli-1.2.3-darwin-amd64.tar.gz",
    );
  });

  it("falls back to the legacy archive name when only legacy is present", () => {
    const assetNames = ["checksums.txt", "1person_darwin_amd64.tar.gz"];

    expect(selectPlatformReleaseAssetName(assetNames, "darwin", "x64")).toBe(
      "1person_darwin_amd64.tar.gz",
    );
  });

  it("matches the renamed darwin archive from release assets", () => {
    const assetNames = [
      "checksums.txt",
      "1person-cli-1.2.3-darwin-amd64.tar.gz",
      "1person-cli-1.2.3-darwin-arm64.tar.gz",
      "1person-cli-1.2.3-linux-amd64.tar.gz",
    ];

    expect(selectPlatformReleaseAssetName(assetNames, "darwin", "x64")).toBe(
      "1person-cli-1.2.3-darwin-amd64.tar.gz",
    );
  });

  it("matches the renamed windows zip archive", () => {
    const assetNames = [
      "1person-cli-1.2.3-windows-amd64.zip",
      "1person-cli-1.2.3-linux-amd64.tar.gz",
    ];

    expect(selectPlatformReleaseAssetName(assetNames, "win32", "x64")).toBe(
      "1person-cli-1.2.3-windows-amd64.zip",
    );
  });

  it("fails when the current platform asset is missing", () => {
    expect(() =>
      selectPlatformReleaseAssetName(
        ["1person-cli-1.2.3-linux-amd64.tar.gz", "1person_linux_amd64.tar.gz"],
        "darwin",
        "arm64",
      ),
    ).toThrow(/no release asset found/);
  });
});
