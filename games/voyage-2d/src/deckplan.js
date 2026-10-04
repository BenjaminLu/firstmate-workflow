// The walkable ship of the 2.5D game (v2.5): one renderer-free model of every ship's decks,
// rooms, doors, stairs and ladders, built from plain data (a "layout", the same shape a mod
// supplies; see docs/modding.md). Forked from the shared v3src/sim/deckplan.js, which the frozen
// 3D game keeps; this file is the 2.5D's own.
//
// Space. Ship space: x runs from the stern toward the bow, y runs down (the main deck's floor is
// y = 0), z runs across the deck from the near rail (0, toward the viewer) to the far rail
// (DEPTH). A deck is a flat rectangle in (x, z) at a height y. One unit is about 1/200 of a
// crewman's height at crew scale 1: a deck is LEVEL (480) below the one above, so a room is
// about 2.4 crewmen tall, and the ship of the line is about 57 crewmen long.
//
// What is here, all plain data and pure functions (no DOM, no canvas, no randomness):
//   CLASSES / setClasses      the ship classes, built from layouts (src/layouts.js, or a mod's)
//   specOf(layout)            a layout's spec: hull, decks, masts, the helm, the waist
//   hullOutline(S)            the hull's side profile as a polygon (fill it, clip to it)
//   deckGeometry(S)           decks, rooms, walls with doors, obstacles, links, guns, stations
//   checkLayout(S)            every room, station and deck reachable from the helm (a mod's gate)
//   buildNav / findPath       A* over a column graph per deck plus the links
//   planRest(G, items)        where everyone stands at rest: stations, spaced by drawn widths
//   Crowd                     deterministic walking; the captain is never blocked by the crew
// See docs/interface.md §5 and docs/modding.md.

export const DEPTH = 420; // deck width across (z), every deck but a crow's nest
export const NEST_DEPTH = 260;
const C = DEPTH / 2, F = DEPTH; // the centre line and the far rail
export const Z_SCREEN = 36 / DEPTH; // the 2.5D draws z as a lift of y: the far rail is 36 up
const R_NAV = 40; // obstacle inflation for paths: the widest footprint plus a margin
export const LEVEL = 480; // a deck's height (floor to floor) in the default ships
export const BEAM = 30; // a deck's thickness under its floor
export const WALL = 24; // a bulkhead's thickness
export const DOOR = [130, 330]; // a doorway through a bulkhead, across the deck (z)
// a flight of stairs across the deck (z), from the far rail in: wide enough for two crewmen abreast
export const STAIR_W = 160;
const STAIR_Z = F - STAIR_W / 2 - 20;
// the captain's run (Shift, or the joystick pushed to its rim): his deck speed times this;
// links (stairs, ladders, shrouds) keep their own pace, and nobody else runs
export const RUN = 1.8;
// everyone's walking pace on deck (units a second). The big ship (2026-09-28) kept the small
// ship's 300 and the captain said it dragged (「整體移動要快速一點, 現在太拖」, and his run no
// longer read as one: a run across the ship of the line took 19 s). At 1100 a walk from the
// captain's cabin to the bow of the frigate takes ~8 s and a run ~5 s. Stairs and ladders keep
// their share of it (0.85 and 0.55).
export const WALK_SPEED = 1100;
export const runK = (m) => 1 + (RUN - 1) * Math.max(0, Math.min(1, +m.run || 0));
export const SEA_LEVEL = 150; // the sea's surface in world y (src/env.js SEA_Y): a ship rides at waterline - SEA_LEVEL

const lerp = (a, b, k) => a + (b - a) * k;
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const ease = (k) => (k <= 0 ? 0 : k >= 1 ? 1 : k * k * (3 - 2 * k));

// ---------------------------------------------------------------- room kinds
// What a room of each kind holds when it is furnished (the default), and the stations it gives.
// A layout may add its own props and stations, or set "furnish": false on a room.
//   helm        an open deck with the wheel: the captain's station (and the mate's, if no chart room)
//   cabin       the captain's great cabin: his desk (where a decision waits) and room for callers
//   chart       the chart room: the firstmate's chart table
//   waist       the open main deck: workbenches, the capstan (hands at work)
//   workshop    an inside workroom: workbenches (hands at work)
//   forecastle  the bow's open deck: lookouts
//   gundeck     guns on both sides: the gates (a hand whose check is red)
//   quarters    hammocks and sea chests: hands at rest, and a hand who is down
//   galley      the stove and the mess table: hands at rest
//   cargo       casks and crates: the backlog and the ready work, stowed; overflow rest
//   nest        a crow's nest (made by a mast with "nest": true): reviewers and hands in review
//   open        nothing
export const ROOM_KINDS = ["helm", "cabin", "chart", "waist", "workshop", "forecastle", "gundeck", "quarters", "galley", "cargo", "nest", "open"];
export const PROP_KINDS = ["gun", "cask", "crate", "workbench", "table", "desk", "stove", "chest", "capstan", "wheel", "hammock", "lantern", "shelf", "bell"];
export const STATION_KINDS = ["helm", "mate", "cabin", "visit", "chart", "work", "rig", "lookout", "review", "gate", "rest", "cargo"];
// battle stations (the kraken's call: "All hands! Battle stations!"): the captain at the bow rail,
// the firstmate beside him, gunners at the guns nearest the bow, riggers at the forward rigging,
// hands carrying shot up from the hold, lookouts in the nests and the bow. A layout may give its
// own (`battle`: [{ post, deck, x }]); else they are made from its rooms, forward first.
export const BATTLE_POSTS = ["captain", "mate", "gun", "rig", "ammo", "lookout"];
// a prop's footprint on its deck: width in x, and its z range (props with no z range are
// drawn only: hung from the beams, or on a wall)
export const PROP_SIZE = {
  gun: [80, [0, 60]], cask: [104, [F - 104, F]], crate: [104, [F - 104, F]], workbench: [150, [150, 250]],
  table: [200, [150, 270]], desk: [180, [170, 280]], stove: [140, [F - 120, F]], chest: [84, [F - 80, F]],
  capstan: [92, [C - 46, C + 46]], wheel: [56, [C - 45, C + 45]], hammock: [200, null], lantern: [30, null], shelf: [160, null], bell: [60, null],
};

