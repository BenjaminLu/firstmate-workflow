// node tools/mockframe.mjs "<query>" <name> [device] [waitMs] [special]
// a game frame with the crew hidden (and the DOM HUD hidden), plus where each crewman stands on screen
import { createRequire } from "node:module";
import { writeFileSync } from "node:fs";
const require = createRequire(import.meta.url);
const { chromium, devices } = require("playwright");
const [q, name, dev = "", wait = 1500, special = ""] = process.argv.slice(2);
const b = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });
const ctx = await b.newContext(dev ? { ...devices[dev] } : { viewport: { width: 1920, height: 1080 } });
const p = await ctx.newPage();
await p.goto(`http://127.0.0.1:8791/game2d.html?${q}`);
await p.waitForFunction(() => window.__G?.ready);
if (special) await p.evaluate((s) => window.__voyage2d.special(s), special);
await p.waitForTimeout(+wait);
if (process.env.TAPS) for (let i = 0; i < +process.env.TAPS; i++) (await p.evaluate(() => window.__voyage2d.battle.tap()), await p.waitForTimeout(260));
if (process.env.TAPS) await p.waitForTimeout(260);
const pos = await p.evaluate(() => {
  const v = window.__voyage2d, W = v.world, cam = v.camera;
  window.__G.paused = true;
  W.hidePennants = true;
  window.__noStageHint = true;
  document.body.classList.add("nohud");
  document.querySelector("#special")?.setAttribute("hidden", "");
  const out = [];
  for (const [id, pp] of Object.entries(W.crew)) {
    const [fx, fy] = W.ship.toWorld(pp.x, pp.y);
    const [sx, sy] = cam.toScreen(fx, fy);
    out.push({ id, key: pp.bakeKey, x: sx, y: sy, h: pp.height * cam.zoom, dir: pp.dir });
    pp.alpha = 0;
  }
  return out;
});
await p.waitForTimeout(120);
await p.screenshot({ path: `concept/${name}.png` });
const vw = await p.evaluate(() => innerWidth);
writeFileSync(`concept/${name}.json`, JSON.stringify({ vw, pos }));
console.log(name, pos.length);
await b.close();
