// The rig's proportions per class, before and after, desktop and phone portrait:
//   node tools/rigproof.mjs <label> [url]   ->  proofs/rig/rig-<label>-<class>[-phone].png
// Also checks the default frame holds the whole ship (masthead to keel) and prints any errors.
import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
const { chromium } = createRequire(import.meta.url)("playwright");
const [label = "after", base = "http://127.0.0.1:8766/artifact-2d.html"] = process.argv.slice(2);
const OUT = new URL("../proofs/rig/", import.meta.url).pathname;
mkdirSync(OUT, { recursive: true });
const b = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });
const errs = [];
for (const [n, cls] of [[7, "sloop"], [12, "brig"], [18, "frigate"], [24, "line"]]) {
  for (const [vp, tag] of [[{ width: 1440, height: 900 }, ""], [{ width: 390, height: 844 }, "-phone"]]) {
    const ctx = await b.newContext({ viewport: vp });
    const p = await ctx.newPage();
    p.on("pageerror", (e) => errs.push(`${cls}${tag}: ${e.message}`));
    p.on("console", (m) => m.type() === "error" && errs.push(`${cls}${tag}: ${m.text()}`));
    await p.goto(`${base}?driver=0&crew=${n}`);
    await p.waitForFunction(() => window.__G?.ready);
    await p.evaluate(() => { window.__voyage2d.ui.dismissCaption?.(); window.__G.welcome = false; });
    await p.waitForFunction(() => { const W = window.__voyage2d.world; return !W.ship.transforming && Object.values(W.crew).every((c) => !W.agent(c.id).goal && !W.agent(c.id).link); }, null, { timeout: 40000 });
    await p.waitForTimeout(2500);
    const fr = await p.evaluate(() => {
      const V = window.__voyage2d, S = V.world.ship, top = S.rigTop ?? Math.min(...S.spec.masts.map((m) => m.top));
      const [, ty] = V.camera.toScreen(...S.toWorld(0, top - 200)), [, ky] = V.camera.toScreen(...S.toWorld(0, S.spec.bottom));
      return { top: Math.round(ty), keel: Math.round(ky), H: innerHeight };
    });
    await p.screenshot({ path: `${OUT}rig-${label}-${cls}${tag}.png` });
    console.log(cls + tag, JSON.stringify(fr), fr.top >= 0 && fr.keel <= fr.H ? "framed" : "CUT");
    await ctx.close();
  }
}
await b.close();
console.log(errs.length ? errs.join("\n") : "no errors");
