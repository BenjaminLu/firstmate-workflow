// node tools/sheet.mjs out.png cols a.png b.png ...   a contact sheet (via the local server)
import { createRequire } from "node:module";
import { writeFileSync } from "node:fs";
const require = createRequire(import.meta.url);
const { chromium } = require("playwright");
const [out, cols, ...files] = process.argv.slice(2);
const html = `<body style="margin:0;background:#222;display:grid;grid-template-columns:repeat(${cols},1fr);gap:4px">${files.map((f) => `<div style="position:relative"><img src="/${f}" style="width:100%;display:block"><span style="position:absolute;left:4px;top:4px;background:#000a;color:#fff;font:12px sans-serif;padding:2px 4px">${f.split("/").pop()}</span></div>`).join("")}</body>`;
writeFileSync("shots/_sheet.html", html);
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 1440, height: 400 } });
await p.goto("http://127.0.0.1:8791/shots/_sheet.html");
await p.waitForLoadState("networkidle");
await p.screenshot({ path: out, fullPage: true });
await b.close();
console.log(out);
