// The crew's boxes on deck: each crewman drawn alone, his inked pixels measured, in ship
// space. Prints every overlapping pair.   node tools/crewbox.mjs [base] [crew counts...]
import { createRequire } from "node:module";
const { chromium } = createRequire(import.meta.url)("playwright");
const [base = "http://127.0.0.1:8766/artifact-2d.html", ...ns] = process.argv.slice(2);
export const BOXES = () => {
  const V = window.__voyage2d, W = V.world, out = [];
  const c = document.createElement("canvas");
  c.width = 900; c.height = 900;
  const g = c.getContext("2d", { willReadFrequently: true });
  for (const p of Object.values(W.crew)) {
    if (p.alpha < 0.5) continue;
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.clearRect(0, 0, 900, 900);
    const x = p.x, y = p.y;
    g.translate(450 - x, 800 - y);
    p.draw(g, { shadow: false });
    const d = g.getImageData(0, 0, 900, 900).data;
    let x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9;
    for (let j = 0; j < 900; j += 2) for (let i = 0; i < 900; i += 2) if (d[(j * 900 + i) * 4 + 3] > 40) (x0 = Math.min(x0, i)), (x1 = Math.max(x1, i)), (y0 = Math.min(y0, j)), (y1 = Math.max(y1, j));
    out.push({ id: p.id, x0: x0 - 450 + x, x1: x1 - 450 + x, y0: y0 - 800 + y, y1: y1 - 800 + y });
  }
  const hits = [];
  for (let i = 0; i < out.length; i++) for (let j = i + 1; j < out.length; j++) {
    const a = out[i], b = out[j];
    if (a.x0 < b.x1 && b.x0 < a.x1 && a.y0 < b.y1 && b.y0 < a.y1) hits.push(a.id + "×" + b.id);
  }
  return { boxes: out.map((b) => ({ id: b.id, x: [Math.round(b.x0), Math.round(b.x1)], y: [Math.round(b.y0), Math.round(b.y1)] })), hits };
};
if (import.meta.url === `file://${process.argv[1]}`) {
  const b = await chromium.launch();
  for (const n of (ns.length ? ns : ["7", "12", "18", "24"]).map(Number)) {
    const p = await b.newPage({ viewport: { width: 1440, height: 900 } });
    await p.goto(`${base}?crew=${n}&driver=0`);
    await p.waitForFunction(() => window.__G?.ready);
    await p.evaluate(() => (window.__G.paused = true));
    const r = await p.evaluate(BOXES);
    console.log(n, r.world ?? "", JSON.stringify(r.hits), JSON.stringify(r.boxes));
    await p.close();
  }
  await b.close();
}
