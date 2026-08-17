// @ts-check
/**
 * postprocess.mjs — runs after `vite build` (Nitro prerender) to fix up the
 * static output in .output/public:
 *
 *  1. Prefix asset URLs (_build/...) with /docs so they resolve behind the
 *     reverse proxy that maps /docs -> .output/public (vite base is not
 *     applied by SolidStart 2.0).
 *  2. Set <html lang> per locale (prerender renders every page as en).
 *  3. Emit /docs/sitemap.xml + robots.txt (contracts referenced by apps/web).
 *  4. Copy search indexes into the output so the client search dialog can
 *     fetch them.
 */
import { readdirSync, readFileSync, writeFileSync, mkdirSync, statSync } from "node:fs";
import { join, dirname, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const OUT = join(here, "..", ".output", "public");
const SOURCE = join(here, "..", ".source");
const SITE_ORIGIN = "https://www.1person.ai";
const DOCS_BASE_PATH = "/docs";
const NL = String.fromCharCode(10);

function walk(dir, acc = []) {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) walk(full, acc);
    else acc.push(full);
  }
  return acc;
}

function langForRel(rel) {
  const first = rel.split(sep)[0];
  if (first === "zh" || first === "ja" || first === "ko") return first;
  return "en";
}

const htmlFiles = walk(OUT).filter((f) => f.endsWith(".html"));

for (const file of htmlFiles) {
  let html = readFileSync(file, "utf8");
  html = html.replaceAll('"/_build/', '"/docs/_build/');
  html = html.replaceAll("'/_build/", "'/docs/_build/");
  html = html.replaceAll('src="/_build/', 'src="/docs/_build/');
  const rel = relative(OUT, file);
  const lang = langForRel(rel);
  html = html.replace('<html lang="en"', '<html lang="' + lang + '"');
  writeFileSync(file, html);
}

console.log("postprocess: " + htmlFiles.length + " HTML files patched");

const meta = JSON.parse(readFileSync(join(SOURCE, "meta.json"), "utf8"));
const pages = Object.values(meta.pages);
const bySlug = new Map();
for (const p of pages) {
  const key = p.slugKey;
  if (!bySlug.has(key)) bySlug.set(key, new Map());
  bySlug.get(key).set(p.lang, p.url);
}
const url = (rel) => SITE_ORIGIN + DOCS_BASE_PATH + (rel === "/" ? "" : rel);
const entries = [];
for (const languages of bySlug.values()) {
  const canonicalRel = languages.get("en") ?? languages.values().next().value;
  if (!canonicalRel) continue;
  const alts = [];
  for (const [lang, rel] of languages) {
    alts.push('      <xhtml:link rel="alternate" hreflang="' + lang + '" href="' + url(rel) + '" />');
  }
  alts.push('      <xhtml:link rel="alternate" hreflang="x-default" href="' + url(canonicalRel) + '" />');
  entries.push(
    '  <url>' + NL + '    <loc>' + url(canonicalRel) + '</loc>' + NL + alts.join(NL) + NL + '  </url>',
  );
}
const sitemap =
  '<?xml version="1.0" encoding="UTF-8"?>' + NL +
  '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"' + NL +
  '        xmlns:xhtml="http://www.w3.org/1999/xhtml">' + NL +
  entries.join(NL) +
  NL + '</urlset>' + NL;
writeFileSync(join(OUT, "sitemap.xml"), sitemap);

writeFileSync(
  join(OUT, "robots.txt"),
  "User-agent: *" + NL + "Allow: /docs/" + NL + "Sitemap: " + SITE_ORIGIN + DOCS_BASE_PATH + "/sitemap.xml" + NL,
);

const searchDir = join(OUT, "search");
mkdirSync(searchDir, { recursive: true });
const searchJson = JSON.parse(readFileSync(join(SOURCE, "search.json"), "utf8"));
for (const [lang, list] of Object.entries(searchJson)) {
  writeFileSync(join(searchDir, lang + ".json"), JSON.stringify(list));
}

console.log("postprocess: sitemap.xml, robots.txt, search/*.json written");
