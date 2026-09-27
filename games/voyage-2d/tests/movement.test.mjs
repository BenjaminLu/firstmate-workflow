// The walkable ship (v3src/sim/deckplan.js), without a renderer: every class has its decks,
// links and stations; every station and every deck can be reached; the rest plan keeps drawn
// boxes apart; and a long, busy crowd run at every class and across class changes never puts
// a crewman in an obstacle or on top of another, never leaves one boxed in, and is deterministic.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { SHIP_CLASSES, deckGeometry, buildNav, findPath, staticFree, Crowd, planRest, fileSegments, restFile, levelIds, connected } from "../v3src/sim/deckplan.js";

const ROOT = new URL("..", import.meta.url).pathname;
const GEO = SHIP_CLASSES.map((S) => deckGeometry(S));

test("every class has its decks: hold, gun deck(s), main deck, quarterdeck, forecastle, and the crow's nest where it has a mast for one", () => {
  for (const [i, G] of GEO.entries()) {
    const S = SHIP_CLASSES[i], ids = Object.keys(G.decks);
    for (const d of ["hold", "gun", "main", "qd", "fore"]) assert.ok(ids.includes(d), `${S.id}: ${d}`);
    assert.equal(ids.includes("nest"), S.masts.some((m) => m.nest), `${S.id}: nest where there is one`);
    if (S.id === "line") assert.ok(ids.includes("gun2"), "the ship of the line has a second gun deck");
    // the decks read top to bottom
    assert.ok(G.decks.qd.y < G.decks.main.y && G.decks.main.y < G.decks.gun.y && G.decks.gun.y < G.decks.hold.y);
    for (const d of Object.keys(G.decks)) assert.ok(connected(G, d), `${S.id}: the ${d} is one walkable piece`);
  }
});

test("walkable spans carry their obstacles, and the decks are linked by stairs, ladders and the shrouds", () => {
  for (const [i, G] of GEO.entries()) {
    const S = SHIP_CLASSES[i], kinds = new Set(G.obstacles.map((o) => o.kind));
    for (const k of ["mast", "gun", "hatch", "capstan", "wheel", "stairs", "ladder"]) assert.ok(kinds.has(k), `${S.id}: ${k}`);
    assert.ok(kinds.has("cask") || kinds.has("crate"), `${S.id}: cargo in the hold`);
    const lk = new Set(G.links.map((l) => l.kind));
    assert.ok(lk.has("stairs") && lk.has("ladder"), `${S.id}: stairs and a ladder`);
    assert.equal(lk.has("shrouds"), !!G.decks.nest, `${S.id}: shrouds up to the nest`);
    // the guns: a full row on each gun deck (the brig's short gun deck keeps five of its six)
    const rows = levelIds(S).length - 1;
    assert.ok(G.guns.length >= (S.guns - 1) * rows, `${S.id}: ${G.guns.length} guns`);
    // every link end stands clear of every obstacle
    for (const l of G.links) for (const e of [l.a, l.b]) assert.ok(staticFree(G, e.deck, e.x, e.z, 36), `${S.id}: ${l.id} end on the ${e.deck}`);
  }
});

