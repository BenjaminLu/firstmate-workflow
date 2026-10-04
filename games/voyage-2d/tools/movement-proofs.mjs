// Proof shots for the movement pass, into proofs/:
//   move-cutaway-<class>.png (+ -phone)     each class's cutaway, crew at rest over the decks
//   move-ladder-01..NN.png                  the captain walks down the stairs, the companionway and
//                                           the hold's ladder (a frame sequence), then up the shrouds
//   move-mini-<game>-<style>.png            each mini-game, Crimson and Manga
//   move-phone-joystick.png                 the phone pad (joystick, ▼ by a stair)
//   move-live-noprompt.png                  Live: walking, no prompt by a working hand
// node tools/movement-proofs.mjs [base]   (default http://127.0.0.1:8766/artifact-2d.html)
import { createRequire } from "node:module";
const { chromium } = createRequire(import.meta.url)("playwright");
const base = process.argv[2] || "http://127.0.0.1:8766/artifact-2d.html";
const OUT = new URL("../proofs/", import.meta.url).pathname;
const b = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });
const errs = [];
async function page(q, opts = { viewport: { width: 1440, height: 900 } }) {
  const ctx = await b.newContext(opts);
  const p = await ctx.newPage();
  p.on("pageerror", (e) => errs.push(q + ": " + e.message));
  p.on("console", (m) => m.type() === "error" && errs.push(q + ": " + m.text()));
  await p.goto(`${base}?${q}`);
  await p.waitForFunction(() => window.__G?.ready);
  await p.evaluate(() => { window.__voyage2d.ui.dismissCaption?.(); window.__G.welcome = false; });
  return { p, ctx };
}
const V = (p, fn, a) => p.evaluate(fn, a);
const rest = () => { const W = window.__voyage2d.world; return Object.values(W.crew).every((c) => !W.agent(c.id).goal && !W.agent(c.id).link); };

// 1. each class's cutaway: some hands sent to the guns, the rigging and the lookout
for (const [n, cls] of [[7, "sloop"], [12, "brig"], [18, "frigate"], [24, "line"]]) {
  for (const [vp, tag] of [[{ width: 1440, height: 900 }, ""], [{ width: 390, height: 844 }, "-phone"]]) {
    const { p, ctx } = await page(`driver=0&crew=${n}`, { viewport: vp });
    await V(p, (n) => { const V2 = window.__voyage2d, st = ["main", "amidships", "top", "main", "main", "amidships"]; for (let i = 1; i <= Math.min(6, n - 3); i++) V2.station("worker-" + i, st[i - 1], ["swab", "haul", "lookout", "hammer", "carry", "capstan"][i - 1]); }, n);
    await p.waitForFunction(rest, null, { timeout: 40000 });
    await p.waitForTimeout(1200);
    await p.screenshot({ path: `${OUT}move-cutaway-${cls}${tag}.png` });
    await ctx.close();
  }
}

// 2. the captain walks the decks: down the stairs, the companionway, the hold's ladder; up the shrouds
{
  const { p, ctx } = await page("driver=0&crew=12");
  await p.waitForTimeout(600);
  await p.keyboard.press("q");
  let frame = 0;
  const shot = async () => p.screenshot({ path: `${OUT}move-ladder-${String(++frame).padStart(2, "0")}.png` });
  const way = async (dir, kind = null) => {
    for (let i = 0; i < 90; i++) {
      const go = await V(p, ([dir, kind]) => {
        const V2 = window.__voyage2d, W = V2.world, a = W.agent("captain"), G = W.G, k = W.crowd.linkAt(a, dir);
        if (k && (!kind || k.L.kind === kind)) return 0;
        const ends = G.links.filter((l) => !kind || l.kind === kind).flatMap((l) => [[l.a, l.b], [l.b, l.a]]).filter(([e, o]) => e.deck === a.deck && (G.decks[o.deck].y > G.decks[e.deck].y) === (dir > 0)).map(([e]) => e);
        const e = ends.sort((p, q) => Math.abs(p.x - a.x) - Math.abs(q.x - a.x))[0];
        return Math.sign(e.x - a.x) || 1;
      }, [dir, kind]);
      if (!go) break;
      const key = go > 0 ? "ArrowRight" : "ArrowLeft";
      await p.keyboard.down(key);
      await p.waitForTimeout(90);
      await p.keyboard.up(key);
      if (i % 6 === 3) await shot();
    }
    await shot();
    await p.keyboard.press(dir < 0 ? "ArrowUp" : "ArrowDown");
    for (let i = 0; i < 6; i++) { await p.waitForTimeout(450); await shot(); }
    await p.waitForFunction(() => { const a = window.__voyage2d.world.agent("captain"); return !a.link && a.manual; }, null, { timeout: 20000 });
  };
  await way(1); await way(1); await way(1); // qd -> main -> gun -> hold
  await way(-1); await way(-1); await way(-1, "shrouds"); // hold -> gun -> main -> the nest
  await p.waitForTimeout(600);
  await shot();
  console.log("ladder frames", frame);
  await ctx.close();
}

