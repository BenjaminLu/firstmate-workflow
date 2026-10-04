// Proof shots for the wider stairs, into proofs/:
//   stairs-<tag>-<class>.png        the stair down from the waist to the gun deck, framed close
//   stairs-<tag>-<class>-plan.png   every deck from above (x along, z across): stairs and hatches
//                                    in red, everything else grey; the flight's width in z reads
// node tools/stairproof.mjs <tag> [file]   (tag: before | after; file: artifact-2d.html). Serves itself.
import { createRequire } from "node:module";
import { createServer } from "node:http";
import { readFileSync, existsSync } from "node:fs";
import { join, extname } from "node:path";
const { chromium } = createRequire(import.meta.url)("playwright");
const tag = process.argv[2] || "after", file = process.argv[3] || "artifact-2d.html";
const ROOT = new URL("..", import.meta.url).pathname, OUT = ROOT + "proofs/";
const server = createServer((req, res) => {
  const f = join(ROOT, decodeURIComponent(req.url.split("?")[0]));
  if (!existsSync(f)) return res.writeHead(404).end();
  res.writeHead(200, { "content-type": extname(f) === ".html" ? "text/html; charset=utf-8" : "application/octet-stream" }).end(readFileSync(f));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}/${file}`;
const b = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });
const errs = [];
for (const [n, cls] of [[7, "sloop"], [12, "brig"], [18, "frigate"], [24, "line"]]) {
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const p = await ctx.newPage();
  p.on("pageerror", (e) => errs.push(cls + ": " + e.message));
  p.on("console", (m) => m.type() === "error" && errs.push(cls + ": " + m.text()));
  await p.goto(`${base}?driver=0&crew=${n}`);
  await p.waitForFunction(() => window.__G?.ready, null, { timeout: 60000 });
  await p.evaluate(() => { window.__voyage2d.ui.dismissCaption?.(); window.__G.welcome = false; });
  await p.waitForFunction(() => { const W = window.__voyage2d.world; return !W.ship.transforming && Object.values(W.crew).every((c) => !W.agent(c.id).goal && !W.agent(c.id).link); }, null, { timeout: 40000 });
  // the camera on the companionway (the waist down to the gun deck)
  await p.evaluate(() => {
    const V2 = window.__voyage2d, W = V2.world, L = W.G.links.find((l) => l.id === "main-gun");
    const [x0, y0] = L.path[1], [x1, y1] = L.path[2];
    const [wx, wy] = W.ship.toWorld((x0 + x1) / 2, (y0 + y1) / 2 - 40);
    V2.director.follow = () => ({ x: wx, y: wy, h: 900 });
  });
  await p.waitForTimeout(1800);
  await p.screenshot({ path: `${OUT}stairs-${tag}-${cls}.png` });
  // the plan: every deck from above
  await p.evaluate(({ tag, cls }) => {
    const G = window.__voyage2d.world.G, decks = Object.values(G.decks).filter((d) => d.id !== "nest").sort((a, b) => a.y - b.y);
    const x0 = Math.min(...decks.map((d) => d.x0)), x1 = Math.max(...decks.map((d) => d.x1));
    const W = 1400, k = (W - 40) / (x1 - x0), rowH = 420 * k + 34, H = decks.length * rowH + 50;
    const c = document.createElement("canvas");
    c.id = "__plan";
    c.width = W; c.height = H;
    Object.assign(c.style, { position: "fixed", left: "20px", top: "20px", zIndex: 99999, background: "#f7f1e6" });
    const g = c.getContext("2d");
    g.fillStyle = "#f7f1e6"; g.fillRect(0, 0, W, H);
    g.font = "bold 18px system-ui"; g.fillStyle = "#222";
    g.fillText(`${cls} — ${tag}: decks from above (x along the ship, z across; far rail at the top of each strip)`, 20, 26);
    decks.forEach((d, i) => {
      const top = 44 + i * rowH, X = (x) => 20 + (x - x0) * k, Zs = (z) => top + 22 + (d.depth - z) * k;
      g.fillStyle = "#222"; g.font = "14px system-ui"; g.fillText(d.id, 20, top + 16);
      g.fillStyle = "#e3d2b4"; g.fillRect(X(d.x0), Zs(d.depth), (d.x1 - d.x0) * k, d.depth * k);
      for (const o of G.obstacles) if (o.deck === d.id) {
        const hot = o.kind === "stairs" || o.kind === "hatch";
        g.fillStyle = hot ? "rgba(200,30,30,.8)" : "rgba(90,90,90,.55)";
        g.fillRect(X(o.x0), Zs(o.z1), (o.x1 - o.x0) * k, (o.z1 - o.z0) * k);
        if (hot) { g.fillStyle = "#fff"; g.font = "bold 11px system-ui"; g.fillText(`${o.kind} ${Math.round(o.z1 - o.z0)}`, X(o.x0) + 3, Zs(o.z1) + 13); }
      }
      for (const l of G.links) for (const e of [l.a, l.b]) if (e.deck === d.id) { g.fillStyle = "#1a5fd0"; g.beginPath(); g.arc(X(e.x), Zs(e.z), 4, 0, 7); g.fill(); }
    });
    document.body.appendChild(c);
  }, { tag, cls });
  await p.locator("#__plan").screenshot({ path: `${OUT}stairs-${tag}-${cls}-plan.png` });
  await ctx.close();
}
await b.close();
server.close();
console.log(errs.length ? errs.join("\n") : "no errors");
