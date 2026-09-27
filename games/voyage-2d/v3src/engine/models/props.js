// Props. Every builder returns a THREE.Group. Hand-held props put the grip at
// the origin with the handle along local z (the fist's groove).
import * as THREE from "three";
import { VoxelGrid, M, hash3 } from "../voxel.js";
import { toMesh, PAL } from "../materials.js";

const grid = (o) => new VoxelGrid({ jitter: 2, seam: 0.3, ...o });
const wrap = (g, scale, origin, name) => {
  const m = toMesh(g, { size: scale, origin: origin || [0, 0, 0], name });
  return m;
};

// ---------------------------------------------------------------- 5x7 pixel font
const FONT = {
  A: ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
  B: ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
  D: ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
  E: ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
  I: ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
  K: ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
  L: ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
  O: ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
  R: ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
  U: ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
  V: ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
  W: ["10001", "10001", "10001", "10101", "10101", "10101", "01010"],
  " ": ["000", "000", "000", "000", "000", "000", "000"],
};
export function textPixels(text) {
  const px = [];
  let cx = 0;
  for (const ch of text) {
    const gl = FONT[ch] || FONT[" "];
    gl.forEach((row, r) => [...row].forEach((b, c) => b === "1" && px.push([cx + c, 6 - r])));
    cx += gl[0].length + 1;
  }
  return { px, width: cx - 1, height: 7 };
}

// ---------------------------------------------------------------- crate
export function buildCrate({ scale = 0.1, w = 10, h = 9, d = 10, seed = 1 } = {}) {
  const g = grid({ jitter: 3, seam: 0.38, seed });
  const W = [0x9a6236, 0x8a5530, 0xa56c3c];
  for (let x = 0; x < w; x++)
    for (let y = 0; y < h; y++)
      for (let z = 0; z < d; z++) {
        const edge = (x === 0 || x === w - 1) + (y === 0 || y === h - 1) + (z === 0 || z === d - 1);
        if (!edge) continue;
        let c = W[(y >> 1) % 3];
        if (y % 3 === 2) c = PAL.woodDark; // plank seams
        // iron corner bands
        if (edge >= 2) c = PAL.iron;
        g.set(x, y, z, c, edge >= 2 ? M.METAL : M.LIT);
      }
  // diagonal brace on the front and side
  for (let i = 1; i < Math.min(w, h) - 1; i++) {
    g.set(i, Math.round((i * (h - 2)) / (w - 2)), d, 0x7a4a26);
    g.set(w, Math.round((i * (h - 2)) / (d - 2)), i, 0x7a4a26);
  }
  // corner plates with rivets
  for (const [x, z] of [
    [-1, -1],
    [w, -1],
    [-1, d],
    [w, d],
  ])
    for (const y of [0, 1, h - 2, h - 1]) g.set(x, y, z, PAL.iron, M.METAL);
  for (const y of [1, h - 2]) {
    g.set(1, y, d, PAL.rivet, M.METAL, 1);
    g.set(w - 2, y, d, PAL.rivet, M.METAL, 1);
  }
  return wrap(g, scale, [(-(w - 1) / 2) * scale, scale / 2, (-(d - 1) / 2) * scale], "crate");
}

// ---------------------------------------------------------------- barrel
export function buildBarrel({ scale = 0.1, h = 12, r = 4.6, seed = 2 } = {}) {
  const g = grid({ jitter: 3, seam: 0.3, seed });
  for (let y = 0; y < h; y++) {
    const k = (y - (h - 1) / 2) / ((h - 1) / 2);
    const rr = r * (1 - 0.16 * k * k);
    for (let x = -6; x <= 6; x++)
      for (let z = -6; z <= 6; z++) {
        const dd = Math.hypot(x, z);
        if (dd > rr) continue;
        const shell = dd > rr - 1.2 || y === 0 || y === h - 1;
        if (!shell) continue;
        const hoop = y === 1 || y === h - 2 || y === Math.round(h * 0.33) || y === Math.round(h * 0.66);
        const stave = Math.floor(((Math.atan2(z, x) + Math.PI) / (Math.PI * 2)) * 14);
        let c = stave % 2 ? 0x8f5a30 : 0x7c4b27;
        if (y === h - 1 && dd < rr - 1.2) c = (x + 20) % 3 === 0 ? 0x6a3f20 : 0x9a6238;
        g.set(x, y, z, hoop && dd > rr - 1.2 ? PAL.iron : c, hoop ? M.METAL : M.LIT);
      }
  }
  return wrap(g, scale, [0, scale / 2, 0], "barrel");
}

