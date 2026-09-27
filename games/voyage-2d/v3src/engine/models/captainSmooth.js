// Captain v4: the body and costume as AUTHORED smooth geometry (C's technique:
// parametric rings, capsules, lathes, tubes along curves), shaped to the original
// voxel captain's measured silhouette (torsoGrid: chest 7, belly 3, depth 3, skirt 5;
// the tricorn's three-lobed brim; bootLeg; the beard region from beardFine).
// Colours are flat per triangle on (angle, height) grid lines, so panel edges are
// straight and crisp; gold braid, piping, fringe and the scroll emblem are real
// tube geometry. One toon material (vertex colours) so skinning merges to one draw.
// Units: body parts in torso voxels (CS), head extras in head units (HU).
import * as THREE from "three";
import { mergeGeometries } from "three/addons/utils/BufferGeometryUtils.js";
import { CS, HS, hu, headHalfW, frontZ, inSkull, mstDist } from "./chibi.js";
import { PAL } from "../materials.js";

// ---------------------------------------------------------------- material + helpers
let RAMP = null;
function ramp() {
  if (RAMP) return RAMP;
  RAMP = new THREE.DataTexture(new Uint8Array([110, 110, 110, 255, 178, 178, 178, 255, 230, 230, 230, 255, 255, 255, 255, 255]), 4, 1);
  RAMP.minFilter = RAMP.magFilter = THREE.NearestFilter;
  RAMP.needsUpdate = true;
  return RAMP;
}
let MAT = null;
export function smoothMat() {
  if (MAT) return MAT;
  MAT = new THREE.MeshToonMaterial({ vertexColors: true, gradientMap: ramp(), side: THREE.DoubleSide });
  // a faint rim of gold sheen and a very faint voxel-grid texture (style, not steps)
  MAT.onBeforeCompile = (sh) => {
    sh.vertexShader = sh.vertexShader.replace("#include <common>", "#include <common>\nvarying vec3 vObjP;").replace("#include <begin_vertex>", "#include <begin_vertex>\nvObjP = position;");
    sh.fragmentShader = sh.fragmentShader
      .replace("#include <common>", "#include <common>\nvarying vec3 vObjP;")
      .replace(
        "#include <color_fragment>",
        `#include <color_fragment>
        { vec3 q = vObjP / 0.05; vec3 f = abs(fract(q) - 0.5); float e = 0.5 - max(max(f.x, f.y), f.z);
          vec3 fw = fwidth(q); float px = max(max(fw.x, fw.y), fw.z);
          diffuseColor.rgb *= 1.0 - 0.035 * (1.0 - smoothstep(0.0, 0.06 + px, e)) * (1.0 - smoothstep(0.2, 0.5, px)); }`,
      );
  };
  MAT.customProgramCacheKey = () => "captain-smooth";
  return MAT;
}
const C = (hex) => new THREE.Color(hex);
// non-indexed, position/normal/colour only (so every part merges and skins together)
function finish(geo, colour) {
  let g = geo.index ? geo.toNonIndexed() : geo;
  for (const k of Object.keys(g.attributes)) if (!["position", "normal", "color"].includes(k)) g.deleteAttribute(k);
  if (!g.attributes.normal) g.computeVertexNormals();
  if (!g.attributes.color) {
    const n = g.attributes.position.count;
    const col = new Float32Array(n * 3);
    const c = new THREE.Color();
    const p = new THREE.Vector3();
    for (let i = 0; i < n; i += 3) {
      // flat colour per triangle, from its centroid (crisp panel edges)
      p.set(0, 0, 0);
      for (let k = 0; k < 3; k++) p.x += g.attributes.position.getX(i + k) / 3, p.y += g.attributes.position.getY(i + k) / 3, p.z += g.attributes.position.getZ(i + k) / 3;
      c.copy(typeof colour === "function" ? colour(p) : C(colour));
      for (let k = 0; k < 3; k++) col.set([c.r, c.g, c.b], (i + k) * 3);
    }
    g.setAttribute("color", new THREE.BufferAttribute(col, 3));
  }
  return g;
}
function meshOf(parts, scale) {
  const g = mergeGeometries(parts, false);
  g.scale(scale, scale, scale);
  g.computeBoundingSphere();
  const m = new THREE.Mesh(g, smoothMat());
  m.castShadow = m.receiveShadow = true;
  return m;
}
// a tube along points, colour flat
function tube(points, r, colour, { closed = false, seg = 0, radial = 8 } = {}) {
  const curve = new THREE.CatmullRomCurve3(points.map((p) => (p.isVector3 ? p : new THREE.Vector3(...p))), closed, "centripetal");
  const g = new THREE.TubeGeometry(curve, seg || Math.max(8, points.length * 4), r, radial, closed);
  const parts = [finish(g, colour)];
  if (!closed) for (const t of [0, 1]) parts.push(finish(new THREE.SphereGeometry(r, radial, 6).translate(...curve.getPoint(t).toArray()), colour));
  return mergeGeometries(parts, false);
}
const sphere = (r, at, colour, sx = 1, sy = 1, sz = 1, seg = 14) => finish(new THREE.SphereGeometry(r, seg, Math.round(seg * 0.7)).scale(sx, sy, sz).translate(...at), colour);
const capsule = (r, len, at, colour) => finish(new THREE.CapsuleGeometry(r, len, 6, 16).translate(...at), colour);

