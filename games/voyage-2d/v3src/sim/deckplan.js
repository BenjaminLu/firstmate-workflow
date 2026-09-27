// The walkable ship: one renderer-free model of every class's decks, shared verbatim by the
// 2.5D game (v3src/sim/deckplan.js) and the 3D game (src/sim/deckplan.js).
//
// Space. Ship space, in the 2.5D's units: x runs from the stern toward the bow, y runs down
// (the main deck's top is y = 0), z runs across the deck from the near rail (0, toward the
// viewer in the 2.5D) to the far rail (DEPTH). A deck is a flat rectangle in (x, z) at a
// height y. The 3D pass maps (x, y, z) onto its hull with one scale and one axis swap.
//
// What is here, all plain data and pure functions (no DOM, no canvas, no randomness):
//   SHIP_CLASSES             the four hulls: deck spans and heights, masts, guns, interior levels
//   hullOutline(S)           the hull's side profile as a polygon (the cutaway and the 3D loft)
//   deckGeometry(S)          decks, obstacles, links (stairs, ladders, shrouds), guns, stations
//   buildNav(G) / findPath   A* (Dijkstra) over a visibility graph per deck plus the links
//   planRest(G, items)       where everyone stands at rest: stations, spaced by drawn widths
//   Crowd                    deterministic walking: paths, link climbs, separation, the captain
// See docs/interface.md §5 and docs/movement-spec.md "For the 3D pass".

export const DEPTH = 420; // deck width across (z), every deck but the crow's nest
export const NEST_DEPTH = 260;
const C = DEPTH / 2, F = DEPTH; // the centre line and the far rail
export const Z_SCREEN = 36 / DEPTH; // the 2.5D draws z as a lift of y: the far rail is 36 up
const R_NAV = 40; // obstacle inflation for paths: the widest footprint plus a margin

// A mast: its x, its truck, its yards ([y, half-span], top down) and, on the mainmast, the crow's
// nest's floor. The nest sits at the lower masthead: over the course yard, below the topsail
// yard, a standing lookout's head just under that yard in the 2.5D's drawn rig (the rig is drawn
// scaled about the deck, the nest where the crew walk it; the 3D stands its topmast on the nest).
const mast = (x, top, yards, nest) => ({ x, top, yards, nest });
// levels: the interior floors below the main deck, top to bottom; the last is the hold, the
// others are gun decks. ride: how far the ship floats up so the lowest gun deck is dry.
export const SHIP_CLASSES = [
  {
    id: "sloop", cap: 7, en: "Sloop", tw: "單桅帆船", cn: "单桅帆船", gang: -90,
    stern: -640, bow: 820, qd: [-620, -330, -120], main: [-330, 440, 0], fore: [440, 660, -70],
    masts: [mast(40, -1150, [[-900, 230], [-620, 190]])], guns: 4, crewScale: 1,
    levels: [330, 660], bottom: 770, ride: 210,
  },
  {
    id: "brig", cap: 12, en: "Brig", tw: "雙桅橫帆船", cn: "双桅横帆船", gang: -100,
    stern: -840, bow: 1000, qd: [-820, -450, -140], main: [-450, 600, 0], fore: [600, 840, -80],
    masts: [mast(-260, -1260, [[-1000, 220], [-740, 180]]), mast(330, -1380, [[-1140, 250], [-880, 210], [-640, 170]], -1030)], guns: 6, crewScale: 0.95,
    levels: [315, 630], bottom: 740, ride: 195,
  },
  {
    id: "frigate", cap: 18, en: "Frigate", tw: "巡防艦", cn: "巡防舰", gang: -115,
    stern: -1000, bow: 1240, qd: [-980, -520, -150], main: [-520, 760, 0], fore: [760, 1060, -90],
    masts: [mast(-640, -1180, [[-980, 200], [-770, 160]]), mast(40, -1520, [[-1260, 290], [-980, 250], [-700, 200]], -1160), mast(700, -1280, [[-1080, 230], [-820, 190]])],
    guns: 7, crewScale: 0.9,
    levels: [300, 600], bottom: 710, ride: 180,
  },
  {
    id: "line", cap: 24, en: "Ship of the line", tw: "戰列艦", cn: "战列舰", gang: -125,
    stern: -1360, bow: 1620, qd: [-1340, -760, -170], main: [-760, 1080, 0], fore: [1080, 1420, -100],
    masts: [mast(-900, -1420, [[-1200, 250], [-960, 210], [-740, 170]]), mast(120, -1900, [[-1640, 340], [-1330, 300], [-1030, 250], [-760, 200]], -1420), mast(960, -1560, [[-1340, 270], [-1060, 230], [-800, 190]])],
    guns: 10, crewScale: 0.84,
    levels: [285, 570, 855], bottom: 960, ride: 450,
  },
];
for (const c of SHIP_CLASSES) c.gunRows = c.levels.slice(0, -1).map((y) => y - 78); // muzzle heights
export const classFor = (n) => SHIP_CLASSES.find((c) => n <= c.cap) || SHIP_CLASSES[SHIP_CLASSES.length - 1];
export const levelIds = (S) => S.levels.map((_, i, a) => (i === a.length - 1 ? "hold" : i === 0 ? "gun" : "gun" + (i + 1)));

const lerp = (a, b, k) => a + (b - a) * k;
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));

// ---------------------------------------------------------------- the hull's profile
// A closed polygon in (x, y), clockwise from the stern's top: the quarterdeck's rail, the waist,
// the forecastle, the stem, the keel, the transom. The 2.5D fills it; the 3D can loft it.
export function hullOutline(S, n = 14) {
  const qy = S.qd[2] - 60, fy = S.fore[2] - 60, B = S.bottom;
  const pts = [[S.stern, qy]];
  let cur = [S.stern, qy];
  const L = (x, y) => { pts.push([x, y]); cur = [x, y]; };
  const Q = (cx, cy, x, y) => { const [x0, y0] = cur; for (let i = 1; i <= n; i++) { const t = i / n, u = 1 - t; pts.push([u * u * x0 + 2 * u * t * cx + t * t * x, u * u * y0 + 2 * u * t * cy + t * t * y]); } cur = [x, y]; };
  const C = (c1x, c1y, c2x, c2y, x, y) => { const [x0, y0] = cur; for (let i = 1; i <= n; i++) { const t = i / n, u = 1 - t; pts.push([u * u * u * x0 + 3 * u * u * t * c1x + 3 * u * t * t * c2x + t * t * t * x, u * u * u * y0 + 3 * u * u * t * c1y + 3 * u * t * t * c2y + t * t * t * y]); } cur = [x, y]; };
  L(S.qd[1] - 40, qy);
  Q(S.qd[1], qy, S.qd[1], -60);
  L(S.fore[0], -60);
  Q(S.fore[0] + 10, fy, S.fore[0] + 50, fy);
  L(S.bow - 170, fy);
  Q(S.bow - 40, fy + 10, S.bow, fy - 40);
  // the stem sweeps down and aft into the keel
  C(S.bow - 20, B * 0.28, S.bow - 150, B * 0.86, S.bow - 430, B);
  L(S.stern + 330, B);
  // the transom and the counter
  C(S.stern + 110, B, S.stern - 20, B * 0.72, S.stern - 40, B * 0.38);
  Q(S.stern - 60, (B * 0.38 + qy) / 2, S.stern, qy);
  return pts;
}
// the hull's inside span [x0, x1] at height y (the widest run of the polygon at that y)
export function hullSpanAt(S, y, pts = hullOutline(S)) {
  const xs = [];
  for (let i = 0; i < pts.length; i++) {
    const [ax, ay] = pts[i], [bx, by] = pts[(i + 1) % pts.length];
    if ((ay <= y && by > y) || (by <= y && ay > y)) xs.push(ax + ((y - ay) / (by - ay)) * (bx - ax));
  }
  xs.sort((a, b) => a - b);
  return xs.length >= 2 ? [xs[0], xs[xs.length - 1]] : [0, 0];
}

