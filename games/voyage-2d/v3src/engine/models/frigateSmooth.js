// p6 (the captain: "drop the voxel construction for the ship, too many faces"): the
// frigate as low-poly smooth meshes in the crew's toon/manga look. The hull is lofted
// from the same plan as the voxel ship (ship-dims: halfW, bottom, deckY, railTop), the
// decks are planes, masts and yards cylinders, sails cloth planes with a few
// subdivisions. The detail lives in the shaders: plank strakes and butt joints, wales,
// gold stripes, gun ports, the lit stern windows, the waterline moss and wear. Every
// contract the voxel ship exposes (spots, spotAt, deckY, guns, railSections, wheel,
// bell, size) is kept, in the same ship-local units.
import * as THREE from "three";
import { mergeGeometries } from "three/addons/utils/BufferGeometryUtils.js";
import { materials, mergeStatic, withCut } from "../materials.js";
import { SHIP_K, V, WL, XQ, XF, deckY, railTop, bottom, xMin, xMax, halfW, HALF_LENGTH, HALF_BEAM, PORTS, GUN, gunLayout, CHASERS } from "./ship-dims.js";
import { MASTS, ropeGeometry, HELM_X } from "./frigate.js";

// the toon ramp shared by every ship material (three bands, like the crew and the kraken)
let RAMP = null;
function ramp() {
  if (RAMP) return RAMP;
  RAMP = new THREE.DataTexture(new Uint8Array([70, 70, 70, 255, 150, 150, 150, 255, 235, 235, 235, 255]), 3, 1);
  RAMP.minFilter = RAMP.magFilter = THREE.NearestFilter;
  RAMP.needsUpdate = true;
  return RAMP;
}
const GLSL_COMMON = /* glsl */ `
  varying vec3 vVox; varying vec3 vNl; varying vec2 vUv2;
  float hsh(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
  vec3 srgb(vec3 c){ return pow(c, vec3(2.2)); }
  float band(float y, float a, float b){ return step(a, y) * step(y, b); }
`;
// a toon material whose base colour comes from a GLSL function of the voxel-space
// position (vVox: x along the ship, y up from the waterline plan, z across)
function shipMat(name, colourGLSL, { side = THREE.FrontSide, emissiveGLSL = "", uniforms = {} } = {}) {
  const m = new THREE.MeshToonMaterial({ color: 0xffffff, gradientMap: ramp(), side });
  m.onBeforeCompile = (sh) => {
    Object.assign(sh.uniforms, uniforms);
    const decl = Object.keys(uniforms).map((k) => `uniform ${typeof uniforms[k].value === "number" ? "float" : "vec2"} ${k};`).join("\n");
    sh.vertexShader = sh.vertexShader
      .replace("#include <common>", "#include <common>\n" + GLSL_COMMON)
      .replace("#include <begin_vertex>", `#include <begin_vertex>\n vec4 wv = modelMatrix * vec4(position, 1.0); vVox = vec3(position.x / ${V.toFixed(4)}, position.y / ${V.toFixed(4)} - ${WL.toFixed(1)} - 0.5, position.z / ${V.toFixed(4)}); vNl = normal; vUv2 = uv;`);
    sh.fragmentShader = sh.fragmentShader
      .replace("#include <common>", "#include <common>\n" + GLSL_COMMON + decl + "\n" + colourGLSL + "\n" + (emissiveGLSL || "vec3 shipGlow(vec3 p, vec3 n, vec2 uv){ return vec3(0.0); }"))
      .replace("vec4 diffuseColor = vec4( diffuse, opacity );", "vec4 diffuseColor = vec4( shipColour(vVox, normalize(vNl), vUv2), opacity );")
      .replace("vec3 totalEmissiveRadiance = emissive;", "vec3 totalEmissiveRadiance = emissive + shipGlow(vVox, normalize(vNl), vUv2);");
  };
  m.customProgramCacheKey = () => "ship-" + name;
  m.name = "ship-" + name;
  return withCut(m);
}
// the ink: an inverted hull a little outside the surface (the crew's and the kraken's outline)
function inkMat(w) {
  const m = new THREE.MeshBasicMaterial({ color: 0x0b0708, side: THREE.BackSide });
  m.onBeforeCompile = (sh) => (sh.vertexShader = sh.vertexShader.replace("#include <begin_vertex>", `vec3 transformed = position + normal * ${w.toFixed(3)};`));
  m.customProgramCacheKey = () => "ship-ink-" + w;
  return withCut(m);
}

