// The big ship's proof shots (proofs/big-ship-*.png), taken from the built artifact:
//   node tools/bigship-proofs.mjs [name ...]      (all of them with no name)
// whole: the whole ship zoomed out (desktop 1440x900); through: the captain walking through a
// line of his crew; cabin: the captain's cabin with a decision waiting; crew24: 24 hands at work
// through the rooms; phone: 390x844 in low detail; embed: the 1400x420 panel; galleon: the
// example galleon mod; plus rooms (a close shot), crimson (the skin mod) and battle.
import { createServer } from "node:http";
import { readFileSync, existsSync, mkdirSync } from "node:fs";
import { createRequire } from "node:module";
import { join, extname } from "node:path";

const { chromium } = createRequire(import.meta.url)("playwright");
const ROOT = new URL("..", import.meta.url).pathname, OUT = join(ROOT, "proofs");
mkdirSync(OUT, { recursive: true });
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".json": "application/json", ".png": "image/png" };
const server = createServer((req, res) => {
  const f = join(ROOT, decodeURIComponent(req.url.split("?")[0]));
  if (!existsSync(f)) return res.writeHead(404).end();
  res.writeHead(200, { "content-type": TYPES[extname(f)] || "application/octet-stream" }).end(readFileSync(f));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}/artifact-2d.html?`;
const browser = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });

async function shot(name, q, viewport, setup, { wait = 1500 } = {}) {
  const ctx = await browser.newContext({ viewport });
  const p = await ctx.newPage();
  const errs = [];
  p.on("pageerror", (e) => errs.push(e.message));
  p.on("console", (m) => m.type() === "error" && errs.push(m.text()));
  await p.goto(base + q);
  await p.waitForFunction(() => window.__G?.ready, null, { timeout: 60000 });
  await p.evaluate(() => window.__voyage2d.ui.dismissCaption?.());
  const info = setup ? await setup(p) : null;
  await p.waitForTimeout(wait);
  await p.screenshot({ path: join(OUT, `big-ship-${name}.png`) });
  console.log(JSON.stringify({ name, info, errs }));
  await ctx.close();
}
const D = { width: 1440, height: 900 };
const SHOTS = {
  // the whole ship of the line, masthead to keel, stern to jib-boom
  whole: () => shot("whole-desktop", "driver=0&crew=24&seed=7", D, async (p) => {
    await p.keyboard.press("z");
    await p.waitForTimeout(3000);
    return p.evaluate(() => ({ cls: window.__voyage2d.world.cls.id, zoom: window.__voyage2d.camera.zoom }));
  }),
  // the captain has the deck and runs aft to fore through a line of hands across the waist:
  // taken as he passes behind them
  through: () => shot("captain-through-crew", "driver=0&crew=24", D, async (p) => {
    await p.keyboard.press("q");
    const set = await p.evaluate(() => {
      const W = window.__voyage2d.world, C = W.crowd, S = W.ship.spec, cap = C.get("captain");
      const x0 = S.main[0] + 450;
      Object.assign(cap, { deck: "main", x: x0, z: 200, link: null, goal: null, plan: null });
      Object.values(W.crew).filter((c) => c.role === "worker").slice(0, 12).forEach((h, i) => {
        W.pinned.add(h.id);
        const a = C.get(h.id);
        C.stop(h.id);
        // (two files, near and far: he takes the middle lane between them and is drawn between)
        const x = x0 + 520 + Math.floor(i / 2) * 260, z = [70, 330][i % 2];
        if (C.free("main", x, z, a.r, a)) Object.assign(a, { deck: "main", x, z, link: null });
        h.setLoop("lean");
      });
      return { from: x0, first: x0 + 520 };
    });
    await p.waitForTimeout(1500);
    await p.keyboard.down("ArrowRight");
    await p.waitForFunction((x) => window.__voyage2d.world.agent("captain").x > x, set.first + 520 + 8, { timeout: 20000 });
    await p.evaluate(() => (window.__G.paused = true));
    await p.keyboard.up("ArrowRight");
    return p.evaluate(() => { const a = window.__voyage2d.world.agent("captain"); return { x: Math.round(a.x), z: Math.round(a.z) }; });
  }, { wait: 300 }),
  // a decision waits: the captain at his desk in the great cabin, the card on it (the card itself
  // folded into the deck at the bottom right, so the cabin shows)
  cabin: () => shot("cabin-decision", "scene=decision&driver=0&crew=12", D, async (p) => {
    await p.evaluate(() => { window.__G.speed = 0; });
    await p.waitForFunction(() => { const W = window.__voyage2d.world, a = W.agent("captain"); return W.stationOf("captain")?.kind === "cabin" && !a.goal && !a.link; }, null, { timeout: 60000 });
    await p.evaluate(() => { const V = window.__voyage2d; V.ui.minimise(); V.director.cinematic = false; const W = V.world, d = W.G.props.find((q) => q.kind === "desk"), [x, y] = W.ship.toWorld(d.x + 200, W.G.decks[d.deck].y - 230); V.camera.go({ x, y, h: 1150 }, { cut: true }); });
    return p.evaluate(() => ({ decisions: window.__voyage2d.sim.decisions.map((d) => d.id + ":" + d.kind) }));
  }, { wait: 1200 }),
  // 24 hands on a busy voyage: at work in the waist, at the gates, in review up the masts, at rest
  crew24: () => shot("24-crew", "crew=24&speed=3&seed=11", D, async (p) => {
    await p.evaluate(() => window.__voyage2d.setHands(24)); // (the captain sets the hands: nobody goes ashore)
    await p.waitForTimeout(40000);
    await p.evaluate(() => { const V = window.__voyage2d; V.ui.minimise?.(); V.director.cinematic = false; V.camera.go(V.director.frames().wide(), { cut: true }); window.__G.paused = true; });
    return p.evaluate(() => { const W = window.__voyage2d.world, k = {}; for (const c of Object.values(W.crew)) { const s = W.stationOf(c.id)?.kind || "-"; k[s] = (k[s] || 0) + 1; } return { stations: k, bad: W.crowd.violations().length }; });
  }, { wait: 400 }),
  phone: () => shot("phone", "driver=0&crew=12&detail=low", { width: 390, height: 844 }, null, { wait: 2500 }),
  "phone-whole": () => shot("phone-whole", "driver=0&crew=12&detail=low", { width: 390, height: 844 }, async (p) => { await p.keyboard.press("z"); }, { wait: 3000 }),
  embed: () => shot("embed-1400x420", "embed=1&crew=18&driver=0", { width: 1400, height: 420 }, null, { wait: 3000 }),
  galleon: () => shot("galleon-mod", "mod=galleon&driver=0&crew=24", D, async (p) => { await p.keyboard.press("z"); }, { wait: 3000 }),
  "galleon-rooms": () => shot("galleon-mod-rooms", "mod=galleon&crew=24&speed=3", D, async (p) => { await p.waitForTimeout(20000); await p.evaluate(() => { const V = window.__voyage2d; V.ui.minimise?.(); V.director.cinematic = false; V.camera.go(V.director.frames().wide(), { cut: true }); }); }, { wait: 1500 }),
  rooms: () => shot("rooms-closeup", "driver=0&crew=18", D, async (p) => {
    await p.evaluate(() => { const V = window.__voyage2d; V.director.cinematic = false; const S = V.world.ship, [x, y] = S.toWorld(S.spec.stern + S.spec.len * 0.2, 300); V.camera.go({ x, y, h: 2300 }, { cut: true }); });
  }, { wait: 3000 }),
  crimson: () => shot("crimson-mod", "mod=crimson-crew&driver=0&crew=12&scene=decision", D, async (p) => {
    await p.evaluate(() => { window.__G.speed = 0; const V = window.__voyage2d; V.ui.minimise(); V.director.cinematic = false; });
    await p.waitForTimeout(1500);
    await p.evaluate(() => { const V = window.__voyage2d, W = V.world, f = W.crew.firstmate, [x, y] = W.at(f, "torso"); V.camera.go({ x: x + 500, y: y - 250, h: 1300 }, { cut: true }); });
  }, { wait: 1500 }),
  battle: () => shot("battle", "scene=battle&crew=24", D, null, { wait: 3500 }),
  // v2d-12 (the captain's notes on v2d-11): the kraken in the embed panel, the embed's own controls,
  // a run through the crew, the merge salvo, the class change pulling back to the whole ship
  "embed-kraken": () => shot("embed-kraken", "embed=1&crew=12&speed=3", { width: 1400, height: 420 }, async (p) => {
    await p.waitForFunction(() => window.__voyage2d.sim.kraken.arms.length > 0, null, { timeout: 120000, polling: 200 });
    await p.evaluate(() => (window.__G.speed = 1));
    await p.waitForTimeout(5000);
    return p.evaluate(() => ({ simT: Math.round(window.__voyage2d.sim.t), eye: window.__voyage2d.camera.toScreen(...window.__voyage2d.world.kraken.eyePos()).map(Math.round) }));
  }, { wait: 200 }),
  "embed-controls": () => shot("embed-controls", "embed=1&crew=18&driver=0", { width: 1400, height: 420 }, async (p) => {
    await p.click("#qDeck");
    await p.waitForTimeout(1500);
  }, { wait: 800 }),
  "embed-settings": () => shot("embed-settings", "embed=1&crew=18&driver=0", { width: 1400, height: 420 }, async (p) => {
    await p.click("#menuBtn");
    await p.click('#menu [data-tab="settings"]');
    await p.evaluate(() => { const b = document.querySelector("#sheetBody"); b.scrollTop = b.scrollHeight; });
  }, { wait: 400 }),
  run: () => shot("run-through-crew", "driver=0&crew=24", D, async (p) => {
    await p.keyboard.press("q");
    await p.evaluate(() => {
      const W = window.__voyage2d.world, C = W.crowd, S = W.ship.spec, cap = C.get("captain"), x0 = S.main[0] + 300;
      Object.assign(cap, { deck: "main", x: x0, z: 200, link: null, goal: null, plan: null });
      Object.values(W.crew).filter((c) => c.role === "worker").slice(0, 14).forEach((h, i) => { W.pinned.add(h.id); const a = C.get(h.id); C.stop(h.id); const x = x0 + 900 + Math.floor(i / 2) * 240, z = [70, 330][i % 2]; if (C.free("main", x, z, a.r, a)) Object.assign(a, { deck: "main", x, z, link: null }); h.setLoop("lean"); });
    });
    await p.waitForTimeout(1200);
    await p.keyboard.down("Shift");
    await p.keyboard.down("ArrowRight");
    await p.waitForTimeout(1300);
    await p.evaluate(() => (window.__G.paused = true));
    await p.keyboard.up("ArrowRight");
    await p.keyboard.up("Shift");
    return p.evaluate(() => ({ runW: +window.__voyage2d.world.crew.captain.runW.toFixed(2), v: Math.round(window.__voyage2d.world.crew.captain.locoSpeed) }));
  }, { wait: 200 }),
  salvo: () => shot("salvo", "scene=merge&crew=24", D, async (p) => { await p.evaluate(() => window.__voyage2d.ui.minimise()); await p.waitForTimeout(2300); return p.evaluate(() => window.__voyage2d.director.shot); }, { wait: 0 }),
  "salvo-embed": () => shot("salvo-embed", "scene=merge&crew=12&embed=1", { width: 1400, height: 420 }, async (p) => { await p.waitForTimeout(2300); return p.evaluate(() => window.__voyage2d.director.shot); }, { wait: 0 }),
  // v2d-13: the whole battle in the 1400x420 embed, from the prompt to the victory card
  "embed-battle": async () => {
    const ctx = await browser.newContext({ viewport: { width: 1400, height: 420 } });
    const p = await ctx.newPage();
    const errs = [];
    p.on("pageerror", (e) => errs.push(e.message));
    await p.goto(base + "embed=1&crew=12&speed=10");
    await p.waitForFunction(() => window.__G?.ready);
    await p.waitForFunction(() => window.__voyage2d.sim.kraken.arms.length > 0, null, { timeout: 120000, polling: 200 });
    await p.evaluate(() => (window.__G.speed = 1));
    await p.waitForFunction(() => !document.querySelector("#prompt").hidden, null, { timeout: 20000 });
    await p.waitForTimeout(2500);
    const snap = (n) => p.screenshot({ path: join(OUT, `big-ship-embed-battle-${n}.png`) });
    await snap("1-prompt");
    await p.locator("#prompt").click();
    await p.waitForTimeout(3000);
    await snap("2-fight");
    await p.evaluate(() => (window.__botFight = true));
    await p.waitForFunction(() => window.__voyage2d.overlay.cuts.length > 0, null, { timeout: 60000, polling: 50 });
    await p.waitForTimeout(400);
    await snap("3-special");
    await p.waitForFunction(() => window.__voyage2d.battle.ending?.t > 2.6, null, { timeout: 150000 });
    await snap("4-hero");
    await p.waitForTimeout(1600);
    await snap("5-victory");
    console.log(JSON.stringify({ name: "embed-battle", errs }));
    await ctx.close();
  },
  // v2d-14: "All hands! Battle stations!", mid-run, and the bow manned, full screen and in the embed
  muster: async () => {
    for (const [tag, q, vp] of [["desktop", "scene=kraken&crew=24&driver=0", D], ["embed", "embed=1&scene=kraken&crew=18&driver=0", { width: 1400, height: 420 }]]) {
      const ctx = await browser.newContext({ viewport: vp });
      const p = await ctx.newPage();
      const errs = [];
      p.on("pageerror", (e) => errs.push(e.message));
      await p.goto(base + q);
      await p.waitForFunction(() => window.__G?.ready);
      await p.waitForTimeout(3000);
      if (tag === "embed") await p.locator("#prompt").click();
      else await p.locator('#decision .opt[data-key="A"]').click();
      await p.waitForTimeout(1300);
      await p.screenshot({ path: join(OUT, `big-ship-muster-${tag}-running.png`) });
      await p.waitForFunction(() => window.__voyage2d.world.mustered(), null, { timeout: 15000 });
      await p.waitForTimeout(1500);
      await p.screenshot({ path: join(OUT, `big-ship-muster-${tag}-manned.png`) });
      console.log(JSON.stringify({ name: "muster-" + tag, errs }));
      await ctx.close();
    }
  },
  // v2d-15: one exchange of the fight as a sequence of frames, full screen and in the embed
  exchange: async () => {
    for (const [tag, q, vp] of [["desktop", "scene=kraken&crew=24&driver=0", D], ["embed", "embed=1&scene=kraken&crew=18&driver=0", { width: 1400, height: 420 }]]) {
      const ctx = await browser.newContext({ viewport: vp });
      const p = await ctx.newPage();
      await p.goto(base + q);
      await p.waitForFunction(() => window.__G?.ready);
      await p.evaluate(() => window.__voyage2d.ui.minimise?.());
      await p.waitForTimeout(1500);
      await p.evaluate(() => { const V = window.__voyage2d, d = V.sim.decisions.find((x) => x.kind === "kraken"); V.source.command({ type: "answer", decision: d.id, chosen: "A" }); });
      await p.waitForFunction(() => window.__voyage2d.world.mustered(), null, { timeout: 15000 });
      await p.evaluate(() => { window.__botFight = true; window.__voyage2d.battle.shotLog.length = 0; });
      const got = new Set();
      for (let i = 0; i < 40 && got.size < 6; i++) {
        await p.waitForTimeout(300);
        const n = await p.evaluate(() => { const L = window.__voyage2d.battle.shotLog; return L.length ? L[L.length - 1].name : "two-shot"; });
        if (got.has(n)) continue;
        got.add(n);
        await p.screenshot({ path: join(OUT, `big-ship-exchange-${tag}-${got.size}-${n}.png`) });
      }
      console.log(JSON.stringify({ name: "exchange-" + tag, shots: [...got] }));
      await ctx.close();
    }
  },
  "class-change": () => shot("class-change", "driver=0&crew=12", D, async (p) => { await p.evaluate(() => window.__voyage2d.setHands(13)); await p.waitForTimeout(1900); }, { wait: 0 }),
  "class-change-embed": () => shot("class-change-embed", "driver=0&crew=12&embed=1", { width: 1400, height: 420 }, async (p) => { await p.evaluate(() => window.__voyage2d.setHands(13)); await p.waitForTimeout(1900); }, { wait: 0 }),
};
const want = process.argv.slice(2);
for (const [k, f] of Object.entries(SHOTS)) if (!want.length || want.includes(k)) await f();
await browser.close();
server.close();
