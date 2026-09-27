// Walk jitter: the captain under control (right, then left) and a hand walking across the ship,
// stepped frame by frame at 60 fps with the game loop paused, so the numbers are deterministic.
// For each walker, per frame: both hands relative to his feet (ship px), his dir, the walk cycle.
//   node tools/walkjitter.mjs [url] [out.json]
// Prints: hand jerk (RMS and max second difference, px/frame^2), max per-frame hand move
// relative to the body (px), dir flips per second, and the step cadence (Hz).
import { createRequire } from "node:module";
import { writeFileSync } from "node:fs";
const require = createRequire(import.meta.url);
const { chromium } = require("playwright");
const url = process.argv[2] || "http://127.0.0.1:8766/artifact-2d.html";
const out = process.argv[3];

export async function measure(page) {
  return page.evaluate(() => {
    const V = window.__voyage2d, W = V.world, G = window.__G, h = 1 / 60;
    G.paused = true;
    const rec = (p) => {
      const r = p.jointAt("hand_r"), l = p.jointAt("hand_l");
      return { rx: r[0] - p.x, ry: r[1] - p.y, lx: l[0] - p.x, ly: l[1] - p.y, dir: p.dir, loco: p.locoW, ph: p.walkPhase, x: p.x, sc: p.scale };
    };
    const step = (n, each) => { for (let i = 0; i < n; i++) { V.helm.update(h); W.update(h); each?.(i); } };
    const runs = {};
    // settle
    step(60);
    // 1) the captain under control: 2 s right, 0.5 s still, 2 s left, 0.5 s still
    V.helm.enter();
    const cap = W.crew.captain, cf = [];
    const hold = (key, n) => { V.helm.held.clear(); if (key) V.helm.held.add(key); step(n, () => cf.push(rec(cap))); };
    hold("ArrowRight", 120); hold(null, 30); hold("ArrowLeft", 120); hold(null, 30);
    V.helm.leave({ quiet: true });
    runs.captain = { frames: cf, segs: [[0, 120, 1], [150, 270, -1]] };
    // 2) a hand walks: the first worker to the far end of the waist and back
    const wk = Object.values(W.crew).find((p) => p.role === "worker");
    const a = W.agent(wk.id), d = W.G.decks[a.deck];
    const far = a.x - d.x0 > d.x1 - a.x ? d.x0 + 80 : d.x1 - 80;
    W.crowd.goTo(wk.id, { deck: a.deck, x: far, z: a.z });
    const nf = [];
    step(240, () => nf.push(rec(wk)));
    runs.npc = { id: wk.id, frames: nf };
    return runs;
  });
}

export function stats(frames, segs) {
  const moving = frames.map((f, i) => i > 0 && Math.abs(f.x - frames[i - 1].x) > 0.05);
  let n = 0, s2 = 0, mx2 = 0, mx1 = 0, flips = 0, walkFrames = 0;
  for (let i = 2; i < frames.length; i++) {
    const a = frames[i - 2], b = frames[i - 1], c = frames[i];
    if (b.dir !== c.dir) flips++;
    if (!moving[i]) continue;
    walkFrames++;
    // the jitter is only read while facing one way (a turn is its own event)
    if (a.dir !== b.dir || b.dir !== c.dir) continue;
    for (const k of ["r", "l"]) {
      const jx = c[k + "x"] - 2 * b[k + "x"] + a[k + "x"], jy = c[k + "y"] - 2 * b[k + "y"] + a[k + "y"];
      const j = Math.hypot(jx, jy), d1 = Math.hypot(c[k + "x"] - b[k + "x"], c[k + "y"] - b[k + "y"]);
      s2 += j * j; n++;
      mx2 = Math.max(mx2, j); mx1 = Math.max(mx1, d1);
    }
  }
  // cadence: footfalls (half cycles of walkPhase) per second while walking
  const ph = frames.filter((f, i) => moving[i]).map((f) => f.ph);
  const steps = ph.length > 1 ? ph[ph.length - 1] - ph[0] : 0;
  const secs = walkFrames / 60;
  const flipsIn = (a, b) => { let k = 0; for (let i = a + 1; i < b; i++) if (frames[i].dir !== frames[i - 1].dir) k++; return k; };
  return {
    jerkRms: +Math.sqrt(s2 / Math.max(1, n)).toFixed(2),
    jerkMax: +mx2.toFixed(2),
    handStepMax: +mx1.toFixed(2),
    dirFlipsPerSec: +(flips / (frames.length / 60)).toFixed(2),
    flipsHoldingOneWay: segs ? segs.map(([a, b]) => flipsIn(a + 6, b)).reduce((x, y) => x + y, 0) : null,
    stepsPerSec: +(steps / Math.max(1e-3, secs)).toFixed(2),
    scale: +frames[0].sc.toFixed(3),
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const browser = await chromium.launch();
  const res = {};
  for (const q of ["driver=0&crew=12", "driver=0&crew=12&style=manga"]) {
    const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    const page = await ctx.newPage();
    const errs = [];
    page.on("pageerror", (e) => errs.push(e.message));
    await page.goto(url + "?" + q);
    await page.waitForFunction(() => window.__G?.ready, null, { timeout: 60000 });
    await page.waitForTimeout(1500);
    const runs = await measure(page);
    res[q] = { captain: stats(runs.captain.frames, runs.captain.segs), npc: { id: runs.npc.id, ...stats(runs.npc.frames) }, errs };
    if (out && q === "driver=0&crew=12") writeFileSync(out.replace(/\.json$/, ".frames.json"), JSON.stringify(runs));
    await ctx.close();
  }
  await browser.close();
  console.log(JSON.stringify(res, null, 1));
  if (out) writeFileSync(out, JSON.stringify(res, null, 1));
}