const PORT_X = PORTS.map((p) => p.toFixed(1)).join(",");
const HULL_GLSL = /* glsl */ `
  const float PX[7] = float[7](${PORT_X});
  float portMask(vec3 p, out float frame){
    frame = 0.0;
    float m = 0.0;
    for (int i = 0; i < 7; i++) {
      // the upper row in the waist and the stagger below it (ship-dims gunLayout)
      vec2 d = abs(vec2(p.x - PX[i], p.y + 4.5));
      if (max(d.x, d.y) < 2.6) { m = step(max(d.x, d.y), 1.9); frame = 1.0 - m; }
      float lx = PX[i] + 6.0;
      if (lx <= 30.0 && lx >= -48.0) {
        d = abs(vec2(p.x - lx, p.y + 12.5));
        if (max(d.x, d.y) < 2.6) { m = step(max(d.x, d.y), 1.9); frame = 1.0 - m; }
      }
    }
    return m;
  }
  float railTopAt(float x){ return x < ${XQ.toFixed(1)} ? 15.0 : x > ${XF.toFixed(1)} ? 11.0 : 4.0; }
  vec3 shipColour(vec3 p, vec3 n, vec2 uv){
    float strake = floor((p.y + 40.0) / 2.0);
    float len = 5.0 + floor(hsh(vec2(strake, 7.0)) * 5.0);
    float xs = p.x + strake * 3.0 + 400.0;
    float plank = floor(xs / len);
    float tone = hsh(vec2(plank, strake + (p.z > 0.0 ? 5.0 : 6.0)));
    float h = (p.y + ${WL.toFixed(1)}) / ${(WL + 16).toFixed(1)};
    vec3 c = p.y < -${(WL - 1).toFixed(1)} ? vec3(0.37, 0.21, 0.125) : h < 0.35 ? vec3(0.49, 0.28, 0.157) : h < 0.75 ? vec3(0.60, 0.376, 0.227) : vec3(0.69, 0.478, 0.29);
    c *= 0.86 + tone * 0.26;
    if (tone > 0.94) c = vec3(0.6, 0.54, 0.47); // a grey, bleached plank
    // the seam under each strake and the butt joints (the plank lines)
    c *= mix(0.7, 1.0, smoothstep(0.0, 0.16, fract((p.y + 40.0) / 2.0)));
    c *= mix(0.6, 1.0, smoothstep(0.0, 0.12, fract(xs / len) * len));
    // the wales (black) and the gold stripes; red lids round the gun ports
    float rt = railTopAt(p.x);
    if (band(p.y, -9.3, -7.6) > 0.5) c = vec3(0.09, 0.07, 0.06) * (0.9 + tone * 0.2);
    if (band(p.y, 0.6, 1.5) > 0.5 || band(p.y, rt - 1.7, rt - 1.0) > 0.5) c = vec3(0.93, 0.71, 0.25);
    if (band(p.y, -1.8, 0.6) > 0.5) c = vec3(0.13, 0.17, 0.42) * (0.9 + tone * 0.2);
    float fr; float pm = portMask(p, fr);
    if (abs(n.x) < 0.8) { if (pm > 0.5) c = vec3(0.03, 0.025, 0.03); else if (fr > 0.5) c = vec3(0.72, 0.12, 0.08); }
    // the waterline: moss and weed; salt streaks under the rail; wear toward the keel
    if (abs(p.y + ${WL.toFixed(1)}) < 1.6 && hsh(floor(p.xz * 0.7)) < 0.5) c = mix(c, vec3(0.3, 0.36, 0.2), 0.8);
    if (hsh(vec2(floor(p.x), 11.0 + step(0.0, p.z))) < 0.05 && h > 0.25) c = mix(c, vec3(0.78, 0.7, 0.58), 0.45);
    c *= mix(0.72, 1.0, smoothstep(-26.0, -10.0, p.y));
    // the transom: carved gold frames round the gallery
    if (n.x < -0.7 && p.y > 2.0) c = mix(vec3(0.42, 0.2, 0.1), vec3(0.93, 0.71, 0.25), step(0.7, fract(p.y / 3.0)));
    return srgb(c);
  }`;
const HULL_GLOW = /* glsl */ `
  vec3 shipGlow(vec3 p, vec3 n, vec2 uv){
    // the stern gallery: two rows of lit windows across the transom
    if (n.x > -0.7 || p.y < 3.0) return vec3(0.0);
    vec2 g = vec2(fract((p.z + 1.5) / 5.0), p.y);
    float win = step(0.2, g.x) * step(g.x, 0.8) * (band(p.y, 4.0, 7.0) + band(p.y, 8.5, 11.5));
    float bar = step(abs(g.x - 0.5), 0.05) + step(abs(fract(p.y / 1.5) - 0.5), 0.08);
    return win * (1.0 - min(1.0, bar)) * vec3(2.4, 1.3, 0.45);
  }`;
