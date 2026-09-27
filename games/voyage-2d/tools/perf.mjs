// node tools/perf.mjs [mobile] : frame cost over a staged, auto-played battle
// mobile: a 390x844 phone, touch, 4x CPU throttling (the low tier)
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { chromium, devices } = require("playwright");
const mobile = process.argv[2] === "mobile";
const page = process.env.PAGE || "game2d.html";
const scene = process.env.SCENE || "battle";
const b = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });
const ctx = await b.newContext(mobile ? { ...devices["iPhone 13"] } : { viewport: { width: 1440, height: 900 } });
const p = await ctx.newPage();
const errs = [];
p.on("pageerror", (e) => errs.push("pageerror " + e.message));
p.on("console", (m) => (m.type() === "error" || m.type() === "warning") && errs.push(m.text().slice(0, 200)));
const cdp = await ctx.newCDPSession(p);
if (mobile) await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
const t0 = Date.now();
await p.goto(`http://127.0.0.1:8791/${page}?scene=${scene}&demo=1&crew=${process.env.CREW || 7}`);
await p.waitForFunction(() => window.__G?.ready, null, { timeout: 120000 });
const ready = Date.now() - t0;
await p.waitForTimeout(+(process.env.WAIT || 9000));
const perf = await p.evaluate(() => window.__voyage2d.perf());
if (process.env.HEAVY) console.log(JSON.stringify(await p.evaluate(() => window.__G.heavy)));
if (process.env.SHOT) await p.screenshot({ path: process.env.SHOT });
console.log(JSON.stringify({ mobile, scene, readyWallMs: ready, perf, errs }));
await b.close();
