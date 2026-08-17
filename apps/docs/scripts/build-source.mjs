// @ts-check
/**
 * build-source.mjs — docs content pipeline (SolidStart edition).
 *
 * Scans content/docs, extracts frontmatter + plain-text bodies, resolves the
 * per-language navigation trees from meta.json / meta.<lang>.json, and emits
 * .source/{meta.json, tree.json, routes.json, search.json} consumed by the
 * SolidStart app at build time.
 *
 * MDX compilation itself is left to Vite (@mdx-js/rollup + vite-plugin-solid),
 * which transforms content/docs/*.mdx files on import. This script only prepares
 * metadata — it runs before `vite build` (see package.json "build").
 */
import { readdirSync, readFileSync, writeFileSync, existsSync, statSync } from "node:fs";
import { join, relative, basename, dirname, sep } from "node:path";
import { fileURLToPath } from "node:url";
import matter from "gray-matter";
import { unified } from "unified";
import remarkParse from "remark-parse";
import remarkFrontmatter from "remark-frontmatter";
import remarkMdx from "remark-mdx";
import { visit } from "unist-util-visit";
import GithubSlugger from "github-slugger";

const here = dirname(fileURLToPath(import.meta.url));
const CONTENT_ROOT = join(here, "..", "content", "docs");
const OUT_DIR = join(here, "..", ".source");

const LANGS = ["en", "zh", "ko", "ja"];
const DEFAULT_LANG = "en";

/* ------------------------------------------------------------------ */
/* File discovery                                                      */
/* ------------------------------------------------------------------ */

/** Recursively list files under a root. */
function walk(dir, acc = []) {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) walk(full, acc);
    else acc.push(full);
  }
  return acc;
}

/**
 * Parse a docs source filename into { slugParts, lang }.
 *   conventions.zh.mdx      -> slug ["conventions"], lang "zh"
 *   index.mdx               -> slug [],            lang "en"
 *   cli/installation.zh.mdx -> slug ["cli","installation"], lang "zh"
 */
function parseSourceName(absPath) {
  const rel = relative(CONTENT_ROOT, absPath).split(sep);
  const file = rel.pop();
  const dirParts = rel;
  let stem = file.replace(/\.mdx$/, "");
  let lang = DEFAULT_LANG;
  for (const l of LANGS) {
    if (l === DEFAULT_LANG) continue;
    if (stem.endsWith("." + l)) {
      stem = stem.slice(0, -(l.length + 1));
      lang = l;
      break;
    }
  }
  const slug = stem === "index" ? [] : [...dirParts, stem];
  return { slug, lang };
}

/* ------------------------------------------------------------------ */
/* Plain-text extraction (search index)                                */
/* ------------------------------------------------------------------ */

const textProcessor = unified()
  .use(remarkParse)
  .use(remarkFrontmatter, ["yaml"])
  .use(remarkMdx)
  .use(remarkGfmLike);

function remarkGfmLike() {
  return (tree) => {
    // minimal GFM-ish handling: link text, inline code already plain text
    return tree;
  };
}

function extractPlainText(mdxSource) {
  const tree = textProcessor.parse(mdxSource);
  const chunks = [];
  visit(tree, "text", (node) => chunks.push(node.value));
  visit(tree, "inlineCode", (node) => chunks.push(node.value));
  visit(tree, "code", (node) => chunks.push(node.value));
  return chunks.join(" ").replace(/\s+/g, " ").trim();
}

/** Extract h2/h3 headings with slugified ids (matches rehype-slug at render). */
function extractToc(mdxSource) {
  const tree = textProcessor.parse(mdxSource);
  const slugger = new GithubSlugger();
  const toc = [];
  visit(tree, "heading", (node) => {
    if (node.depth < 2 || node.depth > 3) return;
    const text = node.children
      .map((child) => (child.type === "text" || child.type === "inlineCode" ? child.value : ""))
      .join("")
      .trim();
    if (!text) return;
    toc.push({ depth: node.depth, text, id: slugger.slug(text) });
  });
  return toc;
}

/* ------------------------------------------------------------------ */
/* Navigation trees (meta.json)                                        */
/* ------------------------------------------------------------------ */

