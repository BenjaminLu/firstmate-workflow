// Shared chibi rig, built to the ratios in PROPORTIONS.md (3.0 heads tall,
// shoulders 1.3 head widths, arms to mid-thigh, visible neck, booted legs).
//
// Two voxel scales:
//   CS = 0.05  body: legs y -1..-11 under the hip pivot, torso y 0..10 (+ neck y 11),
//              arms: upper y 0..-4 from the shoulder, forearm y 0..-4 from the elbow
//   HS = 0.03  head, face, hair, hats and hands (1.7x the face resolution)
//              head: x -9..9, y 0..18 (chin at y 0), z -8..8, face toward +z
// Characters supply paint callbacks and pose tables; the rig builds, caches
// per-expression heads and per-shape hands, and poses with FK or two-bone IK.
import * as THREE from "three";
import { VoxelGrid, M, hash3 } from "../voxel.js";
import { toMesh, PAL } from "../materials.js";

export const CS = 0.05;
export const HS = 0.03;
const D2R = Math.PI / 180;
const LEG = 11; // leg voxels
const HIP = LEG + 0.5; // hip pivot height above the soles, in CS
const NECK_TOP = 11.35; // head sits here (torso CS)
const SHOULDER = [5.5, 9]; // |x|, y in torso CS
const UPPER = 5;
const WRIST = 4.6; // hand group below the elbow, CS
const GRIP = 2.6; // grip centre below the wrist, HS

// ---------------------------------------------------------------- head shape
const HX = 9.5,
  HZ = 8.6;
// half-width of the skull at height y (voxel-stepped oval: dome, cheeks, narrower jaw)
function skullHalf(y) {
  if (y > 18) return -1;
  if (y >= 14) return HX * Math.sqrt(Math.max(0, 1 - ((y - 13) / 6.2) ** 2));
  if (y >= 5) return HX;
  return HX - (5 - y) * 0.95;
}
export function inSkull(x, y, z) {
  const h = skullHalf(y);
  if (h < 0 || y < 0) return false;
  const k = h / HX;
  const p = 2.6;
  return (Math.abs(x) / (HX * k)) ** p + (Math.abs(z) / (HZ * (0.75 + 0.25 * k))) ** p <= 1;
}
// frontmost skull z at (x, y)
export function frontZ(x, y) {
  for (let z = 10; z >= -10; z--) if (inSkull(x, y, z)) return z;
  return null;
}

function skull(g, skin) {
  for (let x = -10; x <= 10; x++) for (let y = 0; y <= 18; y++) for (let z = -9; z <= 9; z++) if (inSkull(x, y, z)) g.set(x, y, z, skin, M.LIT, 1);
  // ears
  for (const s of [-1, 1]) {
    g.box(s * 10, 6, -1, s * 10, 9, 1, skin, M.LIT, 1);
    g.box(s * 10, 7, 0, s * 10, 8, 0, PAL.skinShade, M.LIT, 1);
  }
}

