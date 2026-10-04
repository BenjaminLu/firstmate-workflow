import test from "node:test";
import assert from "node:assert/strict";
import { createBattle, stepBattle, attackView, ultView, TUNE } from "../src/battle2d.js";

const run = (b, a) => stepBattle(b, a);
function until(b, pred, max = 30) {
  const evs = [];
  for (let i = 0; i < max * 100; i++) {
    const r = run(b, { type: "tick", dt: 0.01 });
    b = r.battle;
    evs.push(...r.events);
    if (pred(b, r.events)) return { b, evs };
  }
  throw new Error("timed out");
}
const startOf = (pattern) => (b, e) => e.some((x) => x.type === "attack_start" && (!pattern || x.pattern === pattern));

test("the reducer never mutates its input and is deterministic for a seed", () => {
  const a = createBattle({ seed: 3 });
  const snap = JSON.stringify(a);
  const r1 = until(a, startOf());
  assert.equal(JSON.stringify(a), snap);
  const r2 = until(createBattle({ seed: 3 }), startOf());
  assert.deepEqual(r1.b.attack, r2.b.attack);
});

test("an attack unanswered strikes the hull at the end of its wind-up", () => {
  let { b } = until(createBattle({ seed: 1 }), startOf());
  const P = TUNE.patterns[b.attack.pattern];
  const hull = b.hull;
  const r = until(b, (x, e) => e.some((y) => y.type === "strike"), P.wind + 0.2);
  assert.equal(r.b.hull, hull - P.dmg);
});

test("a parry in the last sliver of a slam is perfect and opens a riposte that crits", () => {
  let { b } = until(createBattle({ seed: 1 }), startOf("slam"));
  const P = TUNE.patterns.slam;
  b = until(b, (x) => P.wind - (x.t - x.attack.start) <= P.parry * 0.5, 3).b;
  let r = run(b, { type: "parry" });
  assert.ok(r.events.some((e) => e.type === "parry_ok"));
  r = until(r.battle, (x, e) => e.some((y) => y.type === "parried"), 1);
  b = r.b;
  assert.ok(b.riposteUntil > b.t && b.weak);
  const grip = b.grip;
  const r2 = run(b, { type: "parry" });
  const h = r2.events.find((e) => e.type === "hit");
  assert.ok(h && h.crit && h.source === "riposte");
  assert.ok(r2.battle.grip < grip - TUNE.riposte.crit + 1);
});

test("a parry too early is a miss and the strike lands", () => {
  let { b } = until(createBattle({ seed: 1 }), startOf("slam"));
  const r = run(b, { type: "parry" });
  assert.ok(r.events.some((e) => e.type === "parry_miss"));
  const r2 = until(r.battle, (x, e) => e.some((y) => y.type === "strike"), 2);
  assert.ok(r2.b.hull < TUNE.hull);
});

test("a sweep cannot be parried but can be dodged late", () => {
  let { b } = until(createBattle({ seed: 1, round: 3 }), startOf("sweep"), 60);
  const P = TUNE.patterns.sweep;
  const early = run(b, { type: "parry" });
  assert.ok(early.events.some((e) => e.type === "parry_miss"));
  b = until(b, (x) => P.wind - (x.t - x.attack.start) <= P.dodge * 0.5, 3).b;
  const hull = b.hull;
  const d = run(b, { type: "dodge" });
  assert.ok(d.events.some((e) => e.type === "dodge_ok"));
  const r = until(d.battle, (x, e) => e.some((y) => y.type === "dodged"), 1);
  assert.equal(r.b.hull, hull);
});

test("the ultimate triggers at 60 % grip, and a braced perfect parry counters it", () => {
  let b = createBattle({ seed: 2 });
  b.grip = 62;
  b.gauge = 100;
  b = run(b, { type: "harpoon" }).battle; // 12 damage: 62 -> 50, past the 60 % mark
  assert.ok(b.pendingUlt);
  let r = until(b, (x, e) => e.some((y) => y.type === "ult_start"), 10);
  b = r.b;
  assert.equal(b.phase, "ultimate");
  r = until(b, (x, e) => e.some((y) => y.type === "ult_brace"), 5);
  b = run(r.b, { type: "brace", on: true }).battle;
  r = until(b, (x, e) => e.some((y) => y.type === "ult_strike"), 5);
  assert.ok(r.evs.find((e) => e.type === "ult_strike").braced);
  b = run(r.b, { type: "brace", on: false }).battle;
  b = until(b, (x) => ultView(x) && ultView(x).stage === "strike" && ultView(x).p >= 1 - ultView(x).parryZone * 0.5, 3).b;
  const p = run(b, { type: "parry" });
  assert.ok(p.events.some((e) => e.type === "ult_parry"));
  const grip = p.battle.grip;
  r = until(p.battle, (x, e) => e.some((y) => y.type === "ult_countered"), 2);
  assert.equal(r.b.hull, TUNE.hull);
  assert.ok(r.b.grip <= grip - TUNE.ultimate.counter);
});

test("an unbraced, unparried ultimate lands in full; a braced one at half", () => {
  const land = (brace) => {
    let b = createBattle({ seed: 2 });
    b.pendingUlt = true;
    let r = until(b, (x, e) => e.some((y) => y.type === "ult_brace"), 10);
    b = brace ? run(r.b, { type: "brace", on: true }).battle : r.b;
    r = until(b, (x, e) => e.some((y) => y.type === "ult_landed"), 5);
    return TUNE.hull - r.b.hull;
  };
  assert.equal(land(false), TUNE.ultimate.dmg);
  assert.equal(land(true), Math.round(TUNE.ultimate.dmg * TUNE.ultimate.braceSave));
});

