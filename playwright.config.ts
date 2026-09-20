// One browser, one worker, no retries: an e2e that is flaky is not a gate.
// Every run uses the mock adapter and a fixture root, so nothing here calls a
// model or the network.
import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "tests/e2e",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 20_000,
  expect: { timeout: 5_000 },
  reporter: [["list"]],
  use: { ...devices["Desktop Chrome"], headless: true },
});