// ---------------------------------------------------------------- treasure chest
export function buildChest({ scale = 0.08, open = true } = {}) {
  const g = grid({ jitter: 2, seam: 0.3 });
  const w = 14,
    h = 7,
    d = 9;
  for (let x = 0; x < w; x++)
    for (let y = 0; y < h; y++)
      for (let z = 0; z < d; z++) {
        const edge = (x === 0 || x === w - 1) + (y === 0) + (z === 0 || z === d - 1);
        if (!edge && y < h - 1) continue;
        let c = y % 2 ? 0x8a3f22 : 0x7a3620;
        if (x === 0 || x === w - 1 || x === 4 || x === 9 || y === h - 1) c = PAL.gold;
        if (y === h - 1 && x > 0 && x < w - 1 && z > 0 && z < d - 1) c = PAL.gold;
        g.set(x, y, z, c, c === PAL.gold ? M.METAL : M.LIT);
      }
  if (open) {
    // coins heaped inside, emissive so the chest glows
    for (let x = 1; x < w - 1; x++)
      for (let z = 1; z < d - 1; z++) {
        const hh = 1 + Math.round(1.8 * Math.sin((x / (w - 1)) * Math.PI) * Math.sin((z / (d - 1)) * Math.PI) + hash3(x, 0, z));
        for (let y = h - 1; y < h - 1 + hh; y++) g.set(x, y, z, hash3(x, y, z) < 0.3 ? 0xffe28a : PAL.gold, hash3(x, y, z) < 0.2 ? M.GLOW : M.METAL, 1);
      }
    // lid tipped back
    for (let x = 0; x < w; x++)
      for (let a = 0; a < 5; a++)
        for (let t = 0; t < 7; t++) {
          const y = h - 1 + t + Math.round(Math.sin((a / 4) * Math.PI) * 1.5);
          const z = -1 - a + Math.round(t * 0.15);
          g.set(x, y, z, x === 0 || x === w - 1 || x === 4 || x === 9 ? PAL.gold : 0x7a3620, x % 5 === 4 || x === 0 || x === w - 1 ? M.METAL : M.LIT);
        }
  } else {
    for (let x = 0; x < w; x++)
      for (let z = 0; z < d; z++) {
        const top = Math.round(2.5 * Math.sin((z / (d - 1)) * Math.PI));
        for (let y = h; y <= h + top; y++) g.set(x, y, z, x === 0 || x === w - 1 || x === 4 || x === 9 ? PAL.gold : 0x7a3620, x === 0 || x === w - 1 || x === 4 || x === 9 ? M.METAL : M.LIT);
      }
  }
  // lock plate
  g.box(6, 3, d, 7, 5, d, PAL.gold, M.METAL, 1);
  g.set(6, 4, d + 1, PAL.black, M.LIT, 0);
  return wrap(g, scale, [(-(w - 1) / 2) * scale, scale / 2, (-(d - 1) / 2) * scale], "chest");
}

// ---------------------------------------------------------------- globe
export function buildGlobe({ scale = 0.06 } = {}) {
  const g = grid({ jitter: 2, seam: 0.2 });
  const R = 7;
  const cy = 12;
  const land = (x, y, z) => {
    const n = Math.sin(x * 0.55 + 1.3) * Math.cos(z * 0.5 - 0.7) + Math.sin(y * 0.62 + x * 0.2) * 0.8 + (hash3(x, y, z) - 0.5) * 0.35;
    return n > 0.35;
  };
  g.ellipsoid(0, cy, 0, R, R, R, (x, y, z, d) => {
    if (d < 0.6) return null;
    return land(x, y - cy, z) ? (y - cy > 4 ? 0xe9e2c8 : 0xc9a86a) : y % 3 === 0 ? 0x3c6fb8 : 0x2f5ea8;
  });
  // brass meridian ring
  for (let a = 0; a < 64; a++) {
    const t = (a / 64) * Math.PI * 2;
    g.set(Math.round(Math.cos(t) * (R + 1.5) * 0.5), cy + Math.round(Math.sin(t) * (R + 1.5)), Math.round(Math.cos(t) * (R + 1.5) * 0.87), PAL.gold, M.METAL, 1);
  }
  // stand
  g.cyl("y", 2, cy - R - 1, 0, 0, 1, PAL.goldDark, M.METAL, 1);
  g.cyl("y", 0, 1, 0, 0, 4.2, 0x6b4226, M.LIT);
  g.cyl("y", 2, 2, 0, 0, 3, PAL.gold, M.METAL, 1);
  return wrap(g, scale, [0, scale / 2, 0], "globe");
}

