// One browser, four workers, no retries: an e2e that is flaky is not a gate.
// The tests run in parallel, so no test changes state another test reads:
// one that writes to its board starts a board of its own.
// Every run uses the mock adapter and a fixture root, so nothing here calls a
// model or the network.
import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "tests/e2e",
  fullyParallel: true,
  workers: 4,
  retries: 0,
  timeout: 20_000,
  expect: { timeout: 5_000 },
  reporter: [["list"]],
  use: { ...devices["Desktop Chrome"], headless: true },
});
