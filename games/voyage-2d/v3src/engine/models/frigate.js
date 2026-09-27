// Frigate. Voxel units (V = 0.2 world): x along the ship (bow +x), y up, z across.
// Hull: stepped-voxel curvature from a plan x section function, plank strakes
// with butt joints, wales, iron plates with rivets on every frame, gold trim,
// gun ports with cannons, anchor + chain, glowing stern gallery, balustraded
// rails, raised quarterdeck with the wheel, forecastle, three masts with iron
// bands, yards, billowing cream sails, the navy flag-sail with the white wheel
// emblem, crow's nest, rope rigging with ratlines, lanterns.
// The hull's waterline (voxel y = -12) sits at group y = 0.
import * as THREE from "three";
import { mergeGeometries } from "three/addons/utils/BufferGeometryUtils.js";
import { VoxelGrid, M, hash3 } from "../voxel.js";
import { toMesh, PAL, materials } from "../materials.js";
import { buildCannon, buildAnchor, buildChain, buildWheel, buildLantern, buildBarrel, buildCrate } from "./props.js";

export const V = 0.2;
const WL = 12; // waterline offset in voxels
const XQ = -34; // quarterdeck break
const XF = 38; // forecastle break
const BEAM = 19;

const deckY = (x) => (x < XQ ? 11 : x > XF ? 7 : 0);
const railTop = (x) => (x < XQ ? 16 : x > XF ? 12 : 5);
const bottom = (x) => -26 + Math.max(0, x - 40) * 0.45 + Math.max(0, -50 - x) * 0.6;
const xMin = (y) => -68 + Math.max(0, -y - 6) * 0.45;
const xMax = (y) => 64 + (y + 12) * 0.28;
function halfW(x, y) {
  const x0 = xMin(y),
    x1 = xMax(y);
  if (x < x0 || x > x1) return -1;
  let p = 1;
  if (x > 16) {
    const t = (x - 16) / (x1 - 16);
    p = Math.sqrt(Math.max(0, 1 - t * t));
  } else if (x < -52) p = 1 - ((-52 - x) / 20) * 0.22;
  const b = bottom(x);
  let q;
  if (y < -4) {
    const k = (-4 - y) / (-4 - b);
    q = Math.pow(Math.max(0, 1 - k * k), 0.55);
  } else q = 1 - (y + 4) * 0.006;
  return BEAM * p * q;
}
const inBody = (x, y, z) => y >= bottom(x) && y <= deckY(x) && Math.abs(z) <= halfW(x, y);
const inEnvelope = (x, y, z) => y >= bottom(x) && y <= railTop(x) && Math.abs(z) <= halfW(x, Math.min(y, 14));

const WOOD = [0x8c5430, 0x7c482a, 0x98603a, 0x84502c];
const FRAMES = [];
for (let x = -60; x <= 60; x += 12) FRAMES.push(x);
const PORTS = [-50, -26, -14, -2, 10, 22, 34];
const PORT_Y0 = -6,
  PORT_Y1 = -3;