// ---------------------------------------------------------------- parchment map
export function buildMap({ scale = 0.04, w = 26, d = 18 } = {}) {
  const g = grid({ jitter: 1, seam: 0.12 });
  const P = 0xf2e2b6;
  for (let x = 0; x < w; x++)
    for (let z = 0; z < d; z++) {
      let y = 0;
      if (x < 2 || x > w - 3) y = 1; // curled ends
      let c = hash3(x, 1, z) < 0.12 ? 0xe6d2a0 : P;
      // coastline + dotted route + X
      const coast = Math.abs(Math.sin(x * 0.45) * 3 + 6 - z) < 0.6;
      if (coast && x > 3 && x < w - 4) c = 0x9c7040;
      if (z === 11 && x % 2 === 0 && x > 4 && x < w - 6) c = 0xa33a2a;
      if ((x === w - 7 || x === w - 5) && (z === 10 || z === 12)) c = 0xa33a2a;
      if (x === w - 6 && z === 11) c = 0xa33a2a;
      if ((x === 5 || x === 7) && z >= 3 && z <= 5 && (x + z) % 2 === 0) c = 0x6a8a4a;
      g.set(x, y, z, c, M.LIT, 1);
      if (x === 0 || x === w - 1) g.set(x, 2, z, 0xdcc48e, M.LIT, 1);
    }
  return wrap(g, scale, [(-(w - 1) / 2) * scale, scale / 2, (-(d - 1) / 2) * scale], "map");
}

// ---------------------------------------------------------------- stamp (grip at origin)
export function buildStamp({ scale = 0.05 } = {}) {
  const g = grid({ jitter: 1, seam: 0.25 });
  // knob grip around origin, handle down to the block (block below the hand, along -y)
  g.ellipsoid(0, 0, 0, 1.6, 1.6, 1.6, 0xc0302a);
  g.cyl("y", -4, -1, 0, 0, 1, 0xa82a22);
  g.box(-3, -5, -2, 3, -5, 2, PAL.gold, M.METAL, 1);
  g.box(-3, -7, -2, 3, -6, 2, 0xb8261c);
  g.box(-3, -8, -2, 3, -8, 2, 0x3a1010);
  return wrap(g, scale, [0, 0, 0], "stamp");
}

// ---------------------------------------------------------------- scroll
export function buildScroll({ scale = 0.04, glow = false, open = false } = {}) {
  const g = grid({ jitter: 1, seam: 0.2 });
  const mat = glow ? M.GLOW : M.LIT;
  const PAPER = glow ? 0xffe0a0 : 0xf0dfb0;
  const INK = glow ? 0xd08a2a : 0x8a5a2a;
  if (open) {
    // unfurled sheet with rolled ends and a drawn symbol
    for (let x = -8; x <= 8; x++)
      for (let y = -10; y <= 10; y++) {
        const ink = (Math.abs(Math.hypot(x, y) - 4.5) < 0.6 && hash3(x, y, 1) < 0.9) || (Math.abs(x) <= 0 && Math.abs(y) < 4) || (Math.abs(y) <= 0 && Math.abs(x) < 4);
        g.set(x, y, 0, ink ? INK : PAPER, mat, 1);
      }
    for (const yy of [-11, 11]) g.cyl("x", -9, 9, yy, 0, 1.4, glow ? 0xffd080 : 0xe0c890, mat, 1);
  } else {
    g.cyl("x", -7, 7, 0, 0, 2.2, (x) => (Math.abs(x) >= 6 ? 0xe0c890 : PAPER), mat, 1);
    g.cyl("x", -1, 1, 0, 0, 2.6, 0xc03030, M.LIT, 1);
  }
  const grp = wrap(g, scale, [0, 0, 0], glow ? "scroll-glow" : "scroll");
  if (glow) {
    const l = new THREE.PointLight(0xffc070, 1.2, 2.5, 2);
    grp.add(l);
  }
  return grp;
}

