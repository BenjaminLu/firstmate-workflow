// p95 frame cost on a 4x-throttled phone (the budget test's setup), two builds interleaved:
//   node tools/perfcmp.mjs <urlA> <urlB> [runs]
import { createRequire } from "node:module";
const { chromium, devices } = createRequire(import.meta.url)("playwright");
const [A, B, runs = 3] = process.argv.slice(2);
const b = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });
const res = { A: [], B: [] };
for (let r = 0; r < +runs; r++) for (const [k, url] of [["A", A], ["B", B]]) for (const crew of (process.env.CREW || "7,24").split(",").map(Number)) {
  const ctx = await b.newContext({ ...devices["iPhone 13"] });
  const p = await ctx.newPage();
  await p.goto(`${url}?scene=battle&demo=1&crew=${crew}`);
  await p.waitForFunction(() => window.__G?.ready, null, { timeout: 60000 });
  await (await ctx.newCDPSession(p)).send("Emulation.setCPUThrottlingRate", { rate: 4 });
  await p.waitForTimeout(6000);
  res[k].push(`${crew}:${(await p.evaluate(() => window.__voyage2d.perf())).p95}`);
  await ctx.close();
}
await b.close();
console.log(JSON.stringify(res));
