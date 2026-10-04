// node tools/seq.mjs "<query>" <prefix> <ms,ms,...> [w] [h]   screenshots of game2d.html over time
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { chromium } = require("playwright");
const [q, prefix, times, w = 1440, h = 900] = process.argv.slice(2);
const page = process.env.PAGE || "game2d.html";
const b = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });
const p = await b.newPage({ viewport: { width: +w, height: +h }, deviceScaleFactor: 1 });
const errs = [];
p.on("pageerror", (e) => errs.push("pageerror " + e.message));
p.on("console", (m) => (m.type() === "error" || m.type() === "warning") && errs.push(m.type() + " " + m.text().slice(0, 300)));
await p.goto(`http://127.0.0.1:8791/${page}?${q}`);
await p.waitForFunction(() => window.__G?.ready, null, { timeout: 60000 });
const t0 = Date.now();
const out = [];
for (const t of times.split(",").map(Number)) {
  const wait = t - (Date.now() - t0);
  if (wait > 0) await p.waitForTimeout(wait);
  if (process.env.PRE) await p.evaluate(process.env.PRE);
  const f = `${prefix}-${t}.png`;
  await p.screenshot({ path: f });
  out.push(f);
}
const perf = await p.evaluate(() => window.__voyage2d.perf());
console.log(JSON.stringify({ out, perf, errs: errs.slice(0, 6) }));
await b.close();