function hullGrid() {
  const g = new VoxelGrid({ jitter: 3, seam: 0.32, seed: 51 });
  for (let x = -70; x <= 72; x++)
    for (let y = -27; y <= 17; y++) {
      const hw = halfW(x, Math.min(y, 14));
      if (hw < 0) continue;
      for (let z = Math.floor(-hw); z <= Math.ceil(hw); z++) {
        if (!inEnvelope(x, y, z)) continue;
        const dy = deckY(x);
        const az = Math.abs(z);
        const outerDist = Math.min(hw - az, x - xMin(Math.min(y, 14)), xMax(Math.min(y, 14)) - x);
        let c = null;
        let mat = M.LIT;
        if (y <= dy) {
          // body: shell + deck surface only
          const shell = !inBody(x + 1, y, z) || !inBody(x - 1, y, z) || !inBody(x, y, z + 1) || !inBody(x, y, z - 1) || !inBody(x, y - 1, z);
          if (!shell && y !== dy) continue;
          if (y === dy && outerDist > 1.2) {
            // deck planks along x, staggered butt joints, treenails
            const plank = Math.floor((z + 40) / 2);
            c = plank % 2 ? PAL.deck : PAL.deckB;
            if ((x + plank * 5 + 200) % 17 === 0) c = 0x8a5a32;
            if ((x * 3 + z * 7 + 400) % 29 === 0) c = 0x6a4424;
          } else {
            // hull sides: strakes 2 voxels tall
            const strake = Math.floor((y + 40) / 2);
            c = WOOD[(strake + Math.floor(hash3(Math.floor((x + strake * 7) / 7), strake, 1) * 4)) % 4];
            if ((x + strake * 5 + 300) % 7 === 0) c = PAL.woodDark; // butt joints
            if (y < -WL) c = y < -WL - 3 ? 0x4a2c18 : 0x5e3a22; // below the waterline
            if (y === -8 || y === -9 || y === -1) c = PAL.woodDeep; // wales
            if (y === 0 && x > XQ && x < XF) c = PAL.gold; // gold moulding below the rail
            if (x < XQ && y === 9) c = PAL.gold;
            if (x > XF && y === 5) c = PAL.gold;
          }
        } else {
          // bulwark above the deck: only the outer two layers
          if (outerDist > 1.8) continue;
          const r = y - dy;
          const top = y === railTop(x);
          const nearEnd = x - xMin(14) < 2.2;
          const post = nearEnd ? (z + 300) % 3 === 0 : (x + 300) % 3 === 0;
          if (top) c = outerDist < 0.9 ? PAL.woodDeep : 0x6a3e20; // cap rail
          else if (r <= 2) {
            const strake = Math.floor((y + 40) / 2);
            c = WOOD[(strake + (x & 3)) % 4];
            if (r === 2 && outerDist < 0.9) c = PAL.gold; // gold trim line
          } else {
            if (!post) continue; // balusters
            c = r % 2 ? 0x7a4626 : 0x6e3f22;
          }
        }
        g.set(x, y, z, c, c === PAL.gold ? M.METAL : mat, c === PAL.gold ? 1 : 3);
      }
    }

  // frames: vertical ribs with iron plates and rivets
  for (const fx of FRAMES) {
    for (let y = -WL; y <= railTop(fx); y++) {
      const hw = halfW(fx, Math.min(y, 14));
      if (hw < 0) continue;
      for (const s of [-1, 1]) {
        const z = s * Math.round(hw + 0.5);
        g.set(fx, y, z, PAL.woodDeep, M.LIT, 2);
        g.set(fx + 1, y, z, 0x5a331b, M.LIT, 2);
      }
    }
    for (const py of [-9, -1, railTop(fx) - 1]) {
      const hw = halfW(fx, Math.min(py, 14));
      if (hw < 0) continue;
      for (const s of [-1, 1]) {
        const z = s * (Math.round(hw + 0.5) + 1);
        for (let dx = -1; dx <= 2; dx++) for (let dy = -1; dy <= 1; dy++) g.set(fx + dx, py + dy, z, PAL.iron, M.METAL, 2);
        for (const [dx, dy] of [[-1, -1], [2, -1], [-1, 1], [2, 1]]) g.set(fx + dx, py + dy, z + s, PAL.rivet, M.METAL, 1);
      }
    }
  }
  // extra L-shaped corner brackets along the cap rail between frames
  for (let x = -62; x <= 58; x += 6) {
    if (FRAMES.includes(x)) continue;
    const y = railTop(x);
    const hw = halfW(x, 14);
    for (const s of [-1, 1]) {
      const z = s * Math.round(hw + 0.5);
      g.set(x, y, z, PAL.iron, M.METAL, 2);
      g.set(x, y - 1, z, PAL.iron, M.METAL, 2);
      g.set(x + 1, y, z, PAL.iron, M.METAL, 2);
    }
  }

  // gun ports: dark openings framed in dark wood with a red-painted lid above
  for (const px of PORTS) {
    for (const s of [-1, 1]) {
      for (let x = px - 2; x <= px + 2; x++)
        for (let y = PORT_Y0 - 1; y <= PORT_Y1 + 1; y++) {
          const hw = halfW(x, y);
          const z = s * Math.round(hw);
          const frame = x === px - 2 || x === px + 2 || y === PORT_Y0 - 1 || y === PORT_Y1 + 1;
          if (frame) g.set(x, y, z + s, 0x4a2a14, M.LIT, 2);
          else {
            g.del(x, y, z);
            g.del(x, y, z - s);
            g.set(x, y, z - 2 * s, 0x100a08, M.LIT, 0);
          }
        }
      // lid propped open above the port
      for (let x = px - 2; x <= px + 2; x++) {
        const hw = halfW(x, PORT_Y1 + 3);
        g.set(x, PORT_Y1 + 2, s * (Math.round(hw) + 2), 0xa0302a, M.LIT, 2);
        g.set(x, PORT_Y1 + 3, s * (Math.round(hw) + 2), 0x8a2822, M.LIT, 2);
      }
    }
  }

  // stern: gallery windows (two rows) glowing on the transom, gold frames and carvings
  for (let y = -6; y <= 16; y++) {
    const x0 = Math.ceil(xMin(Math.min(y, 14)));
    const hw = halfW(x0, Math.min(y, 14));
    for (let z = -Math.floor(hw); z <= Math.floor(hw); z++) {
      const rowA = y >= 2 && y <= 6;
      const rowB = y >= -4 && y <= -1;
      const col = ((z + 60) % 5) - 1; // window 3 wide, mullion every 5
      const inWin = (rowA || rowB) && col >= 0 && col <= 2 && Math.abs(z) < hw - 3;
      if (inWin) {
        const mull = (rowA && y === 4) || col === 1 && rowA && y === 4;
        g.set(x0, y, z, mull ? PAL.goldDark : (y + z) % 3 === 0 ? 0xffe6a0 : 0xffb850, mull ? M.METAL : M.GLOW, 0);
        g.set(x0 + 1, y, z, 0xffc870, M.GLOW, 0);
      } else if ((rowA || rowB) && Math.abs(z) < hw - 2) g.set(x0 - 1, y, z, PAL.gold, M.METAL, 1);
      if (y === 8 || y === 0 || y === -6 || y === 13) g.set(x0 - 1, y, z, PAL.gold, M.METAL, 1);
      if (y === 10 && (z + 60) % 4 === 0) g.set(x0 - 1, y, z, PAL.goldDark, M.METAL, 1);
    }
  }
  // side quarter galleries with windows
  for (const s of [-1, 1])
    for (let x = -66; x <= -56; x++)
      for (let y = -2; y <= 8; y++) {
        const hw = halfW(x, y);
        const z = s * (Math.round(hw) + 1);
        const win = y >= 1 && y <= 5 && (x + 70) % 4 !== 0 && x > -65 && x < -57;
        g.set(x, y, z, win ? 0xffc060 : y === -2 || y === 8 ? PAL.gold : 0x6a3e20, win ? M.GLOW : y === -2 || y === 8 ? M.METAL : M.LIT, 1);
      }

  // quarterdeck front bulkhead: doors + glowing windows; railing across
  const bx = XQ - 1;
  for (let z = -16; z <= 16; z++) {
    for (let y = 1; y <= 10; y++) {
      const door = Math.abs(Math.abs(z) - 8) <= 1 && y <= 7;
      const win = Math.abs(z) <= 3 && y >= 4 && y <= 7 && z % 3 !== 0;
      if (door) g.set(bx + 1, y, z, y === 7 ? PAL.gold : 0x5a3418, y === 7 ? M.METAL : M.LIT);
      else if (win) g.set(bx + 1, y, z, 0xffc060, M.GLOW, 0);
      else if (y === 10) g.set(bx + 1, y, z, PAL.gold, M.METAL, 1);
    }
    const hw = halfW(bx, 14);
    if (Math.abs(z) > hw - 1) continue;
    for (let y = 12; y <= 16; y++) {
      if (y === 16) g.set(bx, y, z, PAL.woodDeep);
      else if (y === 12) g.set(bx, y, z, 0x7a4626);
      else if ((z + 300) % 3 === 0) g.set(bx, y, z, 0x7a4626);
    }
  }
  // stairs up to the quarterdeck on both sides
  for (const s of [-1, 1])
    for (let i = 0; i < 11; i++) g.box(bx + 1 + (10 - i), i, s * 12, bx + 1 + (10 - i), i, s * 14, 0x9a6a3c, M.LIT, 2);
  // forecastle aft railing
  const fx = XF + 1;
  for (let z = -18; z <= 18; z++) {
    if (Math.abs(z) > halfW(fx, 12) - 1) continue;
    for (let y = 1; y <= 6; y++) if (y === 6 || Math.abs(z) > 4) g.set(fx, y, z, y === 6 ? PAL.gold : 0x7a4626, y === 6 ? M.METAL : M.LIT);
    for (let y = 8; y <= 12; y++) if (y === 12 || y === 8 || (z + 300) % 3 === 0) g.set(fx, y, z, y === 12 ? PAL.woodDeep : 0x7a4626);
  }
  // hatch grating in the waist
  for (let x = -12; x <= 0; x++)
    for (let z = -5; z <= 5; z++) {
      const edge = x === -12 || x === 0 || Math.abs(z) === 5;
      g.set(x, 1, z, edge ? 0x6a4020 : (x + z) % 2 ? 0x3a2412 : 0x9a6a3c);
    }
  // bow: stem post rising in front, gold figurehead scroll
  for (let y = -10; y <= 16; y++) {
    const x = Math.round(xMax(Math.min(y, 14))) + 1;
    g.box(x, y, -1, x + 1, y, 1, y > 10 ? PAL.gold : PAL.woodDeep, y > 10 ? M.METAL : M.LIT, 2);
  }
  // hawse holes for the anchor chain
  for (const s of [-1, 1]) {
    const x = 56;
    const hw = halfW(x, 4);
    g.box(x, 3, s * Math.round(hw + 1), x + 2, 5, s * Math.round(hw + 1), PAL.iron, M.METAL, 2);
    g.set(x + 1, 4, s * Math.round(hw + 2), 0x0a0a0c, M.LIT, 0);
  }
  return g;
}

