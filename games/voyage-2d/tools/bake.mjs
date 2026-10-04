// Bake the crew sprites: node tools/bake.mjs [only]
import { createRequire } from "node:module";
import { writeFileSync } from "node:fs";
const require = createRequire(import.meta.url);
const { chromium } = require("playwright");
const only = process.argv[2] && process.argv[2] !== "-" ? process.argv[2] : "";
const variant = process.argv[3] || "";
const b = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });
const p = await b.newPage({ viewport: { width: 1100, height: 1100 } });
const errs = [];
p.on("pageerror", (e) => errs.push("pageerror " + e.message));
p.on("console", (m) => m.type() === "error" && errs.push(m.text().slice(0, 400)));
await p.goto(`http://127.0.0.1:8791/bake/bake.html?${only ? "only=" + only : ""}&variant=${variant}`);
await p.waitForFunction(() => window.__bake || window.__bakeErr, null, { timeout: 600000 });
const err = await p.evaluate(() => window.__bakeErr);
if (err) { console.error(err, errs); process.exit(1); }
const res = await p.evaluate(() => window.__bake);
const out = variant ? `bake/sprites-${variant}.json` : only ? `bake/sprites-${only}.json` : "bake/sprites.json";
writeFileSync(out, JSON.stringify(res));
console.log(out, (JSON.stringify(res).length / 1e6).toFixed(2) + " MB", errs.length ? errs : "");
await b.close();
