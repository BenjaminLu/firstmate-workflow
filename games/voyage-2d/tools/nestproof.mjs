// The crow's nest per class, before and after raising it, desktop and phone portrait:
//   node tools/nestproof.mjs <label> [url]  ->  proofs/nest-<label>-<class>[-phone].png
//                                               proofs/nest-<label>-<class>-mast.png (the main mast, close)
// Prints the frame (masthead to keel) and any console errors.
import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
const { chromium } = createRequire(import.meta.url)("playwright");
const [label = "after", base = "http://127.0.0.1:8766/artifact-2d.html"] = process.argv.slice(2);
const OUT = new URL("../proofs/", import.meta.url).pathname;
mkdirSync(OUT, { recursive: true });
const b = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });
const errs = [];
for (const style of ["&style=p5", "&style=manga"]) {
  for (const [n, cls] of [[7, "sloop"], [12, "brig"], [18, "frigate"], [24, "line"]]) {
    for (const [vp, tag] of [[{ width: 1440, height: 900 }, ""], [{ width: 390, height: 844 }, "-phone"]]) {
      const ctx = await b.newContext({ viewport: vp });
      const p = await ctx.newPage();
      p.on("pageerror", (e) => errs.push(`${cls}${tag}${style}: ${e.message}`));
      p.on("console", (m) => m.type() === "error" && errs.push(`${cls}${tag}${style}: ${m.text()}`));
      await p.goto(`${base}?driver=0&crew=${n}${style}`);
      await p.waitForFunction(() => window.__G?.ready);
      await p.evaluate(() => { window.__voyage2d.ui.dismissCaption?.(); window.__G.welcome = false; window.__voyage2d.station("worker-3", "top", "lookout"); });
      await p.waitForFunction(() => { const W = window.__voyage2d.world; return !W.ship.transforming && Object.values(W.crew).every((c) => !W.agent(c.id).goal && !W.agent(c.id).link); }, null, { timeout: 40000 });
      await p.waitForTimeout(2500);
      const fr = await p.evaluate(() => {
        const V = window.__voyage2d, S = V.world.ship, top = S.rigTop;
        const [, ty] = V.camera.toScreen(...S.toWorld(0, top - 200)), [, ky] = V.camera.toScreen(...S.toWorld(0, S.spec.bottom));
        const m = S.spec.masts[Math.min(S.spec.masts.length - 1, S.spec.masts.length === 1 ? 0 : 1)];
        const [nx, ny] = V.camera.toScreen(...S.toWorld(m.x, m.nest ?? -900));
        return { top: Math.round(ty), keel: Math.round(ky), H: innerHeight, nest: m.nest ? [Math.round(nx), Math.round(ny)] : null };
      });
      if (style === "&style=manga") { if (!tag) await p.screenshot({ path: `${OUT}nest-${label}-${cls}-manga.png` }); }
      else {
        await p.screenshot({ path: `${OUT}nest-${label}-${cls}${tag}.png` });
        if (!tag && fr.nest) {
          const w = 520, h = 520, x = Math.max(0, Math.min(1440 - w, fr.nest[0] - w / 2)), y = Math.max(0, Math.min(900 - h, fr.nest[1] - h * 0.55));
          await p.screenshot({ path: `${OUT}nest-${label}-${cls}-mast.png`, clip: { x, y, width: w, height: h } });
        }
      }
      console.log(cls + tag + style, JSON.stringify(fr), fr.top >= 0 && fr.keel <= fr.H ? "framed" : "CUT");
      await ctx.close();
    }
  }
}
await b.close();
console.log(errs.length ? errs.join("\n") : "no errors");