// ------------------------------------------------------------------ masts, yards, sails
const MASTS = [
  { x: 44, top: 118, r: 2.6, yards: [[52, 26], [86, 20], [110, 13]], top1: 56 },
  { x: 2, top: 140, r: 3.0, yards: [[58, 30], [94, 23], [128, 15]], nest: 97 },
  { x: -48, top: 104, r: 2.4, yards: [[58, 20], [86, 15]], top1: 62 },
];

function mastGrid() {
  const g = new VoxelGrid({ jitter: 3, seam: 0.3, seed: 61 });
  for (const m of MASTS) {
    const y0 = deckY(m.x);
    for (let y = y0; y <= m.top; y++) {
      const r = m.r * (1 - ((y - y0) / (m.top - y0)) * 0.45);
      const band = (y - y0) % 12 === 0 || (y - y0) % 12 === 1;
      g.cyl("y", y, y, m.x, 0, r + (band ? 0.7 : 0), band ? PAL.iron : (y >> 1) % 2 ? 0x8a5a34 : 0x7e5230, band ? M.METAL : M.LIT, band ? 1 : 3);
    }
    // cap + truck at the mast head
    g.box(m.x - 2, m.top + 1, -2, m.x + 2, m.top + 2, 2, 0x5a3418);
    g.ellipsoid(m.x, m.top + 4, 0, 1.5, 1.5, 1.5, PAL.gold, M.METAL, 1);
    // yards: tapered spars across z with iron slings
    for (const [yy, half] of m.yards) {
      for (let z = -half; z <= half; z++) {
        const rr = 1.5 - (Math.abs(z) / half) * 0.7;
        g.cyl("z", z, z, m.x + 3, yy, rr, Math.abs(z) < 2 ? PAL.iron : 0x6e4428, Math.abs(z) < 2 ? M.METAL : M.LIT, 2);
      }
      g.box(m.x + 2, yy - 1, -half, m.x + 2, yy - 1, half, 0x5a3418); // footrope line
    }
    // fighting top platform
    if (m.top1) {
      for (let x = -6; x <= 6; x++) for (let z = -8; z <= 8; z++) if (Math.abs(x) + Math.abs(z) * 0.6 <= 9) g.set(m.x + x, m.top1, z, (x + z) % 2 ? 0x8a5a34 : 0x7a4a2a);
      for (let z = -8; z <= 8; z += 2) g.box(m.x + 6, m.top1 + 1, z, m.x + 6, m.top1 + 3, z, 0x6a3e20);
    }
    // crow's nest: a banded barrel basket around the mast
    if (m.nest) {
      for (let y = m.nest; y <= m.nest + 7; y++)
        for (let x = -7; x <= 7; x++)
          for (let z = -7; z <= 7; z++) {
            const d = Math.hypot(x, z);
            const r = 6.5 + (y === m.nest || y === m.nest + 7 ? 0 : 0.6);
            if (d > r || (d < r - 1.3 && y !== m.nest)) continue;
            const hoop = y === m.nest + 1 || y === m.nest + 6;
            const stave = Math.floor(((Math.atan2(z, x) + Math.PI) / (Math.PI * 2)) * 20) % 2;
            g.set(m.x + x, y, z, hoop ? PAL.iron : stave ? 0x8f5a30 : 0x7a4a26, hoop ? M.METAL : M.LIT);
          }
    }
  }
  // bowsprit + jib boom
  g.line(62, 10, 0, 104, 30, 0, 1.8, 0x7e5230, M.LIT, 3);
  for (let i = 0; i < 3; i++) {
    const k = 0.25 + i * 0.25;
    g.cyl("x", 62 + 42 * k, 62 + 42 * k + 1, 10 + 20 * k, 0, 2.6, PAL.iron, M.METAL, 1);
  }
  return g;
}

