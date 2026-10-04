// node tools/uishot.mjs "<query>" <out.png> [device]
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { chromium, devices } = require("playwright");
const [q, out, dev = ""] = process.argv.slice(2);
const b = await chromium.launch();
const ctx = await b.newContext(dev ? { ...devices[dev] } : { viewport: { width: 1920, height: 1080 } });
const p = await ctx.newPage();
const errs = [];
p.on("pageerror", (e) => errs.push(e.message));
await p.goto("http://127.0.0.1:8791/concept/ui.html?" + q);
await p.waitForFunction(() => window.__ok);
await p.evaluate(() => document.fonts.ready);
await p.waitForTimeout(600);
await p.screenshot({ path: out });
console.log(JSON.stringify({ out, errs }));
await b.close();
