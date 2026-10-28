import { defineConfig } from "vitest/config";

// Mobile vitest is intentionally minimal — Node environment only, scoped to
// pure-function tests in `lib/` and `data/`. We don't ship jsdom or RN test
// renderers here because the app runs on Hermes / native shims and any
// DOM-shaped runner would be a lie. Tests that need RN component rendering
// would need a separate jest+react-native-testing-library track; for now we
// keep this lane for helpers and serializers only.
//
// `data/` is in scope because the realtime layer there (ws-client.ts) is
// deliberately React-free and RN-free — it only touches the global
// WebSocket/URL/timers, all of which exist in Node, so it is testable
// here with a stubbed global.
//
// Co-located test files (foo.ts + foo.test.ts) match how the rest of the
// monorepo organises vitest suites.
export default defineConfig({
  test: {
    environment: "node",
    globals: true,
    include: ["lib/**/*.test.ts", "data/**/*.test.ts"],
    passWithNoTests: true,
  },
});
