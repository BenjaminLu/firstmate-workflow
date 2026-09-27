// Sparse voxel grid + face-culled mesher.
// Every model is authored in integer voxel coordinates, then meshed into one
// BufferGeometry per material kind. Vertex colours carry per-voxel jitter and
// corner ambient occlusion; a per-face UV lets the material draw soft seams so
// each block reads as a crafted brick.
import * as THREE from "three";

export const M = { LIT: 0, GLOW: 1, METAL: 2, CLOTH: 3 };
const KINDS = 4;

const OFF = 1024;
const key = (x, y, z) => ((x + OFF) * 2048 + (y + OFF)) * 2048 + (z + OFF);

export function hash3(x, y, z) {
  let h = Math.imul(x | 0, 374761393) + Math.imul(y | 0, 668265263) + Math.imul(z | 0, 1274126177);
  h = Math.imul(h ^ (h >>> 13), 1274126177);
  h = h ^ (h >>> 16);
  return (h >>> 0) / 4294967296;
}
export function rng(seed) {
  let a = seed | 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let r = Math.imul(a ^ (a >>> 15), 1 | a);
    r = (r + Math.imul(r ^ (r >>> 7), 61 | r)) ^ r;
    return ((r ^ (r >>> 14)) >>> 0) / 4294967296;
  };
}

// jitter levels: 0 none, 1 subtle (skin, glass), 2 normal, 3 strong (wood, rock)
const JIT = [0, 0.03, 0.07, 0.12];

