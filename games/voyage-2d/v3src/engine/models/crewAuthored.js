// The crew's bodies and hats as AUTHORED smooth geometry (pass 2, the captain's
// technique from captainSmooth.js): each torso is a ring surface on a superellipse
// cross-section shaped to the character's own build (chest, waist, belly, depth,
// the voxel torso's measured silhouette), and every costume piece is modelled on top
// of it: collars, lapels, the V fill and kerchief triangles are overlay patches that
// follow the surface (their colour edges are geometry edges, so they stay straight
// and clean up close); piping, stripes, straps, anchors and seams are tubes; belts,
// buckles, satchels and robot shells are ring bands and rounded boxes. Base colours
// change only on ring rows or angle columns, so no colour edge steps.
// One toon material (smoothMat) for everything that skins, so each body is one draw.
// Units: bodies in torso voxels (CS, scaled at the end), hats in head units (HU).
// Parts that swing (kerchief tails, hat ribbons and bows) are separate child groups
// named "kerchiefTails" and "ribbons" (userData.noSkin), pivoted at their knot.
import * as THREE from "three";
import { mergeVertices, mergeGeometries } from "three/addons/utils/BufferGeometryUtils.js";
import { RoundedBoxGeometry } from "three/addons/geometries/RoundedBoxGeometry.js";
import { finish, meshOf, tube, sphere, capsule } from "./captainSmooth.js";
import { headHalfW, CS, shade } from "./chibi.js";
import { PAL } from "../materials.js";
import { loftQuality } from "./crewSmooth.js";
import { softMaterial } from "../smoothmesh.js";
import { M } from "../voxel.js";

const C = (h) => new THREE.Color(h);
const V3 = (x, y, z) => new THREE.Vector3(x, y, z);
// segment counts follow the loft quality (phones 0.55)
const segs = (n, min = 6) => Math.max(min, Math.round(n * loftQuality()));
const sm = (a, b, x) => {
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
};
const NAVY = PAL.navy, NAVY_D = PAL.navyDark, WHITE = PAL.white, UNDER = 0xdfe6f2;

// ---------------------------------------------------------------- surface helpers
// an indexed grid P(i, j) (i rows 0..rows, j cols 0..cols), welded for smooth normals,
// then flat colour per triangle from its centroid (finish)
function gridSurface(rows, cols, P, colour) {
  const pos = [], idx = [];
  for (let i = 0; i <= rows; i++) for (let j = 0; j <= cols; j++) pos.push(...P(i, j).toArray());
  const W = cols + 1;
  for (let i = 0; i < rows; i++)
    for (let j = 0; j < cols; j++) {
      const a = i * W + j, b = a + 1, c = a + W + 1, d = a + W;
      idx.push(a, b, c, a, c, d);
    }
  let g = new THREE.BufferGeometry();
  g.setAttribute("position", new THREE.Float32BufferAttribute(pos, 3));
  g.setIndex(idx);
  g = mergeVertices(g, 1e-4);
  g.computeVertexNormals();
  return finish(g, colour);
}
// a flat ribbon with a rectangular section (w wide, t thick) along a curve; `up` is the
// direction the broad face looks toward; the width tapers toward the tip
function ribbon(pts, w, t, colour, { taper = 0.55, up = V3(0, 0, 1), n = 0 } = {}) {
  const P = pts.map((p) => (p.isVector3 ? p : V3(...p)));
  const curve = new THREE.CatmullRomCurve3(P, false, "centripetal");
  const N = n || segs(Math.max(5, P.length * 3), 3);
  const rings = [];
  for (let k = 0; k <= N; k++) {
    const u = k / N, p = curve.getPoint(u), T = curve.getTangent(u).normalize();
    const A = new THREE.Vector3().crossVectors(T, up);
    if (A.lengthSq() < 1e-6) A.set(1, 0, 0);
    A.normalize();
    const Nn = new THREE.Vector3().crossVectors(A, T).normalize();
    const ww = (w / 2) * (1 - (1 - taper) * u), tt = t / 2;
    rings.push([[ww, tt], [-ww, tt], [-ww, -tt], [ww, -tt]].map(([a, b]) => p.clone().addScaledVector(A, a).addScaledVector(Nn, b)));
  }
  const pos = [];
  const quad = (a, b, c, d) => pos.push(...a.toArray(), ...b.toArray(), ...c.toArray(), ...a.toArray(), ...c.toArray(), ...d.toArray());
  for (let k = 0; k < N; k++) for (let s = 0; s < 4; s++) quad(rings[k][s], rings[k][(s + 1) % 4], rings[k + 1][(s + 1) % 4], rings[k + 1][s]);
  const e = rings[N];
  quad(e[0], e[1], e[2], e[3]);
  const g = new THREE.BufferGeometry();
  g.setAttribute("position", new THREE.Float32BufferAttribute(pos, 3));
  g.computeVertexNormals();
  return finish(g, colour);
}
const rbox = (w, h, d, at, colour, r = 0.5, seg = 2) => finish(new RoundedBoxGeometry(w, h, d, seg, Math.min(r, w / 2 - 0.01, h / 2 - 0.01, d / 2 - 0.01)).translate(...at), colour);
// an anchor emblem: strokes in (u, v) mapped onto a surface by map(u, v) -> Vector3
const ANCHOR = [
  [[0, 0.95], [0, -0.92]],
  [[-0.52, 0.55], [0.52, 0.55]],
  [[-0.82, -0.3], [-0.6, -0.78], [0, -1.0], [0.6, -0.78], [0.82, -0.3]],
];
function anchorParts(map, s, r, colour) {
  const out = ANCHOR.map((st) => tube(st.map(([u, v]) => map(u * s, v * s)), r, colour, { seg: st.length > 2 ? 12 : 2, radial: 5 }));
  out.push(sphere(r * 1.7, map(0, 1.12 * s).toArray(), colour, 1, 1, 1, 6));
  return out;
}

