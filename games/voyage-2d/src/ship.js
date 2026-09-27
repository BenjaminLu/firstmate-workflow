// The pirate ship, painted in vector and sized to the crew: four classes (sloop, brig,
// frigate, ship of the line) for up to 7, 12, 18 and 24 agents. A class is a spec (deck
// spans, masts and yards, gun rows, hull depth); the ship draws any spec, and while it
// changes class it draws the spec interpolated between the two (the hull stretches, new
// masts and guns grow in), live, then caches the result. Ship space: x toward the bow,
// y down, the main deck at y = 0; the waterline sits at y = SEA_Y.
import { SEA_Y } from "./env.js";
import { SHIP_CLASSES, classFor, deckGeometry, hullOutline, levelIds, linkPoint, Z_SCREEN, DEPTH } from "../v3src/sim/deckplan.js";

const WOOD = "#6b3f22", WOOD_D = "#3c2212", WOOD_L = "#8e5a32", GOLD = "#f0b53a", GOLD_D = "#a8741c", DARK = "#1c1016";

// the hulls and their walkable decks live in the shared, renderer-free model (v3src/sim/deckplan.js)
export const CLASSES = SHIP_CLASSES;
export { classFor };
const lerp = (a, b, k) => a + (b - a) * k;
const ease = (k) => (k <= 0 ? 0 : k >= 1 ? 1 : k * k * (3 - 2 * k));

// the spec between two classes at k (0..1): numbers lerp, masts and yards grow in or out
export function blendSpec(A, B, k) {
  if (!A || A === B || k >= 1) return { ...B, grow: null };
  const e = ease(k);
  const L = (key) => lerp(A[key], B[key], e);
  const span = (key) => A[key].map((v, i) => lerp(v, B[key][i], e));
  const n = Math.max(A.masts.length, B.masts.length);
  // map masts by rank from the stern; a mast only in B grows in over the second half
  const masts = [];
  for (let i = 0; i < n; i++) {
    const a = A.masts[Math.min(i, A.masts.length - 1)], b = B.masts[Math.min(i, B.masts.length - 1)];
    const inA = i < A.masts.length, inB = i < B.masts.length;
    const g = inA && inB ? 1 : inB ? ease((k - 0.45) / 0.45) : 1 - ease(k / 0.5);
    if (g <= 0.01) continue;
    const yn = Math.max(a.yards.length, b.yards.length);
    const yards = [];
    for (let j = 0; j < yn; j++) {
      const ya = a.yards[Math.min(j, a.yards.length - 1)], yb = b.yards[Math.min(j, b.yards.length - 1)];
      const inY = j < a.yards.length && j < b.yards.length ? 1 : j < b.yards.length ? ease((k - 0.55) / 0.4) : 1 - ease(k / 0.5);
      if (inY > 0.02) yards.push([lerp(ya[0], yb[0], e), lerp(ya[1], yb[1], e) * inY]);
    }
    masts.push({ x: lerp(a.x, b.x, e), top: lerp(0, lerp(a.top, b.top, e), g), yards: yards.map(([y, h]) => [lerp(0, y, g), h * g]), nest: b.nest ? lerp(a.nest || b.nest, b.nest, e) : a.nest && k < 0.5 ? a.nest : null, g });
  }
  const levels = B.levels.map((y, i) => lerp(A.levels[Math.min(i, A.levels.length - 1)], y, e));
  return {
    ...B, stern: L("stern"), bow: L("bow"), bottom: L("bottom"), ride: L("ride"), qd: span("qd"), main: span("main"), fore: span("fore"),
    masts, levels, gunRows: levels.slice(0, -1).map((y) => y - 78), guns: Math.round(lerp(A.guns, B.guns, ease((k - 0.3) / 0.6))), grow: k, from: A,
  };
}

// geometry helpers from a spec
export const gunXs = (S) => Array.from({ length: S.guns }, (_, i) => lerp(S.qd[0] + 140, S.main[1] - 60, S.guns === 1 ? 0.5 : i / (S.guns - 1)));
// the walkable geometry of each class, built once (the shared model; placing everything takes
// a moment on the bigger ships, so it is cached)
const GEO = new Map();
export function geometryOf(cls) {
  if (!GEO.has(cls.id)) GEO.set(cls.id, deckGeometry(cls));
  return GEO.get(cls.id);
}
// the height of a deck's floor in a spec (a blend while the ship changes class)
export function levelY(S, id, G = null) {
  if (id === "qd") return S.qd[2];
  if (id === "fore") return S.fore[2];
  if (id === "main") return 0;
  if (id === "nest") { const m = S.masts[Math.min(S.masts.length - 1, S.masts.length === 1 ? 0 : 1)]; return m?.nest ?? G?.decks.nest?.y ?? -900; }
  const i = levelIds(S).indexOf(id);
  return i >= 0 ? S.levels[i] : S.levels[S.levels.length - 1];
}
// target geometry drawn on a blended hull: x stretches with the hull, floors follow their levels
function mapper(S, G) {
  const T = G.spec;
  if (T === S) return { x: (x) => x, y: (y) => y, k: 1 };
  const kx = (S.bow - S.stern) / (T.bow - T.stern);
  const ids = levelIds(T);
  const ys = T.levels.map((y, i) => [y, levelY(S, ids[i])]);
  return {
    x: (x) => S.stern + (x - T.stern) * kx,
    y: (y) => {
      if (y <= 0) return y;
      let prev = [0, 0];
      for (const [a, b] of ys) { if (y <= a) return lerp(prev[1], b, (y - prev[0]) / (a - prev[0])); prev = [a, b]; }
      return prev[1] + (y - prev[0]) * (S.bottom - prev[1]) / Math.max(1, T.bottom - prev[0]);
    },
    k: kx,
  };
}
export const sectionsOf = (S) => [0.12, 0.37, 0.62, 0.87].map((f) => lerp(S.main[0], S.main[1], f));
export function deckYOf(S, x) {
  if (x < S.qd[1]) return S.qd[2];
  if (x >= S.fore[0]) return S.fore[2];
  return 0;
}