// ---------------------------------------------------------------- flags on poles
export function buildFlag({ text = "WORKER", color = 0x2a45c8, dark = 0x1a2c8a, scale = 0.05, pole = 36, wave = 1 } = {}) {
  const g = grid({ jitter: 1, seam: 0.2 });
  const t = textPixels(text);
  const w = t.width + 8;
  const h = t.height + 6;
  // pole
  g.cyl("y", 0, pole, 0, 0, 0.9, 0x6b4226, M.LIT, 2);
  g.ellipsoid(0, pole + 1, 0, 1.3, 1.3, 1.3, PAL.gold, M.METAL, 1);
  const on = new Set(t.px.map(([x, y]) => x + "," + y));
  const top = pole - 1;
  for (let x = 1; x <= w; x++) {
    const zoff = Math.round(Math.sin(x * 0.28) * 1.6 * wave);
    const droop = Math.round((x / w) * 1.5 * wave);
    for (let y = 0; y < h; y++) {
      const tx = x - 5,
        ty = y - 3;
      const letter = on.has(tx + "," + ty);
      const border = y === 0 || y === h - 1;
      const c = letter ? PAL.white : border ? dark : color;
      g.set(x, top - h + 1 + y - droop, zoff, c, M.CLOTH, 1);
    }
  }
  return wrap(g, scale, [0, scale / 2, 0], "flag-" + text.toLowerCase());
}

// ---------------------------------------------------------------- lantern
export function buildLantern({ scale = 0.05, light = true } = {}) {
  const g = grid({ jitter: 1, seam: 0.3 });
  // base
  g.box(-3, 0, -3, 3, 1, 3, PAL.iron, M.METAL, 2);
  // glass box with iron corner posts and a cross bar
  for (let y = 2; y <= 8; y++)
    for (let x = -2; x <= 2; x++)
      for (let z = -2; z <= 2; z++) {
        const post = Math.abs(x) === 2 && Math.abs(z) === 2;
        const bar = y === 5 && (Math.abs(x) === 2 || Math.abs(z) === 2);
        if (post || bar) g.set(x, y, z, PAL.iron, M.METAL, 1);
        else g.set(x, y, z, Math.abs(x) + Math.abs(z) <= 1 && y >= 3 && y <= 6 ? 0xfff0c0 : 0xffb54a, M.GLOW, 1);
      }
  // roof + ring
  g.box(-3, 9, -3, 3, 9, 3, PAL.iron, M.METAL, 2);
  g.box(-2, 10, -2, 2, 10, 2, PAL.ironLight, M.METAL, 2);
  g.box(-1, 11, -1, 1, 11, 1, PAL.iron, M.METAL, 2);
  g.set(0, 12, -1, PAL.iron, M.METAL, 1).set(0, 13, 0, PAL.iron, M.METAL, 1).set(0, 12, 1, PAL.iron, M.METAL, 1);
  const grp = wrap(g, scale, [0, scale / 2, 0], "lantern");
  if (light) {
    const l = new THREE.PointLight(0xffa54a, 2.2, 4 * (scale / 0.05), 2);
    l.position.y = 5 * scale;
    grp.add(l);
  }
  return grp;
}

// ---------------------------------------------------------------- hand-held tools
export function buildSpyglass({ scale = 0.05 } = {}) {
  const g = grid({ jitter: 1, seam: 0.25 });
  g.cyl("z", -3, 3, 0, 0, 1.1, 0x2a2a30, M.METAL, 1);
  g.cyl("z", 4, 8, 0, 0, 1.5, PAL.goldDark, M.METAL, 1);
  g.cyl("z", 9, 13, 0, 0, 1.9, 0x3a2a20, M.LIT, 1);
  g.cyl("z", 14, 14, 0, 0, 2.2, PAL.gold, M.METAL, 1);
  g.cyl("z", 8, 8, 0, 0, 1.9, PAL.gold, M.METAL, 1);
  g.set(0, 0, 15, 0x9fd8ff, M.GLOW, 0);
  return wrap(g, scale, [0, 0, 0], "spyglass");
}

export function buildHammer({ scale = 0.05 } = {}) {
  const g = grid({ jitter: 2, seam: 0.3 });
  g.box(0, 0, -3, 0, 0, 7, 0x8a5a30);
  g.box(-1, -1, -3, 1, 1, -2, 0x6b4226); // pommel wrap
  g.box(-1, -2, 7, 1, 4, 10, PAL.ironLight, M.METAL, 2); // head
  g.box(-1, -3, 7, 1, -3, 10, PAL.iron, M.METAL, 2);
  g.box(-1, 5, 8, 1, 5, 9, PAL.iron, M.METAL, 2);
  return wrap(g, scale, [0, 0, 0], "hammer");
}

