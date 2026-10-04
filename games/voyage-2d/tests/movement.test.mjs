// The walkable ship (src/deckplan.js, the 2.5D's own model; the frozen 3D keeps v3src/sim/
// deckplan.js), without a renderer: every class has its decks, rooms, links and stations; every
// station and every room can be reached; the rest plan keeps drawn boxes apart; a long, busy
// crowd run at every class and across class changes never puts a crewman in an obstacle or on top
// of another, never leaves one boxed in, and is deterministic; and the captain always gets past
// the crew (the captain's "橫移碰到船員永遠過不去").
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { deckGeometry, buildNav, findPath, staticFree, Crowd, planRest, fileSegments, restFile, connected, checkLayout, specOf } from "../src/deckplan.js";
import { CLASSES as SHIP_CLASSES, LAYOUTS } from "../src/layouts.js";

const ROOT = new URL("..", import.meta.url).pathname;
const GEO = SHIP_CLASSES.map((S) => deckGeometry(S));
const lower = (G) => Object.values(G.decks).filter((d) => d.y > 0).sort((a, b) => a.y - b.y).map((d) => d.id);

test("the ship is big and the crew small: 3-4x the old ship's length and ~3x its height, in crewmen", () => {
  // the old model (v3src/sim/deckplan.js, still the 3D's): stern-to-bow and rail-to-keel, over a
  // crewman's height (200 x crewScale)
  const OLD = { sloop: [7.3, 4.45], brig: [9.7, 4.7], frigate: [12.4, 5.1], line: [17.7, 6.7] };
  for (const S of SHIP_CLASSES) {
    const h = 200 * S.crewScale, top = Math.min(...S.hull.map((p) => p[1])), len = S.len / h, tall = (S.bottom - top) / h;
    const [ol, ot] = OLD[S.id];
    assert.ok(len / ol >= 3 && len / ol <= 4.5, `${S.id}: ${len.toFixed(1)} crewmen long (was ${ol}): ${(len / ol).toFixed(2)}x`);
    assert.ok(tall / ot >= 2.5, `${S.id}: ${tall.toFixed(1)} crewmen tall (was ${ot}): ${(tall / ot).toFixed(2)}x`);
    // a believable hull: about three times as long as she is deep
    assert.ok(S.len / (S.bottom - top) > 2.4 && S.len / (S.bottom - top) < 3.6, `${S.id}: length to depth ${(S.len / (S.bottom - top)).toFixed(2)}`);
  }
});

test("every class has its rooms: the helm, the captain's cabin, the chart room, the waist, the forecastle, gun decks, quarters, the galley, the hold, and crow's nests", () => {
  for (const [i, G] of GEO.entries()) {
    const S = SHIP_CLASSES[i], kinds = new Set(G.rooms.map((r) => r.kind));
    for (const k of ["helm", "cabin", "chart", "waist", "forecastle", "gundeck", "quarters", "galley", "cargo", "nest"]) assert.ok(kinds.has(k), `${S.id}: a ${k}`);
    assert.deepEqual(lower(G).slice(-2), ["berth", "hold"], `${S.id}: the berth deck and the hold at the bottom`);
    if (S.id === "line") assert.ok(G.decks.gun2, "the ship of the line has a second gun deck");
    assert.ok(G.decks.qd.y < G.decks.main.y && G.decks.main.y < G.decks.gun.y && G.decks.gun.y < G.decks.hold.y);
    assert.ok(G.walls.length >= 3 && G.walls.some((w) => w.door), `${S.id}: ${G.walls.length} bulkheads`);
  }
});

test("every default layout passes the gate a mod must pass: every room and station reachable from the helm", () => {
  for (const S of SHIP_CLASSES) assert.deepEqual(checkLayout(S), [], S.id);
  // and the layouts are plain data: they survive JSON and rebuild the same ship
  for (const L of LAYOUTS) {
    const a = deckGeometry(specOf(JSON.parse(JSON.stringify(L)))), b = deckGeometry(specOf(L));
    assert.equal(JSON.stringify(a.stations), JSON.stringify(b.stations), L.id);
  }
});