test("every station is clear of obstacles and reachable from the helm; the captain can reach every deck", () => {
  for (const [i, G] of GEO.entries()) {
    const S = SHIP_CLASSES[i], nav = buildNav(G);
    const helm = G.stations.find((s) => s.kind === "helm");
    const kinds = new Set(G.stations.map((s) => s.kind));
    for (const k of ["helm", "mate", "review", "gun", "rig", "lookout"]) assert.ok(kinds.has(k), `${S.id}: a ${k} station`);
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

// a drawn box for the rest plan's check: a sailor's width at crew scale
const box = (S) => [-66 * S.crewScale, 94 * S.crewScale];
test("at rest: the plan keeps every drawn box apart on every deck (topside as one row), clear of obstacles and link landings", () => {
  for (const [i, G] of GEO.entries()) {
    const S = SHIP_CLASSES[i];
    for (const n of [S.cap, Math.max(7, S.cap - 4)]) {
      const items = [];
      const spots = G.stations.filter((s) => s.kind !== "helm" && s.kind !== "mate" && s.kind !== "review");
      items.push({ id: "captain", deck: "qd", x: G.stations[0].x, dir: 1, ext: [-129 * S.crewScale, 159 * S.crewScale], f: 30, rank: 0 });
      items.push({ id: "firstmate", deck: "qd", x: G.stations[1].x, dir: 1, ext: [-72, 99].map((v) => v * S.crewScale), f: 26, gapL: 60, rank: 1 });
      items.push({ id: "reviewer", deck: "fore", x: G.stations[2].x, dir: -1, ext: [-62, 68].map((v) => v * S.crewScale), f: 26 });
      for (let k = 0; k < n - 3; k++) { const s = spots[k % spots.length]; items.push({ id: "w" + k, deck: s.deck, x: s.x + (k >= spots.length ? 40 : 0), dir: 1, ext: box(S), f: 26 }); }
      const { fit, at } = planRest(G, items);
      assert.ok(fit > 0.55, `${S.id} ${n}: fit ${fit}`);
      const byFile = {};
      for (const it of items) (byFile[restFile(G, at[it.id].deck)] ||= []).push({ ...it, x: at[it.id].x, deck: at[it.id].deck, z: at[it.id].z });
      for (const [file, list] of Object.entries(byFile)) {
        list.sort((a, b) => a.x - b.x);
        for (let k = 1; k < list.length; k++) assert.ok(list[k - 1].x + list[k - 1].ext[1] * fit + 15.9 <= list[k].x + list[k].ext[0] * fit, `${S.id} ${n} ${file}: ${list[k - 1].id} and ${list[k].id} apart`);
        for (const it of list) assert.ok(staticFree(G, it.deck, it.x, it.z, 26), `${S.id} ${n}: ${it.id} clear at ${it.deck} ${it.x.toFixed(0)}`);
      }
    }
  }
});

// A busy run: every crewman walks to a seeded free spot anywhere aboard every few seconds, far
// busier than a voyage, and the ship changes class under them. Checked every 1/60 s step.
function busyRun(order, secs, seed) {
  let s = seed;
  const rnd = () => ((s = (s * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
  const spotsOf = (G) => {
    const out = G.stations.filter((q) => q.kind !== "helm").map((q) => ({ id: q.id, deck: q.deck, x: q.x, z: q.z }));
    for (const file of new Set(Object.keys(G.decks).map((d) => restFile(G, d)))) for (const [a, b, dk] of fileSegments(G, file, 30)) for (let x = a; x <= b; x += 170) out.push({ id: `${dk}@${x.toFixed(0)}`, deck: dk, x, z: G.decks[dk].rest });
    return out;
  };
  let S = SHIP_CLASSES[order[0]], G = deckGeometry(S), C = new Crowd(G), spots = spotsOf(G);
  // each class carries its own full crew: hands come aboard and go ashore as it changes
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
      G = deckGeometry(S);
      for (const a of C.agents.values()) a.r = 26 * S.crewScale;
      C.setGeometry(G);
      spots = spotsOf(G);
      crew();
      out.classes.push(S.id);
    }
    for (const a of C.order()) {
      if (!a.goal && !a.link && rnd() < 0.002) {
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
  // (a walk cut short by a class change drops its goal: the hand is sent again from where he is)
  assert.ok(r.walks > 250 && r.arrived / r.walks > 0.75, `walks ${r.walks}, arrived ${r.arrived}`);
  assert.ok(r.slips <= r.walks * 0.03, `the last resort stays rare: ${r.slips} slips in ${r.walks} walks`);
});

test("the crowd is deterministic: the same run twice ends in the same places", () => {
  const a = busyRun([3, 1], 60, 42), b = busyRun([3, 1], 60, 42);
  assert.equal(a.final, b.final);
  assert.equal(a.walks, b.walks);
});

test("the captain at the helm of his legs: he walks, takes a ladder down and back up, and nobody is shoved into anything", () => {
  const G = GEO[1], C = new Crowd(G);
  const helm = G.stations.find((s) => s.kind === "helm");
  const cap = C.add("captain", { deck: helm.deck, x: helm.x, z: helm.z, r: 30, pri: 0 });
  cap.manual = { vx: 0 };
  // walk forward to the stairs, down to the waist, on to the companionway, down to the gun deck,
  // on to the hold's ladder, down, then all the way back up
  // as a player would: walk toward the nearest way down (or up), take it when he is at it
  const go = (way, maxT = 30) => {
    const from = cap.deck;
    for (let t = 0; t < maxT; t += 1 / 60) {
      if (C.linkAt(cap, way) && cap.manual) { assert.ok(C.takeLink("captain", way)); break; }
      const ends = G.links.flatMap((l) => [[l.a, l.b], [l.b, l.a]]).filter(([e, o]) => e.deck === cap.deck && (G.decks[o.deck].y > G.decks[e.deck].y) === (way > 0));
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
  go(1); go(1); go(1); // down: the waist, the gun deck, the hold
  go(-1); go(-1); go(-1); // and back up to the quarterdeck
  assert.deepEqual(seen, ["qd", "main", "gun", "hold", "gun", "main", "qd"]);
});

test("the shared model is the same file in both games", () => {
  const a = readFileSync(`${ROOT}v3src/sim/deckplan.js`, "utf8");
  const b = readFileSync(`${ROOT}../voyage-game/src/sim/deckplan.js`, "utf8");
  assert.equal(a, b);
  assert.ok(!/document|window|canvas|ctx\./.test(a.replace(/\/\/.*$/gm, "")), "renderer-free");
});

// Up the shrouds to the crow's nest at a hand's pace at every class, whatever the mast's height:
// from the foot of the shrouds to standing in the nest in under 5 s (the 2.5D's walking speed;
// the 3D's own test runs its slower crew).
test("climbing the shrouds to the crow's nest takes under 5 s at every class", () => {
  for (const [i, G] of GEO.entries()) {
    const S = SHIP_CLASSES[i], L = G.links.find((l) => l.kind === "shrouds");
    if (!G.decks.nest) { assert.ok(!L, `${S.id}: no shrouds without a nest`); continue; }
    const C = new Crowd(G), a = C.add("w", { deck: L.a.deck, x: L.a.x, z: L.a.z, r: 26 * S.crewScale, pri: 5 });
    const look = G.stations.find((q) => q.kind === "lookout" && q.deck === "nest");
    let done = null, t = 0;
    C.goTo("w", { deck: "nest", x: look.x, z: look.z }, () => (done = t));
    for (; t < 20 && done === null; t += 1 / 60) C.step(1 / 60);
    assert.ok(done !== null && a.deck === "nest", `${S.id}: reached the nest`);
    assert.ok(done < 5, `${S.id}: ${done.toFixed(2)} s from the foot of the shrouds (${L.len.toFixed(0)} long) to the lookout's spot`);
  }
});