// ---------------------------------------------------------------- the torso shape (CS)
// the voxel torso (torsoGrid): half width chest above y 6, waist below y 3, a ramp
// between; back at -depth, front at depth (y 5..9, else depth-1) plus the belly;
// shoulders round over to the neck at y 10.8; the seat closes at y -1.2
export function torsoShape(b, { p = 2.9, box = false } = {}) {
  const ch = b.chest + 0.5, wa = (b.waist ?? b.chest) + 0.5, dep = (b.depth ?? 3) + 0.5, belly = b.belly || 0;
  const Y0 = -1.2, TOP = 10.8, SH = 8.6;
  const top = (y) => (y > SH ? Math.pow(Math.max(0, 1 - ((y - SH) / (TOP - SH)) ** 2.4), 1 / 2.4) : 1);
  const seat = (y) => (y < 0 ? Math.sqrt(Math.max(0, 1 - (y / (0 - Y0)) ** 2)) : 1);
  const Wb = (y) => (y < 3 ? wa : wa + (ch - wa) * sm(3, 6, y));
  const W = (y) => Wb(y) * top(y) * (0.35 + 0.65 * seat(y)) + 0.001;
  const DB = (y) => dep * Math.sqrt(top(y)) * (0.4 + 0.6 * seat(y)) + 0.001;
  const DF = (y) => (dep - 1 + sm(4, 5.5, y) * (1 - sm(9.2, 10.6, y)) + (y > -1 && y < 8 ? belly * Math.sin((Math.PI * (y + 1)) / 9) : 0)) * Math.sqrt(top(y)) * (0.4 + 0.6 * seat(y)) + 0.001;
  return { ch, wa, dep, W, DF, DB, p, Y0, TOP, box };
}
export function ringPt(S, a, y, grow = 0) {
  const s = Math.sin(a), c = Math.cos(a), ex = 2 / S.p;
  const w = S.W(y) + grow, d = (c > 0 ? S.DF(y) : S.DB(y)) + grow;
  return V3(Math.sign(s) * Math.abs(s) ** ex * w, y, Math.sign(c) * Math.abs(c) ** ex * d);
}
// the surface point at (x, y), front or back
export function onSurf(S, x, y, grow = 0, back = false) {
  const w = S.W(y) + grow;
  const s = Math.max(-1, Math.min(1, x / w));
  let a = Math.asin(Math.max(-1, Math.min(1, Math.sign(s) * Math.abs(s) ** (S.p / 2))));
  if (back) a = Math.PI - a;
  return ringPt(S, a, y, grow);
}
const ROWS = 30; // ring rows every 0.4 CS from y -1.2: colour boundaries sit on rows 0.4, 5.6, 9.2, 9.6
function torsoBase(S, colour) {
  const cols = segs(64, 28);
  return gridSurface(ROWS, cols, (i, j) => ringPt(S, (j / cols) * Math.PI * 2, S.Y0 + ((S.TOP - S.Y0) * i) / ROWS), colour);
}
// a ring band (belts, sashes)
function band(S, y0, y1, grow, colour, rows = 2) {
  const cols = segs(56, 24);
  return gridSurface(rows, cols, (i, j) => ringPt(S, (j / cols) * Math.PI * 2, y0 + ((y1 - y0) * i) / rows, grow), colour);
}
// an overlay patch on the front (or back) surface: xy(u, v) -> [x, y]
function patch(S, rows, cols, xy, grow, colour, back = false) {
  return gridSurface(rows, cols, (i, j) => {
    const [x, y] = xy(j / cols, i / rows);
    return onSurf(S, x, y, grow, back);
  }, colour);
}
// a patch in (angle, y): back panels
function anglePatch(S, a0, a1, y0, y1, rows, cols, grow, colour) {
  return gridSurface(rows, cols, (i, j) => ringPt(S, a0 + ((a1 - a0) * j) / cols, y0 + ((y1 - y0) * i) / rows, grow), colour);
}
const surfTube = (S, xy, n, grow, r, colour, back = false) => {
  const pts = [];
  for (let k = 0; k <= n; k++) {
    const [x, y] = xy(k / n);
    pts.push(onSurf(S, x, y, grow, back));
  }
  return tube(pts, r, colour, { seg: Math.max(4, n * 2), radial: 5 });
};
const clampX = (S, x, y, k = 0.95) => Math.sign(x) * Math.min(Math.abs(x), S.W(y) * k);
// the neck and the belt with its buckle
function neckAndBelt(S, parts, { belt = PAL.leather, buckle = PAL.gold, neck = PAL.skin } = {}) {
  parts.push(capsule(1.5, 1.0, [0, 11.5, 0], neck));
  if (belt) {
    parts.push(band(S, 0.4, 2.3, 0.32, belt));
    const f = onSurf(S, 0, 1.35, 0.32);
    parts.push(rbox(2.3, 1.75, 0.7, [0, 1.35, f.z + 0.25], buckle, 0.28));
    parts.push(rbox(1.2, 0.8, 0.4, [0, 1.35, f.z + 0.55], shade(buckle, 0.62), 0.15));
  }
}
function tailsGroup(name, at, parts) {
  const g = new THREE.Group();
  g.name = name;
  g.userData.noSkin = true;
  g.position.set(at.x * CS, at.y * CS, at.z * CS);
  const m = meshOf(parts, CS);
  g.add(m);
  return g;
}