export class VoxelGrid {
  constructor({ jitter = 2, seam = 0.35, seed = 1 } = {}) {
    this.map = new Map();
    this.jitter = jitter;
    this.seam = seam;
    this.seed = seed;
  }
  set(x, y, z, color, mat = M.LIT, jitter = this.jitter) {
    x = Math.round(x);
    y = Math.round(y);
    z = Math.round(z);
    if (color === null || color === undefined || color === false) return this;
    this.map.set(key(x, y, z), { x, y, z, c: color, m: mat, j: jitter });
    return this;
  }
  get(x, y, z) {
    return this.map.get(key(Math.round(x), Math.round(y), Math.round(z)));
  }
  has(x, y, z) {
    return this.map.has(key(x, y, z));
  }
  del(x, y, z) {
    this.map.delete(key(Math.round(x), Math.round(y), Math.round(z)));
    return this;
  }
  // paint an existing voxel (keeps it only if present)
  paint(x, y, z, color, mat, jitter) {
    const v = this.get(x, y, z);
    if (!v) return false;
    v.c = color;
    if (mat !== undefined) v.m = mat;
    if (jitter !== undefined) v.j = jitter;
    return true;
  }
  box(x0, y0, z0, x1, y1, z1, c, mat, jit) {
    const [ax, bx] = x0 <= x1 ? [x0, x1] : [x1, x0];
    const [ay, by] = y0 <= y1 ? [y0, y1] : [y1, y0];
    const [az, bz] = z0 <= z1 ? [z0, z1] : [z1, z0];
    for (let x = Math.round(ax); x <= Math.round(bx); x++)
      for (let y = Math.round(ay); y <= Math.round(by); y++)
        for (let z = Math.round(az); z <= Math.round(bz); z++) {
          const col = typeof c === "function" ? c(x, y, z) : c;
          if (col !== null && col !== undefined) this.set(x, y, z, col, mat, jit);
        }
    return this;
  }
  // fill every voxel in bounds where fn returns a colour (or [colour, mat])
  fill(x0, y0, z0, x1, y1, z1, fn, mat, jit) {
    for (let x = x0; x <= x1; x++)
      for (let y = y0; y <= y1; y++)
        for (let z = z0; z <= z1; z++) {
          const r = fn(x, y, z);
          if (r === null || r === undefined || r === false) continue;
          if (Array.isArray(r)) this.set(x, y, z, r[0], r[1] ?? mat, r[2] ?? jit);
          else this.set(x, y, z, r, mat, jit);
        }
    return this;
  }
  ellipsoid(cx, cy, cz, rx, ry, rz, c, mat, jit) {
    return this.fill(
      Math.floor(cx - rx),
      Math.floor(cy - ry),
      Math.floor(cz - rz),
      Math.ceil(cx + rx),
      Math.ceil(cy + ry),
      Math.ceil(cz + rz),
      (x, y, z) => {
        const d = ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 + ((z - cz) / rz) ** 2;
        return d <= 1 ? (typeof c === "function" ? c(x, y, z, d) : c) : null;
      },
      mat,
      jit,
    );
  }
  // cylinder along an axis ('x' | 'y' | 'z'), from a0 to a1, centred at (u,v)
  cyl(axis, a0, a1, cu, cv, r, c, mat, jit) {
    const r2 = r * r;
    for (let a = Math.round(Math.min(a0, a1)); a <= Math.round(Math.max(a0, a1)); a++)
      for (let u = Math.floor(cu - r); u <= Math.ceil(cu + r); u++)
        for (let v = Math.floor(cv - r); v <= Math.ceil(cv + r); v++) {
          if ((u - cu) ** 2 + (v - cv) ** 2 > r2) continue;
          const col = typeof c === "function" ? c(a, u, v) : c;
          if (axis === "x") this.set(a, u, v, col, mat, jit);
          else if (axis === "y") this.set(u, a, v, col, mat, jit);
          else this.set(u, v, a, col, mat, jit);
        }
    return this;
  }
  // thick line (sphere brush) between two points
  line(x0, y0, z0, x1, y1, z1, r, c, mat, jit) {
    const n = Math.max(1, Math.ceil(Math.hypot(x1 - x0, y1 - y0, z1 - z0) * 2));
    for (let i = 0; i <= n; i++) {
      const k = i / n;
      const x = x0 + (x1 - x0) * k,
        y = y0 + (y1 - y0) * k,
        z = z0 + (z1 - z0) * k;
      if (r <= 0.5) this.set(x, y, z, typeof c === "function" ? c(k) : c, mat, jit);
      else this.ellipsoid(x, y, z, r, r, r, typeof c === "function" ? c(k) : c, mat, jit);
    }
    return this;
  }
  // copy another grid in, offset
  merge(other, dx = 0, dy = 0, dz = 0) {
    for (const v of other.map.values()) this.set(v.x + dx, v.y + dy, v.z + dz, v.c, v.m, v.j);
    return this;
  }
  bounds() {
    let mn = [1e9, 1e9, 1e9],
      mx = [-1e9, -1e9, -1e9];
    for (const v of this.map.values()) {
      mn = [Math.min(mn[0], v.x), Math.min(mn[1], v.y), Math.min(mn[2], v.z)];
      mx = [Math.max(mx[0], v.x), Math.max(mx[1], v.y), Math.max(mx[2], v.z)];
    }
    return { min: mn, max: mx };
  }
  get count() {
    return this.map.size;
  }
}

// face table: normal, 4 corners (CCW from outside), and the two tangent axes used for AO
const FACES = [
  { n: [1, 0, 0], c: [[1, 0, 0], [1, 1, 0], [1, 1, 1], [1, 0, 1]] },
  { n: [-1, 0, 0], c: [[0, 0, 1], [0, 1, 1], [0, 1, 0], [0, 0, 0]] },
  { n: [0, 1, 0], c: [[0, 1, 1], [1, 1, 1], [1, 1, 0], [0, 1, 0]] },
  { n: [0, -1, 0], c: [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]] },
  { n: [0, 0, 1], c: [[1, 0, 1], [1, 1, 1], [0, 1, 1], [0, 0, 1]] },
  { n: [0, 0, -1], c: [[0, 0, 0], [0, 1, 0], [1, 1, 0], [1, 0, 0]] },
];
const UVS = [
  [0, 0],
  [0, 1],
  [1, 1],
  [1, 0],
];
const AO_CURVE = [0.5, 0.68, 0.84, 1.0];
const tmpC = new THREE.Color();

