import { describe, expect, it, vi, beforeEach } from "vitest";

// site.ts reads pages via getPage; stub it so tests never touch the MDX
// pipeline (content/*.mdx are compiled by the Vite plugin at build time).
vi.mock("~/lib/source", () => ({
  getPage: vi.fn((lang: string, slugs: string[]) => {
    const key = slugs.join("/");
    const urls: Record<string, Record<string, string>> = {
      agents: { en: "/agents", zh: "/zh/agents", ko: "/ko/agents", ja: "/ja/agents" },
      "guides/agents": { zh: "/zh/guides/agents" },
    };
    const pageUrl = urls[key]?.[lang];
    return pageUrl ? { url: pageUrl } : undefined;
  }),
  getPageWithFallback: vi.fn(),
  getPageByKey: vi.fn(),
  getTree: vi.fn(() => []),
  getSearchIndex: vi.fn(() => []),
  getLanguages: vi.fn(() => ["en", "zh", "ko", "ja"]),
  getPageComponentSync: vi.fn(),
  DEFAULT_LANGUAGE: "en",
}));

import { docsAlternates, absoluteDocsUrl } from "./site";

describe("docsAlternates", () => {
  it("builds hreflang alternates for a page in all languages", () => {
    const alternates = docsAlternates(["agents"]);
    expect(alternates.canonical).toBe("https://www.1person.xyz/docs/agents");
    expect(alternates.languages).toMatchObject({
      en: "https://www.1person.xyz/docs/agents",
      zh: "https://www.1person.xyz/docs/zh/agents",
      ko: "https://www.1person.xyz/docs/ko/agents",
      ja: "https://www.1person.xyz/docs/ja/agents",
      "x-default": "https://www.1person.xyz/docs/agents",
    });
  });

  it("falls back to the first available language for untranslated pages", () => {
    const alternates = docsAlternates(["guides", "agents"]);
    expect(alternates.canonical).toBe("https://www.1person.xyz/docs/zh/guides/agents");
    expect(alternates.languages["x-default"]).toBe(alternates.languages.zh);
  });

  it("returns a home fallback for unknown slugs", () => {
    const alternates = docsAlternates(["does-not-exist"]);
    expect(alternates.canonical).toBe("https://www.1person.xyz/docs");
  });
});

describe("absoluteDocsUrl", () => {
  it("strips the lone root slash", () => {
    expect(absoluteDocsUrl("/")).toBe("https://www.1person.xyz/docs");
    expect(absoluteDocsUrl("/agents")).toBe("https://www.1person.xyz/docs/agents");
  });
});
