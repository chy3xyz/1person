import { defineConfig } from "vitest/config";
import path from "node:path";

export default defineConfig({
  test: {
    environment: "node",
    globals: true,
    include: ["src/**/*.test.{ts,tsx}"],
    exclude: ["node_modules/**", ".output/**", ".source/**", ".nitro/**"],
  },
  resolve: {
    alias: {
      "~": path.resolve(import.meta.dirname, "src"),
      "@": path.resolve(import.meta.dirname, "src"),
    },
  },
});