// ---------------------------------------------------------------- face
export function paintFace(g, expr, { eye = 0x17121e, brow = PAL.hair, blush = true, sclera = false, lashes = false, mouthW = 3 } = {}) {
  // on the frontmost skull voxel of each (x, y)
  const P = (x, y, c, dz = 0) => {
    const z = frontZ(x, y);
    if (z === null) return;
    g.set(x, y, z + dz, c, M.LIT, 1);
  };
  const L = -4,
    R = 4; // eye centres
  const openEye = (cx, look = 0) => {
    const out = Math.sign(cx);
    for (let dx = -1; dx <= 1; dx++) for (let y = 7; y <= 10; y++) P(cx + dx, y, sclera ? 0xfbfbfd : eye);
    if (sclera) {
      for (const dx of [0, -out]) for (let y = 7; y <= 9; y++) P(cx + dx + look, y, eye);
      P(cx + look, 9, 0xffffff);
    } else {
      P(cx + look, 7, 0x5a3426); // warm iris bottom
      P(cx - out, 10, 0xffffff); // big glint
      P(cx - out, 9, 0xffffff);
      P(cx + out, 7, 0xd8e6ff); // small glint
    }
    // upper lid line + outer lash
    for (let dx = -1; dx <= 1; dx++) P(cx + dx, 11, eye);
    if (lashes) P(cx + out * 2, 11, eye), P(cx + out * 2, 12, eye);
    else P(cx + out * 2, 10, eye);
  };
  const happyEye = (cx) => {
    P(cx - 2, 8, eye);
    P(cx - 1, 9, eye);
    P(cx, 10, eye);
    P(cx + 1, 9, eye);
    P(cx + 2, 8, eye);
  };
  const fierceEye = (cx) => {
    const out = Math.sign(cx);
    for (let dx = -1; dx <= 1; dx++) for (let y = 7; y <= 9; y++) P(cx + dx, y, eye);
    P(cx - out, 9, 0xffffff);
    for (let dx = -1; dx <= 2; dx++) P(cx + dx * out, 10, eye);
  };
  const brows = (kind) => {
    for (const cx of [L, R]) {
      const inn = -Math.sign(cx);
      for (let dx = -2; dx <= 1; dx++) {
        const x = cx - dx * inn; // dx>0 toward the outside
        let y = 13;
        if (kind === "angry") y = 13 - (dx <= -1 ? 1 : 0) + (dx >= 1 ? 1 : 0);
        if (kind === "up") y = 13 + (dx >= 0 ? 1 : 0);
        P(x, y, brow);
        if (kind !== "thin") P(x, y + 1, dx === -2 || dx === 1 ? null : brow);
      }
    }
  };
  // nose, blush
  g.set(0, 6, (frontZ(0, 6) ?? 8) + 1, PAL.skinShade, M.LIT, 1);
  if (blush) for (const x of [-7, -6, 6, 7]) P(x, 5, PAL.blush);
  const w = mouthW;
  const bigMouth = (tongue = true) => {
    for (let x = -w; x <= w; x++) P(x, 4, Math.abs(x) === w ? PAL.mouth : 0xffffff);
    for (let x = -w; x <= w; x++) P(x, 3, PAL.mouth);
    for (let x = -w + 1; x <= w - 1; x++) P(x, 2, tongue && Math.abs(x) <= w - 2 ? PAL.tongue : PAL.mouth);
    for (let x = -w + 2; x <= w - 2; x++) P(x, 1, PAL.mouth);
  };
  switch (expr) {
    case "joy":
    case "cheer":
      happyEye(L);
      happyEye(R);
      brows("up");
      bigMouth();
      break;
    case "grin":
      openEye(L);
      openEye(R);
      brows("up");
      bigMouth();
      break;
    case "shout":
      fierceEye(L);
      fierceEye(R);
      brows("angry");
      bigMouth();
      for (let x = -w + 1; x <= w - 1; x++) P(x, 1, PAL.mouth);
      break;
    case "focus":
      openEye(L, 0);
      openEye(R, 0);
      brows("angry");
      for (let x = -2; x <= 2; x++) P(x, 3, PAL.mouth);
      P(-2, 4, PAL.mouth);
      P(2, 4, PAL.mouth);
      break;
    case "surprise":
      openEye(L);
      openEye(R);
      brows("up");
      for (let x = -1; x <= 1; x++) for (let y = 1; y <= 4; y++) P(x, y, PAL.mouth);
      P(0, 1, PAL.tongue);
      break;
    default: // smile
      openEye(L);
      openEye(R);
      brows("flat");
      for (let x = -w + 1; x <= w - 1; x++) P(x, 3, Math.abs(x) === w - 1 ? PAL.mouth : 0xffffff);
      for (let x = -w + 2; x <= w - 2; x++) P(x, 2, x === 0 ? PAL.tongue : PAL.mouth);
  }
}