test("walkable spans carry their obstacles, and the decks are linked by stairs, ladders and the shrouds", () => {
  for (const [i, G] of GEO.entries()) {
    const S = SHIP_CLASSES[i], kinds = new Set(G.obstacles.map((o) => o.kind));
    for (const k of ["mast", "gun", "hatch", "capstan", "wheel", "stairs", "ladder", "wall", "workbench", "desk", "table", "stove"]) assert.ok(kinds.has(k), `${S.id}: ${k}`);
    assert.ok(kinds.has("cask") || kinds.has("crate"), `${S.id}: cargo in the hold`);
    const lk = new Set(G.links.map((l) => l.kind));
    assert.ok(lk.has("stairs") && lk.has("ladder") && lk.has("shrouds"), `${S.id}: stairs, ladders and shrouds`);
    for (const d of S.gunDecks) assert.ok(G.guns.filter((g) => g.deck === d).length >= 8, `${S.id}: guns on the ${d}`);
    for (const l of G.links) for (const e of [l.a, l.b]) assert.ok(staticFree(G, e.deck, e.x, e.z, 36), `${S.id}: ${l.id} end on the ${e.deck}`);
    for (const d of Object.keys(G.decks)) if (!G.walls.some((w) => w.deck === d && !w.door)) assert.ok(connected(G, d), `${S.id}: the ${d} is one walkable piece`);
  }
});

test("every station is clear of obstacles and reachable from the helm; the captain can reach every deck", () => {
  for (const [i, G] of GEO.entries()) {
    const S = SHIP_CLASSES[i], nav = buildNav(G);
    const helm = G.stations.find((s) => s.kind === "helm");
    const kinds = new Set(G.stations.map((s) => s.kind));
    for (const k of ["helm", "cabin", "chart", "work", "rig", "lookout", "review", "gate", "rest", "visit"]) assert.ok(kinds.has(k), `${S.id}: a ${k} station`);
    for (const s of G.stations) {
      assert.ok(staticFree(G, s.deck, s.x, s.z, 30), `${S.id}: ${s.id} clear`);
      assert.ok(findPath(nav, helm, s), `${S.id}: ${s.id} reachable`);
    }
    for (const d of Object.values(G.decks)) {
      const [a, b] = fileSegments(G, restFile(G, d.id), 30).find((q) => q[2] === d.id) || [];
      assert.ok(a !== undefined, `${S.id}: somewhere to stand on the ${d.id}`);
      const route = findPath(nav, helm, { deck: d.id, x: (a + b) / 2, z: d.rest }, 30);
      assert.ok(route, `${S.id}: the captain reaches the ${d.id}`);
      if (d.id !== "qd") assert.ok(route.some((st) => st.link), `${S.id}: by a stair or ladder to the ${d.id}`);
    }
  }
});

test("stations for a full crew in any state: rest, work and gate stations for the whole crew, review and visit stations for several", () => {
  for (const [i, G] of GEO.entries()) {
    const S = SHIP_CLASSES[i], n = (k) => G.stations.filter((s) => s.kind === k).length;
    assert.ok(n("rest") + n("cargo") >= S.cap, `${S.id}: ${n("rest")} rest + ${n("cargo")} cargo`);
    assert.ok(n("work") + n("rig") >= Math.min(S.cap, 8), `${S.id}: ${n("work")} work`);
    assert.ok(n("gate") >= Math.min(S.cap, 8), `${S.id}: ${n("gate")} gate`);
    assert.ok(n("review") + n("lookout") >= 3 && n("visit") >= 1, `${S.id}: review ${n("review")}, lookout ${n("lookout")}, visit ${n("visit")}`);
  }
});

