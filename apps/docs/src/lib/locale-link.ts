import { DEFAULT_LANGUAGE, LANGUAGES } from "~/lib/i18n";

// Public URL prefix for every docs link (the site is mounted at /docs).
export const DOCS_BASE_PATH = "/docs";

/** Turn a docs-internal route path into the public /docs-prefixed href. */
export function toDocsHref(routePath: string): string {
  return routePath === "/" ? DOCS_BASE_PATH : DOCS_BASE_PATH + routePath;
}

/**
 * Prefix a root-relative MDX link with the active locale so internal
 * navigation inside zh/ko/ja docs stays in that language. Mirrors the
 * original Next implementation (apps/docs/lib/locale-link.ts) but also
 * applies the /docs base path, which Next's basePath used to inject.
 *
 * Deliberately untouched: external links, in-page anchors, relative paths,
 * already-locale-prefixed paths, and the default language.
 */
export function prefixLocale(href: string, lang: string): string {
  if (!href) return href;
  if (lang === DEFAULT_LANGUAGE) return toDocsHref(href);
  if (/^[a-z][a-z0-9+.-]*:/i.test(href)) return href;
  if (href.startsWith("#")) return href;
  if (!href.startsWith("/")) return href;

  const segments = href.split("/").filter(Boolean);
  const first = segments[0];
  if (first && (LANGUAGES as readonly string[]).includes(first)) {
    return toDocsHref(href);
  }

  const prefixed = href === "/" ? "/" + lang : "/" + lang + href;
  return toDocsHref(prefixed);
}