// ---------------------------------------------------------------- hair
// Volume: a 1-2 voxel shell over the crown, back and sides, jagged strand clumps
// for bangs, sideburns, and tufts that stick out. capY removes what a hat covers.
export function paintHair(g, { color = PAL.hair, hi = PAL.hairHi, style = "messy", capY = 99, seed = 1 } = {}) {
  const H = (x, y, z) => {
    if (y >= capY && Math.abs(x) <= 12) return;
    // strands: colour runs in vertical streaks
    const streak = hash3(x * 3 + seed, Math.floor(y / 3), z * 5 + seed);
    g.set(x, y, z, streak < 0.22 ? hi : streak > 0.9 ? 0x0e0a08 : color, M.LIT, 2);
  };
  const back = style === "long" ? -6 : 3;
  for (let x = -11; x <= 11; x++)
    for (let y = back; y <= 20; y++)
      for (let z = -11; z <= 10; z++) {
        if (inSkull(x, y, z) && y < 15) continue;
        // shell: within 2 voxels outside the skull
        const near = inSkull(x, y - 2, z) || inSkull(x - Math.sign(x) * 2, y, z) || inSkull(x, y, z + 2) || inSkull(x, y, z - 2) || inSkull(x - Math.sign(x), y - 1, z + 1);
        if (!near && !(inSkull(x, y, z) && y >= 15)) continue;
        const fz = frontZ(x, Math.min(y, 18));
        // keep the face open below the fringe line
        if (z >= (fz ?? 8) - 1 && y < 14 && Math.abs(x) <= 8) continue;
        if (y < 10 && z > -2 && Math.abs(x) <= 10) {
          // sides: only sideburns in front of the ears
          if (!(Math.abs(x) >= 9 && z >= 2 && z <= 4 && y >= 5)) continue;
        }
        if (Math.abs(x) >= 10 && y >= 5 && y <= 10 && Math.abs(z) <= 1) continue; // ears
        if (style !== "long" && y < 6 && z > -6) continue;
        H(x, y, z);
      }
  // bangs: strand clumps over the forehead, 3 wide, alternating lengths
  for (let x = -9; x <= 9; x++) {
    const clump = Math.floor((x + 9) / 3);
    const len = style === "neat" ? 0 : [2, 3, 1, 3, 2, 3, 1][clump % 7];
    const edge = (x + 9) % 3 === 2 ? 1 : 0;
    for (let y = 16 - len + edge; y <= 17; y++) {
      const fz = frontZ(x, Math.min(y, 17)) ?? 7;
      H(x, y, fz + 1);
    }
  }
  if (style === "messy" || style === "long") {
    const tufts = [[-11, 12, 0], [-12, 13, 1], [11, 13, -1], [12, 12, 0], [-11, 9, -3], [11, 10, -4], [-6, 11, -10], [5, 9, -10], [0, 12, -10], [-10, 15, 3], [10, 15, 3]];
    for (const [x, y, z] of tufts) H(x, y, z);
  }
  if (style === "long") {
    // long curly hair to the shoulders: curl clumps at the back and sides
    for (let n = 0; n < 70; n++) {
      const a = (hash3(n, 1, 9) - 0.5) * Math.PI * 1.5 + Math.PI; // behind
      const r = 10.5;
      const x = Math.round(Math.sin(a) * r);
      const z = Math.round(Math.cos(a) * 9) - 1;
      const y = Math.round(hash3(n, 2, 9) * 16) - 6;
      g.ellipsoid(x, y, z, 1.3, 1.3, 1.3, (xx, yy, zz) => (hash3(xx, yy, zz) < 0.3 ? PAL.hairHi : color), M.LIT, 2);
    }
  }
}

