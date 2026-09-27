// The movement pass in the built artifact: the crew rest apart on every deck; a long voyage
// across class changes never puts anyone in an obstacle or on top of another; the captain
// takes the deck (Q or a tap), walks it by stairs, ladders and shrouds, and gives it back
// (Q, Esc, the fight); the card's keys win while a card is up; phones get a joystick; the
// Playground's mini-games open, are won or skipped, in both styles and three languages; Live
// shows none; and nothing of it ever writes. Serves itself.
import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFileSync, existsSync } from "node:fs";
import { createRequire } from "node:module";
import { join, extname } from "node:path";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");
const ROOT = new URL("..", import.meta.url).pathname;
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".json": "application/json", ".png": "image/png" };
let server, base, browser;

test.before(async () => {
  server = createServer((req, res) => {
    const f = join(ROOT, decodeURIComponent(req.url.split("?")[0]));
    if (!existsSync(f)) return res.writeHead(404).end();
    res.writeHead(200, { "content-type": TYPES[extname(f)] || "application/octet-stream" }).end(readFileSync(f));
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  base = `http://127.0.0.1:${server.address().port}/`;
  browser = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });
});
test.after(async () => { await browser?.close(); server?.close(); });

async function open(q, ctxOpts = { viewport: { width: 1440, height: 900 } }) {
  const ctx = await browser.newContext(ctxOpts);
  const p = await ctx.newPage();
  const errs = [];
  p.on("pageerror", (e) => errs.push(e.message));
  p.on("console", (m) => m.type() === "error" && errs.push(m.text()));
  p.on("request", (r) => { if (!r.url().startsWith(base) && !/fonts\.(googleapis|gstatic)\.com/.test(r.url())) errs.push("outside request " + r.url()); });
  await p.goto(base + "artifact-2d.html?" + q);
  await p.waitForFunction(() => window.__G?.ready, null, { timeout: 60000 });
  return { p, ctx, errs };
}
const V = (p, fn, arg) => p.evaluate(fn, arg);
const cap = (p) => V(p, () => { const a = window.__voyage2d.world.agent("captain"); return { deck: a.deck, x: a.x, z: a.z, link: a.link?.L.id || null, goal: a.goal, on: window.__voyage2d.helm.on }; });
const atRest = () => { const W = window.__voyage2d.world; const k = W.ship.cls.crewScale * W.fit; return !W.ship.transforming && Object.values(W.crew).every((c) => !W.agent(c.id)?.goal && !W.agent(c.id)?.link && !c.shots.length && c.alpha > 0.99 && Math.abs(c.scale / (c.baseScale * k) - 1) < 0.01) && !W.leaving.length; };
// each crewman drawn alone and his inked pixels boxed, in ship space; every overlapping pair
const crewOverlaps = () => {
  const W = window.__voyage2d.world, out = [];
  const c = document.createElement("canvas");
  c.width = c.height = 900;
  const g = c.getContext("2d", { willReadFrequently: true });
  for (const p of Object.values(W.crew)) {
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.clearRect(0, 0, 900, 900);
    g.translate(450 - p.x, 800 - p.y);
    p.draw(g, { shadow: false });
    const d = g.getImageData(0, 0, 900, 900).data;
    let x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9;
    for (let j = 0; j < 900; j += 2) for (let i = 0; i < 900; i += 2) if (d[(j * 900 + i) * 4 + 3] > 40) (x0 = Math.min(x0, i)), (x1 = Math.max(x1, i)), (y0 = Math.min(y0, j)), (y1 = Math.max(y1, j));
    out.push({ id: p.id, x0: x0 - 450 + p.x, x1: x1 - 450 + p.x, y0: y0 - 800 + p.y, y1: y1 - 800 + p.y });
  }
  const hits = [];
  for (let i = 0; i < out.length; i++) for (let j = i + 1; j < out.length; j++) {
    const a = out[i], b = out[j];
    if (a.x0 < b.x1 && b.x0 < a.x1 && a.y0 < b.y1 && b.y0 < a.y1) hits.push(a.id + " x " + b.id);
  }
  const decks = [...new Set(Object.values(W.crew).map((p) => W.agent(p.id).deck))];
  return { n: out.length, hits, decks, broken: W.crowd.violations() };
};

