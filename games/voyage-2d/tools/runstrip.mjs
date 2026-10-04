// The run's frame strip: the captain under control on the ship of the line's waist walks, runs
// (Shift held), walks again and stops; every 4th frame at 60 fps, each drawn alone on a light
// card with the run's weight (r) and his ground speed (v, ship units a second).
//   node tools/runstrip.mjs [file]   writes proofs/run-strip.png. Serves itself.
import { createRequire } from "node:module";
import { createServer } from "node:http";
import { readFileSync, existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
const { chromium } = createRequire(import.meta.url)("playwright");
const file = process.argv[2] || "artifact-2d.html";
const ROOT = new URL("..", import.meta.url).pathname;
const server = createServer((req, res) => { const f = join(ROOT, decodeURIComponent(req.url.split("?")[0])); if (!existsSync(f)) return res.writeHead(404).end(); res.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(readFileSync(f)); });
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const b = await chromium.launch();
const p = await (await b.newContext({ viewport: { width: 1440, height: 900 } })).newPage();
const errs = [];
p.on("pageerror", (e) => errs.push(e.message));
await p.goto(`http://127.0.0.1:${server.address().port}/${file}?driver=0&crew=24`);
await p.waitForFunction(() => window.__G?.ready, null, { timeout: 60000 });
await p.waitForTimeout(1500);
const url = await p.evaluate(() => {
  const V = window.__voyage2d, W = V.world, G = window.__G, h = 1 / 60;
  G.paused = true;
  const EVERY = 4, COLS = 12, CW = 150, CH = 230;
  const plan = [[["ArrowRight"], 32, "walk"], [["ArrowRight", "Shift"], 104, "Shift: run"], [["ArrowRight"], 40, "walk"], [[], 16, "stop"]];
  const n = plan.reduce((s, x) => s + x[1], 0) / EVERY, rows = Math.ceil(n / COLS);
  const c = document.createElement("canvas");
  c.width = CW * COLS; c.height = CH * rows + 30;
  const g = c.getContext("2d");
  g.fillStyle = "#f3eee4"; g.fillRect(0, 0, c.width, c.height);
  g.fillStyle = "#1a1410"; g.font = "600 16px system-ui";
  g.fillText("the captain's run (2.5D): walk → Shift held (eases in) → released (eases out) → stop · every 4th frame at 60 fps · r = run weight, v = ground speed", 8, 20);
  const step = (k, each) => { for (let i = 0; i < k; i++) { V.helm.update(h); W.update(h); each?.(i); } };
  step(60);
  V.helm.enter();
  const cap = W.crew.captain, a = W.agent("captain"), C = W.crowd, d = W.G.decks.main;
  Object.assign(a, C.findFree("main", d.x0 + 120, 120, a.r, a), { link: null, goal: null, plan: null });
  step(30);
  let i = 0, px = a.x;
  for (const [keys, len, tag] of plan) {
    V.helm.held.clear();
    for (const k of keys) V.helm.held.add(k);
    step(len, (f) => {
      const v = (a.x - px) * 60;
      px = a.x;
      if (f % EVERY) return;
      const col = i % COLS, row = Math.floor(i / COLS), k = 0.6 / cap.scale;
      g.save();
      g.beginPath(); g.rect(col * CW, 30 + row * CH, CW, CH); g.clip();
      g.fillStyle = tag.startsWith("Shift") ? "rgba(230,0,18,.06)" : "rgba(0,0,0,0)"; g.fillRect(col * CW, 30 + row * CH, CW, CH);
      g.strokeStyle = "rgba(0,0,0,.12)"; g.strokeRect(col * CW + 0.5, 30 + row * CH + 0.5, CW - 1, CH - 1);
      g.fillStyle = "rgba(60,40,20,.25)"; g.fillRect(col * CW, 30 + row * CH + CH - 22, CW, 2);
      g.translate(col * CW + CW / 2 - cap.x * 0.4 * k, 30 + row * CH + CH - 22 - cap.y * 0.4 * k);
      g.scale(0.4 * k, 0.4 * k);
      cap.draw(g, { shadow: true });
      g.restore();
      g.fillStyle = "#6b5f50"; g.font = "11px system-ui";
      g.fillText(`${tag} r${cap.runW.toFixed(2)} v${v.toFixed(0)}`, col * CW + 4, 30 + row * CH + 14);
      i++;
    });
  }
  V.helm.leave({ quiet: true });
  return c.toDataURL("image/png");
});
writeFileSync(ROOT + "proofs/run-strip.png", Buffer.from(url.split(",")[1], "base64"));
await b.close(); server.close();
console.log(errs.length ? errs.join("\n") : "wrote proofs/run-strip.png");