// ---------------------------------------------------------------- sailors
// white shirt; the square sailor collar: a navy panel over the back with a white
// stripe, navy over the shoulders, navy lapels down to a V with a white stripe; the
// light undershirt (skin at the throat) in the V; belt and gold buckle; a navy anchor
// on the left chest; the neckerchief knot and tails (or the red kerchief)
export function sailorTorso(body, { kerchief = null } = {}) {
  const S = torsoShape(body);
  const parts = [];
  parts.push(torsoBase(S, (p) => C(p.y < 0.4 ? NAVY : p.y > 9.6 ? NAVY : WHITE)));
  // the V (point at y 5.2) and the lapels
  const lw = 0.9 + 0.12 * S.ch;
  const k = (0.826 * S.ch - lw) / 4.7;
  const vx = (y) => Math.max(0, y - 5.2) * k;
  const VR = 14, VY0 = 5.2, VY1 = 5.2 + 14 * 0.38; // rows every 0.38: y 9.0 on a row
  parts.push(patch(S, VR, 8, (u, v) => { const y = VY0 + (VY1 - VY0) * v; return [clampX(S, (u * 2 - 1) * vx(y), y, 0.8), y]; }, 0.08, (p) => C(p.y < 9.0 ? UNDER : PAL.skin)));
  for (const s of [-1, 1]) {
    parts.push(patch(S, VR, 3, (u, v) => { const y = VY0 + (VY1 - VY0) * v; return [clampX(S, s * (vx(y) + lw * u), y), y]; }, 0.16, NAVY));
    // the white stripe along the lapel
    parts.push(surfTube(S, (t) => { const y = 5.5 + 4.6 * t; return [clampX(S, s * (vx(y) + lw * 0.62), y, 0.93), y]; }, 8, 0.3, 0.2, WHITE));
  }
  // the back panel (angle columns, so its sides are clean) with its white stripe
  const d = 0.32;
  parts.push(anglePatch(S, Math.PI / 2 + d, (3 * Math.PI) / 2 - d, 5.6, 9.8, 6, segs(24, 10), 0.14, NAVY));
  {
    const a0 = Math.PI / 2 + d + 0.28, a1 = (3 * Math.PI) / 2 - d - 0.28, pts = [];
    for (let y = 9.9; y > 6.6; y -= 0.55) pts.push(ringPt(S, a0, y, 0.3));
    for (let k2 = 0; k2 <= 10; k2++) pts.push(ringPt(S, a0 + ((a1 - a0) * k2) / 10, 6.5, 0.3));
    for (let y = 6.6; y < 9.95; y += 0.55) pts.push(ringPt(S, a1, y, 0.3));
    parts.push(tube(pts, 0.24, WHITE, { seg: 48, radial: 5 }));
  }
  neckAndBelt(S, parts);
  // the anchor on the left chest (+x)
  const ax = 0.66 * S.ch;
  parts.push(...anchorParts((u, v) => onSurf(S, ax + u, 6.3 + v, 0.22), 0.95, 0.2, NAVY));
  const g = new THREE.Group();
  if (kerchief) {
    // the red kerchief (banner): a band round the neck, a triangle on the chest, a big knot
    const [K, KD] = kerchief;
    parts.push(finish(new THREE.TorusGeometry(2.75, 0.72, 6, segs(22, 10)).rotateX(Math.PI / 2).scale(1, 1, 1.12).translate(0, 10.35, 0.35), K));
    parts.push(patch(S, 6, 6, (u, v) => { const y = 9.5 - v * 4.4; return [(u * 2 - 1) * 2.5 * (1 - v * 0.96), y]; }, 0.26, (p) => C(p.y > 8.9 ? KD : K)));
    const kn = onSurf(S, 0, 8.7, 0.9);
    g.add(tailsGroup("kerchiefTails", kn, [
      sphere(1.15, [0, 0, 0], KD, 1.25, 1, 0.8, segs(12, 8)),
      ribbon([[-0.4, -0.3, 0.3], [-1.1, -1.2, 0.45], [-1.6, -2.1, 0.5]], 1.1, 0.35, K),
      ribbon([[0.4, -0.3, 0.3], [1.0, -1.1, 0.5], [1.45, -1.9, 0.6]], 1.1, 0.35, K),
    ]));
  } else {
    // the navy neckerchief knot at the V, and its tails
    const kn = onSurf(S, 0, 5.45, 0.5);
    g.add(tailsGroup("kerchiefTails", kn, [
      sphere(0.85, [0, 0, 0], NAVY, 1.35, 1, 0.8, segs(10, 6)),
      ribbon([[-0.3, -0.4, 0.15], [-0.7, -1.4, 0.3], [-0.95, -2.3, 0.35]], 1.0, 0.3, NAVY_D),
      ribbon([[0.3, -0.4, 0.15], [0.7, -1.3, 0.3], [0.9, -2.15, 0.4]], 1.0, 0.3, NAVY_D),
    ]));
  }
  g.add(meshOf(parts, CS));
  return g;
}
// sleeves: lathed, rows on the colour boundaries (shoulder seam, cuff)
function lathe(profile, colour, seg = 16) {
  const g = new THREE.LatheGeometry(profile.map(([r, y]) => new THREE.Vector2(Math.max(r, 0.001), y)), segs(seg, 8));
  return finish(g, colour);
}
function upperSleeve(r, colour) {
  return lathe([[0, -5.7], [1.35, -5.45], [r * 0.97, -4.9], [r, -3.7], [r, -2.5], [r, -1.3], [r * 0.99, -0.4], [r * 0.95, 0.15], [r * 0.72, 0.65], [0, 0.95]], colour);
}
function foreSleeve(r, colour) {
  return lathe([[0, -5.0], [1.45, -4.85], [r * 0.93, -4.4], [r * 0.95, -3.5], [r * 0.97, -2.5], [r, -1.3], [r, 0.2], [r * 0.7, 0.7], [0, 0.9]], colour);
}
export function sailorUpperArm(side) {
  const s = side === "l" ? 1 : -1, R = 1.92;
  const parts = [upperSleeve(R, (p) => C(p.y > -0.4 ? NAVY : WHITE))];
  // the navy sleeve patch with a white anchor on the outer face (kf2)
  parts.push(sphere(1.05, [s * 1.62, -2.55, 0.15], NAVY, 0.5, 1.5, 1.2, segs(12, 8)));
  const map = (u, v) => V3(s * (1.62 + 0.525 * Math.sqrt(Math.max(0, 1 - (v / 1.575) ** 2 - (u / 1.26) ** 2)) + 0.06), -2.55 + v, 0.15 + u);
  parts.push(...anchorParts(map, 0.95, 0.13, 0xf2f2f6));
  return meshOf(parts, CS);
}
export function sailorForearm() {
  const parts = [foreSleeve(1.9, (p) => C(p.y < -3.5 ? NAVY : WHITE))];
  parts.push(finish(new THREE.TorusGeometry(1.95, 0.42, 5, segs(18, 8)).rotateX(Math.PI / 2).translate(0, -4.15, 0), NAVY));
  parts.push(finish(new THREE.TorusGeometry(1.86, 0.16, 4, segs(18, 8)).rotateX(Math.PI / 2).translate(0, -3.62, 0), WHITE));
  return meshOf(parts, CS);
}
// a booted leg from the hip (y 0) to the sole (y -(len + 0.5)); knee rows every ~0.7
export function humanLeg(len, { trousers, flare = null, boot = 0x1b1b22, cuff = null, bootTop = 3.6 }) {
  const b = -len;
  const prof = [[0, b + 2.4]];
  if (flare) prof.push([2.4, b + 2.7], [2.62, b + 3.4], [2.6, b + 4.4], [2.3, b + 5.1], [2.0, b + 5.6]);
  else prof.push([1.95, b + 2.7], [1.9, b + bootTop + 0.3]);
  const y0 = prof[prof.length - 1][1], y1 = -0.4;
  const n = Math.max(4, Math.ceil((y1 - y0) / 0.7));
  for (let k = 1; k <= n; k++) {
    const y = y0 + ((y1 - y0) * k) / n, t = (y - b) / len;
    prof.push([1.78 + 0.22 * t, y]);
  }
  prof.push([1.9, 0.3], [1.3, 0.85], [0, 1.05]);
  const parts = [lathe(prof, (p) => C(flare && p.y < b + 5.6 ? flare : trousers))];
  parts.push(finish(new THREE.CylinderGeometry(2.22, 2.36, bootTop - 0.2, segs(16, 8), 1, true).translate(0, b + 0.3 + (bootTop - 0.2) / 2, 0.1), boot));
  parts.push(finish(new THREE.CircleGeometry(2.22, segs(16, 8)).rotateX(-Math.PI / 2).translate(0, b + bootTop + 0.1, 0.1), boot));
  if (cuff) parts.push(finish(new THREE.TorusGeometry(2.36, 0.46, 5, segs(18, 8)).rotateX(Math.PI / 2).translate(0, b + bootTop - 0.1, 0.1), cuff));
  parts.push(sphere(2.4, [0, b + 0.9, 1.15], boot, 1.03, 0.62, 1.45, segs(14, 8)));
  parts.push(sphere(1.45, [0, b + 0.5, 3.25], shade(boot, 1.35), 1.3, 0.72, 0.9, segs(10, 6)));
  parts.push(rbox(4.9, 0.6, 7.4, [0, -(len + 0.2), 1.3], 0x2a2018, 0.25));
  return meshOf(parts, CS);
}
export const sailorLeg = (len) => () => humanLeg(len, { trousers: NAVY, flare: 0x26356e });
export function sailorBody(body, opts = {}) {
  return { torso: () => sailorTorso(body, opts), upperArm: sailorUpperArm, forearm: sailorForearm, leg: sailorLeg(body.legLen ?? 11) };
}