function wheelEmblem(u, v, W, H) {
  // u,v in voxels relative to the emblem centre
  const r = Math.hypot(u, v);
  const R = Math.min(W, H) * 0.26;
  if (r >= R - 1.6 && r <= R + 0.4) return true; // rim
  if (r <= 3.3 && r >= 1.6) return true; // hub ring
  const a = Math.atan2(v, u);
  const sector = Math.round(a / (Math.PI / 4)) * (Math.PI / 4);
  const off = Math.abs(Math.sin(a - sector) * r);
  if (r > 3 && r < R + 4.5 && off < 1.0) {
    if (r > R + 0.5 && r < R + 1.5) return off < 0.6; // neck
    return true;
  }
  if (r >= R + 3.5 && r <= R + 5.8 && off < 1.6) return true; // handle knobs
  return false;
}

function sailGrid() {
  const g = new VoxelGrid({ jitter: 1, seam: 0.12, seed: 71 });
  const cream = [0xf6ead0, 0xefe0c2, 0xf8eed8];
  const addSail = (mx, yTop, yBot, halfTop, belly, { navy = false } = {}) => {
    const H = yTop - yBot;
    const halfBot = halfTop * 1.08;
    const X = (z, y) => {
      const v = (yTop - y) / H;
      const half = halfTop + (halfBot - halfTop) * v;
      const u = (z + half) / (2 * half);
      if (u < 0 || u > 1) return null;
      const bz = Math.pow(Math.sin(Math.PI * u), 0.75);
      const bv = 0.25 + 0.75 * Math.sin(Math.PI * Math.min(1, v * 0.95 + 0.05));
      return mx + 4 + belly * bz * bv;
    };
    for (let y = yBot; y <= yTop - 1; y++) {
      const v = (yTop - y) / H;
      const half = halfTop + (halfBot - halfTop) * v;
      for (let z = Math.ceil(-half); z <= Math.floor(half); z++) {
        const x = X(z, y);
        if (x === null) continue;
        // watertight: fill between this voxel and its lower/left neighbours
        const nx = [X(z - 1, y), X(z, y + 1), X(z + 1, y), X(z, y - 1)].filter((a) => a !== null);
        const xr = Math.round(x);
        let lo = xr,
          hi = xr;
        for (const n of nx) {
          const r = Math.round(n);
          if (r < lo) lo = Math.max(r + 1, xr - 3);
          if (r > hi) hi = Math.min(r - 1, xr + 3);
        }
        const u = (z + half) / (2 * half);
        const edge = y === yBot || y === yTop - 1 || Math.abs(z) >= Math.floor(half);
        let c;
        if (navy) {
          const ex = z,
            ey = y - (yBot + H * 0.5);
          c = wheelEmblem(ex, ey, 2 * half, H) ? 0xf2f2f6 : (Math.floor((z + 60) / 6) % 2 ? 0x22329a : 0x1f2d8e);
          if (edge) c = 0x14206a;
          if ((z + 60) % 6 === 0 && !wheelEmblem(ex, ey, 2 * half, H)) c = 0x1a2780;
        } else {
          c = cream[Math.floor(hash3(z, y, 3) * 3)];
          if ((z + 60) % 6 === 0) c = PAL.creamShade; // cloth panel seams
          if (Math.abs(y - (yTop - Math.round(H * 0.18))) < 0.5) c = 0xd8c49c; // reef band
          if (edge) c = 0xc9ad7e; // bolt rope
          // shade toward the leeches
          if (u < 0.08 || u > 0.92) c = 0xe2d2b0;
        }
        for (let xx = lo; xx <= hi; xx++) g.set(xx, y, z, c, M.LIT, 1);
        // reef points dangling in front of the reef band
        if (!navy && Math.abs(y - (yTop - Math.round(H * 0.18))) < 0.5 && (z + 60) % 4 === 0) g.set(hi + 1, y - 1, z, 0xb89868, M.LIT, 1);
      }
    }
    // corner patches (clews) in iron rings
    for (const s of [-1, 1]) g.set(Math.round(X(s * Math.floor(halfBot - 1), yBot + 1) ?? mx + 4), yBot, s * Math.floor(halfBot), PAL.iron, M.METAL, 1);
  };
  for (const [mi, m] of MASTS.entries()) {
    const ys = m.yards;
    for (let i = 0; i < ys.length; i++) {
      const [yy, half] = ys[i];
      const below = i === 0 ? deckY(m.x) + (mi === 1 ? 22 : 16) : ys[i - 1][0] + 4;
      const navy = mi === 1 && i === 0;
      addSail(m.x, yy - 1, below, half - 1, navy ? 9 : 8 - i, { navy });
    }
  }
  // jibs: triangles from the fore mast to the bowsprit
  const jib = (x0, y0, x1, y1, yb) => {
    for (let x = x0; x <= x1; x++) {
      const k = (x - x0) / (x1 - x0);
      const top = Math.round(y0 + (y1 - y0) * k);
      for (let y = yb + Math.round(k * (y1 - yb) * 0.9); y <= top; y++) {
        const bz = Math.round(Math.sin(Math.PI * k) * 3 * Math.sin(Math.PI * Math.min(1, (top - y) / 20 + 0.1)));
        const edge = y === top || x === x0;
        g.set(x, y, bz, edge ? 0xc9ad7e : (x + 60) % 6 === 0 ? PAL.creamShade : 0xf4e8cc, M.LIT, 1);
      }
    }
  };
  jib(50, 104, 96, 30, 22);
  jib(58, 82, 84, 25, 20);
  return g;
}

