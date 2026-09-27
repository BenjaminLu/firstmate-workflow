// live-adapter.js: viewToSim, the translation from a BoardSource view into
// the sim shape World, HUD, Director and BattleView already read.
import test from "node:test";
import assert from "node:assert/strict";
import { viewToSim, liveEmptySim } from "../src/live-adapter.js";
import { mapView } from "../src/boardsource.js";

test("liveEmptySim is a valid, empty starting point", () => {
  const s = liveEmptySim({ order: true });
  assert.deepEqual(s.tasks, []);
  assert.deepEqual(s.crew, []);
  assert.deepEqual(s.kraken, { arms: [], battle: null, fled: false });
  assert.deepEqual(s.rituals, { order: true });
});

test("viewToSim keeps lane data straight, folding gate into working with a red flag", () => {
  const view = mapView({
    tasks: [
      { id: "T-1", title: "a", milestone: "M1", stage: "working" },
      { id: "T-2", title: "b", milestone: "M1", stage: "gate" },
      { id: "T-3", title: "c", milestone: "M1", stage: "merged" },
    ],
    crew: [{ id: "worker-1", role: "worker", state: "working", task: "T-1" }],
  });
  const sim = viewToSim(view, null);
  assert.equal(sim.tasks.find((t) => t.id === "T-1").lane, "working");
  assert.equal(sim.tasks.find((t) => t.id === "T-2").lane, "working");
  assert.equal(sim.gate["T-2"], "red");
  assert.equal(sim.tasks.find((t) => t.id === "T-3").lane, "merged");
  assert.equal(sim.crew.length, 1);
  assert.equal(sim.crew[0].id, "worker-1");
});

test("closed tasks are dropped, like merged history", () => {
  const view = mapView({ tasks: [{ id: "T-9", stage: "closed" }] });
  assert.deepEqual(viewToSim(view, null).tasks, []);
});

test("port advances only once every task of a milestone, in order, has merged", () => {
  const view = mapView({
    tasks: [
      { id: "T-1", milestone: "M1", stage: "merged" },
      { id: "T-2", milestone: "M1", stage: "merged" },
      { id: "T-3", milestone: "M2", stage: "working" },
    ],
  });
  const sim = viewToSim(view, null);
  assert.equal(sim.port, 1);
});

test("a pending card own options travel through untouched; the game never interprets chosen", () => {
  const view = mapView({
    tasks: [],
    pending: [{ id: "D-1", task: "T-1", kind: "choice", details: { en: { title: "pick", explanation: "why",
      options: { A: { description: "do it" }, B: { description: "wait" } } } } }],
  });
  const sim = viewToSim(view, null);
  assert.equal(sim.decisions.length, 1);
  assert.equal(sim.decisions[0].title, "pick");
  assert.deepEqual(sim.decisions[0].options.map((o) => o.key), ["A", "B"]);
});

test("ritual toggles and past battle wins survive one snapshot to the next", () => {
  const prev = { rituals: { order: false }, stats: { battlesWon: 3 }, seq: 5 };
  const sim = viewToSim(mapView({ tasks: [] }), prev);
  assert.deepEqual(sim.rituals, { order: false });
  assert.equal(sim.stats.battlesWon, 3);
  assert.equal(sim.seq, 6);
});
