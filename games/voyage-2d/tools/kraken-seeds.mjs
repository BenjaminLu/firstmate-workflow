// When does the kraken rise in a Playground voyage? Runs the sim under the Playground's own
// crew driver (src/main.js playgroundTick: dispatch every 1.6 s when work is ready and a hand
// is idle, a new task every 40 s when nothing is ready; nobody answers a card) and prints the
// first kraken_arm per seed.   node tools/kraken-seeds.mjs [seconds] [seed ...]
import { createSim, step } from "../v3src/sim/sim.js";

export function firstKraken(seed, limit = 900) {
  let s = createSim(seed);
  const drv = { next: 0, newAt: 30 };
  for (let i = 0; i < limit * 10; i++) {
    const r = step(s, { type: "tick", dt: 0.1 });
    s = r.state;
    const arm = r.events.find((e) => e.type === "kraken_arm");
    if (arm) return { t: +s.t.toFixed(1), task: arm.task };
    if (s.t < drv.next) continue;
    drv.next = s.t + 1.6;
    const ready = s.tasks.filter((t) => t.lane === "ready").length;
    const idle = s.crew.filter((c) => c.role === "worker" && c.state === "idle").length;
    if (ready && idle) s = step(s, { type: "dispatch" }).state;
    else if (s.t > drv.newAt && ready < 1) (drv.newAt = s.t + 40), (s = step(s, { type: "newTask" }).state);
  }
  return null;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [lim = "900", ...seeds] = process.argv.slice(2);
  for (const seed of (seeds.length ? seeds : ["1", "2", "3", "7", "42"]).map(Number)) console.log("seed", seed, JSON.stringify(firstKraken(seed, +lim)));
}
