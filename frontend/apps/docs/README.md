# @1person/docs

Source of the published 1Person documentation site: [www.1person.xyz/docs](https://www.1person.xyz/docs).

SolidStart + Vite app. Content lives in `content/docs/` as MDX with frontmatter. Before `vite build`, `scripts/build-source.mjs` scans that folder and emits `.source/{meta,tree,routes,search}.json` plus generated page imports; `scripts/postprocess.mjs` fixes up the prerendered output afterwards.

## Languages

English (`*.mdx`) is the default. Translations use a language suffix:

| Language | Suffix | Example |
|----------|--------|---------|
| English | — | `agents.mdx` |
| 简体中文 | `.zh` | `agents.zh.mdx` |
| 日本語 | `.ja` | `agents.ja.mdx` |
| 한국어 | `.ko` | `agents.ko.mdx` |

Navigation is driven by `meta.json` (default) and per-language `meta.<lang>.json` files in each directory. `"---Section---"` entries render as section separators. Untranslated pages fall back to English.

## Commands

```bash
pnpm --dir frontend dev:docs                             # Vite dev server (turbo)

pnpm --dir frontend --filter @1person/docs build         # build-source + vite build + postprocess
pnpm --dir frontend --filter @1person/docs typecheck     # tsc --noEmit
pnpm --dir frontend --filter @1person/docs test          # vitest run
```

## Writing a page

1. Add `content/docs/<slug>.mdx` with `title` and `description` frontmatter.
2. Add the slug to `content/docs/meta.json` (and to the matching `meta.<lang>.json` when translated) so it appears in the sidebar.
3. Add translations as `<slug>.<lang>.mdx` as they land.

## Build output

`build` prerenders every route into `.output/public`. `postprocess.mjs` then:

1. prefixes asset URLs with `/docs` (the reverse proxy maps `/docs` to that output),
2. sets `<html lang>` per locale,
3. emits `sitemap.xml` and `robots.txt`,
4. copies the search indexes into the output for the client search dialog.

See [`../../../docs/README.md`](../../../docs/README.md) for the full documentation map.
