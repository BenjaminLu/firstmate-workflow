// Crimson and Manga are two complete looks of the same HUD: in both, at desktop 1440x900 and on
// a phone 390x844, in all three languages, every control is on screen, not covered, not
// overflowing its box, clickable, and does what it does. The style switch applies live.
import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFileSync, existsSync } from "node:fs";
import { createRequire } from "node:module";
import { join, extname } from "node:path";

const { chromium } = createRequire(import.meta.url)("playwright");
const ROOT = new URL("..", import.meta.url).pathname;
const PAGE = "artifact-2d.html", HOOK = "__voyage2d";
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

// on screen, the topmost thing at its centre, and its text inside its box
async function usable(p, sel, { click = true } = {}) {
  const r = await p.evaluate(([sel, click]) => {
    const el = document.querySelector(sel);
    if (!el) return { sel, why: "missing" };
    const b = el.getBoundingClientRect(), cs = getComputedStyle(el);
    if (!b.width || !b.height || cs.visibility === "hidden" || cs.display === "none") return { sel, why: "hidden" };
    if (b.left < -1 || b.top < -1 || b.right > innerWidth + 1 || b.bottom > innerHeight + 1) return { sel, why: `off screen ${[b.left, b.top, b.right, b.bottom].map(Math.round)}` };
    if (el.scrollWidth > el.clientWidth + 2 && cs.overflowX !== "auto") return { sel, why: `text overflows ${el.scrollWidth}>${el.clientWidth}` };
    if (click) {
      const hit = document.elementFromPoint(b.left + b.width / 2, b.top + b.height / 2);
      if (!hit || !(el === hit || el.contains(hit))) return { sel, why: "covered by " + (hit?.id || hit?.className || hit?.tagName) };
      if (b.width < 34 || b.height < 34) return { sel, why: `hit target ${Math.round(b.width)}x${Math.round(b.height)}` };
    }
    return null;
  }, [sel, click]);
  assert.equal(r, null, JSON.stringify(r));
}

