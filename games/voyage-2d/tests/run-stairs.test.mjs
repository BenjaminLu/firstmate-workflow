// The captain's run and the wider stairs, in the 2.5D's model (src/deckplan.js), without a
// renderer: every flight and its hatch is STAIR_W across (1.6x the first 100) at every class with
// the decks still whole, the guns all placed and every landing clear; the run is RUN x the walk on
// the deck and nothing faster on a stair, ladder or the shrouds; and a long run at run speed at
// every class, among a busy crowd, never puts anyone in an obstacle or on another, nor two on a link.
import test from "node:test";
import assert from "node:assert/strict";
import { deckGeometry, staticFree, Crowd, connected, fileSegments, restFile, STAIR_W, RUN, runK, WALK_SPEED } from "../src/deckplan.js";
import { CLASSES as SHIP_CLASSES } from "../src/layouts.js";

const GEO = SHIP_CLASSES.map((S) => deckGeometry(S));

test("the stairs are wider: every flight and its hatch 1.6x the first 100 across, landings on the flight, the decks whole, every gun placed", () => {
  assert.ok(STAIR_W >= 160, `STAIR_W ${STAIR_W}`);
  for (const [i, G] of GEO.entries()) {
    const S = SHIP_CLASSES[i];
    const stairs = G.links.filter((l) => l.kind === "stairs");
    assert.ok(stairs.length >= 3, `${S.id}: ${stairs.length} flights`);
    for (const l of stairs) {
      // the flight on the lower deck and (below the waist) its hatch in the deck above
      const lo = [l.a, l.b].sort((p, q) => G.decks[q.deck].y - G.decks[p.deck].y)[0];
      const fl = G.obstacles.find((o) => o.kind === "stairs" && o.deck === lo.deck && (o.link === l.id || (!o.link && Math.abs((o.x0 + o.x1) / 2 - (l.path[1][0] + l.path[2][0]) / 2) < 90)));
      assert.ok(fl, `${S.id}: ${l.id} has its flight`);
      assert.equal(fl.z1 - fl.z0, STAIR_W, `${S.id}: ${l.id} flight ${fl.z1 - fl.z0} across`);
      assert.equal(fl.z1, G.decks[lo.deck].depth, `${S.id}: ${l.id} from the far rail in`);
      const h = G.obstacles.find((o) => o.kind === "hatch" && o.link === l.id);
      if (h) assert.equal(h.z1 - h.z0, STAIR_W, `${S.id}: ${l.id} hatch as wide as its flight`);
      // both landings stand across the flight's width, clear of everything
      for (const e of [l.a, l.b]) {
        assert.ok(e.z > fl.z0 && e.z < fl.z1, `${S.id}: ${l.id} landing on the ${e.deck} at z ${e.z} within the flight`);
        assert.ok(staticFree(G, e.deck, e.x, e.z, 38), `${S.id}: ${l.id} landing on the ${e.deck} clear`);
      }
    }
    for (const d of Object.keys(G.decks)) if (!G.walls.some((w) => w.deck === d && !w.door)) assert.ok(connected(G, d), `${S.id}: the ${d} is one walkable piece`);
    for (const d of S.gunDecks) assert.ok(G.guns.filter((g) => g.deck === d).length >= 8, `${S.id}: a row of guns on the ${d}`);
    // two crewmen abreast fit across a flight (the footprints the 2.5D gives its crew)
    assert.ok(STAIR_W >= 2 * 2 * 30 * S.crewScale + 20, `${S.id}: two abreast`);
  }
});

test("the run: RUN (about 1.8) x the walk on the deck, eased by the controls (0..1); the stairs, ladders and shrouds keep their pace", () => {
  assert.ok(RUN > 1.7 && RUN < 1.9, `RUN ${RUN}`);
  assert.equal(runK({ run: 0 }), 1);
  assert.equal(runK({ run: true }), RUN);
  assert.equal(runK({ run: 1 }), RUN);
  assert.ok(Math.abs(runK({ run: 0.5 }) - (1 + (RUN - 1) / 2)) < 1e-9);
  assert.equal(runK({}), 1);
  for (const [i, G] of GEO.entries()) {
    const S = SHIP_CLASSES[i];
    // on the open waist: a second walking, a second running
    const pace = (run) => {
      const C = new Crowd(G), d = G.decks.main;
      // (from the waist's aft end: the main deck starts in the captain's cabin, behind doorways)
      const a = C.add("captain", { deck: "main", x: S.main[0] + 60, z: 100, r: 30 * S.crewScale, pri: 0 });
      a.manual = { vx: 1, run };
      const x0 = a.x;
      for (let k = 0; k < 60; k++) C.tick(1 / 60);
      assert.deepEqual(C.violations(), []);
      return a.x - x0;
    };
    const walk = pace(0), run = pace(1);
    assert.ok(Math.abs(walk - WALK_SPEED) < 2, `${S.id}: walks ${walk.toFixed(1)} a second`);
    assert.ok(Math.abs(run / walk - RUN) < 0.02, `${S.id}: runs ${(run / walk).toFixed(3)}x`);
    // a link climbed with the run held takes exactly as long as without it
    for (const kind of ["stairs", "ladder", "shrouds"]) {
      const L = G.links.find((l) => l.kind === kind);
      if (!L) continue;
      const climb = (run) => {
        const C = new Crowd(G), a = C.add("captain", { deck: L.a.deck, x: L.a.x, z: L.a.z, r: 30 * S.crewScale, pri: 0 });
        a.manual = { vx: 0, run };
        assert.ok(C.takeLink("captain", G.decks[L.b.deck].y > G.decks[L.a.deck].y ? 1 : -1), `${S.id}: takes the ${kind}`);
        let t = 0;
        for (; t < 30 && !(a.manual && a.deck === L.b.deck); t += 1 / 60) {
          if (a.manual) a.manual.run = run; // (the key is still held as he steps off)
          C.tick(1 / 60);
        }
        return t;
      };
      const tw = climb(0), tr = climb(1);
      assert.ok(tw < 30, `${S.id}: climbed the ${kind}`);
      assert.ok(Math.abs(tr - tw) < 1e-6, `${S.id}: the ${kind} in ${tw.toFixed(2)} s walking, ${tr.toFixed(2)} s with the run held`);
    }
  }
});

