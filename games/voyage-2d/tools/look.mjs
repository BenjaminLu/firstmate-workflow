// A quick look at the game: node tools/look.mjs "<query>" <out.png> [w] [h] [waitMs] [js-to-run-before-shot]
// Serves from the local server (http://127.0.0.1:8766). Prints console errors.
import { createRequire } from "node:module";
const { chromium } = createRequire(import.meta.url)("playwright");
const [q = "", out = "build/wip/look.png", w = 1440, h = 900, wait = 1500, js = ""] = process.argv.slice(2);
const b = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });
const p = await b.newPage({ viewport: { width: +w, height: +h } });
const errs = [];
p.on("pageerror", (e) => errs.push("pageerror " + e.message));
p.on("console", (m) => m.type() === "error" && errs.push(m.text().slice(0, 300)));
await p.goto("http://127.0.0.1:8766/artifact-2d.html?" + q);
await p.waitForFunction(() => window.__G?.ready, null, { timeout: 60000 });
if (js) console.log(JSON.stringify(await p.evaluate(js)));
await p.waitForTimeout(+wait);
await p.screenshot({ path: out });
console.log(JSON.stringify({ out, errs: errs.concat(await p.evaluate(() => window.__G.errors)) }));
await b.close();
