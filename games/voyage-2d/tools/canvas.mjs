// node tools/canvas.mjs <page?query> <out.png> : save the page's #c canvas at full size
import { createRequire } from "node:module";
import { writeFileSync } from "node:fs";
const require = createRequire(import.meta.url);
const { chromium } = require("playwright");
const [page, out] = process.argv.slice(2);
const b = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });
const p = await b.newPage({ viewport: { width: 1600, height: 900 } });
const errs = [];
p.on("pageerror", (e) => errs.push(e.message));
p.on("console", (m) => m.type() === "error" && errs.push(m.text()));
await p.goto("http://127.0.0.1:8791/" + page);
await p.waitForFunction(() => window.__ok, null, { timeout: 120000 });
const data = await p.evaluate(() => document.getElementById("c").toDataURL("image/png"));
writeFileSync(out, Buffer.from(data.split(",")[1], "base64"));
console.log(JSON.stringify({ out, errs }));
await b.close();