// ---------------------------------------------------------------- hats (HS)
export function sailorCap(g, { band = PAL.navy, top = PAL.white, emblem = PAL.navy, ribbon = true } = {}) {
  // a white box widening toward the top, navy band, anchor badge, ribbon tails
  for (let y = 14; y <= 24; y++) {
    const hw = y <= 17 ? 11 : 11 + Math.min(2, (y - 17) * 0.5);
    for (let x = -13; x <= 13; x++)
      for (let z = -12; z <= 12; z++) {
        const r = (Math.abs(x) / (hw + 0.4)) ** 4 + (Math.abs(z - 0.5) / (hw - 0.6)) ** 4;
        if (r > 1) continue;
        const shell = y === 24 || r > 0.62 || y <= 16;
        if (!shell) continue;
        let c = y <= 16 ? band : top;
        if (y === 24 && r < 0.5) c = PAL.offWhite;
        if (y === 17) c = 0xdfe3ec; // fold above the band
        if (y >= 18 && r > 0.62 && (x + z + y) % 7 === 0 && y > 19) c = 0x5a6aa8; // blue studs like the paintings
        g.set(x, y, z, c, M.LIT, 1);
      }
  }
  // anchor badge
  const A = ["..#..", ".###.", "..#..", "..#..", "#.#.#", ".###."];
  A.forEach((row, i) =>
    [...row].forEach((ch, j) => {
      if (ch !== "#") return;
      const x = j - 2,
        y = 23 - i;
      let z = 14;
      while (z > 0 && !g.has(x, y, z)) z--;
      g.set(x, y, z + 1, emblem, M.LIT, 1);
    }),
  );
  if (ribbon) {
    // navy ribbon bow + tails at the side, like the paintings
    g.box(11, 14, 2, 13, 16, 4, band, M.CLOTH, 1);
    for (let i = 0; i < 6; i++) {
      g.set(13 + (i >> 1), 13 - i, 3, band, M.CLOTH, 1);
      g.set(13 + (i >> 1), 13 - i, 4, PAL.navyDark, M.CLOTH, 1);
      g.set(12, 12 - i, 1, band, M.CLOTH, 1);
    }
  }
}

export function tricorn(g) {
  const BLK = 0x17171e,
    BLK2 = 0x23232d;
  for (let x = -10; x <= 10; x++)
    for (let z = -9; z <= 9; z++)
      for (let y = 15; y <= 26; y++) {
        const r = (x / 10) ** 2 + (z / 9) ** 2;
        if (r > 1 - Math.max(0, y - 21) * 0.14) continue;
        g.set(x, y, z, (x + y) % 5 === 0 ? BLK2 : BLK, M.LIT, 2);
      }
  // brim: rounded triangle, three walls pinned up, corners low, gold braid on the rim
  for (let x = -19; x <= 19; x++)
    for (let z = -17; z <= 20; z++) {
      const a = Math.atan2(x, z - 1);
      const c3 = Math.cos(3 * a);
      const R = 13.6 + 4 * c3;
      const r = Math.hypot(x, z - 1);
      if (r > R + 0.5) continue;
      const wallTop = Math.round(18.5 - 3.4 * c3);
      if (r > R - 1.6) {
        for (let y = 15; y <= wallTop; y++) {
          const rim = y >= wallTop - 1;
          g.set(x, y, z, rim ? PAL.gold : BLK, rim ? M.METAL : M.LIT, rim ? 1 : 2);
        }
      } else g.set(x, 15, z, BLK, M.LIT, 2);
    }
  // gold scroll ornament on the front wall + a cockade
  for (const [x, y] of [[-3, 18], [-2, 19], [-1, 18], [1, 18], [2, 19], [3, 18], [0, 17]]) {
    let z = 22;
    while (z > 0 && !g.has(x, y, z)) z--;
    if (z > 0) g.set(x, y, z + 1, PAL.gold, M.METAL, 1);
  }
}

