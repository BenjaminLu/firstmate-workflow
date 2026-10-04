// Side-by-side proofs, Crimson | Manga: the HUD, the menu's board sheet, the decision card and
// the battle HUD, at desktop and phone.   node tools/style-proof.mjs [base url]
import { createRequire } from "node:module";
import { readFileSync, unlinkSync } from "node:fs";
const { chromium } = createRequire(import.meta.url)("playwright");
const [base = "http://127.0.0.1:8766/artifact-2d.html"] = process.argv.slice(2);
const OUT = new URL("../proofs/", import.meta.url).pathname, HOOK = "__voyage2d";
const b = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });
const errors = [];
for (const [dev, vp] of [["desktop", { width: 1440, height: 900 }], ["phone", { width: 390, height: 844 }]]) {
  for (const shot of ["hud", "board", "decision", "battle"]) {
    const files = [];
    for (const style of ["p5", "manga"]) {
      const ctx = await b.newContext({ viewport: vp, isMobile: dev === "phone", hasTouch: dev === "phone" });
      const p = await ctx.newPage();
      p.on("pageerror", (e) => errors.push(`${dev} ${shot} ${style}: ${e.message}`));
      p.on("console", (m) => m.type() === "error" && errors.push(`${dev} ${shot} ${style}: ${m.text()}`));
      await p.goto(`${base}?seed=7&driver=0&style=${style}&lang=zh-TW`);
      await p.waitForFunction(() => window.__G?.ready, null, { timeout: 120000 });
      await p.evaluate(([H, shot]) => {
        const V = window[H];
        V.G.driver = false;
        V.ui.setLang(shot === "board" || shot === "battle" ? "en" : "zh-TW");
        if (shot === "hud") { V.stage("work"); V.ui.toast(V.ui.t.welcome, { icon: "⚓" }); V.ui.banner({ en: "The ship grows: Brig", tw: "船艦升級：雙桅橫帆船", cn: "船舰升级：双桅横帆船" }, "transform"); }
        if (shot === "board") { V.stage("work"); V.ui.toggle("board"); }
        if (shot === "decision") V.stage("decision");
        if (shot === "battle") V.stage("battle");
      }, [HOOK, shot]);
      await p.waitForTimeout(shot === "battle" ? 2600 : 1300);
      const f = `${OUT}style-${dev}-${shot}-${style}.png`;
      await p.screenshot({ path: f });
      files.push(f);
      await ctx.close();
    }
    // the pair on one sheet
    const pg = await b.newPage({ viewport: { width: vp.width * 2 + 30, height: vp.height + 50 } });
    const img = (f) => "data:image/png;base64," + readFileSync(f).toString("base64");
    await pg.setContent(`<body style="margin:0;background:#222;color:#fff;font:700 18px sans-serif;display:flex;gap:10px;padding:10px"><div><div>Crimson</div><img src="${img(files[0])}" width="${vp.width}"></div><div><div>Manga</div><img src="${img(files[1])}" width="${vp.width}"></div></body>`);
    await pg.screenshot({ path: `${OUT}style-${dev}-${shot}.png` });
    await pg.close();
    for (const f of files) unlinkSync(f);
  }
}
await b.close();
console.log(errors.length ? errors : "no console errors");
