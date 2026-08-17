import { getPage } from "~/lib/source";
import { DEFAULT_LANGUAGE, LANGUAGES, type Lang } from "~/lib/i18n";

// Canonical production origin and base path (kept identical to the Next
// implementation — sitemap + hreflang contract must not change).
export const SITE_ORIGIN = "https://www.1person.ai";
export const DOCS_BASE_PATH = "/docs";

export function absoluteDocsUrl(relative: string): string {
  const path = relative === "/" ? "" : relative;
  return SITE_ORIGIN + DOCS_BASE_PATH + path;
}

/**
 * hreflang alternates for a docs page. Slugs that only exist in one language
 * still produce a valid block; Google serves only what is declared.
 */
export function docsAlternates(slugs: string[]): {
  canonical: string;
  languages: Record<string, string>;
} {
  const languages: Record<string, string> = {};
  for (const lang of LANGUAGES) {
    const page = getPage(lang as Lang, slugs);
    if (!page) continue;
    languages[lang] = absoluteDocsUrl(page.url);
  }

  const canonical = languages[DEFAULT_LANGUAGE] ?? Object.values(languages)[0];
  if (canonical) languages["x-default"] = canonical;

  return { canonical: canonical ?? absoluteDocsUrl("/"), languages };
}