const DECK_GLSL = /* glsl */ `
  vec3 shipColour(vec3 p, vec3 n, vec2 uv){
    if (n.y < 0.5) {
      // a bulkhead: dark planks with doors
      vec3 c = vec3(0.42, 0.25, 0.14) * (0.85 + hsh(vec2(floor(p.z / 2.0), 3.0)) * 0.3);
      c *= mix(0.7, 1.0, smoothstep(0.0, 0.14, fract(p.z / 2.0)));
      if (abs(p.z) < 2.5 && p.y < deckTop(p.x) - 2.0) c = vec3(0.25, 0.13, 0.07);
      return srgb(c);
    }
    // deck planks run fore and aft: a seam every 2 voxels across, staggered butt joints
    float row = floor((p.z + 40.0) / 2.0);
    float len = 9.0 + floor(hsh(vec2(row, 2.0)) * 6.0);
    float xs = p.x + row * 5.0 + 400.0;
    float tone = hsh(vec2(floor(xs / len), row));
    vec3 c = mix(vec3(0.66, 0.47, 0.3), vec3(0.78, 0.6, 0.4), tone);
    c *= mix(0.62, 1.0, smoothstep(0.0, 0.12, fract((p.z + 40.0) / 2.0)));
    c *= mix(0.65, 1.0, smoothstep(0.0, 0.1, fract(xs / len) * len));
    // treenails, a darker worn path down the middle
    c *= 1.0 - 0.1 * smoothstep(6.0, 0.0, abs(p.z));
    return srgb(c);
  }
  float deckTop(float x){ return x < ${XQ.toFixed(1)} ? 11.0 : x > ${XF.toFixed(1)} ? 7.0 : 0.0; }`;
const WOOD_GLSL = /* glsl */ `
  vec3 shipColour(vec3 p, vec3 n, vec2 uv){
    // masts, yards, spars: wood with iron bands every 12 voxels
    vec3 c = mix(vec3(0.5, 0.33, 0.19), vec3(0.56, 0.37, 0.21), step(0.5, fract(p.y / 2.0)));
    if (fract(p.y / 12.0) < 0.14 && abs(n.y) < 0.6 && uv.y > -1.0) c = vec3(0.2, 0.2, 0.23);
    return srgb(c);
  }`;
const SAIL_GLSL = /* glsl */ `
  vec3 shipColour(vec3 p, vec3 n, vec2 uv){
    // cream canvas: panel seams, a reef band, the bolt rope round the edge, a shade on the leeches
    vec3 c = vec3(0.96, 0.92, 0.82) * (0.97 + hsh(floor(uv * vec2(12.0, 8.0))) * 0.05);
    float seams = 1.0 - smoothstep(0.0, 0.03, abs(fract(uv.x * uPanels) - 0.5) - 0.47);
    c = mix(c, vec3(0.85, 0.78, 0.63), seams * 0.8);
    if (abs(uv.y - 0.82) < 0.018) c = vec3(0.85, 0.77, 0.61);
    float e = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
    if (e < 0.02) c = vec3(0.79, 0.68, 0.49);
    else if (uv.x < 0.08 || uv.x > 0.92) c *= 0.93;
    return srgb(c);
  }`;
const NAVY_GLSL = /* glsl */ `
  // the white ship's wheel on the navy flag-sail (kf1): rim, hub, eight spokes, knobs
  bool wheelEmblem(vec2 q, float R){
    float r = length(q);
    if (r >= R - 1.3 && r <= R + 0.8) return true;
    if (r <= 2.6) return r >= 1.2;
    float a = atan(q.y, q.x);
    float sec = floor(a / 0.7854 + 0.5) * 0.7854;
    if (r > 2.4 && r < R + 3.2 && abs(sin(a - sec) * r) <= 0.95) return true;
    return length(q - vec2(cos(sec), sin(sec)) * (R + 4.0)) <= 1.5;
  }
  vec3 shipColour(vec3 p, vec3 n, vec2 uv){
    vec2 q = (uv - 0.5) * uEm;
    vec3 c = mod(floor(uv.x * uEm.x / 6.0), 2.0) > 0.5 ? vec3(0.13, 0.2, 0.6) : vec3(0.12, 0.18, 0.56);
    if (wheelEmblem(q, min(uEm.x, uEm.y) * 0.3)) c = vec3(0.95, 0.95, 0.97);
    float e = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
    if (e < 0.02) c = vec3(0.08, 0.12, 0.42);
    return srgb(c);
  }`;
const IRON_GLSL = /* glsl */ `
  vec3 shipColour(vec3 p, vec3 n, vec2 uv){ return srgb(vec3(0.27, 0.28, 0.31)); }`;
const GOLD_GLSL = /* glsl */ `
  vec3 shipColour(vec3 p, vec3 n, vec2 uv){ return srgb(vec3(0.9, 0.68, 0.24)); }`;
const DARK_GLSL = /* glsl */ `
  vec3 shipColour(vec3 p, vec3 n, vec2 uv){ return srgb(vec3(0.36, 0.2, 0.1)); }`;

let MATS = null;
function mats() {
  if (MATS) return MATS;
  MATS = {
    hull: shipMat("hull", HULL_GLSL, { side: THREE.DoubleSide, emissiveGLSL: HULL_GLOW }),
    deck: shipMat("deck", DECK_GLSL, { side: THREE.DoubleSide }),
    wood: shipMat("wood", WOOD_GLSL),
    dark: shipMat("dark", DARK_GLSL, { side: THREE.DoubleSide }),
    iron: shipMat("iron", IRON_GLSL),
    gold: shipMat("gold", GOLD_GLSL),
    glow: withCut(new THREE.MeshBasicMaterial({ color: new THREE.Color(3.0, 1.9, 0.8) })),
    navy: null, // per sail (its size)
    ink: inkMat(0.07),
  };
  return MATS;
}
const sailMat = (panels) => shipMat("sail" + panels, SAIL_GLSL.replace(/uPanels/g, panels.toFixed(1)), { side: THREE.DoubleSide });

