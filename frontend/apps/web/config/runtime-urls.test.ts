import { describe, expect, it } from "vitest";

import { resolveRemoteApiUrl } from "./runtime-urls";

describe("resolveRemoteApiUrl", () => {
  it("prefers REMOTE_API_URL when explicitly configured", () => {
    expect(
      resolveRemoteApiUrl({
        REMOTE_API_URL: "http://backend:8080",
        NEXT_PUBLIC_API_URL: "http://localhost:19000",
        BACKEND_PORT: "18080",
      }),
    ).toBe("http://backend:8080");
  });

  it("uses NEXT_PUBLIC_API_URL when REMOTE_API_URL is unset", () => {
    expect(
      resolveRemoteApiUrl({
        NEXT_PUBLIC_API_URL: "http://localhost:19000",
        BACKEND_PORT: "18080",
      }),
    ).toBe("http://localhost:19000");
  });

  it("ignores PORT, which Next.js sets to the web server's own port", () => {
    // Next.js assigns `process.env.PORT` before next.config.ts is
    // evaluated, so inside a Next process it is always the frontend's port.
    // Trusting it made the SSR proxy forward `/api` and `/auth` calls back
    // to the frontend itself — every request failed with a socket hang up.
    expect(resolveRemoteApiUrl({ PORT: "19080" })).toBe("http://localhost:8080");
    expect(resolveRemoteApiUrl({ PORT: "19080", NEXT_PUBLIC_API_URL: "  " })).toBe(
      "http://localhost:8080",
    );
    expect(
      resolveRemoteApiUrl({ PORT: "19080", BACKEND_PORT: "28080" }),
    ).toBe("http://localhost:28080");
  });

  it("derives the backend URL from the explicit backend port aliases", () => {
    expect(resolveRemoteApiUrl({ BACKEND_PORT: "28080" })).toBe(
      "http://localhost:28080",
    );
    expect(resolveRemoteApiUrl({ API_PORT: "38080" })).toBe(
      "http://localhost:38080",
    );
    expect(resolveRemoteApiUrl({ SERVER_PORT: "48080" })).toBe(
      "http://localhost:48080",
    );
  });

  it("prefers backend port aliases by documented precedence", () => {
    expect(
      resolveRemoteApiUrl({
        BACKEND_PORT: "28080",
        API_PORT: "38080",
        SERVER_PORT: "48080",
      }),
    ).toBe("http://localhost:28080");

    expect(
      resolveRemoteApiUrl({
        API_PORT: "38080",
        SERVER_PORT: "48080",
      }),
    ).toBe("http://localhost:38080");

    expect(resolveRemoteApiUrl({ SERVER_PORT: "48080" })).toBe(
      "http://localhost:48080",
    );
  });

  it("ignores whitespace-only backend URL values", () => {
    expect(
      resolveRemoteApiUrl({
        REMOTE_API_URL: "  ",
        NEXT_PUBLIC_API_URL: "  ",
        BACKEND_PORT: "  ",
        API_PORT: "  ",
        SERVER_PORT: "  ",
      }),
    ).toBe("http://localhost:8080");
  });

  it("falls back to the historical backend port when no env is configured", () => {
    expect(resolveRemoteApiUrl({})).toBe("http://localhost:8080");
  });
});
