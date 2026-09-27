// Sculpted soft masses from blended blobs (p4): hair, beards, curls.
//
// The captain's note was "the faces clip": the hair and beard were hundreds of separate
// little boxes, each pushed onto the skull on its own, so they crossed each other, the
// brows, the hat and the face, and skin showed between them. Here a mass is ONE surface:
// blobs (clump centres) are splatted into a density field with a compact smooth kernel,
// masks carve the field (keep off the face, stay inside a band over the skull, stay
// under the hat), and the 0.5 iso-surface is extracted with surface nets. Neighbouring
// curls melt into each other instead of intersecting; nothing is left floating.
//
// Units are the caller's (head units for heads). Output: non-indexed geometry with
// position, normal (from the field gradient) and colour, ready to merge with the
// captain-smooth parts.
import * as THREE from "three";

// a density grid over [min, max] with node spacing `step`
export class Field {
  constructor(min, max, step) {
    this.min = min.slice();
    this.step = step;
    this.n = [0, 1, 2].map((a) => Math.max(2, Math.ceil((max[a] - min[a]) / step) + 1));
    this.v = new Float32Array(this.n[0] * this.n[1] * this.n[2]);
  }
  idx(i, j, k) {
    return (k * this.n[1] + j) * this.n[0] + i;
  }
  pos(i, j, k) {
    return [this.min[0] + i * this.step, this.min[1] + j * this.step, this.min[2] + k * this.step];
  }
  // a blob of surface radius r (alone it meshes to a sphere of radius r) at c; `p` > 2
  // squares it off (a chunky curl), `w` weights it; `scale` stretches it per axis
  blob(c, r, { p = 2, w = 1, scale = [1, 1, 1] } = {}) {
    const R = r / 0.4542; // (1 - (0.4542)^2)^3 = 0.5
    const [n0, n1, n2] = this.n;
    const lo = [0, 1, 2].map((a) => Math.max(0, Math.floor((c[a] - R * scale[a] - this.min[a]) / this.step)));
    const hi = [0, 1, 2].map((a) => Math.min(this.n[a] - 1, Math.ceil((c[a] + R * scale[a] - this.min[a]) / this.step)));
    for (let k = lo[2]; k <= hi[2]; k++)
      for (let j = lo[1]; j <= hi[1]; j++)
        for (let i = lo[0]; i <= hi[0]; i++) {
          const x = (this.min[0] + i * this.step - c[0]) / scale[0],
            y = (this.min[1] + j * this.step - c[1]) / scale[1],
            z = (this.min[2] + k * this.step - c[2]) / scale[2];
          const d = p === 2 ? Math.sqrt(x * x + y * y + z * z) : Math.pow(Math.abs(x) ** p + Math.abs(y) ** p + Math.abs(z) ** p, 1 / p);
          if (d >= R) continue;
          const t = 1 - (d / R) ** 2;
          this.v[(k * n1 + j) * n0 + i] += w * t * t * t;
        }
    return this;
  }
  // multiply every node by mask(x, y, z) in [0, 1]
  mask(fn) {
    const [n0, n1, n2] = this.n;
    for (let k = 0; k < n2; k++)
      for (let j = 0; j < n1; j++)
        for (let i = 0; i < n0; i++) {
          const q = (k * n1 + j) * n0 + i;
          if (this.v[q] <= 0) continue;
          this.v[q] *= fn(this.min[0] + i * this.step, this.min[1] + j * this.step, this.min[2] + k * this.step);
        }
    return this;
  }
  // trilinear sample
  at(x, y, z) {
    const fx = (x - this.min[0]) / this.step, fy = (y - this.min[1]) / this.step, fz = (z - this.min[2]) / this.step;
    const i = Math.max(0, Math.min(this.n[0] - 2, Math.floor(fx))), j = Math.max(0, Math.min(this.n[1] - 2, Math.floor(fy))), k = Math.max(0, Math.min(this.n[2] - 2, Math.floor(fz)));
    const u = Math.min(1, Math.max(0, fx - i)), v = Math.min(1, Math.max(0, fy - j)), w = Math.min(1, Math.max(0, fz - k));
    const g = (a, b, c) => this.v[this.idx(i + a, j + b, k + c)];
    const x00 = g(0, 0, 0) * (1 - u) + g(1, 0, 0) * u, x10 = g(0, 1, 0) * (1 - u) + g(1, 1, 0) * u;
    const x01 = g(0, 0, 1) * (1 - u) + g(1, 0, 1) * u, x11 = g(0, 1, 1) * (1 - u) + g(1, 1, 1) * u;
    return (x00 * (1 - v) + x10 * v) * (1 - w) + (x01 * (1 - v) + x11 * v) * w;
  }
  grad(x, y, z, h = this.step * 0.75) {
    return [this.at(x + h, y, z) - this.at(x - h, y, z), this.at(x, y + h, z) - this.at(x, y - h, z), this.at(x, y, z + h) - this.at(x, y, z - h)];
  }
  // surface nets at `iso`; colour(x, y, z, normal, field) -> THREE.Color
  mesh(colour, iso = 0.5, { relax = 1 } = {}) {
    const [n0, n1, n2] = this.n, V = this.v;
    const vid = new Int32Array(n0 * n1 * n2).fill(-1);
    const P = [];
    const E = [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]];
    const cv = new Float32Array(8);
    for (let k = 0; k < n2 - 1; k++)
      for (let j = 0; j < n1 - 1; j++)
        for (let i = 0; i < n0 - 1; i++) {
          let m = 0;
          for (let c = 0; c < 8; c++) {
            cv[c] = V[this.idx(i + (c & 1), j + ((c >> 1) & 1), k + ((c >> 2) & 1))];
            if (cv[c] > iso) m |= 1 << c;
          }
          if (m === 0 || m === 255) continue;
          let sx = 0, sy = 0, sz = 0, cnt = 0;
          for (const [a, b] of E) {
            if (((m >> a) & 1) === ((m >> b) & 1)) continue;
            const t = (iso - cv[a]) / (cv[b] - cv[a]);
            sx += (a & 1) + ((b & 1) - (a & 1)) * t;
            sy += ((a >> 1) & 1) + (((b >> 1) & 1) - ((a >> 1) & 1)) * t;
            sz += ((a >> 2) & 1) + (((b >> 2) & 1) - ((a >> 2) & 1)) * t;
            cnt++;
          }
          vid[this.idx(i, j, k)] = P.length / 3;
          P.push(this.min[0] + (i + sx / cnt) * this.step, this.min[1] + (j + sy / cnt) * this.step, this.min[2] + (k + sz / cnt) * this.step);
        }
    const quads = [];
    const cell = (i, j, k) => (i < 0 || j < 0 || k < 0 || i >= n0 - 1 || j >= n1 - 1 || k >= n2 - 1 ? -1 : vid[this.idx(i, j, k)]);
    for (let k = 0; k < n2; k++)
      for (let j = 0; j < n1; j++)
        for (let i = 0; i < n0; i++) {
          const a = V[this.idx(i, j, k)] > iso;
          // x edge
          if (i < n0 - 1 && a !== V[this.idx(i + 1, j, k)] > iso) {
            const q = [cell(i, j - 1, k - 1), cell(i, j, k - 1), cell(i, j, k), cell(i, j - 1, k)];
            if (q.every((x) => x >= 0)) quads.push(a ? q : q.slice().reverse());
          }
          if (j < n1 - 1 && a !== V[this.idx(i, j + 1, k)] > iso) {
            const q = [cell(i - 1, j, k - 1), cell(i - 1, j, k), cell(i, j, k), cell(i, j, k - 1)];
            if (q.every((x) => x >= 0)) quads.push(a ? q : q.slice().reverse());
          }
          if (k < n2 - 1 && a !== V[this.idx(i, j, k + 1)] > iso) {
            const q = [cell(i - 1, j - 1, k), cell(i, j - 1, k), cell(i, j, k), cell(i - 1, j, k)];
            if (q.every((x) => x >= 0)) quads.push(a ? q : q.slice().reverse());
          }
        }
    // light relaxation toward the neighbours' mean (keeps the iso-surface, softens the nets' terraces)
    if (relax > 0) {
      const nv = P.length / 3, nb = Array.from({ length: nv }, () => new Set());
      for (const q of quads) for (let e = 0; e < 4; e++) (nb[q[e]].add(q[(e + 1) & 3]), nb[q[(e + 1) & 3]].add(q[e]));
      for (let it = 0; it < relax; it++) {
        const Q2 = P.slice();
        for (let v = 0; v < nv; v++) {
          if (!nb[v].size) continue;
          let x = 0, y = 0, z = 0;
          for (const u of nb[v]) (x += P[u * 3]), (y += P[u * 3 + 1]), (z += P[u * 3 + 2]);
          const s = nb[v].size;
          Q2[v * 3] = P[v * 3] * 0.5 + (x / s) * 0.5;
          Q2[v * 3 + 1] = P[v * 3 + 1] * 0.5 + (y / s) * 0.5;
          Q2[v * 3 + 2] = P[v * 3 + 2] * 0.5 + (z / s) * 0.5;
        }
        for (let t = 0; t < P.length; t++) P[t] = Q2[t];
      }
    }
    // normals from the field (smooth shading across the whole mass) and colours
    const nv = P.length / 3, N = new Float32Array(nv * 3), C = new Float32Array(nv * 3);
    for (let v = 0; v < nv; v++) {
      const [gx, gy, gz] = this.grad(P[v * 3], P[v * 3 + 1], P[v * 3 + 2]);
      const l = Math.hypot(gx, gy, gz) || 1;
      N[v * 3] = -gx / l;
      N[v * 3 + 1] = -gy / l;
      N[v * 3 + 2] = -gz / l;
      const c = colour(P[v * 3], P[v * 3 + 1], P[v * 3 + 2], [N[v * 3], N[v * 3 + 1], N[v * 3 + 2]], this);
      C[v * 3] = c.r;
      C[v * 3 + 1] = c.g;
      C[v * 3 + 2] = c.b;
    }
    const pos = [], nor = [], col = [];
    const put = (v) => (pos.push(P[v * 3], P[v * 3 + 1], P[v * 3 + 2]), nor.push(N[v * 3], N[v * 3 + 1], N[v * 3 + 2]), col.push(C[v * 3], C[v * 3 + 1], C[v * 3 + 2]));
    for (const q of quads) {
      // split along the shorter diagonal
      const d02 = (P[q[0] * 3] - P[q[2] * 3]) ** 2 + (P[q[0] * 3 + 1] - P[q[2] * 3 + 1]) ** 2 + (P[q[0] * 3 + 2] - P[q[2] * 3 + 2]) ** 2;
      const d13 = (P[q[1] * 3] - P[q[3] * 3]) ** 2 + (P[q[1] * 3 + 1] - P[q[3] * 3 + 1]) ** 2 + (P[q[1] * 3 + 2] - P[q[3] * 3 + 2]) ** 2;
      const tri = d02 <= d13 ? [0, 1, 2, 0, 2, 3] : [1, 2, 3, 1, 3, 0];
      for (const t of tri) put(q[t]);
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute("position", new THREE.Float32BufferAttribute(pos, 3));
    g.setAttribute("normal", new THREE.Float32BufferAttribute(nor, 3));
    g.setAttribute("color", new THREE.Float32BufferAttribute(col, 3));
    return g;
  }
}

// hair / beard colouring: a darker body in the crevices between curls (where the field
// is still dense a little way out along the normal), a lighter crest on the tops of
// the curls, and a soft sheen band across the crown
export function hairColour(base, { hi, lo, crown = null } = {}) {
  const B = new THREE.Color(base), H = new THREE.Color(hi ?? base).lerp(new THREE.Color(0xffffff), hi ? 0 : 0.18), L = new THREE.Color(lo ?? base).multiplyScalar(lo ? 1 : 0.6);
  const out = new THREE.Color();
  return (x, y, z, n, f) => {
    const probe = f.at(x + n[0] * 1.1, y + n[1] * 1.1, z + n[2] * 1.1); // denser outside = a crevice
    const crev = Math.min(1, Math.max(0, probe / 0.45));
    out.copy(B).lerp(L, crev * 0.85);
    const up = Math.max(0, n[1]) * (1 - crev);
    out.lerp(H, up * 0.55);
    if (crown) {
      const band = Math.exp(-(((y - crown[0]) / crown[1]) ** 2)) * Math.max(0, n[1] * 0.5 + n[2] * 0.5);
      out.lerp(H, Math.min(0.6, band * 0.6));
    }
    return out.clone();
  };
}