// ---------------------------------------------------------------- the captain's torso (CS units)
const COAT = 0x1d2648, COAT_D = 0x151b36, GOLD = 0xf1b43c, GOLD_D = 0xc88a24, WHITE = 0xf4efe6, SASH = 0xc8282a, SASH_D = 0x96191c, LEATHER = 0x5a3620;
// the body's measured cross-section: half width w(y), front depth df(y), back db(y)
const W = (y) => (y > 9.2 ? 7.4 * Math.sqrt(Math.max(0, 1 - ((y - 9.2) / 2.1) ** 2)) + 0.001 : y > 5.5 ? 7.5 : 7.4 + 0.1 * Math.max(0, y - 3) / 2.5);
const DB = (y) => (y > 9.2 ? 3.5 * Math.sqrt(Math.max(0, 1 - ((y - 9.2) / 2.1) ** 2)) + 0.001 : 3.5);
const DF = (y) => DB(y) + (y > -0.5 && y < 7.8 ? 3.0 * Math.sin((Math.PI * (y + 0.5)) / 8.3) : 0);
const PEXP = 2.9; // superellipse: a tailored, not boxy, cross-section
function ringPoint(a, y, grow = 0) {
  // a: 0 at the front (+z), increasing toward +x
  const s = Math.sin(a), c = Math.cos(a);
  const w = W(y) + grow, d = (c > 0 ? DF(y) : DB(y)) + grow;
  const ex = 2 / PEXP;
  return new THREE.Vector3(Math.sign(s) * Math.abs(s) ** ex * w, y, Math.sign(c) * Math.abs(c) ** ex * d);
}
// a ring-strip surface from y0 to y1 over angle range, rows x cols
function ringSurface(y0, y1, rows, cols, { a0 = 0, a1 = Math.PI * 2, grow = 0, flare = null, colour }) {
  const pos = [];
  const P = (i, j) => {
    const y = y0 + ((y1 - y0) * i) / rows;
    const a = a0 + ((a1 - a0) * j) / cols;
    const p = ringPoint(a, y, grow);
    if (flare) {
      const k = flare(y);
      p.x *= k;
      p.z *= k;
    }
    return p;
  };
  for (let i = 0; i < rows; i++)
    for (let j = 0; j < cols; j++) {
      const p00 = P(i, j), p01 = P(i, j + 1), p10 = P(i + 1, j), p11 = P(i + 1, j + 1);
      pos.push(...p00.toArray(), ...p01.toArray(), ...p11.toArray(), ...p00.toArray(), ...p11.toArray(), ...p10.toArray());
    }
  const g = new THREE.BufferGeometry();
  g.setAttribute("position", new THREE.Float32BufferAttribute(pos, 3));
  g.computeVertexNormals();
  return finish(g, colour);
}
// the angle at which the surface sits at x (front half)
function angleAtX(x, y, grow = 0) {
  const w = W(y) + grow;
  const s = Math.max(-1, Math.min(1, x / w));
  const sx = Math.sign(s) * Math.abs(s) ** (PEXP / 2);
  return Math.asin(Math.max(-1, Math.min(1, sx)));
}
const onFront = (x, y, grow) => ringPoint(angleAtX(x, y, grow), y, grow);