test("at rest on every deck: no two crewmen's boxes overlap, footprints clear, and the crew spreads below decks as it grows (7 to 24, desktop and phone)", async () => {
  for (const vp of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) for (const n of [7, 12, 18, 24]) {
    const { p, ctx, errs } = await open(`driver=0&crew=${n}`, { viewport: vp });
    await p.waitForFunction(atRest, null, { timeout: 20000 });
    await V(p, () => (window.__G.paused = true));
    const r = await V(p, crewOverlaps);
    assert.equal(r.n, n);
    assert.deepEqual(r.hits, [], `${vp.width}px, ${n} aboard`);
    assert.deepEqual(r.broken, [], `${vp.width}px, ${n} aboard: footprints`);
    if (n >= 18) assert.ok(r.decks.includes("hold") && r.decks.includes("main"), `${n} aboard stand on the waist and in the hold: ${r.decks}`);
    // the captain at the wheel, the firstmate forward of him and clearly apart
    const q = await V(p, () => { const W = window.__voyage2d.world, c = W.crew.captain, f = W.crew.firstmate, [, cr] = W.foot(c, c.dir), [fl] = W.foot(f, f.dir); return { deck: W.agent("captain").deck, gap: f.x + fl - (c.x + cr), wheel: Math.abs(c.x - W.ship.wheelPos()[0]) }; });
    assert.equal(q.deck, "qd");
    assert.ok(q.wheel < 60, "the captain at the wheel: " + q.wheel.toFixed(0));
    assert.ok(q.gap >= 59, `the firstmate clearly apart: ${q.gap.toFixed(0)}`);
    assert.deepEqual(errs, []);
    await ctx.close();
  }
});

