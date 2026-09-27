// Scarlet macaw: red body, yellow and blue wing bands, curved beak.
// Poses: perch (wings folded), flap (wings spread up).
import * as THREE from "three";
import { VoxelGrid, M } from "../voxel.js";
import { toMesh, PAL } from "../materials.js";

const S = 0.04;
const RED = 0xe0262a;
const REDD = 0xa81a20;
const YEL = 0xffc62a;
const BLU = 0x2a6ae0;
const BLUD = 0x1a3ea8;

function wing(spread) {
  const g = new VoxelGrid({ jitter: 1, seam: 0.2, seed: 21 });
  // wing is authored flat along -y (folded), pivot at the shoulder
  for (let y = 0; y >= -14; y--)
    for (let z = -2; z <= 3; z++) {
      const w = y > -4 ? 3 : y > -10 ? 2 : 1;
      if (z > w) continue;
      const band = y > -4 ? RED : y > -7 ? YEL : y > -11 ? BLU : BLUD;
      g.set(0, y, z, band, M.LIT, 1);
      if (y > -6 && z < 2) g.set(spread ? 1 : -1, y, z, band === RED ? REDD : band, M.LIT, 1);
    }
  return g;
}

export function buildParrot({ pose = "perch" } = {}) {
  const root = new THREE.Group();
  root.name = "parrot";
  const g = new VoxelGrid({ jitter: 1, seam: 0.2, seed: 22 });
  // body tilted upright, head on top
  g.ellipsoid(0, 8, 0, 3.6, 6, 3.6, (x, y, z) => (z > 2 && y < 9 ? 0xf04030 : RED));
  g.ellipsoid(0, 16, 1, 3.8, 3.8, 3.8, RED);
  // white face patch + eye
  for (const s of [-1, 1]) {
    g.box(s * 3, 15, 2, s * 4, 17, 4, 0xf6f0ea, M.LIT, 1);
    g.set(s * 4, 16, 3, PAL.black, M.LIT, 0);
    g.set(s * 4, 17, 3, 0xffe066, M.LIT, 0);
  }
  // beak: pale upper hooking down, dark lower
  g.box(-1, 15, 4, 1, 17, 6, 0xf4e8d6, M.LIT, 1);
  g.box(-1, 14, 7, 1, 15, 7, 0xf4e8d6, M.LIT, 1);
  g.set(0, 13, 7, 0x2a2a2a);
  g.box(-1, 13, 5, 1, 14, 6, 0x2a2a2a);
  // long tail: red then blue
  for (let i = 0; i < 14; i++) {
    const y = 3 - i;
    const z = -3 - Math.round(i * 0.45);
    const c = i < 6 ? RED : i < 10 ? BLU : BLUD;
    g.box(-1, y, z, 1, y, z, c, M.LIT, 1);
    if (i < 10) g.set(0, y, z - 1, c, M.LIT, 1);
  }
  // feet gripping a perch
  for (const s of [-1, 1]) g.box(s * 2, 0, 0, s * 1, 1, 2, 0x5a5a5a);
  root.add(toMesh(g, { size: S }));
  const wings = [];
  for (const s of [-1, 1]) {
    const piv = new THREE.Group();
    piv.position.set(s * 3.8 * S, 12 * S, 0);
    const m = toMesh(wing(pose === "flap"), { size: S });
    if (s < 0) m.scale.x = -1;
    piv.add(m);
    root.add(piv);
    wings.push(piv);
  }
  const setPose = (p) => {
    for (const [i, w] of wings.entries()) {
      const s = i === 0 ? -1 : 1;
      if (p === "flap") w.rotation.set(0.2, 0, s * 2.5);
      else w.rotation.set(0.35, 0, s * 0.08);
    }
  };
  setPose(pose);
  root.userData.rig = { group: root, poses: ["perch", "flap"], expressions: ["eyes"], setPose, setExpression() {} };
  return root.userData.rig;
}