// ---------------------------------------------------------------- the reviewer
const G = PAL.green, GD = PAL.greenDark;
export function reviewerTorso(body) {
  const S = torsoShape(body);
  const parts = [];
  const OLIVE = 0x3d5a36;
  parts.push(torsoBase(S, (p) => C(p.y < 0.4 ? OLIVE : p.y > 9.2 ? G : WHITE)));
  // the open collar: white collar points round a skin V at the throat
  parts.push(patch(S, 5, 8, (u, v) => { const y = 8.5 + v * 2.0; return [clampX(S, (u * 2 - 1) * (1.15 + 1.4 * v), y, 0.9), y]; }, 0.1, WHITE));
  parts.push(patch(S, 4, 6, (u, v) => { const y = 8.95 + v * 1.55; return [clampX(S, (u * 2 - 1) * (0.25 + 1.2 * v), y, 0.8), y]; }, 0.17, PAL.skin));
  // the satchel strap: right shoulder (-x) to the left hip, front and back, over the shoulder
  {
    const x0 = -(S.ch - 1.3), x1 = S.ch - 0.5, y0 = 10.3, y1 = 1.0;
    const front = [], back = [];
    for (let k = 0; k <= 10; k++) {
      const t = k / 10, x = x0 + (x1 - x0) * t, y = y0 + (y1 - y0) * t;
      front.push(onSurf(S, clampX(S, x, y, 0.96), y, 0.3));
      back.push(onSurf(S, clampX(S, x, y, 0.96), y, 0.3, true));
    }
    const topY = 10.55, topP = ringPt(S, -Math.PI / 2, topY, 0.35);
    topP.x = x0 * 0.92;
    const pts = [...back.reverse(), topP, ...front];
    parts.push(tube(pts, 0.42, 0x6a4222, { seg: 64, radial: 5 }));
  }
  // a blue badge on the left chest, by the side
  const bp = onSurf(S, 0.74 * S.ch, 7.1, 0.12);
  parts.push(sphere(0.62, bp.toArray(), 0x2a5ad8, 1, 1, 0.45, 8));
  neckAndBelt(S, parts);
  // the satchel on the left hip, with its flap and a gold clasp
  const sx = S.W(1) + 0.95;
  parts.push(rbox(1.9, 4.4, 4.6, [sx, 1.0, 0], 0x7a4c26, 0.55));
  parts.push(rbox(0.6, 2.2, 4.8, [sx + 0.85, 2.2, 0], 0x5a3418, 0.28));
  parts.push(rbox(0.45, 0.75, 0.9, [sx + 1.2, 1.35, 0], PAL.gold, 0.18));
  const g = new THREE.Group();
  // the dark green neckerchief (kf3)
  const NK = 0x145230, NKD = 0x0c3a20;
  const kn = onSurf(S, 0, 7.7, 0.45);
  g.add(tailsGroup("kerchiefTails", kn, [
    sphere(0.9, [0, 0, 0], NK, 1.35, 1, 0.8, segs(10, 6)),
    ribbon([[-0.3, -0.45, 0.12], [-0.6, -1.4, 0.25], [-0.75, -2.4, 0.3]], 1.0, 0.3, NKD),
    ribbon([[0.3, -0.45, 0.12], [0.55, -1.35, 0.25], [0.7, -2.2, 0.35]], 1.0, 0.3, NK),
  ]));
  g.add(meshOf(parts, CS));
  return g;
}
export function reviewerBody(body) {
  return {
    torso: () => reviewerTorso(body),
    upperArm: () => meshOf([upperSleeve(1.9, (p) => C(p.y > -0.4 ? G : WHITE))], CS),
    forearm: () => meshOf([
      foreSleeve(1.88, (p) => C(p.y < -3.5 ? G : p.y < -2.5 ? GD : WHITE)),
      finish(new THREE.TorusGeometry(1.93, 0.4, 5, segs(18, 8)).rotateX(Math.PI / 2).translate(0, -4.15, 0), G),
    ], CS),
    leg: () => humanLeg(body.legLen ?? 11, { trousers: 0x3d5a36, boot: 0x4a2e1a, cuff: 0x5c3a22 }),
  };
}

