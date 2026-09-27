// Soft voxels (the captain's pick, look C with the original models' costume):
// a naive surface-nets mesher over the ORIGINAL voxel grids, so every hat, braid,
// scroll, beard and painted face keeps its silhouette and colour placement, but the
// surface is rounded (Taubin smoothing keeps volume, so thin brims and ribbons are
// not eaten). Colour stays crisp per voxel: each quad takes its solid voxel's colour
// (vertices are split per quad), while normals are shared, so the shading is smooth.
// The material family: a toon ramp plus a voxel-grid skin drawn in bind-pose object
// space at the grid's own voxel size (it rides skinned poses without swimming).
import * as THREE from "three";
import { M, hash3 } from "./voxel.js";

const JIT = [0, 0.03, 0.07, 0.12];
const tmpC = new THREE.Color();

// ---------------------------------------------------------------- materials
let RAMP = null;
function ramp() {
  if (RAMP) return RAMP;
  // four soft bands (the keyframes are painterly, not hard cel)
  RAMP = new THREE.DataTexture(new Uint8Array([105, 105, 105, 255, 175, 175, 175, 255, 228, 228, 228, 255, 255, 255, 255, 255]), 4, 1);
  RAMP.minFilter = RAMP.magFilter = THREE.NearestFilter;
  RAMP.needsUpdate = true;
  return RAMP;
}
const MAT_CACHE = new Map();
// kind: LIT / METAL / CLOTH share the toon family (metal gets a small specular sheen);
// GLOW stays unlit and bright
export function softMaterial(kind, cell, off, { seam = 0.2 } = {}) {
  if (kind === M.GLOW) {
    const k = "glow";
    if (!MAT_CACHE.has(k)) MAT_CACHE.set(k, new THREE.MeshBasicMaterial({ vertexColors: true, color: new THREE.Color(3.2, 3.2, 3.2) }));
    return MAT_CACHE.get(k);
  }
  const key = [kind, cell.toFixed(5), off.map((v) => v.toFixed(5)).join(","), seam].join("|");
  if (MAT_CACHE.has(key)) return MAT_CACHE.get(key);
  const m = new THREE.MeshToonMaterial({ vertexColors: true, gradientMap: ramp(), side: kind === M.CLOTH ? THREE.DoubleSide : THREE.FrontSide });
  const U = { uCell: { value: cell }, uOff: { value: new THREE.Vector3(...off) }, uSeam: { value: seam }, uSheen: { value: kind === M.METAL ? 0.35 : 0 } };
  m.onBeforeCompile = (sh) => {
    Object.assign(sh.uniforms, U);
    sh.vertexShader = sh.vertexShader
      .replace("#include <common>", "#include <common>\nvarying vec3 vBindP; varying vec3 vBindN;")
      .replace("#include <begin_vertex>", "#include <begin_vertex>\nvBindP = position; vBindN = normal;");
    sh.fragmentShader = sh.fragmentShader
      .replace("#include <common>", "#include <common>\nvarying vec3 vBindP; varying vec3 vBindN; uniform float uCell, uSeam, uSheen; uniform vec3 uOff;")
      .replace(
        "#include <color_fragment>",
        `#include <color_fragment>
        {
          // the voxel grid on the skin: seams on the original voxel boundaries (triplanar, bind pose)
          vec3 an = abs(normalize(vBindN));
          vec3 q = (vBindP - uOff) / uCell;
          vec2 uv = an.x > an.y && an.x > an.z ? q.zy : an.y > an.z ? q.xz : q.xy;
          vec2 f = fract(uv);
          float e = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
          vec2 fw = fwidth(uv);
          float px = max(fw.x, fw.y);
          float s = 1.0 - smoothstep(0.0, 0.06 + px, e);
          s *= 1.0 - smoothstep(0.15, 0.4, px); // fades out where cells get tiny on screen
          diffuseColor.rgb *= 1.0 - uSeam * s;
        }`,
      )
      .replace(
        "#include <opaque_fragment>",
        `outgoingLight += uSheen * pow(max(dot(normalize(normal), normalize(vec3(0.3, 0.8, 0.5))), 0.0), 24.0) * diffuseColor.rgb;
        #include <opaque_fragment>`,
      );
  };
  m.customProgramCacheKey = () => "soft-voxel-" + kind;
  m.userData.softU = U;
  MAT_CACHE.set(key, m);
  return m;
}

