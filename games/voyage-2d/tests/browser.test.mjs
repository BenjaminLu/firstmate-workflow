// Browser checks on the built artifact: it loads with no errors, every staged state
// renders, the specials run their cut-ins, the finisher ends in the hero pose, and the
// frame budget holds on a desktop and on a throttled phone. Serves itself.
import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFileSync, existsSync } from "node:fs";
import { createRequire } from "node:module";
import { join, extname } from "node:path";

const require = createRequire(import.meta.url);
const { chromium, devices } = require("playwright");
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

async function open(q, ctxOpts = { viewport: { width: 1280, height: 800 } }) {
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

test("the artifact is one file with no network calls in its code", () => {
  const html = readFileSync(join(ROOT, "artifact-2d.html"), "utf8");
  for (const bad of ["fetch(", "XMLHttpRequest", "WebSocket", "sendBeacon"]) assert.ok(!html.includes(bad), bad);
  const hosts = new Set([...html.matchAll(/https?:\/\/([a-zA-Z0-9.-]+)/g)].map((m) => m[1]));
  for (const h of hosts) assert.ok(/^fonts\.(googleapis|gstatic)\.com$/.test(h), "host " + h);
});

test("the baked crew: the young firstmate, the robot as a worker, two facings, knees, no shout face", () => {
  const bake = JSON.parse(readFileSync(join(ROOT, "bake/sprites.json"), "utf8"));
  assert.deepEqual(Object.keys(bake.crew).sort(), ["captain", "firstmate", "reviewer-1", "robot", "sailor-bandana", "sailor-hammer", "sailor-spyglass"]);
  assert.ok(bake.crew.firstmate.expressions.includes("grin"), "the firstmate has a human face");
  assert.deepEqual(bake.crew.robot.expressions.sort(), ["eyes", "happy"]);
  for (const c of Object.values(bake.crew)) assert.ok(c.facings.q.joints.knee_l && c.facings.q.joints.knee_r, c.id + " knees");
  for (const c of Object.values(bake.crew)) {
    assert.ok(c.facings.q && c.facings.f);
    assert.ok(!c.expressions.includes("shout"));
    for (const k of ["torso", "uarm_l", "uarm_r", "farm_l", "farm_r", "leg_l", "leg_r"]) assert.ok(c.facings.q.parts[k], c.id + " " + k);
  }
});

test("every staged state renders without errors", async () => {
  for (const s of ["order", "work", "review", "squall", "merge", "decision", "port", "kraken", "battle", "ultimate"]) {
    const { p, ctx, errs } = await open("scene=" + s);
    await p.waitForTimeout(1200);
    assert.deepEqual(errs, [], s);
    await ctx.close();
  }
});

test("each special plays its cut-in", async () => {
  const { p, ctx, errs } = await open("scene=battle");
  for (const [name, title] of [["broadside", "BROADSIDE!"], ["harpoon", "HARPOON & CHAIN"], ["order", "ALL HANDS!"], ["riposte", "RIPOSTE!"]]) {
    await p.evaluate((n) => window.__voyage2d.special(n), name);
    await p.waitForTimeout(250);
    const titles = await p.evaluate(() => window.__voyage2d.overlay.cuts.map((c) => c.en));
    assert.ok(titles.includes(title), name + ": " + titles);
    await p.waitForTimeout(3500);
  }
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("the ultimate is countered by a braced perfect parry (auto-played)", async () => {
  const { p, ctx, errs } = await open("scene=battle");
  await p.evaluate(() => { window.__botFight = true; window.__voyage2d.special("ult"); });
  const seen = await p.evaluate(() => new Promise((res) => {
    const out = new Set();
    const t = setInterval(() => {
      for (const c of window.__voyage2d.overlay.cuts) out.add(c.en);
      if (out.has("COUNTER BROADSIDE")) (clearInterval(t), res([...out]));
    }, 50);
    setTimeout(() => (clearInterval(t), res([...out])), 12000);
  }));
  assert.ok(seen.includes("MAELSTROM") && seen.includes("COUNTER BROADSIDE"), seen.join());
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("only an approval wins: the finisher approves the held tasks and ends in the hero pose", async () => {
  const { p, ctx, errs } = await open("scene=victory");
  const held = await p.evaluate(() => window.__voyage2d.sim.kraken.arms.slice());
  assert.ok(held.length > 0);
  await p.waitForFunction(() => window.__voyage2d.battle.ending && window.__voyage2d.battle.ending.t > 2, null, { timeout: 20000 });
  const st = await p.evaluate((ids) => ({
    approved: ids.map((id) => window.__voyage2d.sim.tasks.find((t) => t.id === id).approved),
    views: Object.values(window.__voyage2d.world.crew).map((c) => c.view),
    captain: window.__voyage2d.world.crew.captain.shots.map((s) => s.name),
    beside: Math.abs(window.__voyage2d.world.crew.firstmate.x - window.__voyage2d.world.crew.captain.x),
    fireworks: window.__voyage2d.world.fx.fire.length,
  }), held);
  assert.ok(st.approved.every(Boolean), "held tasks approved");
  assert.ok(st.views.every((v) => v === "f"), "the crew face us");
  assert.ok(st.captain.includes("heroPose"));
  assert.ok(st.beside <= 250, "the firstmate stands beside the captain");
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("frame budget: desktop and a 4x-throttled phone stay under 16.7 ms at p95", async () => {
  // and the phone with a full ship of the line (24 hands)
  for (const [mobile, crew] of [[false, 7], [true, 7], [true, 24]]) {
    const opts = mobile ? { ...devices["iPhone 13"] } : { viewport: { width: 1440, height: 900 } };
    const { p, ctx, errs } = await open(`scene=battle&demo=1&crew=${crew}`, opts);
    if (mobile) await (await ctx.newCDPSession(p)).send("Emulation.setCPUThrottlingRate", { rate: 4 });
    await p.waitForTimeout(6000);
    const perf = await p.evaluate(() => window.__voyage2d.perf());
    assert.ok(perf.p95 < 16.7, `${mobile ? "phone" : "desktop"} p95 ${perf.p95} ms`);
    if (mobile) assert.equal(perf.detail, "low");
    assert.deepEqual(errs, []);
    await ctx.close();
  }
});

test("Playground runs itself; the captain answers a card only by clicking the card", async () => {
  let { p, ctx, errs } = await open("");
  // nobody touches anything: the sim's own firstmate dispatches the ready work
  await p.waitForFunction(() => window.__voyage2d.sim.stats.dispatched >= 2, null, { timeout: 15000 });
  assert.deepEqual(await p.evaluate(() => window.__voyage2d.targets()), [], "nothing on stage to tap before a fight");
  await ctx.close();
  // the decision card comes up on its own; its big A answers it
  ({ p, ctx, errs } = await open("scene=decision"));
  await p.waitForTimeout(900);
  const n0 = await p.evaluate(() => window.__voyage2d.sim.decisions.length);
  assert.ok(n0 >= 1 && (await p.locator("#decision .dcard").isVisible()), "the card shows while a decision waits");
  await p.locator('#decision .opt[data-key="A"]').click();
  await p.waitForTimeout(500);
  assert.equal(await p.evaluate(() => window.__voyage2d.sim.decisions.length), n0 - 1);
  await ctx.close();
  // "Later" folds the card away; then neither the keys nor the placard on stage answer it
  ({ p, ctx, errs } = await open("scene=decision"));
  await p.waitForTimeout(900);
  await p.locator("#decision [data-later]").click();
  await p.waitForTimeout(600);
  assert.ok(!(await p.locator("#decision .dcard").isVisible()), "Later hides the card");
  const n = await p.evaluate(() => window.__voyage2d.sim.decisions.length);
  for (const k of ["a", "A", "Enter", "b"]) await p.keyboard.press(k);
  const at = await p.evaluate(() => { const V = window.__voyage2d, c = V.world.crew.captain; return V.camera.toScreen(...V.world.at(c, "head", 60, -370)); });
  await p.mouse.click(at[0], at[1]);
  await p.waitForTimeout(400);
  assert.equal(await p.evaluate(() => window.__voyage2d.sim.decisions.length), n, "no answer without the card");
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("the firstmate's controls are gone: no dispatch, course, survey, review, gate, push, new task, hire or dismiss buttons", async () => {
  const { p, ctx, errs } = await open("scene=work");
  await p.waitForTimeout(500);
  const before = await p.evaluate(() => JSON.stringify({ s: window.__voyage2d.sim.stats, t: window.__voyage2d.sim.tasks.map((x) => x.lane + x.round), c: window.__voyage2d.sim.crew.length }));
  await p.evaluate(() => (window.__voyage2d.G.paused = true));
  for (const k of ["n", "o", "u", "m", "v", "j", "h", "f", "g", "p"]) await p.keyboard.press(k);
  const after = await p.evaluate(() => JSON.stringify({ s: window.__voyage2d.sim.stats, t: window.__voyage2d.sim.tasks.map((x) => x.lane + x.round), c: window.__voyage2d.sim.crew.length }));
  assert.equal(after, before, "no key changes the voyage");
  for (const lang of ["en", "zh-TW", "zh-CN"]) {
    await p.click(`#lang [data-lang="${lang}"]`);
    await p.click("#menuBtn");
    const acts = await p.evaluate(() => [...document.querySelectorAll("#lanes [data-card]")].map((b) => [b.dataset.card, b.closest(".lane").dataset.lane]));
    assert.ok(acts.every(([k, lane]) => ["park", "drop"].includes(k) && ["ready", "backlog"].includes(lane)), JSON.stringify(acts));
    await p.click('#menu [data-tab="settings"]');
    const set = await p.evaluate(() => [...document.querySelectorAll("#menu [data-set]")].map((b) => b.dataset.set));
    for (const gone of ["hire", "dismiss", "demo"]) assert.ok(!set.includes(gone), gone);
    const text = await p.evaluate(() => document.body.innerText);
    for (const word of ["Dispatch", "Set course", "Survey", "Hire", "Dismiss", "Auto-play", "give the order", "派工", "設定航線", "设定航线", "勘查", "招募", "解散", "自動航行", "自动航行", "下達命令", "下达命令"]) assert.ok(!text.includes(word), `${lang}: ${word}`);
    await p.keyboard.press("Escape");
  }
  // Park and Drop stay, and only where the board allows them
  await p.click("#menuBtn");
  const ready = await p.evaluate(() => window.__voyage2d.sim.tasks.find((t) => t.lane === "ready" || t.lane === "backlog")?.id);
  await p.click(`#lanes [data-card="park"][data-id="${ready}"]`);
  assert.equal(await p.evaluate((id) => window.__voyage2d.sim.tasks.find((t) => t.id === id)?.lane ?? "gone", ready), "parked");
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("Playground: the captain sets the hands aboard (Settings and + / - / =), 7 to 24, and the ship changes class; Live shows only the count", async () => {
  const { p, ctx, errs } = await open("");
  const V = () => p.evaluate(() => ({ n: window.__voyage2d.sim.crew.length, cls: window.__voyage2d.world.ship.cls.id, moving: window.__voyage2d.world.ship.transforming }));
  await p.click("#menuBtn");
  await p.click('#menu [data-tab="settings"]');
  for (const [lang, label] of [["en", "Hands aboard"], ["zh-TW", "在船人數"], ["zh-CN", "在船人数"]]) {
    await p.evaluate((l) => window.__voyage2d.ui.setLang(l), lang);
    const row = p.locator("#menu .set", { hasText: label });
    assert.equal(await row.locator('[data-set="hands"]').count(), 2, lang + ": − and +");
  }
  await p.evaluate(() => window.__voyage2d.ui.setLang("en"));
  const minus = p.locator('#menu [data-set="hands"][data-v="-1"]'), plus = p.locator('#menu [data-set="hands"][data-v="1"]');
  assert.equal((await V()).n, 7);
  assert.ok(await minus.isDisabled(), "7 is the fewest");
  await minus.click({ force: true });
  assert.equal((await V()).n, 7);
  // 7 -> 8 crosses the sloop's cap: the brig, with the shipyard transform
  await plus.click();
  assert.equal(await p.locator("#menu [data-hands]").textContent(), "8");
  let v = await V();
  assert.equal(v.n, 8);
  assert.ok(v.moving && v.cls === "brig", "a transform to the brig: " + JSON.stringify(v));
  assert.match(await p.locator("#banner").textContent(), /The ship grows: Brig/i);
  await p.keyboard.press("Escape");
  await p.waitForTimeout(4200);
  assert.deepEqual(await V(), { n: 8, cls: "brig", moving: false });
  // the keys: + and = add a hand, - sends one ashore
  await p.keyboard.press("=");
  await p.keyboard.press("+");
  assert.equal((await V()).n, 10);
  await p.keyboard.press("-");
  assert.equal((await V()).n, 9);
  // clamped at 24, the ship of the line
  assert.equal(await p.evaluate(() => window.__voyage2d.setHands(40)), 24);
  await p.keyboard.press("+");
  assert.equal((await V()).n, 24);
  await p.click("#menuBtn");
  await p.click('#menu [data-tab="settings"]');
  assert.ok(await p.locator('#menu [data-set="hands"][data-v="1"]').isDisabled(), "24 is the most");
  await p.keyboard.press("Escape");
  await p.waitForTimeout(4200);
  assert.equal((await V()).cls, "line");
  // down across the caps again, back to a sloop
  assert.equal(await p.evaluate(() => window.__voyage2d.setHands(7)), 7);
  await p.waitForTimeout(4200);
  assert.equal((await V()).cls, "sloop");
  // in the fight the keys are the fight's
  await p.evaluate(() => window.__voyage2d.stage("battle"));
  await p.waitForTimeout(300);
  await p.keyboard.press("=");
  assert.equal((await V()).n, 7, "no hands change in battle");
  // Live: the board's crew list rules; the sheet shows the count, no buttons
  await p.evaluate(() => { const V = window.__voyage2d; V.battle.play(false); V.ui.h.mode = () => "live"; });
  await p.click("#menuBtn");
  await p.click('#menu [data-tab="settings"]');
  assert.equal(await p.locator('#menu [data-set="hands"]').count(), 0, "no hands control in Live");
  assert.equal(await p.locator("#menu [data-hands]").textContent(), "7");
  assert.deepEqual(errs, []);
  await ctx.close();
});

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
  return { n: out.length, hits };
};

test("the opening crew stands apart: no two crewmen's boxes overlap at 7, 12, 18 and 24, desktop and phone", async () => {
  for (const vp of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) for (const n of [7, 12, 18, 24]) {
    const { p, ctx, errs } = await open(`driver=0&crew=${n}`, { viewport: vp });
    await p.evaluate(() => (window.__G.paused = true));
    const r = await p.evaluate(crewOverlaps);
    assert.equal(r.n, n);
    assert.deepEqual(r.hits, [], `${vp.width}px, ${n} aboard`);
    // the captain on the quarterdeck, by the helm
    assert.ok(await p.evaluate(() => { const W = window.__voyage2d.world; return W.crew.captain.x < W.ship.cls.qd[1]; }), "the captain is on the quarterdeck");
    assert.deepEqual(errs, []);
    await ctx.close();
  }
});

test("hands come and go: after every regroup no two crewmen's boxes overlap", async () => {
  const { p, ctx, errs } = await open("driver=0");
  for (const n of [9, 12, 11, 15, 24, 20, 13, 7]) {
    await p.evaluate((n) => window.__voyage2d.setHands(n), n);
    await p.waitForTimeout(3600); // a class change regroups twice: as it starts and as it ends
    // at rest: every hand has walked the decks to his spot (no walk, no climb), the cheer over
    await p.waitForFunction(() => { const W = window.__voyage2d.world; const k = W.ship.cls.crewScale * W.fit; return !W.ship.transforming && Object.values(W.crew).every((c) => !c.walk && !W.agent(c.id)?.goal && !W.agent(c.id)?.link && !c.shots.length && c.alpha > 0.99 && Math.abs(c.scale / (c.baseScale * k) - 1) < 0.01) && !W.leaving.length; }, null, { timeout: 30000 });
    await p.waitForTimeout(1200); // at rest: the walk's last stride blended into the lean, the cheer over
    const r = await p.evaluate(crewOverlaps);
    assert.equal(r.n, n);
    assert.deepEqual(r.hits, [], n + " aboard");
  }
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("a fresh Playground voyage meets the kraken on its own, its card on top", async () => {
  const { p, ctx, errs } = await open("speed=10");
  await p.waitForFunction(() => window.__voyage2d.sim.kraken.arms.length > 0, null, { timeout: 40000, polling: 100 });
  assert.ok(await p.evaluate(() => window.__voyage2d.sim.t) < 150);
  await p.evaluate(() => (window.__G.speed = 1));
  await p.waitForFunction(() => window.__voyage2d.world.kraken.rise > 0.9, null, { timeout: 15000 });
  await p.waitForTimeout(800);
  assert.ok(await p.locator("#decision .dcard.k-kraken").isVisible());
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("the Playground badge shows in every language, all the time, and the page never talks to the board", async () => {
  const { p, ctx, errs } = await open("scene=battle");
  const outside = [];
  p.on("request", (r) => { if (!r.url().startsWith(base) && !/fonts\.(googleapis|gstatic)\.com/.test(r.url())) outside.push(r.method() + " " + r.url()); if (r.method() !== "GET") outside.push(r.method() + " " + r.url()); });
  for (const [lang, label] of [["en", "PLAYGROUND · simulated"], ["zh-TW", "遊樂場 · 模擬"], ["zh-CN", "游乐场 · 模拟"]]) {
    await p.evaluate((l) => window.__voyage2d.ui.setLang(l), lang);
    assert.ok(await p.locator("#modeBadge").isVisible(), "the badge shows in the fight");
    assert.equal((await p.locator("#modeBadge").textContent()).replace("◆", "").trim(), label);
  }
  await p.evaluate(() => window.__voyage2d.stage("decision"));
  await p.waitForTimeout(300);
  assert.deepEqual(outside, []);
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("click-first: a fight won by real clicks alone, through the maelstrom to the hero ending", async () => {
  const { p, ctx, errs } = await open("scene=battle&grip=40");
  const W = 1280, H = 800;
  let clicks = 0, specials = 0;
  const t0 = Date.now();
  for (;;) {
    const st = await p.evaluate(() => ({ P: window.__voyage2d.prompt(), sp: window.__voyage2d.specialReady(), end: !!window.__voyage2d.battle.ending, ult: window.__voyage2d.battle.b?.ultDone?.length || 0 }));
    if (st.end) break;
    assert.ok(Date.now() - t0 < 120000, "the fight should end within two minutes");
    if (st.sp) {
      const box = await p.locator("#special").boundingBox();
      if (box) (await p.mouse.click(box.x + box.width / 2, box.y + box.height / 2), specials++);
    } else if (st.P && st.P.ready) {
      await p.mouse.click(W / 2, H / 2); // anywhere on the stage
      clicks++;
    }
    await p.waitForTimeout(40);
  }
  const held = await p.evaluate(() => window.__voyage2d.sim.tasks.filter((t) => t.approved).length);
  assert.ok(clicks >= 3 && held >= 2, `clicks ${clicks}, specials ${specials}, approved ${held}`);
  await p.waitForFunction(() => window.__voyage2d.battle.ending?.t > 2, null, { timeout: 20000 });
  assert.ok(await p.evaluate(() => window.__voyage2d.world.crew.captain.shots.some((s) => s.name === "heroPose")));
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("both styles render the cut-ins and the ending (Manga and Crimson)", async () => {
  for (const style of ["manga", "p5"]) {
    const { p, ctx, errs } = await open("scene=victory&style=" + style);
    await p.waitForFunction(() => window.__voyage2d.battle.ending, null, { timeout: 20000 });
    assert.equal(await p.evaluate(() => window.__voyage2d.overlay.style), style);
    assert.deepEqual(errs, [], style);
    await ctx.close();
  }
});

// ---------------------------------------------------------------- pass 3: the HUD, the tiers, the escalation
const visible = (p, sel) => p.locator(sel).first().isVisible();

test("the HUD is minimal: a status cluster, the menu, the mode badge; the menu pauses and holds the board", async () => {
  const { p, ctx, errs } = await open("");
  await p.waitForTimeout(600);
  for (const sel of ["#status", "#menuBtn", "#lang", "#modeBadge"]) assert.ok(await visible(p, sel), sel + " shows");
  for (const sel of ["#menu", "#decision .dcard", "#lanes", "#prompt"]) assert.ok(!(await visible(p, sel)), sel + " stays hidden");
  // everything the captain can press is at least 44 px
  const small = await p.evaluate(() => [...document.querySelectorAll("button")].filter((b) => b.offsetParent).map((b) => [b.id || b.textContent, b.getBoundingClientRect()]).filter(([, r]) => r.width < 43.5 || r.height < 43.5).map(([n]) => n));
  assert.deepEqual(small, []);
  await p.click("#menuBtn");
  await p.waitForTimeout(200);
  assert.ok(await visible(p, "#lanes"), "the menu opens on the board");
  assert.equal(await p.locator("#lanes .lane").count(), 6);
  const t0 = await p.evaluate(() => window.__voyage2d.sim.t);
  await p.waitForTimeout(700);
  assert.equal(await p.evaluate(() => window.__voyage2d.sim.t), t0, "the voyage pauses behind the menu");
  await p.click('#menu [data-tab="roster"]');
  assert.ok(await visible(p, ".roster tbody tr"), "the roster tab");
  await p.keyboard.press("Escape");
  await p.waitForTimeout(200);
  assert.ok(!(await visible(p, "#menu")), "Esc resumes");
  await p.waitForTimeout(400);
  assert.ok((await p.evaluate(() => window.__voyage2d.sim.t)) > t0, "the voyage goes on");
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("three languages: EN by default, 繁 and 简 switch every label, and the choice is remembered", async () => {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const p = await ctx.newPage();
  const errs = [];
  p.on("pageerror", (e) => errs.push(e.message));
  await p.goto(base + "artifact-2d.html");
  await p.waitForFunction(() => window.__G?.ready);
  assert.equal(await p.evaluate(() => document.documentElement.lang), "en");
  assert.equal((await p.locator('#status [data-t="merged"]').textContent()).trim(), "merged");
  await p.click('#lang [data-lang="zh-TW"]');
  assert.equal(await p.evaluate(() => document.documentElement.lang), "zh-TW");
  assert.equal((await p.locator('#status [data-t="merged"]').textContent()).trim(), "已合併");
  await p.click("#menuBtn");
  assert.equal((await p.locator("#sheetTitle").textContent()).trim(), "看板");
  assert.equal((await p.locator("#lanes .lane h3").first().textContent()).replace(/\d+$/, ""), "議題");
  await p.keyboard.press("Escape");
  await p.click('#lang [data-lang="zh-CN"]');
  assert.equal((await p.locator('#status [data-t="merged"]').textContent()).trim(), "已合并");
  await p.reload();
  await p.waitForFunction(() => window.__G?.ready);
  assert.equal(await p.evaluate(() => document.documentElement.lang), "zh-CN", "remembered across a reload");
  // the decision card and the stage's banners speak it too
  await p.evaluate(() => window.__voyage2d.stage("decision"));
  await p.waitForTimeout(600);
  assert.match(await p.locator("#decision .dcard").textContent(), /决策/);
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("the ship grows with the crew: sloop, brig, frigate, ship of the line; every hand aboard; then trims back", async () => {
  const { p, ctx, errs } = await open("");
  const cls = () => p.evaluate(() => window.__voyage2d.world.cls.id);
  assert.equal(await cls(), "sloop");
  const aboard = () => p.evaluate(() => {
    const W = window.__voyage2d.world, S = W.ship.spec;
    return Object.values(W.crew).filter((c) => !(c.x > S.stern + 20 && c.x < S.bow - 20) || c.alpha < 0.99).map((c) => c.id + "@" + Math.round(c.x) + "/" + c.alpha.toFixed(2));
  });
  for (const [n, want] of [[12, "brig"], [18, "frigate"], [24, "ship of the line"]]) {
    await p.evaluate((n) => window.__voyage2d.hire(n - window.__voyage2d.sim.crew.length), n);
    await p.waitForTimeout(300);
    assert.equal(await p.evaluate(() => window.__voyage2d.world.ship.transforming), true, "a transform, not a pop");
    assert.match(await p.locator("#banner").textContent(), new RegExp("The ship grows: " + want, "i"));
    await p.waitForTimeout(4200);
    assert.equal(await p.evaluate(() => window.__voyage2d.world.cls.en.toLowerCase()), want);
    assert.deepEqual(await aboard(), [], "every hand has a spot on the " + want);
  }
  assert.equal(await p.evaluate(() => Object.keys(window.__voyage2d.world.crew).length), 24);
  assert.equal(await p.evaluate(() => window.__voyage2d.hire(3).length), 0, "24 is the most she carries");
  // the roster stays readable at 24: grouped, every hand listed
  await p.click("#menuBtn");
  await p.click('#menu [data-tab="roster"]');
  assert.equal(await p.locator(".roster tbody tr:not(.grp)").count(), 24);
  await p.keyboard.press("Escape");
  await p.evaluate(() => window.__voyage2d.dismiss(17));
  await p.waitForTimeout(300);
  assert.match(await p.locator("#banner").textContent(), /trims down/i);
  await p.waitForTimeout(4200);
  assert.equal(await cls(), "sloop");
  assert.deepEqual(await aboard(), []);
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("the specials escalate with the ship: one portrait on a sloop, three panels on a frigate, the whole crew on the line", async () => {
  for (const [crew, panels, scale] of [[7, 0, 0.72], [12, 0, 1], [18, 3, 1], [24, 7, 1]]) {
    const { p, ctx, errs } = await open(`crew=${crew}&scene=battle`);
    await p.evaluate(() => window.__voyage2d.special("broadside"));
    await p.waitForTimeout(250);
    const c = await p.evaluate(() => window.__voyage2d.overlay.cuts.map((c) => ({ en: c.en, n: c.panels?.length || 0, s: c.scale })).find((c) => c.en === "BROADSIDE!"));
    assert.ok(c, "the cut-in plays at crew " + crew);
    assert.equal(c.n, panels, "panels at crew " + crew);
    assert.equal(c.s, scale, "band scale at crew " + crew);
    await p.waitForTimeout(2600);
    assert.deepEqual(errs, []);
    await ctx.close();
  }
});

test("name tags: only the name and a project flag, never overlapping at 24; the detail card opens on hover, tap and focus", async () => {
  const { p, ctx, errs } = await open("crew=24");
  await p.evaluate(() => { const V = window.__voyage2d; for (let i = 0; i < 4; i++) V.apply({ type: "dispatch" }); for (const d of V.sim.decisions.slice()) V.apply({ type: "answer", decision: d.id, key: "A" }); });
  await p.waitForTimeout(7000);
  const tags = await p.evaluate(() => window.__voyage2d.world.tagsShown);
  assert.ok(tags.length >= 12, "most tags show in the wide shot: " + tags.length);
  for (let i = 0; i < tags.length; i++) for (let j = i + 1; j < tags.length; j++) {
    const a = tags[i], b = tags[j];
    const overlap = Math.abs(a.x - b.x) < (a.w + b.w) / 2 && Math.abs(a.y - b.y) < a.h * 0.95;
    assert.ok(!overlap, `${a.id} overlaps ${b.id}`);
  }
  // (hovered just under the head: the wide shot of a bigger, deeper ship draws the crew smaller)
  // a worker with a task: hover shows his card with every field, labelled (any decision card folded away first)
  // (the wide shot, paused: the hands at work are spread over every deck now, and a close-up
  // could leave the one we hover off screen)
  await p.evaluate(() => { const V = window.__voyage2d; V.G.paused = true; V.ui.minimised = true; V.ui.render(V.sim); V.director.cinematic = false; V.camera.go(V.director.frames().wide(), { cut: true }); });
  await p.waitForTimeout(100);
  const id = await p.evaluate(() => window.__voyage2d.sim.crew.find((c) => c.role === "worker" && c.task && !window.__voyage2d.world.agent(c.id).link).id);
  const at = await p.evaluate((id) => window.__voyage2d.ui.h.crewAt(id), id);
  await p.mouse.move(at[0], at[1] + 12);
  await p.waitForTimeout(150);
  assert.ok(await p.locator("#crewCard").isVisible(), "hover opens the card");
  assert.equal(await p.locator("#crewCard").getAttribute("data-crew"), id);
  const dts = await p.locator("#crewCard dt").allTextContents();
  assert.deepEqual(dts, ["Role", "Project", "Task", "Round", "PR", "State", "Activity", "Rank", "Vendor"]);
  // tap pins it; a second tap closes it; Esc closes it too
  await p.mouse.click(at[0], at[1] + 12);
  await p.mouse.move(5, 400);
  assert.ok(await p.locator("#crewCard").isVisible(), "a tap pins the card");
  const at2 = await p.evaluate((id) => window.__voyage2d.ui.h.crewAt(id), id);
  await p.mouse.click(at2[0], at2[1] + 12);
  assert.ok(!(await p.locator("#crewCard").isVisible()), "a second tap closes it");
  await p.mouse.click(at2[0], at2[1] + 12);
  await p.keyboard.press("Escape");
  assert.ok(!(await p.locator("#crewCard").isVisible()), "Esc closes it");
  // keyboard: focus a crewman, his card opens (in the chosen language)
  await p.click('#lang [data-lang="zh-TW"]');
  await p.focus(`#crewFocus [data-crew="${id}"]`);
  assert.ok(await p.locator("#crewCard").isVisible(), "focus opens the card");
  assert.equal((await p.locator("#crewCard dt").first().textContent()).trim(), "職務");
  // the roster keeps every field as its own column
  await p.keyboard.press("Escape");
  await p.click("#menuBtn");
  await p.click('#menu [data-tab="roster"]');
  assert.equal(await p.locator(".roster thead th").count(), 10);
  assert.equal(await p.locator(".roster tbody tr:not(.grp)").count(), 24);
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("the kraken through play: a fresh voyage, three rejected rounds, the kraken's card, Proceed: fight starts the fight", async () => {
  const { p, ctx, errs } = await open("");
  await p.waitForTimeout(500);
  // the sim's firstmate dispatches and the reviewer turns the work back, round after round (the
  // sim API; the captain has no such control); any other card is answered by clicking its A
  await p.waitForFunction(() => window.__voyage2d.sim.tasks.some((t) => t.lane === "working"), null, { timeout: 15000 });
  let card = null;
  for (let i = 0; i < 60 && !card; i++) {
    await p.evaluate(() => { const V = window.__voyage2d, t = V.sim.tasks.find((x) => x.lane === "working" || x.lane === "review"); if (t && !V.sim.decisions.length) V.apply({ type: "reject", task: t.id }); });
    await p.waitForTimeout(250);
    const kind = await p.evaluate(() => window.__voyage2d.sim.decisions[0]?.kind || null);
    if (kind === "kraken") card = kind;
    else if (kind) await p.locator('#decision .opt[data-key="A"]').click();
  }
  assert.equal(card, "kraken", "the kraken's card comes up after round 3");
  await p.waitForTimeout(600);
  assert.ok(await p.locator("#decision .dcard.k-kraken").isVisible(), "the kraken's card is on screen");
  await p.locator('#decision .opt[data-key="A"]').click(); // Proceed: fight
  await p.waitForFunction(() => window.__voyage2d.battle.playing, null, { timeout: 3000 });
  const st = await p.evaluate(() => ({ playing: window.__voyage2d.battle.playing, battle: !!window.__voyage2d.sim.kraken.battle, prompt: window.__voyage2d.prompt() }));
  assert.ok(st.playing && st.battle && st.prompt, "the fight is on, with a prompt to tap");
  assert.ok(await p.evaluate(() => document.body.classList.contains("battle")));
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("the styles are called Crimson and Manga in every language, never P5", async () => {
  const { p, ctx, errs } = await open("");
  for (const [lang, crimson, manga] of [["en", "Crimson", "Manga"], ["zh-TW", "緋紅", "漫畫"], ["zh-CN", "绯红", "漫画"]]) {
    await p.click(`#lang [data-lang="${lang}"]`);
    await p.click("#menuBtn");
    await p.click('#menu [data-tab="settings"]');
    const b = p.locator('#menu [data-set="style"]');
    assert.equal((await b.textContent()).trim(), crimson);
    await b.click();
    assert.equal((await b.textContent()).trim(), manga);
    await b.click();
    assert.ok(!/P5/.test(await p.evaluate(() => document.body.innerText)), "no P5 on screen in " + lang);
    await p.keyboard.press("Escape");
  }
  assert.deepEqual(errs, []);
  await ctx.close();
});

// ---------------------------------------------------------------- the decision card's infographic and card FX
const liveDiagrams = (p, dir) => p.evaluate((dir) => {
  const V = window.__voyage2d;
  V.ui.diagrams = { src: (id, lang) => `${dir}${id}.${lang}.html`, exists: async (u) => (await fetch(u, { method: "HEAD" })).ok };
  V.ui.decisionShown = null;
  V.ui.render(V.sim);
}, dir);

test("the card shows the board's diagram when the file exists (zh-CN falls back to zh-TW) and no image when it does not", async () => {
  const { p, ctx, errs } = await open("scene=decision");
  await p.waitForTimeout(600);
  await liveDiagrams(p, "tests/fixtures/diagrams/");
  await p.waitForFunction(() => document.querySelector("#decision .dgm.live iframe:not([hidden])"), null, { timeout: 5000 });
  assert.match(await p.locator("#decision .dgm iframe").getAttribute("src"), /D-1100\.en\.html$/);
  await p.evaluate(() => window.__voyage2d.ui.setLang("zh-CN"));
  await p.waitForFunction(() => /D-1100\.zh-TW\.html$/.test(document.querySelector("#decision .dgm iframe")?.getAttribute("src") || ""), null, { timeout: 5000 });
  // a decision with no diagram on the board: the figure goes, nothing broken is shown
  await liveDiagrams(p, "tests/fixtures/no-such-dir/");
  await p.waitForFunction(() => !document.querySelector("#decision .dgm"), null, { timeout: 5000 });
  assert.ok(await p.locator("#decision .dcard").isVisible(), "the card itself stays");
  assert.deepEqual(errs.filter((e) => !/404/.test(e)), []);
  await ctx.close();
});

test("the diagram follows the option under the pointer, the focus and the pick", async () => {
  const { p, ctx, errs } = await open("scene=decision");
  await p.waitForTimeout(700);
  // Playground: its own before/after, drawn from the options
  assert.ok(await p.locator("#decision .dgm.sim svg .after").count() >= 3);
  await p.hover('#decision .opt[data-key="B"]');
  assert.equal(await p.locator("#decision .dgm").getAttribute("data-hl"), "B");
  await p.waitForTimeout(200);
  assert.equal(await p.evaluate(() => getComputedStyle(document.querySelector('#decision .after[data-opt="B"]')).opacity), "1");
  await p.focus('#decision .opt[data-key="C"]');
  assert.equal(await p.locator("#decision .dgm").getAttribute("data-hl"), "C");
  await p.evaluate(() => window.__voyage2d.ui.choose("B"));
  assert.equal(await p.locator("#decision .dgm").getAttribute("data-hl"), "B");
  // Live: the board's diagram lights the picked option's part
  await liveDiagrams(p, "tests/fixtures/diagrams/");
  await p.waitForFunction(() => document.querySelector("#decision .dgm.live iframe:not([hidden])")?.contentDocument?.body, null, { timeout: 5000 });
  await p.waitForTimeout(200);
  await p.hover('#decision .opt[data-key="B"]');
  const lit = await p.evaluate(() => [...document.querySelector("#decision iframe").contentDocument.querySelectorAll(".v2d-pick")].map((e) => e.dataset.option));
  assert.deepEqual(lit, ["B"]);
  assert.deepEqual(errs, []);
  await ctx.close();
});

test("the card is dealt, fanned, sealed and tucked; with reduced motion it simply appears and answers at once", async () => {
  let { p, ctx, errs } = await open("scene=decision");
  await p.waitForTimeout(80);
  assert.equal(await p.evaluate(() => getComputedStyle(document.querySelector("#decision .dcard")).animationName), "deal");
  assert.ok(await p.evaluate(() => [...document.querySelectorAll("#decision .opt")].map((o) => getComputedStyle(o).animationName).every((n) => n === "fanin")));
  await p.waitForTimeout(700);
  const n0 = await p.evaluate(() => window.__voyage2d.sim.decisions.length);
  await p.click('#decision .opt[data-key="A"]');
  await p.waitForTimeout(60);
  assert.ok(await p.locator("#decision .seal").isVisible(), "the wax seal");
  assert.equal(await p.evaluate(() => window.__voyage2d.sim.decisions.length), n0, "the answer lands when the card has flown");
  await p.waitForTimeout(500);
  assert.equal(await p.evaluate(() => window.__voyage2d.sim.decisions.length), n0 - 1);
  await p.waitForTimeout(700);
  await p.click("#decision [data-later]");
  await p.waitForTimeout(40);
  assert.equal(await p.evaluate(() => getComputedStyle(document.querySelector("#decision .dcard")).animationName), "tuck");
  await p.waitForTimeout(400);
  assert.ok(await p.locator("#deckIcon").isVisible(), "the card went into the deck");
  await p.click("#deckIcon");
  await p.waitForTimeout(100);
  assert.ok(await p.locator("#decision .dcard").isVisible(), "the deck deals it again");
  assert.deepEqual(errs, []);
  await ctx.close();
  ({ p, ctx, errs } = await open("scene=decision", { viewport: { width: 1280, height: 800 }, reducedMotion: "reduce" }));
  await p.waitForTimeout(100);
  assert.equal(await p.evaluate(() => getComputedStyle(document.querySelector("#decision .dcard")).animationName), "none");
  const n1 = await p.evaluate(() => window.__voyage2d.sim.decisions.length);
  await p.click('#decision .opt[data-key="A"]');
  await p.waitForTimeout(80);
  assert.equal(await p.evaluate(() => window.__voyage2d.sim.decisions.length), n1 - 1, "answered at once");
  assert.equal(await p.locator("#decision .seal").count(), 0);
  assert.deepEqual(errs, []);
  await ctx.close();
});
