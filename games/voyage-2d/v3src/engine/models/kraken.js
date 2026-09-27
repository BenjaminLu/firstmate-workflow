// Kraken: huge layered-voxel purple head with shading bands and spots, glowing
// square eyes (bloom), 8 segmented tentacles with pink suckers. Each tentacle is
// posed along a curvature-integrated curve (straight base, spiralling tip), so
// any pose is a handful of numbers: lean, heading, height, curl, twist.
// Poses: rise, attack, lurk, curl.  Expressions: glare, angry, hurt.
import * as THREE from "three";
import { VoxelGrid, M, hash3 } from "../voxel.js";
import { toMesh, PAL, materials } from "../materials.js";
import { meshGrid } from "../voxel.js";

const KS = 0.25;
const P0 = 0x2c1650,
  P1 = 0x42206e,
  P2 = 0x5b2f8f,
  P3 = 0x7a45b5,
  P4 = 0x9a64d0;

function headGrid(expr) {
  const g = new VoxelGrid({ jitter: 3, seam: 0.4, seed: 31 });
  const RX = 17,
    RY = 21,
    RZ = 16;
  // mantle: egg shape, fuller at the top, with a slight backward lean
  g.fill(-RX - 2, -6, -RZ - 6, RX + 2, RY * 2 + 4, RZ + 2, (x, y, z) => {
    const yy = y - 18;
    const lean = yy > 0 ? yy * 0.18 : 0;
    const k = yy > 0 ? 1 : 1.12;
    const d = (x / (RX * (1 - Math.max(0, yy) * 0.006))) ** 2 + (yy / (RY * k)) ** 2 + ((z + lean) / RZ) ** 2;
    if (d > 1) return null;
    if (d < 0.78) return null; // hollow shell
    // shading bands climbing the mantle + lighter spots
    const band = Math.floor((y + Math.round(Math.sin(x * 0.4) * 1.5)) / 3);
    let c = [P1, P2, P2, P3, P2, P3, P4, P3][((band % 8) + 8) % 8];
    if (y < 4) c = P1;
    if (y < 0) c = P0;
    const spot = hash3(Math.floor(x / 3), Math.floor(y / 3), Math.floor(z / 3));
    if (spot < 0.12 && y > 6) c = 0xb07ad8;
    if (spot > 0.93 && y > 6) c = P0;
    return c;
  });
  // lower "skirt" where the arms join: lumpy ring
  for (let a = 0; a < 48; a++) {
    const t = (a / 48) * Math.PI * 2;
    const r = 15 + hash3(a, 3, 1) * 3;
    g.ellipsoid(Math.cos(t) * r, 0 + hash3(a, 4, 1) * 3, Math.sin(t) * r * 0.9, 3.4, 4, 3.4, (x, y) => (y < 0 ? P0 : P1));
  }
  // brow ridge over the eyes
  const eyeY = 16,
    eyeZ = 15,
    eyeX = 8;
  for (const s of [-1, 1]) {
    for (let x = 2; x <= 14; x++) {
      const slant = expr === "angry" ? Math.round((14 - x) * -0.35) + 3 : expr === "hurt" ? Math.round((x - 2) * -0.3) + 1 : 0;
      g.box(s * x, eyeY + 6 + slant, eyeZ - 2, s * x, eyeY + 8 + slant, eyeZ + 1, x % 3 ? P1 : P0);
    }
  }
  // eyes: dark socket, glowing square ring, bright core, dark pupil slot
  for (const s of [-1, 1]) {
    const cx = s * eyeX;
    for (let x = -5; x <= 5; x++)
      for (let y = -5; y <= 5; y++) {
        const X = cx + x,
          Y = eyeY + y;
        const r = Math.max(Math.abs(x), Math.abs(y));
        let z = eyeZ + 1;
        // find the mantle surface along z
        for (let zz = eyeZ + 4; zz > 0; zz--)
          if (g.has(X, Y, zz)) {
            z = zz + 1;
            break;
          }
        if (r === 5) g.set(X, Y, z, P0, M.LIT, 1);
        else if (expr === "hurt" && r <= 4) g.set(X, Y, z, Math.abs(x) === Math.abs(y) ? 0xe070ff : P0, Math.abs(x) === Math.abs(y) ? M.GLOW : M.LIT, 0);
        else if (r >= 3) g.set(X, Y, z, 0xc84cff, M.GLOW, 0);
        else if (r === 2) g.set(X, Y, z, 0xf0b0ff, M.GLOW, 0);
        else g.set(X, Y, z, 0x1a0630, M.LIT, 0);
      }
  }
  // wide mouth crease under the eyes (dark) with beak hint
  for (let x = -6; x <= 6; x++) {
    const y = 5 - Math.round((x * x) / 18);
    for (let zz = RZ + 2; zz > 0; zz--)
      if (g.has(x, y, zz)) {
        g.set(x, y, zz, P0, M.LIT, 1);
        break;
      }
  }
  return g;
}

// one tentacle segment: a squashed voxel disc in the x-z plane, thickness along y,
// suckers on +z (the side facing the curl's centre)
function segmentGrids() {
  const body = new VoxelGrid({ jitter: 3, seam: 0.4, seed: 33 });
  const R = 5;
  for (let x = -R; x <= R; x++)
    for (let z = -R; z <= R; z++)
      for (let y = -1; y <= 1; y++) {
        const d = Math.hypot(x, z * 1.05);
        if (d > R + 0.3) continue;
        let c = y === 1 ? P2 : P1;
        if (z < -1) c = y === 1 ? P3 : P2; // lighter back
        if (Math.abs(x) >= R - 1) c = P1;
        if (z < -3 && hash3(x, y, z) < 0.3) c = P4;
        body.set(x, y, z, c);
      }
  // sucker: pink square ring with a darker hollow, proud of the inner face
  for (let x = -2; x <= 2; x++)
    for (let y = -1; y <= 1; y++) {
      const ring = Math.abs(x) === 2 || Math.abs(y) === 1;
      body.set(x, y, R + 1, ring ? PAL.sucker : PAL.suckerDark, M.LIT, 1);
      if (ring && Math.abs(x) === 2) body.set(x, y, R, PAL.sucker, M.LIT, 1);
    }
  return meshGrid(body, { size: KS });
}