// ---------------------------------------------------------------- the decks
// Everything a crewman needs to walk the ship, for one class (or a spec between two, while the
// ship changes class). Pure: the same spec gives the same geometry.
export function deckGeometry(S) {
  const pts = hullOutline(S);
  const ids = levelIds(S);
  const decks = {}, obstacles = [], links = [], guns = [], stations = [];
  const G = { spec: S, decks, obstacles, links, guns, stations, hull: pts };
  const deck = (id, kind, y, x0, x1, extra = {}) => (decks[id] = { id, kind, y, x0, x1, depth: DEPTH, rest: 38, topside: kind === "qd" || kind === "main" || kind === "fore", ...extra });
  const ob = (d, kind, x0, x1, z0, z1, extra = {}) => { const o = { deck: d, kind, x0, x1, z0, z1, ...extra }; obstacles.push(o); return o; };
  const L = (id, kind, a, b, path, extra = {}) => { const l = { id, kind, a, b, path, len: pathLen(path), ...extra }; links.push(l); return l; };
  const [q0, q1, qy] = S.qd, [m0, m1] = S.main, [f0, f1, fy] = S.fore;
  deck("qd", "qd", qy, q0 + 12, q1);
  deck("main", "main", 0, m0, m1);
  deck("fore", "fore", fy, f0, f1 + 10);
  // the cutaway window: the near side of the hull is cut away from under the main deck down to
  // the hold's floor, between the stern's counter and the bow's sweep
  const cut = { x0: S.stern + 90, x1: S.bow - 170, y0: 24, y1: S.levels[S.levels.length - 1] + 26 };
  G.cut = cut;
  ids.forEach((id, i) => {
    const y = S.levels[i];
    const [a, b] = hullSpanAt(S, y + 4, pts);
    deck(id, id === "hold" ? "hold" : "gun", y, Math.max(a + 40, cut.x0 + 20), Math.min(b - 40, cut.x1 - 20), { rest: id === "hold" ? 38 : 98, level: i });
  });
  // masts: through the deck each stands on and every level below it, down to the keel
  const onDeck = (x) => (x < q1 ? "qd" : x >= f0 ? "fore" : "main");
  S.masts.forEach((m, i) => {
    const w = 24 * (m.g ?? 1);
    for (const d of [onDeck(m.x), ...ids]) if (decks[d] && m.x - w > decks[d].x0 + 4 && m.x + w < decks[d].x1 - 4) ob(d, "mast", m.x - w, m.x + w, C - 24, C + 24, { mast: i });
  });
  const mi = S.masts.length ? Math.min(S.masts.length - 1, S.masts.length === 1 ? 0 : 1) : -1, mainMast = S.masts[mi];
  G.mainMast = mi;
  if (mainMast?.nest) {
    deck("nest", "nest", mainMast.nest, mainMast.x - 104, mainMast.x + 104, { depth: NEST_DEPTH, rest: 40, mast: mi });
    ob("nest", "mast", mainMast.x - 20, mainMast.x + 20, 112, 148, { mast: mi });
  }
  // the helm: the wheel on the quarterdeck
  G.wheelX = q0 + 220;
  ob("qd", "wheel", G.wheelX - 28, G.wheelX + 28, C - 45, C + 45);
  // stairs from the quarterdeck and the forecastle down to the waist, on the far side
  L("qd-main", "stairs", { deck: "qd", x: q1 - 50, z: F - 72 }, { deck: "main", x: q1 + 166, z: F - 72 }, [[q1 - 50, qy], [q1, qy], [q1 + 100, 0], [q1 + 166, 0]]);
  ob("main", "stairs", q1, q1 + 104, F - 90, F);
  L("fore-main", "stairs", { deck: "fore", x: f0 + 50, z: F - 72 }, { deck: "main", x: f0 - 166, z: F - 72 }, [[f0 + 50, fy], [f0, fy], [f0 - 100, 0], [f0 - 166, 0]]);
  ob("main", "stairs", f0 - 104, f0, F - 90, F);
  // the shrouds: from the waist's rail up the ratlines to the crow's nest
  if (decks.nest) {
    const mx = mainMast.x, on = onDeck(mx), by = decks[on].y;
    for (const s of [-1, 1]) {
      const e = { deck: on, x: mx + s * 200, z: C - 30 };
      if (!staticFree(G, on, e.x, e.z, 38)) continue;
      L("shrouds", "shrouds", e, { deck: "nest", x: mx + s * 64, z: 40 }, [[mx + s * 200, by], [mx + s * 226, by - 70], [mx + s * 70, mainMast.nest + 60], [mx + s * 64, mainMast.nest]]);
      break;
    }
  }
  // Everything else is placed where it fits: its own footprint clear of what is there, its link
  // ends clear, and every deck it touches still passable at every x behind the resting crew.
  const place = (want, lo, hi, make) => {
    for (let d = 0; d <= hi - lo; d += 10) for (const s of d ? [1, -1] : [1]) {
      const x = want + s * d;
      if (x < lo || x > hi) continue;
      const mark = [obstacles.length, links.length];
      const r = make(x);
      if (r !== false && fits(G, mark)) return x;
      obstacles.length = mark[0];
      links.length = mark[1];
    }
    return null;
  };
  const stairs = (id, up, dn, xt, s) => {
    const U = decks[up], D = decks[dn], run = Math.max(200, (D.y - U.y) * 0.7);
    const a = Math.min(xt, xt + s * run * 0.82), b = Math.max(xt, xt + s * run * 0.82);
    ob(up, "hatch", a, b, F - 100, F, { link: id });
    ob(dn, "stairs", Math.min(xt, xt + s * run), Math.max(xt, xt + s * run), F - 100, F, { link: id });
    L(id, "stairs", { deck: up, x: xt - s * 64, z: F - 72 }, { deck: dn, x: xt + s * (run + 64), z: F - 72 }, [[xt - s * 64, U.y], [xt, U.y], [xt + s * run, D.y], [xt + s * (run + 64), D.y]]);
  };
  const ladder = (id, up, dn, x, s) => {
    const U = decks[up], D = decks[dn];
    ob(up, "hatch", x - 52, x + 52, C - 42, C + 42, { link: id });
    ob(dn, "ladder", x - 20, x + 20, C - 22, C + 22, { link: id });
    L(id, "ladder", { deck: up, x: x + s * 96, z: C }, { deck: dn, x: x + s * 66, z: C }, [[x + s * 96, U.y], [x + s * 14, U.y], [x + s * 14, D.y], [x + s * 66, D.y]]);
  };
  const tryBoth = (fn) => (x) => { for (const s of [-1, 1]) { const mark = [obstacles.length, links.length]; fn(x, s); if (fits(G, mark)) return true; obstacles.length = mark[0]; links.length = mark[1]; } return false; };
  const within = (up, dn) => [Math.max(decks[up].x0, decks[dn].x0) + 60, Math.min(decks[up].x1, decks[dn].x1) - 60];
  // the companionway from the waist down to the gun deck
  {
    const [lo, hi] = within("main", "gun");
    place(m0 + 280, lo, hi, tryBoth((x, s) => stairs("main-gun", "main", "gun", x, s)));
  }
  // down through the gun decks to the hold
  for (let i = 1; i < ids.length; i++) {
    const up = ids[i - 1], dn = ids[i], [lo, hi] = within(up, dn);
    const want = lerp(lo, hi, i % 2 ? 0.52 : 0.3);
    place(want, lo, hi, tryBoth((x, s) => (dn === "hold" ? ladder(up + "-" + dn, up, dn, x, s) : stairs(up + "-" + dn, up, dn, x, s))));
  }
  // a second way between the lower levels (a ladder, forward or aft of the first), where the
  // hull is long enough: two ways halve the queues
  for (let i = 1; i < ids.length; i++) {
    const up = ids[i - 1], dn = ids[i], [lo, hi] = within(up, dn);
    if (hi - lo < 1100) continue;
    const first = links.find((l) => l.id === up + "-" + dn), fx = first ? (first.a.x + first.b.x) / 2 : (lo + hi) / 2;
    const want = fx > (lo + hi) / 2 ? lerp(lo, hi, 0.2) : lerp(lo, hi, 0.8);
    place(want, lo, hi, tryBoth((x, s) => (ladder(up + "-" + dn + "-2", up, dn, x, s), (links[links.length - 1].spare = true))));
  }
  // the fore hatch: a second way down from the waist, where the waist is long enough
  if (m1 - m0 > 900) { const [lo, hi] = within("main", "gun"); place(m1 - 200, Math.max(lo, m0 + 60), Math.min(hi, m1 - 60), tryBoth((x, s) => (ladder("main-gun-fwd", "main", "gun", x, s), (links[links.length - 1].spare = true)))); }
  // the capstan in the waist
  G.capX = place(lerp(m0, m1, 0.64), m0 + 60, m1 - 60, (x) => ob("main", "capstan", x - 46, x + 46, C - 46, C + 46)) ?? (m0 + m1) / 2;
  // the guns: one row per gun deck, a gun on each side at each port
  ids.slice(0, -1).forEach((id, row) => {
    const d = decks[id], ok = [];
    for (let x = d.x0 + 60; x <= d.x1 - 60; x += 10) {
      const mark = [obstacles.length, links.length];
      ob(id, "gun", x - 40, x + 40, 0, 60);
      ob(id, "gun", x - 40, x + 40, F - 60, F);
      if (fits(G, mark)) ok.push(x);
      obstacles.length = mark[0];
    }
    let xs = [];
    for (const gap of [150, 130, 112]) if ((xs = pickSpread(ok, S.guns, gap)).length >= S.guns) break;
    xs.forEach((x, i) => {
      guns.push({ deck: id, row, i, x, y: d.y - 78 });
      ob(id, "gun", x - 40, x + 40, 0, 60, { gun: i });
      ob(id, "gun", x - 40, x + 40, F - 60, F, { gun: i, far: true });
    });
  });
  // cargo in the hold: casks and crates against the far side
  {
    const d = decks.hold, ok = [];
    for (let x = d.x0 + 60; x <= d.x1 - 60; x += 10) {
      const mark = [obstacles.length, links.length];
      ob("hold", "cask", x - 52, x + 52, F - 104, F);
      if (fits(G, mark)) ok.push(x);
      obstacles.length = mark[0];
    }
    pickSpread(ok, Math.max(2, Math.round((d.x1 - d.x0) / 360)), 150).forEach((x, i) => ob("hold", i % 2 ? "crate" : "cask", x - 52, x + 52, F - 104, F, { i }));
  }
  // ---------------------------------------------------------------- stations
  // helm: the captain, just aft of the wheel. mate: the firstmate, forward of him. review: the
  // reviewer on the forecastle. gun: behind each gun. rig: by each mast and the capstan.
  // lookout: the crow's nest (or the bow where there is none).
  const st = (id, kind, d, x, dir = 1, extra = {}) => {
    if (decks[d]?.topside) d = onDeck(x);
    const D = decks[d];
    if (!D || x < D.x0 + 36 || x > D.x1 - 36) return;
    stations.push({ id, kind, deck: d, x, z: D.rest, dir, ...extra });
  };
  st("helm", "helm", "qd", G.wheelX - 20, 1);
  st("mate", "mate", "qd", lerp(q0, q1, 0.78), 1);
  st("review", "review", "fore", lerp(f0, f1, 0.45), -1);
  for (const gn of guns) st(`gun-${gn.deck}-${gn.i}`, "gun", gn.deck, gn.x, gn.i % 2 ? -1 : 1, { gun: gn.i, row: gn.row });
  S.masts.forEach((m, i) => {
    const on = onDeck(m.x);
    if (on === "qd" && Math.abs(m.x - G.wheelX) < 260) return;
    st(`rig-${i}a`, "rig", on, m.x - 105, 1, { mast: i });
    st(`rig-${i}b`, "rig", on, m.x + 105, -1, { mast: i });
  });
  st("rig-cap", "rig", "main", G.capX - 110, 1, { capstan: true });
  if (decks.nest) st("lookout-nest", "lookout", "nest", decks.nest.x0 + 150, 1, { nest: true });
  st("lookout-bow", "lookout", "fore", f1 - 40, 1);
  return G;
}
// every deck touched since `mark` is still passable and nothing new overlaps
function fits(G, [no, nl]) {
  const fresh = G.obstacles.slice(no), freshL = G.links.slice(nl);
  for (const o of fresh) {
    const d = G.decks[o.deck];
    if (!d || o.x0 < d.x0 + 2 || o.x1 > d.x1 - 2) return false;
    for (const p of G.obstacles.slice(0, no)) if (p.deck === o.deck && o.x0 < p.x1 + 12 && p.x0 < o.x1 + 12 && o.z0 < p.z1 + 12 && p.z0 < o.z1 + 12) return false;
  }
  for (const l of G.links) for (const e of [l.a, l.b]) if (!staticFree(G, e.deck, e.x, e.z, 38)) return false;
  // landings of different links stay well apart (two queues on one spot knot up)
  for (const l of freshL) for (const e of [l.a, l.b]) for (const k of G.links) if (k !== l) for (const f of [k.a, k.b]) if (f.deck === e.deck && Math.abs(f.x - e.x) < (l.spare ? 260 : 120) && Math.hypot(f.x - e.x, f.z - e.z) < (l.spare ? 400 : 120)) return false;
  const touched = new Set([...fresh.map((o) => o.deck), ...freshL.flatMap((l) => [l.a.deck, l.b.deck])]);
  for (const dk of touched) if (!connected(G, dk)) return false;
  return true;
}
// the deck's free space (for a walker of radius R_NAV) is one piece, end to end
export function connected(G, deckId) {
  const d = G.decks[deckId];
  let prev = null, comps = 0;
  const parent = [];
  const find = (i) => (parent[i] === i ? i : (parent[i] = find(parent[i])));
  for (let x = d.x0 + R_NAV; x <= d.x1 - R_NAV + 0.01; x += 8) {
    const col = freeZ(G, deckId, x, false).map(([p, q]) => { parent.push(parent.length); comps++; return { p, q, i: parent.length - 1 }; });
    if (!col.length) return false;
    if (prev) for (const A of prev) for (const B of col) if (A.p < B.q - 2 && B.p < A.q - 2) { const ra = find(A.i), rb = find(B.i); if (ra !== rb) (parent[ra] = rb), comps--; }
    prev = col;
  }
  return comps === 1;
}
// the free centre-z intervals for a walker (radius R_NAV) at x; with rest, the resting crew's
// lane counts as taken
export function freeZ(G, deckId, x, rest) {
  const d = G.decks[deckId], R = R_NAV;
  let free = [[R, d.depth - R]];
  const take = (a, b) => { const out = []; for (const [p, q] of free) { if (b <= p || a >= q) out.push([p, q]); else { if (a > p) out.push([p, a]); if (b < q) out.push([b, q]); } } free = out; };
  for (const o of G.obstacles) {
    if (o.deck !== deckId) continue;
    const dx = x < o.x0 ? o.x0 - x : x > o.x1 ? x - o.x1 : 0;
    if (dx >= R) continue;
    const w = Math.sqrt(R * R - dx * dx);
    take(o.z0 - w, o.z1 + w);
  }
  if (rest) take(d.rest - 76, d.rest + 76);
  return free.filter(([p, q]) => q - p >= 4);
}
// n values from a sorted list, spread evenly, at least `gap` apart
function pickSpread(ok, n, gap) {
  if (!ok.length || !n) return [];
  const out = [];
  for (let k = 0; k < n; k++) {
    const t = n === 1 ? (ok[0] + ok[ok.length - 1]) / 2 : lerp(ok[0], ok[ok.length - 1], k / (n - 1));
    let best = null, bd = Infinity;
    for (const x of ok) if (out.every((y) => Math.abs(y - x) >= gap) && Math.abs(x - t) < bd) (bd = Math.abs(x - t)), (best = x);
    if (best !== null) out.push(best);
  }
  return out.sort((a, b) => a - b);
}
function pathLen(p) { let s = 0; for (let i = 1; i < p.length; i++) s += Math.hypot(p[i][0] - p[i - 1][0], p[i][1] - p[i - 1][1]); return s; }
// ---------------------------------------------------------------- collision helpers
// Footprints are circles in (x, z); obstacles are rectangles in (x, z); a deck's bounds keep a
// footprint wholly on it.
export function circleHitsRect(x, z, r, o) {
  const dx = x - clamp(x, o.x0, o.x1), dz = z - clamp(z, o.z0, o.z1);
  return dx * dx + dz * dz < r * r - 1e-6;
}
export function inBounds(d, x, z, r) { return x >= d.x0 + r - 1e-6 && x <= d.x1 - r + 1e-6 && z >= r - 1e-6 && z <= d.depth - r + 1e-6; }
export function staticFree(G, deckId, x, z, r) {
  const d = G.decks[deckId];
  if (!d || !inBounds(d, x, z, r)) return false;
  for (const o of G.obstacles) if (o.deck === deckId && circleHitsRect(x, z, r, o)) return false;
  return true;
}
// segment (x1,z1)-(x2,z2) against a rectangle grown by R with rounded corners (a capsule test)
function segHitsRect(x1, z1, x2, z2, o, R) {
  // the segment crosses the rectangle itself
  let t0 = 0, t1 = 1;
  const dx = x2 - x1, dz = z2 - z1;
  let cross = true;
  for (const [p, q] of [[-dx, x1 - o.x0], [dx, o.x1 - x1], [-dz, z1 - o.z0], [dz, o.z1 - z1]]) {
    if (Math.abs(p) < 1e-9) { if (q < 0) { cross = false; break; } continue; }
    const t = q / p;
    if (p < 0) { if (t > t1) { cross = false; break; } if (t > t0) t0 = t; } else { if (t < t0) { cross = false; break; } if (t < t1) t1 = t; }
  }
  if (cross && t1 >= t0) return true;
  const r2 = R * R;
  const pr = (x, z) => { const ex = x - clamp(x, o.x0, o.x1), ez = z - clamp(z, o.z0, o.z1); return ex * ex + ez * ez; };
  if (pr(x1, z1) < r2 || pr(x2, z2) < r2) return true;
  const L2 = dx * dx + dz * dz;
  for (const [cx, cz] of [[o.x0, o.z0], [o.x1, o.z0], [o.x0, o.z1], [o.x1, o.z1]]) {
    const t = L2 ? clamp(((cx - x1) * dx + (cz - z1) * dz) / L2, 0, 1) : 0;
    const ex = x1 + t * dx - cx, ez = z1 + t * dz - cz;
    if (ex * ex + ez * ez < r2) return true;
  }
  // an edge of the rectangle passing within R of the segment's interior
  for (const [ax, az, bx, bz] of [[o.x0, o.z0, o.x1, o.z0], [o.x0, o.z1, o.x1, o.z1], [o.x0, o.z0, o.x0, o.z1], [o.x1, o.z0, o.x1, o.z1]]) {
    if (segSegDist2(x1, z1, x2, z2, ax, az, bx, bz) < r2) return true;
  }
  return false;
}
function segSegDist2(ax, az, bx, bz, cx, cz, dx, dz) {
  const d = (px, pz, qx, qz, rx, rz) => { const vx = rx - qx, vz = rz - qz, L = vx * vx + vz * vz, t = L ? clamp(((px - qx) * vx + (pz - qz) * vz) / L, 0, 1) : 0; const ex = qx + t * vx - px, ez = qz + t * vz - pz; return ex * ex + ez * ez; };
  return Math.min(d(ax, az, cx, cz, dx, dz), d(bx, bz, cx, cz, dx, dz), d(cx, cz, ax, az, bx, bz), d(dx, dz, ax, az, bx, bz));
}
function segFree(G, deckId, x1, z1, x2, z2, R) {
  for (const o of G.obstacles) if (o.deck === deckId && segHitsRect(x1, z1, x2, z2, o, R - 0.5)) return false;
  return true;
}

