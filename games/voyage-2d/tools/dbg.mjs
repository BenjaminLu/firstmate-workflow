import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { chromium } = require("playwright");
const b = await chromium.launch({ args: ["--use-angle=metal"] });
const p = await b.newPage({ viewport: { width: 1440, height: 900 } });
await p.goto("http://127.0.0.1:8791/game2d.html?scene=victory");
await p.waitForFunction(() => window.__G?.ready);
for (const t of [5000, 7000, 8500, 9500]) {
  await p.waitForTimeout(t === 5000 ? 5000 : t - [5000, 7000, 8500, 9500][[5000, 7000, 8500, 9500].indexOf(t) - 1]);
  console.log(t, await p.evaluate(() => { const c = __voyage2d.world.crew.captain; return JSON.stringify({ shots: c.shots.map(s=>[s.name, +s.start.toFixed(2)]), rs: c.cur.rs.map(v=>+v.toFixed(0)), view: c.view, clock: +c.clock.toFixed(2), et: __voyage2d.battle.ending?.t }); }));
}
await b.close();
