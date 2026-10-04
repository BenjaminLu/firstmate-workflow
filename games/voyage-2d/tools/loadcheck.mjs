// Each built artifact loads with no console errors at desktop 1440x900 and phone 390x844.
//   node tools/loadcheck.mjs
import { createRequire } from "node:module";
const { chromium } = createRequire(import.meta.url)("playwright");
const PAGES = [["2.5D", "http://127.0.0.1:8766/artifact-2d.html", () => window.__G?.ready], ["3D", "http://127.0.0.1:8765/artifact-game.html", () => window.__THREE_GAME_DIAGNOSTICS__?.state.ready]];
const b = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });
let bad = 0;
for (const [name, url, ready] of PAGES) for (const [dev, vp] of [["desktop", { width: 1440, height: 900 }], ["phone", { width: 390, height: 844 }]]) for (const style of ["p5", "manga"]) {
  const ctx = await b.newContext({ viewport: vp, isMobile: dev === "phone", hasTouch: dev === "phone" });
  const p = await ctx.newPage();
  const errs = [];
  p.on("pageerror", (e) => errs.push(e.message));
  p.on("console", (m) => m.type() === "error" && errs.push(m.text()));
  await p.goto(`${url}?style=${style}`);
  await p.waitForFunction(ready, null, { timeout: 120000 });
  await p.waitForTimeout(8000); // the Playground runs a while
  console.log(name, dev, style, errs.length ? errs : "0 errors");
  bad += errs.length;
  await ctx.close();
}
await b.close();
process.exit(bad ? 1 : 0);
