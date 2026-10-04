// node tools/shot.mjs <page> <out.png> [w] [h] [waitMs]   (page relative to voyage-2d, with query)
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { chromium } = require("playwright");
const [page, out, w = 1400, h = 700, wait = 300] = process.argv.slice(2);
const b = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });
const p = await b.newPage({ viewport: { width: +w, height: +h } });
const errs = [];
p.on("pageerror", (e) => errs.push("pageerror " + e.message));
p.on("console", (m) => (m.type() === "error" || m.type() === "warning") && errs.push(m.type() + " " + m.text().slice(0, 300)));
await p.goto("http://127.0.0.1:8791/" + page);
try { await p.waitForFunction(() => window.__ok || window.__G?.ready, null, { timeout: 60000 }); } catch (e) { errs.push("not ready"); }
await p.waitForTimeout(+wait);
await p.screenshot({ path: out });
console.log(JSON.stringify({ out, errs }));
await b.close();