// boxy cloth wrap tied at the side with two trailing knot tails (reviewer, red sailor)
export function bandana(g, { color = PAL.red, dark = PAL.redDark, tail = 0x2fb09a, dots = true } = {}) {
  for (let y = 13; y <= 21; y++)
    for (let x = -12; x <= 12; x++)
      for (let z = -11; z <= 11; z++) {
        const top = y >= 20;
        const hw = top ? 10.4 - (y - 20) * 1.2 : 11.2;
        const r = (Math.abs(x) / hw) ** 5 + (Math.abs(z) / (hw - 1)) ** 5;
        if (r > 1) continue;
        if (r < 0.55 && y < 21) continue; // shell
        if (y < 14 && z > 4) continue; // hem sits higher over the forehead
        const fold = (x + y * 3 + 60) % 9 === 0 || (y === 15 && r > 0.8);
        g.set(x, y, z, fold ? dark : color, M.CLOTH, 2);
      }
  if (dots) for (const [x, y] of [[-7, 18], [-2, 19], [4, 18], [8, 19], [-4, 16], [1, 16]]) {
    let z = 13;
    while (z > 0 && !g.has(x, y, z)) z--;
    if (z > 0) g.set(x, y, z, 0xf4f0ea, M.CLOTH, 1);
  }
  // knot on the right side (+x): a lump + two tails splaying out and down
  g.ellipsoid(12, 16, -3, 1.6, 1.6, 1.6, dark, M.CLOTH, 1);
  for (let i = 0; i < 7; i++) {
    const w = i < 3 ? 1 : 0;
    g.box(13 + i, 17 + Math.round(i * 0.5), -3 - w, 13 + i, 18 + Math.round(i * 0.5), -3 + w, tail, M.CLOTH, 1);
    g.box(13 + i, 15 - Math.round(i * 0.8), -4, 13 + i, 16 - Math.round(i * 0.8), -2 - w, tail, M.CLOTH, 1);
  }
  // small tail on the left
  for (let i = 0; i < 4; i++) g.box(-13 - i, 17 + (i >> 1), -3, -13 - i, 18 + (i >> 1), -2, tail, M.CLOTH, 1);
}

export function glasses(g, { frame = 0x121216 } = {}) {
  for (const cx of [-4, 4]) {
    for (let x = cx - 3; x <= cx + 3; x++)
      for (let y = 5; y <= 12; y++) {
        const ex = x === cx - 3 || x === cx + 3,
          ey = y === 5 || y === 12;
        if (!(ex || ey) || (ex && ey)) continue;
        const z = (frontZ(x, y) ?? 7) + 1;
        g.set(x, y, z, frame, M.METAL, 0);
      }
  }
  g.box(-1, 9, 9, 1, 9, 9, frame, M.METAL, 0);
  for (const s of [-1, 1]) g.box(s * 10, 9, -1, s * 10, 9, 6, frame, M.METAL, 0);
}

export function beard(g, expr) {
  const B = (x, y, z) => g.set(x, y, z, hash3(x, y * 3, z * 7) < 0.3 ? 0x3a2618 : PAL.beard, M.LIT, 3);
  const open = ["joy", "cheer", "shout", "grin"].includes(expr);
  const mw = open ? 4 : 3;
  for (let y = -6; y <= 5; y++) {
    const w = y >= 1 ? 10 : Math.round(10 + (y - 1) * 1.2);
    for (let x = -w; x <= w; x++) {
      if (y >= (open ? 0 : 1) && y <= 4 && Math.abs(x) <= mw) continue; // mouth window
      if (y === 5 && Math.abs(x) <= 1) continue; // under the nose
      if (hash3(x, y, 3) < 0.12 && Math.abs(x) >= w - 1) continue; // ragged edge
      if (y >= 1) {
        const fz = frontZ(x, y);
        if (fz !== null) B(x, y, fz + 1);
        if (Math.abs(x) >= 8) for (let z = 0; z <= 7; z++) if (!inSkull(x, y, z)) B(x, y, z);
      } else for (let z = 2; z <= 9; z++) B(x, y, z);
    }
  }
  // moustache sweeping up into curls
  for (let x = -6; x <= 6; x++) if (Math.abs(x) >= 1) B(x, 5, (frontZ(x, 5) ?? 8) + 2);
  for (const s of [-1, 1]) B(s * 7, 6, 9), B(s * 8, 7, 8);
  // sideburns to the hair
  for (const s of [-1, 1]) for (let y = 5; y <= 13; y++) B(s * 10, y, 3), B(s * 10, y, 4);
  // curl bumps
  for (let n = 0; n < 40; n++) {
    const x = Math.round((hash3(n, 5, 1) - 0.5) * 18);
    const y = Math.round(hash3(n, 6, 1) * 8) - 6;
    if (Math.abs(x) > 10 + Math.min(0, y - 1) * 1.2) continue;
    B(x, y, 10);
  }
}