// ---------------------------------------------------------------- the spec
// A layout (plain data) becomes a spec: the numbers the drawing and the walking share. Decks
// with no x0/x1 take the hull's inside span at their height. A mast's yards and nest follow its
// height. The spec keeps the names the rest of the game reads: qd (the helm deck), fore (the
// forecastle), main (the open waist), bottom (the keel), ride (how high she floats), gunRows.
export function specOf(L) {
  const h = L.hull, len = h.bow - h.stern;
  const S = {
    id: L.id, cap: L.cap, crewScale: L.crewScale ?? 1, layout: L,
    en: L.name?.en || L.id, tw: L.name?.["zh-TW"] || L.name?.en || L.id, cn: L.name?.["zh-CN"] || L.name?.["zh-TW"] || L.name?.en || L.id,
    stern: h.stern, bow: h.bow, bottom: h.keel, wl: h.waterline, ride: h.waterline - SEA_LEVEL, len,
  };
  S.decksIn = L.decks.map((d) => ({ ...d })).sort((a, b) => a.y - b.y);
  // the outline needs the castles (the decks above the main deck), so it comes first
  S.hull = hullOutline(S);
  for (const d of S.decksIn) {
    if (d.x0 == null || d.x1 == null) {
      const [a, b] = hullSpanAt(S, d.y + 6, S.hull);
      if (d.x0 == null) d.x0 = Math.round(a + 70);
      if (d.x1 == null) d.x1 = Math.round(b - 70);
    }
  }
  const D = Object.fromEntries(S.decksIn.map((d) => [d.id, d]));
  const room = (k) => (L.rooms || []).find((r) => r.kind === k);
  const helm = room("helm"), qd = D[helm?.deck] || D.qd || D.main;
  S.qd = [qd.x0, qd.x1, qd.y];
  const fc = room("forecastle"), fore = D[fc?.deck] || D.fore || D.main;
  S.fore = [Math.max(fore.x0, fc?.x0 ?? fore.x0), Math.min(fore.x1, fc?.x1 ?? fore.x1), fore.y];
  const waist = room("waist") || {};
  S.main = [Math.max(D.main.x0, waist.x0 ?? D.main.x0), Math.min(D.main.x1, waist.x1 ?? D.main.x1), 0];
  S.levels = S.decksIn.filter((d) => d.y > 0).map((d) => d.y);
  // the rig: a mast's height over its deck, yards spread down it, the nest at the lower masthead
  const deckAt = (x) => { let best = D.main; for (const d of S.decksIn) if (d.y <= 0 && x >= d.x0 - 1 && x <= d.x1 + 1 && d.y < best.y) best = d; return best; };
  S.masts = (L.masts || []).map((m, i) => {
    const base = deckAt(m.x).y, H = m.height, n = Math.max(2, Math.min(5, Math.round(H / 1300)));
    const span = m.span ?? H * 0.19;
    const yards = [];
    for (let j = 0; j < n; j++) {
      const k = (j + 0.2) / (n - 0.2);
      yards.push([Math.round(base - H * (0.93 - 0.72 * k)), Math.round(span * (0.62 + 0.38 * k))]);
    }
    // the nest: its floor over the course (lowest) yard, a standing lookout under the next
    const course = yards[n - 1][0], topsail = yards[n - 2][0];
    const nest = m.nest ? Math.round(course - (course - topsail) * 0.42) : null;
    return { x: m.x, top: base - H, base, yards, nest, i };
  });
  // the guns' muzzle heights, one row per gun deck (top first)
  S.gunDecks = [...new Set((L.rooms || []).filter((r) => r.kind === "gundeck").map((r) => r.deck))].sort((a, b) => D[a].y - D[b].y);
  S.gunRows = S.gunDecks.map((id) => D[id].y - 78);
  S.guns = 0; // filled by the geometry
  return S;
}