/**
 * Parse a meta.json "pages" array into tree nodes.
 * Strings are page slugs (relative to the meta file's directory) or nested
 * directories; "---Label---" strings are section separators.
 */
function parsePages(pages, dir, pageByKey) {
  const nodes = [];
  for (const item of pages) {
    if (typeof item !== "string") continue;
    if (item.startsWith("---") && item.endsWith("---")) {
      nodes.push({ type: "separator", title: item.slice(3, -3) });
      continue;
    }
    const key = item;
    // Nested directory (has its own meta.json) vs page file
    const dirPath = join(dir, key);
    if (existsSync(join(dirPath, "meta.json"))) {
      nodes.push({ type: "folder", title: key, key, children: null }); // filled later
    } else if (pageByKey.has(key)) {
      nodes.push({ type: "page", key });
    }
    // unknown entries are skipped (e.g. meta of another language)
  }
  return nodes;
}

/* ------------------------------------------------------------------ */
/* Main                                                                */
/* ------------------------------------------------------------------ */

const mdxFiles = walk(CONTENT_ROOT).filter((f) => f.endsWith(".mdx"));

// pages: Map "slugKey" -> { slug, lang, title, description, file }
const pages = new Map();
const byLang = new Map(LANGS.map((l) => [l, new Map()])); // lang -> slugKey -> page

for (const file of mdxFiles) {
  const { slug, lang } = parseSourceName(file);
  const raw = readFileSync(file, "utf8");
  const { data } = matter(raw);
  const slugKey = slug.join("/");
  const page = {
    slug,
    slugKey,
    lang,
    title: typeof data.title === "string" ? data.title : slug.join("/"),
    description: typeof data.description === "string" ? data.description : "",
    file: relative(join(here, ".."), file).replace(/\\/g, "/"),
    text: extractPlainText(raw),
    toc: extractToc(raw),
  };
  pages.set(slugKey + "@" + lang, page);
  byLang.get(lang).set(slugKey, page);
}

// Load meta trees per directory, per language
const metaByDir = new Map(); // dirRel -> lang -> {title, pages}
for (const file of walk(CONTENT_ROOT).filter((f) => f.endsWith(".json"))) {
  const rel = relative(CONTENT_ROOT, file);
  const m = basename(file).match(/^meta(?:\.(zh|ko|ja))?\.json$/);
  if (!m) continue;
  const lang = m[1] ?? DEFAULT_LANG;
  const dir = dirname(rel) === "." ? "" : dirname(rel);
  const key = dir;
  if (!metaByDir.has(key)) metaByDir.set(key, {});
  metaByDir.get(key)[lang] = JSON.parse(readFileSync(file, "utf8"));
}

// Build tree per language
function buildTree(lang) {
  const rootMeta = metaByDir.get("")?.[lang] ?? metaByDir.get("")?.[DEFAULT_LANG];
  if (!rootMeta) return [];
  // pageByKey: slugKey -> page (within this language, fallback to default)
  const node = (dirKey, meta, depth) => {
    const dir = dirKey === "" ? "" : dirKey;
    const children = [];
    for (const item of meta.pages ?? []) {
      if (typeof item !== "string") continue;
      if (item.startsWith("---") && item.endsWith("---")) {
        children.push({ type: "separator", title: item.slice(3, -3) });
        continue;
      }
      const key = item;
      const slugKey = dir ? dir + "/" + key : key;
      const dirPath = join(CONTENT_ROOT, slugKey);
      const hasDirMeta = existsSync(join(dirPath, "meta.json"));
      if (hasDirMeta) {
        const subMeta = metaByDir.get(slugKey)?.[lang] ?? metaByDir.get(slugKey)?.[DEFAULT_LANG];
        const folderTitle =
          (subMeta && typeof subMeta.title === "string" ? subMeta.title : null) ?? key;
        children.push({
          type: "folder",
          title: folderTitle,
          key: slugKey,
          children: subMeta ? node(slugKey, subMeta, depth + 1) : [],
        });
      } else {
        const page = byLang.get(lang)?.get(slugKey) ?? byLang.get(DEFAULT_LANG)?.get(slugKey);
        if (page) children.push({ type: "page", key: slugKey, title: page.title, slug: page.slug });
      }
    }
    return children;
  };
  return node("", rootMeta, 0);
}

