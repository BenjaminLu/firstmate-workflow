// T-298: render every planned page at its viewport and colour scheme.
//
//   bun bin/lib/fm-design-capture.mjs <plan.json>
//
// bin/lib/fm_design.py writes the plan and checks every screenshot this
// writes; it runs in the launcher, outside the round's sandbox, so the
// designer round itself never starts a browser. Any page that fails to load
// exits non-zero, and no designer round starts.
import { readFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { chromium } from "@playwright/test";

const plan = JSON.parse(readFileSync(process.argv[2], "utf8"));
const browser = await chromium.launch();
let failed = 0;
try {
  for (const shot of plan.shots) {
    const context = await browser.newContext({
      viewport: { width: shot.width, height: shot.height },
      colorScheme: shot.scheme,
      reducedMotion: "reduce",
    });
    try {
      const page = await context.newPage();
      const response = await page.goto(shot.url, { waitUntil: "load", timeout: 30000 });
      if (response && !response.ok() && !shot.url.startsWith("file:")) throw new Error(`HTTP ${response.status()}`);
      const out = join(plan.out, shot.file);
      mkdirSync(dirname(out), { recursive: true });
      await page.screenshot({ path: out, fullPage: true, animations: "disabled" });
    } catch (error) {
      failed++;
      console.error(`capture failed: ${shot.file}: ${error.message}`);
    } finally {
      await context.close();
    }
  }
} finally {
  await browser.close();
}
process.exit(failed ? 1 : 0);