export function captainTorso() {
  const parts = [];
  // coat body with the white shirt panel and the gold belt buckle, crisp on grid lines
  parts.push(
    ringSurface(-0.2, 11.3, 46, 96, {
      colour: (p) => {
        const front = p.z > 0;
        if (front && Math.abs(p.x) < 1.35 && p.y > 3.1) return C(p.y > 9.5 ? 0xf0e0d0 : WHITE);
        return C(COAT);
      },
    }),
  );
  // skirts: flared, open at the front (a ≈ ±24°), hanging to y -5.4
  const flare = (y) => 1 + Math.max(0, -y) * 0.035;
  parts.push(ringSurface(-5.4, 0.2, 14, 84, { a0: 0.42, a1: Math.PI * 2 - 0.42, grow: 0.25, flare, colour: () => C(COAT) }));
  // sash: a cloth band over the waist with fold stripes
  parts.push(ringSurface(0.9, 3.3, 8, 96, { grow: 0.45, colour: (p) => C(Math.abs(Math.sin(p.y * 2.2 + p.x * 0.5)) > 0.85 ? SASH_D : SASH) }));
  // belt line under the sash hem
  parts.push(ringSurface(0.3, 0.9, 2, 96, { grow: 0.3, colour: () => C(LEATHER) }));
  // gold piping down both front edges, onto the skirt edges, and a lapel braid
  for (const s of [-1, 1]) {
    const pts = [];
    for (let y = 10.6; y >= 0.2; y -= 0.5) pts.push(onFront(s * 1.55, y, 0.28));
    for (let y = -0.2; y >= -5.2; y -= 0.6) {
      const a = s * 0.42;
      const p = ringPoint(a, y, 0.35);
      const k = flare(y);
      pts.push(new THREE.Vector3(p.x * k, y, p.z * k));
    }
    parts.push(tube(pts, 0.42, GOLD));
    const lap = [];
    for (let y = 10.3; y >= 5.2; y -= 0.5) lap.push(onFront(s * (2.6 + (10.3 - y) * 0.12), y, 0.26));
    parts.push(tube(lap, 0.36, GOLD));
    // buttons
    for (const y of [4.6, 6.4, 8.2]) parts.push(sphere(0.55, onFront(s * 4.2, y, 0.35).toArray(), GOLD));
    // pocket flaps on the skirt
    const pf = ringPoint(s * 0.9, -2.2, 0.45);
    parts.push(finish(new THREE.CapsuleGeometry(0.45, 2.4, 4, 8).rotateZ(Math.PI / 2).translate(pf.x * flare(-2.2), -2.2, pf.z * flare(-2.2)), GOLD));
  }
  // hem piping round the skirt
  const hem = [];
  for (let a = 0.42; a <= Math.PI * 2 - 0.42; a += 0.12) {
    const p = ringPoint(a, -5.3, 0.4);
    hem.push(new THREE.Vector3(p.x * flare(-5.3), -5.3, p.z * flare(-5.3)));
  }
  parts.push(tube(hem, 0.4, GOLD));
  // gold buckle on the sash front
  parts.push(finish(new THREE.BoxGeometry(2.0, 1.6, 0.5).translate(0, 2.1, DF(2.1) + 0.8), GOLD));
  // shirt ruffle
  for (const y of [9.2, 8.2, 7.2]) parts.push(sphere(0.7, [0, y, DF(y) + 0.3], WHITE, 1.5, 0.8, 0.6));
  // standing collar behind the neck with a gold edge
  parts.push(ringSurface(10.2, 12.5, 4, 40, { a0: Math.PI * 0.55, a1: Math.PI * 1.45, grow: -3.4, colour: () => C(COAT) }));
  const col = [];
  for (let a = Math.PI * 0.55; a <= Math.PI * 1.45 + 1e-3; a += 0.1) col.push(ringPoint(a, 12.5, -3.4));
  parts.push(tube(col, 0.3, GOLD));
  // neck
  parts.push(capsule(1.4, 1.2, [0, 11.8, 0], PAL.skin));
  // epaulettes: a rounded gold pad, a red underside, and a fringe of gold cords
  for (const s of [-1, 1]) {
    parts.push(sphere(3.0, [s * 7.6, 10.5, 0.2], GOLD, 1.25, 0.42, 1.05, 20));
    parts.push(sphere(2.4, [s * 7.6, 10.95, 0.2], 0xc0302a, 1.2, 0.3, 1.0, 16));
    for (let i = 0; i < 9; i++) {
      const z = -3 + i * 0.8;
      const len = 3.2 + (i % 2) * 0.9;
      const x = s * (10.9 - Math.abs(z - 0.2) * 0.12);
      parts.push(tube([[x, 10.2, z], [x + s * 0.35, 10.2 - len * 0.5, z], [x + s * 0.25, 10.2 - len, z]], 0.26, i % 2 ? GOLD_D : GOLD, { seg: 6, radial: 6 }));
    }
    const edge = [];
    for (let a = 0; a <= Math.PI * 2 + 1e-3; a += 0.3) edge.push([s * 7.6 + Math.cos(a) * 3.7, 10.35, 0.2 + Math.sin(a) * 3.1]);
    parts.push(tube(edge, 0.28, GOLD_D, { closed: true, radial: 6 }));
  }
  const m = meshOf(parts, CS);
  // the sash knot and tails on the right hip: a separate sprung piece (not skinned)
  const tails = new THREE.Group();
  tails.userData.noSkin = true;
  tails.name = "sashTails";
  tails.position.set(-7.9 * CS, 2.2 * CS, 1.8 * CS);
  const tp = [sphere(1.1, [0, 0, 0], SASH_D, 1, 1, 0.8)];
  tp.push(tube([[0, -0.4, 0.2], [-0.5, -2.6, 0.5], [-0.3, -4.6, 0.3]], 0.55, SASH, { seg: 8 }));
  tp.push(tube([[0.2, -0.4, -0.2], [0.6, -2.2, -0.3], [0.4, -3.8, -0.5]], 0.5, SASH_D, { seg: 8 }));
  tails.add(meshOf(tp, CS));
  const g = new THREE.Group();
  g.add(m, tails);
  return g;
}
export function captainUpperArm() {
  const parts = [capsule(2.15, 3.6, [0, -2.0, 0], COAT)];
  return meshOf(parts, CS);
}
export function captainForearm() {
  const parts = [capsule(2.0, 3.2, [0, -1.8, 0], COAT)];
  // a deep gold cuff, flared, with a white lace edge
  parts.push(finish(new THREE.CylinderGeometry(2.35, 2.75, 2.2, 24, 1, true).translate(0, -3.9, 0), GOLD));
  parts.push(finish(new THREE.TorusGeometry(2.55, 0.32, 8, 24).rotateX(Math.PI / 2).translate(0, -2.8, 0), GOLD_D));
  parts.push(finish(new THREE.TorusGeometry(2.2, 0.45, 8, 24).rotateX(Math.PI / 2).translate(0, -5.1, 0), WHITE));
  return meshOf(parts, CS);
}
export function captainLeg() {
  const parts = [];
  // trousers taper to the knee, then a boot with a cuff, a toe cap and a sole
  const prof = [];
  for (let i = 0; i <= 10; i++) {
    const y = -i * 0.8;
    prof.push(new THREE.Vector2(2.05 - i * 0.03, y));
  }
  parts.push(finish(new THREE.LatheGeometry(prof.map((p) => new THREE.Vector2(p.x, p.y)).reverse(), 20), PAL.navyDark));
  parts.push(sphere(2.0, [0, 0, 0], PAL.navyDark, 1, 0.6, 1));
  const B = 0x17171e;
  parts.push(finish(new THREE.CylinderGeometry(2.25, 2.2, 3.4, 20).translate(0, -9.2, 0.1), B));
  parts.push(finish(new THREE.TorusGeometry(2.25, 0.5, 8, 24).rotateX(Math.PI / 2).translate(0, -7.6, 0.1), 0x7a4a26));
  parts.push(sphere(2.3, [0, -10.6, 1.4], B, 1.02, 0.62, 1.45, 18)); // the foot
  parts.push(sphere(1.35, [0, -10.7, 3.3], 0x2a2a34, 1.3, 0.75, 0.9)); // toe cap
  parts.push(finish(new THREE.BoxGeometry(4.4, 0.6, 6.4).translate(0, -11.55, 1.3), 0x2a2018));
  return meshOf(parts, CS);
}

