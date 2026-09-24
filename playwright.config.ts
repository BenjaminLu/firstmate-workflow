// One browser, four workers, no retries: an e2e that is flaky is not a gate.
// The tests run in parallel, so no test changes state another test reads:
// one that writes to its board starts a board of its own. bin/ci.sh runs
// this beside the bash suites and passes --workers to share the CPUs with
// them; the four here are what a run on its own gets.
// The deadlines are for a loaded machine, not an idle one: a wait passes as
// soon as its condition holds, so a wide one costs nothing when all is well.
// Every run uses the mock adapter and a fixture root, so nothing here calls a
// model or the network.
import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "tests/e2e",
  fullyParallel: true,
  workers: 4,
  retries: 0,
  timeout: 60_000,
  expect: { timeout: 15_000 },
  reporter: [["list"]],
  use: { ...devices["Desktop Chrome"], headless: true },
});