// ---------------------------------------------------------------- the robot
const R_WHITE = 0xf1f3f7, R_PANEL = 0xc9ced9, R_JOINT = 0x6d7482, R_ACC = 0xb8662e, R_SEAM = 0x9aa1ae, R_EYE = 0x1a78c0;
// a rounded-rectangle loop at height y (a superellipse with a high exponent)
function rrLoop(hw, hd, y, n = 40, p = 7, zc = 0) {
  const pts = [];
  for (let k = 0; k < n; k++) {
    const a = (k / n) * Math.PI * 2, s = Math.sin(a), c = Math.cos(a);
    pts.push(V3(Math.sign(s) * Math.abs(s) ** (2 / p) * hw, y, zc + Math.sign(c) * Math.abs(c) ** (2 / p) * hd));
  }
  return pts;
}
const loopTube = (pts, r, colour) => tube(pts, r, colour, { closed: true, seg: pts.length * 2, radial: 5 });
// a rectangle of seam on a flat face: corners [a, b] in the face plane via map(u, v)
const rectSeam = (map, u0, u1, v0, v1, r, colour) => {
  const path = new THREE.CurvePath();
  const c = [map(u0, v0), map(u1, v0), map(u1, v1), map(u0, v1)];
  for (let i = 0; i < 4; i++) path.add(new THREE.LineCurve3(c[i], c[(i + 1) % 4]));
  return finish(new THREE.TubeGeometry(path, 8, r, 4, true), colour);
};
export function robotTorso(body) {
  const hw = body.chest + 0.5, hd = (body.depth ?? 3) + 0.5;
  const parts = [];
  // the white shell, a waist ring with bolts, the panel seams
  parts.push(rbox(2 * hw, 10.0, 2 * hd, [0, 5.6, 0], R_WHITE, 1.6, 3));
  parts.push(rbox(2 * hw - 1.6, 1.9, 2 * hd - 1.0, [0, -0.25, 0], R_JOINT, 0.7));
  for (let k = 0; k < 10; k++) {
    const a = (k / 10) * Math.PI * 2 + 0.3, s = Math.sin(a), c = Math.cos(a);
    parts.push(sphere(0.38, [Math.sign(s) * Math.abs(s) ** (2 / 7) * (hw - 0.75), -0.25, Math.sign(c) * Math.abs(c) ** (2 / 7) * (hd - 0.45)], R_ACC, 1, 1, 1, 6));
  }
  for (const y of [1.35, 4.3]) parts.push(loopTube(rrLoop(hw + 0.02, hd + 0.02, y), 0.14, R_SEAM));
  // the belly plate seams on the front, side hatches, the back panels
  parts.push(rectSeam((u, v) => V3(u, v, hd + 0.02), -3.2, 3.2, 1.8, 3.9, 0.12, R_SEAM));
  for (const s of [-1, 1]) parts.push(rectSeam((u, v) => V3(s * (hw + 0.02), v, u), -1.7, 1.7, 5.6, 8.9, 0.12, R_SEAM));
  // the backpack
  parts.push(rbox(7.0, 5.8, 1.7, [0, 5.7, -hd - 0.55], R_PANEL, 0.5));
  parts.push(rbox(5.0, 3.9, 1.0, [0, 5.6, -hd - 1.45], R_JOINT, 0.3));
  // the neck and a collar ring
  parts.push(finish(new THREE.CylinderGeometry(1.35, 1.5, 2.4, segs(12, 8)).translate(0, 11.5, 0), R_ACC));
  parts.push(finish(new THREE.TorusGeometry(2.05, 0.55, 5, segs(16, 8)).rotateX(Math.PI / 2).translate(0, 10.75, 0), R_JOINT));
  // the chest light's bezel: a dark frame round the triangle
  const tri = [V3(-2.7, 9.55, hd + 0.03), V3(2.7, 9.55, hd + 0.03), V3(0, 6.45, hd + 0.03)];
  const path = new THREE.CurvePath();
  for (let i = 0; i < 3; i++) path.add(new THREE.LineCurve3(tri[i], tri[(i + 1) % 3]));
  parts.push(finish(new THREE.TubeGeometry(path, 6, 0.2, 4, true), R_JOINT));
  const g = new THREE.Group();
  g.add(meshOf(parts, CS));
  // the glowing chest triangle and the two indicator buttons: unlit, bright (the GLOW
  // material of the voxel set), one small rigid mesh on the torso
  const glowParts = [];
  const sh = new THREE.Shape([new THREE.Vector2(-2.45, 9.35), new THREE.Vector2(0, 6.75), new THREE.Vector2(2.45, 9.35)]);
  glowParts.push(colourize(new THREE.ShapeGeometry(sh).translate(0, 0, hd + 0.06), R_EYE));
  glowParts.push(colourize(new THREE.SphereGeometry(0.55, 8, 6).scale(1, 1, 0.6).translate(-3, 3, hd + 0.1), 0xa03a30));
  glowParts.push(colourize(new THREE.SphereGeometry(0.55, 8, 6).scale(1, 1, 0.6).translate(3, 3, hd + 0.1), 0x3a9a50));
  const gm = new THREE.Mesh(mergeGeometries(glowParts, false).scale(CS, CS, CS), softMaterial(M.GLOW));
  gm.name = "chestLight";
  gm.userData.noSkin = true;
  g.add(gm);
  return g;
}
function colourize(geo, hex) {
  const g = geo.index ? geo.toNonIndexed() : geo;
  for (const k of Object.keys(g.attributes)) if (k !== "position") g.deleteAttribute(k);
  const c = C(hex), n = g.attributes.position.count, col = new Float32Array(n * 3);
  for (let i = 0; i < n; i++) col.set([c.r, c.g, c.b], i * 3);
  g.setAttribute("color", new THREE.BufferAttribute(col, 3));
  return g;
}
export function robotBody(body) {
  const len = body.legLen ?? 10;
  return {
    torso: () => robotTorso(body),
    upperArm: () => meshOf([
      rbox(3.8, 5.0, 3.8, [0, -2.3, 0], R_WHITE, 0.9),
      rbox(3.95, 0.9, 3.95, [0, -0.2, 0], R_JOINT, 0.35),
      sphere(1.8, [0, 0, 0], R_ACC, 1, 1, 1, segs(12, 8)),
    ], CS),
    forearm: () => meshOf([
      rbox(3.6, 4.6, 3.6, [0, -2.45, 0], R_WHITE, 0.85),
      rbox(3.78, 0.9, 3.78, [0, -4.15, 0], R_PANEL, 0.3),
      sphere(1.5, [0, 0, 0], R_ACC, 1, 1, 1, segs(10, 8)),
    ], CS),
    leg: () => {
      const b = -len;
      const n = Math.max(4, Math.ceil((0.4 - (b + 3.4)) / 0.8));
      const prof = [[0, b + 3.0], [1.62, b + 3.4]];
      for (let k = 1; k <= n; k++) prof.push([1.62, b + 3.4 + ((0.4 - (b + 3.4)) * k) / n]);
      prof.push([1.3, 0.9], [0, 1.1]);
      return meshOf([
        lathe(prof, R_JOINT, 12),
        rbox(4.3, 2.0, 4.3, [0, -3.45, 0], R_WHITE, 0.6), // the thigh plate
        rbox(4.0, 0.8, 4.0, [0, b / 2 - 1.0, 0], R_ACC, 0.3), // the knee ring
        sphere(1.2, [0, b / 2 - 1.0, 1.7], R_ACC, 1, 1, 0.8, segs(10, 6)),
        rbox(4.6, 3.4, 4.6, [0, b + 1.9, 0.1], R_WHITE, 0.8), // the boot
        rbox(5.8, 2.1, 6.9, [0, b + 0.6, 0.9], R_WHITE, 0.75), // a chunky foot
        rbox(6.0, 0.7, 7.4, [0, -(len + 0.15), 1.2], R_PANEL, 0.3), // the sole
      ], CS);
    },
  };
}

