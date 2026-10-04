// Walk frame strips: the captain under control and a hand walking, 24 frames each (every 3rd
// frame at 60 fps, so 1.2 s), each drawn alone on a light card, for the build before and after.
//   node tools/walkstrip.mjs <label> <url> [query]
// writes proofs/walk/strip-<label>-captain.png and strip-<label>-npc.png
import { createRequire } from "node:module";
import { writeFileSync, mkdirSync } from "node:fs";
const require = createRequire(import.meta.url);
const { chromium } = require("playwright");
const [label = "after", url = "http://127.0.0.1:8766/artifact-2d.html", q = "driver=0&crew=12"] = process.argv.slice(2);
const OUT = new URL("../proofs/walk/", import.meta.url).pathname;
mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();
await page.goto(url + "?" + q);
await page.waitForFunction(() => window.__G?.ready, null, { timeout: 60000 });
await page.waitForTimeout(1500);
const shots = await page.evaluate(() => {
  const V = window.__voyage2d, W = V.world, G = window.__G, h = 1 / 60;
  G.paused = true;
  const N = 24, EVERY = 3, CW = 170, CH = 250;
  const strip = (p, title) => {
    const c = document.createElement("canvas");
    c.width = CW * 12; c.height = CH * 2 + 30;
    const g = c.getContext("2d");
    g.fillStyle = "#f3eee4"; g.fillRect(0, 0, c.width, c.height);
    g.fillStyle = "#1a1410"; g.font = "600 16px system-ui"; g.fillText(title, 8, 20);
    return { c, g, i: 0, p };
  };
  const snap = (S) => {
    const p = S.p, k = 0.6 / p.scale; // the same size for everyone
    const col = S.i % 12, row = Math.floor(S.i / 12);
    const g = S.g;
    g.save();
    g.beginPath(); g.rect(col * CW, 30 + row * CH, CW, CH); g.clip();
    g.strokeStyle = "rgba(0,0,0,.12)"; g.strokeRect(col * CW + 0.5, 30 + row * CH + 0.5, CW - 1, CH - 1);
    // the deck line
    g.fillStyle = "rgba(60,40,20,.25)"; g.fillRect(col * CW, 30 + row * CH + CH - 22, CW, 2);
    g.translate(col * CW + CW / 2 - p.x * 0.42 * k, 30 + row * CH + CH - 22 - p.y * 0.42 * k);
    g.scale(0.42 * k, 0.42 * k);
    p.draw(g, { shadow: true });
    g.restore();
    g.fillStyle = "#6b5f50"; g.font = "11px system-ui"; g.fillText(`f${S.i * 3}`, col * CW + 4, 30 + row * CH + 14);
    S.i++;
  };
  const step = (n, each) => { for (let i = 0; i < n; i++) { V.helm.update(h); W.update(h); each?.(i); } };
  step(60);
  // the captain: starts from rest, walks right (the strip covers the start and the stride)
  V.helm.enter();
  const cap = W.crew.captain;
  const S1 = strip(cap, "captain under control: ArrowRight held from f0 (every 3rd frame, 60 fps)");
  V.helm.held.add("ArrowRight");
  step(N * EVERY, (i) => i % EVERY === 0 && snap(S1));
  V.helm.held.clear();
  V.helm.leave({ quiet: true });
  // a hand: walks off from his spot along the deck
  const wk = Object.values(W.crew).find((p) => p.role === "worker");
  const a = W.agent(wk.id), d = W.G.decks[a.deck];
  const far = a.x - d.x0 > d.x1 - a.x ? d.x0 + 80 : d.x1 - 80;
  W.crowd.goTo(wk.id, { deck: a.deck, x: far, z: a.z });
  const S2 = strip(wk, `${wk.id} walking from rest (every 3rd frame, 60 fps)`);
  step(N * EVERY, (i) => i % EVERY === 0 && snap(S2));
  return [S1.c.toDataURL("image/png"), S2.c.toDataURL("image/png")];
});
writeFileSync(OUT + `strip-${label}-captain.png`, Buffer.from(shots[0].split(",")[1], "base64"));
writeFileSync(OUT + `strip-${label}-npc.png`, Buffer.from(shots[1].split(",")[1], "base64"));
await browser.close();
console.log("wrote", OUT + `strip-${label}-{captain,npc}.png`);
