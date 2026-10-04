// the run's numbers (tools/walkjitter.mjs measureRun), both styles: node tools/runcheck.mjs
import { createRequire } from "node:module";
import { createServer } from "node:http";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { measureRun, stats } from "./walkjitter.mjs";
const { chromium } = createRequire(import.meta.url)("playwright");
const ROOT = new URL("..", import.meta.url).pathname;
const server = createServer((req, res) => { const f = join(ROOT, decodeURIComponent(req.url.split("?")[0])); if (!existsSync(f)) return res.writeHead(404).end(); res.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(readFileSync(f)); });
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const b = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });
for (const style of ["crimson", "manga"]) {
  const p = await (await b.newContext({ viewport: { width: 1440, height: 900 } })).newPage();
  await p.goto(`http://127.0.0.1:${server.address().port}/artifact-2d.html?driver=0&crew=24&style=${style}`);
  await p.waitForFunction(() => window.__G?.ready, null, { timeout: 60000 });
  await p.waitForTimeout(1000);
  const r = await measureRun(p);
  const F = r.frames, seg = (a, b) => F.slice(a, b);
  const avg = (xs) => xs.reduce((s, x) => s + x, 0) / xs.length;
  console.log(style, "walkSpeed", r.walkSpeed,
    "walk v", avg(seg(15, 40).map((f) => f.v)).toFixed(0), "run v", avg(seg(85, 160).map((f) => f.v)).toFixed(0),
    "runW walk", Math.max(...seg(0, 40).map((f) => f.run)).toFixed(2), "runW run", Math.min(...seg(85, 160).map((f) => f.run)).toFixed(2), "runW after", seg(225, 230).map((f) => f.run)[0]?.toFixed(2),
    "maxRunWstep", Math.max(...F.slice(1).map((f, i) => Math.abs(f.run - F[i].run))).toFixed(3));
  console.log(" v/run/x", F.filter((f, i) => i % 15 == 0).map((f) => f.v.toFixed(0) + "/" + f.run.toFixed(2) + "/" + f.x.toFixed(0)).join(" "));
  console.log(" walk", JSON.stringify(stats(seg(0, 40))), "\n run", JSON.stringify(stats(seg(85, 160))), "\n all", JSON.stringify(stats(F)));
  console.log(" lean walk/run", avg(seg(15, 40).map((f) => f.lean)).toFixed(1), avg(seg(85, 160).map((f) => f.lean)).toFixed(1), " bob walk/run", Math.max(...seg(15, 40).map((f) => Math.abs(f.y))).toFixed(2), Math.max(...seg(85, 160).map((f) => Math.abs(f.y))).toFixed(2), " elbow walk/run", avg(seg(15, 40).map((f) => f.re)).toFixed(0), avg(seg(85, 160).map((f) => f.re)).toFixed(0));
}
await b.close(); server.close();
