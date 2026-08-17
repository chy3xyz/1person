import { LANGUAGES, DEFAULT_LANGUAGE, type Lang } from "~/lib/i18n";
import meta from "../../.source/meta.json";
import treeJson from "../../.source/tree.json";
import searchJson from "../../.source/search.json";
import { pageModules } from "../../.source/pages";

export type PageMeta = {
  slug: string[];
  slugKey: string;
  lang: Lang;
  title: string;
  description: string;
  file: string;
  url: string;
  prev: string | null;
  next: string | null;
};

export type TreePageNode = { type: "page"; key: string; title: string; slug: string[]; url: string };
export type TreeSeparatorNode = { type: "separator"; title: string };
export type TreeFolderNode = { type: "folder"; title: string; key: string; children: TreeNode[] };
export type TreeNode = TreePageNode | TreeSeparatorNode | TreeFolderNode;

export type SearchEntry = {
  title: string;
  description: string;
  slug: string;
  url: string;
  text: string;
};

type MetaFile = {
  languages: string[];
  defaultLanguage: string;
  pages: Record<string, Omit<PageMeta, "slug"> & { slug: string[] }>;
};

const metaFile = meta as unknown as MetaFile;
const treeFile = treeJson as unknown as Record<Lang, TreeNode[]>;
const searchFile = searchJson as unknown as Record<Lang, SearchEntry[]>;

const pageByKey = new Map<string, PageMeta>();
for (const [key, p] of Object.entries(metaFile.pages)) {
  pageByKey.set(key, {
    ...p,
    slug: p.slug,
    lang: p.lang as Lang,
  });
}

export function getPage(lang: Lang, slug: string[]): PageMeta | undefined {
  return pageByKey.get(slug.join("/") + "@" + lang);
}

export function getPageByKey(key: string): PageMeta | undefined {
  return pageByKey.get(key);
}

/** Fallback: same slug in the default language (mid-translation pages). */
export function getPageWithFallback(lang: Lang, slug: string[]): PageMeta | undefined {
  return getPage(lang, slug) ?? getPage(DEFAULT_LANGUAGE, slug);
}

export function getTree(lang: Lang): TreeNode[] {
  return treeFile[lang] ?? [];
}

export function getSearchIndex(lang: Lang): SearchEntry[] {
  return searchFile[lang] ?? [];
}

export function getLanguages(): Lang[] {
  return [...LANGUAGES];
}

export type { Lang };
export { DEFAULT_LANGUAGE };

/** MDX component for a page (resolved synchronously for SSG). */
export function getPageComponent(page: PageMeta): (() => any) | undefined {
  return pageModules[page.slugKey + "@" + page.lang];
}

/** MDX component resolved synchronously (SSG renders without Suspense). */
export function getPageComponentSync(
  page: PageMeta,
): ((props: Record<string, unknown>) => any) | undefined {
  const mod = pageModules[page.slugKey + "@" + page.lang];
  return mod ? ((_props: Record<string, unknown>) => mod) : undefined;
}