test("a broadside released in the gold zone is perfect", () => {
  let b = createBattle({ seed: 4 });
  b.gauge = 100;
  b = run(b, { type: "broadsideStart" }).battle;
  const S = TUNE.specials.broadside;
  b = until(b, (x) => x.t - x.charge >= S.charge * ((S.zone[0] + S.zone[1]) / 2), 3).b;
  const r = run(b, { type: "broadsideFire" });
  assert.equal(r.events.find((e) => e.type === "broadside").grade, "perfect");
  assert.equal(r.events.filter((e) => e.type === "hit").length, S.shots + 1);
});

test("zero grip waits for the finisher, and only the finisher wins", () => {
  let b = createBattle({ seed: 5 });
  b.grip = 5;
  b.gauge = 100;
  let r = run(b, { type: "harpoon" });
  assert.ok(r.events.some((e) => e.type === "finisher_ready"));
  b = r.battle;
  assert.equal(b.phase, "finisher");
  b = until(b, (x) => x.t > b.t + 5, 6).b;
  assert.equal(b.hull, TUNE.hull); // no attacks while the finisher waits
  r = run(b, { type: "finish" });
  assert.ok(r.events.some((e) => e.type === "won"));
});

test("specials need the gauge", () => {
  const b = createBattle({ seed: 6 });
  for (const t of ["harpoon", "order", "broadsideStart"]) assert.ok(run(b, { type: t }).events.some((e) => e.type === "no_gauge"));
});

test("views report the wind-up and the ultimate's stages", () => {
  let { b } = until(createBattle({ seed: 1 }), startOf());
  const v = attackView(b);
  assert.ok(v.p >= 0 && v.p <= 1 && v.parryZone > 0 && v.parryZone < 1);
  b.pendingUlt = true;
  b.attack = null;
  b = until(b, (x, e) => e.some((y) => y.type === "ult_start"), 3).b;
  assert.equal(ultView(b).stage, "windup");
});

// ---------------------------------------------------------------- the click-first game: one tap
import { nextSpecial } from "../src/battle2d.js";
const tap = (b) => run(b, { type: "tap" });

test("tap: too soon waits without penalty, in the window it parries a slam", () => {
  let { b } = until(createBattle({ seed: 1 }), startOf("slam"));
  let r = tap(b);
  assert.ok(r.events.some((e) => e.type === "wait"));
  assert.equal(r.battle.attack.answer, null);
  const P = TUNE.patterns.slam;
  b = until(r.battle, (x) => P.wind - (x.t - x.attack.start) <= P.tap * 0.9, 3).b;
  r = tap(b);
  assert.ok(r.events.some((e) => e.type === "parry_ok"));
  r = until(r.battle, (x, e) => e.some((y) => y.type === "parried"), 1);
  assert.equal(r.b.hull, TUNE.hull);
  const r2 = tap(r.b); // the riposte
  assert.ok(r2.events.some((e) => e.type === "hit" && e.source === "riposte" && e.crit));
});

test("tap: an unblockable sweep is dodged, ink is shot down", () => {
  for (const pat of ["sweep", "ink"]) {
    let { b } = until(createBattle({ seed: 1, round: 3 }), startOf(pat), 60);
    const P = TUNE.patterns[pat];
    b = until(b, (x) => P.wind - (x.t - x.attack.start) <= P.tap * 0.5, 3).b;
    const hull = b.hull;
    const r = tap(b);
    assert.ok(r.events.some((e) => e.type === (pat === "ink" ? "ink_shot_ok" : "dodge_ok")), pat);
    const r2 = until(r.battle, (x) => !x.attack, 2);
    assert.equal(r2.b.hull, hull, pat);
  }
});

test("tap: with nothing to answer it fires at will, on a cooldown", () => {
  const b = createBattle({ seed: 1 });
  const r = tap(b);
  assert.ok(r.events.some((e) => e.type === "hit" && e.source === "shot"));
  assert.ok(!tap(r.battle).events.some((e) => e.type === "hit"));
});

test("tap: braces through the swell and parries the crushing tide", () => {
  let b = createBattle({ seed: 2 });
  b.pendingUlt = true;
  let r = until(b, (x, e) => e.some((y) => y.type === "ult_brace"), 10);
  b = tap(r.b).battle;
  b = until(b, (x) => ultView(x) && ultView(x).stage === "strike" && ultView(x).p >= 1 - ultView(x).parryZone * 0.8, 4).b;
  const p = tap(b);
  assert.ok(p.events.some((e) => e.type === "ult_parry"));
  r = until(p.battle, (x, e) => e.some((y) => y.type === "ult_countered"), 2);
  assert.equal(r.b.hull, TUNE.hull);
});

test("tap in the finisher starts it once; the special button rotates at a full gauge", () => {
  let b = createBattle({ seed: 5, arms: 2 });
  b.grip = 0;
  b.phase = "finisher";
  const f = tap(b);
  assert.ok(f.events.some((e) => e.type === "finisher_go"));
  assert.ok(!tap(f.battle).events.some((e) => e.type === "finisher_go"));
  b = createBattle({ seed: 6, arms: 2 });
  assert.ok(run(b, { type: "special" }).events.some((e) => e.type === "no_gauge"));
  const seen = [];
  for (let i = 0; i < 3; i++) {
    b.gauge = 100;
    b.attack = null;
    seen.push(nextSpecial(b));
    const r = run(b, { type: "special" });
    b = r.battle;
    assert.ok(r.events.some((e) => ["broadside", "harpoon", "all_hands"].includes(e.type)));
    b.bound = [];
  }
  assert.deepEqual(seen, ["broadside", "harpoon", "order"]);
  const r = run({ ...b, gauge: 100, specialIdx: 0 }, { type: "special" });
  assert.equal(r.events.find((e) => e.type === "broadside").grade, "perfect");
});
