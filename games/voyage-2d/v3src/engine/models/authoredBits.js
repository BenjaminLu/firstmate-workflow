// p4: authored smooth hands and the robot's head, in place of soft voxels.
//
// Hands (grid units of the old hand grid: palm x -3..3, y -1..-5, fingers below): a
// rounded palm, a thumb that wraps the front, and fingers as capsules. Shapes: fist,
// open (fingers together, a little spread), point (the index out), grip (a hole for a
// handle). The thumb is on the inner side (side +1 = left hand).
//
// The robot (now a worker): a rounded white head shell with a dark glass screen, eyes
// that glow (open rounded bars, happy arcs, blink lines, a wink), ear discs in the
// orange accent and an antenna with a glowing ball; the same toon material and faint
// grid as the crew, and the glow in a separate unlit material (it blooms).
import * as THREE from "three";
import { RoundedBoxGeometry } from "three/addons/geometries/RoundedBoxGeometry.js";
import { mergeGeometries } from "three/addons/utils/BufferGeometryUtils.js";
import { finish, meshOf } from "./captainSmooth.js";
import { loftQuality } from "./crewSmooth.js";

const LOW = () => loftQuality() < 1;
const shade = (hex, k) => {
  const c = new THREE.Color(hex).multiplyScalar(k);
  return c.getHex();
};
const rbox = (w, h, d, at, colour, r = 0.6, seg = 2) => finish(new RoundedBoxGeometry(w, h, d, LOW() ? 1 : seg, Math.min(r, w / 2 - 0.01, h / 2 - 0.01, d / 2 - 0.01)).translate(...at), colour);
const cap = (r, a, b, colour) => {
  const A = new THREE.Vector3(...a), B = new THREE.Vector3(...b);
  const len = A.distanceTo(B);
  const g = new THREE.CapsuleGeometry(r, Math.max(0.01, len), LOW() ? 2 : 3, LOW() ? 6 : 8);
  g.applyQuaternion(new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 1, 0), B.clone().sub(A).normalize()));
  g.translate(...A.clone().add(B).multiplyScalar(0.5).toArray());
  return finish(g, colour);
};

export function smoothHand(shape, skin, side, unit) {
  const dark = shade(skin, 0.86);
  const tx = -side * 3.6;
  const parts = [];
  if (shape === "open") {
    parts.push(rbox(6.6, 5.2, 2.6, [0, -3.1, 0.3], skin, 1.1));
    const xs = [-2.4, -0.8, 0.8, 2.4];
    xs.forEach((x, i) => parts.push(cap(0.78, [x, -5.3, 0.4], [x * 1.08, -8.6 - (i === 1 || i === 2 ? 0.5 : 0), 0.5], i % 2 ? skin : dark)));
    parts.push(cap(0.85, [tx * 0.8, -2.2, 0.6], [tx * 1.15, -5.0, 1.2], skin));
  } else {
    // the fist: a rounded block, knuckles along the front, the thumb across it
    parts.push(rbox(6.8, 5.4, 6.2, [0, -3.2, 0.2], skin, 1.6));
    for (const x of [-2.4, -0.8, 0.8, 2.4]) parts.push(cap(0.85, [x, -5.6, 1.2], [x, -5.7, 2.6], dark));
    parts.push(cap(0.95, [tx, -2.4, 1.6], [tx * 0.25, -4.2, 3.4], skin));
    if (shape === "point") {
      const ix = -side * 1.6;
      parts.push(cap(0.82, [ix, -5.4, 2.2], [ix, -11.2, 2.6], skin));
    }
  }
  const m = meshOf(parts, unit);
  m.name = "hand-" + shape;
  return m;
}

// ---------------------------------------------------------------- the robot's head
const WHITE = 0xf1f3f7, PANEL = 0xc9ced9, JOINT = 0x6d7482, SCREEN = 0x0e1630, ACC = 0xb8662e;
let GLOW = null;
const glowMat = () => (GLOW ||= new THREE.MeshBasicMaterial({ vertexColors: true, color: new THREE.Color(2.6, 2.6, 2.6), toneMapped: true }));
export function robotHeadSmooth(expr, unit) {
  // grid units, as the voxel head: x -10..10, y 0..16, z -8..8
  const parts = [];
  parts.push(rbox(21, 16.5, 17, [0, 8.2, 0], WHITE, 4, 3));
  parts.push(rbox(21.4, 1.2, 17.4, [0, 3.2, 0], PANEL, 0.5)); // a seam band round the jaw
  parts.push(rbox(17.2, 11, 1.4, [0, 8.8, 8.3], SCREEN, 2.2, 3)); // the glass
  parts.push(rbox(18.2, 12, 0.6, [0, 8.8, 7.9], JOINT, 2.6)); // its bezel
  for (const s of [-1, 1]) {
    parts.push(finish(new THREE.CylinderGeometry(3.3, 3.3, 1.6, LOW() ? 10 : 18).rotateZ(Math.PI / 2).translate(s * 11.0, 8.5, 0), ACC));
    parts.push(finish(new THREE.CylinderGeometry(2.0, 2.0, 1.0, LOW() ? 8 : 14).rotateZ(Math.PI / 2).translate(s * 12.0, 8.5, 0), JOINT));
  }
  parts.push(finish(new THREE.CylinderGeometry(0.55, 0.7, 4.2, 8).translate(0, 18.6, 0), JOINT));
  parts.push(finish(new THREE.CylinderGeometry(1.6, 2.2, 0.8, 12).translate(0, 16.8, 0), PANEL));
  const shell = meshOf(parts, unit);
  // the glow: eyes (by expression), the antenna ball
  const EYE = 0x3a9cff, g = [];
  const bar = (x, y, w, h) => finish(new RoundedBoxGeometry(w, h, 0.5, 1, Math.min(w, h) * 0.45).translate(x, y, 9.1), EYE);
  const arc = (x, y, r) => finish(new THREE.TorusGeometry(r, 0.55, 5, 14, Math.PI).translate(x, y, 9.1), EYE);
  for (const s of [-1, 1]) {
    const x = s * 4;
    if (expr === "happy") g.push(arc(x, 7.4, 2.2));
    else if (expr === "blink" || (expr === "wink" && s > 0)) g.push(bar(x, 8.4, 4.6, 0.9));
    else g.push(bar(x, 8.8, 2.6, 6.2));
  }
  if (expr === "happy" || expr === "wink") g.push(finish(new THREE.TorusGeometry(2.2, 0.45, 5, 14, Math.PI).rotateZ(Math.PI).translate(0, 5.2, 9.1), EYE)); // a smile
  g.push(finish(new THREE.SphereGeometry(2.1, 12, 9).translate(0, 22.2, 0), 0x2f7dff));
  const glow = new THREE.Mesh(mergeGeometries(g, false).scale(unit, unit, unit), glowMat());
  glow.castShadow = false;
  const head = new THREE.Group();
  head.add(shell, glow);
  head.userData.robotHead = true;
  return head;
}