const box = (S) => [-66 * S.crewScale, 94 * S.crewScale];
test("at rest: the plan keeps every drawn box apart on every deck, clear of obstacles and link landings, at full size", () => {
  for (const [i, G] of GEO.entries()) {
    const S = SHIP_CLASSES[i];
    for (const kind of ["rest", "work", "gate"]) {
      const items = [];
      const helm = G.stations.find((s) => s.kind === "helm"), mate = G.stations.find((s) => s.kind === "chart");
      items.push({ id: "captain", deck: helm.deck, x: helm.x, dir: 1, ext: [-129 * S.crewScale, 159 * S.crewScale], f: 30, rank: 0, pin: 30, weight: 40 });
      items.push({ id: "firstmate", deck: mate.deck, x: mate.x, dir: 1, ext: [-72, 99].map((v) => v * S.crewScale), f: 26, gapL: 60, rank: 1 });
      const spots = G.stations.filter((s) => s.kind === kind || s.kind === "rest");
      for (let k = 0; k < S.cap - 2; k++) { const s = spots[k % spots.length]; items.push({ id: "w" + k, deck: s.deck, x: s.x + (k >= spots.length ? 40 : 0), dir: 1, ext: box(S), f: 26 }); }
      const { fit, at } = planRest(G, items);
      assert.equal(fit, 1, `${S.id} ${kind}: nobody is drawn smaller (fit ${fit})`);
      const byFile = {};
      for (const it of items) (byFile[restFile(G, at[it.id].deck)] ||= []).push({ ...it, x: at[it.id].x, deck: at[it.id].deck, z: at[it.id].z });
      for (const [file, list] of Object.entries(byFile)) {
        list.sort((a, b) => a.x - b.x);
        for (let k = 1; k < list.length; k++) assert.ok(list[k - 1].x + list[k - 1].ext[1] + 15.9 <= list[k].x + list[k].ext[0], `${S.id} ${kind} ${file}: ${list[k - 1].id} and ${list[k].id} apart`);
        for (const it of list) assert.ok(staticFree(G, it.deck, it.x, it.z, 26), `${S.id}: ${it.id} clear at ${it.deck} ${it.x.toFixed(0)}`);
      }
    }
  }
});

