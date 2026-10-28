/**
 * @vitest-environment jsdom
 */
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { renderHook } from "@testing-library/react";
import type { ReactNode } from "react";
import { describe, expect, it, vi } from "vitest";
import { useActorName } from "./hooks";

// The workspace id comes from the URL slug + workspace list query, which
// needs a router. The hook under test only needs a stable id.
vi.mock("../hooks", () => ({
  useWorkspaceId: () => "ws-1",
}));

// Queries that never settle keep the hook in its "loading" state, which is
// exactly the window where an unstable default value used to break memo
// chains downstream.
const { neverSettles } = vi.hoisted(() => ({
  neverSettles: () => new Promise<never>(() => {}),
}));

vi.mock("../api", () => ({
  api: {
    listMembers: neverSettles,
    listAgents: neverSettles,
    listSquads: neverSettles,
  },
  getApi: () => ({
    listMembers: neverSettles,
    listAgents: neverSettles,
    listSquads: neverSettles,
  }),
  setApiInstance: vi.fn(),
}));

function createWrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>;
  };
}

function createClient() {
  return new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: Infinity } },
  });
}

describe("useActorName identity stability", () => {
  it("keeps getActorName referentially stable while the queries are still loading", () => {
    const qc = createClient();
    const { result, rerender } = renderHook(() => useActorName(), {
      wrapper: createWrapper(qc),
    });

    const first = result.current.getActorName;
    rerender();
    const second = result.current.getActorName;
    rerender();
    const third = result.current.getActorName;

    // A `= []` default allocates a new array on every render, which changes
    // the useCallback chain and therefore the identity of getActorName.
    // Consumers that feed it into a useMemo dependency chain recompute on
    // every render — and a consumer that writes that result back into state
    // turns it into an infinite update loop.
    expect(second).toBe(first);
    expect(third).toBe(first);
  });

  it("keeps the whole hook result referentially stable across re-renders", () => {
    const qc = createClient();
    const { result, rerender } = renderHook(() => useActorName(), {
      wrapper: createWrapper(qc),
    });

    const first = result.current;
    rerender();
    expect(result.current).toBe(first);
    rerender();
    expect(result.current).toBe(first);
  });

  it("still resolves names once the queries resolve", async () => {
    const qc = createClient();
    await qc.prefetchQuery({
      queryKey: ["workspaces", "ws-1", "members"],
      queryFn: () =>
        Promise.resolve([{ user_id: "u-1", name: "Ada Lovelace" }]),
    });

    const { result } = renderHook(() => useActorName(), {
      wrapper: createWrapper(qc),
    });

    expect(result.current.getMemberName("u-1")).toBe("Ada Lovelace");
    expect(result.current.getActorName("member", "u-1")).toBe("Ada Lovelace");
  });
});
