// node tools/pass3.mjs <outDir> [only]  — pass 3 proof shots from the built artifact (dev server on :8791)
import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
const require = createRequire(import.meta.url);
const { chromium, devices } = require("playwright");
const [out = "shots/pass3", only = ""] = process.argv.slice(2);
mkdirSync(out, { recursive: true });
const b = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });
const errs = [];
async function page(q, { w = 1440, h = 810, phone = false, lang = "en" } = {}) {
  const ctx = await b.newContext(phone ? { ...devices["iPhone 13"] } : { viewport: { width: w, height: h } });
  await ctx.addInitScript((l) => { try { localStorage.setItem("v2d-lang", l); } catch {} window.__noStageHint = false; }, lang);
  const p = await ctx.newPage();
  p.on("pageerror", (e) => errs.push(q + ": " + e.message));
  p.on("console", (m) => m.type() === "error" && errs.push(q + ": " + m.text()));
  await p.goto(`http://127.0.0.1:8791/${phone ? "game2d.html" : "artifact-2d.html"}?` + q); // the artifact host adds the viewport meta; locally only the dev page has it
  await p.waitForFunction(() => window.__G?.ready, null, { timeout: 60000 });
  return { p, ctx };
}
const shot = (p, name) => p.screenshot({ path: `${out}/${name}.png` });
const want = (k) => !only || only.split(",").includes(k);

// the HUD in each language: the resting HUD with a toast, the menu (board), the decision card
if (want("hud")) for (const lang of ["en", "zh-TW", "zh-CN"]) {
  const { p, ctx } = await page("seed=7", { lang });
  await p.waitForTimeout(1200);
  await p.evaluate(() => { const V = window.__voyage2d; V.apply({ type: "dispatch" }); V.ui.event({ type: "merged", task: "T-101" }, V.sim); });
  await p.waitForTimeout(2600);
  await shot(p, `hud-${lang}`);
  await p.click("#menuBtn");
  await p.waitForTimeout(400);
  await shot(p, `menu-board-${lang}`);
  await p.click('#menu [data-tab="settings"]');
  await p.waitForTimeout(300);
  await shot(p, `menu-settings-${lang}`);
  await p.keyboard.press("Escape");
  await p.evaluate(() => window.__voyage2d.stage("decision"));
  await p.waitForTimeout(900);
  await shot(p, `decision-${lang}`);
  await ctx.close();
}
// phones: the HUD and the menu
if (want("phone")) for (const lang of ["en", "zh-TW"]) {
  const { p, ctx } = await page("seed=7&crew=18", { phone: true, lang });
  await p.waitForTimeout(2500);
  await shot(p, `phone-hud-${lang}`);
  await p.click("#menuBtn");
  await p.click('#menu [data-tab="roster"]');
  await p.waitForTimeout(400);
  await shot(p, `phone-roster-${lang}`);
  await ctx.close();
}
// each ship tier, the resting wide shot with every hand aboard and name tags
if (want("tiers")) for (const [n, id] of [[7, "sloop"], [12, "brig"], [18, "frigate"], [24, "line"]]) {
  const { p, ctx } = await page(`seed=7&crew=${n}`);
  await p.waitForTimeout(2200);
  await p.evaluate(() => { const V = window.__voyage2d; for (let i = 0; i < 6; i++) V.apply({ type: "dispatch" }); });
  // keep the stage clear of cards for the class portrait: answer whatever comes up
  for (let i = 0; i < 18; i++) {
    await p.waitForTimeout(500);
    await p.evaluate(() => { const V = window.__voyage2d; for (const d of V.sim.decisions.slice()) V.apply({ type: "answer", decision: d.id, key: d.kind === "kraken" ? "C" : "A" }); });
  }
  await shot(p, `tier-${n}-${id}`);
  if (n === 24) {
    // the detail card on a crewman, and the roster at 24
    const at = await p.evaluate(() => { const V = window.__voyage2d; const id = V.sim.crew.find((c) => c.task)?.id || "worker-1"; return [id, V.ui.h.crewAt(id)]; });
    await p.mouse.click(at[1][0], at[1][1] + 30);
    await p.waitForTimeout(300);
    await shot(p, "crew-card-24");
    await p.keyboard.press("Escape");
    await p.click("#menuBtn");
    await p.click('#menu [data-tab="roster"]');
    await p.waitForTimeout(400);
    await shot(p, "roster-24");
  }
  await ctx.close();
}
// the transform: sloop -> brig mid-frames, and brig -> line
if (want("transform")) for (const [from, to, tag] of [[7, 12, "sloop-brig"], [18, 24, "frigate-line"]]) {
  const { p, ctx } = await page(`seed=7&crew=${from}`);
  await p.waitForTimeout(2000);
  await p.evaluate((n) => window.__voyage2d.hire(n), to - from);
  for (const [i, ms] of [[1, 350], [2, 900], [3, 900], [4, 1500]]) {
    await p.waitForTimeout(ms);
    await shot(p, `transform-${tag}-${i}`);
  }
  await ctx.close();
}
// the same special at four classes: the cut-in, then the impact
if (want("special")) for (const [n, id] of [[7, "sloop"], [12, "brig"], [18, "frigate"], [24, "line"]]) {
  const { p, ctx } = await page(`seed=7&crew=${n}&scene=battle`);
  await p.waitForTimeout(1500);
  await p.evaluate(() => window.__voyage2d.special("broadside"));
  await p.waitForTimeout(n >= 24 ? 800 : 420);
  await shot(p, `special-${n}-${id}-cutin`);
  await p.evaluate(() => (window.__freezeOnImpact = false));
  await p.waitForFunction(() => window.__voyage2d.overlay.cuts.length === 0, null, { timeout: 8000 }).catch(() => {});
  await p.waitForTimeout(n >= 24 ? 900 : 700);
  await shot(p, `special-${n}-${id}-impact`);
  await ctx.close();
}
// victory at the ship of the line
if (want("victory")) for (const n of [7, 24]) {
  const { p, ctx } = await page(`seed=7&crew=${n}&scene=victory`);
  await p.waitForFunction(() => window.__voyage2d.battle.ending?.t > 1.2, null, { timeout: 40000 });
  await shot(p, `victory-${n}-gather`);
  await p.waitForFunction(() => window.__voyage2d.battle.ending?.t > 3.6, null, { timeout: 40000 });
  await shot(p, `victory-${n}`);
  await ctx.close();
}
console.log(JSON.stringify({ out, errs }));
await b.close();
