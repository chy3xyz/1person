import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { WSClient } from "./ws-client";

// Stand-in for the global WebSocket. The client only ever touches
// `readyState`, `send()` and `close()`, plus the `OPEN` constant, so a
// flat fake is enough to drive the handshake and the keepalive.
class FakeWebSocket {
  static lastUrl: string | null = null;
  static lastInstance: FakeWebSocket | null = null;
  // Frames the client sent, in order.
  static sent: string[] = [];

  static OPEN = 1;
  static CLOSED = 3;

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

const PING = JSON.stringify({ type: "ping" });

function makeClient() {
  return new WSClient({
    url: "wss://example.test/ws",
    token: "tok",
    workspaceSlug: "acme",
  });
}

/** Drive the handshake: open → auth frame → auth_ack. */
function authenticate() {
  FakeWebSocket.lastInstance!.onopen?.();
  FakeWebSocket.lastInstance!.onmessage?.({
    data: JSON.stringify({ type: "auth_ack" }),
  });
}

describe("WSClient keepalive", () => {
  beforeEach(() => {
    FakeWebSocket.lastUrl = null;
    FakeWebSocket.lastInstance = null;
    FakeWebSocket.sent = [];
    vi.stubGlobal("WebSocket", FakeWebSocket as unknown as typeof WebSocket);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  // The server bounds how long it waits for the next frame (30s in
  // zserver). Without a keepalive an idle mobile connection was dropped
  // every 30 seconds, and every drop made the client reconnect — which
  // invalidates every workspace-scoped query and refetches the whole
  // workspace. That is the "refetch storm".
  it("pings the server periodically so an idle connection survives", () => {
    vi.useFakeTimers();
    try {
      const ws = makeClient();
      ws.connect();
      authenticate();

      vi.advanceTimersByTime(20_000);
      expect(FakeWebSocket.sent).toContain(PING);

      vi.advanceTimersByTime(20_000);
      expect(FakeWebSocket.sent.filter((m) => m === PING)).toHaveLength(2);
    } finally {
      vi.useRealTimers();
    }
  });

  it("does not ping before the handshake completes", () => {
    vi.useFakeTimers();
    try {
      const ws = makeClient();
      ws.connect();

      vi.advanceTimersByTime(60_000);
      expect(FakeWebSocket.sent.filter((m) => m === PING)).toHaveLength(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it("stops the keepalive when the connection closes", () => {
    vi.useFakeTimers();
    try {
      const ws = makeClient();
      ws.connect();
      authenticate();

      FakeWebSocket.lastInstance!.onclose?.();
      const pingsBefore = FakeWebSocket.sent.filter((m) => m === PING).length;

      vi.advanceTimersByTime(60_000);
      expect(FakeWebSocket.sent.filter((m) => m === PING)).toHaveLength(
        pingsBefore,
      );
    } finally {
      vi.useRealTimers();
    }
  });

  // The app is backgrounded on every app switch — a live interval there
  // keeps the socket warm in a state where iOS is about to kill it and
  // would race the pause/resume cycle.
  it("stops the keepalive when the client is paused", () => {
    vi.useFakeTimers();
    try {
      const ws = makeClient();
      ws.connect();
      authenticate();

      ws.pause();
      vi.advanceTimersByTime(60_000);
      expect(FakeWebSocket.sent.filter((m) => m === PING)).toHaveLength(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it("stops the keepalive on disconnect", () => {
    vi.useFakeTimers();
    try {
      const ws = makeClient();
      ws.connect();
      authenticate();

      ws.disconnect();
      vi.advanceTimersByTime(60_000);
      expect(FakeWebSocket.sent.filter((m) => m === PING)).toHaveLength(0);
    } finally {
      vi.useRealTimers();
    }
  });

  // A pong is the answer to our own keepalive — protocol traffic, not a
  // business event. Dispatching it would let a catch-all subscriber
  // react to it.
  it("never dispatches a pong to the event handlers", () => {
    const ws = makeClient();
    const anyHandler = vi.fn();
    const typedHandler = vi.fn();
    ws.onAny(anyHandler);
    ws.on("issue:updated", typedHandler);
    ws.connect();

    FakeWebSocket.lastInstance!.onmessage?.({
      data: JSON.stringify({ type: "pong" }),
    });

    expect(anyHandler).not.toHaveBeenCalled();
    expect(typedHandler).not.toHaveBeenCalled();
  });

  // The event body must be an object — handlers destructure it
  // directly. A frame without one must not throw out of onmessage.
  it("hands the handlers an empty body when the payload is missing", () => {
    const ws = makeClient();
    const handler = vi.fn();
    ws.on("issue:updated", handler);
    ws.connect();

    expect(() => {
      FakeWebSocket.lastInstance!.onmessage?.({
        data: JSON.stringify({ type: "issue:updated" }),
      });
    }).not.toThrow();

    expect(handler).toHaveBeenCalledTimes(1);
    expect(handler).toHaveBeenCalledWith({}, undefined);
  });
});