// build a tentacle curve: returns arrays of positions/tangents/normals
function tentacleFrames(p, n) {
  const { base, heading, lean = 0.2, length = 14, curl = 5, twist = 0, droop = 0 } = p;
  const dir = new THREE.Vector3(Math.cos(heading), 0, Math.sin(heading));
  const up = new THREE.Vector3(0, 1, 0);
  const side = new THREE.Vector3().crossVectors(dir, up).normalize();
  const out = [];
  let theta = Math.PI / 2 - lean; // angle in the (dir, up) plane, measured from dir
  let u = 0,
    v = 0;
  const ds = length / n;
  for (let i = 0; i < n; i++) {
    const s = i / (n - 1);
    const kappa = (-droop + curl * Math.pow(s, 2.2)) / length;
    const T2 = [Math.cos(theta), Math.sin(theta)];
    const pos = new THREE.Vector3().copy(base).addScaledVector(dir, u).addScaledVector(up, v).addScaledVector(side, Math.sin(s * Math.PI) * twist);
    const T = new THREE.Vector3().copy(dir).multiplyScalar(T2[0]).addScaledVector(up, T2[1]).normalize();
    // inner normal: rotate the tangent toward the curl centre
    const sgn = Math.sign(curl || 1);
    const N = new THREE.Vector3().copy(dir).multiplyScalar(-T2[1] * sgn).addScaledVector(up, T2[0] * sgn).normalize();
    out.push({ pos, T, N, s });
    u += T2[0] * ds;
    v += T2[1] * ds;
    theta += kappa * ds * 2.2;
  }
  return out;
}

const POSES = {
  rise: { lean: 0.25, length: 15, curl: 7, twist: 1.2 },
  attack: { lean: 0.75, length: 17, curl: 4, twist: 2.5 },
  lurk: { lean: 1.35, length: 11, curl: 3.5, twist: 0.5 },
  curl: { lean: 0.1, length: 13, curl: 11, twist: 0.8 },
};

export function buildKraken({ pose = "rise", expression = "glare", tentacles = 8, segments = 30 } = {}) {
  const root = new THREE.Group();
  root.name = "kraken";
  const headPivot = new THREE.Group();
  root.add(headPivot);
  const heads = {};
  const setExpression = (e) => {
    if (!heads[e]) headPivot.add((heads[e] = toMesh(headGrid(e), { size: KS })));
    for (const k in heads) heads[k].visible = k === e;
    rig.expression = e;
  };
  // eye glow light
  const eyeLight = new THREE.PointLight(0xc050ff, 6, 14, 2);
  eyeLight.position.set(0, 16 * KS, 19 * KS);
  root.add(eyeLight);

  const { geometries } = segmentGrids();
  const total = tentacles * segments;
  const segMesh = new THREE.InstancedMesh(geometries[M.LIT], materials.lit, total);
  segMesh.castShadow = true;
  segMesh.receiveShadow = true;
  segMesh.frustumCulled = false;
  root.add(segMesh);

  const arms = [];
  for (let i = 0; i < tentacles; i++) {
    // arms fan around the front and sides of the head
    const a = -Math.PI * 0.15 + (i / (tentacles - 1)) * Math.PI * 1.3 + (i % 2 ? 0.1 : -0.1);
    const heading = a;
    const r = 3.4 + (i % 3) * 0.5;
    arms.push({ base: new THREE.Vector3(Math.cos(a) * r, -0.6, Math.sin(a) * r), heading, jitter: hash3(i, 2, 3) });
  }
  const m4 = new THREE.Matrix4();
  const basis = new THREE.Matrix4();
  const B = new THREE.Vector3();
  const setPose = (name, t = 0) => {
    const P = POSES[name] || POSES.rise;
    let k = 0;
    arms.forEach((arm, i) => {
      const j = arm.jitter;
      const params = {
        base: arm.base,
        heading: arm.heading,
        lean: P.lean + (j - 0.5) * 0.4 + Math.sin(t * 0.8 + i) * 0.05,
        length: P.length * (0.8 + j * 0.4),
        curl: P.curl * (0.8 + ((i * 7) % 5) * 0.1) * (i % 2 ? 1 : -1) + Math.sin(t * 1.1 + i * 2) * 0.6,
        twist: P.twist * (j - 0.5) * 2,
      };
      const fr = tentacleFrames(params, segments);
      for (const f of fr) {
        const taper = 1.25 - f.s * 0.95;
        B.crossVectors(f.T, f.N).normalize();
        // local x = binormal, local y = tangent, local z = inner normal
        basis.makeBasis(B, f.T, f.N);
        m4.copy(basis).scale(new THREE.Vector3(taper, taper * 1.25, taper)).setPosition(f.pos);
        segMesh.setMatrixAt(k++, m4);
      }
    });
    segMesh.instanceMatrix.needsUpdate = true;
    rig.pose = name;
  };
  const rig = { group: root, poses: Object.keys(POSES), expressions: ["glare", "angry", "hurt"], setPose, setExpression, head: headPivot, pose, expression, arms: segMesh };
  setExpression(expression);
  setPose(pose);
  root.userData.rig = rig;
  return rig;
}