// The captain runs the whole ship at every class for a long while: fore and aft on each deck, the
// run held (with short walks between), down and up every way he comes to, among a full crew of
// hands walking to seeded spots. Checked at every 1/60 s step.
function runAbout(i, secs, seed) {
  let s = seed;
  const rnd = () => ((s = (s * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
  const S = SHIP_CLASSES[i], G = GEO[i], C = new Crowd(G);
  const spots = G.stations.filter((q) => q.kind !== "helm").map((q) => ({ deck: q.deck, x: q.x, z: q.z }));
  for (const file of new Set(Object.keys(G.decks).map((d) => restFile(G, d)))) for (const [a, b, dk] of fileSegments(G, file, 30)) for (let x = a; x <= b; x += 170) spots.push({ deck: dk, x, z: G.decks[dk].rest });
  const helm = G.stations.find((q) => q.kind === "helm");
  const cap = C.add("captain", { deck: helm.deck, x: helm.x, z: helm.z, r: 30 * S.crewScale, pri: 0 });
  cap.ghost = true; // (as in the game: the crew never stop him, src/world.js)
  for (let k = 0; k < S.cap - 1; k++) { const q = spots[(k * 5) % spots.length]; C.add("c" + String(k).padStart(2, "0"), { deck: q.deck, x: q.x, z: q.z, r: 26 * S.crewScale, pri: k + 1 }); }
  cap.manual = { vx: 1, run: 1 };
  const out = { bad: [], decks: new Set([cap.deck]), links: 0, runT: 0, far: 0 };
  let dir = 1, lastX = cap.x, stuck = 0, nextLink = 4 + rnd() * 6, way = 1, lastLink = null;
  for (let t = 0, h = 1 / 60; t < secs; t += h) {
    for (const a of C.order()) {
      if (a === cap || a.goal || a.link || rnd() > 0.002) continue;
      const q = spots[Math.floor(rnd() * spots.length)];
      C.goTo(a.id, q);
    }
    if (cap.manual) {
      // fore and aft: turn at the deck's end or when he is held up
      const d = G.decks[cap.deck];
      if (Math.abs(cap.x - lastX) < 0.5) stuck += h; else stuck = 0;
      lastX = cap.x;
      if (cap.x > d.x1 - cap.r - 20) dir = -1;
      else if (cap.x < d.x0 + cap.r + 20) dir = 1;
      else if (stuck > 0.6) (dir = -dir), (stuck = 0);
      // the run held mostly, walks between (the ease in and out both taken over and over)
      const run = (t % 5) < 3.8 ? 1 : 0;
      cap.manual.run = Math.max(0, Math.min(1, (cap.manual.run ?? 0) + (run ? h / 0.25 : -h / 0.3)));
      if (cap.manual.run > 0.99) out.runT += h;
      cap.manual.vx = dir;
      // now and then down (or up) the nearest way: he runs to it (the ships are long) and takes it
      if (t > nextLink) {
        if (!C.linkAt(cap, way)) way = -way;
        const k = C.linkAt(cap, way);
        if (k && k.L.id !== lastLink && C.takeLink("captain", way)) (out.links++, (nextLink = t + 4 + rnd() * 6), (lastLink = k.L.id));
        else {
          // (to one he did not just come by: the next deck, not back where he was)
          const ends = G.links.filter((l) => l.id !== lastLink).flatMap((l) => [l.a, l.b]).filter((e) => e.deck === cap.deck).sort((p, q) => Math.abs(p.x - cap.x) - Math.abs(q.x - cap.x));
          if (!ends.length) lastLink = null;
          if (ends[0] && stuck < 0.3) dir = Math.sign(ends[0].x - cap.x) || dir;
          nextLink = t + 0.1;
        }
      }
    }
    C.tick(h);
    if (cap.manual && !cap.link) out.decks.add(cap.deck);
    const v = C.violations();
    if (v.length && out.bad.length < 5) out.bad.push(`${S.id} ${t.toFixed(2)}s: ${v[0]}`);
  }
  return out;
}

test("running about the whole ship at every class, among a busy crew: nobody in an obstacle, nobody on another, never two on a link", () => {
  for (const i of SHIP_CLASSES.keys()) {
    const S = SHIP_CLASSES[i], r = runAbout(i, 150, 11 + i);
    assert.deepEqual(r.bad, [], `${S.id}: no broken rule at any 1/60 s step`);
    assert.ok(r.runT > 25, `${S.id}: ran for ${r.runT.toFixed(0)} s`);
    assert.ok(r.links >= 8, `${S.id}: took ${r.links} ways up and down`);
    assert.ok(r.decks.size >= 3, `${S.id}: ran on ${[...r.decks]}`);
  }
});