test("a long voyage at every class and across the transforms: nobody inside an obstacle or on top of another, and they come to rest again", async () => {
  const { p, ctx, errs } = await open("speed=3");
  const seen = new Set();
  let samples = 0;
  for (const n of [7, 12, 18, 24, 15, 9, 7]) {
    await V(p, (n) => window.__voyage2d.setHands(n), n);
    for (let i = 0; i < 70; i++) {
      await p.waitForTimeout(100);
      const r = await V(p, () => ({ bad: window.__voyage2d.world.crowd.violations(), cls: window.__voyage2d.world.ship.cls.id, n: window.__voyage2d.world.crowd.agents.size }));
      samples++;
      seen.add(r.cls);
      assert.deepEqual(r.bad, [], `${n} aboard (${r.cls})`);
    }
  }
  assert.deepEqual([...seen].sort(), ["brig", "frigate", "line", "sloop"]);
  assert.ok(samples >= 490);
  // every walk ends: the hands on a quiet ship all come to rest
  await V(p, () => { window.__G.driver = false; window.__G.speed = 0; }); // the voyage holds still
  await p.waitForFunction(() => { const W = window.__voyage2d.world; return Object.values(W.crew).every((c) => !W.agent(c.id).link && !W.agent(c.id).goal); }, null, { timeout: 60000 });
  assert.deepEqual(await V(p, () => window.__G.errors), [], "no frame threw");
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("control mode: Q or a tap on the captain takes the deck, the camera follows him, and Q or Esc gives it back (he walks back to the wheel)", async () => {
  const { p, ctx, errs } = await open("driver=0&crew=12");
  await p.waitForTimeout(500);
  assert.equal((await cap(p)).on, false);
  await p.keyboard.press("q");
  assert.equal((await cap(p)).on, true);
  assert.ok(await p.locator("#helmHint").isVisible(), "the keys are shown");
  const x0 = (await cap(p)).x;
  await p.keyboard.down("ArrowRight");
  await p.waitForTimeout(900);
  await p.keyboard.up("ArrowRight");
  const c1 = await cap(p);
  assert.ok(c1.x > x0 + 100, `he walks: ${x0.toFixed(0)} -> ${c1.x.toFixed(0)}`);
  await p.waitForTimeout(900);
  const follow = await V(p, () => { const V2 = window.__voyage2d, [x, y] = V2.world.at(V2.world.crew.captain, "torso"); return { dx: Math.abs(V2.camera.x.x - x), dy: Math.abs(V2.camera.y.x - y + 40), zoom: V2.camera.zoom }; });
  assert.ok(follow.dx < 60 && follow.dy < 60, "the camera follows him: " + JSON.stringify(follow));
  await p.keyboard.press("q");
  const c2 = await cap(p);
  assert.equal(c2.on, false);
  assert.ok(c2.goal && c2.goal.deck === "qd", "he walks back to the wheel");
  await p.waitForFunction(() => !window.__voyage2d.world.agent("captain").goal, null, { timeout: 15000 });
  // a tap on the captain takes the deck; Esc gives it back
  const at = await V(p, () => window.__voyage2d.ui.h.crewAt("captain"));
  await p.mouse.click(at[0], at[1] + 40);
  assert.equal((await cap(p)).on, true, "a tap on the captain");
  await p.keyboard.press("Escape");
  assert.equal((await cap(p)).on, false, "Esc");
  // the settings list the keys, in three languages, and hold a button for it
  await p.click("#menuBtn");
  await p.click('#menu [data-tab="settings"]');
  for (const [lang, label] of [["en", "Take the deck"], ["zh-TW", "接手甲板"], ["zh-CN", "接手甲板"]]) {
    await V(p, (l) => window.__voyage2d.ui.setLang(l), lang);
    const row = p.locator("#menu .set", { hasText: label });
    assert.equal(await row.count(), 1, lang);
    assert.match(await row.textContent(), /Q/);
  }
  await p.locator('#menu [data-set="helm"]').click();
  await p.keyboard.press("Escape");
  assert.equal((await cap(p)).on, true, "the settings button takes the deck");
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("the card's keys win: with a card up, A–D and Enter answer it and A and D do not walk; Esc folds the card before it gives back the deck", async () => {
  const { p, ctx, errs } = await open("scene=decision&driver=0");
  await p.waitForTimeout(900);
  assert.ok(await p.locator("#decision .dcard").isVisible(), "a card is up");
  await p.keyboard.press("q");
  assert.equal((await cap(p)).on, true, "Q takes the deck with a card up");
  const x0 = (await cap(p)).x;
  await p.keyboard.down("d");
  await p.waitForTimeout(500);
  await p.keyboard.up("d");
  const hasD = await V(p, () => window.__voyage2d.sim.decisions[0].options.some((o) => o.key === "D"));
  if (hasD) assert.equal(await V(p, () => window.__voyage2d.ui.pick), "D", "D goes to the card");
  assert.ok(Math.abs((await cap(p)).x - x0) < 1, "D did not walk him");
  await p.keyboard.press("b");
  assert.equal(await V(p, () => window.__voyage2d.ui.pick), "B", "B picks on the card");
  // the arrows still walk him while the card is up
  await p.keyboard.down("ArrowRight");
  await p.waitForTimeout(500);
  await p.keyboard.up("ArrowRight");
  assert.ok((await cap(p)).x > x0 + 40, "the arrows walk him");
  // Esc: first the card folds away, then the deck goes back
  await p.keyboard.press("Escape");
  await p.waitForTimeout(450); // the card tucks away
  assert.equal(await V(p, () => window.__voyage2d.ui.minimised), true, "Esc folds the card first");
  assert.equal((await cap(p)).on, true);
  await p.keyboard.press("Escape");
  assert.equal((await cap(p)).on, false, "then Esc gives back the deck");
  // S walks (down a stair) while he has the deck; it does not toggle the sound
  await p.keyboard.press("q");
  const snd = await V(p, () => window.__voyage2d.ui.flags["b-sound"]?.on ?? false);
  await p.keyboard.press("s");
  assert.equal(await V(p, () => window.__voyage2d.ui.flags["b-sound"]?.on ?? false), snd, "S is not the sound while he has the deck");
  assert.equal(await V(p, () => window.__voyage2d.source.writes), 0, "the walk wrote nothing");
  assert.deepEqual(errs, []);
  await ctx.close();
});

// walk (with the keys only) to the nearest way up or down and take it; returns the new deck
async function takeWay(p, way, kind = null) {
  const from = (await cap(p)).deck;
  for (let i = 0; i < 80; i++) {
    const s = await V(p, ([way, kind]) => {
      const V2 = window.__voyage2d, W = V2.world, a = W.agent("captain"), G = W.G, near = V2.helm.linkNear;
      const k = W.crowd.linkAt(a, way);
      if (near && (way < 0 ? near.up : near.down) && (!kind || k?.L.kind === kind)) return { go: 0 };
      const ends = G.links.filter((l) => !kind || l.kind === kind).flatMap((l) => [[l.a, l.b], [l.b, l.a]]).filter(([e, o]) => e.deck === a.deck && (G.decks[o.deck].y > G.decks[e.deck].y) === (way > 0)).map(([e]) => e);
      const e = ends.sort((p, q) => Math.abs(p.x - a.x) - Math.abs(q.x - a.x))[0];
      return { go: Math.sign(e.x - a.x) || 1 };
    }, [way, kind]);
    if (!s.go) break;
    const key = s.go > 0 ? "ArrowRight" : "ArrowLeft";
    await p.keyboard.down(key);
    await p.waitForTimeout(90);
    await p.keyboard.up(key);
  }
  await p.keyboard.press(way < 0 ? "ArrowUp" : "ArrowDown");
  await p.waitForFunction((from) => { const a = window.__voyage2d.world.agent("captain"); return a.deck !== from && !a.link && a.manual; }, from, { timeout: 20000 });
  return (await cap(p)).deck;
}
test("the captain walks every deck: stairs down to the waist, the companionway to the gun deck, the ladder to the hold, and the shrouds up to the crow's nest", async () => {
  for (const crew of [12, 24]) {
    const { p, ctx, errs } = await open(`driver=0&crew=${crew}`);
    await p.waitForTimeout(500);
    await p.keyboard.press("q");
    const route = ["qd"];
    while ((await cap(p)).deck !== "hold" && route.length < 8) route.push(await takeWay(p, 1));
    const lower = crew === 24 ? ["main", "gun", "gun2", "hold"] : ["main", "gun", "hold"];
    assert.deepEqual(route.slice(1), lower, `${crew}: down every deck in turn`);
    while ((await cap(p)).deck !== "main") route.push(await takeWay(p, -1));
    route.push(await takeWay(p, -1, crew === 12 ? "shrouds" : null)); // the waist's way up: the shrouds (or the stairs)
    assert.ok(route.includes("hold") && route.includes("main"), route.join(" > "));
    if (crew === 12) assert.equal(route[route.length - 1], "nest", "up the shrouds to the crow's nest: " + route.join(" > "));
    assert.deepEqual(await V(p, () => window.__voyage2d.world.crowd.violations()), []);
    assert.equal(await V(p, () => window.__voyage2d.source.writes), 0);
    assert.deepEqual(errs, []);
    await ctx.close();
  }
});

test("phones: a tap on the captain gives him a joystick that walks him, and ▲ ▼ by a stair or ladder that take it", async () => {
  const { p, ctx, errs } = await open("driver=0&crew=12", { viewport: { width: 390, height: 844 }, hasTouch: true });
  await p.waitForTimeout(600);
  const at = await V(p, () => window.__voyage2d.ui.h.crewAt("captain"));
  await p.touchscreen.tap(at[0], at[1] + 30);
  assert.equal((await cap(p)).on, true, "the tap on the captain");
  assert.ok(await p.locator("#helmPad .stick").isVisible(), "the pad shows");
  const stick = await p.locator("#helmPad .stick").boundingBox();
  const x0 = (await cap(p)).x;
  // drag the stick right (pointer events, as a finger would)
  const cx = stick.x + stick.width / 2, cy = stick.y + stick.height / 2;
  await p.mouse.move(cx, cy);
  await p.mouse.down();
  await p.mouse.move(cx + 50, cy, { steps: 4 });
  for (let i = 0; i < 40 && !(await p.locator('#helmPad [data-h="down"]').isVisible()); i++) await p.waitForTimeout(100);
  await p.mouse.up();
  assert.ok((await cap(p)).x > x0 + 60, "the joystick walks him");
  assert.ok(await p.locator('#helmPad [data-h="down"]').isVisible(), "▼ by the stairs");
  const deck = (await cap(p)).deck;
  await p.locator('#helmPad [data-h="down"]').tap();
  await p.waitForFunction((d) => { const a = window.__voyage2d.world.agent("captain"); return a.deck !== d && !a.link; }, deck, { timeout: 15000 });
  await p.locator('#helmPad [data-h="leave"]').tap();
  assert.equal((await cap(p)).on, false, "✕ gives back the deck");
  assert.deepEqual(errs, []);
  await ctx.close();
});

// a hand to his station, the captain beside him, E
async function lendAHand(p, who, station) {
  if (station) await V(p, ([w, s]) => window.__voyage2d.station(w, s, "idle"), [who, station]);
  await p.waitForFunction((w) => { const a = window.__voyage2d.world.agent(w); return !a.goal && !a.link; }, who, { timeout: 30000 });
  await V(p, (w) => { window.__voyage2d.helm.toggle(true); return window.__voyage2d.placeCaptain(w); }, who);
  await p.waitForTimeout(300);
  return V(p, () => window.__voyage2d.helm.target);
}
test("mini-games (Playground): E by a working hand opens his station's game; each is won, or skipped with Esc or the button, in both styles and three languages; the morale rises; nothing is written", async () => {
  for (const style of ["crimson", "manga"]) {
    const { p, ctx, errs } = await open(`driver=0&crew=12&style=${style}`);
    const lanes0 = await V(p, () => JSON.stringify(window.__voyage2d.sim.tasks.map((t) => [t.id, t.lane, t.round])));
    const cases = [["gun", "worker-1", "main", "en", "LOAD THE GUN"], ["rig", "worker-2", "amidships", "zh-TW", "拉帆"], ["nest", "worker-3", "top", "zh-CN", "瞭望来帆"], ["stamp", "reviewer-1", null, "en", "STAMP IT"]];
    let morale = 0;
    for (const [kind, who, st, lang, title] of cases) {
      await V(p, (l) => window.__voyage2d.ui.setLang(l), lang);
      const t = await lendAHand(p, who, st);
      assert.deepEqual(t, { id: who, kind }, `${style}: the prompt over ${who}`);
      await p.keyboard.press("e");
      await p.waitForTimeout(200);
      assert.equal(await V(p, () => window.__voyage2d.mini.active?.kind), kind);
      assert.ok(await p.locator("#mini").isVisible());
      assert.equal(await p.locator('#mini [data-m="title"]').textContent(), title, `${style} ${lang}`);
      // won (the test bot plays it), under 15 s
      await V(p, () => (window.__miniBot = true));
      await p.waitForFunction(() => !window.__voyage2d.mini.active, null, { timeout: 16000 });
      await V(p, () => (window.__miniBot = false));
      const res = await V(p, () => window.__voyage2d.mini.results.at(-1));
      assert.equal(res.result, "won", `${style} ${kind}: ${JSON.stringify(res)}`);
      assert.ok(res.secs < 15);
      assert.equal(await V(p, () => window.__voyage2d.helm.morale), ++morale, "the morale rises");
      // skipped: with Esc, then with the button
      await p.keyboard.press("e");
      await p.waitForTimeout(200);
      await p.keyboard.press("Escape");
      assert.equal(await V(p, () => window.__voyage2d.mini.results.at(-1).result), "skipped", "Esc skips");
      assert.equal((await cap(p)).on, true, "Esc closed the game, not the deck");
      await p.keyboard.press("e");
      await p.locator('#mini [data-m="skip"]').click();
      assert.equal(await V(p, () => window.__voyage2d.mini.results.at(-1).result), "skipped", "the Skip button");
      await p.keyboard.press("q");
    }
    // a game left alone ends by itself, under 15 s, and a loss changes nothing
    await lendAHand(p, "worker-1", null);
    await p.keyboard.press("e");
    await p.waitForFunction(() => !window.__voyage2d.mini.active, null, { timeout: 16000 });
    const lost = await V(p, () => window.__voyage2d.mini.results.at(-1));
    assert.equal(lost.result, "lost");
    assert.ok(lost.secs <= 15);
    assert.equal(await V(p, () => window.__voyage2d.helm.morale), morale, "a loss is no boost");
    assert.equal(await V(p, () => window.__voyage2d.source.writes), 0, "nothing was written");
    assert.equal(await V(p, () => JSON.stringify(window.__voyage2d.sim.tasks.map((t) => [t.id, t.lane, t.round]))), lanes0, "the voyage is untouched");
    assert.deepEqual(errs, []);
    await ctx.close();
  }
});

test("Live: the captain still takes the deck and walks it, but no prompt and no mini-game ever shows, and nothing is written", async () => {
  const { p, ctx, errs } = await open("driver=0&crew=12");
  await V(p, () => { window.__voyage2d.ui.h.mode = () => "live"; });
  const t = await lendAHand(p, "worker-1", "main");
  assert.equal(t, null, "no prompt in Live");
  await p.keyboard.press("e");
  await p.waitForTimeout(300);
  assert.equal(await V(p, () => window.__voyage2d.mini.active), null);
  assert.equal(await V(p, () => window.__voyage2d.mini.open("gun", "worker-1")), false, "the games refuse to open in Live");
  assert.ok(!(await p.locator("#mini").isVisible()));
  assert.ok(!(await p.locator('#helmPad [data-h="act"]').isVisible()));
  assert.doesNotMatch(await p.locator("#helmHint").textContent(), /lend a hand/i, "the hint offers no games");
  const x0 = (await cap(p)).x;
  await p.keyboard.down("ArrowLeft");
  await p.waitForTimeout(600);
  await p.keyboard.up("ArrowLeft");
  assert.ok(Math.abs((await cap(p)).x - x0) > 40, "he walks in Live too");
  assert.equal(await V(p, () => window.__voyage2d.source.writes), 0, "nothing was written");
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("the fight closes the deck: the captain goes back to the wheel, a game in hand closes, and no key walks him", async () => {
  const { p, ctx, errs } = await open("driver=0&crew=12");
  await lendAHand(p, "worker-1", "main");
  await p.keyboard.press("e");
  assert.equal(await V(p, () => window.__voyage2d.mini.active?.kind), "gun");
  await V(p, () => window.__voyage2d.stage("battle"));
  await p.waitForTimeout(300);
  const c = await cap(p);
  assert.equal(c.on, false, "the deck is closed in the fight");
  assert.equal(await V(p, () => window.__voyage2d.mini.active), null, "the game closed");
  await p.keyboard.press("q");
  assert.equal((await cap(p)).on, false, "Q does nothing in the fight");
  await p.waitForFunction(() => { const W = window.__voyage2d.world, a = W.agent("captain"), h = W.home(W.crew.captain); return !a.goal && !a.link && a.deck === "qd" && Math.abs(a.x - h.x) < 8; }, null, { timeout: 30000 });
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("no console errors with the captain on deck and a game open, at 1440x900 and 390x844, in both styles", async () => {
  for (const vp of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) for (const style of ["crimson", "manga"]) {
    const { p, ctx, errs } = await open(`crew=18&style=${style}`, { viewport: vp });
    await p.keyboard.press("q");
    await p.keyboard.down("ArrowRight");
    await p.waitForTimeout(1200);
    await p.keyboard.up("ArrowRight");
    await lendAHand(p, "worker-2", "amidships");
    await p.keyboard.press("e");
    await V(p, () => (window.__miniBot = true));
    await p.waitForFunction(() => !window.__voyage2d.mini.active, null, { timeout: 16000 });
    await p.waitForTimeout(500);
    assert.deepEqual(errs.concat(await V(p, () => window.__G.errors)), [], `${vp.width} ${style}`);
    await ctx.close();
  }
});

// The walk (the captain's "too jittery, too stiff" note): stepped frame by frame with the loop
// paused (tools/walkjitter.mjs), the hands move smoothly while walking, under control and for a
// hand walking by the crowd; the facing never flips while one direction is held; the cadence
// is a walk (2 to 4.5 footfalls a second), not a flutter. Before the fix: jerk 2.65 px/frame^2
// RMS, 12 flips in 2 s holding right, 15 footfalls a second.
test("the walk: smooth hands, no facing flips while one way is held, a walking cadence (captain under control and a hand), in both styles", async () => {
  const { measure, stats } = await import("../tools/walkjitter.mjs");
  for (const style of ["crimson", "manga"]) {
    const { p, ctx, errs } = await open(`driver=0&crew=12&style=${style}`);
    await p.waitForTimeout(1000);
    const runs = await measure(p);
    const c = stats(runs.captain.frames, runs.captain.segs), n = stats(runs.npc.frames);
    for (const [who, s] of [["captain", c], ["hand", n]]) {
      assert.ok(s.jerkRms < 0.6, `${style} ${who}: hand jerk RMS ${s.jerkRms}`);
      assert.ok(s.jerkMax < 1.5, `${style} ${who}: hand jerk max ${s.jerkMax}`);
      assert.ok(s.handStepMax < 3.5, `${style} ${who}: hand step max ${s.handStepMax}`);
      assert.ok(s.stepsPerSec > 2 && s.stepsPerSec < 4.5, `${style} ${who}: cadence ${s.stepsPerSec}`);
      assert.ok(s.dirFlipsPerSec <= 0.5, `${style} ${who}: flips ${s.dirFlipsPerSec}/s`);
    }
    assert.equal(c.flipsHoldingOneWay, 0, `${style}: no flips while one way is held`);
    assert.deepEqual(errs, []);
    await ctx.close();
  }
  // reduced motion: he still walks, with no squash and a small bob
  const { p, ctx, errs } = await open("driver=0&crew=12&motion=reduce");
  const r = await V(p, () => {
    const V2 = window.__voyage2d, W = V2.world, h = 1 / 60;
    window.__G.paused = true;
    V2.helm.enter();
    V2.helm.held.add("ArrowRight");
    let sq = 0, y = 0, loco = 0;
    const c = W.crew.captain;
    for (let i = 0; i < 90; i++) { V2.helm.update(h); W.update(h); if (i > 30) (sq = Math.max(sq, Math.abs(c.pose.sq ?? 1) - 1 > 0 ? Math.abs((c.pose.sq ?? 1) - 1) : sq)), (y = Math.max(y, Math.abs(c.pose.y || 0))), (loco = Math.max(loco, c.locoW)); }
    return { sq, y, loco, turn: c.turnK };
  });
  assert.ok(r.loco > 0.9, "he walks: " + r.loco);
  assert.ok(r.sq < 0.001 && r.y < 0.15, "no squash, a small bob: " + JSON.stringify(r));
  assert.deepEqual(errs, []);
  await ctx.close();
});
