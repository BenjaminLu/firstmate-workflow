// Before/after shots of the opening crew (t = 0) at desktop and phone portrait, per class.
//   node tools/spacing-proof.mjs <page> <tag>
import { createRequire } from "node:module";
const { chromium } = createRequire(import.meta.url)("playwright");
const [page = "artifact-2d.html", tag = "after"] = process.argv.slice(2);
const OUT = new URL("../proofs/", import.meta.url).pathname;
const b = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });
for (const [vw, vh, dev] of [[1440, 900, "desktop"], [390, 844, "phone"]]) for (const n of [7, 12, 18, 24]) {
  const p = await b.newPage({ viewport: { width: vw, height: vh }, deviceScaleFactor: dev === "phone" ? 2 : 1, isMobile: dev === "phone", hasTouch: dev === "phone" });
  const errs = [];
  p.on("pageerror", (e) => errs.push(e.message));
  p.on("console", (m) => m.type() === "error" && errs.push(m.text()));
  await p.goto(`http://127.0.0.1:8766/${page}?seed=7&driver=0&crew=${n}`);
  await p.waitForFunction(() => window.__G?.ready, null, { timeout: 60000 });
  await p.evaluate(() => { window.__G.paused = true; document.querySelector("#toasts")?.remove(); window.__voyage2d.ui.dismissCaption?.(); });
  await p.waitForTimeout(400);
  await p.screenshot({ path: `${OUT}opening-${tag}-${dev}-${n}.png` });
  if (errs.length) console.log(dev, n, errs);
  await p.close();
}
await b.close();
