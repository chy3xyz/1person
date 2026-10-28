import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { WSClient } from "./ws-client";

// Capture URL passed to WebSocket so we can assert the connect-time
// query string.  We don't simulate the full WS lifecycle here — only the
// upgrade URL construction, which is what carries client identity.
class FakeWebSocket {
  static lastUrl: string | null = null;
  static lastInstance: FakeWebSocket | null = null;
  // Frames the client sent, in order.
  static sent: string[] = [];
  // The real class exposes these constants; the client compares
  // `readyState` against `WebSocket.OPEN`.
  static OPEN = 1;
  static CLOSED = 3;
  // Fields read by WSClient.connect()/disconnect(), all no-op here.
  onopen: (() => void) | null = null;
  onmessage: ((ev: { data: string }) => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  readyState = 1;
  constructor(url: string) {
    FakeWebSocket.lastUrl = url;
    FakeWebSocket.lastInstance = this;
  }
  close() {}
  send(data: string) {
    FakeWebSocket.sent.push(data);
  }
}

describe("WSClient", () => {
  beforeEach(() => {
    FakeWebSocket.lastUrl = null;
    FakeWebSocket.lastInstance = null;
    FakeWebSocket.sent = [];
    vi.stubGlobal("WebSocket", FakeWebSocket as unknown as typeof WebSocket);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("includes client identity in the upgrade URL when configured", () => {
    const ws = new WSClient("ws://example.test/ws", {
      identity: { platform: "desktop", version: "1.2.3", os: "macos" },
    });
    ws.setAuth("tok", "acme");
    ws.connect();

    const url = new URL(FakeWebSocket.lastUrl!);
    expect(url.searchParams.get("workspace_slug")).toBe("acme");
    expect(url.searchParams.get("client_platform")).toBe("desktop");
    expect(url.searchParams.get("client_version")).toBe("1.2.3");
    expect(url.searchParams.get("client_os")).toBe("macos");
    // Token must never appear in the URL — it is delivered as the first
    // WS message in token mode.
    expect(url.searchParams.has("token")).toBe(false);
  });

  it("omits client_* params when identity is not configured", () => {
    const ws = new WSClient("ws://example.test/ws");
    ws.setAuth("tok", "acme");
    ws.connect();

    const url = new URL(FakeWebSocket.lastUrl!);
    expect(url.searchParams.has("client_platform")).toBe(false);
    expect(url.searchParams.has("client_version")).toBe(false);
    expect(url.searchParams.has("client_os")).toBe(false);
  });

  it("only includes the identity fields that are set", () => {
    const ws = new WSClient("ws://example.test/ws", {
      identity: { platform: "cli" },
    });
    ws.setAuth("tok", "acme");
    ws.connect();

    const url = new URL(FakeWebSocket.lastUrl!);
    expect(url.searchParams.get("client_platform")).toBe("cli");
    expect(url.searchParams.has("client_version")).toBe(false);
    expect(url.searchParams.has("client_os")).toBe(false);
  });

  it("truncates the logged payload when an unparseable frame is large", () => {
    const logger = {
      debug: vi.fn(),
      info: vi.fn(),
      warn: vi.fn(),
      error: vi.fn(),
    };
    const ws = new WSClient("ws://example.test/ws", { logger });
    ws.connect();

    const huge = "x".repeat(5000);
    FakeWebSocket.lastInstance!.onmessage?.({ data: huge });

    expect(logger.warn).toHaveBeenCalledTimes(1);
    const [, summary] = logger.warn.mock.calls[0] as [string, string];
    expect(summary.length).toBeLessThan(huge.length);
    expect(summary).toContain("truncated");
    expect(summary).toContain("5000");
    expect(summary.startsWith("x".repeat(200))).toBe(true);
  });

  it("logs and skips malformed frames without breaking later messages", () => {
    const logger = {
      debug: vi.fn(),
      info: vi.fn(),
      warn: vi.fn(),
      error: vi.fn(),
    };
    const ws = new WSClient("ws://example.test/ws", { logger });
    const handler = vi.fn();
    ws.on("issue:updated", handler);
    ws.connect();

    expect(() => {
      FakeWebSocket.lastInstance!.onmessage?.({ data: `{"type":"issue` });
    }).not.toThrow();

    FakeWebSocket.lastInstance!.onmessage?.({
      data: JSON.stringify({
        type: "issue:updated",
        payload: { id: "issue-1" },
      }),
    });

    expect(logger.warn).toHaveBeenCalledWith(
      "ws: received unparseable message",
      `{"type":"issue`,
    );
    expect(handler).toHaveBeenCalledWith(
      { id: "issue-1" },
      undefined,
      undefined,
    );
  });

  it("passes actor_id and actor_type to event handlers", () => {
    const ws = new WSClient("ws://example.test/ws");
    ws.setAuth("tok", "acme");
    ws.connect();

    const handler = vi.fn();
    ws.on("issue:created", handler);

    const fakeWs = (ws as any).ws as FakeWebSocket;
    fakeWs.onmessage?.({
      data: JSON.stringify({
        type: "issue:created",
        payload: { id: "issue-1" },
        actor_id: "user-123",
        actor_type: "user",
      }),
    });

    expect(handler).toHaveBeenCalledWith(
      { id: "issue-1" },
      "user-123",
      "user",
    );
  });

  // The server bounds how long it waits for the next frame (30s in
  // zserver). Without a keepalive an idle browser connection was dropped
  // every 30 seconds, and every drop made the client reconnect — which
  // invalidates every workspace-scoped query and refetches the whole
  // workspace. That is the "refetch storm".
  it("pings the server periodically so an idle connection survives", () => {
    vi.useFakeTimers();
    try {
      const ws = new WSClient("ws://example.test/ws");
      ws.setAuth("tok", "acme");
      ws.connect();

      // Token mode: the handshake completes on the auth ack.
      FakeWebSocket.lastInstance!.onopen?.();
      FakeWebSocket.lastInstance!.onmessage?.({
        data: JSON.stringify({ type: "auth_ack" }),
      });

      vi.advanceTimersByTime(20_000);
      expect(FakeWebSocket.sent).toContain(JSON.stringify({ type: "ping" }));

      vi.advanceTimersByTime(20_000);
      expect(
        FakeWebSocket.sent.filter((m) => m === JSON.stringify({ type: "ping" })),
      ).toHaveLength(2);
    } finally {
      vi.useRealTimers();
    }
  });

  it("stops the keepalive when the connection closes", () => {
    vi.useFakeTimers();
    try {
      const ws = new WSClient("ws://example.test/ws");
      ws.setAuth("tok", "acme");
      ws.connect();

      FakeWebSocket.lastInstance!.onopen?.();
      FakeWebSocket.lastInstance!.onmessage?.({
        data: JSON.stringify({ type: "auth_ack" }),
      });

      FakeWebSocket.lastInstance!.onclose?.();
      const pingsBefore = FakeWebSocket.sent.filter(
        (m) => m === JSON.stringify({ type: "ping" }),
      ).length;

      vi.advanceTimersByTime(60_000);
      const pingsAfter = FakeWebSocket.sent.filter(
        (m) => m === JSON.stringify({ type: "ping" }),
      ).length;
      expect(pingsAfter).toBe(pingsBefore);
    } finally {
      vi.useRealTimers();
    }
  });
});