// ---------------------------------------------------------------- mesher
// grid: VoxelGrid; size: voxel size; origin: world offset of voxel (0,0,0)'s centre
// smooth: Taubin iterations (0 = raw surface nets)
export function softMesh(grid, { size = 1, origin = [0, 0, 0], smooth = 2, cast = true, receive = true, seam = 0.2 } = {}) {
  const vox = [...grid.map.values()];
  const g = new THREE.Group();
  if (!vox.length) return g;
  let x0 = Infinity, y0 = Infinity, z0 = Infinity, x1 = -Infinity, y1 = -Infinity, z1 = -Infinity;
  for (const v of vox) {
    if (v.x < x0) x0 = v.x;
    if (v.y < y0) y0 = v.y;
    if (v.z < z0) z0 = v.z;
    if (v.x > x1) x1 = v.x;
    if (v.y > y1) y1 = v.y;
    if (v.z > z1) z1 = v.z;
  }
  // dense occupancy with a 1-voxel pad: value = voxel index + 1
  const X0 = x0 - 1, Y0 = y0 - 1, Z0 = z0 - 1;
  const nx = x1 - x0 + 3, ny = y1 - y0 + 3, nz = z1 - z0 + 3;
  const occ = new Int32Array(nx * ny * nz);
  const I = (x, y, z) => ((x - X0) * ny + (y - Y0)) * nz + (z - Z0);
  vox.forEach((v, i) => (occ[I(v.x, v.y, v.z)] = i + 1));
  const S = (x, y, z) => (x < X0 || y < Y0 || z < Z0 || x >= X0 + nx || y >= Y0 + ny || z >= Z0 + nz ? 0 : occ[I(x, y, z)]);
  // dual cells: cell (x,y,z) has corners at voxel centres x..x+1, y..y+1, z..z+1
  const cellV = new Int32Array(nx * ny * nz).fill(-1);
  const P = []; // shared positions (voxel units)
  const solidN = []; // solid-corner count per vertex (for AO)
  const EDGES = [
    [0, 1], [2, 3], [4, 5], [6, 7], // x edges (corner bit 1)
    [0, 2], [1, 3], [4, 6], [5, 7], // y edges (bit 2)
    [0, 4], [1, 5], [2, 6], [3, 7], // z edges (bit 4)
  ];
  for (let x = X0; x < X0 + nx - 1; x++)
    for (let y = Y0; y < Y0 + ny - 1; y++)
      for (let z = Z0; z < Z0 + nz - 1; z++) {
        let mask = 0, cnt = 0;
        for (let c = 0; c < 8; c++) if (S(x + (c & 1), y + ((c >> 1) & 1), z + ((c >> 2) & 1))) (mask |= 1 << c), cnt++;
        if (mask === 0 || mask === 255) continue;
        let sx = 0, sy = 0, sz = 0, n = 0;
        for (const [a, b] of EDGES) {
          if (((mask >> a) & 1) === ((mask >> b) & 1)) continue;
          sx += ((a & 1) + (b & 1)) / 2;
          sy += (((a >> 1) & 1) + ((b >> 1) & 1)) / 2;
          sz += (((a >> 2) & 1) + ((b >> 2) & 1)) / 2;
          n++;
        }
        cellV[I(x, y, z)] = P.length / 3;
        P.push(x + sx / n, y + sy / n, z + sz / n);
        solidN.push(cnt);
      }
  // quads: one per solid/empty voxel pair, around the shared edge; colour and kind from the solid voxel
  const quads = []; // [v0, v1, v2, v3, voxelIndex]
  const cellAt = (x, y, z) => (x < X0 || y < Y0 || z < Z0 || x >= X0 + nx - 1 || y >= Y0 + ny - 1 || z >= Z0 + nz - 1 ? -1 : cellV[I(x, y, z)]);
  for (const v of vox) {
    const vi = occ[I(v.x, v.y, v.z)] - 1;
    for (let axis = 0; axis < 3; axis++)
      for (const dir of [1, -1]) {
        const ox = axis === 0 ? dir : 0, oy = axis === 1 ? dir : 0, oz = axis === 2 ? dir : 0;
        if (S(v.x + ox, v.y + oy, v.z + oz)) continue;
        // the edge from v toward its empty neighbour; the 4 cells around it
        const ex = dir > 0 ? v.x : v.x - (axis === 0 ? 1 : 0),
          ey = dir > 0 ? v.y : v.y - (axis === 1 ? 1 : 0),
          ez = dir > 0 ? v.z : v.z - (axis === 2 ? 1 : 0);
        let c;
        if (axis === 0) c = [cellAt(ex, v.y - 1, v.z - 1), cellAt(ex, v.y, v.z - 1), cellAt(ex, v.y, v.z), cellAt(ex, v.y - 1, v.z)];
        else if (axis === 1) c = [cellAt(v.x - 1, ey, v.z - 1), cellAt(v.x - 1, ey, v.z), cellAt(v.x, ey, v.z), cellAt(v.x, ey, v.z - 1)];
        else c = [cellAt(v.x - 1, v.y - 1, ez), cellAt(v.x, v.y - 1, ez), cellAt(v.x, v.y, ez), cellAt(v.x - 1, v.y, ez)];
        if (c.some((k) => k < 0)) continue;
        if (dir < 0) c.reverse();
        quads.push(c[0], c[1], c[2], c[3], vi);
      }
  }
  // Taubin smoothing over the shared vertex graph (rounds without shrinking)
  const nv = P.length / 3;
  if (smooth > 0 && nv) {
    const nb = Array.from({ length: nv }, () => new Set());
    for (let q = 0; q < quads.length; q += 5)
      for (let k = 0; k < 4; k++) {
        const a = quads[q + k], b = quads[q + ((k + 1) & 3)];
        nb[a].add(b);
        nb[b].add(a);
      }
    const adj = nb.map((s) => [...s]);
    const T = new Float32Array(P.length);
    const pass = (lam) => {
      for (let i = 0; i < nv; i++) {
        const a = adj[i];
        if (!a.length) {
          T[i * 3] = P[i * 3];
          T[i * 3 + 1] = P[i * 3 + 1];
          T[i * 3 + 2] = P[i * 3 + 2];
          continue;
        }
        let sx = 0, sy = 0, sz = 0;
        for (const j of a) (sx += P[j * 3]), (sy += P[j * 3 + 1]), (sz += P[j * 3 + 2]);
        const n = a.length;
        T[i * 3] = P[i * 3] + lam * (sx / n - P[i * 3]);
        T[i * 3 + 1] = P[i * 3 + 1] + lam * (sy / n - P[i * 3 + 1]);
        T[i * 3 + 2] = P[i * 3 + 2] + lam * (sz / n - P[i * 3 + 2]);
      }
      for (let i = 0; i < P.length; i++) P[i] = T[i];
    };
    for (let it = 0; it < smooth; it++) pass(0.5), pass(-0.53);
  }
  // shared normals from the quads
  const N = new Float32Array(P.length);
  const va = new THREE.Vector3(), vb = new THREE.Vector3(), vc = new THREE.Vector3(), vd = new THREE.Vector3();
  for (let q = 0; q < quads.length; q += 5) {
    va.fromArray(P, quads[q] * 3);
    vb.fromArray(P, quads[q + 1] * 3);
    vc.fromArray(P, quads[q + 2] * 3);
    vd.fromArray(P, quads[q + 3] * 3);
    const n = vc.clone().sub(va).cross(vd.clone().sub(vb)); // diagonal cross: area-weighted
    for (let k = 0; k < 4; k++) {
      const i = quads[q + k] * 3;
      N[i] += n.x;
      N[i + 1] += n.y;
      N[i + 2] += n.z;
    }
  }
  // per-kind buffers, vertices split per quad (crisp voxel colours on a smooth surface)
  const buf = {};
  const seed = grid.seed || 1;
  let tris = 0;
  for (let q = 0; q < quads.length; q += 5) {
    const v = vox[quads[q + 4]];
    const b = (buf[v.m] ||= { pos: [], nor: [], col: [], idx: [], n: 0 });
    tmpC.set(v.c);
    const j = JIT[v.j] ?? 0.07;
    if (j > 0) {
      const h = hash3(v.x + seed * 131, v.y, v.z) - 0.5;
      const s = 1 + h * 2 * j;
      tmpC.r *= s;
      tmpC.g *= s;
      tmpC.b *= s;
    }
    const base = b.n;
    for (let k = 0; k < 4; k++) {
      const i = quads[q + k];
      b.pos.push(P[i * 3] * size + origin[0], P[i * 3 + 1] * size + origin[1], P[i * 3 + 2] * size + origin[2]);
      const l = Math.hypot(N[i * 3], N[i * 3 + 1], N[i * 3 + 2]) || 1;
      b.nor.push(N[i * 3] / l, N[i * 3 + 1] / l, N[i * 3 + 2] / l);
      // soft AO: creases (more solid corners) darken a little
      const ao = v.m === M.GLOW ? 1 : 1 - 0.28 * Math.max(0, Math.min(1, (solidN[i] - 4) / 3));
      b.col.push(tmpC.r * ao, tmpC.g * ao, tmpC.b * ao);
    }
    b.idx.push(base, base + 1, base + 2, base, base + 2, base + 3);
    b.n += 4;
    tris += 2;
  }
  const off = [origin[0] - 0.5 * size, origin[1] - 0.5 * size, origin[2] - 0.5 * size];
  for (const [k, b] of Object.entries(buf)) {
    const geo = new THREE.BufferGeometry();
    geo.setAttribute("position", new THREE.Float32BufferAttribute(b.pos, 3));
    geo.setAttribute("normal", new THREE.Float32BufferAttribute(b.nor, 3));
    geo.setAttribute("color", new THREE.Float32BufferAttribute(b.col, 3));
    geo.setIndex(b.idx);
    geo.computeBoundingSphere();
    const mesh = new THREE.Mesh(geo, softMaterial(+k, size, off, { seam }));
    mesh.castShadow = cast && +k !== M.GLOW;
    mesh.receiveShadow = receive && +k !== M.GLOW;
    g.add(mesh);
  }
  g.userData.triangles = tris;
  return g;
}