const VIEWS = [["desktop", { width: 1440, height: 900 }], ["phone", { width: 390, height: 844 }]];
for (const style of ["p5", "manga"]) for (const [dev, viewport] of VIEWS) {
  test(`every HUD control works in ${style === "p5" ? "Crimson" : "Manga"}, ${dev}, in EN, 繁 and 简`, async () => {
    const ctx = await browser.newContext({ viewport, isMobile: dev === "phone", hasTouch: dev === "phone" });
    const p = await ctx.newPage();
    const errs = [];
    p.on("pageerror", (e) => errs.push(e.message));
    p.on("console", (m) => m.type() === "error" && !/Failed to load resource/.test(m.text()) && errs.push(m.text()));
    const V = (f, a) => p.evaluate(([f, a, H]) => new Function("V", "a", "return (" + f + ")(V, a)")(window[H], a), [f.toString(), a, HOOK]);
    for (const lang of ["en", "zh-TW", "zh-CN"]) {
      await p.goto(base + PAGE + "?seed=7&driver=0&style=" + style);
      await p.waitForFunction(() => window.__G?.ready, null, { timeout: 120000 });
      await V((V) => { V.G.driver = false; document.querySelector("#toasts").innerHTML = ""; V.ui.dismissCaption?.(); });
      assert.equal(await p.evaluate(() => document.body.dataset.style), style);
      await usable(p, `#lang [data-lang="${lang}"]`);
      await p.click(`#lang [data-lang="${lang}"]`);
      assert.equal(await p.evaluate(() => document.documentElement.lang), lang);
      for (const sel of ["#status .chip:nth-child(1)", "#status .chip:nth-child(2)", "#waitChip", "#shipChip"]) await usable(p, sel, { click: false });
      await usable(p, "#modeBadge", { click: false });
      await usable(p, "#menuBtn");
      // a toast and the banner stay on screen
      await V((V) => { V.ui.toast(V.ui.t.welcome, { icon: "⚓" }); V.ui.banner({ en: "The ship grows: Brig", tw: "船艦升級：雙桅橫帆船", cn: "船舰升级：双桅横帆船" }, "transform"); });
      await p.waitForFunction(() => { const t = document.querySelector("#toasts .toast"); return t && !t.getAnimations().some((a) => a.playState === "running") && t.getBoundingClientRect().left >= 0; }, null, { timeout: 5000 }); // slid in
      await p.waitForTimeout(300);
      await usable(p, "#toasts .toast", { click: false });
      await usable(p, "#banner span", { click: false });
      // the menu: every tab, then the settings' controls
      await p.click("#menuBtn");
      assert.ok(await p.evaluate(() => document.body.classList.contains("menu")));
      for (const tab of ["roster", "chart", "board", "settings"]) {
        await usable(p, `#menu nav [data-tab="${tab}"]`);
        await p.click(`#menu nav [data-tab="${tab}"]`);
        assert.equal(await p.evaluate(() => document.querySelector("#menu nav [aria-current]")?.dataset.tab), tab);
        await usable(p, "#sheet h2", { click: false });
      }
      await usable(p, '#menu [data-set="sound"]');
      const snd = await p.getAttribute('#menu [data-set="sound"]', "aria-pressed");
      await p.click('#menu [data-set="sound"]');
      assert.notEqual(await p.getAttribute('#menu [data-set="sound"]', "aria-pressed"), snd, "sound toggles");
      await p.click('#menu [data-set="sound"]');
      const n0 = await V((V) => V.sim.crew.length);
      await usable(p, '#menu [data-set="hands"][data-v="1"]');
      await p.click('#menu [data-set="hands"][data-v="1"]');
      assert.equal(await V((V) => V.sim.crew.length), n0 + 1, "a hand aboard");
      await p.click('#menu [data-set="hands"][data-v="-1"]');
      assert.equal(await V((V) => V.sim.crew.length), n0, "and ashore");
      for (const k of ["camera", "speed", "style"]) await usable(p, `#menu [data-set="${k}"]`);
      await usable(p, '#menu nav [data-tab="resume"]');
      await p.click('#menu nav [data-tab="resume"]');
      assert.ok(!(await p.evaluate(() => document.body.classList.contains("menu"))));
      // the decision card: an option, Later, the deck, then an answer
      await V((V) => V.stage("decision"));
      await p.waitForSelector("#decision .dcard", { state: "visible" });
      await p.waitForTimeout(700);
      for (const k of ["A", "B", "C"]) await usable(p, `#decision .opt[data-key="${k}"]`);
      await usable(p, "#decision [data-later]");
      await p.click("#decision [data-later]");
      await p.waitForTimeout(500);
      await usable(p, "#deckIcon");
      await p.click("#deckIcon");
      await p.waitForSelector("#decision .dcard", { state: "visible" });
      await p.waitForTimeout(700);
      const d0 = await V((V) => V.sim.decisions.length);
      await p.click('#decision .opt[data-key="A"]');
      await p.waitForFunction(([H, d0]) => window[H].sim.decisions.length < d0, [HOOK, d0], { timeout: 4000 });
    }
    // the fight: the special button lights and fires, in this style
    await V((V) => V.stage("battle"));
    await p.waitForTimeout(600);
    await V((V) => { V.battle.b.gauge = 100; });
    await p.waitForSelector("#special", { state: "visible" });
    await usable(p, "#special");
    const g0 = await V((V) => V.battle.b.gauge);
    await p.locator("#special").dispatchEvent("pointerdown");
    await p.waitForTimeout(200);
    assert.ok((await V((V) => V.battle.b.gauge)) < g0, "the special fired");
    // the style switches live, both ways, and is remembered
    await V((V) => V.battle.play(false));
    await p.waitForTimeout(400);
    await p.click("#menuBtn");
    await p.click('#menu nav [data-tab="settings"]');
    await p.click('#menu [data-set="style"]');
    const other = style === "p5" ? "manga" : "p5";
    assert.equal(await p.evaluate(() => document.body.dataset.style), other, "live, no reload");
    await p.goto(base + PAGE + "?seed=7"); // no style in the URL: the stored choice
    await p.waitForFunction(() => window.__G?.ready, null, { timeout: 120000 });
    assert.equal(await p.evaluate(() => document.body.dataset.style), other, "remembered");
    assert.deepEqual(errs, []);
    await ctx.close();
  });
}