// ---------------------------------------------------------------- hats (HU)
// the same size, placement and silhouette as the voxel hats (chibi.js sailorCap and
// boxCap: voxel edges at +0.5), so hatLift, HAT_DROP and the tilt pivot still fit
function ringsMesh(rings, P, cols, colour) {
  // rings: [[y, hw], ...] bottom to top; P(hw, a, y) -> Vector3
  return gridSurface(rings.length - 1, cols, (i, j) => P(rings[i][1], (j / cols) * Math.PI * 2, rings[i][0]), colour);
}
const seP = (p, zs, zc = 0) => (hw, a, y) => {
  const s = Math.sin(a), c = Math.cos(a);
  return V3(Math.sign(s) * Math.abs(s) ** (2 / p) * hw, y, zc + Math.sign(c) * Math.abs(c) ** (2 / p) * hw * zs);
};
function hatGroup(parts, ribbonParts, pivot) {
  const g = new THREE.Group();
  const m = meshOf(parts, 1);
  m.castShadow = false;
  g.add(m);
  if (ribbonParts?.length) {
    const r = new THREE.Group();
    r.name = "ribbons";
    r.userData.noSkin = true;
    r.position.copy(pivot);
    const rm = meshOf(ribbonParts.map((geo) => geo.translate(-pivot.x, -pivot.y, -pivot.z)), 1);
    rm.castShadow = false;
    r.add(rm);
    g.add(r);
  }
  g.userData.isHat = true;
  return g;
}
export function sailorCapSmooth({ band = NAVY, top = 0xf4f2f4, emblem = NAVY, studs = 0x3a5ac8, ribbon: withRibbon = true } = {}) {
  const base = headHalfW(11) + 1.6, Y0 = 14, Y1 = 17, TOP = 29, P = 2.6, ZS = 0.93, ZC = 0.6;
  const hwv = (y) => {
    if (y <= Y1) return base;
    const t = (Math.min(y, TOP) - Y1) / (TOP - Y1);
    return base + 1.8 * Math.sin(Math.min(1, t * 1.6) * Math.PI * 0.5) - Math.max(0, t - 0.8) ** 1.5 * 44;
  };
  const E = 0.45; // voxel edge
  const rings = [[13.6, base - 0.1], [13.5, base + 0.3], [14.5, base + E], [15.5, base + E], [16.5, base + E], [17.5, base + E]];
  for (let y = 18; y <= 29.5; y += 0.5) rings.push([y, hwv(y) + E]);
  const hT = hwv(TOP) + E;
  rings.push([29.85, hT * 0.88], [30.1, hT * 0.62], [30.22, hT * 0.3], [30.25, 0]);
  const Pf = seP(P, ZS, ZC);
  const cols = segs(72, 30);
  const parts = [ringsMesh(rings, Pf, cols, (p) => C(p.y < 17.5 ? band : top))];
  const ringAt = (y, grow, n = 60) => {
    const pts = [];
    for (let k = 0; k < n; k++) pts.push(Pf(hwv(y) + E + grow, (k / n) * Math.PI * 2, y));
    return pts;
  };
  // the fold where the crown meets the band, and the band's stitching
  parts.push(tube(ringAt(17.7, 0.12, 60), 0.42, 0xdcdce4, { closed: true, seg: 120, radial: 5 }));
  parts.push(tube(ringAt(16.9, 0.05, 60), 0.16, NAVY_D, { closed: true, seg: 120, radial: 4 }));
  // the blue studs: two staggered rows of twelve (kf2), clear of the anchor
  for (const [row, y] of [[0, 20.5], [1, 24.5]])
    for (let k = 0; k < 12; k++) {
      const a = ((k + 0.5 + row * 0.5) / 12) * Math.PI * 2;
      const aa = Math.atan2(Math.sin(a), Math.cos(a));
      if (Math.abs(aa) < 0.42) continue;
      const p = Pf(hwv(y) + E - 0.1, a, y);
      parts.push(sphere(0.95, p.toArray(), studs, 1, 1, 1, segs(8, 6)));
    }
  // the anchor on the front (9 tall)
  const zf = (x, y) => { const hw = hwv(y) + E; return ZC + ZS * hw * Math.pow(Math.max(0, 1 - (Math.abs(x) / hw) ** P), 1 / P); };
  parts.push(...anchorParts((u, v) => V3(u, 23 + v, zf(u, 23 + v) + 0.25), 4.3, 0.55, emblem));
  const rib = [];
  const bx = Math.round(base) + 1;
  const pivot = V3(bx + 0.2, 15.5, 2.5);
  if (withRibbon) {
    // the navy bow at the side and two tails fluttering out and down (banner, kf2)
    rib.push(rbox(2.9, 3.8, 3.6, [bx + 1, 15.5, 2.5], band, 1.1));
    rib.push(ribbon([[bx + 2.2, 14.2, 3.6], [bx + 3.6, 11.6, 3.8], [bx + 5.2, 9.0, 3.4], [bx + 6.4, 6.2, 3.6]], 2.1, 0.9, band, { taper: 0.75 }));
    rib.push(ribbon([[bx + 1.4, 13.4, 0.8], [bx + 1.6, 10.6, 0.5], [bx + 1.9, 7.8, 0.6], [bx + 2.1, 5.2, 0.4]], 2.0, 0.9, NAVY_D, { taper: 0.75 }));
  }
  return hatGroup(parts, rib, pivot);
}
export function boxCapSmooth({ color = PAL.red, dark = PAL.redDark, bow = null, rivets = true, rivet = 0x2a1a14, height = 9, ridge = false, round = 6, rearBrim = false, dome = 0 } = {}) {
  const base = headHalfW(11) + 1.4, Y0 = 14, TOP = Y0 + height, ZS = 0.92, E = 0.42;
  const hwv = (y) => {
    const yy = Math.min(y, TOP), hw = base + (yy - Y0) * 0.12;
    return dome && yy > TOP - 3 ? hw - (yy - (TOP - 3)) ** 2 * dome : hw;
  };
  const Pf = seP(round, ZS);
  const rings = [[13.6, hwv(14)], [13.5, hwv(14) + E]];
  for (let y = 14.5; y <= TOP + 0.5; y += 1) rings.push([y, hwv(y) + E]);
  const hT = hwv(TOP) + E, yT = TOP + 0.5;
  rings.push([yT + 0.22, hT * 0.9], [yT + 0.34, hT * 0.6], [yT + 0.4, 0]);
  const cols = segs(72, 30);
  const parts = [ringsMesh(rings, Pf, cols, (p) => C(p.y < 15.5 ? dark : color))];
  const loop = (y, off, n = 64) => {
    const pts = [];
    for (let k = 0; k < n; k++) pts.push(Pf(hwv(y) + E + off, (k / n) * Math.PI * 2, y));
    return pts;
  };
  // the top edge seam, and the four panel seams up the crown
  if (!ridge) parts.push(tube(loop(TOP + 0.3, -0.1), 0.34, dark, { closed: true, seg: 128, radial: 5 }));
  for (const a of [0, Math.PI / 2, Math.PI, -Math.PI / 2]) {
    const pts = [];
    for (let y = 15.6; y <= TOP + 0.25; y += 0.5) pts.push(Pf(hwv(y) + E + 0.02, a, y));
    parts.push(tube(pts, 0.22, dark, { seg: 16, radial: 4 }));
  }
  // rivets round the crown
  if (rivets)
    for (const y of dome ? [Y0 + 3] : [Y0 + 3, TOP - 2])
      for (let k = 0; k < 16; k++) {
        const a = ((k + 0.5) / 16) * Math.PI * 2;
        parts.push(sphere(0.52, Pf(hwv(y) + E - 0.05, a, y).toArray(), rivet, 1, 1, 1, segs(8, 6)));
      }
  if (ridge) {
    // a raised lip round the top edge and a ridge over the crown (banner red cap)
    parts.push(tube(loop(TOP + 0.95, 0.55), 0.78, color, { closed: true, seg: 128, radial: 6 }));
    parts.push(tube(loop(TOP + 0.2, 0.55), 0.36, dark, { closed: true, seg: 128, radial: 4 }));
    const L = 2 * ZS * hT * 0.97;
    parts.push(rbox(4.6, 1.8, L, [0, TOP + 1.35, 0], color, 0.75));
    parts.push(tube([[0, TOP + 2.28, -L / 2 + 0.8], [0, TOP + 2.28, L / 2 - 0.8]], 0.3, dark, { seg: 2, radial: 4 }));
  }
  // the brim: a visor over the forehead, its front edge dark
  {
    const bw = Math.round(base - 1), hw15 = hwv(15) + E, U = bw + 0.5;
    const zf = (x) => ZS * hw15 * Math.pow(Math.max(0, 1 - Math.min(1, Math.abs(x) / hw15) ** round), 1 / round);
    const reach = (x) => 5.5 - 3 * Math.min(1, Math.abs(x) / bw) ** 3;
    const nu = segs(28, 12);
    const edge = [];
    // a closed section per column: top-back, top-front, bottom-front, bottom-back
    const sec = (x) => {
      const th = 0.95 * (1 - Math.min(1, Math.abs(x) / U) ** 8) + 0.05, z0 = zf(x) - 0.9, z1 = zf(x) + reach(x);
      return [V3(x, 14.45, z0), V3(x, 14.45 - 0.3, z1), V3(x, 14.45 - 0.3 - th, z1), V3(x, 14.45 - th, z0), V3(x, 14.45, z0)];
    };
    parts.push(gridSurface(4, nu, (i, j) => sec(-U + (2 * U * j) / nu)[i], color));
    for (let j = 0; j <= nu; j++) {
      const s = sec(-U + (2 * U * j) / nu);
      edge.push(s[1].clone().lerp(s[2], 0.5));
    }
    parts.push(tube(edge, 0.55, dark, { seg: nu * 2, radial: 5 }));
  }
  if (rearBrim) {
    // a short brim turned up at the back (banner red cap)
    const bw = Math.round(base - 1), hw = hwv(15) + E;
    const sa = Math.min(0.999, Math.pow(Math.min(1, (0.95 * (bw + 1)) / hw), round / 2));
    const A = Math.asin(sa), na = segs(30, 12);
    const at = (a, off, y) => { const s = Math.sin(a), c = Math.cos(a); return V3(Math.sign(s) * Math.abs(s) ** (2 / round) * (hw + off), y, Math.sign(c) * Math.abs(c) ** (2 / round) * (hw * ZS + off)); };
    const topY = (a) => { const t = Math.abs(Math.sin(a)) ** (2 / round) * hw / (bw + 1); return 16.4 + 1.0 * (1 - sm(0.6, 0.8, t)); };
    const prof = (a) => [[0.2, 13.55], [1.4, 13.45], [2.0, 14.1], [2.1, topY(a)]];
    parts.push(gridSurface(3, na, (i, j) => { const a = Math.PI - A + (2 * A * j) / na; const [o, y] = prof(a)[i]; return at(a, o, y); }, color));
    const bot = [], tp = [];
    for (let j = 0; j <= na; j++) {
      const a = Math.PI - A + (2 * A * j) / na;
      bot.push(at(a, 1.1, 13.5));
      tp.push(at(a, 2.1, topY(a)));
    }
    parts.push(tube(bot, 0.42, dark, { seg: na * 2, radial: 4 }), tube(tp, 0.38, dark, { seg: na * 2, radial: 4 }));
  }
  const rib = [];
  let pivot = V3(0, 0, 0);
  if (bow) {
    // a two-loop bow at the front-right corner, two tails below (banner reviewer)
    const X = -Math.round(base) + 1, Z = Math.round(base * 0.92) + 1, bowD = shade(bow, 0.7);
    pivot = V3(X, Y0 + 4.5, Z + 1);
    rib.push(rbox(3.0, 4.0, 3.0, [X, Y0 + 4.5, Z + 1], bowD, 1.0));
    const loopPts = (cx, cy, cz, ax, ay) => {
      const pts = [];
      for (let k = 0; k < 16; k++) {
        const t = (k / 16) * Math.PI * 2;
        pts.push(V3(cx + Math.cos(t) * 3.4 * ax[0] + Math.sin(t) * 2.5 * ay[0], cy + Math.cos(t) * 3.4 * ax[1] + Math.sin(t) * 2.5 * ay[1], cz + 0.5 + Math.cos(t) * 3.4 * ax[2] + Math.sin(t) * 2.5 * ay[2]));
      }
      return pts;
    };
    rib.push(tube(loopPts(X - 4, Y0 + 6.5, Z, [0.8, 0.4, 0], [-0.3, 0.55, 0.3]), 1.05, bow, { closed: true, seg: 32, radial: 6 }));
    rib.push(tube(loopPts(X - 4, Y0 + 2.5, Z, [0.85, -0.3, 0], [0.3, 0.6, 0.3]), 1.05, bow, { closed: true, seg: 32, radial: 6 }));
    rib.push(ribbon([[X - 0.6, Y0 + 2, Z + 2.5], [X - 1.8, Y0 - 0.8, Z + 2.7], [X - 3.4, Y0 - 4.0, Z + 2.5]], 1.9, 0.8, bow, { taper: 0.7 }));
    rib.push(ribbon([[X + 1, Y0 + 1, Z + 1.2], [X + 1.1, Y0 - 2, Z + 1.3], [X + 1.0, Y0 - 5.2, Z + 1.1]], 1.7, 0.8, bowD, { taper: 0.7 }));
  }
  return hatGroup(parts, rib, pivot);
}
