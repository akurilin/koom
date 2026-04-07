import { defineConfig } from "vitest/config";

export default defineConfig({
  // Vite resolves @/* and other tsconfig path aliases natively
  // (introduced in Vite 7 / Vitest 4) so we don't need the
  // vite-tsconfig-paths plugin.
  resolve: {
    tsconfigPaths: true,
  },
  test: {
    // Node env for API route / backend tests. If we add React component
    // tests later they'll need happy-dom or jsdom via a separate config.
    environment: "node",
    // Integration tests hit real Postgres and real R2; they take longer
    // than the default 5s.
    testTimeout: 30_000,
    // Run tests sequentially for now. The integration test mutates
    // shared state (a row in recordings, an object in R2) and parallel
    // runs could conflict. If we ever split into isolated units that
    // can run in parallel, revisit.
    fileParallelism: false,
    // Only pick up files under tests/ — don't let a stray *.test.ts in
    // the Next.js source tree get scooped up by the default glob.
    include: ["tests/**/*.{test,spec}.ts"],
    // Populate process.env from .env.local before any route handler
    // modules are imported by the test files.
    setupFiles: ["./tests/setup.ts"],
  },
});