// ------------------------------------------------------------------ the hull (lofted)
function hullGeometry(nx, ny) {
  // stations along x (with the quarterdeck and forecastle breaks kept sharp), each a
  // section from the port rail down round the keel and up to the starboard rail
  const x0 = -68, x1 = xMax(railTop(60)) + 0.5;
  const xs = [];
  for (let i = 0; i <= nx; i++) xs.push(x0 + ((x1 - x0) * i) / nx);
  for (const b of [XQ, XF]) xs.push(b - 0.02, b + 0.02);
  xs.sort((a, b) => a - b);
  const pos = [], uv = [], idx = [];
  const cols = 2 * ny + 1;
  for (const x of xs) {
    const yb = bottom(x), yt = railTop(x);
    for (let j = 0; j < cols; j++) {
      const s = j < ny ? 1 : -1; // port first, then starboard
      const t = j < ny ? 1 - j / ny : (j - ny) / ny; // 1 at the rail, 0 at the keel
      const tt = Math.pow(t, 0.8);
      const y = yb + (yt - yb) * tt;
      const w = Math.max(0, halfW(x, Math.min(y, 14)));
      pos.push(x * V, (y + WL) * V + V / 2, s * w * V);
      uv.push((x - x0) / (x1 - x0), j / (cols - 1));
    }
  }
  for (let i = 0; i < xs.length - 1; i++)
    for (let j = 0; j < cols - 1; j++) {
      const a = i * cols + j, b = a + cols;
      idx.push(a, a + 1, b, b, a + 1, b + 1);
    }
  // the transom: a fan across the stern section
  const base = pos.length / 3;
  const xT = xs[0];
  const cy = (bottom(xT) + railTop(xT)) / 2;
  pos.push(xT * V, (cy + WL) * V + V / 2, 0);
  uv.push(0, 0.5);
  for (let j = 0; j < cols; j++) pos.push(pos[j * 3], pos[j * 3 + 1], pos[j * 3 + 2]), uv.push(0, j / (cols - 1));
  for (let j = 0; j < cols - 1; j++) idx.push(base, base + 1 + j + 1, base + 1 + j);
  const g = new THREE.BufferGeometry();
  g.setAttribute("position", new THREE.Float32BufferAttribute(pos, 3));
  g.setAttribute("uv", new THREE.Float32BufferAttribute(uv, 2));
  g.setIndex(idx);
  g.computeVertexNormals();
  return g;
}
// the cap rail along the top of the bulwarks (a flat strip, so the rail has a thickness)
function capRailGeometry(n) {
  const geos = [];
  for (const s of [-1, 1]) {
    const pos = [], uv = [], idx = [];
    const xsR = [];
    for (let i = 0; i <= n; i++) xsR.push(-68 + (137 * i) / n);
    for (const b of [XQ, XF]) xsR.push(b - 0.02, b + 0.02);
    xsR.sort((a, b) => a - b);
    for (const x of xsR) {
      const y = railTop(x), w = Math.max(0, halfW(x, Math.min(y, 14)));
      const Y = (y + WL) * V + V / 2 + 0.06;
      pos.push(x * V, Y, s * (w + 0.4) * V, x * V, Y, s * Math.max(0, w - 1.2) * V);
      uv.push(0, 0, 0, 1);
    }
    for (let i = 0; i < xsR.length - 1; i++) {
      const a = i * 2;
      idx.push(a, a + 1, a + 2, a + 2, a + 1, a + 3);
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute("position", new THREE.Float32BufferAttribute(pos, 3));
    g.setAttribute("uv", new THREE.Float32BufferAttribute(uv, 2));
    g.setIndex(idx);
    g.computeVertexNormals();
    geos.push(g);
  }
  return mergeGeometries(geos);
}
// the decks: plank planes inside the bulwarks, and the break bulkheads
function deckGeometry(n) {
  const geos = [];
  const strip = (xa, xb, y) => {
    const pos = [], uv = [], idx = [];
    for (let i = 0; i <= n; i++) {
      const x = xa + ((xb - xa) * i) / n;
      const w = Math.max(0.5, halfW(x, y + 1) + 0.3);
      const Y = (y + WL) * V + V / 2;
      pos.push(x * V, Y, w * V, x * V, Y, -w * V);
      uv.push(i / n, 0, i / n, 1);
    }
    for (let i = 0; i < n; i++) {
      const a = i * 2;
      idx.push(a, a + 2, a + 1, a + 1, a + 2, a + 3);
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute("position", new THREE.Float32BufferAttribute(pos, 3));
    g.setAttribute("uv", new THREE.Float32BufferAttribute(uv, 2));
    g.setIndex(idx);
    g.computeVertexNormals();
    geos.push(g);
  };
  strip(-67.8, XQ, 11);
  strip(XQ, XF, 0);
  strip(XF, xMax(7) - 0.5, 7);
  // bulkheads at the breaks: the quarterdeck's face (0 -> 11) and the forecastle's (0 -> 7)
  for (const [x, top] of [[XQ, 11], [XF, 7]]) {
    const w = halfW(x, 2) + 0.3;
    const g = new THREE.PlaneGeometry(2 * w * V, top * V, 2, 1);
    g.rotateY(Math.PI / 2);
    g.translate(x * V, (top / 2 + WL) * V + V / 2, 0);
    geos.push(g);
  }
  // the breast rails at the breaks, over the bulkheads (a low balustrade)
  for (const [x, top, h] of [[XQ, 11, 3], [XF, 7, 3]]) {
    const w = halfW(x, top + 1);
    const g = new THREE.BoxGeometry(0.6 * V, h * V, 2 * w * V);
    g.translate(x * V + (x === XQ ? 0 : 0), (top + h / 2 + WL) * V + V / 2, 0);
    geos.push(g.toNonIndexed().index ? g : g);
  }
  return mergeGeometries(geos.map((g) => (g.index ? g : g)));
}
// a tapered cylinder between two points (voxel space), for spars
function spar(a, b, r0, r1, seg) {
  const A = new THREE.Vector3(a[0] * V, (a[1] + WL) * V + V / 2, a[2] * V), B = new THREE.Vector3(b[0] * V, (b[1] + WL) * V + V / 2, b[2] * V);
  const d = B.clone().sub(A), len = d.length();
  const g = new THREE.CylinderGeometry(r1 * V, r0 * V, len, seg, 1, false);
  g.translate(0, len / 2, 0);
  g.applyQuaternion(new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 1, 0), d.normalize()));
  g.translate(A.x, A.y, A.z);
  return g;
}
// a square sail: a cloth plane with a belly (the voxel sail's own formula), authored
// with the mast at x = 0 so the set is braced round the mast
function sailGeometry(yTop, yBot, halfTop, belly, sx, sy) {
  const H = yTop - yBot, halfBot = halfTop * 1.08;
  const g = new THREE.PlaneGeometry(1, 1, sx, sy);
  const p = g.attributes.position, uv = g.attributes.uv;
  for (let i = 0; i < p.count; i++) {
    const u = uv.getX(i), v = 1 - uv.getY(i); // v 0 at the head
    const half = halfTop + (halfBot - halfTop) * v;
    const z = (u - 0.5) * 2 * half;
    const y = yTop - v * H;
    const bz = Math.pow(Math.sin(Math.PI * u), 0.75), bv = 0.25 + 0.75 * Math.sin(Math.PI * Math.min(1, v * 0.95 + 0.05));
    const x = 4 + belly * bz * bv;
    p.setXYZ(i, x * V, (y + WL) * V + V / 2, z * V);
  }
  g.computeVertexNormals();
  return g;
}
function jibGeometry(sx, sy) {
  const x0 = 60, y0 = 66, x1 = 88, y1 = 25, yb = 19;
  const g = new THREE.PlaneGeometry(1, 1, sx, sy);
  const p = g.attributes.position, uv = g.attributes.uv;
  for (let i = 0; i < p.count; i++) {
    const k = uv.getX(i), s = uv.getY(i);
    const top = y0 + (y1 - y0) * k, bot = yb + k * (y1 - yb) * 0.9;
    const y = bot + (top - bot) * s;
    const bz = Math.sin(Math.PI * k) * 3 * Math.sin(Math.PI * Math.min(1, (1 - s) * 0.8 + 0.1));
    p.setXYZ(i, (x0 + (x1 - x0) * k) * V, (y + WL) * V + V / 2, bz * V);
  }
  g.computeVertexNormals();
  return g;
}