// ---------------------------------------------------------------- head extras (HU)
const HAIR = 0x2b1b12, HAIR_HI = 0x3b2618;
// hair: smooth clumps from the original hair grid (one colour family, no stripes)
function clumps(grid, cell, rMin, rMax, colours, { toHU = (v) => [v.x, v.y, v.z], skip = null, squash = 1 } = {}) {
  const cells = new Map();
  for (const v of grid.map.values()) {
    const [x, y, z] = toHU(v);
    if (skip && skip(x, y, z)) continue;
    const k = [Math.floor(x / cell), Math.floor(y / cell), Math.floor(z / cell)].join(",");
    const c = cells.get(k) || { x: 0, y: 0, z: 0, n: 0 };
    c.x += x;
    c.y += y;
    c.z += z;
    c.n++;
    cells.set(k, c);
  }
  const parts = [];
  let i = 0;
  for (const c of cells.values()) {
    if (c.n < 2) continue;
    const h = ((i++ * 2654435761) >>> 0) / 4294967296;
    const r = rMin + (rMax - rMin) * Math.min(1, c.n / (cell ** 3 * 0.6));
    parts.push(sphere(r, [c.x / c.n, c.y / c.n, c.z / c.n], colours[Math.floor(h * colours.length)], 1, squash, 1, 10));
  }
  return parts;
}
export function captainExtras({ expr, hairG, beardGrid, faceHW, face }) {
  const out = [];
  // hair
  const hair = clumps(hairG, 2.4, 1.3, 2.1, [HAIR, HAIR, HAIR_HI]);
  const hm = meshOf(hair, 1);
  hm.userData.part = "hair";
  out.push(hm);
  // beard: squared, chunky clumps following the jaw (banner), from the beard region
  const bparts = beardGrid ? clumps(beardGrid, 1.35, 0.8, 1.15, [0x2a1a10, 0x33200f, 0x2e1c0e], { toHU: (v) => [hu(v.x), hu(v.y), hu(v.z)] }) : [];
  // moustache: v3's clean 八 arc as a tube, on the face surface
  const open = ["joy", "cheer", "shout", "grin"].includes(expr);
  const mw = open ? faceHW * 0.5 + 0.8 : 3.0;
  for (const s of [-1, 1]) {
    const pts = [];
    for (let i = 0; i <= 16; i++) {
      const t = i / 16, a = t * Math.PI * 0.62;
      const x = 0.4 + ((mw + 0.5) * Math.sin(a)) / Math.sin(Math.PI * 0.62);
      const y = 4.95 - 3.1 * (1 - Math.cos(a)) ** 1.4;
      const z = (frontZ(Math.round(x), Math.round(y)) ?? 7) + 0.9;
      pts.push([s * x, y, z]);
    }
    bparts.push(tube(pts, 0.62 - 0.0, 0x2a1a10, { seg: 24, radial: 7 }));
  }
  // brows: thick, angled (inner ends lower, stern-cheerful), outer ends past the face side (banner)
  const eyeGap = face.eyeGap ?? 14, eyeW = face.eyeW ?? 6, eyeTop = ((face.eyeBot ?? 11) + (face.eyeH ?? 9) - 1) / 2;
  const by = eyeTop + 1.9 + (face.browLift ?? 0);
  for (const s of [-1, 1]) {
    const cx = (eyeGap / 2) * s;
    const pts = [];
    for (let i = 0; i <= 8; i++) {
      const u = i / 8; // 0 inner .. 1 outer
      const x = cx + s * (-eyeW / 2 - 0.8 + u * (eyeW + 3.6));
      const y = by - 0.9 * (1 - u) + (expr === "joy" || expr === "cheer" ? 0.4 * Math.sin(u * Math.PI) : 0);
      const fz = frontZ(Math.round(Math.min(Math.abs(x), 10.5) * Math.sign(x)), Math.round(y));
      pts.push([x, y, (fz ?? 6) + 0.55 - (u > 0.8 ? (u - 0.8) * 3 : 0)]);
    }
    bparts.push(tube(pts, 0.78, 0x1c120c, { seg: 20, radial: 8 }));
  }
  const bm = meshOf(bparts, 1);
  bm.userData.part = "beard";
  out.push(bm);
  // the tricorn
  const hat = tricornSmooth();
  hat.userData.isHat = true;
  out.push(hat);
  return out;
}

