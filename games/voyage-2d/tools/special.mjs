// node tools/special.mjs <name> <ms,ms,...> [w h] : fire a special in a staged battle and capture frames
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { chromium } = require("playwright");
const [name, times, w = 1440, h = 900] = process.argv.slice(2);
const b = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });
const p = await b.newPage({ viewport: { width: +w, height: +h } });
const errs = [];
p.on("pageerror", (e) => errs.push("pageerror " + e.message));
p.on("console", (m) => (m.type() === "error" || m.type() === "warning") && errs.push(m.text().slice(0, 200)));
await p.goto("http://127.0.0.1:8791/game2d.html?scene=battle&hud=1");
await p.waitForFunction(() => window.__G?.ready);
await p.waitForTimeout(1500);
if (process.env.BOT) await p.evaluate(() => (window.__botFight = true));
if (process.env.IMPACT) await p.evaluate(() => (window.__freezeOnImpact = true));
await p.evaluate((n) => window.__voyage2d.special(n), name);
if (process.env.IMPACT_AFTER) setTimeout(() => p.evaluate(() => (window.__freezeOnImpact = true)).catch(() => {}), +process.env.IMPACT_AFTER);
const t0 = Date.now(), out = [];
for (const t of times.split(",").map(Number)) {
  const wait = t - (Date.now() - t0);
  if (wait > 0) await p.waitForTimeout(wait);
  const f = `shots/sp-${name}-${t}.png`;
  await p.screenshot({ path: f });
  out.push(f);
}
console.log(JSON.stringify({ out, errs }));
await b.close();
