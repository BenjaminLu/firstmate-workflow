// The big ship in the built artifact (the captain's "船需要變得超大 人變得超小"): the captain walks
// the waist through a line of his crew and arrives; the crew's stations follow their workflow
// state; the camera follows him and zooms out to the whole ship (desktop, a phone in low detail,
// the 1400x420 embed panel); and mods load (bundled with ?mod=, or the player's own file), are
// refused with their errors when they fail validation, and reset to the default. Serves itself.
import nodeTest from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFileSync, existsSync } from "node:fs";
import { createRequire } from "node:module";
import { join, extname } from "node:path";

// Prefer the same installed package and browser as the board e2e runner.
const requireBrowser = createRequire(import.meta.url);
let browserTools;
try { browserTools = requireBrowser("@playwright/test"); }
catch (error) {
  if (error.code !== "MODULE_NOT_FOUND") throw error;
  try { browserTools = requireBrowser("playwright"); }
  catch (fallback) { if (fallback.code !== "MODULE_NOT_FOUND") throw fallback; }
}
const { chromium, devices } = browserTools || {};
const skipBrowser = !chromium ? "Playwright is not installed"
  : !existsSync(chromium.executablePath()) ? "Chromium is not installed; run bunx playwright install chromium" : false;
const test = Object.assign((name, fn) => nodeTest(name, {skip: skipBrowser}, fn), {
  before: nodeTest.before, after: nodeTest.after,
});
const ARTIFACT = process.env.VOYAGE_PLAYGROUND || "artifact-2d.html";
const ROOT = new URL("..", import.meta.url).pathname;
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".json": "application/json", ".png": "image/png" };
let server, base, browser;
test.before(async () => {
  if (skipBrowser) return;
  server = createServer((req, res) => {
    const path = decodeURIComponent(req.url.split("?")[0]);
    const f = join(ROOT, path === "/artifact-2d.html" ? ARTIFACT : path);
    if (!existsSync(f)) return res.writeHead(404).end();
    res.writeHead(200, { "content-type": TYPES[extname(f)] || "application/octet-stream" }).end(readFileSync(f));
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  base = `http://127.0.0.1:${server.address().port}/`;
  browser = await chromium.launch();
});
test.after(async () => { await browser?.close(); server?.close(); });

async function open(q, ctxOpts = { viewport: { width: 1440, height: 900 } }, ctx = null) {
  ctx ||= await browser.newContext(ctxOpts);
  const p = await ctx.newPage();
  const errs = [];
  p.on("pageerror", (e) => errs.push(e.message));
  p.on("console", (m) => m.type() === "error" && !/Content Security Policy|example\.com|ERR_FAILED/.test(m.text()) && errs.push(m.text()));
  await p.goto(base + "artifact-2d.html?" + q);
  await p.waitForFunction(() => window.__G?.ready, null, { timeout: 60000 });
  return { p, ctx, errs };
}
const V = (p, fn, arg) => p.evaluate(fn, arg);

test("the captain walks the length of the waist through a line of his crew standing across it, and arrives", async () => {
  const { p, ctx, errs } = await open("driver=0&crew=24");
  await p.waitForTimeout(400);
  await p.keyboard.press("q");
  // the captain at the aft end of the waist; ten hands in a wall across it, three deep, pinned
  const set = await V(p, () => {
    const V2 = window.__voyage2d, W = V2.world, C = W.crowd, S = W.ship.spec, cap = C.get("captain");
    const x0 = S.main[0] + 450, x1 = S.main[1] - 350;
    Object.assign(cap, { deck: "main", x: x0, z: 200, link: null, goal: null, plan: null });
    const hands = Object.values(W.crew).filter((c) => c.role === "worker").slice(0, 12);
    const line = [];
    hands.forEach((h, i) => {
      W.pinned.add(h.id);
      const a = C.get(h.id);
      C.stop(h.id);
      const x = x0 + 500 + Math.floor(i / 4) * 900, z = [70, 150, 230, 320][i % 4];
      if (C.free("main", x, z, a.r, a)) Object.assign(a, { deck: "main", x, z, link: null });
      line.push({ id: h.id, x: a.x, deck: a.deck });
    });
    return { x0, x1, line: line.filter((l) => l.deck === "main") };
  });
  assert.ok(set.line.length >= 9, `a line of ${set.line.length} across the waist`);
  await p.keyboard.down("Shift");
  await p.keyboard.down("ArrowRight");
  await p.waitForFunction((x1) => window.__voyage2d.world.agent("captain").x > x1, set.x1, { timeout: 30000 });
  await p.keyboard.up("ArrowRight");
  await p.keyboard.up("Shift");
  const r = await V(p, (ids) => ({ bad: window.__voyage2d.world.crowd.violations(), x: window.__voyage2d.world.agent("captain").x, still: ids.map((id) => window.__voyage2d.world.agent(id).deck) }), set.line.map((l) => l.id));
  assert.deepEqual(r.bad, [], "nobody in anything or on each other");
  assert.ok(r.still.every((d) => d === "main"), "the crew stood their ground: he passed them");
  assert.deepEqual(errs, []);
  await ctx.close();
});

// The captain's "船長不能跑了" (v2d-11): from the wheel, → with the run held carries him off the
// quarterdeck, down its stairs and forward along the waist past his crew, much further than a walk
// does in the same time; with the keys on a desktop and with the stick at its rim on a phone. On
// v2d-11 he stood at the quarterdeck's forward rail after a second and a half (the stairs wanted ↓),
// at 540 a second.
test("the run: from the wheel, Shift + → (or the stick at its rim) runs him down to the waist and forward, much further than a walk", async () => {
  const far = async (p, go) => {
    await V(p, () => { const V2 = window.__voyage2d, W = V2.world, a = W.crowd.get("captain"), h = W.home(W.crew.captain); V2.helm.toggle(true); Object.assign(a, { deck: h.deck, x: h.x, z: h.z, link: null, goal: null, plan: null }); });
    await p.waitForTimeout(200);
    const stop = await go();
    await p.waitForTimeout(4000);
    await stop();
    return V(p, () => { const W = window.__voyage2d.world, a = W.agent("captain"); return { deck: a.deck, x: a.x, into: a.x - W.ship.spec.main[0] }; });
  };
  {
    const { p, ctx, errs } = await open("driver=0&crew=24");
    await p.waitForTimeout(500);
    const keys = (run) => async () => { if (run) await p.keyboard.down("Shift"); await p.keyboard.down("ArrowRight"); return async () => { await p.keyboard.up("ArrowRight"); if (run) await p.keyboard.up("Shift"); }; };
    const walk = await far(p, keys(false)), run = await far(p, keys(true));
    assert.equal(run.deck, "main", "the run took him down to the waist: " + JSON.stringify(run));
    assert.ok(run.into > 3500, `4 s of running from the wheel: ${run.into.toFixed(0)} along the waist`);
    assert.ok(run.into > (walk.deck === "main" ? walk.into : 0) + 2000, `further than the walk: ${JSON.stringify({ walk, run })}`);
    assert.deepEqual(await V(p, () => window.__voyage2d.world.crowd.violations()), []);
    assert.deepEqual(errs, []);
    await ctx.close();
  }
  {
    const { p, ctx, errs } = await open("driver=0&crew=24", { viewport: { width: 390, height: 844 }, hasTouch: true });
    await p.waitForTimeout(500);
    await V(p, () => window.__voyage2d.helm.toggle(true));
    const stick = await p.locator("#helmPad .stick").boundingBox();
    const cx = stick.x + stick.width / 2, cy = stick.y + stick.height / 2;
    const push = (k) => async () => { await p.mouse.move(cx, cy); await p.mouse.down(); await p.mouse.move(cx + stick.width * k, cy, { steps: 3 }); return async () => p.mouse.up(); };
    const walk = await far(p, push(0.3)), run = await far(p, push(0.6));
    assert.equal(run.deck, "main", "the stick at its rim ran him down to the waist: " + JSON.stringify(run));
    assert.ok(run.into > (walk.deck === "main" ? walk.into : 0) + 2000, `the stick's run beats its walk: ${JSON.stringify({ walk, run })}`);
    assert.deepEqual(errs, []);
    await ctx.close();
  }
});

test("the crew's stations follow their workflow: a red gate to the gun deck, a review to a crow's nest, a call to the captain's cabin, idle to the quarters; a decision takes the captain to his desk", async () => {
  const { p, ctx, errs } = await open("driver=0&crew=12");
  await p.waitForTimeout(400);
  const place = (id) => V(p, (id) => { const W = window.__voyage2d.world, a = W.agent(id), s = W.stationOf(id); const room = W.G.rooms.find((r) => r.deck === a.deck && a.x >= r.x0 && a.x <= r.x1); return { kind: s?.kind, deck: a.deck, room: room?.kind, walking: !!(a.goal || a.link) }; }, id);
  // (the ship is long: a walk from one end to a crow's nest can take half a minute)
  const settle = async (id, kind) => {
    try { await p.waitForFunction(([id, kind]) => { const W = window.__voyage2d.world, a = W.agent(id); return W.stationOf(id)?.kind === kind && !a.goal && !a.link; }, [id, kind], { timeout: 60000 }); }
    catch (e) { throw new Error(`${id} never settled at a ${kind} station: ${JSON.stringify(await place(id))}`); }
  };
  for (const [state, kind, room] of [["blocked", "gate", "gundeck"], ["standby", "review", "nest"], ["waiting", "visit", null], ["idle", "rest", null]]) {
    await V(p, (state) => { const c = window.__voyage2d.sim.crew.find((x) => x.id === "worker-2"); c.state = state; c.station = "main"; }, state);
    await settle("worker-2", kind);
    const q = await place("worker-2");
    if (room) assert.equal(q.room, room, `${state}: ${JSON.stringify(q)}`);
    if (kind === "visit") assert.ok(["cabin", "chart"].includes(q.room), `waiting on the captain: in his cabin or the chart room (${q.room})`);
    if (kind === "rest") assert.ok(["quarters", "galley"].includes(q.room), `idle: in the quarters or the galley (${q.room})`);
  }
  // a decision waits: the captain goes to his desk in the great cabin, and back to the helm after
  await V(p, () => window.__voyage2d.stage("decision"));
  await settle("captain", "cabin");
  assert.equal((await place("captain")).room, "cabin");
  assert.ok(await V(p, () => window.__voyage2d.world.ship.decision), "the card lies on his desk");
  // (the voyage held still, so no new card comes up meanwhile)
  await V(p, () => { const V2 = window.__voyage2d; V2.G.speed = 0; for (let i = 0; i < 6 && V2.sim.decisions.length; i++) for (const d of V2.sim.decisions.slice()) V2.apply({ type: "answer", decision: d.id, key: d.kind === "merge" ? "C" : "A" }); return V2.sim.decisions.length; });
  assert.equal(await V(p, () => window.__voyage2d.sim.decisions.length), 0, "every card answered");
  await settle("captain", "helm");
  assert.equal((await place("captain")).deck, "qd");
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("the camera: it follows the captain, Z (or ⤢) shows the whole ship and back, the wheel zooms; desktop, a phone in low detail, and the embed panel", async () => {
  // the whole ship inside the screen: stern to jib-boom, masthead to keel
  const whole = (p) => V(p, () => { const V2 = window.__voyage2d, S = V2.world.ship, sp = S.spec; const pts = [[sp.stern, sp.bottom], [sp.bow + sp.len * 0.19, sp.bottom], [sp.stern, Math.min(...sp.masts.map((m) => m.top))]].map(([x, y]) => V2.camera.toScreen(...S.toWorld(x, y))); return pts.every(([x, y]) => x >= -2 && x <= innerWidth + 2 && y >= -2 && y <= innerHeight + 2); });
  for (const [vp, q] of [[{ width: 1440, height: 900 }, "driver=0&crew=24"], [{ width: 390, height: 844 }, "driver=0&crew=24&detail=low"]]) {
    const { p, ctx, errs } = await open(q, { viewport: vp });
    await p.waitForTimeout(500);
    assert.equal(await whole(p), false, `${vp.width}: the default shot is closer than the whole ship`);
    await p.keyboard.press("z");
    await p.waitForTimeout(2500);
    assert.ok(await whole(p), `${vp.width}: Z shows the whole ship`);
    assert.equal(await p.locator("#zoomBtn").getAttribute("aria-pressed"), "true");
    await p.locator("#zoomBtn").click();
    await p.waitForTimeout(2500);
    assert.equal(await whole(p), false, `${vp.width}: and back`);
    // the captain takes the deck: the camera is on him, close enough to read the deck
    await p.keyboard.press("q");
    await p.waitForTimeout(2000);
    const f = await V(p, () => { const V2 = window.__voyage2d, [x, y] = V2.world.at(V2.world.crew.captain, "torso"), [sx, sy] = V2.camera.toScreen(x, y); return { sx, sy, h: V2.world.crew.captain.height * V2.camera.zoom }; });
    assert.ok(Math.abs(f.sx - vp.width / 2) < 60 && Math.abs(f.sy - vp.height / 2) < 120, "on him: " + JSON.stringify(f));
    assert.ok(f.h > 60, `he reads: ${f.h.toFixed(0)} px tall`);
    // the wheel zooms out and in
    const h0 = await V(p, () => window.__voyage2d.camera.def.h);
    await p.mouse.move(vp.width / 2, vp.height / 2);
    await p.mouse.wheel(0, 600);
    await p.waitForTimeout(200);
    assert.ok((await V(p, () => window.__voyage2d.camera.def.h)) > h0 * 1.5, "the wheel zooms out");
    await p.keyboard.press("z");
    await p.waitForTimeout(2500);
    assert.ok(await whole(p), `${vp.width}: Z shows the whole ship while he has the deck`);
    if (vp.width < 500) assert.equal(await V(p, () => window.__voyage2d.perf().detail), "low");
    assert.deepEqual(errs, []);
    await ctx.close();
  }
  // the embed panel: no HUD, and the whole hull, stern to stem, in a wide short panel
  const { p, ctx, errs } = await open("embed=1&driver=0&crew=18", { viewport: { width: 1400, height: 420 } });
  await p.waitForTimeout(2500);
  // (the board shows the counters and the card; the game keeps its own controls, see below)
  for (const sel of ["#status", "#decision"]) assert.ok(!(await p.locator(sel).first().isVisible()), sel + " hidden in the embed");
  const hull = await V(p, () => { const V2 = window.__voyage2d, S = V2.world.ship, sp = S.spec; return [[sp.stern, sp.bottom], [sp.bow, sp.bottom], [sp.stern, sp.qd[2]]].map(([x, y]) => V2.camera.toScreen(...S.toWorld(x, y))); });
  assert.ok(hull.every(([x, y]) => x >= 0 && x <= 1400 && y >= 0 && y <= 420), "the hull in the panel: " + JSON.stringify(hull.map((q) => q.map(Math.round))));
  assert.ok(hull[1][0] - hull[0][0] > 900, "and it fills it");
  assert.deepEqual(errs, []);
  await ctx.close();
});

// The captain's 「原本遊戲內的操控面板 設定不見了」: ?embed=1 hides only what the host board shows itself
// (the decision card and its deck, the status counters); the game's own controls stay, in one
// compact row that fits the 1400x420 panel: language, sound, style, take the deck, the whole ship,
// the menu with Settings and mods. Outside the embed nothing is hidden and the quick row is not
// needed (sound and style live in Settings, the captain is tapped).
test("the embed keeps its controls: language, sound, style, take the deck, whole ship, the menu and Settings with mods; it hides only the card and the counters", async () => {
  const { p, ctx, errs } = await open("embed=1&driver=0&crew=18&scene=decision", { viewport: { width: 1400, height: 420 } });
  await p.waitForTimeout(800);
  const box = (sel) => p.evaluate((sel) => { const e = document.querySelector(sel); if (!e) return null; const b = e.getBoundingClientRect(), cs = getComputedStyle(e); return cs.display === "none" || !b.width ? null : [b.left, b.top, b.right, b.bottom].map(Math.round); }, sel);
  const ctl = ["#qSound", "#qStyle", "#qDeck", '#lang [data-lang="zh-TW"]', "#zoomBtn", "#menuBtn"];
  const boxes = [];
  for (const sel of ctl) {
    const b = await box(sel);
    assert.ok(b, `${sel} shows in the embed`);
    assert.ok(b[0] >= 0 && b[1] >= 0 && b[2] <= 1400 && b[3] <= 420, `${sel} inside the panel: ${b}`);
    assert.ok(b[2] - b[0] >= 38 && b[3] - b[1] >= 38, `${sel} big enough to press: ${b}`);
    assert.ok(b[3] <= 70, `${sel} in the top row: ${b}`);
    for (const [o, q] of boxes) assert.ok(b[2] <= q[0] || q[2] <= b[0] || b[3] <= q[1] || q[3] <= b[1], `${sel} and ${o} apart`);
    boxes.push([sel, b]);
  }
  for (const sel of ["#status", "#decision .dcard", "#waitChip", "#deckIcon"]) assert.equal(await box(sel), null, `${sel} hidden in the embed (the board shows it)`);
  // they work
  await p.click("#qSound");
  assert.equal(await p.getAttribute("#qSound", "aria-pressed"), "true", "sound on");
  const st = await p.evaluate(() => document.body.dataset.style);
  await p.click("#qStyle");
  assert.notEqual(await p.evaluate(() => document.body.dataset.style), st, "the style switches");
  await p.click("#qDeck");
  assert.equal(await V(p, () => window.__voyage2d.helm.on), true, "the captain takes the deck");
  assert.ok(await p.locator("#helmHint").isVisible(), "the keys hint shows");
  await p.click('#lang [data-lang="zh-TW"]');
  assert.equal(await p.evaluate(() => document.documentElement.lang), "zh-TW");
  await p.click("#zoomBtn");
  assert.equal(await p.getAttribute("#zoomBtn", "aria-pressed"), "true", "the whole ship");
  await p.click("#menuBtn");
  await p.click('#menu [data-tab="settings"]');
  assert.ok(await p.locator('#menu [data-set="mod"][data-v="file"]').isVisible() || (await p.locator('#menu [data-set="mod"][data-v="file"]').count()) === 1, "Settings has the mods row");
  const sheet = await box("#sheet");
  assert.ok(sheet && sheet[1] >= 0 && sheet[3] <= 420, "the menu fits the panel: " + sheet);
  assert.deepEqual(errs, []);
  await ctx.close();
  // outside the embed: the counters show, and the quick row is the embed's own
  const o = await open("driver=0&crew=7");
  assert.ok(await o.p.locator("#status").isVisible());
  assert.ok(await o.p.locator("#zoomBtn").isVisible() && await o.p.locator("#menuBtn").isVisible() && await o.p.locator("#lang").isVisible());
  assert.ok(!(await o.p.locator("#quick").isVisible()));
  assert.deepEqual(o.errs, []);
  await o.ctx.close();
});

// The captain's 「海怪出現沒有戰鬥」 (v2d-12, in the board): the embed hides the game's decision cards
// (the board shows its own), so the kraken's card could never be answered and no fight began. In
// the embed the kraken is taken up as Live will take it (docs/interface.md §1.4): the prompt (and a
// tap on the monster) starts the fight, which plays to its end in the 1400x420 panel.
test("the embed: the kraken rises in the Playground, the prompt takes up the fight, and the battle plays to the hero ending", async () => {
  const { p, ctx, errs } = await open("embed=1&crew=12&speed=10", { viewport: { width: 1400, height: 420 } });
  await p.waitForFunction(() => window.__voyage2d.sim.kraken.arms.length > 0, null, { timeout: 90000, polling: 200 });
  await V(p, () => (window.__G.speed = 1));
  assert.ok(await V(p, () => window.__voyage2d.sim.decisions.some((d) => d.kind === "kraken")), "the kraken's card waits (the board would not show it)");
  assert.ok(!(await p.locator("#decision .dcard").isVisible()), "the game's card is hidden in the embed");
  await p.waitForFunction(() => !document.querySelector("#prompt").hidden, null, { timeout: 20000 });
  assert.match(await p.locator("#prompt").textContent(), /fight the kraken/);
  const box = await p.locator("#prompt").boundingBox();
  assert.ok(box.y >= 0 && box.y + box.height <= 420, "the prompt in the panel");
  await p.locator("#prompt").click();
  await p.waitForFunction(() => window.__voyage2d.battle.playing, null, { timeout: 3000 });
  assert.ok(await V(p, () => !!window.__voyage2d.sim.kraken.battle), "the fight is the sim's battle");
  // the kraken in the frame while it fights
  await p.waitForTimeout(2500);
  const eye = await V(p, () => window.__voyage2d.camera.toScreen(...window.__voyage2d.world.kraken.eyePos()));
  assert.ok(eye[0] > 0 && eye[0] < 1400 && eye[1] > 0 && eye[1] < 420, "the kraken in the panel: " + eye.map(Math.round));
  await V(p, () => (window.__botFight = true));
  await p.waitForFunction(() => window.__voyage2d.battle.ending?.t > 2, null, { timeout: 150000 });
  const st = await V(p, () => ({ hero: window.__voyage2d.world.crew.captain.shots.some((s) => s.name === "heroPose"), approved: window.__voyage2d.sim.tasks.filter((t) => t.approved).length, tags: window.__voyage2d.world.tagsShown.length }));
  assert.ok(st.hero && st.approved >= 1 && st.tags === 0, JSON.stringify(st));
  assert.deepEqual(errs, []);
  await ctx.close();
});

// The captain's 「海怪開戰沒有各就各位的感覺」 (v2d-13): when the fight is taken up, "All hands! Battle
// stations!": every hand runs to a battle station of the layout (one each: the captain at the bow
// rail, the firstmate beside him, the reviewer in a nest, the hands at the bow's guns, the rigging,
// the shot, the lookout) within the muster's time; with reduced motion they are placed at once;
// when the fight is over they go back to their workflow's stations. Full screen and the embed.
const MUSTER_SECS = 7;
test("battle stations: when the fight starts every hand is at a battle station of his own within the muster time, and back at his station after", async () => {
  for (const [q, vp] of [["scene=kraken&crew=24&driver=0", { width: 1440, height: 900 }], ["scene=kraken&crew=12&driver=0&embed=1", { width: 1400, height: 420 }], ["scene=kraken&crew=18&driver=0&motion=reduce", { width: 390, height: 844 }]]) {
    const { p, ctx, errs } = await open(q, { viewport: vp });
    await V(p, () => window.__voyage2d.ui.minimise?.());
    await p.waitForTimeout(1500);
    await V(p, () => { const V2 = window.__voyage2d, d = V2.sim.decisions.find((x) => x.kind === "kraken"); V2.source.command({ type: "answer", decision: d.id, chosen: "A" }); });
    assert.ok(await V(p, () => window.__voyage2d.battle.playing), `${q}: the fight is on`);
    assert.match(await p.locator("#banner").textContent(), /All hands! Battle stations!/);
    const t0 = Date.now();
    await p.waitForFunction(() => window.__voyage2d.world.mustered(), null, { timeout: MUSTER_SECS * 1000, polling: 100 });
    const secs = (Date.now() - t0) / 1000;
    const r = await V(p, () => {
      const W = window.__voyage2d.world, ids = Object.keys(W.crew), posts = ids.map((id) => W.posts[id]);
      return { n: ids.length, have: posts.filter(Boolean).length, uniq: new Set(posts.map((b) => b?.id)).size, battle: posts.every((b) => b && W.G.battle.includes(b)), captain: W.posts.captain?.post, mate: W.posts.firstmate?.post, reviewer: W.posts["reviewer-1"]?.post, bad: W.crowd.violations() };
    });
    assert.equal(r.have, r.n, `${q}: every hand has a post`);
    assert.equal(r.uniq, r.n, `${q}: no two share one`);
    assert.ok(r.battle, `${q}: every post is one of the layout's battle stations`);
    assert.deepEqual([r.captain, r.mate, r.reviewer], ["captain", "mate", "lookout"]);
    assert.deepEqual(r.bad, []);
    if (/reduce/.test(q)) assert.ok(secs < 1.5, `${q}: placed at once (${secs.toFixed(1)} s)`);
    // the fight over (the captain steps out of it): back to the workflow's stations
    await p.keyboard.press("Escape");
    await p.waitForTimeout(1200); // (the stations follow the workflow every half second)
    const back = await V(p, () => ({ mode: window.__voyage2d.world.battleMode, posts: Object.keys(window.__voyage2d.world.posts).length, helm: window.__voyage2d.world.stationOf("captain")?.kind, decision: window.__voyage2d.sim.decisions.length > 0 }));
    assert.deepEqual(back, { mode: false, posts: 0, helm: back.decision ? "cabin" : "helm", decision: back.decision }, `${q}: back to the workflow's stations`);
    assert.deepEqual(errs, []);
    await ctx.close();
  }
});

// The captain's 「戰鬥位置砲口沒有對到海怪，導演鏡頭希望能隨著戰鬥切換視角，像RPG game那樣」 (v2d-14): the
// manned guns are trained on the kraken and their shots fly from their muzzles to it; the director
// cuts the fight into shots (two-shot, wind-up, the gunner and the shot, reactions, specials), each
// short and none leaving the ship and the kraken both out of the picture; with reduced motion only
// the specials cut; in the 1400x420 embed the fight's bars sit in the corner, off the bow.
test("the fight: the manned guns aim at the kraken, the director cuts between several shots, and the embed's bars leave the bow clear", async () => {
  for (const [q, vp] of [["scene=kraken&crew=24&driver=0", { width: 1440, height: 900 }], ["scene=kraken&crew=18&driver=0&embed=1", { width: 1400, height: 420 }]]) {
    const { p, ctx, errs } = await open(q, { viewport: vp });
    await V(p, () => window.__voyage2d.ui.minimise?.());
    await p.waitForTimeout(1500);
    await V(p, () => { const V2 = window.__voyage2d, d = V2.sim.decisions.find((x) => x.kind === "kraken"); V2.source.command({ type: "answer", decision: d.id, chosen: "A" }); });
    await p.waitForFunction(() => window.__voyage2d.world.mustered(), null, { timeout: 15000 });
    // the aim: every manned gun's barrel points forward toward the kraken, within what a carriage allows
    const aim = await V(p, () => {
      const W = window.__voyage2d.world, S = W.ship, gs = S.mannedGuns();
      return { n: gs.length, all: gs.map((g) => { const a = S.gunAim(g); return { dx: S.aimAt[0] - a.pivot[0], ang: a.ang, want: a.want, err: Math.abs(a.ang - a.want) }; }) };
    });
    assert.ok(aim.n >= 3, `${q}: ${aim.n} guns manned`);
    for (const g of aim.all) {
      assert.ok(g.dx > 0, `${q}: the kraken is forward of the gun`);
      assert.ok(Math.abs(g.ang) < Math.PI / 2 && g.ang >= -0.36 && g.ang <= 0.27, `${q}: trained forward within its elevation (${g.ang.toFixed(2)})`);
      assert.ok(g.err < 0.2, `${q}: on the kraken or at its limit (${g.ang.toFixed(2)} vs ${g.want.toFixed(2)})`);
    }
    // a shot leaves from a trained muzzle
    const port = await V(p, () => { const S = window.__voyage2d.world.ship, m = S.mannedGuns(0).length ? S.mannedGuns(0) : S.mannedGuns(), t = S.toWorld(...S.gunAim(m[0]).tip), w = S.portWorld(0, 0); return Math.hypot(t[0] - w[0], t[1] - w[1]); });
    assert.ok(port < 1, `${q}: the ball leaves the muzzle (${port.toFixed(1)})`);
    // the director, for ~9 s of an auto-played fight: several kinds of shot, and the ship or the kraken always in frame
    await V(p, () => { window.__botFight = true; window.__voyage2d.battle.shotLog.length = 0; });
    let lost = 0;
    for (let i = 0; i < 45; i++) {
      await p.waitForTimeout(200);
      lost += await V(p, () => { const V2 = window.__voyage2d, W = V2.world, cam = V2.camera, S = W.ship, sp = S.spec; const inV = ([x, y]) => x > -50 && x < innerWidth + 50 && y > -50 && y < innerHeight + 50; const ship = [[sp.fore[0], 0], [sp.bow, 0], [sp.main[0], 0], [(sp.main[0] + sp.bow) / 2, 480]].some((q) => inV(cam.toScreen(...S.toWorld(...q)))); return ship || inV(cam.toScreen(...W.kraken.eyePos())) ? 0 : 1; });
    }
    const kinds = await V(p, () => [...new Set(window.__voyage2d.battle.shotLog.map((x) => x.name))]);
    assert.ok(kinds.length >= 3 && kinds.includes("two-shot"), `${q}: shots ${kinds}`);
    assert.equal(lost, 0, `${q}: never both the ship and the kraken out of frame`);
    if (vp.height < 500) {
      // the bars in the top left corner, clear of the forecastle
      const fc = await V(p, () => { const V2 = window.__voyage2d, S = V2.world.ship; return V2.camera.toScreen(...S.toWorld(S.spec.fore[0] + 200, S.spec.fore[2] - 200))[0]; });
      const bars = await V(p, () => { const c = document.getElementById("c"); return c.width; });
      assert.ok(fc > 400 && bars > 0, `the forecastle (${fc.toFixed(0)}) right of the bars (x < 400)`);
    }
    assert.deepEqual(errs, []);
    await ctx.close();
  }
  // reduced motion: calmer, only the specials cut
  const { p, ctx, errs } = await open("scene=kraken&crew=12&driver=0&motion=reduce");
  await V(p, () => window.__voyage2d.ui.minimise?.());
  await p.waitForTimeout(1000);
  await V(p, () => { const V2 = window.__voyage2d, d = V2.sim.decisions.find((x) => x.kind === "kraken"); V2.source.command({ type: "answer", decision: d.id, chosen: "A" }); window.__botFight = true; V2.battle.shotLog.length = 0; });
  await p.waitForTimeout(6000);
  const k = await V(p, () => window.__voyage2d.battle.shotLog.map((x) => x.name));
  assert.ok(!k.some((n) => ["gunner", "windup", "hullhit", "reaction"].includes(n)), "reduced motion: no RPG cuts, " + k);
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("mods: ?mod=galleon loads the bundled galleon; a player's file is validated, kept and loaded; a bad one is refused with its errors; reset goes back to the default", async () => {
  const bad = { format: "voyage-mod/1", id: "bad", name: "Bad", colour: 1, ships: { classes: [{ id: "tub", cap: "7" }] } };
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  let { p, errs } = await open("mod=galleon&driver=0&crew=24", {}, ctx);
  let st = await V(p, () => ({ mod: window.__voyage2d.mod.current?.id, cls: window.__voyage2d.world.cls.id, decks: Object.keys(window.__voyage2d.world.G.decks).length, bad: window.__voyage2d.world.crowd.violations() }));
  assert.deepEqual(st, { mod: "galleon", cls: "galleon", decks: 13, bad: [] });
  // the page may not reach any other host, whatever runs in it
  assert.equal(await V(p, async () => { try { await fetch("https://example.com/"); return "reached"; } catch { return "blocked"; } }), "blocked");
  assert.deepEqual(errs, []);
  await p.close();
  // the player's own file (as the file button or a drop hands it over): the crimson crew
  ({ p, errs } = await open("driver=0", {}, ctx));
  assert.equal(await V(p, () => window.__voyage2d.mod.current), null, "no mod by default");
  const text = readFileSync(join(ROOT, "mods/crimson-crew.json"), "utf8");
  await Promise.all([p.waitForNavigation(), V(p, (t) => window.__voyage2d.mod.load(t), text)]);
  await p.waitForFunction(() => window.__G?.ready);
  st = await V(p, () => ({ mod: window.__voyage2d.mod.current?.id, source: window.__voyage2d.mod.source, welcome: window.__voyage2d.ui.t.welcome }));
  assert.deepEqual(st, { mod: "crimson-crew", source: "file", welcome: "The Crimson Crew is aboard, captain. They are at work; a card comes up when they need your call." });
  await p.click("#menuBtn");
  await p.click('#menu [data-tab="settings"]');
  assert.equal(await p.locator("#menu [data-mod]").getAttribute("data-mod"), "crimson-crew", "Settings shows the mod");
  // a bad file is refused, with its errors, and nothing changes
  const r = await V(p, (t) => window.__voyage2d.mod.load(t), JSON.stringify(bad));
  assert.equal(r, false);
  await p.waitForTimeout(200);
  const listed = await p.locator("#menu .moderr li").allTextContents();
  assert.ok(listed.some((e) => e.startsWith('mod: unknown key "colour"')), listed.join("\n"));
  assert.ok(listed.some((e) => e.startsWith('mod.ships.classes[0].cap: expected a number, got the text "7"')), listed.join("\n"));
  assert.equal(await V(p, () => window.__voyage2d.mod.current?.id), "crimson-crew");
  // reset to the default
  await Promise.all([p.waitForNavigation(), p.click('#menu [data-set="mod"][data-v="reset"]')]);
  await p.waitForFunction(() => window.__G?.ready);
  assert.equal(await V(p, () => window.__voyage2d.mod.current), null, "back to the default");
  assert.equal(await V(p, () => window.__voyage2d.world.cls.id), "sloop");
  assert.deepEqual(errs, []);
  await ctx.close();
});
