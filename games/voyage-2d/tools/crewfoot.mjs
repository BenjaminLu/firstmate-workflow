// Each model's drawn extent across its idle loops, in baked px about the feet (facing right).
import { createRequire } from "node:module";
const { chromium } = createRequire(import.meta.url)("playwright");
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 1440, height: 900 } });
await p.goto("http://127.0.0.1:8766/artifact-2d.html?crew=10");
await p.waitForFunction(() => window.__G?.ready);
await p.evaluate(() => (window.__G.paused = true));
const r = await p.evaluate(async () => {
  const V = window.__voyage2d, W = V.world, ext = {};
  const c = document.createElement("canvas"); c.width = 1000; c.height = 1000;
  const g = c.getContext("2d", { willReadFrequently: true });
  const LOOPS = { captain: ["idle", "helm"], firstmate: ["helm", "idle"], "reviewer-1": ["idle"] };
  for (const [lp, i] of [0, 1, 2].map((i) => [null, i])) for (const pp of Object.values(W.crew)) { const L = LOOPS[pp.bakeKey] || ["lean", "coil", "mend"]; pp.setLoop(L[i % L.length]); }
  for (let k = 0; k < 180; k++) {
    if (k % 60 === 0) for (const pp of Object.values(W.crew)) { const L = LOOPS[pp.bakeKey] || ["lean", "coil", "mend"]; pp.setLoop(L[(k / 60) % L.length]); }
    for (const pp of Object.values(W.crew)) pp.update(0.1);
    for (const pp of Object.values(W.crew)) {
      if (pp.shots.length) continue;
      const key = pp.bakeKey + ":" + pp.loop;
      g.setTransform(1, 0, 0, 1, 0, 0); g.clearRect(0, 0, 1000, 1000);
      const x = pp.x, y = pp.y, dir = pp.dir, sc = pp.scale;
      g.translate(500 - x, 900 - y);
      pp.dir = 1; pp.draw(g, { shadow: false }); pp.dir = dir;
      const d = g.getImageData(0, 0, 1000, 1000).data;
      let x0 = 1e9, x1 = -1e9, y0 = 1e9;
      for (let j = 0; j < 1000; j += 2) for (let i = 0; i < 1000; i += 2) if (d[(j * 1000 + i) * 4 + 3] > 40) (x0 = Math.min(x0, i)), (x1 = Math.max(x1, i)), (y0 = Math.min(y0, j));
      const e = ext[key] || (ext[key] = [1e9, -1e9, 1e9]);
      e[0] = Math.min(e[0], (x0 - 500) / sc); e[1] = Math.max(e[1], (x1 - 500) / sc); e[2] = Math.min(e[2], (y0 - 900) / sc);
    }
  }
  return Object.fromEntries(Object.entries(ext).map(([k, v]) => [k, v.map(Math.round)]));
});
console.log(r);
await b.close();