// A busy run: every crewman walks to a seeded station anywhere aboard every few seconds, far
// busier than a voyage, and the ship changes class under them. Checked every 1/60 s step.
function busyRun(order, secs, seed) {
  let s = seed;
  const rnd = () => ((s = (s * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
  const spotsOf = (G) => G.stations.filter((q) => q.kind !== "helm").map((q) => ({ id: q.id, deck: q.deck, x: q.x, z: q.z }));
  let S = SHIP_CLASSES[order[0]], G = GEO[order[0]], C = new Crowd(G), spots = spotsOf(G);
  const crew = () => {
    const n = S.cap;
    for (const a of C.order()) if (+a.id.slice(1) >= n) C.remove(a.id);
    for (let i = 0; i < n; i++) if (!C.get("c" + String(i).padStart(2, "0"))) { const q = spots[(i * 5) % spots.length]; C.add("c" + String(i).padStart(2, "0"), { deck: q.deck, x: q.x, z: q.z, r: 26 * S.crewScale, pri: i }); }
  };
  crew();
  const out = { bad: [], walks: 0, arrived: 0, stalls: [], classes: [S.id] };
  const still = new Map();
  const per = secs / order.length;
  for (let t = 0, h = 1 / 60, phase = 0; t < secs; t += h) {
    if (t >= (phase + 1) * per) {
      phase++;
      S = SHIP_CLASSES[order[phase]];
      G = GEO[order[phase]];
      for (const a of C.agents.values()) a.r = 26 * S.crewScale;
      C.setGeometry(G);
      spots = spotsOf(G);
      crew();
      out.classes.push(S.id);
    }
    for (const a of C.order()) {
      if (!a.goal && !a.link && rnd() < 0.004) {
        const used = C.order().map((b) => b.goal || (!b.link && { deck: b.deck, x: b.x })).filter(Boolean);
        const free = spots.filter((q) => !used.some((u) => u.deck === q.deck && Math.abs(u.x - q.x) < 70));
        if (free.length) { const q = free[Math.floor(rnd() * free.length)]; C.goTo(a.id, { deck: q.deck, x: q.x, z: q.z }, () => out.arrived++); out.walks++; }
      }
      if (a.moving || !a.goal) still.set(a.id, t);
      else if (t - (still.get(a.id) ?? t) > 30) { out.stalls.push(`${S.id} ${a.id} at ${t.toFixed(1)}`); still.set(a.id, t); }
    }
    C.tick(h);
    const v = C.violations();
    if (v.length && out.bad.length < 5) out.bad.push(`${S.id} ${t.toFixed(2)}s: ${v[0]}`);
  }
  out.slips = C.slips || 0;
  out.final = C.order().map((a) => `${a.id}:${a.deck}:${a.x.toFixed(3)}:${a.z.toFixed(3)}`).join("|");
  return out;
}

test("a long busy run at every class and across class changes: never inside an obstacle, never on top of another, never boxed in for long", () => {
  const r = busyRun([0, 1, 2, 3, 2, 0, 3, 1], 480, 7);
  assert.deepEqual(r.classes, ["sloop", "brig", "frigate", "line", "frigate", "sloop", "line", "brig"]);
  assert.deepEqual(r.bad, [], "no broken rule at any 1/60 s step");
  assert.deepEqual(r.stalls, [], "no one stands boxed in for 30 s");
  // (the ships are long: a walk is often cut short by the next class change, and sent again)
  assert.ok(r.walks > 250 && r.arrived / r.walks > 0.6, `walks ${r.walks}, arrived ${r.arrived}`);
  assert.ok(r.slips <= r.walks * 0.03, `the last resort stays rare: ${r.slips} slips in ${r.walks} walks`);
});

test("the crowd is deterministic: the same run twice ends in the same places", () => {
  const a = busyRun([3, 1], 60, 42), b = busyRun([3, 1], 60, 42);
  assert.equal(a.final, b.final);
  assert.equal(a.walks, b.walks);
});

test("the captain at the helm of his legs: he walks, takes every way down to the hold and back up, and nobody is shoved into anything", () => {
  const G = GEO[1], C = new Crowd(G);
  const helm = G.stations.find((s) => s.kind === "helm");
  const cap = C.add("captain", { deck: helm.deck, x: helm.x, z: helm.z, r: 30, pri: 0 });
  cap.ghost = true;
  cap.manual = { vx: 0 };
  const go = (way, maxT = 60) => {
    const from = cap.deck;
    for (let t = 0; t < maxT; t += 1 / 60) {
      if (C.linkAt(cap, way) && cap.manual && G.decks[C.linkAt(cap, way).to.deck].kind !== "nest") { assert.ok(C.takeLink("captain", way)); break; }
      const ends = G.links.flatMap((l) => [[l.a, l.b], [l.b, l.a]]).filter(([e, o]) => e.deck === cap.deck && (G.decks[o.deck].y > G.decks[e.deck].y) === (way > 0) && G.decks[o.deck].kind !== "nest");
      const e = ends.map(([e]) => e).sort((p, q) => Math.abs(p.x - cap.x) - Math.abs(q.x - cap.x))[0];
      cap.manual.vx = Math.sign(e.x - cap.x);
      C.tick(1 / 60);
    }
    for (let t = 0; t < 20 && !cap.manual; t += 1 / 60) C.tick(1 / 60);
    assert.notEqual(cap.deck, from, `he left the ${from}`);
    seen.push(cap.deck);
    assert.deepEqual(C.violations(), []);
  };
  const seen = ["qd"];
  for (let i = 0; i < 4; i++) go(1); // down: the waist, the gun deck, the berth deck, the hold
  for (let i = 0; i < 4; i++) go(-1); // and back up to the quarterdeck
  assert.deepEqual(seen, ["qd", "main", "gun", "berth", "hold", "berth", "gun", "main", "qd"]);
});

// The captain's note: walking sideways into a crewman, the captain could never get past. The
// crew are not obstacles to him (nor he to them); he steers into the lane they leave (behind or
// in front of them) and, where they fill every lane, passes them in depth. Walls, guns and the
// hull still stop him, and doors and links still route him.
test("the captain walks the whole length of every deck through a line of crew and arrives, at every class", () => {
  for (const [i, G] of GEO.entries()) {
    const S = SHIP_CLASSES[i];
    for (const deck of ["main", "gun", "berth"]) {
      const C = new Crowd(G), d = G.decks[deck];
      const cap = C.add("captain", { deck, x: d.x0 + 60, z: 200, r: 30 * S.crewScale, pri: 0 });
      cap.ghost = true;
      cap.manual = { vx: 1 };
      // a crewman every 160 along the deck, in every lane (near, middle, far), all at rest
      let n = 0;
      for (let x = d.x0 + 300; x < d.x1 - 200; x += 160) for (const z of [70, 150, 230, 310]) {
        const a = C.add("w" + n, { deck, x, z, r: 26 * S.crewScale, pri: n + 1 });
        if (Math.abs(a.x - x) > 1 || Math.abs(a.z - z) > 1 || a.deck !== deck) C.remove(a.id);
        else n++;
      }
      assert.ok(n > 30, `${S.id} ${deck}: a crowd of ${n}`);
      const speed = cap.speed;
      let t = 0;
      for (; t < 120 && cap.x < d.x1 - 80; t += 1 / 60) {
        C.tick(1 / 60);
        assert.ok(staticFree(G, deck, cap.x, cap.z, cap.r), `${S.id} ${deck}: the captain is never inside the ship at ${cap.x.toFixed(0)}`);
      }
      assert.ok(cap.x >= d.x1 - 80, `${S.id} ${deck}: he arrives at the far end (x ${cap.x.toFixed(0)} of ${d.x1.toFixed(0)}, through ${n} crew)`);
      // at his own pace: walls with doorways and the guns may slow him, the crew never do
      const straight = (d.x1 - 80 - (d.x0 + 60)) / speed;
      assert.ok(t < straight * 1.25, `${S.id} ${deck}: ${t.toFixed(1)} s for a ${straight.toFixed(1)} s walk`);
      assert.deepEqual(C.violations(), [], `${S.id} ${deck}: the crew never overlap each other`);
    }
  }
});

test("a bulkhead without a door still stops him: the crew are no wall, the ship's walls are", () => {
  const L = JSON.parse(JSON.stringify(LAYOUTS[0]));
  const qu = L.rooms.find((r) => r.id === "quarters"), mess = L.rooms.find((r) => r.id === "mess");
  qu.fore = "wall";
  mess.aft = "wall";
  const S = specOf(L), G = deckGeometry(S), C = new Crowd(G), wx = qu.x1;
  const cap = C.add("captain", { deck: "berth", x: wx - 400, z: 200, r: 30, pri: 0 });
  cap.ghost = true;
  cap.manual = { vx: 1 };
  for (let t = 0; t < 8; t += 1 / 60) C.tick(1 / 60);
  assert.ok(cap.x < wx - 12, `the solid bulkhead at ${wx} holds him at ${cap.x.toFixed(0)}`);
  assert.ok(G.decks.berth.x1 > wx);
});

test("the 2.5D runs its own fork of the model; the frozen 3D game's shared file is untouched", () => {
  const a = readFileSync(`${ROOT}v3src/sim/deckplan.js`, "utf8");
  const b = readFileSync(`${ROOT}../voyage-game/src/sim/deckplan.js`, "utf8");
  assert.equal(a, b, "the 3D's model and its copy here are the same file");
  const mine = readFileSync(`${ROOT}src/deckplan.js`, "utf8");
  assert.ok(!/document|window|canvas|ctx\./.test(mine.replace(/\/\/.*$/gm, "")), "renderer-free");
  for (const f of ["world.js", "ship.js", "control.js", "layouts.js"]) assert.ok(!readFileSync(`${ROOT}src/${f}`, "utf8").includes("v3src/sim/deckplan"), `${f} uses the 2.5D's own model`);
});

test("climbing the shrouds to a crow's nest takes under 5 s at every class", () => {
  for (const [i, G] of GEO.entries()) {
    const S = SHIP_CLASSES[i];
    for (const L of G.links.filter((l) => l.kind === "shrouds")) {
      const C = new Crowd(G);
      C.add("w", { deck: L.a.deck, x: L.a.x, z: L.a.z, r: 26 * S.crewScale, pri: 5 });
      const look = G.stations.find((q) => q.kind === "review" && q.deck === L.b.deck);
      let done = null, t = 0;
      C.goTo("w", { deck: look.deck, x: look.x, z: look.z }, () => (done = t));
      for (; t < 20 && done === null; t += 1 / 60) C.step(1 / 60);
      assert.ok(done !== null && done < 5, `${S.id} ${L.id}: ${done?.toFixed(2)} s from the foot of the shrouds to the nest`);
    }
  }
});

// The captain's "船長不能跑了" and "整體移動要快速一點, 現在太拖" (v2d-11). The run itself still
// worked there (1.8x), but the pace had stayed the small ship's (300 a second) while the ship grew
// 3-4x: a run across the ship of the line took 19 s and did not read as one. A fixed distance
// through a crowd, walked and run, on every class; and the frigate from the captain's cabin to the
// bow: under 10 s walking, about half that running (the keys, as a player would: → with the run
// held, ↑ at the forecastle's stairs). On v2d-11: a run of 540 a second, and 28 s cabin to bow.
test("the pace: a run is much faster than a walk over a fixed distance through the crew, and the frigate's cabin to its bow takes under 10 s walking, about half running", () => {
  const D = 2400;
  for (const [i, G] of GEO.entries()) {
    const S = SHIP_CLASSES[i];
    const time = (run) => {
      const C = new Crowd(G), x0 = S.main[0] + 60;
      const cap = C.add("captain", { deck: "main", x: x0, z: 100, r: 30 * S.crewScale, pri: 0 });
      cap.ghost = true;
      cap.manual = { vx: 1, run };
      let n = 0;
      for (let x = x0 + 250; x < x0 + D; x += 180) for (const z of [70, 330]) { const a = C.add("w" + n, { deck: "main", x, z, r: 26 * S.crewScale, pri: n + 1 }); if (a.deck !== "main" || Math.abs(a.x - x) > 1) C.remove(a.id); else n++; }
      let t = 0;
      for (; t < 30 && cap.x < x0 + D; t += 1 / 60) C.tick(1 / 60);
      return t;
    };
    const walk = time(0), run = time(1);
    assert.ok(walk < D / 900, `${S.id}: ${D} walked in ${walk.toFixed(2)} s (${(D / walk).toFixed(0)} a second)`);
    assert.ok(run < D / 1600, `${S.id}: ${D} run in ${run.toFixed(2)} s (${(D / run).toFixed(0)} a second)`);
    assert.ok(walk / run > 1.6, `${S.id}: the run ${(walk / run).toFixed(2)}x the walk`);
  }
  const fi = SHIP_CLASSES.findIndex((S) => S.id === "frigate"), G = GEO[fi], S = SHIP_CLASSES[fi];
  const cabin = G.stations.find((s) => s.kind === "cabin"), bow = G.stations.filter((s) => s.kind === "lookout" && s.deck === "fore").sort((a, b) => b.x - a.x)[0];
  const byKeys = (run) => {
    const C = new Crowd(G), cap = C.add("captain", { deck: cabin.deck, x: cabin.x, z: cabin.z, r: 30 * S.crewScale, pri: 0 });
    cap.ghost = true;
    cap.manual = { vx: 1, run };
    let t = 0;
    for (; t < 60 && !(cap.deck === "fore" && cap.x >= bow.x); t += 1 / 60) {
      if (cap.manual && cap.deck === "main" && C.linkAt(cap, -1)?.to.deck === "fore") C.takeLink("captain", -1);
      if (cap.manual) Object.assign(cap.manual, { vx: 1, run });
      C.tick(1 / 60);
    }
    return t;
  };
  const walk = byKeys(0), run = byKeys(1);
  assert.ok(walk < 10, `frigate, cabin to bow: ${walk.toFixed(1)} s walking`);
  assert.ok(run < walk * 0.65, `frigate, cabin to bow: ${run.toFixed(1)} s running (${walk.toFixed(1)} walking)`);
});