// ---------------------------------------------------------------- body parts (CS)
// torso: chest x -4..4 tapering to a -3..3 waist, belt at y 1..2, neck y 11
export function torsoGrid(paint, { skirt = 0, neck = PAL.skin } = {}) {
  const g = new VoxelGrid({ jitter: 2, seam: 0.26 });
  for (let y = -skirt; y <= 10; y++) {
    const hw = y >= 5 ? 4 : y >= 0 ? 3.6 : 4;
    const dz0 = y >= 5 ? -3 : -2,
      dz1 = y >= 5 && y <= 9 ? 3 : 2;
    for (let x = -4; x <= 4; x++)
      for (let z = dz0; z <= dz1; z++) {
        if (Math.abs(x) > hw) continue;
        if (y === 10 && (Math.abs(x) >= 4 || z === dz0 || z === dz1)) continue; // rounded shoulders
        if (Math.abs(x) === 4 && (z === dz0 || z === dz1)) continue;
        const c = paint(x, y, z);
        if (c !== null && c !== undefined) Array.isArray(c) ? g.set(x, y, z, c[0], c[1], c[2]) : g.set(x, y, z, c);
      }
  }
  g.box(-1, 11, -1, 1, 11, 1, neck, M.LIT, 1);
  return g;
}

export function limbGrid(len, paint, { r = 1, rz = r } = {}) {
  const g = new VoxelGrid({ jitter: 2, seam: 0.24 });
  for (let y = 0; y >= -len + 1; y--)
    for (let x = -r; x <= r; x++)
      for (let z = -rz; z <= rz; z++) {
        const c = paint(x, y, z);
        if (c !== null && c !== undefined) Array.isArray(c) ? g.set(x, y, z, c[0], c[1], c[2]) : g.set(x, y, z, c);
      }
  return g;
}

// standard booted leg: trousers, boot with a cuff and a toe cap
export function bootLeg({ trousers, boot = 0x1b1b22, cuff = null, flare = null }) {
  const g = limbGrid(LEG, (x, y) => (y <= -8 ? boot : trousers), { r: 1, rz: 1 });
  g.box(-1, -11, 2, 1, -10, 2, boot, M.LIT, 2); // toe cap
  g.box(-1, -11, -1, 1, -11, 2, 0x2a2018, M.LIT, 2); // sole
  if (cuff) g.box(-2, -8, -2, 2, -8, 2, cuff, M.LIT, 2);
  if (flare) g.box(-2, -7, -2, 2, -6, 2, flare, M.LIT, 2);
  return g;
}

// hands at HS: wrist at y 0, fingers down; side = +1 left hand, -1 right hand
export function handGrid(shape, skin = PAL.skin, side = 1) {
  const g = new VoxelGrid({ jitter: 1, seam: 0.2, seed: 9 });
  const S = (x, y, z, c = skin) => g.set(x, y, z, c, M.LIT, 1);
  const tx = -side * 3; // thumb on the inner side
  if (shape === "open") {
    g.box(-2, -1, -1, 2, -4, 1, skin, M.LIT, 1);
    for (const x of [-2, -1, 1, 2]) for (let y = -5; y >= -7; y--) S(x, y, 0);
    for (let y = -2; y >= -4; y--) S(tx, y, 0), S(tx + Math.sign(tx), y - 1, 0);
    return g;
  }
  // palm + curled fingers
  g.box(-2, -1, -2, 2, -4, 2, skin, M.LIT, 1);
  for (let x = -2; x <= 2; x++) S(x, -5, 1), S(x, -5, 0);
  for (const x of [-1, 1]) for (let y = -2; y >= -4; y--) S(x, y, 3, PAL.skinShade); // knuckle grooves
  for (const x of [-2, 0, 2]) for (let y = -2; y >= -4; y--) S(x, y, 3);
  // thumb: a separate block across the front
  for (let y = -2; y >= -4; y--) S(tx, y, 1), S(tx, y, 2);
  S(tx - Math.sign(tx), -4, 3);
  if (shape === "point") {
    // index finger extended beside the thumb, rest curled
    const ix = -side * 1.5 > 0 ? 1 : -1;
    for (let y = -5; y >= -10; y--) S(ix, y, 1), S(ix, y, 2);
    S(ix, -10, 2, PAL.skinShade); // nail tip
    for (let x = -2; x <= 2; x++) if (x !== ix) g.del(x, -5, 1);
  }
  if (shape === "thumb") for (let y = -1; y <= 3; y++) S(tx, y, 1);
  if (shape === "grip") for (let y = -2; y >= -3; y--) g.del(0, y, 0);
  return g;
}