// ---------------------------------------------------------------- the hull's profile
// A believable big sailing ship in profile, clockwise from the top of the transom: the rail
// along a sheer that rises to the ends and steps up over the castles (the quarterdeck and poop
// aft, the forecastle forward) with a smooth break; the raked stem sweeping down into the
// forefoot; the straight keel; the sternpost and the counter overhanging aft of it.
export function railY(S, x) {
  const mid = (S.stern + S.bow) / 2, half = S.len / 2;
  let y = -70 - 90 * ((x - mid) / half) ** 2; // the sheer
  for (const d of S.decksIn) {
    if (d.y >= 0) continue;
    const top = d.y - 70, x0 = d.hx0 ?? d.x0 ?? S.stern, x1 = d.hx1 ?? d.x1 ?? S.bow;
    // a castle at an end: full height over its deck, with a crisp break (a short round-off) at
    // its inner end, as a quarterdeck's or a forecastle's forward bulkhead stands
    const aft = x0 - S.stern < S.len * 0.25, fwd = S.bow - x1 < S.len * 0.25, E = 50;
    let k = 0;
    if (aft && x <= x1) k = 1;
    else if (aft && x < x1 + E) k = 1 - ease((x - x1) / E);
    if (fwd && x >= x0) k = Math.max(k, 1);
    else if (fwd && x > x0 - E) k = Math.max(k, ease((x - (x0 - E)) / E));
    if (k > 0) y = Math.min(y, lerp(y, top, k));
  }
  return y;
}
export function hullOutline(S) {
  const pts = [];
  const B = S.bottom, wl = S.wl, len = S.len;
  const topAt = (x) => railY(S, x);
  // the rail, stern to bow
  const sx = S.stern, bx = S.bow;
  for (let x = sx; x <= bx; x += 40) pts.push([x, topAt(x)]);
  pts.push([bx, topAt(bx)]);
  const cub = (p0, c1, c2, p1, n = 24) => { for (let i = 1; i <= n; i++) { const t = i / n, u = 1 - t; pts.push([u * u * u * p0[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t * t * t * p1[0], u * u * u * p0[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t * t * t * p1[1]]); } };
  // the stem: raked forward at the head, sweeping down and aft into the forefoot
  const foot = [bx - len * 0.19, B];
  cub([bx, topAt(bx)], [bx - len * 0.012, lerp(topAt(bx), wl, 0.6)], [bx - len * 0.06, B - (B - wl) * 0.1], foot);
  // the keel, forefoot to heel
  const heel = [sx + len * 0.075, B];
  pts.push(heel);
  // the sternpost up to the counter, the counter overhanging aft, the transom up to the rail
  const knuckle = [sx + len * 0.03, wl - (wl - topAt(sx)) * 0.12];
  pts.push([sx + len * 0.062, lerp(B, wl, 0.55)]);
  cub([sx + len * 0.062, lerp(B, wl, 0.55)], [sx + len * 0.055, wl + 40], [sx + len * 0.045, wl - 30], knuckle, 12);
  cub(knuckle, [sx + len * 0.012, lerp(knuckle[1], topAt(sx), 0.4)], [sx - len * 0.004, lerp(knuckle[1], topAt(sx), 0.8)], [sx, topAt(sx)], 12);
  return pts;
}
// the hull's inside span [x0, x1] at height y (the widest run of the polygon at that y)
export function hullSpanAt(S, y, pts = S.hull || hullOutline(S)) {
  const xs = [];
  for (let i = 0; i < pts.length; i++) {
    const [ax, ay] = pts[i], [bx, by] = pts[(i + 1) % pts.length];
    if ((ay <= y && by > y) || (by <= y && ay > y)) xs.push(ax + ((y - ay) / (by - ay)) * (bx - ax));
  }
  xs.sort((a, b) => a - b);
  return xs.length >= 2 ? [xs[0], xs[xs.length - 1]] : [0, 0];
}

// ---------------------------------------------------------------- the decks
// Everything a crewman needs to walk the ship, for one spec. Pure: the same spec gives the same
// geometry. G.rooms and G.walls carry what the drawing needs beyond the walking.
export function deckGeometry(S) {
  const L = S.layout;
  const decks = {}, obstacles = [], links = [], guns = [], stations = [], rooms = [], walls = [], props = [], errors = [];
  const G = { spec: S, decks, obstacles, links, guns, stations, rooms, walls, props, hull: S.hull, errors };
  const byY = S.decksIn;
  for (const d of byY) {
    const open = d.y <= 0;
    decks[d.id] = { id: d.id, kind: d.kind || (d.y < 0 ? "castle" : d.y === 0 ? "main" : "lower"), y: d.y, x0: d.x0, x1: d.x1, depth: DEPTH, rest: 60, topside: open, label: d.label || null };
  }
  const ob = (deck, kind, x0, x1, z0, z1, extra = {}) => { const o = { deck, kind, x0, x1, z0, z1, ...extra }; obstacles.push(o); return o; };
  const inDeck = (deck, x, pad = 0) => decks[deck] && x >= decks[deck].x0 + pad && x <= decks[deck].x1 - pad;
  // the rooms, and the deck above each (its ceiling), and whether it is open to the sky
  for (const r of L.rooms || []) {
    const d = decks[r.deck];
    if (!d) { errors.push(`room "${r.id}": no deck "${r.deck}"`); continue; }
    const x0 = Math.max(d.x0, r.x0 ?? d.x0), x1 = Math.min(d.x1, r.x1 ?? d.x1);
    const above = byY.filter((o) => o.y < d.y && o.x0 < x1 - 1 && o.x1 > x0 + 1).sort((a, b) => b.y - a.y)[0];
    rooms.push({ id: r.id, kind: r.kind, deck: r.deck, x0, x1, y: d.y, ceil: above ? above.y + BEAM : null, label: r.label || null, aft: r.aft || "door", fore: r.fore || "door", furnish: r.furnish !== false });
  }
  // the crow's nests: a small deck on each mast that has one
  for (const m of S.masts) {
    if (m.nest == null) continue;
    const id = "nest" + (m.i ? m.i : "");
    decks[id] = { id, kind: "nest", y: m.nest, x0: m.x - 210, x1: m.x + 210, depth: NEST_DEPTH, rest: 40, topside: true, mast: m.i };
    ob(id, "mast", m.x - 22, m.x + 22, 112, 148, { mast: m.i });
    rooms.push({ id, kind: "nest", deck: id, x0: m.x - 210, x1: m.x + 210, y: m.nest, ceil: null, furnish: true, aft: "open", fore: "open" });
  }
  // gun decks keep their resting lane clear of the near guns
  for (const r of rooms) if (r.kind === "gundeck") decks[r.deck].rest = 98;
  // bulkheads between rooms (and at a room's end inside a deck): a wall with a doorway, or solid
  {
    const ends = {};
    for (const r of rooms) {
      if (r.kind === "nest") continue;
      const d = decks[r.deck];
      for (const [x, how] of [[r.x0, r.aft], [r.x1, r.fore]]) {
        if (x <= d.x0 + 2 || x >= d.x1 - 2) continue; // the hull closes the deck's ends
        const k = r.deck + "@" + Math.round(x);
        const e = (ends[k] ||= { deck: r.deck, x: Math.round(x), how: "open", n: 0 });
        e.n++;
        // a wall wins over nothing, a door wins over a wall (the way through is kept)
        if (how === "door" || (how === "wall" && e.how !== "door")) e.how = how;
      }
    }
    for (const e of Object.values(ends)) {
      if (e.how === "open") continue;
      const d = decks[e.deck], above = byY.filter((o) => o.y < d.y && o.x0 < e.x && o.x1 > e.x).sort((a, b) => b.y - a.y)[0];
      const w = { deck: e.deck, x: e.x, y: d.y, top: above ? above.y + BEAM : d.y - 250, door: e.how === "door" };
      walls.push(w);
      const a = e.x - WALL / 2, b = e.x + WALL / 2;
      if (w.door) { ob(e.deck, "wall", a, b, 0, DOOR[0], { wall: true }); ob(e.deck, "wall", a, b, DOOR[1], F, { wall: true }); }
      else ob(e.deck, "wall", a, b, 0, F, { wall: true });
    }
  }
  // masts through every deck they stand in (the nest has its own)
  for (const m of S.masts) for (const d of Object.values(decks)) {
    if (d.kind === "nest" || d.y < m.base - 1) continue;
    if (m.x - 24 > d.x0 + 4 && m.x + 24 < d.x1 - 4) ob(d.id, "mast", m.x - 24, m.x + 24, C - 24, C + 24, { mast: m.i });
  }
  // stairs, ladders, and the shrouds up to the nests
  const flight = (id, up, dn, xt, s) => {
    const U = decks[up], D = decks[dn], run = Math.max(200, (D.y - U.y) * 0.7);
    const a = Math.min(xt, xt + s * run * 0.82), b = Math.max(xt, xt + s * run * 0.82);
    // (a flight from a castle's forward edge starts at the deck's end: it has no hatch)
    if (a >= U.x0 - 1 && b <= U.x1 + 1) ob(up, "hatch", a, b, F - STAIR_W, F, { link: id });
    ob(dn, "stairs", Math.min(xt, xt + s * run), Math.max(xt, xt + s * run), F - STAIR_W, F, { link: id });
    links.push(mkLink(id, "stairs", { deck: up, x: xt - s * 64, z: STAIR_Z }, { deck: dn, x: xt + s * (run + 64), z: STAIR_Z }, [[xt - s * 64, U.y], [xt, U.y], [xt + s * run, D.y], [xt + s * (run + 64), D.y]]));
  };
  const ladder = (id, up, dn, x, s) => {
    const U = decks[up], D = decks[dn];
    ob(up, "hatch", x - 52, x + 52, C - 42, C + 42, { link: id });
    ob(dn, "ladder", x - 20, x + 20, C - 22, C + 22, { link: id });
    links.push(mkLink(id, "ladder", { deck: up, x: x + s * 96, z: C }, { deck: dn, x: x + s * 66, z: C }, [[x + s * 96, U.y], [x + s * 14, U.y], [x + s * 14, D.y], [x + s * 66, D.y]]));
  };
  (L.links || []).forEach((l, i) => {
    const id = l.id || `${l.kind}-${l.from}-${l.to}-${i}`;
    if (!decks[l.from] || !decks[l.to]) return void errors.push(`link "${id}": no deck "${decks[l.from] ? l.to : l.from}"`);
    let up = l.from, dn = l.to;
    if (decks[up].y > decks[dn].y) [up, dn] = [dn, up];
    if (decks[up].y === decks[dn].y) return void errors.push(`link "${id}": "${l.from}" and "${l.to}" are at one height`);
    const s = l.dir === -1 ? -1 : 1;
    if (l.kind === "stairs") flight(id, up, dn, l.x, s);
    else ladder(id, up, dn, l.x, s);
  });
  for (const m of S.masts) {
    if (m.nest == null) continue;
    const nid = "nest" + (m.i ? m.i : ""), on = Object.values(decks).filter((d) => d.kind !== "nest" && d.y <= 0 && m.x > d.x0 && m.x < d.x1).sort((a, b) => a.y - b.y)[0];
    if (!on) { errors.push(`mast ${m.i}: no deck under its nest`); continue; }
    let made = false;
    for (const s of [1, -1]) {
      for (const off of [220, 300, 380]) {
        const e = { deck: on.id, x: m.x + s * off, z: C - 30 };
        if (!staticFree(G, on.id, e.x, e.z, 38)) continue;
        links.push(mkLink("shrouds" + (m.i ? m.i : ""), "shrouds", e, { deck: nid, x: m.x + s * 80, z: 40 }, [[e.x, on.y], [m.x + s * (off + 30), on.y - 80], [m.x + s * 90, m.nest + 70], [m.x + s * 80, m.nest]]));
        made = true;
        break;
      }
      if (made) break;
    }
    if (!made) errors.push(`mast ${m.i}: no room for the shrouds on the ${on.id}`);
  }
  // ---------------------------------------------------------------- furnishing
  const clearLinks = (deck, x0, x1, pad = 70) => !links.some((l) => [l.a, l.b].some((e) => e.deck === deck && e.x > x0 - pad && e.x < x1 + pad)) && !obstacles.some((o) => o.deck === deck && (o.kind === "hatch" || o.kind === "stairs" || o.kind === "ladder" || o.kind === "wall" || o.kind === "mast") && o.x0 < x1 + 30 && o.x1 > x0 - 30);
  const free = (deck, x0, x1, z0, z1) => !obstacles.some((o) => o.deck === deck && o.x0 < x1 + 12 && o.x1 > x0 - 12 && o.z0 < z1 + 12 && o.z1 > z0 - 12);
  const prop = (kind, deck, x, extra = {}) => {
    const [w, zr] = PROP_SIZE[kind];
    const p = { kind, deck, x, w, ...extra };
    props.push(p);
    if (zr) ob(deck, kind, x - w / 2, x + w / 2, extra.z0 ?? zr[0], extra.z1 ?? zr[1], { prop: props.length - 1 });
    return p;
  };
  const fits = (kind, deck, x, extra = {}) => {
    const [w, zr] = PROP_SIZE[kind];
    if (!inDeck(deck, x - w / 2, 4) || !inDeck(deck, x + w / 2, 4)) return false;
    if (!zr) return true;
    if (!free(deck, x - w / 2, x + w / 2, extra.z0 ?? zr[0], extra.z1 ?? zr[1])) return false;
    return !links.some((l) => [l.a, l.b].some((e) => e.deck === deck && Math.abs(e.x - x) < w / 2 + 70));
  };
  const st = (kind, deck, x, dir = 1, extra = {}) => {
    const D = decks[deck];
    if (!D || x < D.x0 + 40 || x > D.x1 - 40) return null;
    const s = { id: extra.id || `${kind}-${deck}-${Math.round(x)}`, kind, deck, x: Math.round(x), z: extra.z ?? D.rest, dir, room: extra.room || null };
    if (!staticFree(G, deck, s.x, s.z, 30)) return null;
    if (stations.some((o) => o.deck === deck && Math.abs(o.x - s.x) < 150)) return null;
    stations.push(s);
    return s;
  };
  // explicit props first (they are the author's), then each room's furniture where it fits
  for (const p of L.props || []) {
    if (!decks[p.deck]) { errors.push(`prop ${p.kind}: no deck "${p.deck}"`); continue; }
    if (!fits(p.kind, p.deck, p.x)) errors.push(`prop ${p.kind} at ${p.deck} ${p.x}: it does not fit there (a wall, a link or another prop is in the way)`);
    else prop(p.kind, p.deck, p.x, p.far ? { z0: F - 110, z1: F } : {});
  }
  const spread = (x0, x1, step, fn) => { const n = Math.max(1, Math.floor((x1 - x0) / step)); const pad = (x1 - x0 - (n - 1) * step) / 2; for (let i = 0; i < n; i++) fn(x0 + pad + i * step, i); };
  G.wheelX = null;
  for (const r of rooms) {
    if (!r.furnish) continue;
    const a = r.x0 + 90, b = r.x1 - 90, mid = (r.x0 + r.x1) / 2;
    switch (r.kind) {
      case "helm": {
        const w0 = lerp(r.x0, r.x1, 0.3);
        for (let d = 0; d < (r.x1 - r.x0) * 0.6 && G.wheelX == null; d += 20) for (const wx of d ? [w0 + d, w0 - d] : [w0]) if (G.wheelX == null && wx > r.x0 + 120 && wx < r.x1 - 120 && fits("wheel", r.deck, wx)) (prop("wheel", r.deck, wx), (G.wheelX = wx));
        prop("bell", r.deck, r.x1 - 40);
        break;
      }
      case "cabin": {
        const x = lerp(r.x0, r.x1, 0.42);
        if (fits("desk", r.deck, x)) prop("desk", r.deck, x);
        prop("shelf", r.deck, r.x0 + Math.min(360, (r.x1 - r.x0) * 0.4) + 150); // (after the stern windows)
        prop("lantern", r.deck, mid);
        break;
      }
      case "chart":
        if (fits("table", r.deck, mid)) prop("table", r.deck, mid);
        prop("lantern", r.deck, mid);
        break;
      case "waist": {
        const cx = lerp(r.x0, r.x1, 0.62);
        for (let d = 0; d < 800; d += 20) { const x = cx + (d % 40 ? -d : d); if (fits("capstan", r.deck, x)) { prop("capstan", r.deck, x); G.capX = x; break; } }
        spread(a + 60, b - 60, 520, (x) => { for (const dx of [0, 60, -60, 120, -120]) if (fits("workbench", r.deck, x + dx)) return void prop("workbench", r.deck, x + dx); });
        break;
      }
      case "workshop":
        spread(a + 40, b - 40, 480, (x) => { for (const dx of [0, 60, -60, 120, -120]) if (fits("workbench", r.deck, x + dx)) return void prop("workbench", r.deck, x + dx); });
        prop("lantern", r.deck, mid);
        break;
      case "gundeck": {
        let i = guns.filter((g) => g.deck === r.deck).length;
        const row = S.gunDecks.indexOf(r.deck);
        for (let x = a + 30; x <= b - 30; x += 10) {
          if (!fits("gun", r.deck, x) || !fits("gun", r.deck, x, { z0: F - 60, z1: F })) continue;
          if (guns.some((g) => g.deck === r.deck && Math.abs(g.x - x) < 300)) continue;
          if (!clearLinks(r.deck, x - 40, x + 40, 50)) continue;
          ob(r.deck, "gun", x - 40, x + 40, 0, 60, { gun: i });
          ob(r.deck, "gun", x - 40, x + 40, F - 60, F, { gun: i, far: true });
          guns.push({ deck: r.deck, row, i: i++, x, y: decks[r.deck].y - 78 });
        }
        for (let x = a + 200; x < b; x += 900) prop("lantern", r.deck, x);
        break;
      }
      case "quarters":
        spread(a, b, 240, (x, i) => { prop("hammock", r.deck, x); if (i % 2 === 0 && fits("chest", r.deck, x)) prop("chest", r.deck, x); });
        prop("lantern", r.deck, mid);
        break;
      case "galley":
        if (fits("stove", r.deck, a + 70)) prop("stove", r.deck, a + 70);
        if (fits("table", r.deck, mid + 60)) prop("table", r.deck, mid + 60);
        prop("lantern", r.deck, mid);
        break;
      case "cargo":
        spread(a, b, 190, (x, i) => { const k = i % 3 === 1 ? "crate" : "cask"; if (fits(k, r.deck, x)) prop(k, r.deck, x); });
        break;
    }
  }
  if (G.wheelX == null) G.wheelX = lerp(S.qd[0], S.qd[1], 0.3);
  if (G.capX == null) G.capX = (S.main[0] + S.main[1]) / 2;
  // ---------------------------------------------------------------- stations
  // explicit stations first, then each room's
  for (const s of L.stations || []) {
    if (!decks[s.deck]) { errors.push(`station ${s.kind}: no deck "${s.deck}"`); continue; }
    if (!st(s.kind, s.deck, s.x, s.dir ?? 1, { id: s.id })) errors.push(`station ${s.id || s.kind} at ${s.deck} ${s.x}: not a clear spot (off the deck, in something, or within 150 of another station)`);
  }
  const has = (k) => rooms.some((r) => r.kind === k);
  for (const r of rooms) {
    if (!r.furnish) continue;
    const a = r.x0 + 80, b = r.x1 - 80, room = r.id;
    const along = (kind, step, dir = 1, first = a) => { for (let x = first, i = 0; x <= b; x += step, i++) st(kind, r.deck, x, i % 2 ? -dir : dir, { room }); };
    switch (r.kind) {
      case "helm":
        st("helm", r.deck, G.wheelX - 20, 1, { id: "helm", room });
        if (!has("chart")) st("mate", r.deck, lerp(r.x0, r.x1, 0.72), 1, { id: "mate", room });
        break;
      case "cabin": {
        const desk = props.find((p) => p.kind === "desk" && p.deck === r.deck && p.x > r.x0 && p.x < r.x1);
        // (the captain stands at the desk's end, facing it: the card on it shows)
        st("cabin", r.deck, (desk ? desk.x - desk.w / 2 - 70 : (r.x0 + r.x1) / 2), 1, { id: "cabin", room });
        along("visit", 200, -1, (desk ? desk.x : a) + 260);
        break;
      }
      case "chart": {
        const t = props.find((p) => p.kind === "table" && p.deck === r.deck && p.x > r.x0 && p.x < r.x1);
        st("chart", r.deck, t ? t.x - 50 : (r.x0 + r.x1) / 2, 1, { id: "mate", room });
        along("visit", 200, -1, (t ? t.x : a) + 220);
        break;
      }
      case "waist":
      case "workshop":
        for (const p of props) if (p.kind === "workbench" && p.deck === r.deck && p.x > r.x0 && p.x < r.x1) st("work", r.deck, p.x, 1, { room });
        for (const m of S.masts) if (m.x > r.x0 && m.x < r.x1 && decks[r.deck].y <= 0) for (const s of [-1, 1]) st("rig", r.deck, m.x + s * 110, -s, { room });
        if (r.kind === "waist") st("rig", r.deck, G.capX - 120, 1, { room });
        along("work", 220, 1);
        break;
      case "forecastle":
        st("lookout", r.deck, r.x1 - 60, 1, { room });
        along("lookout", 220, 1);
        for (const m of S.masts) if (m.x > r.x0 && m.x < r.x1) for (const s of [-1, 1]) st("rig", r.deck, m.x + s * 110, -s, { room });
        break;
      case "gundeck":
        for (const g of guns) if (g.deck === r.deck && g.x > r.x0 && g.x < r.x1) st("gate", r.deck, g.x, g.i % 2 ? -1 : 1, { room });
        along("gate", 200, 1);
        break;
      case "quarters":
      case "galley":
        along("rest", 200, 1);
        break;
      case "cargo":
        along("cargo", 220, 1);
        break;
      case "nest":
        st("review", r.deck, r.x0 + 110, 1, { room });
        st("review", r.deck, r.x1 - 110, -1, { room });
        break;
    }
  }
  if (!stations.some((s) => s.kind === "helm")) errors.push("no helm: a layout needs a room of kind \"helm\" with a wheel (or a helm station)");
  G.battle = battlePosts(G, L, errors);
  S.guns = Math.max(0, ...S.gunDecks.map((d) => guns.filter((g) => g.deck === d).length));
  index(G);
  return G;
}
// the obstacles per deck, for the walking's many look-ups (the ships are long)
export function index(G) {
  G.byDeck = {};
  for (const o of G.obstacles) (G.byDeck[o.deck] ||= []).push(o);
  return G;
}
const obsOn = (G, deckId) => (G.byDeck ? G.byDeck[deckId] || [] : G.obstacles.filter((o) => o.deck === deckId));
// the battle stations: explicit ones from the layout, else made from its rooms, the bow first
function battlePosts(G, L, errors) {
  const S = G.spec, out = [];
  const add = (post, deck, x, dir = 1, extra = {}) => {
    const D = G.decks[deck];
    if (!D || x < D.x0 + 40 || x > D.x1 - 40) return false;
    const z = extra.z ?? D.rest;
    if (!staticFree(G, deck, x, z, 30)) return false;
    if (out.some((o) => o.deck === deck && Math.abs(o.x - x) < 170)) return false;
    out.push({ id: `battle-${post}-${deck}-${Math.round(x)}`, kind: "battle", post, deck, x: Math.round(x), z, dir, ...(extra.gun != null ? { gun: extra.gun } : {}) });
    return true;
  };
  // the nearest clear spot to a want, within reach, on a deck
  const near = (post, deck, x, dir, reach = 400) => { for (let d = 0; d <= reach; d += 20) for (const v of d ? [x - d, x + d] : [x]) if (add(post, deck, v, dir)) return true; return false; };
  if (L.battle) {
    const gunNear = (deck, x) => { let best = null; for (const g of G.guns) if (g.deck === deck && Math.abs(g.x - x) < 200 && (!best || Math.abs(g.x - x) < Math.abs(best.x - x))) best = g; return best ? best.row * 64 + best.i : null; };
    for (const b of L.battle) if (!add(b.post, b.deck, b.x, b.dir ?? 1, b.post === "gun" ? { gun: gunNear(b.deck, b.x) } : {})) errors.push(`battle station ${b.post} at ${b.deck} ${b.x}: not a clear spot (off the deck, in something, or within 170 of another)`);
    return out;
  }
  const fc = G.rooms.find((r) => r.kind === "forecastle");
  if (fc) {
    near("captain", fc.deck, fc.x1 - 170, 1);
    near("mate", fc.deck, fc.x1 - 400, 1);
    for (let x = fc.x1 - 620; x > fc.x0 + 60; x -= 200) near("lookout", fc.deck, x, 1, 60);
  }
  for (const s of G.stations) if (s.kind === "review") add("lookout", s.deck, s.x, s.dir);
  // the guns, the bow's half of every gun deck, forward first
  const guns = G.guns.slice().sort((a, b) => b.x - a.x);
  const mid = (S.stern + S.bow) / 2;
  // (a gunner stands at his gun's breech, the bow side of it: he faces the bow as the gun is trained)
  for (const g of guns) if (g.x > mid - S.len * 0.1) add("gun", g.deck, g.x - 70, 1, { gun: g.row * 64 + g.i });
  // the rigging and the capstan forward of amidships
  for (const s of G.stations) if (s.kind === "rig" && s.x > mid - S.len * 0.2) add("rig", s.deck, s.x, s.dir);
  // shot and powder carried up from the hold, forward of amidships
  const hold = G.rooms.find((r) => r.kind === "cargo");
  if (hold) for (let x = hold.x1 - 250; x > mid - S.len * 0.2; x -= 230) near("ammo", hold.deck, x, -1, 60);
  // and more guns aft if the crew is bigger than the bow can hold
  for (const g of guns) if (g.x <= mid - S.len * 0.1) add("gun", g.deck, g.x - 70, 1, { gun: g.row * 64 + g.i });
  return out;
}
function mkLink(id, kind, a, b, path) { return { id, kind, a, b, path, len: pathLen(path) }; }

// ---------------------------------------------------------------- the layout's gate
// Every deck, room and station can be reached from the helm, and nothing a crewman stands on is
// inside something. The loader refuses a layout that fails this (docs/modding.md "Validate").
export function checkLayout(S, G = deckGeometry(S)) {
  const errors = [...G.errors];
  const helm = G.stations.find((s) => s.kind === "helm");
  if (!helm) return errors.length ? errors : ["no helm station"];
  const nav = buildNav(G);
  const reach = (p, what) => { if (!findPath(nav, helm, p, 30)) errors.push(`${what} cannot be reached from the helm`); };
  for (const s of G.stations) reach(s, `station ${s.id} (${s.deck} ${s.x})`);
  for (const r of G.rooms) {
    const segs = fileSegments(G, r.deck, 30).filter(([a, b]) => b > r.x0 && a < r.x1);
    if (!segs.length) { errors.push(`room ${r.id} has nowhere to stand`); continue; }
    const [a, b] = segs[0];
    reach({ deck: r.deck, x: clamp((Math.max(a, r.x0) + Math.min(b, r.x1)) / 2, a, b), z: G.decks[r.deck].rest }, `room ${r.id} (${r.deck})`);
  }
  for (const l of G.links) for (const e of [l.a, l.b]) if (!staticFree(G, e.deck, e.x, e.z, 36)) errors.push(`link ${l.id}: its end on the ${e.deck} at ${Math.round(e.x)} is inside something`);
  // a hatch, a flight or a ladder runs into nothing solid (a mast, a bulkhead, another way down)
  const solid = ["mast", "wall", "hatch", "stairs", "ladder"];
  for (const o of G.obstacles) {
    if (!o.link) continue;
    for (const q of G.byDeck?.[o.deck] || []) {
      if (q === o || q.link === o.link || !solid.includes(q.kind)) continue;
      const ox = Math.min(o.x1, q.x1) - Math.max(o.x0, q.x0), oz = Math.min(o.z1, q.z1) - Math.max(o.z0, q.z0);
      if (ox > 16 && oz > 0) errors.push(`link ${o.link}: its ${o.kind} on the ${o.deck} (${Math.round(o.x0)} to ${Math.round(o.x1)}) runs into a ${q.kind === "wall" ? "bulkhead" : q.kind}${q.link ? " of " + q.link : ""} at ${Math.round(q.x0)}`);
    }
  }
  for (const b of G.battle || []) reach(b, `battle station ${b.post} (${b.deck} ${b.x})`);
  if ((G.battle || []).length < (S.cap || 0)) errors.push(`${(G.battle || []).length} battle stations for up to ${S.cap} hands: one each is needed`);
  for (const post of ["captain", "mate"]) if (!(G.battle || []).some((b) => b.post === post)) errors.push(`no "${post}" battle station (a forecastle room, or one in "battle")`);
  const kinds = new Set(G.stations.map((s) => s.kind));
  for (const k of ["work", "rest"]) if (!kinds.has(k)) errors.push(`no "${k}" station: add a ${k === "work" ? "waist or workshop" : "quarters or galley"} room`);
  return errors;
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
  for (const o of obsOn(G, deckId)) {
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
  for (const o of obsOn(G, deckId)) if (x > o.x0 - r && x < o.x1 + r && circleHitsRect(x, z, r, o)) return false;
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
  const lo = Math.min(x1, x2) - R, hi = Math.max(x1, x2) + R;
  for (const o of obsOn(G, deckId)) if (o.x1 > lo && o.x0 < hi && segHitsRect(x1, z1, x2, z2, o, R - 0.5)) return false;
  return true;
}

// ---------------------------------------------------------------- the nav graph and A*
// A column graph per deck: every 24 units along x, a node at each run of free z (for a walker
// of radius R_NAV); runs in neighbouring columns that overlap are joined. Link ends join the
// columns they see, and each link joins its two ends. Routes are smoothed by line of sight.
const COL = 16, R_WALK = 36;
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
// Files: each deck (and each nest) is one row. The decks are a room's height apart, so no
// crewman's drawing reaches another deck's. Within a file each crewman keeps his drawn width
// (ext, at full size) and a GAP from his neighbours, and his footprint stays clear of obstacles
// and link ends on the rest lane. When a file cannot hold its crew at full size, everyone is
// drawn smaller (fit), as before.
export const GAP = 16;
export function restFile(G, deckId) { return deckId; }
// the allowed centre intervals of a file for a footprint of radius f
export function fileSegments(G, file, f) {
  const decks = [G.decks[file]];
  const segs = [];
  for (const d of decks) {
    if (!d) continue;
    let s = [[d.x0 + f, d.x1 - f]];
    const cut = (a, b) => { const out = []; for (const [p, q] of s) { if (b <= p || a >= q) out.push([p, q]); else { if (a > p) out.push([p, a]); if (b < q) out.push([b, q]); } } s = out; };
    for (const o of obsOn(G, d.id)) if (o.z0 < d.rest + f && o.z1 > d.rest - f) {
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
// (priority, then id), no randomness. The captain passes (the captain's "橫移碰到船員永遠過不
// 去"): an agent with `ghost` set (the captain) is never an obstacle to anyone and nobody is an
// obstacle to him. Walls, hatches, guns and the hull still stop him, and doors and links still
// route him; the crew are only a preference. In the 2.5D he steps into the lane behind (or in
// front of) whoever is in his way and is drawn in that depth, so he walks past the crew instead
// of through them (the drawing sorts by depth). Why not make the crew step aside: the crew stand
// at their stations doing their work (a gunner at his gun, a hand at his bench); moving them
// would break the picture of the workflow, cascade down a crowded gun deck and could still box
// him in, where a depth pass is instant, never fails and reads naturally in a 2.5D view.
// The rules for everyone else:
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
  add(id, { deck, x, z, r = 30, pri = 50, speed = WALK_SPEED, dir = 1 }) {
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
    if (self?.ghost) return true; // the captain: only the ship itself stops him
    for (const b of this.agents.values()) {
      if (b === self || (placedOnly && !b.placed) || b.ghost) continue;
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
  movable(b) { return !b.ghost && !b.link && (b.goal || b.manual || b.yieldFrom); }
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
    const l = a.link, speed = l.L.kind === "shrouds" ? Math.max(a.speed * 0.5, l.L.len / SHROUD_SECS) : a.speed * (l.L.kind === "stairs" ? 0.85 : 0.55);
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
  // the captain at the helm of his legs: vx in -1..1 walks the deck (run, 0..1 or true: up to
  // RUN x as fast), stepping round whoever and whatever is in the way
  drive(a, h) {
    const m = a.manual;
    if (!m.vx) return;
    const ux = Math.sign(m.vx), d = a.speed * runK(m) * Math.min(1, Math.abs(m.vx)) * h;
    a.dir = ux;
    // steer across the deck toward the open lane ahead (round masts, hatches, stairs, guns, and
    // through a doorway); among the open lanes, one the crew ahead leave clear (he passes behind
    // or in front of them); if none is clear he keeps his lane and passes them in depth
    const D = this.G.decks[a.deck];
    // the lanes open all the way along the next stride and a half (a doorway in a thin bulkhead
    // is a lane only where it is; one sample beyond it would steer him into its jamb)
    let ahead = null;
    for (let dx = 10; dx <= 80; dx += 14) {
      const f = freeZ(this.G, a.deck, clamp(a.x + ux * dx, D.x0 + R_NAV, D.x1 - R_NAV), false);
      if (!f.length) continue;
      ahead = ahead ? ahead.flatMap(([p, q]) => f.filter(([u, v]) => u < q && v > p).map(([u, v]) => [Math.max(p, u), Math.min(q, v)])).filter(([p, q]) => q - p >= 4) : f;
    }
    if (!ahead?.length) ahead = freeZ(this.G, a.deck, clamp(a.x + ux * 70, D.x0 + R_NAV, D.x1 - R_NAV), false);
    let lanes = ahead;
    if (a.ghost) {
      const busy = [];
      for (const b of this.agents.values()) {
        if (b === a || b.link || b.deck !== a.deck) continue;
        const dx = (b.x - a.x) * ux;
        if (dx < -a.r || dx > 240) continue;
        busy.push([b.z - b.r - a.r - 8, b.z + b.r + a.r + 8]);
      }
      if (busy.length) {
        const cut = [];
        for (const [p, q] of ahead) {
          let segs = [[p, q]];
          for (const [u, v] of busy) segs = segs.flatMap(([s, t]) => (v <= s || u >= t ? [[s, t]] : [...(u > s ? [[s, u]] : []), ...(v < t ? [[v, t]] : [])]));
          cut.push(...segs.filter(([s, t]) => t - s >= 8));
        }
        if (cut.length) lanes = cut;
      }
    }
    let tz = a.z;
    if (lanes.length && !lanes.some(([p, q]) => a.z >= p && a.z <= q)) {
      let best = Infinity;
      for (const [p, q] of lanes) { const z = clamp(a.z, p + 4, q - 4), dd = Math.abs(z - a.z); if (dd < best) (best = dd), (tz = z); }
    }
    // (a lane that only the crew close is taken at a stroll across; a wall's doorway at once)
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
      if (a.ghost || b.ghost) continue; // the captain passes in depth
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