// ---------------------------------------------------------------- the nav graph and A*
// A column graph per deck: every 24 units along x, a node at each run of free z (for a walker
// of radius R_NAV); runs in neighbouring columns that overlap are joined. Link ends join the
// columns they see, and each link joins its two ends. Routes are smoothed by line of sight.
const COL = 8, R_WALK = 36;
// the resting crew's lane: walkers keep out of it (it costs REST_COST times as much) unless
// there is no other way, and only step into it at the end, onto their own spot
const REST_BAND = 76, REST_COST = 8;
const RESERVE = 260; // how near a link a walker must be to hold it
const LANDING = 44; // a landing's radius: kept clear for the link's holder
const SLIP = 6; // seconds boxed in before a walker slips past (see Crowd.slip)
export const SHROUD_SECS = 3.2; // the longest the shrouds take to climb, deck to nest, at any class
export function buildNav(G, R = R_NAV) {
  const nodes = [], edges = [], cols = {};
  const add = (deck, x, z, link = null) => { nodes.push({ i: nodes.length, deck, x, z, link }); edges.push([]); return nodes.length - 1; };
  const join = (a, b, c) => { edges[a].push([b, c, null]); edges[b].push([a, c, null]); };
  for (const d of Object.values(G.decks)) {
    const list = (cols[d.id] = []);
    for (let x = d.x0 + R; x <= d.x1 - R + 0.01; x += COL) {
      const band = d.rest + REST_BAND;
      const col = freeZ(G, d.id, x, false).map(([p, q]) => {
        const zs = q - p > 70 ? [p + 6, (p + q) / 2, q - 6] : [(p + q) / 2];
        if (band + 4 > p && band + 4 < q) zs.push(band + 4);
        zs.sort((u, v) => u - v);
        const ids = zs.map((z) => add(d.id, x, z));
        for (let k = 1; k < ids.length; k++) join(ids[k - 1], ids[k], Math.abs(nodes[ids[k]].z - nodes[ids[k - 1]].z) * (nodes[ids[k - 1]].z < band ? REST_COST : 1));
        return { p, q, ids };
      });
      const prev = list[list.length - 1];
      if (prev) for (const A of prev.col) for (const B of col) if (A.p < B.q && B.p < A.q) for (const i of A.ids) for (const j of B.ids) {
        const a = nodes[i], b = nodes[j];
        if (segFree(G, d.id, a.x, a.z, b.x, b.z, R - 4)) join(i, j, Math.hypot(a.x - b.x, a.z - b.z) * (a.z < band || b.z < band ? REST_COST : 1));
      }
      list.push({ x, col });
    }
  }
  const nav = { G, R, nodes, edges, cols };
  for (const l of G.links) {
    const ia = add(l.a.deck, l.a.x, l.a.z, l.id), ib = add(l.b.deck, l.b.x, l.b.z, l.id);
    for (const [k, [v, c]] of seen(nav, l.a)) join(ia, k, c);
    for (const [k, [v, c]] of seen(nav, l.b)) join(ib, k, c);
    const c = l.len * (l.kind === "stairs" ? 1.2 : 1.8);
    edges[ia].push([ib, c, l.id]);
    edges[ib].push([ia, c, l.id]);
  }
  return nav;
}
// the column nodes a spot on a deck can walk straight to
function seen(nav, p, rad = R_WALK, reach = 48) {
  const out = new Map(), list = nav.cols[p.deck] || [];
  for (const { x, col } of list) {
    if (Math.abs(x - p.x) > reach) continue;
    for (const C of col) for (const i of C.ids) {
      const n = nav.nodes[i];
      if (segFree(nav.G, p.deck, p.x, p.z, n.x, n.z, rad)) out.set(i, [n, Math.hypot(n.x - p.x, n.z - p.z)]);
    }
  }
  return out;
}
// the route from one spot to another: [{ deck, walk: [[x, z], ...] }, { link, from, to }, ...]
export function findPath(nav, from, to, r = R_WALK, busy = null) {
  const { G, nodes, edges } = nav;
  if (!G.decks[from.deck] || !G.decks[to.deck]) return null;
  if (from.deck === to.deck && segFree(G, from.deck, from.x, from.z, to.x, to.z, Math.min(r, R_WALK)) && Math.min(from.z, to.z) >= G.decks[from.deck].rest + REST_BAND - 1e-6) return [{ deck: from.deck, walk: [[to.x, to.z]] }];
  const N = nodes.length, S = N, T = N + 1;
  const dist = new Float64Array(N + 2).fill(Infinity), prev = new Int32Array(N + 2).fill(-1), via = new Array(N + 2).fill(null);
  const goal = seen(nav, to, Math.min(r, R_WALK));
  // a walker pressed into a pocket the graph cannot see from (between a hatch and a flight, say)
  // steps out along the nearest line clear of the obstacles themselves
  let start = seen(nav, from, Math.min(r, R_WALK));
  if (!start.size) start = seen(nav, from, 1, 260);
  // A*: the heuristic is the straight distance (links are never shorter than their ends' gap)
  const hx = (i) => (i === T ? 0 : Math.hypot(nodes[i].x - to.x, (nodes[i].deck === to.deck ? nodes[i].z - to.z : 0)));
  const heap = [];
  const push = (i, f) => { heap.push([f, i]); let k = heap.length - 1; while (k) { const p = (k - 1) >> 1; if (heap[p][0] <= heap[k][0]) break; [heap[p], heap[k]] = [heap[k], heap[p]]; k = p; } };
  const pop = () => { const top = heap[0], last = heap.pop(); if (heap.length) { heap[0] = last; let k = 0; for (;;) { const l = 2 * k + 1, r = l + 1; let m = k; if (l < heap.length && heap[l][0] < heap[m][0]) m = l; if (r < heap.length && heap[r][0] < heap[m][0]) m = r; if (m === k) break; [heap[m], heap[k]] = [heap[k], heap[m]]; k = m; } } return top; };
  dist[S] = 0;
  push(S, 0);
  const out = (u) => (u === S ? [...start].map(([v, [, c]]) => [v, c, null]) : goal.has(u) ? edges[u].concat([[T, goal.get(u)[1], null]]) : edges[u]);
  while (heap.length) {
    const [f, u] = pop();
    if (u === T) break;
    if (f > dist[u] + (u === S ? 0 : hx(u)) + 1e-6) continue;
    for (const [v, c, l] of out(u)) {
      const nd = dist[u] + c + (l && busy?.[l] ? busy[l] : 0);
      if (nd < dist[v] - 1e-9) { dist[v] = nd; prev[v] = u; via[v] = l; push(v, nd + hx(v)); }
    }
  }
  if (!isFinite(dist[T])) return null;
  const chain = [];
  for (let v = T; v !== S; v = prev[v]) chain.push(v);
  chain.reverse();
  const steps = [];
  let walk = { deck: from.deck, walk: [] }, at = from;
  for (const v of chain) {
    const p = v === T ? to : nodes[v];
    if (via[v]) {
      if (walk.walk.length) steps.push(walk);
      steps.push({ link: via[v], from: nodes[prev[v]].deck, to: p.deck });
      walk = { deck: p.deck, walk: [] };
    } else walk.walk.push([p.x, p.z]);
    at = p;
  }
  if (walk.walk.length) steps.push(walk);
  // smooth each walk by line of sight
  let cur = from;
  for (const s of steps) {
    if (s.link) { const l = G.links.find((k) => k.id === s.link); cur = l.a.deck === s.to ? l.a : l.b; continue; }
    const out = [];
    let px = cur.x, pz = cur.z, i = 0;
    while (i < s.walk.length) {
      let j = s.walk.length - 1;
      const band = G.decks[s.deck].rest + REST_BAND;
      // a straight line may cross the resting lane, but not run along it
      const inBand = (x1, z1, x2, z2) => { if (z1 >= band && z2 >= band) return 0; if (z1 < band && z2 < band) return Math.abs(x2 - x1); const f = (band - Math.min(z1, z2)) / Math.abs(z2 - z1); return Math.abs(x2 - x1) * f; };
      const ok = (k) => segFree(G, s.deck, px, pz, s.walk[k][0], s.walk[k][1], R_WALK) && (k === i || inBand(px, pz, s.walk[k][0], s.walk[k][1]) <= 60);
      while (j > i && !ok(j)) j--;
      out.push(s.walk[j]);
      [px, pz] = s.walk[j];
      i = j + 1;
    }
    s.walk = out;
    cur = { x: px, z: pz };
  }
  return steps;
}
// the length of a route, in walking units (links weighted as in the graph)
export function routeCost(G, from, steps) {
  let x = from.x, z = from.z, c = 0;
  for (const s of steps) {
    if (s.link) { const l = G.links.find((k) => k.id === s.link); c += l.len * (l.kind === "stairs" ? 1.2 : 1.8); const e = l.a.deck === s.to ? l.a : l.b; x = e.x; z = e.z; continue; }
    for (const [px, pz] of s.walk) (c += Math.hypot(px - x, pz - z)), (x = px), (z = pz);
  }
  return c;
}

