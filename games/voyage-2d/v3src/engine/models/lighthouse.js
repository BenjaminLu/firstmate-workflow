// Lighthouse on a rocky green island: stepped cliffs with strata and grass
// tops, tiny voxel trees, a red/white banded tower with gallery and glowing
// lamp room. Also sea stacks (with an optional arch) for the background.
import * as THREE from "three";
import { VoxelGrid, M, hash3 } from "../voxel.js";
import { toMesh, PAL } from "../materials.js";

const ROCK = [0x8c7f98, 0x7a6d88, 0x9a8ca2, 0x6a5e7a];
const GRASS = [0x5eae3c, 0x4f9a34, 0x6cbc44];

function noise2(x, z, s) {
  const xi = Math.floor(x / s),
    zi = Math.floor(z / s);
  const fx = x / s - xi,
    fz = z / s - zi;
  const a = hash3(xi, 0, zi),
    b = hash3(xi + 1, 0, zi),
    c = hash3(xi, 0, zi + 1),
    d = hash3(xi + 1, 0, zi + 1);
  const ux = fx * fx * (3 - 2 * fx),
    uz = fz * fz * (3 - 2 * fz);
  return a + (b - a) * ux + (c - a) * uz + (a - b - c + d) * ux * uz;
}

function tree(g, x, y, z, kind, seed) {
  const h = 3 + Math.floor(hash3(seed, 1, 2) * 3);
  g.box(x, y, z, x, y + h, z, 0x6b4226, M.LIT, 2);
  if (kind === 0) {
    // pine: stacked shrinking squares
    for (let i = 0; i < 4; i++) {
      const r = 3 - i;
      g.box(x - r, y + h - 1 + i * 2, z - r, x + r, y + h + i * 2, z + r, (xx, yy, zz) => (hash3(xx, yy, zz) < 0.3 ? 0x2f7a34 : 0x3c8f3c), M.LIT, 3);
    }
  } else {
    g.ellipsoid(x, y + h + 2, z, 3.2, 2.8, 3.2, (xx, yy) => (yy > y + h + 3 ? 0x6cc04a : 0x4a9a38), M.LIT, 3);
  }
}

// stepped island terrain; returns the grid and a height lookup
function islandGrid({ radius = 30, height = 26, seed = 1, trees = 14, flatTop = null }) {
  const g = new VoxelGrid({ jitter: 3, seam: 0.35, seed });
  const H = (x, z) => {
    const r = Math.hypot(x, z * 1.15) / radius;
    if (r > 1.15) return -99;
    const n = noise2(x + seed * 50, z, 9) * 0.6 + noise2(x, z + seed * 30, 4.5) * 0.4;
    let h = height * Math.max(0, 1 - r * r) * (0.55 + 0.7 * n);
    if (flatTop && Math.hypot(x - flatTop[0], z - flatTop[1]) < flatTop[2]) h = Math.max(h, flatTop[3]);
    // terraces: quantise into 3-voxel ledges
    return Math.round(h / 3) * 3 - 3 + Math.round(noise2(x, z, 2) * 1.2);
  };
  const heights = new Map();
  for (let x = -radius - 4; x <= radius + 4; x++)
    for (let z = -radius - 4; z <= radius + 4; z++) {
      const h = H(x, z);
      if (h < -4) continue;
      heights.set(x + "," + z, h);
      for (let y = -4; y <= h; y++) {
        // only the shell
        const exposed = y === h || y >= Math.min(H(x + 1, z), H(x - 1, z), H(x, z + 1), H(x, z - 1)) - 1 || y === -4;
        if (!exposed) continue;
        let c;
        if (y === h && h > 0) c = GRASS[Math.floor(hash3(x, y, z) * 3)];
        else if (y === h - 1 && h > 0 && hash3(x, 7, z) < 0.55) c = 0x4a8a30; // moss lip
        else if (h <= 0 || y < 1) c = y < -1 ? 0x5a506a : 0x9a8a78; // wet rock + beach
        else c = ROCK[(Math.floor((y + (x % 2)) / 2) + 4) % 4];
        g.set(x, y, z, c);
      }
    }
  // trees on the grass tops
  let placed = 0;
  for (let n = 0; n < 400 && placed < trees; n++) {
    const x = Math.round((hash3(n, seed, 1) - 0.5) * radius * 1.6);
    const z = Math.round((hash3(n, seed, 2) - 0.5) * radius * 1.4);
    const h = heights.get(x + "," + z);
    if (h === undefined || h < 4) continue;
    if (flatTop && Math.hypot(x - flatTop[0], z - flatTop[1]) < flatTop[2] + 2) continue;
    tree(g, x, h + 1, z, n % 3 === 0 ? 1 : 0, n);
    placed++;
  }
  return { g, heights };
}