// Mesh a grid. Returns { geometries: [kind] -> BufferGeometry|null, triangles }
export function meshGrid(grid, { size = 1, origin = [0, 0, 0], ao = true } = {}) {
  const buf = [];
  for (let k = 0; k < KINDS; k++) buf.push({ pos: [], nor: [], col: [], fuv: [], idx: [], n: 0 });
  const seed = grid.seed;
  const seam = grid.seam;
  const solid = (x, y, z) => grid.map.has(key(x, y, z));
  // glow voxels do not occlude lit neighbours for AO purposes (they emit)
  const occ = (x, y, z) => {
    const v = grid.map.get(key(x, y, z));
    return v && v.m !== M.GLOW ? 1 : 0;
  };
  let tris = 0;
  for (const v of grid.map.values()) {
    const { x, y, z } = v;
    const b = buf[v.m];
    tmpC.set(v.c);
    const j = JIT[v.j] ?? 0.07;
    if (j > 0) {
      const h = hash3(x + seed * 131, y, z) - 0.5;
      const h2 = hash3(x, y + seed * 71, z) - 0.5;
      const s = 1 + h * 2 * j;
      tmpC.r *= s * (1 + h2 * j * 0.5);
      tmpC.g *= s;
      tmpC.b *= s * (1 - h2 * j * 0.5);
    }
    for (let f = 0; f < 6; f++) {
      const F = FACES[f];
      const nx = F.n[0],
        ny = F.n[1],
        nz = F.n[2];
      if (solid(x + nx, y + ny, z + nz)) continue;
      const base = b.n;
      const aoV = [1, 1, 1, 1];
      for (let i = 0; i < 4; i++) {
        const cc = F.c[i];
        // corner offsets in the two tangent directions (-1 or +1)
        const d = [cc[0] * 2 - 1, cc[1] * 2 - 1, cc[2] * 2 - 1];
        if (nx) d[0] = 0;
        if (ny) d[1] = 0;
        if (nz) d[2] = 0;
        let a = 3;
        if (ao && v.m !== M.GLOW) {
          const px = x + nx,
            py = y + ny,
            pz = z + nz;
          // split the diagonal into its two axis components
          const t1 = [d[0], nx ? 0 : d[1] && !d[0] ? d[1] : 0, 0];
          let s1, s2;
          if (nx) {
            s1 = occ(px, py + d[1], pz);
            s2 = occ(px, py, pz + d[2]);
          } else if (ny) {
            s1 = occ(px + d[0], py, pz);
            s2 = occ(px, py, pz + d[2]);
          } else {
            s1 = occ(px + d[0], py, pz);
            s2 = occ(px, py + d[1], pz);
          }
          const cr = occ(px + d[0], py + d[1], pz + d[2]);
          a = s1 && s2 ? 0 : 3 - (s1 + s2 + cr);
          void t1;
        }
        aoV[i] = AO_CURVE[a];
        b.pos.push((x + cc[0] - 0.5) * size + origin[0], (y + cc[1] - 0.5) * size + origin[1], (z + cc[2] - 0.5) * size + origin[2]);
        b.nor.push(nx, ny, nz);
        b.col.push(tmpC.r * aoV[i], tmpC.g * aoV[i], tmpC.b * aoV[i]);
        b.fuv.push(UVS[i][0], UVS[i][1], seam);
      }
      // flip the quad diagonal to follow AO (removes the classic anisotropy)
      if (aoV[0] + aoV[2] > aoV[1] + aoV[3]) b.idx.push(base, base + 1, base + 2, base, base + 2, base + 3);
      else b.idx.push(base + 1, base + 2, base + 3, base + 1, base + 3, base);
      b.n += 4;
      tris += 2;
    }
  }
  const geometries = buf.map((b) => {
    if (!b.n) return null;
    const g = new THREE.BufferGeometry();
    g.setAttribute("position", new THREE.Float32BufferAttribute(b.pos, 3));
    g.setAttribute("normal", new THREE.Float32BufferAttribute(b.nor, 3));
    g.setAttribute("color", new THREE.Float32BufferAttribute(b.col, 3));
    g.setAttribute("faceUv", new THREE.Float32BufferAttribute(b.fuv, 3));
    g.setIndex(b.n > 65535 ? new THREE.Uint32BufferAttribute(b.idx, 1) : new THREE.Uint16BufferAttribute(b.idx, 1));
    g.computeBoundingSphere();
    return g;
  });
  return { geometries, triangles: tris };
}
