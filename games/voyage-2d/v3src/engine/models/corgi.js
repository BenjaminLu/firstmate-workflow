// Corgi: orange-and-white, big ears, blue collar, tongue out. Poses: sit, stand.
import * as THREE from "three";
import { VoxelGrid, M } from "../voxel.js";
import { toMesh, PAL } from "../materials.js";

const S = 0.045;
const OR = 0xe39a3c;
const ORD = 0xc97e28;
const WH = 0xfbf3e6;

function head(expr) {
  const g = new VoxelGrid({ jitter: 1, seam: 0.2, seed: 11 });
  // skull
  g.ellipsoid(0, 5, 0, 6.2, 5.2, 5.5, (x, y, z) => {
    if (z >= 2 && Math.abs(x) <= 1 + (5 - y) * 0.5 && y <= 6) return WH; // white blaze
    if (y <= 3 && z >= 1) return WH; // white cheeks
    return OR;
  });
  // muzzle
  g.box(-3, 1, 4, 3, 4, 8, (x, y) => (y >= 4 && Math.abs(x) >= 2 ? OR : WH));
  g.box(-1, 3, 9, 1, 4, 9, PAL.black); // nose
  g.set(0, 4, 10, 0x2a2a2a);
  // mouth + tongue
  g.box(-2, 1, 9, 2, 1, 9, 0x5a2020);
  if (expr !== "calm") {
    g.box(-1, 0, 8, 1, -1, 9, 0xef6f86, M.LIT, 1);
    g.set(0, -2, 9, 0xef6f86, M.LIT, 1);
  }
  // eyes
  for (const s of [-1, 1]) {
    if (expr === "happy") {
      g.set(s * 3, 7, 5, PAL.black).set(s * 2, 8, 5, PAL.black).set(s * 4, 8, 5, PAL.black);
    } else {
      g.box(s * 2, 6, 5, s * 3, 8, 5, PAL.black);
      g.set(s * 2, 8, 6, 0xffffff, M.LIT, 0);
    }
  }
  // tall ears
  for (const s of [-1, 1])
    for (let y = 9; y <= 16; y++) {
      const w = Math.max(0, Math.round((16 - y) * 0.45));
      for (let dx = -w; dx <= w; dx++) {
        const x = s * 4 + dx + s * Math.round((y - 9) * 0.25);
        g.set(x, y, 0, OR);
        g.set(x, y, -1, ORD);
        if (Math.abs(dx) < w) g.set(x, y, 1, 0xf6b8a8);
      }
    }
  return g;
}

export function buildCorgi({ pose = "sit", expression = "happy" } = {}) {
  const root = new THREE.Group();
  root.name = "corgi";
  const body = new VoxelGrid({ jitter: 2, seam: 0.2, seed: 12 });
  const sit = pose === "sit";
  if (sit) {
    // sitting: body angled up, chest forward, haunches down
    for (let i = 0; i <= 10; i++) {
      const y = 4 + i * 0.9;
      const z = -4 + i * 0.55;
      body.ellipsoid(0, y, z, 5.6 - i * 0.1, 4.2, 4.6, (x, yy, zz) => (zz > z + 2.5 && Math.abs(x) < 4 ? WH : OR));
    }
    body.ellipsoid(0, 3, -4, 6.2, 3.5, 5.5, (x, y, z) => (y < 2 ? WH : OR)); // haunches
    for (const s of [-1, 1]) body.box(s * 3, 0, 2, s * 2, 6, 3, WH); // front legs
    for (const s of [-1, 1]) body.box(s * 4, 0, -2, s * 6, 1, 2, WH); // back paws
  } else {
    body.ellipsoid(0, 6, 0, 5.4, 4.4, 9.5, (x, y, z) => (y < 4 || (z > 5 && Math.abs(x) < 3) ? WH : OR));
    for (const [x, z] of [[-3, 6], [3, 6], [-3, -6], [3, -6]]) body.box(x - 1, 0, z - 1, x + 1, 3, z + 1, WH);
  }
  // blue collar with a gold tag
  const cy = sit ? 13 : 9,
    cz = sit ? 2 : 8;
  for (let a = 0; a < 28; a++) {
    const t = (a / 28) * Math.PI * 2;
    body.set(Math.round(Math.cos(t) * 4.3), cy, cz + Math.round(Math.sin(t) * 3.6), 0x2a55d8, M.LIT, 1);
  }
  body.set(0, cy - 1, cz + 4, PAL.gold, M.METAL, 1);
  // fluffy tail stub
  body.ellipsoid(0, sit ? 3 : 8, sit ? -9 : -10, 1.8, 1.8, 1.8, OR);
  root.add(toMesh(body, { size: S }));

  const headG = new THREE.Group();
  headG.position.set(0, (sit ? 14 : 10) * S, (sit ? 2.5 : 9) * S);
  root.add(headG);
  const heads = {};
  const setExpression = (e) => {
    if (!heads[e]) headG.add((heads[e] = toMesh(head(e), { size: S })));
    for (const k in heads) heads[k].visible = k === e;
  };
  setExpression(expression);
  headG.rotation.z = sit ? 0.12 : 0;
  root.userData.rig = { group: root, poses: ["sit", "stand"], expressions: ["happy", "eyes", "calm"], setExpression, head: headG };
  return root.userData.rig;
}