// ---------------------------------------------------------------- tricorn (HU)
export function tricornSmooth() {
  const BLK = 0x1a2670, BLK_TOP = 0x141d56;
  const k = headHalfW(11) / 10.2;
  const CR = 10.4 * k;
  // brim radius: three lobes, with a shallower front point (banner)
  const R = (a) => (15.5 + 5.2 * Math.cos(3 * a)) * k * (1 - 0.3 * Math.max(0, Math.cos(a)) ** 4);
  const H = (a) => 6 - 4.5 * Math.cos(3 * a); // how far the wall turns up
  const brimPt = (a, s) => {
    const up = H(a) * Math.pow(Math.max(0, (s - 0.18) / 0.82), 1.7);
    const r = CR * 0.96 + s * (R(a) - CR * 0.96) - up * 0.18;
    return new THREE.Vector3(Math.sin(a) * r, 14 + up, 1 + Math.cos(a) * r);
  };
  const parts = [];
  const pos = [];
  const NA = 120, NS = 14;
  for (let i = 0; i < NA; i++)
    for (let j = 0; j < NS; j++) {
      const a0 = (i / NA) * Math.PI * 2, a1 = ((i + 1) / NA) * Math.PI * 2, s0 = j / NS, s1 = (j + 1) / NS;
      const p00 = brimPt(a0, s0), p01 = brimPt(a1, s0), p10 = brimPt(a0, s1), p11 = brimPt(a1, s1);
      pos.push(...p00.toArray(), ...p10.toArray(), ...p11.toArray(), ...p00.toArray(), ...p11.toArray(), ...p01.toArray());
    }
  const bg = new THREE.BufferGeometry();
  bg.setAttribute("position", new THREE.Float32BufferAttribute(pos, 3));
  bg.computeVertexNormals();
  parts.push(finish(bg, BLK));
  // crown: a lathe, slightly oval
  const prof = [[0, 27.2], [CR * 0.55, 26.8], [CR * 0.86, 25], [CR * 0.98, 22], [CR, 17], [CR * 0.98, 13.6]].map(([x, y]) => new THREE.Vector2(x, y));
  parts.push(finish(new THREE.LatheGeometry(prof, 48).scale(1, 1, 0.92).translate(0, 0, 0.4), (p) => C(p.y > 24.5 ? BLK_TOP : BLK)));
  // gold piping on the brim edge, and an inner braid
  for (const [s, r] of [[1, 0.95], [0.84, 0.5]]) {
    const pts = [];
    for (let i = 0; i < 120; i++) pts.push(brimPt((i / 120) * Math.PI * 2, s).add(new THREE.Vector3(0, s === 1 ? 0.2 : 0.35, 0)));
    parts.push(tube(pts, r, s === 1 ? GOLD : GOLD_D, { closed: true, seg: 240, radial: 8 }));
  }
  // the square-scroll emblem on the two up-turned walls beside the front point
  const KEY = [[-3, 0], [3, 0], [3, 5], [-2, 5], [-2, 1.6], [1.5, 1.6], [1.5, 3.4], [-0.4, 3.4]]; // a greek-key spiral (u, v)
  for (const side of [-1, 1]) {
    const a0 = (side * Math.PI) / 3;
    const pts = KEY.map(([u, v]) => {
      const a = a0 + (u * 0.95) / R(a0);
      const s = 0.62 + v * 0.07;
      const p = brimPt(a, s);
      const n = new THREE.Vector3(Math.sin(a), 0.35, Math.cos(a)).normalize();
      return p.addScaledVector(n, 0.55);
    });
    // straight segments with small rounded joints (crisp, not stepped)
    for (let i = 1; i < pts.length; i++) parts.push(tube([pts[i - 1], pts[i - 1].clone().lerp(pts[i], 0.5), pts[i]], 0.5, GOLD, { seg: 6, radial: 6 }));
  }
  // a gold band round the crown
  const band = [];
  for (let i = 0; i < 60; i++) {
    const a = (i / 60) * Math.PI * 2;
    band.push([Math.sin(a) * CR * 1.01, 15.2, 0.4 + Math.cos(a) * CR * 0.93]);
  }
  parts.push(tube(band, 0.55, GOLD_D, { closed: true, seg: 120, radial: 6 }));
  const m = meshOf(parts, 1);
  m.castShadow = false;
  return m;
}
const GOLD_HAT = GOLD;
export { GOLD_HAT };