// ---------------------------------------------------------------- the rig's proportions
// The movement pass made every hull deeper (the cutaway, the hold, the gun decks) and left the
// masts, yards and sails at their old sizes, so the rig read undersized. The shared model
// (deckplan.js) keeps the rig's numbers as they were; the drawing scales the rig about the deck
// by RIG[class] so the sails carry the same share of the ship's side as before the movement
// pass: sail area / hull side area equal to the pre-movement ship's. The pre-movement hull is
// the same outline with the keel at RIG_OLD_BOTTOM (measured off the pre-movement shots). The
// crow's nest stays where the walkable model puts it: at the lower masthead, over the course yard
// and under the topsail yard of this drawn rig (tests/rig.test.mjs), drawn over the sails so the
// lookout's platform reads on the mast.
export const RIG_OLD_BOTTOM = 290;
const RIG_SAIL_CAP = 330, RIG_LOW = 260; // a sail's deepest drop; the lowest sail's foot above the deck
const polyArea = (P) => { let a = 0; for (let i = 0; i < P.length; i++) { const [x0, y0] = P[i], [x1, y1] = P[(i + 1) % P.length]; a += x0 * y1 - x1 * y0; } return Math.abs(a) / 2; };
export const hullArea = (S) => polyArea(hullOutline(S));
// the rig at scale f about the deck: masts, yards and their sails, as drawn
function scaleRig(S, f) {
  return S.masts.map((m) => {
    const base = deckYOf(S, m.x), up = (y) => base + (y - base) * f;
    return { ...m, top: up(m.top), yards: m.yards.map(([y, h]) => [up(y), h * f]), f };
  });
}
// the sails' drawn shapes as boxes: [x, yTop, half, drop] per yard
export function sailBoxes(S, masts, f) {
  const out = [];
  for (const m of masts) {
    const base = deckYOf(S, m.x);
    m.yards.forEach(([y, half], yi) => {
      if (half < 4) return;
      const next = m.yards[yi + 1]?.[0] ?? base - RIG_LOW;
      out.push([m.x, y, half, Math.max(20, Math.min(next - y - 40, RIG_SAIL_CAP * f))]);
    });
  }
  return out;
}
export const sailArea = (S, masts, f) => sailBoxes(S, masts, f).reduce((a, [, , half, h]) => a + 2 * half * h, 0);
// the scale per class that puts the sail share back where it was (solved once, by bisection)
export const RIG = {};
for (const S of SHIP_CLASSES) {
  const want = sailArea(S, S.masts, 1) / hullArea({ ...S, bottom: RIG_OLD_BOTTOM }), hull = hullArea(S);
  let lo = 1, hi = 3;
  for (let i = 0; i < 40; i++) { const f = (lo + hi) / 2; if (sailArea(S, scaleRig(S, f), f) / hull < want) lo = f; else hi = f; }
  RIG[S.id] = +((lo + hi) / 2).toFixed(3);
}
// the scale of a spec (a blend while the ship changes class)
export function rigScale(S) {
  const f = RIG[S.id] ?? 1;
  return S.from && S.grow != null ? lerp(rigScale(S.from), f, ease(S.grow)) : f;
}
const RIGS = new WeakMap();
export function rigOf(S) {
  let r = RIGS.get(S);
  if (!r) { const f = rigScale(S); r = { f, masts: scaleRig(S, f) }; RIGS.set(S, r); }
  return r;
}
export const rigTop = (S) => Math.min(...rigOf(S).masts.map((m) => m.top));

function hullPath(ctx, S) {
  const pts = hullOutline(S);
  ctx.beginPath();
  ctx.moveTo(pts[0][0], pts[0][1]);
  for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0], pts[i][1]);
  ctx.closePath();
}
// the cutaway window through the near side of the hull (rounded, like a cut-open model)
function cutPath(ctx, c, ccw = false) {
  const r = 46, { x0, x1, y0, y1 } = c;
  if (!ccw) {
    ctx.moveTo(x0 + r, y0);
    ctx.lineTo(x1 - r, y0); ctx.quadraticCurveTo(x1, y0, x1, y0 + r);
    ctx.lineTo(x1, y1 - r); ctx.quadraticCurveTo(x1, y1, x1 - r, y1);
    ctx.lineTo(x0 + r, y1); ctx.quadraticCurveTo(x0, y1, x0, y1 - r);
    ctx.lineTo(x0, y0 + r); ctx.quadraticCurveTo(x0, y0, x0 + r, y0);
  } else {
    ctx.moveTo(x0 + r, y0);
    ctx.quadraticCurveTo(x0, y0, x0, y0 + r); ctx.lineTo(x0, y1 - r);
    ctx.quadraticCurveTo(x0, y1, x0 + r, y1); ctx.lineTo(x1 - r, y1);
    ctx.quadraticCurveTo(x1, y1, x1, y1 - r); ctx.lineTo(x1, y0 + r);
    ctx.quadraticCurveTo(x1, y0, x1 - r, y0); ctx.lineTo(x0 + r, y0);
  }
  ctx.closePath();
}
function cutOf(S, G) {
  const M = mapper(S, G), c = G.cut;
  return { x0: M.x(c.x0), x1: M.x(c.x1), y0: c.y0, y1: M.y(c.y1) };
}

