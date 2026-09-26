import { describe, expect, it } from "vitest";
import { prefixLocale, toDocsHref } from "./locale-link";

describe("prefixLocale", () => {
  it("prefixes root-relative paths with /docs + active non-default locale", () => {
    expect(prefixLocale("/workspaces", "zh")).toBe("/docs/zh/workspaces");
    expect(prefixLocale("/workspaces", "ko")).toBe("/docs/ko/workspaces");
    expect(prefixLocale("/workspaces", "ja")).toBe("/docs/ja/workspaces");
  });

  it("preserves anchors and query strings on prefixed paths", () => {
    expect(prefixLocale("/providers#claude-code", "zh")).toBe("/docs/zh/providers#claude-code");
    expect(prefixLocale("/agents?from=docs", "zh")).toBe("/docs/zh/agents?from=docs");
  });

  it("rewrites the bare root path to the locale root", () => {
    expect(prefixLocale("/", "zh")).toBe("/docs/zh");
  });

  it("prefixes default-language URLs with /docs only", () => {
    expect(prefixLocale("/workspaces", "en")).toBe("/docs/workspaces");
    expect(prefixLocale("/", "en")).toBe("/docs");
  });

  it("does not double-prefix paths that already carry a known locale", () => {
    expect(prefixLocale("/zh/workspaces", "zh")).toBe("/docs/zh/workspaces");
    expect(prefixLocale("/en/workspaces", "zh")).toBe("/docs/en/workspaces");
    expect(prefixLocale("/ko/workspaces", "zh")).toBe("/docs/ko/workspaces");
  });

  it("leaves external URLs, anchors and relative paths alone", () => {
    expect(prefixLocale("https://1person.xyz/download", "zh")).toBe("https://1person.xyz/download");
    expect(prefixLocale("mailto:hello@1person.xyz", "zh")).toBe("mailto:hello@1person.xyz");
    expect(prefixLocale("#section", "zh")).toBe("#section");
    expect(prefixLocale("./sibling", "zh")).toBe("./sibling");
    expect(prefixLocale("../sibling", "zh")).toBe("../sibling");
  });

  it("returns empty hrefs unchanged", () => {
    expect(prefixLocale("", "zh")).toBe("");
  });
});

describe("toDocsHref", () => {
  it("maps internal routes to /docs-prefixed public URLs", () => {
    expect(toDocsHref("/")).toBe("/docs");
    expect(toDocsHref("/agents")).toBe("/docs/agents");
    expect(toDocsHref("/zh/agents")).toBe("/docs/zh/agents");
  });
});