// ------------------------------------------------------------------ rigging (merged rope geometry)
function ropeGeometry() {
  const geos = [];
  const up = new THREE.Vector3(0, 1, 0);
  const seg = (a, b, r) => {
    const d = new THREE.Vector3().subVectors(b, a);
    const len = d.length();
    if (len < 1e-3) return;
    const geo = new THREE.BoxGeometry(r, len, r);
    const q = new THREE.Quaternion().setFromUnitVectors(up, d.clone().normalize());
    const m = new THREE.Matrix4().compose(a.clone().add(b).multiplyScalar(0.5), q, new THREE.Vector3(1, 1, 1));
    geo.applyMatrix4(m);
    geos.push(geo);
  };
  const P = (x, y, z) => new THREE.Vector3(x * V, (y + WL) * V, z * V);
  for (const m of MASTS) {
    const head = m.yards[0][0] + 4;
    const topHead = m.yards[m.yards.length - 1][0] + 6;
    for (const s of [-1, 1]) {
      const shrouds = [];
      for (let i = 0; i < 5; i++) {
        const cx = m.x - 8 + i * 4;
        const cz = s * (Math.round(halfW(cx, 4)) + 2);
        const a = P(cx, railTop(cx), cz);
        const b = P(m.x, head, s * m.r);
        seg(a, b, 0.07);
        shrouds.push([a, b]);
        // topmast shrouds from the top to the masthead
        seg(P(m.x - 4 + i * 2, head, s * 8), P(m.x, topHead, s * 1.5), 0.05);
        // dead-eyes at the channel
        const de = new THREE.BoxGeometry(0.22, 0.26, 0.12);
        de.translate(a.x, a.y + 0.1, a.z);
        geos.push(de);
      }
      // ratlines across the shrouds
      for (let k = 0.06; k < 0.95; k += 0.055)
        for (let i = 0; i < 4; i++) {
          const a = shrouds[i][0].clone().lerp(shrouds[i][1], k);
          const b = shrouds[i + 1][0].clone().lerp(shrouds[i + 1][1], k);
          seg(a, b, 0.045);
        }
      // braces from yard arms aft
      for (const [yy, half] of m.yards) seg(P(m.x + 3, yy, s * half), P(m.x - 26, yy - 20, s * 10), 0.035);
    }
    // stays forward
  }
  seg(P(44, 118, 0), P(104, 30, 0), 0.06);
  seg(P(2, 140, 0), P(44, 90, 0), 0.06);
  seg(P(-48, 104, 0), P(2, 70, 0), 0.06);
  seg(P(44, 60, 0), P(64, 12, 0), 0.06);
  // pennant halyard
  return mergeGeometries(geos);
}