// ---------------------------------------------------------------- where everyone rests
// Files: the topside (quarterdeck, waist and forecastle read as one row from the stern to the
// bow), each interior deck, the nest. Within a file each crewman keeps his drawn width (ext, at
// full size) and a GAP from his neighbours, and his footprint stays clear of obstacles and link
// ends on the rest lane. When a file cannot hold its crew at full size, everyone is drawn
// smaller (fit), as before.
export const GAP = 16;
export function restFile(G, deckId) { return G.decks[deckId]?.topside ? "top" : deckId; }
// the allowed centre intervals of a file for a footprint of radius f
export function fileSegments(G, file, f) {
  const decks = file === "top" ? ["qd", "main", "fore"].map((k) => G.decks[k]) : [G.decks[file]];
  const segs = [];
  for (const d of decks) {
    if (!d) continue;
    let s = [[d.x0 + f, d.x1 - f]];
    const cut = (a, b) => { const out = []; for (const [p, q] of s) { if (b <= p || a >= q) out.push([p, q]); else { if (a > p) out.push([p, a]); if (b < q) out.push([b, q]); } } s = out; };
    for (const o of G.obstacles) if (o.deck === d.id && o.z0 < d.rest + f && o.z1 > d.rest - f) {
      const dz = d.rest < o.z0 ? o.z0 - d.rest : d.rest > o.z1 ? d.rest - o.z1 : 0, w = Math.sqrt(Math.max(0, f * f - dz * dz));
      cut(o.x0 - w - 1, o.x1 + w + 1);
    }
    for (const l of G.links) for (const e of [l.a, l.b]) if (e.deck === d.id && Math.abs(e.z - d.rest) < 2 * f + 4) cut(e.x - 2 * f - 6, e.x + 2 * f + 6);
    // where walkers can only pass through the resting lane, nobody rests
    for (let x = d.x0 + R_NAV; x <= d.x1 - R_NAV; x += 8) if (!freeZ(G, d.id, x, true).length) cut(x - 2 * f - 8, x + 2 * f + 8);
    for (const [p, q] of s) if (q - p >= 0) segs.push([p, q, d.id]);
  }
  return segs.sort((a, b) => a[0] - b[0]);
}
// items: [{ id, deck, x (want), dir, ext: [l, r] at fit 1, f (footprint at fit 1), gapL? }]
// returns { fit, at: { id: { deck, x, z, dir } } }
export function planRest(G, items) {
  let fit = 1;
  for (let tries = 0; tries < 40; tries++) {
    const at = {};
    let ok = true;
    const files = {};
    for (const it of items) (files[restFile(G, it.deck)] ||= []).push(it);
    for (const [file, list] of Object.entries(files)) {
      const r = solveFile(G, file, list, fit);
      if (!r) { ok = false; break; }
      Object.assign(at, r);
    }
    if (ok) return { fit, at };
    fit *= 0.95;
  }
  // nothing fits: stack them anyway at their wants (never expected)
  const at = {};
  for (const it of items) at[it.id] = { deck: it.deck, x: it.x, z: G.decks[it.deck]?.rest ?? 38, dir: it.dir };
  return { fit, at };
}
function solveFile(G, file, list, fit) {
  const fMax = Math.max(...list.map((it) => it.f)); // footprints do not shrink with the drawing
  const segs = fileSegments(G, file, fMax);
  if (!segs.length) return null;
  const items = list.map((it) => ({ ...it, l: it.ext[0] * fit, r: it.ext[1] * fit, gapL: it.gapL ?? GAP })).sort((a, b) => a.x - b.x || (a.rank ?? 9) - (b.rank ?? 9) || (a.id < b.id ? -1 : 1));
  const n = items.length;
  // one file, as close to each want as the boxes allow (pool adjacent violators)
  const cum = [0];
  for (let i = 1; i < n; i++) cum[i] = cum[i - 1] + items[i - 1].r - items[i].l + items[i].gapL;
  const blocks = [];
  for (let i = 0; i < n; i++) {
    blocks.push({ v: items[i].x - cum[i], w: items[i].weight || 1 }); // a heavy item (the captain at his wheel) moves least
    blocks[blocks.length - 1].n = 1;
    while (blocks.length > 1 && blocks[blocks.length - 2].v > blocks[blocks.length - 1].v) {
      const q = blocks.pop(), o = blocks[blocks.length - 1];
      o.v = (o.v * o.w + q.v * q.w) / (o.w + q.w);
      o.w += q.w;
      o.n += q.n;
    }
  }
  const xs = [];
  for (const bl of blocks) for (let j = 0; j < bl.n; j++) xs.push(bl.v + cum[xs.length]);
  const lo = segs[0][0], hi = segs[segs.length - 1][1];
  const snapR = (x) => { for (const [a, b] of segs) { if (x <= b) return Math.max(x, a); } return Infinity; };
  const snapL = (x) => { for (let k = segs.length - 1; k >= 0; k--) { const [a, b] = segs[k]; if (x >= a) return Math.min(x, b); } return -Infinity; };
  // forward: keep the gaps, step over what is in the way
  for (let i = 0; i < n; i++) {
    let x = Math.max(xs[i], lo);
    if (i) x = Math.max(x, xs[i - 1] + items[i - 1].r + items[i].gapL - items[i].l);
    xs[i] = snapR(x);
  }
  // backward: pull back inside the far end
  for (let i = n - 1; i >= 0; i--) {
    let x = Math.min(xs[i], hi);
    if (i < n - 1) x = Math.min(x, xs[i + 1] + items[i + 1].l - items[i + 1].gapL - items[i].r);
    xs[i] = snapL(x);
  }
  for (let i = 0; i < n; i++) {
    if (!isFinite(xs[i]) || xs[i] < lo - 1e-6) return null;
    if (items[i].pin != null && Math.abs(xs[i] - items[i].x) > items[i].pin) return null; // pinned (the captain at his wheel): draw smaller instead
    if (i && xs[i] - xs[i - 1] < items[i - 1].r - items[i].l + items[i].gapL - 1e-6) return null;
  }
  const at = {};
  items.forEach((it, i) => {
    const seg = segs.find(([a, b]) => xs[i] >= a - 1e-6 && xs[i] <= b + 1e-6);
    const d = seg ? seg[2] : it.deck;
    at[it.id] = { deck: d, x: xs[i], z: G.decks[d].rest, dir: it.dir };
  });
  return at;
}