export function buildLaptop({ scale = 0.05, open = 105 } = {}) {
  const grp = new THREE.Group();
  const base = grid({ jitter: 1, seam: 0.25 });
  base.box(-7, 0, -5, 7, 0, 5, 0x3a3d48, M.METAL, 1);
  for (let x = -6; x <= 6; x++) for (let z = -3; z <= 2; z++) if ((x + z) % 2 === 0) base.set(x, 1, z, 0x22242c, M.LIT, 1);
  base.box(-2, 1, 3, 2, 1, 4, 0x2c2f38, M.LIT, 1);
  grp.add(wrap(base, scale, [0, 0, 0]));
  const lid = grid({ jitter: 1, seam: 0.2 });
  lid.box(-7, 0, 0, 7, 9, 0, 0x3a3d48, M.METAL, 1);
  for (let x = -6; x <= 6; x++)
    for (let y = 1; y <= 8; y++) {
      const code = y % 2 === 0 && x < -6 + ((y * 7 + 3) % 11) ? (y % 4 === 0 ? 0x8fe3ff : 0x6fffb0) : 0x1a3350;
      lid.set(x, y, 1, code, M.GLOW, 0);
    }
  lid.set(0, 5, -1, 0xd0d4dc, M.METAL, 1); // logo on the back
  const lidMesh = wrap(lid, scale, [0, 0, 0]);
  const hinge = new THREE.Group();
  hinge.position.set(0, 0.5 * scale, -5 * scale);
  hinge.rotation.x = -((open - 90) * Math.PI) / 180;
  hinge.add(lidMesh);
  grp.add(hinge);
  grp.name = "laptop";
  return grp;
}

export function buildMagnifier({ scale = 0.05 } = {}) {
  const g = grid({ jitter: 1, seam: 0.25 });
  g.box(0, 0, -3, 0, 0, 4, 0x6b4226); // handle through the fist
  g.box(-1, -1, -3, 1, 1, -3, PAL.gold, M.METAL, 1);
  g.set(0, 0, 5, PAL.gold, M.METAL, 1);
  // rim in the y-z plane beyond the handle
  const cz = 10;
  for (let y = -6; y <= 6; y++)
    for (let z = cz - 6; z <= cz + 6; z++) {
      const r = Math.hypot(y, z - cz);
      if (r > 5.6) continue;
      if (r > 4.4) g.set(0, y, z, PAL.gold, M.METAL, 1);
      else g.set(0, y, z, r < 1.5 && y > 0 ? 0xe8fbff : 0xa8dcf0, M.GLOW, 0);
    }
  const grp = wrap(g, scale, [0, 0, 0], "magnifier");
  // tame the lens glow: separate darker glow material
  grp.traverse((o) => {
    if (o.isMesh && o.material.isMeshBasicMaterial) {
      o.material = o.material.clone();
      o.material.color.setScalar(0.95);
    }
  });
  return grp;
}

export function buildWhistle({ scale = 0.04 } = {}) {
  const g = grid({ jitter: 1, seam: 0.2 });
  // bosun's pipe: a flared brass horn along +z
  for (let z = -2; z <= 10; z++) {
    const r = z < 6 ? 1.0 : 1.0 + (z - 6) * 0.45;
    g.cyl("z", z, z, 0, 0, r, z >= 9 ? PAL.gold : 0xe0a42e, M.METAL, 1);
  }
  g.ellipsoid(0, -2, 1, 1.5, 1.5, 1.5, PAL.gold, M.METAL, 1);
  g.set(0, 0, 11, 0xffe8a0, M.GLOW, 0);
  return wrap(g, scale, [0, 0, 0], "whistle");
}

// ---------------------------------------------------------------- ship fittings
export function buildCannon({ scale = 0.1, len = 16, carriage = true } = {}) {
  const g = grid({ jitter: 1, seam: 0.3 });
  for (let z = 0; z <= len; z++) {
    const r = 1.9 - (z / len) * 0.5 + (z === len ? 0.5 : 0) + (z === 3 || z === 9 ? 0.45 : 0);
    g.cyl("z", z, z, 0, 0, r, z === len ? 0x24252c : 0x3a3c44, M.METAL, 1);
  }
  g.cyl("z", len, len, 0, 0, 0.9, 0x0c0c10, M.LIT, 0); // bore
  g.ellipsoid(0, 0, -1, 1.4, 1.4, 1.4, 0x3a3c44, M.METAL, 1);
  g.set(0, 0, -3, 0x3a3c44, M.METAL, 1);
  if (carriage) {
    g.box(-3, -4, -2, 3, -2, 7, 0x7a4a26, M.LIT, 3);
    for (const x of [-3, 3]) for (const z of [-1, 6]) g.cyl("x", x, x, -4, z, 1.6, 0x5a3418, M.LIT, 2);
  }
  return wrap(g, scale, [0, 0, 0], "cannon");
}