// ------------------------------------------------------------------ assembly
export function buildFrigate({ lanternLights = true, detail = true } = {}) {
  const root = new THREE.Group();
  root.name = "frigate";
  const origin = [0, WL * V, 0];
  const hull = toMesh(hullGrid(), { size: V, origin, name: "hull" });
  root.add(hull);
  root.add(toMesh(mastGrid(), { size: V, origin, name: "masts" }));
  const sails = toMesh(sailGrid(), { size: V, origin, name: "sails" });
  sails.traverse((o) => o.isMesh && (o.castShadow = true));
  root.add(sails);
  const ropes = new THREE.Mesh(ropeGeometry(), materials.rope);
  ropes.castShadow = true;
  root.add(ropes);

  const W = (x, y, z) => new THREE.Vector3(x * V, (y + WL) * V + V / 2, z * V);
  // cannons in every port, pointing outboard
  if (detail) {
    for (const px of PORTS)
      for (const s of [-1, 1]) {
        const c = buildCannon({ scale: 0.09, len: 12, carriage: false });
        const hw = halfW(px, -4.5);
        c.position.copy(W(px, -4.5, s * (hw - 3)));
        c.position.y -= V / 2;
        c.rotation.y = s > 0 ? 0 : Math.PI;
        root.add(c);
      }
    // two big chase guns on the forecastle, over the bow rail
    for (const s of [-1, 1]) {
      const c = buildCannon({ scale: 0.13, len: 18 });
      c.position.copy(W(54, 7, s * 7));
      c.position.y += 0.55;
      c.rotation.y = Math.PI / 2 - s * 0.12;
      root.add(c);
    }
    // anchor hanging on the port bow, chain from the hawse hole
    for (const s of [1, -1]) {
      const a = buildAnchor({ scale: 0.1 });
      const hw = halfW(50, -2);
      a.position.copy(W(50, -3, s * (hw + 2.5)));
      a.rotation.y = Math.PI / 2;
      a.rotation.z = 0.05;
      root.add(a);
      const hw2 = halfW(57, 4);
      root.add(buildChain(W(57, 4, s * (hw2 + 2)), W(50, 1.8, s * (hw + 2.5)), { scale: 0.07, sag: 0.9 }));
    }
    // ship's wheel on the quarterdeck, with a binnacle pedestal
    const wheel = buildWheel({ scale: 0.05 });
    wheel.position.copy(W(-44, 11, 0));
    wheel.position.y += 0.95;
    wheel.rotation.y = Math.PI / 2;
    root.add(wheel);
    const ped = new VoxelGrid({ jitter: 2 });
    ped.box(-1, 0, -1, 1, 3, 1, 0x6b3e1e);
    ped.box(-2, 0, -2, 2, 0, 2, 0x5a3418);
    const pm = toMesh(ped, { size: V });
    pm.position.copy(W(-45, 12, 0));
    root.add(pm);
    // lanterns: rail posts along both sides, big stern lanterns
    const lanterns = [];
    for (const lx of [-58, -40, -20, 0, 20, 36, 52])
      for (const s of [-1, 1]) {
        const l = buildLantern({ scale: 0.045, light: false });
        const hw = halfW(lx, 14);
        l.position.copy(W(lx, railTop(lx) + 0.5, s * Math.round(hw - 0.5)));
        root.add(l);
        lanterns.push(l);
      }
    for (const z of [-10, 0, 10]) {
      const l = buildLantern({ scale: 0.08, light: false });
      l.position.copy(W(Math.ceil(xMin(14)) + 1, 16.5, z));
      root.add(l);
    }
    if (lanternLights) {
      for (const [x, y, z] of [[-66, 20, 0], [0, 8, 14], [0, 8, -14], [52, 14, 0]]) {
        const pl = new THREE.PointLight(0xffa550, 3, 9, 2);
        pl.position.copy(W(x, y, z));
        root.add(pl);
      }
    }
    // deck clutter: barrels + crates by the masts
    for (const [x, z, k] of [[-6, 12, "b"], [-9, 13, "b"], [14, -12, "c"], [17, -12, "c"], [-58, 9, "b"], [30, 12, "c"]]) {
      const o = k === "b" ? buildBarrel({ scale: 0.07 }) : buildCrate({ scale: 0.08, seed: x });
      o.position.copy(W(x, deckY(x), z));
      root.add(o);
    }
  }
  // masthead pennant
  const pen = new VoxelGrid({ jitter: 1, seam: 0.1 });
  for (let i = 0; i < 26; i++) {
    const w = Math.max(1, Math.round(3 - i / 10));
    for (let j = -w; j <= w; j++) pen.set(-i, Math.round(Math.sin(i * 0.35) * 2) + j, 0, (i >> 2) % 2 ? PAL.white : PAL.navy, M.CLOTH, 1);
  }
  const penM = toMesh(pen, { size: V });
  penM.position.copy(W(2, 146, 0));
  penM.rotation.y = 0.4;
  root.add(penM);

  // named anchor points for placing crew, in ship-local world units
  const spots = {
    bow: W(50, 7, 0),
    bowL: W(46, 7, 8),
    bowR: W(46, 7, -8),
    wheel: W(-50, 11, 0),
    quarterL: W(-40, 11, 10),
    quarterR: W(-40, 11, -10),
    waist: [W(28, 0, 11), W(18, 0, 12), W(8, 0, 12), W(-4, 0, 12), W(-16, 0, 12), W(-26, 0, 11), W(20, 0, -12), W(-10, 0, -12)],
    foreRail: W(40, 7, 14),
    sternRail: W(-62, 11, 12),
  };
  root.userData = {
    spots,
    deckY: (x) => (deckY(x / V) + WL) * V + V / 2,
    size: { halfLength: 68 * V, halfBeam: BEAM * V },
  };
  return { group: root, poses: ["sail"], expressions: ["default"], setPose() {}, setExpression() {}, spots };
}
