import type { NextConfig } from "next";
import { parse } from "dotenv";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "path";
import { resolveRemoteApiUrl } from "./config/runtime-urls";
import { createMDX } from "fumadocs-mdx/next";

// The repo-root .env is the project's single env file. Read only the keys
// the build needs: loading the whole file would push secrets (JWT_SECRET,
// DATABASE_URL, …) into the web server process.
//
// `PORT` in that file is the *backend's* port — the web server's own port
// is not recorded there. It cannot be taken from `process.env`, because
// Next.js overwrites that with the web server's listening port before this
// config is evaluated.
const rootEnvPath = resolve(__dirname, "../../../.env");
const rootEnv = existsSync(rootEnvPath)
  ? parse(readFileSync(rootEnvPath, "utf8"))
  : {};

function firstNonEmpty(...values: (string | undefined)[]): string | undefined {
  for (const value of values) {
    if (value && value.trim().length > 0) return value;
  }
  return undefined;
}

const remoteApiUrl = resolveRemoteApiUrl({
  REMOTE_API_URL: firstNonEmpty(
    process.env.REMOTE_API_URL,
    rootEnv.REMOTE_API_URL,
  ),
  NEXT_PUBLIC_API_URL: firstNonEmpty(
    process.env.NEXT_PUBLIC_API_URL,
    rootEnv.NEXT_PUBLIC_API_URL,
  ),
  BACKEND_PORT: firstNonEmpty(
    process.env.BACKEND_PORT,
    rootEnv.BACKEND_PORT,
    rootEnv.PORT,
  ),
  API_PORT: firstNonEmpty(process.env.API_PORT, rootEnv.API_PORT),
  SERVER_PORT: firstNonEmpty(process.env.SERVER_PORT, rootEnv.SERVER_PORT),
});
const docsUrl = process.env.DOCS_URL || "http://localhost:4000";

// Parse hostnames from CORS_ALLOWED_ORIGINS so that Next.js dev server
// allows cross-origin HMR / webpack requests (e.g. from Tailscale IPs).
const allowedDevOrigins = process.env.CORS_ALLOWED_ORIGINS
  ? process.env.CORS_ALLOWED_ORIGINS.split(",")
      .map((origin) => {
        try {
          return new URL(origin.trim()).host;
        } catch {
          return origin.trim();
        }
      })
      .filter(Boolean)
  : undefined;

const nextConfig: NextConfig = {
  ...(process.env.STANDALONE === "true" ? { output: "standalone" as const } : {}),
  transpilePackages: ["@1person/core", "@1person/ui", "@1person/views"],
  ...(allowedDevOrigins && allowedDevOrigins.length > 0
    ? { allowedDevOrigins }
    : {}),
  images: {
    formats: ["image/avif", "image/webp"],
    qualities: [75, 80, 85],
  },
  async rewrites() {
    return {
      // Run before file-system routes so /docs isn't shadowed by the
      // [workspaceSlug] dynamic segment.
      beforeFiles: [
        {
          source: "/docs",
          destination: `${docsUrl}/docs`,
        },
        {
          source: "/docs/:path*",
          destination: `${docsUrl}/docs/:path*`,
        },
      ],
      afterFiles: [
        {
          source: "/api/:path*",
          destination: `${remoteApiUrl}/api/:path*`,
        },
        {
          source: "/ws",
          destination: `${remoteApiUrl}/ws`,
        },
        {
          source: "/auth/:path*",
          destination: `${remoteApiUrl}/auth/:path*`,
        },
        {
          source: "/uploads/:path*",
          destination: `${remoteApiUrl}/uploads/:path*`,
        },
      ],
      fallback: [],
    };
  },
};

// fumadocs-mdx@12 is incompatible with Next 16's Turbopack: its loader fails to
// dynamic-import `.source/source.config.mjs` under the Turbopack Node evaluator
// (see fumadocs#2658). `dev`/`build` scripts pass `--webpack` to opt out.
// Drop the flag once fumadocs-mdx ships a Turbopack-compatible loader.
const withMDX = createMDX() as (config: NextConfig) => NextConfig;

export default withMDX(nextConfig);