export function buildAnchor({ scale = 0.1 } = {}) {
  const g = grid({ jitter: 2, seam: 0.3 });
  const C = PAL.ironLight;
  g.box(0, -12, 0, 0, 6, 0, C, M.METAL); // shank
  g.box(-1, -12, 0, 1, 6, 0, C, M.METAL);
  g.box(-5, 3, 0, 5, 4, 0, C, M.METAL); // stock
  // ring
  for (let a = 0; a < 20; a++) {
    const t = (a / 20) * Math.PI * 2;
    g.set(Math.round(Math.cos(t) * 2), 9 + Math.round(Math.sin(t) * 2), 0, C, M.METAL);
  }
  // arms curving up into flukes
  for (let x = -8; x <= 8; x++) {
    const y = -12 + Math.round((x * x) / 9);
    g.box(x, y, 0, x, y + 1, 0, C, M.METAL);
  }
  for (const s of [-1, 1]) g.box(s * 7, -6, -1, s * 9, -4, 1, C, M.METAL);
  g.box(-1, -14, -1, 1, -13, 1, C, M.METAL);
  return wrap(g, scale, [0, 0, 0], "anchor");
}

// chain of alternating links from a to b (world units), returns a group
export function buildChain(a, b, { scale = 0.08, sag = 0.3 } = {}) {
  const g = grid({ jitter: 2, seam: 0.3 });
  const A = a.clone().divideScalar(scale),
    B = b.clone().divideScalar(scale);
  const n = Math.ceil(A.distanceTo(B) / 3);
  for (let i = 0; i <= n; i++) {
    const k = i / n;
    const p = A.clone().lerp(B, k);
    p.y -= (Math.sin(k * Math.PI) * sag) / scale;
    const flip = i % 2;
    for (let u = -1; u <= 1; u++)
      for (let v = -1; v <= 1; v++) {
        if (u === 0 && v === 0) continue;
        if (flip) g.set(p.x + u, p.y + v * 1.4, p.z, PAL.iron, M.METAL);
        else g.set(p.x, p.y + v * 1.4, p.z + u, PAL.iron, M.METAL);
      }
  }
  return wrap(g, scale, [0, 0, 0], "chain");
}

export function buildWheel({ scale = 0.05 } = {}) {
  const g = grid({ jitter: 2, seam: 0.3 });
  const R = 9;
  // rim (in x-y plane, axle along z)
  for (let x = -R - 5; x <= R + 5; x++)
    for (let y = -R - 5; y <= R + 5; y++) {
      const r = Math.hypot(x, y);
      if (r <= R + 0.5 && r >= R - 1.5) for (let z = -1; z <= 0; z++) g.set(x, y, z, r > R - 0.5 ? 0x6b3e1e : 0x8a5230);
      if (r < 2.5) for (let z = -2; z <= 1; z++) g.set(x, y, z, r < 1.2 ? PAL.gold : 0x6b3e1e, r < 1.2 ? M.METAL : M.LIT);
    }
  // 8 spokes with turned handles poking past the rim
  for (let s = 0; s < 8; s++) {
    const t = (s / 8) * Math.PI * 2;
    for (let r = 2; r <= R + 4; r++) {
      const x = Math.round(Math.cos(t) * r),
        y = Math.round(Math.sin(t) * r);
      const handle = r > R + 0.5;
      g.set(x, y, 0, handle ? (r === R + 4 ? 0x5a3418 : 0x9a6238) : 0x7a4a26);
      if (handle && r === R + 3) g.set(x, y, 1, 0x9a6238), g.set(x, y, -1, 0x9a6238);
    }
  }
  // gold hub ring decorations
  for (let s = 0; s < 8; s++) {
    const t = ((s + 0.5) / 8) * Math.PI * 2;
    g.set(Math.round(Math.cos(t) * (R - 0.5)), Math.round(Math.sin(t) * (R - 0.5)), 1, PAL.gold, M.METAL, 1);
  }
  return wrap(g, scale, [0, 0, 0], "wheel");
}