// 3. each mini-game, both styles (the game half played, so it reads)
for (const style of ["crimson", "manga"]) {
  const { p, ctx } = await page(`driver=0&crew=12&style=${style}`);
  for (const [kind, who, st, lang] of [["gun", "worker-1", "main", "en"], ["rig", "worker-2", "amidships", "zh-TW"], ["nest", "worker-3", "top", "zh-CN"], ["stamp", "reviewer-1", null, "en"]]) {
    await V(p, (l) => window.__voyage2d.ui.setLang(l), lang);
    if (st) await V(p, ([w, s]) => window.__voyage2d.station(w, s, "idle"), [who, st]);
    await p.waitForFunction((w) => { const a = window.__voyage2d.world.agent(w); return !a.goal && !a.link; }, who, { timeout: 30000 });
    await V(p, (w) => { window.__voyage2d.helm.toggle(true); window.__voyage2d.placeCaptain(w); }, who);
    await p.waitForTimeout(1300);
    if (kind === "gun" && style === "crimson") await p.screenshot({ path: `${OUT}move-prompt-gun.png` });
    await p.keyboard.press("e");
    await V(p, () => (window.__miniBot = true));
    await p.waitForTimeout(kind === "stamp" ? 2600 : 700);
    await V(p, () => (window.__miniBot = false));
    await p.screenshot({ path: `${OUT}move-mini-${kind}-${style}.png` });
    await p.keyboard.press("Escape");
    await p.keyboard.press("q");
    await p.waitForTimeout(300);
  }
  await ctx.close();
}

// 4. the phone pad
{
  const { p, ctx } = await page("driver=0&crew=12", { viewport: { width: 390, height: 844 }, hasTouch: true });
  await p.waitForTimeout(600);
  const at = await V(p, () => window.__voyage2d.ui.h.crewAt("captain"));
  await p.touchscreen.tap(at[0], at[1] + 30);
  const s = await p.locator("#helmPad .stick").boundingBox();
  await p.mouse.move(s.x + s.width / 2, s.y + s.height / 2);
  await p.mouse.down();
  await p.mouse.move(s.x + s.width / 2 + 50, s.y + s.height / 2, { steps: 4 });
  for (let i = 0; i < 40 && !(await p.locator('#helmPad [data-h="down"]').isVisible()); i++) await p.waitForTimeout(100);
  await p.screenshot({ path: `${OUT}move-phone-joystick.png` });
  await p.mouse.up();
  await ctx.close();
}

// 5. Live: he walks, but no prompt by a working hand
{
  const { p, ctx } = await page("driver=0&crew=12");
  await V(p, () => { window.__voyage2d.ui.h.mode = () => "live"; window.__voyage2d.station("worker-1", "main", "swab"); });
  await p.waitForFunction(() => { const a = window.__voyage2d.world.agent("worker-1"); return !a.goal && !a.link; }, null, { timeout: 30000 });
  await V(p, () => { window.__voyage2d.helm.toggle(true); window.__voyage2d.placeCaptain("worker-1"); });
  await p.waitForTimeout(1300);
  await p.screenshot({ path: `${OUT}move-live-noprompt.png` });
  await ctx.close();
}
console.log(JSON.stringify({ errs }));
await b.close();