// ------------------------------------------------------------------ small fittings
function cannonGeo(len, seg) {
  // barrel along +z from the breech (0) to the muzzle (len), in voxels of the gun's scale
  const geos = [];
  const b = new THREE.CylinderGeometry(1.45, 1.9, len, seg, 1);
  b.rotateX(Math.PI / 2).translate(0, 0, len / 2);
  geos.push(b);
  const m = new THREE.CylinderGeometry(2.0, 2.0, 1.2, seg, 1);
  m.rotateX(Math.PI / 2).translate(0, 0, len - 0.4);
  geos.push(m);
  const k = new THREE.SphereGeometry(1.4, seg, 4);
  k.translate(0, 0, -0.9);
  geos.push(k);
  return mergeGeometries(geos.map((g) => g.toNonIndexed()));
}
function lanternGroup(scale, M) {
  const g = new THREE.Group();
  const body = new THREE.Mesh(new THREE.CylinderGeometry(3 * scale, 3 * scale, 6 * scale, 6), M.glow);
  const cap = new THREE.Mesh(new THREE.ConeGeometry(3.8 * scale, 3 * scale, 6), M.iron);
  cap.position.y = 4.5 * scale;
  const foot = new THREE.Mesh(new THREE.CylinderGeometry(3.4 * scale, 3.4 * scale, 1 * scale, 6), M.iron);
  foot.position.y = -3.4 * scale;
  g.add(body, cap, foot);
  return g;
}
function wheelGroup(scale, M) {
  // crew scale (0.05 per unit): rim, hub, eight spokes with handles; axle along z
  const g = new THREE.Group();
  const R = 9 * scale;
  g.add(new THREE.Mesh(new THREE.TorusGeometry(R, 0.9 * scale, 5, 20), M.wood));
  g.add(new THREE.Mesh(new THREE.CylinderGeometry(1.8 * scale, 1.8 * scale, 2 * scale, 8).rotateX(Math.PI / 2), M.gold));
  for (let i = 0; i < 8; i++) {
    const s = new THREE.Mesh(new THREE.CylinderGeometry(0.5 * scale, 0.6 * scale, R + 4 * scale, 5), M.wood);
    s.geometry.translate(0, (R + 4 * scale) / 2, 0);
    s.rotation.z = (i / 8) * Math.PI * 2;
    g.add(s);
  }
  return g;
}