// ---------------------------------------------------------------- the crowd
// Deterministic walking on the deck graph: fixed 1/60 s steps, agents in a fixed order
// (priority, then id), no randomness. The rules:
//   - a move is taken only if the footprint stays on the deck, clear of every obstacle and of
//     every other footprint on that deck, so no two crewmen ever overlap and none ever stands
//     in a mast, a gun or a hatch;
//   - walkers keep out of the resting lane, where the crew stand at their stations;
//   - blocked, a walker keeps right (45°, then 90°), then the left side, then waits and asks
//     whoever is in the way to give way: someone just off a link first, then the captain,
//     then by rank; anyone who has been waiting gives way to anyone on the move; nobody at
//     rest is ever asked. The one who gives way steps aside (or back), holds a moment, and
//     plans again;
//   - links (stairs, ladders, shrouds) take one crewman at a time; the next waits a stride back.
export class Crowd {
  constructor(G) {
    this.t = 0;
    this.acc = 0;
    this.agents = new Map();
    this.linkBusy = {};
    this.setGeometry(G);
  }
  setGeometry(G) {
    this.G = G;
    this.nav = buildNav(G);
    this.links = Object.fromEntries(G.links.map((l) => [l.id, l]));
    this.linkBusy = {};
    const order = this.order();
    for (const a of order) {
      a.plan = null; a.wait = 0; a.yieldFrom = null; a.yieldUntil = 0; a.holdUntil = 0; a.placed = false; a.want = null; a.leaving = null;
      // a goal the new decks cannot hold (gone, or off the deck, or in something) is dropped
      if (a.goal && !staticFree(G, a.goal.deck, a.goal.x, a.goal.z, a.r)) (a.goal = null), (a.onArrive = null);
      if (a.link) { const l = a.link, e = l.s > l.L.len / 2 ? l.to : l.from; a.deck = e.deck; a.x = e.x; a.z = e.z; a.link = null; }
      // the deck is gone (the nest, a lower gun deck): step onto the deck nearest it
      if (!G.decks[a.deck]) a.deck = a.deck.startsWith("gun") && G.decks.gun ? "gun" : "main";
    }
    // everyone keeps his spot if it is still clear, else takes the nearest clear one
    for (const a of order) {
      const d = G.decks[a.deck];
      a.x = clamp(a.x, d.x0 + a.r, d.x1 - a.r);
      a.z = clamp(a.z, a.r, d.depth - a.r);
      if (!this.free(a.deck, a.x, a.z, a.r, a, true)) {
        const p = this.findFree(a.deck, a.x, a.z, a.r, a, true);
        if (p) (a.x = p.x), (a.z = p.z), (a.deck = p.deck);
      }
      a.placed = true;
    }
  }
  order() { return [...this.agents.values()].sort((a, b) => a.pri - b.pri || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)); }
  // add a crewman at (or as near as possible to) a spot
  add(id, { deck, x, z, r = 30, pri = 50, speed = 300, dir = 1 }) {
    const a = { id, deck, x, z, r, pri, speed, dir, goal: null, plan: null, link: null, wait: 0, manual: null, moving: false, idleT: 0, yieldFrom: null, yieldUntil: 0, holdUntil: 0, offLink: 0, placed: false };
    this.agents.set(id, a);
    if (!this.G.decks[a.deck]) a.deck = "main";
    const d = this.G.decks[a.deck];
    a.x = clamp(a.x, d.x0 + r, d.x1 - r);
    a.z = clamp(a.z, r, d.depth - r);
    const p = this.free(a.deck, a.x, a.z, r, a) ? null : this.findFree(a.deck, a.x, a.z, r, a);
    if (p) Object.assign(a, p);
    a.placed = true;
    return a;
  }
  remove(id) {
    const a = this.agents.get(id);
    if (!a) return;
    if (a.link && this.linkBusy[a.link.L.id] === id) delete this.linkBusy[a.link.L.id];
    this.agents.delete(id);
  }
  get(id) { return this.agents.get(id); }
  // is this footprint clear of the deck's edges, its obstacles and everyone else on it
  free(deck, x, z, r, self, placedOnly = false) {
    if (!staticFree(this.G, deck, x, z, r)) return false;
    for (const b of this.agents.values()) {
      if (b === self || (placedOnly && !b.placed)) continue;
      const p = this.footOn(b, deck);
      if (p && (p[0] - x) ** 2 + (p[1] - z) ** 2 < (b.r + r) ** 2 - 1e-6) return false;
    }
    // a held link's two landings belong to its holder; anyone else inside may only move out
    for (const [id, who] of Object.entries(this.linkBusy)) {
      if (self && who === self.id) continue;
      const L = this.links[id];
      if (!L) continue;
      for (const e of [L.a, L.b]) {
        if (e.deck !== deck) continue;
        const d2 = (e.x - x) ** 2 + (e.z - z) ** 2, lim = (LANDING + r) ** 2;
        if (d2 >= lim) continue;
        if (!self || self.deck !== deck || (e.x - self.x) ** 2 + (e.z - self.z) ** 2 >= d2) return false;
      }
    }
    return true;
  }
  // where an agent's footprint stands on a deck (a climber holds the end of his link he is near)
  footOn(b, deck) {
    if (!b.link) return b.deck === deck ? [b.x, b.z] : null;
    const l = b.link, near = l.s < l.L.len * 0.35 ? l.from : l.s > l.L.len * 0.5 ? l.to : null;
    return near && near.deck === deck ? [near.x, near.z] : null;
  }
  findFree(deck, x, z, r, self, placedOnly = false) {
    const decks = [deck, ...Object.keys(this.G.decks).filter((k) => k !== deck)];
    for (const dk of decks) {
      const d = this.G.decks[dk];
      for (let ring = 0; ring < 120; ring++) {
        const rad = ring * 10, n = Math.max(1, ring * 6);
        for (let k = 0; k < n; k++) {
          const ang = (k / n) * Math.PI * 2;
          const px = clamp(x + Math.cos(ang) * rad, d.x0 + r, d.x1 - r), pz = clamp((dk === deck ? z : d.rest) + Math.sin(ang) * rad * 0.5, r, d.depth - r);
          if (this.free(dk, px, pz, r, self, placedOnly)) return { deck: dk, x: px, z: pz };
        }
      }
    }
    return null;
  }
  // send someone somewhere (a spot on a deck); onArrive runs when he gets there
  goTo(id, goal, onArrive) {
    const a = this.agents.get(id);
    if (!a) return false;
    a.goal = { ...goal };
    a.onArrive = onArrive || null;
    a.plan = null;
    a.wait = 0;
    a.manual = null;
    if (!a.link) this.replan(a);
    return !!(a.plan || a.link || this.at(a, a.goal));
  }
  stop(id) { const a = this.agents.get(id); if (a) (a.goal = null), (a.plan = null), (a.onArrive = null); }
  at(a, g, tol = 3) { return !a.link && a.deck === g.deck && Math.hypot(a.x - g.x, a.z - g.z) <= tol; }
  // plan (again) from where he stands; links someone else holds cost more, so a queue is
  // walked round by another way when there is one
  replan(a) {
    const busy = {};
    for (const [id, who] of Object.entries(this.linkBusy)) if (who !== a.id) busy[id] = 500;
    a.plan = a.goal ? findPath(this.nav, { deck: a.deck, x: a.x, z: a.z }, a.goal, a.r, busy) : null;
    a.replanned = this.t;
  }
  step(dt) {
    this.acc += Math.min(dt, 0.25);
    const h = 1 / 60;
    while (this.acc >= h - 1e-9) { this.acc -= h; this.tick(h); }
  }
  tick(h) {
    this.t += h;
    const order = this.order();
    for (const [id, who] of Object.entries(this.linkBusy)) {
      const b = this.agents.get(who);
      const next = b?.plan?.find((st) => st.link)?.link;
      if (b && b.leaving === id && !b.link) {
        const L = this.links[id], e = L && [L.a, L.b].find((k) => k.deck === b.deck);
        if (e && Math.hypot(e.x - b.x, e.z - b.z) < LANDING + b.r + 2 && b.offLink > -3) continue;
        b.leaving = null;
      }
      if (!b || (b.link?.L.id !== id && next !== id)) delete this.linkBusy[id];
    }
    // a free link goes to whoever has waited for it longest (first come, first served)
    this.grant = {};
    for (const a of order) {
      if (!a.want) continue;
      const next = a.plan?.[1]?.link, st = a.plan?.[1];
      for (const id of Object.keys(a.want)) {
        const L = this.links[id], e = L && st && (L.a.deck === st.from ? L.a : L.b);
        if (id !== next || a.link || !e || e.deck !== a.deck || Math.hypot(e.x - a.x, e.z - a.z) >= RESERVE) delete a.want[id];
      }
      for (const [id, since] of Object.entries(a.want)) {
        const g = this.grant[id] && this.agents.get(this.grant[id]);
        if (!g || since < g.want[id]) this.grant[id] = a.id;
      }
    }
    for (const a of order) {
      const px = a.x, pz = a.z, pl = a.link?.s;
      if (a.link) this.climb(a, h);
      else if (a.yieldFrom && this.t < a.yieldUntil) this.giveWay(a, h);
      else {
        if (a.yieldFrom) (a.yieldFrom = null), (a.holdUntil = this.t + 0.3), (a.plan = null);
        if (this.t < a.holdUntil) {}
        else if (a.manual) this.drive(a, h);
        else if (a.goal) this.walk(a, h);
      }
      if (a.leaving || a.offLink > 0) a.offLink -= h;
      a.moving = !!a.link && a.link.s !== pl || Math.hypot(a.x - px, a.z - pz) > 1e-3;
      a.idleT = a.moving || a.goal ? 0 : a.idleT + h;
    }
  }
  // who goes first when two meet
  rank(a) {
    // someone giving way carries the rank of whoever asked him (so a chain can clear)
    if (a.yieldFrom && this.t < a.yieldUntil) return a.yieldRank;
    if (a.link || a.offLink > 0) return -3;
    if (a.manual) return a.manual.vx ? -2 : 500;
    // whoever holds a link is on his way to clear a queue
    const next = a.plan?.[1]?.link;
    if (next && this.linkBusy[next] === a.id) return -1;
    return (a.wait > 0.5 ? 1000 : 0) + a.pri;
  }
  // may b be asked to give way (never someone at rest)
  movable(b) { return !b.link && (b.goal || b.manual || b.yieldFrom); }
  ask(a, ux, uz, d) {
    const ra = this.rank(a), nx = a.x + ux * Math.max(d, 4), nz = a.z + uz * Math.max(d, 4);
    for (const b of this.agents.values()) {
      if (b === a || b.deck !== a.deck || !this.movable(b) || this.rank(b) <= ra) continue;
      if ((b.x - nx) ** 2 + (b.z - nz) ** 2 < (a.r + b.r + 4) ** 2) {
        if (!b.yieldFrom || this.t >= b.yieldUntil || b.yieldRank > ra) (b.yieldFrom = a), (b.yieldDir = [ux, uz]), (b.yieldRank = ra);
        b.yieldUntil = this.t + 0.5;
      }
    }
  }
  // step out of the asker's way: to his left, else ahead of him; pass the request on if stuck
  giveWay(a, h) {
    const [ux, uz] = a.yieldDir, d = a.speed * h * 0.9;
    const c = Math.SQRT1_2, L = [uz, -ux], R = [-uz, ux], F = [ux, uz], B = [-ux, -uz];
    const mix = (p, q) => [c * (p[0] + q[0]), c * (p[1] + q[1])];
    const order = a.yieldFrom?.link ? [F, mix(F, L), mix(F, R), L, R, mix(B, L), mix(B, R)] : [L, R, F, mix(F, L), mix(F, R), mix(B, L), mix(B, R)];
    for (const [vx, vz] of order) {
      const nx = a.x + vx * d, nz = a.z + vz * d;
      if (this.free(a.deck, nx, nz, a.r, a)) return void ((a.x = nx), (a.z = nz));
    }
    this.ask(a, ux, uz, d);
  }
  // one step along (ux, uz), keeping right when blocked; true when a step was taken
  tryMove(a, ux, uz, d) {
    const c = Math.SQRT1_2, rx = -uz, rz = ux;
    const cand = [[ux, uz], [c * (ux + rx), c * (uz + rz)], [rx, rz], [c * (ux - rx), c * (uz - rz)], [-rx, -rz]];
    for (const [vx, vz] of cand) {
      const nx = a.x + vx * d, nz = a.z + vz * d;
      if (this.free(a.deck, nx, nz, a.r, a)) { a.x = nx; a.z = nz; if (Math.abs(vx) > 0.2) a.dir = vx > 0 ? 1 : -1; return true; }
    }
    this.ask(a, ux, uz, d);
    return false;
  }
  walk(a, h) {
    if (!a.plan) {
      if (this.at(a, a.goal)) return this.arrive(a);
      if (this.t - (a.replanned ?? -9) > 0.4) this.replan(a);
      if (!a.plan) return void (a.wait += h);
    }
    const s = a.plan[0];
    if (!s) return this.at(a, a.goal, 6) ? this.arrive(a) : void (a.plan = null);
    if (s.link) {
      const L = this.G.links.find((k) => k.id === s.link);
      const from = L.a.deck === s.from ? L.a : L.b, to = from === L.a ? L.b : L.a;
      if (a.deck !== from.deck) return void (a.plan = null);
      if (this.linkBusy[L.id] !== a.id) {
        if (this.linkBusy[L.id] || (this.grant?.[L.id] && this.grant[L.id] !== a.id)) return void (a.wait += h);
        this.linkBusy[L.id] = a.id;
      }
      if (Math.hypot(a.x - from.x, a.z - from.z) > 4) return void a.plan.unshift({ deck: a.deck, walk: [[from.x, from.z]] });
      a.link = { L, from, to, s: 0, rev: from === L.b };
      a.plan.shift();
      a.wait = 0;
      return;
    }
    if (s.deck !== a.deck) return void (a.plan = null);
    const wp = s.walk[0];
    const tx = wp[0], tz = wp[1];
    // a link is held for whoever is coming to it from near by: nobody else heads for it (so
    // nobody queues on its landings); the rest wait where they are until it is free
    const nxt = a.plan[1];
    if (nxt?.link) {
      const L = this.G.links.find((k) => k.id === nxt.link), e = L.a.deck === nxt.from ? L.a : L.b;
      if (this.linkBusy[L.id] !== a.id) {
        const de = Math.hypot(e.x - a.x, e.z - a.z);
        if (de < RESERVE) {
          (a.want ||= {})[L.id] ??= this.t;
          if (this.linkBusy[L.id] || this.grant?.[L.id] !== a.id) {
            // held by someone else: wait here (its landings are his); after a while look for
            // another way
            a.wait += h;
            if (a.wait > 1.5 && this.t - a.replanned > 1.5) this.replan(a);
            return;
          }
          this.linkBusy[L.id] = a.id;
          delete a.want[L.id];
        }
      }
    }
    const dx = tx - a.x, dz = tz - a.z, dist = Math.hypot(dx, dz);
    if (dist < 0.5) { s.walk.shift(); if (!s.walk.length) a.plan.shift(); return; }
    const d = Math.min(dist, a.speed * h);
    const x0 = a.x, z0 = a.z;
    // progress toward this waypoint: no real gain for SLIP seconds is a knot
    if (a.wpKey !== wp) (a.wpKey = wp), (a.best = dist), (a.noGain = 0);
    if (dist < a.best - 12) (a.best = dist), (a.noGain = 0);
    else if ((a.noGain = (a.noGain || 0) + h) > SLIP) return (a.noGain = 0), (a.best = dist), this.slip(a, s);
    if (this.tryMove(a, dx / dist, dz / dist, d)) {
      a.wait = Math.max(0, a.wait - h);
      if (Math.hypot(tx - a.x, tz - a.z) < 1) { if (this.free(a.deck, tx, tz, a.r, a)) (a.x = tx), (a.z = tz); s.walk.shift(); if (!s.walk.length) a.plan.shift(); }
      // a side step off the route: plan again from here soon
      else if (Math.abs((a.x - x0) * dz - (a.z - z0) * dx) / dist > d * 0.5 && this.t - a.replanned > 0.6) a.plan = null;
      a.blocked = 0;
    } else {
      a.wait += h;
      a.blocked = (a.blocked || 0) + h;
      if (a.blocked > SLIP) return this.slip(a, s);
      if (a.wait > 0.8 && this.t - a.replanned > 0.8) this.replan(a);
    }
  }
  // the last resort, when a walker has been boxed in for SLIP seconds: he slips past to the
  // first clear spot further along his way on this deck (never into anyone or anything); the
  // renderer shows it as a quick fade. Rare, deterministic, and it keeps every rule.
  slip(a, s) {
    const pts = [[a.x, a.z], ...s.walk];
    const cand = [];
    for (let i = 1; i < pts.length; i++) {
      const [x0, z0] = pts[i - 1], [x1, z1] = pts[i], len = Math.hypot(x1 - x0, z1 - z0);
      for (let d = 0; d <= len; d += 8) cand.push([x0 + ((x1 - x0) * d) / len, z0 + ((z1 - z0) * d) / len]);
    }
    for (let k = cand.length - 1; k >= 0; k--) {
      const [x, z] = cand[k];
      if (Math.hypot(x - a.x, z - a.z) < a.r * 2 + 8 || Math.hypot(x - a.x, z - a.z) > 320) continue;
      if (this.free(a.deck, x, z, a.r, a)) { a.x = x; a.z = z; a.slipped = this.t; a.blocked = 0; a.plan = null; this.slips = (this.slips || 0) + 1; return; }
    }
    a.blocked = SLIP - 2;
  }
  climb(a, h) {
    // the shrouds go up the rig at a hand's pace whatever the mast's height: never slower than
    // SHROUD_SECS from the rail to the nest
    const l = a.link, speed = l.L.kind === "shrouds" ? Math.max(a.speed * 0.5, l.L.len / SHROUD_SECS) : a.speed * (l.L.kind === "stairs" ? 0.75 : 0.5);
    if (l.s < l.L.len) {
      // past half way he holds the far end: only when it is clear
      const hold = l.L.len * 0.5, ns = Math.min(l.L.len, l.s + speed * h);
      if (l.s <= hold && ns > hold && !this.free(l.to.deck, l.to.x, l.to.z, a.r, a)) {
        l.stall = (l.stall || 0) + h;
        if (l.stall > SLIP) {
          const p = this.findFree(l.to.deck, l.to.x, l.to.z, a.r, a);
          if (p && p.deck === l.to.deck) { a.deck = p.deck; a.x = p.x; a.z = p.z; a.link = null; a.offLink = 1.2; a.leaving = l.L.id; a.slipped = this.t; this.slips = (this.slips || 0) + 1; return; }
        }
        return void this.clearLanding(a, l.to);
      }
      if (l.s > hold) this.clearLanding(a, l.to);
      l.s = ns;
      return;
    }
    // step off at the far end when there is room
    if (this.free(l.to.deck, l.to.x, l.to.z, a.r, a)) {
      a.deck = l.to.deck; a.x = l.to.x; a.z = l.to.z;
      a.link = null;
      a.offLink = 1.2;
      a.leaving = l.L.id; // he holds it until he is off its landing
    } else {
      l.stall = (l.stall || 0) + h;
      if (l.stall > SLIP) {
        const p = this.findFree(l.to.deck, l.to.x, l.to.z, a.r, a);
        if (p && p.deck === l.to.deck) { a.deck = p.deck; a.x = p.x; a.z = p.z; a.link = null; a.offLink = 1.2; a.leaving = l.L.id; a.slipped = this.t; this.slips = (this.slips || 0) + 1; return; }
      }
      this.clearLanding(a, l.to);
    }
  }
  // a climber asks whoever stands on the landing he is coming to to step off it
  clearLanding(a, e) {
    for (const b of this.agents.values()) {
      if (b === a || b.deck !== e.deck || !this.movable(b)) continue;
      const dx = b.x - e.x, dz = b.z - e.z, dd = Math.hypot(dx, dz);
      if (dd < Math.max(LANDING, a.r) + b.r + 4) (b.yieldFrom = a), (b.yieldDir = dd > 1 ? [dx / dd, dz / dd] : [1, 0]), (b.yieldUntil = this.t + 0.5), (b.yieldRank = -3);
    }
  }
  arrive(a) {
    a.plan = null;
    if (a.goal?.dir) a.dir = a.goal.dir;
    a.goal = null;
    a.wait = 0;
    const f = a.onArrive;
    a.onArrive = null;
    f?.();
  }
  // the captain at the helm of his legs: vx in -1..1 walks the deck, stepping round whoever and
  // whatever is in the way
  drive(a, h) {
    const m = a.manual;
    if (!m.vx) return;
    const ux = Math.sign(m.vx), d = a.speed * Math.min(1, Math.abs(m.vx)) * h;
    a.dir = ux;
    // steer across the deck toward the open lane ahead (round masts, hatches, stairs, guns)
    const ahead = freeZ(this.G, a.deck, clamp(a.x + ux * 70, this.G.decks[a.deck].x0 + R_NAV, this.G.decks[a.deck].x1 - R_NAV), false);
    let tz = a.z;
    if (ahead.length && !ahead.some(([p, q]) => a.z >= p && a.z <= q)) {
      let best = Infinity;
      for (const [p, q] of ahead) { const z = clamp(a.z, p + 4, q - 4), dd = Math.abs(z - a.z); if (dd < best) (best = dd), (tz = z); }
    }
    const dz = clamp((tz - a.z) / 50, -1.2, 1.2), n = Math.hypot(1, dz);
    this.tryMove(a, ux / n, dz / n, d);
  }
  // the nearest link end on this deck, within reach, that goes up (-1) or down (+1)
  linkAt(a, way, reach = 90) {
    if (a.link) return null;
    let best = null, bd = reach;
    for (const L of this.G.links) for (const [e, o] of [[L.a, L.b], [L.b, L.a]]) {
      if (e.deck !== a.deck) continue;
      const up = this.G.decks[o.deck].y < this.G.decks[e.deck].y;
      if (way && (way < 0) !== up) continue;
      const d = Math.abs(e.x - a.x) + Math.max(0, Math.abs(e.z - a.z) - 200) * 0.5;
      if (d < bd) (bd = d), (best = { L, from: e, to: o, up });
    }
    return best;
  }
  // take a link from where he stands: walk to its end, climb, and hand back control
  takeLink(id, way, done) {
    const a = this.agents.get(id);
    const k = a && this.linkAt(a, way);
    if (!k) return false;
    const keep = !!a.manual;
    a.manual = null;
    a.goal = { deck: k.to.deck, x: k.to.x, z: k.to.z };
    a.plan = [{ deck: a.deck, walk: [[k.from.x, k.from.z]] }, { link: k.L.id, from: k.from.deck, to: k.to.deck }];
    a.replanned = this.t;
    a.onArrive = () => { if (keep) a.manual = { vx: 0 }; done?.(); };
    return true;
  }
  // every broken rule right now: overlaps, footprints in obstacles or off their deck, two on one link
  violations() {
    const out = [];
    const list = this.order();
    for (const a of list) {
      if (a.link) continue;
      if (!staticFree(this.G, a.deck, a.x, a.z, a.r)) out.push(`${a.id} in an obstacle or off the ${a.deck} at ${a.x.toFixed(0)},${a.z.toFixed(0)}`);
    }
    for (let i = 0; i < list.length; i++) for (let j = i + 1; j < list.length; j++) {
      const a = list[i], b = list[j];
      if (a.link && b.link && a.link.L.id === b.link.L.id) out.push(`${a.id} and ${b.id} on one link`);
      for (const dk of Object.keys(this.G.decks)) {
        const p = this.footOn(a, dk), q = this.footOn(b, dk);
        if (p && q && Math.hypot(p[0] - q[0], p[1] - q[1]) < a.r + b.r - 0.5) out.push(`${a.id} overlaps ${b.id} on the ${dk}`);
      }
    }
    return out;
  }
}
// a point along a link's path at distance s: [x, y] in ship space
export function linkPoint(L, s, rev = false) {
  const p = rev ? L.path.slice().reverse() : L.path;
  let left = clamp(s, 0, L.len);
  for (let i = 1; i < p.length; i++) {
    const seg = Math.hypot(p[i][0] - p[i - 1][0], p[i][1] - p[i - 1][1]);
    if (left <= seg || i === p.length - 1) { const k = seg ? Math.min(1, left / seg) : 1; return [lerp(p[i - 1][0], p[i][0], k), lerp(p[i - 1][1], p[i][1], k), i]; }
    left -= seg;
  }
  return [p[p.length - 1][0], p[p.length - 1][1], p.length - 1];
}
// is the climber on the steep part (a ladder's rungs or the shrouds) at distance s
export function linkSteep(L, s, rev = false) {
  const p = rev ? L.path.slice().reverse() : L.path;
  const [, , i] = linkPoint(L, s, rev);
  const dx = Math.abs(p[i][0] - p[i - 1][0]), dy = Math.abs(p[i][1] - p[i - 1][1]);
  return dy > dx * 2.2;
}
