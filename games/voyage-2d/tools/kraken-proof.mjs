// Proof: in the built Playground page the kraken rises on its own, its card comes up, and
// Proceed: fight starts the fight. Fast-forwards with ?speed. Screenshots to proofs/.
//   node tools/kraken-proof.mjs [base url] [seeds...]
import { createRequire } from "node:module";
const { chromium } = createRequire(import.meta.url)("playwright");
const [base = "http://127.0.0.1:8766/artifact-2d.html", ...seedArgs] = process.argv.slice(2);
const seeds = seedArgs.length ? seedArgs.map(Number) : [7, 1, 42];
const OUT = new URL("../proofs/", import.meta.url).pathname;
const b = await chromium.launch({ args: ["--use-angle=metal", "--enable-gpu"] });
let bad = 0;
for (const seed of seeds) {
  const p = await b.newPage({ viewport: { width: 1440, height: 900 } });
  const errs = [];
  p.on("pageerror", (e) => errs.push(e.message));
  p.on("console", (m) => m.type() === "error" && errs.push(m.text()));
  await p.goto(`${base}?seed=${seed}&speed=10`);
  await p.waitForFunction(() => window.__G?.ready, null, { timeout: 60000 });
  await p.waitForFunction(() => window.__voyage2d.sim.kraken.arms.length > 0, null, { timeout: 60000, polling: 50 });
  const at = await p.evaluate(() => ({ t: +window.__voyage2d.sim.t.toFixed(1), arms: window.__voyage2d.sim.kraken.arms }));
  await p.evaluate(() => (window.__G.speed = 1));
  await p.waitForFunction(() => window.__voyage2d.world.kraken.rise > 0.9, null, { timeout: 15000 });
  await p.waitForTimeout(800);
  const card = await p.locator("#decision .dcard.k-kraken").isVisible();
  await p.screenshot({ path: `${OUT}kraken-rises-seed${seed}.png` });
  await p.locator('#decision .dcard.k-kraken .opt[data-key="A"]').click();
  await p.waitForFunction(() => window.__voyage2d.battle.playing, null, { timeout: 5000 });
  await p.waitForTimeout(2500);
  await p.screenshot({ path: `${OUT}kraken-battle-seed${seed}.png` });
  console.log(JSON.stringify({ seed, simT: at.t, arms: at.arms, card, battle: true, errors: errs }));
  if (!card || errs.length) bad++;
  await p.close();
}
await b.close();
process.exit(bad ? 1 : 0);