function tower() {
  const g = new VoxelGrid({ jitter: 1, seam: 0.3, seed: 41 });
  const TH = 52;
  for (let y = 0; y <= TH; y++) {
    const r = 7.2 - (y / TH) * 2.2;
    const band = Math.floor(y / 9) % 2 === 0;
    for (let x = -8; x <= 8; x++)
      for (let z = -8; z <= 8; z++) {
        const d = Math.hypot(x, z);
        if (d > r || d < r - 1.6) continue;
        g.set(x, y, z, band ? 0xd8322a : 0xf6f2ea, M.LIT, 1);
      }
  }
  // stone plinth
  g.cyl("y", -3, 0, 0, 0, 8.6, (a, u, v) => (hash3(u, a, v) < 0.3 ? 0x9a8e86 : 0xb0a498), M.LIT, 3);
  // door + windows facing +z
  g.box(-1, 1, 7, 1, 5, 7, 0x5a3418);
  for (const y of [14, 27, 40]) g.box(0, y, 6, 0, y + 2, 6, 0x2a3350);
  // gallery deck + railing
  g.cyl("y", TH + 1, TH + 1, 0, 0, 7.5, 0x3a3c44, M.METAL, 1);
  for (let a = 0; a < 28; a++) {
    const t = (a / 28) * Math.PI * 2;
    const x = Math.round(Math.cos(t) * 7),
      z = Math.round(Math.sin(t) * 7);
    g.set(x, TH + 2, z, 0x2c2e36, M.METAL, 1);
    g.set(x, TH + 3, z, 0x2c2e36, M.METAL, 1);
  }
  // lamp room: iron mullions around a glowing lamp
  for (let y = TH + 2; y <= TH + 8; y++)
    for (let x = -4; x <= 4; x++)
      for (let z = -4; z <= 4; z++) {
        const d = Math.hypot(x, z);
        if (d > 4.3) continue;
        const mull = d > 3.3 && (Math.abs(x) === Math.abs(z) || x === 0 || z === 0);
        if (y === TH + 2 || y === TH + 8 || mull) g.set(x, y, z, 0x2a2c34, M.METAL, 1);
        else if (d < 3.4) g.set(x, y, z, d < 1.8 ? 0xfff4c8 : 0xffc45a, M.GLOW, 0);
      }
  // red dome + finial
  for (let y = 0; y <= 4; y++) g.cyl("y", TH + 9 + y, TH + 9 + y, 0, 0, 5 - y * 1.1, 0xc02a24, M.LIT, 1);
  g.box(0, TH + 14, 0, 0, TH + 16, 0, 0x2a2c34, M.METAL, 1);
  return g;
}

export function buildLighthouseIsland({ seed = 3, lampLight = true } = {}) {
  const root = new THREE.Group();
  root.name = "lighthouse-island";
  const S = 0.3;
  const { g, heights } = islandGrid({ radius: 30, height: 27, seed, trees: 16, flatTop: [-6, 2, 7, 24] });
  root.add(toMesh(g, { size: S }));
  const top = heights.get("-6,2") ?? 24;
  const t = toMesh(tower(), { size: 0.15 });
  t.position.set(-6 * S, (top + 1) * S, 2 * S);
  root.add(t);
  if (lampLight) {
    const l = new THREE.PointLight(0xffc060, 8, 18, 2);
    l.position.set(-6 * S, (top + 1) * S + 57 * 0.15, 2 * S);
    root.add(l);
  }
  root.userData.footprint = 30 * S;
  return { group: root, poses: ["default"], expressions: ["lit"], setPose() {}, setExpression() {} };
}

// background rock spire / sea stack, optional arch
export function buildSeaStack({ seed = 7, h = 40, r = 9, arch = false, scale = 0.35 } = {}) {
  const g = new VoxelGrid({ jitter: 3, seam: 0.35, seed });
  for (let y = -3; y <= h; y++) {
    const k = y / h;
    const rr = r * (1 - k * 0.55) * (0.85 + noise2(y, seed, 5) * 0.3);
    const ox = Math.sin(y * 0.08 + seed) * 2;
    for (let x = -r - 3; x <= r + 3; x++)
      for (let z = -r - 3; z <= r + 3; z++) {
        const d = Math.hypot(x - ox, z);
        if (d > rr) continue;
        if (d < rr - 2 && y !== h) continue;
        if (arch && Math.abs(z) < rr && y < h * 0.45 && Math.hypot(x - ox, (y - 0) * 0.8) < rr * 0.55) continue;
        const top = y >= h - 1 || (d > rr - 1 && hash3(x, y, z) < 0.05);
        g.set(x, y, z, top ? GRASS[Math.floor(hash3(x, y, z) * 3)] : ROCK[(Math.floor(y / 2) + 4) % 4]);
      }
  }
  return toMesh(g, { size: scale });
}