// the planks of a deck seen from a little above: its far half, a strip from y - 36 to y
function planks(ctx, a, b, y) {
  const g = ctx.createLinearGradient(0, y - 36, 0, y);
  g.addColorStop(0, "#a9713f");
  g.addColorStop(1, "#c98d52");
  ctx.fillStyle = g;
  ctx.fillRect(a, y - 36, b - a, 38);
  ctx.strokeStyle = "rgba(60,30,10,.45)";
  ctx.lineWidth = 2;
  for (let k = 1; k < 4; k++) (ctx.beginPath(), ctx.moveTo(a, y - 36 + k * 9), ctx.lineTo(b, y - 36 + k * 9), ctx.stroke());
}
const lift = (z) => z * Z_SCREEN;
// a flight of stairs along a link's path (top landing, flight, bottom landing), on the far side
function stairs(ctx, pts, M, z) {
  const [p1, p2] = [pts[1], pts[2]].map(([x, y]) => [M.x(x), M.y(y) - lift(z)]);
  const len = Math.hypot(p2[0] - p1[0], p2[1] - p1[1]), n = Math.max(3, Math.round(len / 34));
  ctx.lineCap = "round";
  ctx.strokeStyle = "#3a2010";
  ctx.lineWidth = 14;
  ctx.beginPath(); ctx.moveTo(...p1); ctx.lineTo(...p2); ctx.stroke();
  for (let i = 0; i < n; i++) {
    const k = (i + 0.5) / n, x = lerp(p1[0], p2[0], k), y = lerp(p1[1], p2[1], k);
    ctx.fillStyle = "#b07a44";
    ctx.fillRect(x - 22, y - 5, 44, 9);
    ctx.fillStyle = "rgba(40,20,8,.6)";
    ctx.fillRect(x - 22, y + 4, 44, 3);
  }
  // the hand rail and its posts
  ctx.strokeStyle = GOLD_D;
  ctx.lineWidth = 5;
  ctx.beginPath(); ctx.moveTo(p1[0], p1[1] - 70); ctx.lineTo(p2[0], p2[1] - 70); ctx.stroke();
  ctx.lineWidth = 3;
  for (let i = 0; i <= 3; i++) { const k = i / 3, x = lerp(p1[0], p2[0], k), y = lerp(p1[1], p2[1], k); ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(x, y - 70); ctx.stroke(); }
  ctx.lineCap = "butt";
}
// a ladder: two rails and the rungs, through a hatch in the floor above
function ladder(ctx, pts, M, z) {
  const x = M.x(pts[1][0]), y0 = M.y(pts[1][1]) - lift(z) - 30, y1 = M.y(pts[2][1]) - lift(z);
  ctx.strokeStyle = "#7a4a22";
  ctx.lineWidth = 8;
  ctx.beginPath(); ctx.moveTo(x - 20, y0); ctx.lineTo(x - 20, y1); ctx.moveTo(x + 20, y0); ctx.lineTo(x + 20, y1); ctx.stroke();
  ctx.strokeStyle = "#b07a44";
  ctx.lineWidth = 6;
  for (let y = y1 - 20; y > y0 + 6; y -= 34) (ctx.beginPath(), ctx.moveTo(x - 20, y), ctx.lineTo(x + 20, y), ctx.stroke());
}
// a hatch in a deck: a dark opening across the planks, with its gold-edged coaming
function hatch(ctx, x0, x1, y) {
  ctx.fillStyle = "#1a0d06";
  ctx.fillRect(x0, y - 30, x1 - x0, 22);
  ctx.strokeStyle = GOLD_D;
  ctx.lineWidth = 4;
  ctx.strokeRect(x0, y - 30, x1 - x0, 22);
}
// the inside of the hull, seen through the cutaway: the far planking and its ribs, the gun
// decks and the hold, the far guns at their ports, the stairs and ladders, masts, cargo, lamps
function interior(ctx, S, G, M) {
  const c = cutOf(S, G), ids = levelIds(S);
  ctx.save();
  hullPath(ctx, S);
  ctx.clip();
  ctx.beginPath();
  cutPath(ctx, c);
  ctx.clip();
  const g = ctx.createLinearGradient(0, c.y0, 0, c.y1);
  g.addColorStop(0, "#4e2a14");
  g.addColorStop(1, "#1f1008");
  ctx.fillStyle = g;
  ctx.fillRect(c.x0 - 10, c.y0 - 10, c.x1 - c.x0 + 20, c.y1 - c.y0 + 40);
  ctx.strokeStyle = "rgba(12,5,2,.5)";
  ctx.lineWidth = 3;
  for (let y = c.y0 + 18; y < c.y1 + 20; y += 26) (ctx.beginPath(), ctx.moveTo(c.x0, y), ctx.lineTo(c.x1, y), ctx.stroke());
  ctx.fillStyle = "#2a150a";
  for (let x = c.x0 + 60; x < c.x1; x += 124) ctx.fillRect(x - 9, c.y0, 18, c.y1 - c.y0 + 30);
  // far gunports: daylight through the far side, a cannon's breech run out at each
  for (const gn of G.guns) {
    const x = M.x(gn.x), y = levelY(S, gn.deck) - 36;
    ctx.fillStyle = "#140a06";
    ctx.fillRect(x - 32, y - 104, 64, 58);
    const sky = ctx.createLinearGradient(0, y - 100, 0, y - 50);
    sky.addColorStop(0, "#9cc4ef");
    sky.addColorStop(1, "#3f7fc6");
    ctx.fillStyle = sky;
    ctx.fillRect(x - 26, y - 98, 52, 46);
    ctx.fillStyle = "#2c2c34";
    ctx.fillRect(x - 12, y - 84, 24, 40);
    ctx.fillStyle = "#4a2a14";
    ctx.fillRect(x - 36, y - 40, 72, 30);
    ctx.fillStyle = "#1c1c22";
    ctx.beginPath(); ctx.arc(x, y - 46, 17, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = "#101014";
    for (const dx of [-24, 24]) (ctx.beginPath(), ctx.arc(x + dx, y - 8, 9, 0, Math.PI * 2), ctx.fill());
  }
  // the masts run down through every deck to the keel
  for (const m of S.masts) {
    const w = 22 * (m.g ?? 1), x = m.x;
    const mg = ctx.createLinearGradient(x - w, 0, x + w, 0);
    mg.addColorStop(0, "#4a2a12");
    mg.addColorStop(0.45, "#7e5230");
    mg.addColorStop(1, "#3a200e");
    ctx.fillStyle = mg;
    ctx.fillRect(x - w, c.y0 - 4, w * 2, S.bottom - c.y0);
    ctx.fillStyle = "#26262c";
    for (let y = c.y0 + 60; y < S.bottom; y += 150) ctx.fillRect(x - w - 2, y, w * 2 + 4, 9);
  }
  // cargo in the hold: casks and crates on the far side
  for (const o of G.obstacles) {
    if (o.deck !== "hold" || (o.kind !== "cask" && o.kind !== "crate")) continue;
    const x0 = M.x(o.x0), x1 = M.x(o.x1), y = levelY(S, "hold") - lift(o.z0) + 4, w = x1 - x0;
    if (o.kind === "cask") {
      for (const [dx, h] of [[0, 96], [w * 0.52, 84]]) {
        const cx = x0 + dx + w * 0.24;
        ctx.fillStyle = "#6e4020";
        ctx.beginPath(); ctx.ellipse(cx, y - h / 2, w * 0.24, h / 2, 0, 0, Math.PI * 2); ctx.fill();
        ctx.strokeStyle = "#2a2a30";
        ctx.lineWidth = 5;
        for (const k of [0.25, 0.75]) (ctx.beginPath(), ctx.moveTo(cx - w * 0.23, y - h * k), ctx.lineTo(cx + w * 0.23, y - h * k), ctx.stroke());
      }
    } else {
      ctx.fillStyle = "#8a5a2e";
      ctx.fillRect(x0, y - 92, w, 92);
      ctx.strokeStyle = "#4a2a14";
      ctx.lineWidth = 6;
      ctx.strokeRect(x0 + 3, y - 89, w - 6, 86);
      ctx.beginPath(); ctx.moveTo(x0 + 6, y - 86); ctx.lineTo(x1 - 6, y - 6); ctx.moveTo(x1 - 6, y - 86); ctx.lineTo(x0 + 6, y - 6); ctx.stroke();
    }
  }
  // hammocks slung under the gun deck's beams, over the hold
  {
    const hy = levelY(S, ids[ids.length - 2] ?? "gun") + 40;
    ctx.strokeStyle = "#d8c6a4";
    ctx.lineWidth = 7;
    for (let x = c.x0 + 180, i = 0; x < c.x1 - 200; x += 330, i++) {
      if (i % 2) continue;
      ctx.beginPath(); ctx.moveTo(x, hy); ctx.quadraticCurveTo(x + 100, hy + 70, x + 200, hy); ctx.stroke();
    }
  }
  // the floors: each deck's planks, and the beam under it cut through
  for (const id of ids) {
    const y = levelY(S, id);
    planks(ctx, c.x0, c.x1, y);
    ctx.fillStyle = "#5a3218";
    ctx.fillRect(c.x0, y, c.x1 - c.x0, 26);
    ctx.fillStyle = "#3a1e0c";
    for (let x = c.x0 + 30; x < c.x1; x += 62) ctx.fillRect(x - 8, y + 5, 16, 16);
    ctx.fillStyle = "#c98d52";
    ctx.fillRect(c.x0, y, c.x1 - c.x0, 3);
  }
  // hatches in the interior floors, then the stairs and ladders down through them
  for (const o of G.obstacles) if (o.kind === "hatch" && o.deck !== "main") hatch(ctx, M.x(o.x0), M.x(o.x1), levelY(S, o.deck));
  for (const l of G.links) {
    if (l.a.deck === "qd" || l.a.deck === "fore" || l.kind === "shrouds") continue;
    if (l.kind === "stairs") stairs(ctx, l.path, M, l.a.z - 20);
    else ladder(ctx, l.path, M, l.a.z);
  }
  // lanterns hung from the beams
  for (const id of ids) {
    const y = levelY(S, id), top = id === ids[0] ? 26 : levelY(S, ids[ids.indexOf(id) - 1]) + 26;
    for (let x = c.x0 + 260; x < c.x1 - 120; x += 520) {
      const ly = top + 40;
      const glow = ctx.createRadialGradient(x, ly + 26, 0, x, ly + 26, 150);
      glow.addColorStop(0, "rgba(255,200,110,.38)");
      glow.addColorStop(1, "rgba(255,160,60,0)");
      ctx.fillStyle = glow;
      ctx.fillRect(x - 150, ly - 124, 300, 300);
      ctx.strokeStyle = "#1c1016";
      ctx.lineWidth = 3;
      ctx.beginPath(); ctx.moveTo(x, top); ctx.lineTo(x, ly + 6); ctx.stroke();
      ctx.fillStyle = GOLD_D;
      ctx.fillRect(x - 11, ly + 6, 22, 34);
      ctx.fillStyle = "#ffe29a";
      ctx.fillRect(x - 6, ly + 11, 12, 22);
    }
  }
  ctx.restore();
}

// the crow's nest at the lower masthead: a round-bottomed top on the mast, its rim, the floor the
// lookout stands on at m.nest
function nestTop(ctx, m) {
  ctx.fillStyle = WOOD;
  ctx.beginPath();
  ctx.moveTo(m.x - 110, m.nest);
  ctx.lineTo(m.x + 110, m.nest);
  ctx.lineTo(m.x + 86, m.nest + 90);
  ctx.lineTo(m.x - 86, m.nest + 90);
  ctx.fill();
  ctx.fillStyle = "rgba(0,0,0,.22)";
  ctx.fillRect(m.x - 98, m.nest + 44, 196, 8);
  ctx.fillStyle = GOLD;
  ctx.fillRect(m.x - 112, m.nest, 224, 12);
  planks(ctx, m.x - 104, m.x + 104, m.nest);
}

function drawBack(ctx, S, G) {
  const [q0, q1, qy] = S.qd, [f0, f1, fy] = S.fore, [m0, m1] = S.main;
  const M = mapper(S, G);
  // far bulwarks (seen over the decks)
  ctx.fillStyle = WOOD_D;
  ctx.fillRect(q0, qy - 110, q1 - q0, 110);
  ctx.fillRect(m0, -110, m1 - m0, 110);
  ctx.fillRect(f0, fy - 110, f1 - f0, 110);
  ctx.fillStyle = "#4a2a16";
  ctx.fillRect(q1 - 40, qy, 60, -qy);
  ctx.fillStyle = WOOD_L;
  ctx.fillRect(q0 + 5, qy, q1 - q0 - 5, 22);
  for (const [a, b, y] of [S.qd, S.main, S.fore]) planks(ctx, a, b, y);
  // hatches in the waist, and the capstan
  for (const o of G.obstacles) if (o.kind === "hatch" && o.deck === "main") hatch(ctx, M.x(o.x0), M.x(o.x1), 0);
  {
    const x = M.x(G.capX), y = -lift(DEPTH / 2) + 6;
    ctx.fillStyle = "#5a3218";
    ctx.fillRect(x - 36, y - 64, 72, 64);
    ctx.fillStyle = "#8e5a32";
    ctx.fillRect(x - 40, y - 72, 80, 14);
    ctx.fillStyle = GOLD_D;
    ctx.fillRect(x - 38, y - 40, 76, 7);
    ctx.strokeStyle = "#6b3f22";
    ctx.lineWidth = 8;
    ctx.beginPath(); ctx.moveTo(x - 90, y - 66); ctx.lineTo(x + 90, y - 66); ctx.stroke();
  }
  // the stairs down from the quarterdeck and the forecastle
  for (const l of G.links) if ((l.a.deck === "qd" || l.a.deck === "fore") && l.kind === "stairs") stairs(ctx, l.path, M, l.a.z - 20);
  // the inside of the hull through the cutaway
  interior(ctx, S, G, M);
  // masts, iron bands, the fighting tops (the rig at its drawn scale)
  const { f: rf, masts: rig } = rigOf(S), rw = Math.sqrt(rf);
  for (const m of rig) {
    const base = deckYOf(S, m.x), w = 26 * (m.g ?? 1) * rw;
    const g = ctx.createLinearGradient(m.x - w, 0, m.x + w, 0);
    g.addColorStop(0, "#5a3218");
    g.addColorStop(0.45, "#9a6436");
    g.addColorStop(1, "#4a2a14");
    ctx.fillStyle = g;
    ctx.beginPath();
    ctx.moveTo(m.x - w, base);
    ctx.lineTo(m.x - w * 0.55, m.top);
    ctx.lineTo(m.x + w * 0.55, m.top);
    ctx.lineTo(m.x + w, base);
    ctx.fill();
    ctx.fillStyle = "#2a2a30";
    for (let y = base - 120; y > m.top + 60; y -= 180) ctx.fillRect(m.x - w * 0.9, y, w * 1.8, 10);
    ctx.fillStyle = GOLD;
    ctx.beginPath();
    ctx.arc(m.x, m.top - 14 * rw, 20 * (m.g ?? 1) * rw, 0, Math.PI * 2);
    ctx.fill();
    // shrouds and ratlines
    ctx.strokeStyle = "rgba(40,24,14,.8)";
    ctx.lineWidth = 3;
    for (let i = 0; i < 5; i++) {
      ctx.beginPath();
      ctx.moveTo(m.x, m.top + (140 + i * 30) * rf);
      ctx.lineTo(m.x - (240 - i * 26) * rw, base - 60);
      ctx.moveTo(m.x, m.top + (140 + i * 30) * rf);
      ctx.lineTo(m.x + (240 - i * 26) * rw, base - 60);
      ctx.stroke();
    }
  }
  // the ratlines the lookout climbs: rungs across the shrouds up to the nest
  const sh = G.links.find((l) => l.kind === "shrouds");
  if (sh && S.masts.some((m) => m.nest && (m.g ?? 1) > 0.6)) {
    const [a, b] = [sh.path[1], sh.path[2]].map(([x, y]) => [M.x(x), y]);
    ctx.strokeStyle = "rgba(60,36,18,.95)";
    ctx.lineWidth = 4;
    const n = Math.round(Math.abs(b[1] - a[1]) / 46);
    for (let i = 1; i < n; i++) { const k = i / n, x = lerp(a[0], b[0], k), y = lerp(a[1], b[1], k); ctx.beginPath(); ctx.moveTo(x - 34, y); ctx.lineTo(x + 34, y); ctx.stroke(); }
    ctx.lineWidth = 5;
    ctx.beginPath(); ctx.moveTo(a[0] - 30, a[1]); ctx.lineTo(b[0] - 30, b[1]); ctx.moveTo(a[0] + 30, a[1]); ctx.lineTo(b[0] + 30, b[1]); ctx.stroke();
  }
  // stays: mast to mast and to the bowsprit
  ctx.strokeStyle = "rgba(40,24,14,.8)";
  ctx.lineWidth = 3;
  ctx.beginPath();
  for (let i = 0; i < rig.length; i++) {
    const a = rig[i], b = rig[i + 1];
    if (b) (ctx.moveTo(a.x, a.top + 40 * rf), ctx.lineTo(b.x, deckYOf(S, b.x) - 400 * rf));
  }
  const last = rig[rig.length - 1];
  if (last) (ctx.moveTo(last.x, last.top + 40 * rf), ctx.lineTo(S.bow + 340, fy - 210));
  ctx.stroke();
  ctx.fillStyle = WOOD_D;
  ctx.fillRect(q0 + 208, qy - 100, 24, 100);
}

function drawFront(ctx, S, G) {
  const [q0, q1, qy] = S.qd, [f0, f1, fy] = S.fore, [m0, m1] = S.main;
  const c = cutOf(S, G);
  // the hull's skin, all but the cutaway
  ctx.save();
  hullPath(ctx, S);
  ctx.clip();
  ctx.beginPath();
  ctx.rect(S.stern - 400, qy - 400, S.bow - S.stern + 1200, S.bottom - qy + 800);
  cutPath(ctx, c, true);
  ctx.clip("evenodd");
  const top = qy - 70, wl = SEA_Y + S.ride, g = ctx.createLinearGradient(0, top, 0, S.bottom + 20);
  const k = Math.max(0.3, Math.min(0.95, (wl - top) / (S.bottom + 20 - top)));
  g.addColorStop(0, "#7a4526");
  g.addColorStop(k * 0.5, "#5c321a");
  g.addColorStop(k - 0.01, "#3a1e10");
  g.addColorStop(k + 0.01, "#1a1a26");
  g.addColorStop(1, "#101018");
  ctx.fillStyle = g;
  ctx.fillRect(S.stern - 200, top, S.bow - S.stern + 400, S.bottom - top + 100);
  ctx.strokeStyle = "rgba(20,8,4,.55)";
  ctx.lineWidth = 3;
  const W0 = S.stern - 200, W1 = S.bow + 200, Mx = (W0 + W1) / 2;
  for (let y = top + 20; y < S.bottom + 10; y += 26) (ctx.beginPath(), ctx.moveTo(W0, y), ctx.bezierCurveTo(lerp(W0, Mx, 0.6), y + 18, lerp(Mx, W1, 0.4), y + 18, W1, y - 10), ctx.stroke());
  ctx.strokeStyle = GOLD;
  ctx.lineWidth = 10;
  for (const y of [-20, wl - 30]) (ctx.beginPath(), ctx.moveTo(W0, y), ctx.bezierCurveTo(lerp(W0, Mx, 0.6), y + 18, lerp(Mx, W1, 0.4), y + 18, W1, y - 10), ctx.stroke());
  ctx.strokeStyle = "#c8402c";
  ctx.lineWidth = 12;
  ctx.beginPath();
  ctx.moveTo(W0, 12);
  ctx.bezierCurveTo(lerp(W0, Mx, 0.6), 30, lerp(Mx, W1, 0.4), 30, W1, 2);
  ctx.stroke();
  // the stern galleries
  const nw = Math.max(2, Math.floor((q1 - q0 - 100) / 95));
  for (let i = 0; i < Math.min(nw, 6); i++) {
    const x = q0 + 20 + i * 90;
    ctx.fillStyle = "#2a1408";
    ctx.fillRect(x, qy - 20, 64, 80);
    const w = ctx.createLinearGradient(0, qy - 18, 0, qy + 58);
    w.addColorStop(0, "#fff0b0");
    w.addColorStop(1, "#ff9a3a");
    ctx.fillStyle = w;
    ctx.fillRect(x + 6, qy - 14, 52, 68);
    ctx.fillStyle = "#2a1408";
    ctx.fillRect(x + 29, qy - 14, 6, 68);
  }
  ctx.restore();
  // the cut's edge: the planking sawn through, a light section with an inked rim
  ctx.save();
  hullPath(ctx, S);
  ctx.clip();
  ctx.beginPath();
  cutPath(ctx, c);
  ctx.lineWidth = 22;
  ctx.strokeStyle = "#c98d52";
  ctx.stroke();
  ctx.lineWidth = 5;
  ctx.strokeStyle = DARK;
  ctx.beginPath();
  cutPath(ctx, { x0: c.x0 - 11, x1: c.x1 + 11, y0: c.y0 - 11, y1: c.y1 + 11 });
  ctx.stroke();
  ctx.beginPath();
  cutPath(ctx, { x0: c.x0 + 11, x1: c.x1 - 11, y0: c.y0 + 11, y1: c.y1 - 11 });
  ctx.stroke();
  // the plank ends along the section
  ctx.strokeStyle = "rgba(60,30,10,.6)";
  ctx.lineWidth = 3;
  for (let y = c.y0 + 40; y < c.y1 - 30; y += 26) for (const x of [c.x0, c.x1]) (ctx.beginPath(), ctx.moveTo(x - 11, y), ctx.lineTo(x + 11, y), ctx.stroke());
  ctx.restore();
  ctx.strokeStyle = DARK;
  ctx.lineWidth = 8;
  hullPath(ctx, S);
  ctx.stroke();
  // the rails, with balusters
  const rail = (a, b, y, h) => {
    ctx.fillStyle = GOLD_D;
    ctx.fillRect(a, y - h - 12, b - a, 14);
    ctx.fillStyle = GOLD;
    ctx.fillRect(a, y - h - 12, b - a, 5);
    ctx.fillStyle = "#5a3018";
    for (let x = a + 10; x < b - 6; x += 34) {
      ctx.beginPath();
      ctx.moveTo(x, y - h);
      ctx.quadraticCurveTo(x + 9, y - h / 2, x, y);
      ctx.lineTo(x + 12, y);
      ctx.quadraticCurveTo(x + 3, y - h / 2, x + 12, y - h);
      ctx.fill();
    }
  };
  rail(S.stern, q1, qy + 12, 60);
  rail(m0, m1, 12, 50);
  rail(f0, f1 + 20, fy + 12, 60);
  // the figurehead, the name plate (on the keel band, under the cutaway), the bowsprit, the stern lanterns
  ctx.fillStyle = GOLD;
  ctx.beginPath();
  ctx.moveTo(S.bow - 10, fy - 20);
  ctx.quadraticCurveTo(S.bow + 100, fy + 40, S.bow + 60, fy + 120);
  ctx.quadraticCurveTo(S.bow + 30, fy + 160, S.bow - 20, fy + 150);
  ctx.quadraticCurveTo(S.bow + 20, fy + 70, S.bow - 30, fy);
  ctx.fill();
  const cx = (m0 + m1) / 2, py = c.y1 + 16, ph = Math.max(40, Math.min(60, S.bottom - py - 16));
  ctx.fillStyle = "#2a1408";
  ctx.fillRect(cx - 260, py, 520, ph);
  ctx.strokeStyle = GOLD;
  ctx.lineWidth = 6;
  ctx.strokeRect(cx - 260, py, 520, ph);
  ctx.fillStyle = GOLD;
  ctx.font = `italic 800 ${Math.round(ph * 0.72)}px 'Barlow Semi Condensed', system-ui, sans-serif`;
  ctx.textAlign = "center";
  ctx.fillText("FIRSTMATE", cx, py + ph * 0.78);
  for (const [col, w] of [["#5a3218", 26], [GOLD, 6]]) {
    ctx.strokeStyle = col;
    ctx.lineWidth = w;
    ctx.beginPath();
    ctx.moveTo(S.bow - 150, fy - 80);
    ctx.lineTo(S.bow + 340, fy - 220);
    ctx.stroke();
  }
  ctx.fillStyle = "#2a2a30";
  for (const x of [S.stern, q0 + 220]) ctx.fillRect(x - 14, qy - 150, 28, 50);
}

export class Ship {
  constructor({ low = false, cls = CLASSES[2] } = {}) {
    this.low = low;
    this.x = 0; this.y = 0; this.roll = 0; this.pitch = 0;
    this.heel = 0; this.heelV = 0;
    this.t = 0;
    this.wind = 0.5;
    this.chaser = 0;
    this.wheel = 0; this.wheelV = 0;
    this.bell = 0;
    this.damage = [];
    this.S = low ? 0.5 : 0.85; // cache resolution
    this.cls = cls;
    this.G = geometryOf(cls); // the walkable decks (the target class's, during a change)
    this.from = null;
    this.k = 1; // 0..1 through a class change
    this.spec = cls;
    this.y = -cls.ride;
    this.recoil = Array(60).fill(0);
    this._build();
  }
  // grow (or shrink) to a class; `dur` seconds, drawn live meanwhile
  setClass(cls, dur = 3.2) {
    if (cls === this.cls && this.k >= 1) return false;
    this.from = this.k < 1 ? { ...this.spec } : this.cls;
    this.cls = cls;
    this.G = geometryOf(cls);
    this.k = dur > 0 ? 0 : 1;
    this.dur = dur;
    if (!dur) (this.spec = cls), this._build();
    return true;
  }
  get transforming() { return this.k < 1; }
  // the guns of one gun deck (row 0 is the upper gun deck), x in the drawn hull
  gunsAt(row = 0) { const M = mapper(this.spec, this.G); return this.G.guns.filter((g) => g.row === row).map((g) => M.x(g.x)); }
  get gunports() { return this.gunsAt(0); }
  get gunY() { return this.spec.gunRows[0]; }
  get ride() { return this.spec.ride; }
  // the drawn rig's highest point (the camera frames sails to keel) and its masts, as drawn
  get rigTop() { return rigTop(this.spec); }
  get rig() { return rigOf(this.spec).masts; }
  // a deck's floor height now (it moves while the ship changes class)
  levelY(id) { return levelY(this.spec, id, this.G); }
  get sections() { return sectionsOf(this.spec); }
  deckY(x) { return deckYOf(this.spec, x); }
  _build() {
    const S = this.spec, x0 = S.stern - 260, x1 = S.bow + 420, yTop = rigTop(S) - 260 * rigScale(S), yBot = S.bottom + 60;
    this.box = { x0, y0: yTop, w: x1 - x0, h: yBot - yTop };
    // the front layer is clipped to the hull (from 400 over the quarterdeck down), so its cache
    // leaves the rig's sky out: a smaller canvas to blit every frame
    const fTop = Math.min(S.qd[2], S.fore[2]) - 420;
    this.fbox = { x0, y0: fTop, w: x1 - x0, h: yBot - fTop };
    const mk = (fn, B) => {
      const c = document.createElement("canvas");
      c.width = Math.ceil(B.w * this.S);
      c.height = Math.ceil(B.h * this.S);
      const x = c.getContext("2d");
      x.scale(this.S, this.S);
      x.translate(-B.x0, -B.y0);
      fn(x, S, this.G);
      return c;
    };
    this.back = mk(drawBack, this.box);
    this.front = mk(drawFront, this.fbox);
  }
  kick(deg) { this.heelV += deg; }
  update(dt, env) {
    this.t += dt;
    if (this.k < 1) {
      this.k = Math.min(1, this.k + dt / this.dur);
      this.spec = blendSpec(this.from, this.cls, this.k);
      if (this.k >= 1) (this.spec = this.cls), (this.from = null), this._build();
    }
    const half = (this.spec.bow - this.spec.stern) / 2;
    const bow = env.waveAt(this.x + half, 1), stern = env.waveAt(this.x - half, 1);
    this.y += ((bow + stern) / 2 * 0.8 - this.spec.ride - this.y) * Math.min(1, dt * 3);
    this.pitch += (Math.atan2(bow - stern, half * 2) * 0.8 - this.pitch) * Math.min(1, dt * 3);
    this.heelV += (-30 * this.heel - 3.2 * this.heelV) * dt;
    this.heel += this.heelV * dt;
    this.roll = this.pitch + (this.heel * Math.PI) / 180;
    for (let i = 0; i < this.recoil.length; i++) this.recoil[i] = Math.max(0, this.recoil[i] - dt * 3);
    this.chaser = Math.max(0, this.chaser - dt * 3);
    this.wheelV *= Math.exp(-dt * 1.5);
    this.wheel += this.wheelV * dt;
    this.bell = Math.max(0, this.bell - dt * 0.6);
    this.damage = this.damage.filter((d) => this.t - d.t < 60);
  }
  toWorld(x, y) {
    const c = Math.cos(this.roll), s = Math.sin(this.roll);
    return [this.x + x * c - y * s, this.y + x * s + y * c];
  }
  enter(ctx) {
    ctx.save();
    ctx.translate(this.x, this.y);
    ctx.rotate(this.roll);
  }
  drawBack(ctx) {
    this.enter(ctx);
    if (this.k < 1) drawBack(ctx, this.spec, this.G);
    else ctx.drawImage(this.back, this.box.x0, this.box.y0, this.box.w, this.box.h);
    this._sails(ctx);
    this._wheel(ctx);
    this._bell(ctx);
    ctx.restore();
  }
  drawFront(ctx) {
    this.enter(ctx);
    if (this.k < 1) drawFront(ctx, this.spec, this.G);
    else ctx.drawImage(this.front, this.fbox.x0, this.fbox.y0, this.fbox.w, this.fbox.h);
    this._guns(ctx);
    this._lanterns(ctx);
    for (const d of this.damage) {
      const a = Math.max(0, 1 - (this.t - d.t) / 60);
      ctx.fillStyle = `rgba(20,8,4,${0.7 * a})`;
      ctx.beginPath();
      ctx.moveTo(d.x - 50, -40);
      ctx.lineTo(d.x - 10, -10);
      ctx.lineTo(d.x + 30, -44);
      ctx.lineTo(d.x + 44, 6);
      ctx.lineTo(d.x - 40, 12);
      ctx.fill();
    }
    ctx.restore();
  }
  _sails(ctx) {
    const S = this.spec, w = 0.35 + this.wind * 0.8;
    const { f: rf, masts: rig } = rigOf(S);
    const mainI = Math.min(rig.length - 1, rig.length === 1 ? 0 : 1);
    rig.forEach((m, mi) => {
      const base = deckYOf(S, m.x);
      // the emblem rides on the main's second sail from the top, or the one above the nest's
      const nestSail = m.nest ? m.yards.findIndex(([y], j) => y < m.nest && (m.yards[j + 1]?.[0] ?? base) > m.nest) : -1;
      const mark = nestSail > 0 ? Math.min(nestSail - 1, 1) : Math.min(1, m.yards.length - 1);
      m.yards.forEach(([y, half], yi) => {
        if (half < 4) return;
        const next = m.yards[yi + 1]?.[0] ?? base - RIG_LOW;
        const h = Math.max(20, Math.min(next - y - 40, RIG_SAIL_CAP * rf));
        const bel = (22 + 60 * w) * rf * (1 + 0.08 * Math.sin(this.t * 2.2 + y));
        ctx.fillStyle = "#4a2a14";
        ctx.fillRect(m.x - half - 20 * rf, y - 12 * rf, (half + 20 * rf) * 2, 18 * rf);
        const g = ctx.createLinearGradient(m.x - half, 0, m.x + half, 0);
        g.addColorStop(0, "#d8c6a4");
        g.addColorStop(0.5, "#fbf1dc");
        g.addColorStop(1, "#e2cfae");
        ctx.fillStyle = g;
        ctx.beginPath();
        ctx.moveTo(m.x - half, y);
        ctx.lineTo(m.x + half, y);
        ctx.quadraticCurveTo(m.x + half + bel * 0.6, y + h * 0.55, m.x + half * 0.92, y + h);
        ctx.quadraticCurveTo(m.x, y + h + bel * 0.35, m.x - half * 0.92, y + h);
        ctx.quadraticCurveTo(m.x - half + bel * 0.3, y + h * 0.5, m.x - half, y);
        ctx.fill();
        ctx.strokeStyle = "rgba(150,110,70,.35)";
        ctx.lineWidth = 5;
        for (const k of [-0.5, 0, 0.5]) (ctx.beginPath(), ctx.moveTo(m.x + k * half, y + 10), ctx.quadraticCurveTo(m.x + k * half + bel * 0.3, y + h * 0.5, m.x + k * half * 0.92, y + h - 10), ctx.stroke());
        ctx.strokeStyle = "#c8402c";
        ctx.lineWidth = 12;
        ctx.beginPath();
        ctx.moveTo(m.x + half * 0.92, y + h);
        ctx.quadraticCurveTo(m.x, y + h + bel * 0.35, m.x - half * 0.92, y + h);
        ctx.stroke();
        if (mi === mainI && yi === mark && half > 120) {
          ctx.save();
          ctx.translate(m.x + bel * 0.12, y + h * 0.5);
          ctx.scale(rf, rf);
          ctx.fillStyle = "#1f2f5c";
          star(ctx, 0, 0, 90, 38, 8);
          ctx.fillStyle = GOLD;
          ctx.beginPath();
          ctx.arc(0, 0, 30, 0, Math.PI * 2);
          ctx.fill();
          ctx.fillStyle = "#1f2f5c";
          ctx.font = "900 44px system-ui, sans-serif";
          ctx.textAlign = "center";
          ctx.textBaseline = "middle";
          ctx.fillText("⚓", 0, 3);
          ctx.restore();
        }
      });
      if (m.nest && (m.g ?? 1) > 0.6) nestTop(ctx, m);
    });
    const last = rig[rig.length - 1];
    if (last) {
      ctx.fillStyle = "#f4ead2";
      ctx.beginPath();
      ctx.moveTo(last.x + 40, last.top + 80 * rf);
      ctx.quadraticCurveTo(S.bow + 20 + w * 60, (last.top + S.fore[2]) / 2, S.bow + 300, S.fore[2] - 220);
      ctx.lineTo(last.x + 60, S.fore[2] - 210);
      ctx.fill();
    }
    const m = rig[mainI];
    if (!m) return;
    // the flag, at the rig's scale
    const fx = m.x, fy = m.top - 30 * rf, gw = (m.g ?? 1) * rf;
    ctx.fillStyle = "#15151c";
    ctx.beginPath();
    ctx.moveTo(fx, fy);
    for (let i = 0; i <= 10; i++) ctx.lineTo(fx - i * 30 * gw, fy + Math.sin(this.t * 7 - i * 0.7) * 10 * (i / 10) * (0.5 + w));
    for (let i = 10; i >= 0; i--) ctx.lineTo(fx - i * 30 * gw, fy + 150 * gw + Math.sin(this.t * 7 - i * 0.7) * 10 * (i / 10) * (0.5 + w));
    ctx.fill();
    if ((m.g ?? 1) < 0.9) return;
    ctx.save();
    ctx.translate(fx, fy);
    ctx.scale(rf, rf);
    ctx.fillStyle = "#f4ead2";
    const cx = -150, cy = 72 + Math.sin(this.t * 7 - 3.5) * 5;
    ctx.beginPath();
    ctx.arc(cx, cy - 8, 30, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillRect(cx - 18, cy + 14, 36, 18);
    ctx.fillStyle = "#15151c";
    ctx.fillRect(cx - 16, cy - 16, 12, 12);
    ctx.fillRect(cx + 4, cy - 16, 12, 12);
    ctx.strokeStyle = "#f4ead2";
    ctx.lineWidth = 9;
    ctx.beginPath();
    ctx.moveTo(cx - 56, cy - 40); ctx.lineTo(cx + 56, cy + 52);
    ctx.moveTo(cx + 56, cy - 40); ctx.lineTo(cx - 56, cy + 52);
    ctx.stroke();
    ctx.fillStyle = GOLD;
    ctx.beginPath();
    ctx.moveTo(cx - 44, cy - 30);
    ctx.quadraticCurveTo(cx, cy - 76, cx + 44, cy - 30);
    ctx.quadraticCurveTo(cx, cy - 44, cx - 44, cy - 30);
    ctx.fill();
    ctx.restore();
  }
  wheelPos() { return [this.spec.qd[0] + 220, this.spec.qd[2] - 112]; }
  _wheel(ctx) {
    ctx.save();
    ctx.translate(...this.wheelPos());
    ctx.rotate(this.wheel);
    ctx.strokeStyle = "#7a4522";
    ctx.lineWidth = 12;
    ctx.beginPath();
    ctx.arc(0, 0, 58, 0, Math.PI * 2);
    ctx.stroke();
    ctx.lineWidth = 8;
    for (let i = 0; i < 8; i++) {
      const a = (i / 8) * Math.PI * 2;
      ctx.beginPath();
      ctx.moveTo(Math.cos(a) * 12, Math.sin(a) * 12);
      ctx.lineTo(Math.cos(a) * 82, Math.sin(a) * 82);
      ctx.stroke();
    }
    ctx.fillStyle = GOLD;
    ctx.beginPath();
    ctx.arc(0, 0, 14, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
  }
  _bell(ctx) {
    ctx.save();
    ctx.translate(this.spec.qd[1] - 20, this.spec.qd[2] - 180);
    ctx.fillStyle = "#4a2a14";
    ctx.fillRect(-40, -12, 80, 12);
    ctx.fillRect(-36, 0, 10, 150);
    ctx.rotate(Math.sin(this.t * 14) * 0.5 * this.bell);
    ctx.fillStyle = GOLD;
    ctx.beginPath();
    ctx.moveTo(-10, 0);
    ctx.quadraticCurveTo(-26, 30, -30, 56);
    ctx.lineTo(30, 56);
    ctx.quadraticCurveTo(26, 30, 10, 0);
    ctx.fill();
    ctx.restore();
  }
  _guns(ctx) {
    const S = this.spec, M = mapper(S, this.G), rows = S.gunRows.length;
    for (const gn of this.G.guns) {
      if (gn.row >= rows) continue;
      const x = M.x(gn.x), y = levelY(S, gn.deck, this.G), i = gn.i;
      const r = this.recoil[(gn.row * 12 + i) % this.recoil.length];
      const pop = this.k < 1 && i >= (this.from?.guns ?? 99) ? Math.min(1, (this.k - 0.3) * 3) : 1; // new guns pop in
      if (pop <= 0) continue;
      ctx.save();
      ctx.translate(x, y - 3);
      ctx.scale(pop, pop);
      // the carriage and its trucks
      ctx.fillStyle = "#5a3218";
      ctx.fillRect(-44, -46, 88, 40);
      ctx.fillStyle = "#3a1e0c";
      ctx.fillRect(-44, -12, 88, 6);
      ctx.fillStyle = "#1c1016";
      for (const dx of [-30, 30]) (ctx.beginPath(), ctx.arc(dx, -8, 11, 0, Math.PI * 2), ctx.fill());
      // the muzzle, run out toward us (it recoils in when it fires)
      ctx.translate(0, -75);
      const k = 1 - r * 0.25;
      ctx.fillStyle = "#26262c";
      ctx.beginPath();
      ctx.arc(0, 0, 26 * k, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = "#050505";
      ctx.beginPath();
      ctx.arc(0, 0, 14 * k, 0, Math.PI * 2);
      ctx.fill();
      ctx.strokeStyle = "#5a5a66";
      ctx.lineWidth = 5;
      ctx.beginPath();
      ctx.arc(0, 0, 26 * k, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }
    const [cx, cy] = this.chaserLocal();
    ctx.save();
    ctx.translate(cx - 100 - this.chaser * 30, cy);
    ctx.fillStyle = "#26262c";
    ctx.beginPath();
    ctx.moveTo(-60, -20);
    ctx.lineTo(90, -14);
    ctx.lineTo(90, 14);
    ctx.lineTo(-60, 22);
    ctx.fill();
    ctx.fillStyle = "#3a3a44";
    ctx.fillRect(84, -18, 14, 36);
    ctx.fillStyle = "#5a3018";
    ctx.beginPath();
    ctx.arc(-30, 30, 18, 0, Math.PI * 2);
    ctx.arc(40, 30, 18, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
  }
  _lanterns(ctx) {
    const S = this.spec;
    ctx.save();
    ctx.globalCompositeOperation = "lighter";
    for (const x of [S.stern, S.qd[0] + 220]) {
      const y = S.qd[2] - 125;
      const g = ctx.createRadialGradient(x, y, 0, x, y, 90);
      const f = 0.55 + 0.1 * Math.sin(this.t * 9 + x);
      g.addColorStop(0, `rgba(255,210,120,${f})`);
      g.addColorStop(1, "rgba(255,150,60,0)");
      ctx.fillStyle = g;
      ctx.fillRect(x - 90, y - 90, 180, 180);
    }
    ctx.restore();
  }
  // clip to everything but the hull (world view rectangle minus the hull, even-odd)
  clipOutHull(ctx, v) {
    ctx.beginPath();
    ctx.rect(v.x0 - 50, v.y0 - 50, v.x1 - v.x0 + 100, v.y1 - v.y0 + 100);
    const pts = hullOutline(this.spec), c = Math.cos(this.roll), s = Math.sin(this.roll);
    const w = ([x, y]) => [this.x + x * c - y * s, this.y + x * s + y * c];
    ctx.moveTo(...w(pts[0]));
    for (let i = pts.length - 1; i > 0; i--) ctx.lineTo(...w(pts[i]));
    ctx.closePath();
    ctx.clip("evenodd");
  }
  // the sea inside the cut: a tint below the waterline and the line itself
  drawWater(ctx, env) {
    this.enter(ctx);
    hullPath(ctx, this.spec);
    ctx.clip();
    const S = this.spec, x0 = S.stern - 120, x1 = S.bow + 120;
    ctx.beginPath();
    const wy = (x) => SEA_Y + env.waveAt(this.x + x, 1) * 0.6 - this.y - x * Math.tan(this.roll);
    ctx.moveTo(x0, wy(x0));
    for (let x = x0; x <= x1; x += 40) ctx.lineTo(x, wy(x));
    ctx.lineTo(x1, S.bottom + 60);
    ctx.lineTo(x0, S.bottom + 60);
    ctx.closePath();
    ctx.fillStyle = "rgba(22,86,190,.34)";
    ctx.fill();
    ctx.beginPath();
    for (let x = x0; x <= x1; x += 40) x === x0 ? ctx.moveTo(x, wy(x)) : ctx.lineTo(x, wy(x));
    ctx.strokeStyle = "rgba(236,246,255,.85)";
    ctx.lineWidth = 6;
    ctx.stroke();
    ctx.restore();
  }
  chaserLocal() { return [this.spec.fore[1] - 40, this.spec.fore[2] - 60]; }
  portWorld(i, row = 0) {
    const r = row % Math.max(1, this.spec.gunRows.length), xs = this.gunsAt(r).length ? this.gunsAt(r) : this.gunsAt(0);
    return this.toWorld(xs[i % xs.length] ?? 0, this.spec.gunRows[r] ?? 70);
  }
  chaserWorld() { const [x, y] = this.chaserLocal(); return this.toWorld(x + 100, y); }
}

function star(ctx, x, y, R, r, n) {
  ctx.beginPath();
  for (let i = 0; i < n * 2; i++) {
    const a = (i / (n * 2)) * Math.PI * 2 - Math.PI / 2, rr = i % 2 ? r : R;
    ctx.lineTo(x + Math.cos(a) * rr, y + Math.sin(a) * rr);
  }
  ctx.fill();
}
export { SEA_Y };