// ---------------------------------------------------------------- rig
export function makeChibi(spec) {
  const root = new THREE.Group();
  root.name = spec.name;
  const hips = new THREE.Group();
  hips.position.y = HIP * CS;
  root.add(hips);
  const torso = new THREE.Group();
  hips.add(torso);
  torso.add(toMesh(spec.torso(), { size: CS }));
  const head = new THREE.Group();
  head.position.set(0, NECK_TOP * CS, 0);
  torso.add(head);

  const legs = {};
  for (const side of ["l", "r"]) {
    const s = side === "l" ? 1 : -1;
    const leg = new THREE.Group();
    leg.position.set(s * 2 * CS, 0, 0);
    leg.add(toMesh(spec.leg(side), { size: CS }));
    hips.add(leg);
    legs[side] = leg;
  }
  const arms = {};
  for (const side of ["l", "r"]) {
    const s = side === "l" ? 1 : -1;
    const sh = new THREE.Group();
    sh.position.set(s * SHOULDER[0] * CS, SHOULDER[1] * CS, 0);
    sh.add(toMesh(spec.upperArm(side), { size: CS }));
    torso.add(sh);
    const el = new THREE.Group();
    el.position.y = -UPPER * CS;
    sh.add(el);
    el.add(toMesh(spec.forearm(side), { size: CS }));
    const wrist = new THREE.Group();
    wrist.position.y = -WRIST * CS;
    el.add(wrist);
    const hand = new THREE.Group(); // grip point: props attach here
    hand.position.y = -GRIP * HS;
    wrist.add(hand);
    arms[side] = { sh, el, wrist, hand, hands: {} };
  }

  const heads = {};
  const setExpression = (expr) => {
    if (!heads[expr]) {
      heads[expr] = toMesh(spec.head(expr), { size: HS, origin: [0, HS / 2, 0] });
      head.add(heads[expr]);
    }
    for (const k in heads) heads[k].visible = k === expr;
    rig.expression = expr;
  };
  const setHand = (side, shape) => {
    const a = arms[side];
    if (!a.hands[shape]) {
      a.hands[shape] = toMesh((spec.hand || handGrid)(shape, spec.handColor || PAL.skin, side === "l" ? 1 : -1), { size: HS });
      a.wrist.add(a.hands[shape]);
    }
    for (const k in a.hands) a.hands[k].visible = k === shape;
  };

  const props = {};
  for (const [name, p] of Object.entries(spec.props || {})) {
    const obj = p.build();
    obj.visible = false;
    props[name] = { obj, ...p };
  }

  const R = (o, a) => o.rotation.set((a?.[0] || 0) * D2R, (a?.[1] || 0) * D2R, (a?.[2] || 0) * D2R);
  const FORE = WRIST + (GRIP * HS) / CS;
  const DOWN = new THREE.Vector3(0, -1, 0);
  // two-bone IK in torso CS space: put the grip point at `to`, elbow toward the pole
  const solveArm = (side, to, pole) => {
    const a = arms[side];
    const s = side === "l" ? 1 : -1;
    const S = new THREE.Vector3(s * SHOULDER[0], SHOULDER[1], 0);
    const D = new THREE.Vector3(...to).sub(S);
    const d = Math.min(Math.max(D.length(), 1.5), UPPER + FORE - 0.05);
    const u = D.normalize();
    const pv = new THREE.Vector3(...(pole || [s * 0.8, -0.7, -0.6])).normalize();
    const v = pv.sub(u.clone().multiplyScalar(pv.dot(u))).normalize();
    const cosA = (UPPER * UPPER + d * d - FORE * FORE) / (2 * UPPER * d);
    const sinA = Math.sqrt(Math.max(0, 1 - cosA * cosA));
    const E = S.clone().addScaledVector(u, UPPER * cosA).addScaledVector(v, UPPER * sinA);
    const T = S.clone().addScaledVector(u, d);
    const q1 = new THREE.Quaternion().setFromUnitVectors(DOWN, E.clone().sub(S).normalize());
    const dFl = T.clone().sub(E).normalize().applyQuaternion(q1.clone().invert());
    a.sh.quaternion.copy(q1);
    a.el.quaternion.setFromUnitVectors(DOWN, dFl);
  };
  const qTmp = new THREE.Quaternion();
  const setPose = (name) => {
    const P = spec.poses[name] || spec.poses[Object.keys(spec.poses)[0]];
    R(torso, P.torso);
    R(head, P.head);
    R(arms.r.sh, P.rs || [0, 0, -8]);
    R(arms.r.el, P.re || [-10, 0, 0]);
    R(arms.l.sh, P.ls || [0, 0, 8]);
    R(arms.l.el, P.le || [-10, 0, 0]);
    if (P.ik?.r) solveArm("r", P.ik.r, P.ik.rp);
    if (P.ik?.l) solveArm("l", P.ik.l, P.ik.lp);
    R(legs.r, P.rl);
    R(legs.l, P.ll);
    root.position.y = (P.y || 0) * CS;
    setHand("r", P.hr || "fist");
    setHand("l", P.hl || "fist");
    root.updateMatrixWorld(true);
    const qRoot = root.getWorldQuaternion(new THREE.Quaternion());
    for (const [pn, p] of Object.entries(props)) {
      const use = (P.props || {})[pn];
      p.obj.visible = !!use;
      if (!use) continue;
      const where = use.attach || p.attach || use.side || p.side || "r";
      const parent = where === "torso" ? torso : where === "root" ? root : arms[where].hand;
      parent.add(p.obj);
      p.obj.position.set(...(use.pos || p.pos || [0, 0, 0]).map((v) => v * CS));
      if (use.aim) {
        const axis = new THREE.Vector3(...(use.axis || p.axis || [0, 0, 1])).normalize();
        const A = new THREE.Vector3(...use.aim).normalize().applyQuaternion(qRoot);
        const qW = new THREE.Quaternion().setFromUnitVectors(axis, A);
        if (use.roll) qW.multiply(qTmp.setFromAxisAngle(axis, use.roll * D2R));
        const qParent = parent.getWorldQuaternion(new THREE.Quaternion());
        p.obj.quaternion.copy(qParent.invert().multiply(qW));
      } else R(p.obj, use.rot || p.rot);
    }
    if (P.expr && !rig.lockExpr) setExpression(P.expr);
    rig.pose = name;
  };

  const rig = { group: root, root, hips, torso, head, arms, legs, props, poses: Object.keys(spec.poses), expressions: spec.expressions, setPose, setExpression, pose: null, expression: null, lockExpr: false };
  root.userData.rig = rig;
  setExpression(spec.defaultExpr || spec.expressions[0]);
  setPose(spec.defaultPose || rig.poses[0]);
  return rig;
}

// standard human head: skull + hair + face + optional hat/beard/glasses (HS grid)
export function humanHead(expr, { hair = {}, hat, capY, beardOn = false, glassesOn = false, skin = PAL.skin, blush = true, lashes = false } = {}) {
  const g = new VoxelGrid({ jitter: 1, seam: 0.18, seed: 7 });
  skull(g, skin);
  paintHair(g, { capY: hat ? capY ?? 15 : 99, ...hair });
  paintFace(g, expr, { blush: blush && !beardOn, sclera: glassesOn, lashes });
  if (beardOn) beard(g, expr);
  if (glassesOn) glasses(g);
  if (hat) hat(g);
  return g;
}