// ------------------------------------------------------------------ assembly
export function buildFrigateSmooth({ lanternLights = true, detail = true, brace = 0.42, lod = "high", masts = [0, 1, 2] } = {}) {
  const M = mats();
  const lo = lod === "low" || lod === "lowest";
  const seg = lod === "lowest" ? 5 : lo ? 6 : 10;
  const root = new THREE.Group();
  root.name = "frigate";
  const hullG = hullGeometry(lod === "lowest" ? 30 : lo ? 40 : 72, lod === "lowest" ? 6 : lo ? 8 : 14);
  const hull = new THREE.Mesh(hullG, M.hull);
  hull.name = "hull";
  hull.castShadow = hull.receiveShadow = true;
  root.add(hull);
  const ink = new THREE.Mesh(hullG, M.ink);
  root.add(ink);
  root.add(new THREE.Mesh(capRailGeometry(lo ? 30 : 60), M.dark));
  const deck = new THREE.Mesh(deckGeometry(lo ? 10 : 24), M.deck);
  deck.receiveShadow = true;
  root.add(deck);

  // masts, tops, the crow's nest, yards, sails
  const W = (x, y, z) => new THREE.Vector3(x * V, (y + WL) * V + V / 2, z * V);
  const woods = [], irons = [], golds = [];
  MASTS.forEach((m, mi) => {
    if (!masts.includes(mi)) return;
    const y0 = deckY(m.x);
    woods.push(spar([m.x, y0 - 2, 0], [m.x, m.top, 0], m.r, m.r * 0.55, seg));
    golds.push(new THREE.SphereGeometry(1.5 * V, seg, 4).translate(m.x * V, (m.top + 4 + WL) * V, 0));
    woods.push(new THREE.BoxGeometry(4 * V, 2 * V, 4 * V).translate(m.x * V, (m.top + 1.5 + WL) * V + V / 2, 0));
    if (m.top1) woods.push(new THREE.CylinderGeometry(8 * V, 7 * V, 1.2 * V, seg + 2).translate(m.x * V, (m.top1 + WL) * V + V / 2, 0));
    if (m.nest) {
      const n = new THREE.CylinderGeometry(6.8 * V, 6.3 * V, 7 * V, seg + 4, 1, true);
      n.translate(m.x * V, (m.nest + 3.5 + WL) * V + V / 2, 0);
      root.add(new THREE.Mesh(n, M.dark));
      woods.push(new THREE.CylinderGeometry(6.8 * V, 6.8 * V, 0.8 * V, seg + 4).translate(m.x * V, (m.nest + WL) * V + V / 2, 0));
    }
    // the sails and yards of this mast, braced round it
    const set = new THREE.Group();
    set.position.x = m.x * V;
    set.rotation.y = brace;
    const ys = m.yards;
    for (let i = 0; i < ys.length; i++) {
      const [yy, half] = ys[i];
      const below = i === 0 ? deckY(m.x) + (mi === 1 ? 22 : mi === 0 ? 11 : 16) : ys[i - 1][0] + 4;
      const navy = mi === 0 && i === 0;
      const sg = sailGeometry(yy - 1, below, half - 1, navy ? 9 : 8 - i, lo ? 4 : 8, lo ? 3 : 6);
      let mat;
      if (navy) {
        mat = shipMat("navy", NAVY_GLSL, { side: THREE.DoubleSide, uniforms: { uEm: { value: new THREE.Vector2(2 * (half - 1), yy - 1 - below) } } });
      } else mat = sailMat(Math.max(2, Math.round((2 * half) / 6)));
      const sail = new THREE.Mesh(sg, mat);
      sail.castShadow = true;
      set.add(sail);
      const yard = new THREE.Mesh(spar([3, yy, -half], [3, yy, half], 1.0, 1.0, seg - 2).translate(0, 0, 0), M.wood);
      yard.position.x = -m.x * V + m.x * V; // authored at the mast (x 0 inside the set)
      yard.geometry.translate(-0 * V, 0, 0);
      set.add(yard);
    }
    root.add(set);
  });
  // bowsprit and jib boom, with iron bands
  woods.push(spar([62, 10, 0], [96, 26, 0], 1.3, 0.8, seg));
  if (masts.includes(0) || masts.length === 1) {
    const jib = new THREE.Mesh(jibGeometry(lo ? 3 : 6, lo ? 3 : 5), sailMat(4));
    root.add(jib);
  }
  root.add(new THREE.Mesh(mergeGeometries(woods.map((g) => g.toNonIndexed())), M.wood));
  root.add(new THREE.Mesh(mergeGeometries(golds.map((g) => g.toNonIndexed())), M.gold));
  const ropes = new THREE.Mesh(ropeGeometry(brace, masts), materials.rope);
  root.add(ropes);

  const guns = [];
  let wheel = null,
    bell = null;
  if (detail) {
    // cannons in every port, pointing outboard (ship-dims gunLayout)
    const cg = cannonGeo(GUN.len, seg);
    const barrels = [];
    for (const g of gunLayout()) {
      const b = cg.clone();
      b.scale(GUN.scale, GUN.scale, GUN.scale);
      if (g.side < 0) b.rotateY(Math.PI);
      const p = W(g.x, g.y, g.side * g.breech);
      p.y -= V / 2;
      b.translate(p.x, p.y, p.z);
      barrels.push(b);
      if (g.upper) guns.push({ pos: W(g.x, g.y, g.side * (g.muzzle + 0.5)), side: g.side });
    }
    // chase guns on low carriages over the bow rail and the taffrail
    const carriages = [];
    for (const ch of CHASERS) {
      const b = cannonGeo(18, seg);
      b.scale(ch.scale, ch.scale, ch.scale);
      b.rotateY(ch.yaw > 0 ? Math.PI / 2 - Math.sign(ch.z) * 0.12 : -Math.PI / 2 + Math.sign(ch.z) * 0.12);
      const p = W(ch.x, deckY(ch.x), ch.z);
      p.y += 4 * ch.scale;
      b.translate(p.x, p.y, p.z);
      barrels.push(b);
      carriages.push(new THREE.BoxGeometry(6 * ch.scale, 3 * ch.scale, 6 * ch.scale).translate(p.x, p.y - 2.2 * ch.scale, p.z).toNonIndexed());
    }
    root.add(new THREE.Mesh(mergeGeometries(barrels), M.iron));
    root.add(new THREE.Mesh(mergeGeometries(carriages), M.dark));
    // anchors on both bows, chains from the hawse holes
    const anchors = [];
    for (const s of [1, -1]) {
      const hw = halfW(50, -2), at = W(50, -3, s * (hw + 2.5)), k = 0.1 * SHIP_K;
      anchors.push(new THREE.CylinderGeometry(0.9 * k, 0.9 * k, 22 * k, 6).translate(at.x, at.y, at.z).toNonIndexed());
      anchors.push(new THREE.CylinderGeometry(0.7 * k, 0.7 * k, 12 * k, 6).rotateX(Math.PI / 2).translate(at.x, at.y + 9 * k, at.z).toNonIndexed());
      const arm = new THREE.TorusGeometry(7 * k, 0.9 * k, 4, 10, Math.PI);
      arm.rotateZ(Math.PI).translate(at.x, at.y - 4 * k, at.z);
      anchors.push(arm.toNonIndexed());
      const hw2 = halfW(57, 4);
      const a = W(57, 4, s * (hw2 + 2)), b = W(50, 1.8, s * (hw + 2.5));
      const mid = a.clone().lerp(b, 0.5);
      mid.y -= 0.9 * SHIP_K;
      anchors.push(new THREE.TubeGeometry(new THREE.QuadraticBezierCurve3(a, mid, b), 8, 0.12 * SHIP_K, 4).toNonIndexed());
    }
    root.add(new THREE.Mesh(mergeGeometries(anchors), M.iron));
    // the ship's wheel (it spins in the order ritual: dynamic), a binnacle pedestal
    const helm = new THREE.Group();
    helm.userData.dynamic = true;
    helm.position.copy(W(HELM_X, 11, 0));
    helm.position.y += 0.95;
    helm.rotation.y = Math.PI / 2;
    helm.add(wheelGroup(0.05, M));
    root.add(helm);
    wheel = helm.children[0];
    root.add(new THREE.Mesh(new THREE.BoxGeometry(0.6, 0.8, 0.6).translate(...W(HELM_X + 1.5, 12, 0).toArray()).translate(0, 0.2, 0), M.dark));
    // the bell on its gallows
    const gal = W(-50, 11, -9);
    root.add(new THREE.Mesh(mergeGeometries([new THREE.BoxGeometry(0.06, 0.7, 0.06).translate(gal.x, gal.y + 0.35, gal.z).toNonIndexed(), new THREE.BoxGeometry(0.34, 0.05, 0.05).translate(gal.x + 0.15, gal.y + 0.68, gal.z).toNonIndexed()]), M.dark));
    bell = new THREE.Group();
    bell.userData.dynamic = true;
    const bellG = new THREE.LatheGeometry([new THREE.Vector2(0.02, 0), new THREE.Vector2(0.08, -0.02), new THREE.Vector2(0.1, -0.2), new THREE.Vector2(0.14, -0.34), new THREE.Vector2(0.02, -0.34)], 10);
    bell.add(new THREE.Mesh(bellG, M.gold));
    bell.position.copy(gal).add(new THREE.Vector3(0.3, 12.5 * 0.05, 0));
    root.add(bell);
    // lanterns on the rail posts and three big ones over the stern
    for (const lx of [-58, -40, -20, 0, 20, 36, 60])
      for (const s of [-1, 1]) {
        const l = lanternGroup(0.06, M);
        const hw = halfW(lx, 14);
        l.position.copy(W(lx, railTop(lx) + 0.5, s * Math.round(hw - 0.5)));
        root.add(l);
      }
    for (const z of [-10, 0, 10]) {
      const l = lanternGroup(0.08 * SHIP_K, M);
      l.position.copy(W(Math.ceil(xMin(14)) + 1, 16.5, z));
      root.add(l);
    }
    if (lanternLights)
      for (const [x, y, z] of [[-66, 20, 0], [0, 8, 14], [0, 8, -14], [52, 14, 0]]) {
        const pl = new THREE.PointLight(0xffa550, 3 * SHIP_K, 9 * SHIP_K, 2);
        pl.position.copy(W(x, y, z));
        root.add(pl);
      }
    // deck clutter: barrels and crates by the masts
    const clutter = [];
    for (const [x, z, k] of [[-6, 12, "b"], [-9, 13, "b"], [14, -12, "c"], [17, -12, "c"], [-58, 9, "b"], [30, 12, "c"]]) {
      const p = W(x, deckY(x), z);
      clutter.push((k === "b" ? new THREE.CylinderGeometry(0.34, 0.3, 0.8, 8) : new THREE.BoxGeometry(0.7, 0.7, 0.7)).translate(p.x, p.y + 0.4, p.z).toNonIndexed());
    }
    root.add(new THREE.Mesh(mergeGeometries(clutter), M.dark));
  }
  // masthead pennant: a narrow navy streamer
  const pen = new THREE.PlaneGeometry(26 * V, 3 * V, 8, 1);
  const pp = pen.attributes.position;
  for (let i = 0; i < pp.count; i++) pp.setZ(i, Math.sin(pp.getX(i) * 1.2) * 0.3), pp.setY(i, pp.getY(i) * (1 - (pp.getX(i) / (26 * V) + 0.5) * 0.6));
  pen.translate(-13 * V, 0, 0).rotateY(0.4).translate(...W(2, 146, 0).toArray());
  root.add(new THREE.Mesh(pen, shipMat("pennant", `vec3 shipColour(vec3 p, vec3 n, vec2 uv){ return srgb(mod(floor(uv.x * 6.0), 2.0) > 0.5 ? vec3(0.95) : vec3(0.12, 0.18, 0.56)); }`, { side: THREE.DoubleSide })));

  mergeStatic(root, mergeGeometries);

  const spots = {
    bow: W(50, 7, 0),
    bowL: W(46, 7, 8),
    bowR: W(46, 7, -8),
    wheel: W(-50, 11, 0),
    helmStand: W(HELM_X - 1.15 / V, 11, 0),
    quarterL: W(-40, 11, 10),
    quarterR: W(-40, 11, -10),
    waist: [W(28, 0, 11), W(18, 0, 12), W(8, 0, 12), W(-4, 0, 12), W(-16, 0, 12), W(-26, 0, 11), W(20, 0, -12), W(-10, 0, -12)],
    foreRail: W(40, 7, 14),
    sternRail: W(-62, 11, 12),
  };
  const spotAt = (x, side = -1, inset = 4) => W(x, deckY(x), side * Math.max(0, halfW(x, deckY(x) + 1) - inset));
  const railSections = [30, 10, -10, -28].map((x) => W(x, railTop(x), -(halfW(x, 14) + 0.5)));
  root.userData = {
    spots,
    spotAt,
    guns,
    wheel,
    bell,
    railSections,
    deckY: (x) => (deckY(x / V) + WL) * V + V / 2,
    size: { halfLength: HALF_LENGTH, halfBeam: HALF_BEAM },
    smooth: true,
  };
  return { group: root, poses: ["sail"], expressions: ["default"], setPose() {}, setExpression() {}, spots };
}
