// Small voxel props for the deck actions (prototype v2: "every action holds or
// stands at something"). Hand props put the grip at the origin, handle along +z.
import * as THREE from "three";
import { VoxelGrid, M } from "../engine/voxel.js";
import { toMesh, PAL } from "../engine/materials.js";
import * as P from "../engine/models/props.js";

const g = (o) => new VoxelGrid({ jitter: 2, seam: 0.25, ...o });
const m = (grid, s = 0.05, name) => toMesh(grid, { size: s, name });

export function saw() {
  const v = g();
  v.box(-1, -1, -2, 1, 1, 1, 0x7a4a26); // handle
  v.box(0, -1, 2, 0, 1, 14, 0xb8bcc6, M.METAL, 1); // blade
  for (let z = 3; z <= 14; z += 2) v.set(0, -2, z, 0x8a8e98, M.METAL, 1); // teeth
  return m(v, 0.05, "saw");
}
export function swab() {
  const v = g();
  v.box(0, 0, -2, 0, 0, 16, 0x8a5a30); // pole
  for (let x = -2; x <= 2; x++) for (let y = -2; y <= 2; y++) for (let z = 17; z <= 20; z++) if (Math.abs(x) + Math.abs(y) < 4) v.set(x, y, z, 0xd8ccb0, M.CLOTH, 3); // mop head
  return m(v, 0.05, "swab");
}
export function flag(color = 0xd83a2c) {
  const v = g({ jitter: 1 });
  v.box(0, 0, -2, 0, 0, 12, 0x8a5a30);
  for (let x = 1; x <= 8; x++) for (let z = 7; z <= 12; z++) v.set(x, 0, z, (x + z) % 4 < 2 ? color : 0xf4e6c8, M.CLOTH, 1);
  return m(v, 0.05, "flag");
}
export function logbook() {
  const v = g({ jitter: 1 });
  v.box(-3, -1, -2, 3, 1, 3, 0x6b2a1a);
  v.box(-3, 1, -2, 3, 1, 3, 0xf0dfb0);
  v.box(0, 1, -2, 0, 1, 3, 0x8a5a30);
  return m(v, 0.05, "logbook");
}
export function quill() {
  const v = g({ jitter: 1 });
  v.box(0, 0, 0, 0, 0, 8, 0xf6f6f8, M.CLOTH, 1);
  v.box(0, 1, 3, 0, 1, 8, 0xe8e8ee, M.CLOTH, 1);
  return m(v, 0.04, "quill");
}
export function crate() {
  return P.buildCrate({ scale: 0.05, w: 9, h: 7, d: 8 });
}
export function coil() {
  const v = g({ jitter: 2 });
  for (let a = 0; a < 40; a++) {
    const t = (a / 40) * Math.PI * 2;
    for (let r of [3, 4]) v.set(Math.round(Math.cos(t) * r), 0, Math.round(Math.sin(t) * r), PAL.rope);
  }
  v.set(0, 1, 4, PAL.rope);
  return m(v, 0.05, "coil");
}
export function sailcloth() {
  const v = g({ jitter: 1 });
  for (let x = -6; x <= 6; x++) for (let z = -1; z <= 8; z++) v.set(x, Math.round(Math.sin(x * 0.6)), z, (x + z) % 5 ? PAL.cream : PAL.creamShade, M.CLOTH, 1);
  return m(v, 0.05, "sailcloth");
}
export function cutlass() {
  const v = g({ jitter: 1 });
  v.box(-1, -1, -2, 1, 1, 1, 0x3a2412); // grip
  v.box(-2, -2, 2, 2, 2, 2, PAL.gold, M.METAL, 1); // guard
  for (let z = 3; z <= 17; z++) v.box(0, 0, z, 0, Math.round(Math.sin((z - 3) / 14 * 1.2) * 1.5) + 1, z, 0xd8dce4, M.METAL, 1); // curved blade
  return m(v, 0.045, "cutlass");
}
export function rope(len = 2) {
  const mesh = new THREE.Mesh(new THREE.BoxGeometry(0.05, 0.05, len), new THREE.MeshStandardMaterial({ color: PAL.rope, roughness: 0.95 }));
  mesh.name = "rope";
  return mesh;
}
export function capstan() {
  const v = g({ jitter: 3, seam: 0.3 });
  v.cyl("y", 0, 9, 0, 0, 3.2, (a) => (a % 3 === 0 ? PAL.iron : 0x7a4a26));
  v.cyl("y", 10, 11, 0, 0, 4.2, 0x5a3418);
  for (let k = 0; k < 4; k++) {
    const t = (k / 4) * Math.PI * 2;
    v.line(0, 9, 0, Math.cos(t) * 10, 9, Math.sin(t) * 10, 0.5, 0x8a5a30);
  }
  return m(v, 0.05, "capstan");
}
export function sawhorse() {
  const v = g({ jitter: 2 });
  v.box(-8, 6, -1, 8, 7, 1, 0x8a5a30);
  for (const x of [-7, 7]) for (const z of [-3, 3]) v.line(x, 0, z, x, 6, z * 0.3, 0.5, 0x6b4226);
  v.box(-6, 8, -2, 4, 8, 2, 0xb07c48); // the plank being sawn
  return m(v, 0.05, "sawhorse");
}
export function bucket() {
  const v = g({ jitter: 2 });
  v.cyl("y", 0, 5, 0, 0, 3, (a) => (a === 1 || a === 4 ? PAL.iron : 0x7a4a26));
  v.cyl("y", 5, 5, 0, 0, 2.2, 0x3a6ab8, M.LIT, 1);
  return m(v, 0.05, "bucket");
}
export function chartTable() {
  const v = g({ jitter: 2 });
  v.box(-6, 7, -4, 6, 7, 4, 0x6b4226);
  for (const x of [-5, 5]) for (const z of [-3, 3]) v.box(x, 0, z, x, 6, z, 0x5a3418);
  const t = m(v, 0.05, "chartTable");
  const map = P.buildMap({ scale: 0.025, w: 20, d: 14 });
  map.position.y = 8 * 0.05;
  t.add(map);
  return t;
}
export function plank() {
  const v = g({ jitter: 3 });
  v.box(-6, 0, -1, 6, 0, 1, 0xb07c48);
  return m(v, 0.05, "plank");
}
export function criteriaList() {
  // the reviewer's answer: a parchment list with three check marks
  const v = g({ jitter: 1 });
  for (let x = -4; x <= 4; x++) for (let y = -6; y <= 6; y++) v.set(x, y, 0, 0xf2e2b6, M.LIT, 1);
  for (const y of [3, 0, -3]) {
    v.set(-3, y, 1, 0x2f9a4a, M.LIT, 1);
    v.set(-2, y - 1, 1, 0x2f9a4a, M.LIT, 1);
    for (let x = 0; x <= 3; x++) v.set(x, y, 1, 0x7a5a3a, M.LIT, 1);
  }
  return m(v, 0.05, "criteria");
}
export function decisionPlacard(color = 0xf2b53a) {
  // the captain's card raised at the helm
  const v = g({ jitter: 1 });
  for (let x = -5; x <= 5; x++) for (let y = -7; y <= 7; y++) v.set(x, y, 0, Math.abs(x) === 5 || Math.abs(y) === 7 ? color : 0xf4e6c8, M.LIT, 1);
  v.box(0, -14, 0, 0, -8, 0, 0x6b4226);
  for (const [x, y] of [[-2, 3], [0, 4], [2, 3], [0, 1], [-1, -2], [1, -2], [0, -4]]) v.set(x, y, 1, 0x1f2f86, M.LIT, 1);
  return m(v, 0.06, "placard");
}
export const kit = { saw, swab, flag, logbook, quill, crate, coil, sailcloth, cutlass, rope, capstan, sawhorse, bucket, chartTable, plank, criteriaList, decisionPlacard };