const tree = {};
for (const lang of LANGS) tree[lang] = buildTree(lang);

// Flatten tree per language for prev/next + routes
const routeList = [];
const flatByLang = {};
for (const lang of LANGS) {
  const flat = [];
  const walkTree = (nodes) => {
    for (const n of nodes) {
      if (n.type === "page") {
        flat.push(n);
        const url = lang === DEFAULT_LANG ? "/" + n.key : "/" + lang + "/" + n.key;
        routeList.push(url);
        n.url = url;
      } else if (n.type === "folder") {
        walkTree(n.children ?? []);
      }
    }
  };
  walkTree(tree[lang]);
  flatByLang[lang] = flat;
  routeList.push(lang === DEFAULT_LANG ? "/" : "/" + lang);
}

// Tree-orphan pages: reachable URLs but not part of any nav tree (e.g.
// how-multica-works exists as content but is absent from meta.json).
// Fumadocs exposes them via the page loader and sitemap; keep parity.
const orphanRoutes = [];
for (const page of pages.values()) {
  const url = page.lang === DEFAULT_LANG ? "/" + page.slugKey : "/" + page.lang + "/" + page.slugKey;
  orphanRoutes.push(url);
}

// prev/next per page per lang
for (const lang of LANGS) {
  const flat = flatByLang[lang];
  for (let i = 0; i < flat.length; i++) {
    const p = byLang.get(lang)?.get(flat[i].key) ?? byLang.get(DEFAULT_LANG)?.get(flat[i].key);
    if (!p) continue;
    p.prev = i > 0 ? flat[i - 1].url : null;
    p.next = i < flat.length - 1 ? flat[i + 1].url : null;
  }
}

// Search index per language
const search = {};
for (const lang of LANGS) {
  search[lang] = [...byLang.get(lang).values()].map((p) => ({
    title: p.title,
    description: p.description,
    slug: p.slugKey,
    url: lang === DEFAULT_LANG ? "/" + p.slugKey : "/" + lang + "/" + p.slugKey,
    text: p.text,
  }));
}

const meta = {
  languages: LANGS,
  defaultLanguage: DEFAULT_LANG,
  pages: Object.fromEntries([...pages.values()].map((p) => [p.slugKey + "@" + p.lang, {
    slug: p.slug,
    slugKey: p.slugKey,
    lang: p.lang,
    title: p.title,
    description: p.description,
    file: p.file,
    url: p.lang === DEFAULT_LANG ? "/" + p.slugKey : "/" + p.lang + "/" + p.slugKey,
    prev: p.prev,
    next: p.next,
    toc: p.toc,
  }])),
};

writeFileSync(join(OUT_DIR, "meta.json"), JSON.stringify(meta, null, 2));
writeFileSync(join(OUT_DIR, "tree.json"), JSON.stringify(tree, null, 2));
writeFileSync(join(OUT_DIR, "routes.json"), JSON.stringify([...new Set([...routeList, ...orphanRoutes])], null, 2));
writeFileSync(join(OUT_DIR, "search.json"), JSON.stringify(search, null, 2));


// Emit .source/pages.ts — static imports so SSG renders synchronously.
const pagesLines = [];
let i = 0;
for (const page of pages.values()) {
  pagesLines.push(`import p${i} from "../${page.file}";`);
  i++;
}
const pagesTs = [
  "// @ts-nocheck -- generated file; content MDX has no typed exports",
  ...pagesLines,
  "export const pageModules: Record<string, any> = {",
  ...[...pages.values()].map((page, idx) => `  "${page.slugKey}@${page.lang}": p${idx},`),
  "};",
].join("\n");
writeFileSync(join(OUT_DIR, "pages.ts"), pagesTs + "\n");

console.log(
  `docs source: ${mdxFiles.length} mdx files, ${pages.size} pages, ${new Set(routeList).size} routes`,
);
