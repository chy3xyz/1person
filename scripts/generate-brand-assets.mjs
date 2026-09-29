#!/usr/bin/env node
/**
 * generate-brand-assets.mjs — regenerate the 1Person mark / favicon assets.
 *
 * Canonical vector sources live in `docs/assets/` (`logo-light.svg`,
 * `logo-dark.svg`). This script emits the derived assets:
 *
 *   docs/assets/favicon.svg                          adaptive SVG (light/dark)
 *   frontend/apps/web/public/favicon.svg             copy of the adaptive SVG
 *   frontend/apps/web/public/favicon-16.png
 *   frontend/apps/web/public/favicon-32.png
 *   frontend/apps/web/public/apple-touch-icon.png    180×180, app-icon style
 *   frontend/apps/web/public/icon-192.png            PWA / home-screen icon
 *   frontend/apps/web/public/icon-512.png            PWA / home-screen icon
 *   frontend/apps/docs/public/favicon.svg
 *   frontend/apps/docs/public/apple-touch-icon.png   180×180, app-icon style
 *
 * Rasterization uses sharp, resolved from the frontend workspace install:
 *
 *   pnpm --dir frontend install
 *   node scripts/generate-brand-assets.mjs
 *
 * Keep the mark geometry in sync with the consumers that inline it:
 * `frontend/packages/ui/components/common/app-icon.tsx` (clip-path) and
 * `frontend/apps/mobile/components/brand/multica-logo.tsx` (react-native-svg).
 */

import { mkdir, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "..");

let sharp;
try {
  const require = createRequire(join(repoRoot, "frontend", "package.json"));
  sharp = require("sharp");
} catch {
  console.error(
    "[brand] sharp is not installed — run `pnpm --dir frontend install` first.",
  );
  process.exit(1);
}

// The 8-pointed 1Person mark, traced in a 100×100 box (matches the polygon
// used by the UI clip-path and the mobile component).
const MARK_POINTS =
  "45,62.1 45,100 55,100 55,62.1 81.8,88.9 88.9,81.8 62.1,55 100,55 100,45 " +
  "62.1,45 88.9,18.2 81.8,11.1 55,37.9 55,0 45,0 45,37.9 18.2,11.1 11.1,18.2 " +
  "37.9,45 0,45 0,55 37.9,55 11.1,81.8 18.2,88.9";

// Mark occupies 60% of the canvas, centred (20% padding on every side).
const MARK_TRANSFORM = "translate(20 20) scale(0.6)";

const INK = "#111827";
const PAPER = "#ffffff";
const INK_LIGHT = "#f9fafb";
const APP_MARK = "#e5e7eb";
const APP_BG = "#111827";
const RADIUS = 22;

function markGroup(attrs) {
  return `  <g transform="${MARK_TRANSFORM}">
    <polygon ${attrs} points="${MARK_POINTS}"/>
  </g>`;
}

/** Browser favicon: flips with the color scheme, rounded-square badge. */
function adaptiveFaviconSvg() {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" role="img" aria-label="1Person">
  <style>
    .bg { fill: ${PAPER}; }
    .mark { fill: ${INK}; }
    @media (prefers-color-scheme: dark) {
      .bg { fill: ${INK}; }
      .mark { fill: ${INK_LIGHT}; }
    }
  </style>
  <rect width="100" height="100" rx="${RADIUS}" class="bg"/>
${markGroup('class="mark"')}
</svg>
`;
}

/** App-icon style: dark rounded square + light mark (apple-touch, PWA, apps). */
function appIconSvg() {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" role="img" aria-label="1Person">
  <rect width="100" height="100" rx="${RADIUS}" fill="${APP_BG}"/>
${markGroup(`fill="${APP_MARK}"`)}
</svg>
`;
}

async function renderPng(svg, size, outPath) {
  await mkdir(dirname(outPath), { recursive: true });
  await sharp(Buffer.from(svg))
    .resize(size, size)
    .png({ compressionLevel: 9 })
    .toFile(outPath);
  console.log(`[brand] ${outPath.replace(repoRoot + "/", "")} (${size}×${size})`);
}

async function writeSvg(outPath, svg) {
  await mkdir(dirname(outPath), { recursive: true });
  await writeFile(outPath, svg);
  console.log(`[brand] ${outPath.replace(repoRoot + "/", "")}`);
}

const web = join(repoRoot, "frontend", "apps", "web", "public");
const docs = join(repoRoot, "frontend", "apps", "docs", "public");

const faviconSvg = adaptiveFaviconSvg();
const iconSvg = appIconSvg();

await writeSvg(join(repoRoot, "docs", "assets", "favicon.svg"), faviconSvg);
await writeSvg(join(web, "favicon.svg"), faviconSvg);
await writeSvg(join(docs, "favicon.svg"), faviconSvg);

await renderPng(iconSvg, 16, join(web, "favicon-16.png"));
await renderPng(iconSvg, 32, join(web, "favicon-32.png"));
await renderPng(iconSvg, 180, join(web, "apple-touch-icon.png"));
await renderPng(iconSvg, 192, join(web, "icon-192.png"));
await renderPng(iconSvg, 512, join(web, "icon-512.png"));
await renderPng(iconSvg, 180, join(docs, "apple-touch-icon.png"));

console.log("[brand] done");
