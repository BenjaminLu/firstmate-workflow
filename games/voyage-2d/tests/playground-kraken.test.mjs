// Every Playground voyage meets the kraken early. The sim is run under the Playground's own
// crew driver (main.js playgroundTick: dispatch every 1.6 s while work is ready and a hand is
// idle, a new task every 40 s when nothing is ready) and nobody answers a card, as when the
// captain only watches. The first ready task is the stubborn one (createSim).
import test from "node:test";
import assert from "node:assert/strict";
import { createSim, step } from "../v3src/sim/sim.js";
import { CONFIG } from "../v3src/sim/config.js";

function watch(seed, limit) {
  let s = createSim(seed);
  const drv = { next: 0, newAt: 30 };
  const seen = [];
  for (let i = 0; i < limit * 10; i++) {
    const r = step(s, { type: "tick", dt: 0.1 });
    s = r.state;
    for (const e of r.events) if (/^kraken_/.test(e.type)) seen.push({ t: s.t, cards: s.decisions.map((d) => d.kind), ...e });
    if (s.t < drv.next) continue;
    drv.next = s.t + 1.6;
    const ready = s.tasks.filter((t) => t.lane === "ready").length;
    const idle = s.crew.filter((c) => c.role === "worker" && c.state === "idle").length;
    if (ready && idle) s = step(s, { type: "dispatch" }).state;
    else if (s.t > drv.newAt && ready < 1) (drv.newAt = s.t + 40), (s = step(s, { type: "newTask" }).state);
  }
  return { s, seen };
}

test("the kraken rises within 150 s of every Playground voyage (seeds 1, 2, 3, 7, 42 and more)", () => {
  for (const seed of [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 42, 99, 1234]) {
    const { seen } = watch(seed, 150);
    const arm = seen.find((e) => e.type === "kraken_arm");
    assert.ok(arm, "seed " + seed + ": no kraken in 150 s");
    assert.ok(arm.t <= 150, "seed " + seed + " at " + arm.t);
    assert.ok(arm.round >= CONFIG.kraken.from_round, "the kraken's own rule: round " + arm.round);
  }
});

test("the stubborn task: the first ready one, deterministic, two rounds past the kraken, no card on the way", () => {
  for (const seed of [1, 7, 42]) {
    const s = createSim(seed);
    const t = s.tasks.find((x) => x.lane === "ready");
    assert.ok(t.rounds >= CONFIG.kraken.from_round + 2);
    assert.equal(t.flags.decision, false);
    assert.deepEqual(createSim(seed), s);
    // the other tasks keep their seeded draw
    assert.ok(s.tasks.filter((x) => x.lane !== "issues" && x !== t).some((x) => x.rounds < CONFIG.kraken.from_round + 1));
  }
});

test("the kraken holds its task long enough to be faced (a round or more) before it lets go; its card comes up", () => {
  for (const seed of [1, 7, 42]) {
    const { seen } = watch(seed, 240);
    const arm = seen.find((e) => e.type === "kraken_arm");
    assert.equal(arm.cards[0], "kraken", "seed " + seed + ": the kraken's card is on top of the deck");
    const go = seen.find((e) => e.type === "kraken_let_go" && e.task === arm.task);
    assert.ok(go, "seed " + seed + ": the task is approved in the end");
    assert.ok(go.t - arm.t >= 15, "seed " + seed + ": held " + (go.t - arm.t).toFixed(1) + " s");
  }
});
