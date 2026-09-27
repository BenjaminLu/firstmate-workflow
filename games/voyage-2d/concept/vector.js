// Variant C: the cast hand-authored as 2D vector cutouts in the manga / P5 language.
// One skeleton with per-character proportions and a pose; every part is a flat colour,
// one hard cel shadow shape (light from the upper left), and a black ink outline. Faces
// keep the approved rule: eyes a black block plus white, no glint.
const D = Math.PI / 180;
const INK = "#0c0608";

export const PAL = {
  navy: "#1f2a5c", navyS: "#10163a", gold: "#f2c040", goldS: "#b8801c", red: "#e60012", redS: "#8a0010",
  white: "#f8f4ec", whiteS: "#b9b2c8", skin: "#f6c49a", skinS: "#d88a68", hair: "#1a1216", hairS: "#000",
  beard: "#3a2418", beardS: "#1e120c", boot: "#2a1a12", bootS: "#120a06", blue: "#2a5ad8", blueS: "#16307a",
  green: "#1f9a58", greenS: "#0e5a32", olive: "#4a5a30", oliveS: "#26301a", brown: "#7a4a24", brownS: "#40240e",
  robot: "#eef0f4", robotS: "#9aa2b4", orange: "#e8742a", orangeS: "#9a3a10", visor: "#101826",
};

// ---------------------------------------------------------------- drawing primitives
function shade(ctx, path, fill, shadow, { lx = -0.6, ly = -0.8, cut = 0.15, w = 6, bbox } = {}) {
  path();
  ctx.fillStyle = fill;
  ctx.fill();
  if (shadow && bbox) {
    // the hard cel shadow: the part of the shape beyond a line facing away from the light
    ctx.save();
    path();
    ctx.clip();
    const [x0, y0, x1, y1] = bbox, cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, R = Math.hypot(x1 - x0, y1 - y0);
    const nx = -lx, ny = -ly, px = cx + nx * R * cut, py = cy + ny * R * cut;
    ctx.beginPath();
    ctx.moveTo(px - ny * R, py + nx * R);
    ctx.lineTo(px + ny * R, py - nx * R);
    ctx.lineTo(px + ny * R + nx * R * 2, py - nx * R + ny * R * 2);
    ctx.lineTo(px - ny * R + nx * R * 2, py + nx * R + ny * R * 2);
    ctx.fillStyle = shadow;
    ctx.fill();
    ctx.restore();
  }
  path();
  ctx.lineWidth = w;
  ctx.strokeStyle = INK;
  ctx.lineJoin = "round";
  ctx.stroke();
}
// a tapered limb segment between two joints
function limb(ctx, a, b, wa, wb, fill, shadow, w = 6) {
  const dx = b[0] - a[0], dy = b[1] - a[1], L = Math.hypot(dx, dy) || 1, nx = -dy / L, ny = dx / L;
  const path = () => {
    ctx.beginPath();
    ctx.moveTo(a[0] + nx * wa, a[1] + ny * wa);
    ctx.lineTo(b[0] + nx * wb, b[1] + ny * wb);
    ctx.arc(b[0], b[1], wb, Math.atan2(ny, nx), Math.atan2(-ny, -nx), true);
    ctx.lineTo(a[0] - nx * wa, a[1] - ny * wa);
    ctx.arc(a[0], a[1], wa, Math.atan2(-ny, -nx), Math.atan2(ny, nx), true);
    ctx.closePath();
  };
  shade(ctx, path, fill, shadow, { bbox: [Math.min(a[0], b[0]) - wa, Math.min(a[1], b[1]) - wa, Math.max(a[0], b[0]) + wa, Math.max(a[1], b[1]) + wa], cut: 0.05, w });
}
const poly = (ctx, pts) => () => { ctx.beginPath(); pts.forEach((p, i) => (i ? ctx.lineTo(...p) : ctx.moveTo(...p))); ctx.closePath(); };
const bboxOf = (pts) => [Math.min(...pts.map((p) => p[0])), Math.min(...pts.map((p) => p[1])), Math.max(...pts.map((p) => p[0])), Math.max(...pts.map((p) => p[1]))];
function shape(ctx, pts, fill, shadow, o = {}) { shade(ctx, poly(ctx, pts), fill, shadow, { bbox: bboxOf(pts), ...o }); }
const at = (p, ang, len) => [p[0] + Math.sin(ang * D) * len, p[1] + Math.cos(ang * D) * len];

// ---------------------------------------------------------------- the skeleton
// angles in degrees from straight down; positive swings toward screen right (the facing)
function skeleton(S, P) {
  const hip = [0, 0];
  const L = {};
  for (const s of ["b", "f"]) {
    const knee = at(hip, P["th" + s], S.thigh);
    const ankle = at(knee, P["sh" + s], S.shin);
    L[s] = { hip: [hip[0] + (s === "f" ? S.hipW * 0.35 : -S.hipW * 0.35), hip[1]], knee, ankle };
    L[s].knee = at(L[s].hip, P["th" + s], S.thigh);
    L[s].ankle = at(L[s].knee, P["sh" + s], S.shin);
  }
  const lean = P.lean || 0;
  const neck = at(hip, 180 + lean, S.torso);
  const sh = { b: [neck[0] - S.shW * 0.8, neck[1] + S.shW * 0.25], f: [neck[0] + S.shW * 0.8, neck[1] + S.shW * 0.25] };
  const A = {};
  for (const s of ["b", "f"]) {
    const elbow = at(sh[s], P["ua" + s], S.upper);
    const wrist = at(elbow, P["fa" + s], S.fore);
    A[s] = { sh: sh[s], elbow, wrist };
  }
  const headC = at(neck, 180 + lean + (P.tilt || 0), S.neck + S.headR);
  // put the lowest foot on the ground (y 0)
  const low = Math.max(L.b.ankle[1], L.f.ankle[1]) + S.foot * 0.6;
  const off = (p) => [p[0], p[1] - low];
  const mv = (o) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, off(v)]));
  return { hip: off(hip), neck: off(neck), head: off(headC), L: { b: mv(L.b), f: mv(L.f) }, A: { b: mv(A.b), f: mv(A.f) } };
}

// ---------------------------------------------------------------- faces and heads
function eyes(ctx, c, R, { gap = 0.42, h = 0.36, w = 0.2, y = 0.05, brow = 14, browW = 10, slant = 1 } = {}) {
  for (const s of [-1, 1]) {
    const ex = c[0] + s * R * gap + R * 0.1, ey = c[1] + R * y;
    // the white, then the black block, no glint
    ctx.fillStyle = "#fff";
    ctx.beginPath();
    ctx.moveTo(ex - R * w * 1.1, ey - R * h * 0.4);
    ctx.lineTo(ex + R * w * 1.1, ey - R * h * 0.55 + s * slant * 4);
    ctx.lineTo(ex + R * w * 1.0, ey + R * h * 0.5);
    ctx.lineTo(ex - R * w * 1.0, ey + R * h * 0.5);
    ctx.closePath();
    ctx.fill();
    ctx.lineWidth = 5;
    ctx.strokeStyle = INK;
    ctx.stroke();
    ctx.fillStyle = INK;
    ctx.fillRect(ex - R * w * 0.35 + R * 0.05, ey - R * h * 0.5, R * w * 0.95, R * h * 0.98);
    // the brow: a heavy slanted blade
    ctx.beginPath();
    ctx.moveTo(ex - s * R * w * 1.5, ey - R * h * 0.75 - brow * 0.3);
    ctx.lineTo(ex + s * R * w * 1.6, ey - R * h * 0.9 - brow + (s > 0 ? 0 : 0));
    ctx.lineTo(ex + s * R * w * 1.6, ey - R * h * 0.9 - brow + browW);
    ctx.lineTo(ex - s * R * w * 1.5, ey - R * h * 0.75 - brow * 0.3 + browW);
    ctx.fill();
  }
}
function grin(ctx, c, R, { w = 0.42, y = 0.52, open = 0.22 } = {}) {
  ctx.beginPath();
  ctx.moveTo(c[0] - R * w + R * 0.1, c[1] + R * y);
  ctx.quadraticCurveTo(c[0] + R * 0.1, c[1] + R * (y + open * 2.2), c[0] + R * w + R * 0.1, c[1] + R * (y - 0.06));
  ctx.closePath();
  ctx.fillStyle = "#6a1016";
  ctx.fill();
  ctx.lineWidth = 5;
  ctx.strokeStyle = INK;
  ctx.stroke();
  // teeth band
  ctx.save();
  ctx.clip();
  ctx.fillStyle = "#fff";
  ctx.fillRect(c[0] - R, c[1] + R * (y - 0.05), R * 2, R * open * 0.6);
  ctx.restore();
}
function faceShape(ctx, c, R, jaw = "sharp") {
  return () => {
    ctx.beginPath();
    if (jaw === "square") {
      ctx.moveTo(c[0] - R * 0.95, c[1] - R * 0.2);
      ctx.quadraticCurveTo(c[0] - R, c[1] - R * 1.05, c[0] + R * 0.1, c[1] - R * 1.05);
      ctx.quadraticCurveTo(c[0] + R * 1.1, c[1] - R * 1.0, c[0] + R * 1.0, c[1] - R * 0.2);
      ctx.lineTo(c[0] + R * 0.9, c[1] + R * 0.6);
      ctx.lineTo(c[0] + R * 0.3, c[1] + R * 0.95);
      ctx.lineTo(c[0] - R * 0.5, c[1] + R * 0.9);
      ctx.lineTo(c[0] - R * 0.95, c[1] + R * 0.5);
    } else {
      ctx.moveTo(c[0] - R * 0.9, c[1] - R * 0.3);
      ctx.quadraticCurveTo(c[0] - R * 0.95, c[1] - R * 1.05, c[0] + R * 0.1, c[1] - R * 1.05);
      ctx.quadraticCurveTo(c[0] + R * 1.05, c[1] - R * 1.0, c[0] + R * 0.95, c[1] - R * 0.2);
      ctx.lineTo(c[0] + R * 0.75, c[1] + R * 0.55);
      ctx.lineTo(c[0] + R * 0.25, c[1] + R * 1.05); // the pointed manga chin
      ctx.lineTo(c[0] - R * 0.45, c[1] + R * 0.7);
      ctx.lineTo(c[0] - R * 0.9, c[1] + R * 0.25);
    }
    ctx.closePath();
  };
}
function ear(ctx, c, R) {
  const e = [c[0] - R * 0.92, c[1] + R * 0.05];
  shade(ctx, () => { ctx.beginPath(); ctx.ellipse(e[0], e[1], R * 0.16, R * 0.26, 0.2, 0, Math.PI * 2); }, PAL.skin, PAL.skinS, { bbox: [e[0] - 20, e[1] - 30, e[0] + 20, e[1] + 30], cut: 0 });
}
function spikyHair(ctx, c, R, { spikes = 7, len = 0.55, col = PAL.hair, back = true, swoop = 1 } = {}) {
  const pts = [];
  for (let i = 0; i <= spikes; i++) {
    const a = Math.PI * (1.05 + (i / spikes) * 0.95);
    const r = R * (1.02 + (i % 2 ? len : 0.12) * (i === spikes ? 0.4 : 1));
    pts.push([c[0] + Math.cos(a) * r * 1.05 - (i % 2 ? swoop * R * 0.12 : 0), c[1] + Math.sin(a) * r - R * 0.1]);
  }
  pts.push([c[0] + R * 0.95, c[1] - R * 0.1], [c[0] + R * 0.4, c[1] - R * 0.55], [c[0] - R * 0.2, c[1] - R * 0.35], [c[0] - R * 0.7, c[1] - R * 0.15], [c[0] - R * 1.0, c[1] + R * 0.35]);
  shape(ctx, pts, col, PAL.hairS, { cut: 0.25 });
}
function blush(ctx, c, R) {
  ctx.fillStyle = "rgba(230,60,70,.55)";
  for (const s of [-1, 1]) {
    ctx.save();
    ctx.translate(c[0] + s * R * 0.45 + R * 0.1, c[1] + R * 0.42);
    ctx.rotate(-0.2);
    for (let i = 0; i < 3; i++) ctx.fillRect(-R * 0.18 + i * R * 0.12, -R * 0.03, R * 0.06, R * 0.12);
    ctx.restore();
  }
}

// ---------------------------------------------------------------- hats
function sailorCap(ctx, c, R, { band = PAL.navy, ribbon = PAL.blue, tilt = -10, big = 1 } = {}) {
  ctx.save();
  ctx.translate(c[0], c[1] - R * 0.78);
  ctx.rotate(tilt * D);
  const W = R * 1.25 * big;
  // ribbon tails flying back
  shape(ctx, [[-W * 0.7, -R * 0.1], [-W * 1.5, R * 0.25], [-W * 1.75, R * 0.75], [-W * 1.35, R * 0.35], [-W * 0.8, R * 0.18]], ribbon, PAL.blueS, { w: 5 });
  shape(ctx, [[-W * 0.7, 0], [-W * 1.25, R * 0.5], [-W * 1.3, R * 1.0], [-W * 1.05, R * 0.45], [-W * 0.75, R * 0.2]], ribbon, PAL.blueS, { w: 5 });
  // the white drum
  shape(ctx, [[-W, 0], [-W * 0.95, -R * 0.62], [W * 0.95, -R * 0.62], [W, 0]], PAL.white, PAL.whiteS, { cut: 0.3 });
  shape(ctx, [[-W * 1.02, 0], [W * 1.02, 0], [W * 1.0, R * 0.22], [-W * 1.0, R * 0.22]], band, PAL.navyS);
  // the anchor badge
  ctx.fillStyle = band;
  ctx.font = `900 ${R * 0.4}px system-ui, sans-serif`;
  ctx.textAlign = "center";
  ctx.fillText("⚓", W * 0.15, -R * 0.14);
  ctx.restore();
}
function tricorn(ctx, c, R, big = 1.5) {
  ctx.save();
  ctx.translate(c[0] + R * 0.05, c[1] - R * 0.82);
  const W = R * 1.55 * big;
  const pts = [[-W, R * 0.1], [-W * 0.7, -R * 0.55], [-W * 0.2, -R * 0.95], [W * 0.25, -R * 1.05], [W * 0.75, -R * 0.6], [W * 1.05, R * 0.05], [W * 0.4, -R * 0.05], [0, R * 0.12], [-W * 0.45, -R * 0.02]];
  shape(ctx, pts, PAL.navy, PAL.navyS, { cut: 0.2, w: 7 });
  // gold trim along the brim
  ctx.strokeStyle = PAL.gold;
  ctx.lineWidth = 10;
  ctx.beginPath();
  ctx.moveTo(-W * 0.95, R * 0.02);
  ctx.lineTo(-W * 0.45, -R * 0.1);
  ctx.lineTo(0, R * 0.03);
  ctx.lineTo(W * 0.4, -R * 0.13);
  ctx.lineTo(W * 0.98, -R * 0.02);
  ctx.stroke();
  // a red cockade (the P5 accent) and a gold skull-less emblem
  shade(ctx, () => { ctx.beginPath(); ctx.arc(W * 0.45, -R * 0.55, R * 0.2, 0, Math.PI * 2); }, PAL.red, PAL.redS, { bbox: [W * 0.25, -R * 0.75, W * 0.65, -R * 0.35], cut: 0, w: 5 });
  shade(ctx, () => { ctx.beginPath(); ctx.arc(W * 0.45, -R * 0.55, R * 0.08, 0, Math.PI * 2); }, PAL.gold, null, { w: 3 });
  ctx.restore();
}
function boxCap(ctx, c, R, { col, colS, brim = true, tilt = -6, h = 0.7 }) {
  ctx.save();
  ctx.translate(c[0], c[1] - R * 0.72);
  ctx.rotate(tilt * D);
  const W = R * 1.18;
  shape(ctx, [[-W, 0], [-W * 0.92, -R * h], [W * 0.95, -R * h], [W, 0]], col, colS, { cut: 0.25 });
  if (brim) shape(ctx, [[W * 0.2, R * 0.02], [W * 1.55, R * 0.12], [W * 1.45, R * 0.26], [W * 0.1, R * 0.2]], colS, INK, { w: 5 });
  ctx.restore();
}

// ---------------------------------------------------------------- the cast
const S0 = { headR: 53, neck: 10, torso: 150, shW: 44, hipW: 40, upper: 70, fore: 64, thigh: 120, shin: 118, foot: 30 };
export const CAST = {
  captain: {
    S: { ...S0, headR: 63, torso: 170, shW: 88, hipW: 72, upper: 76, fore: 68, thigh: 118, shin: 110, foot: 40 },
    P: { thb: -14, shb: -8, thf: 20, shf: 4, uab: -35, fab: -95, uaf: 100, faf: 95, lean: -4, tilt: -6 },
  },
  firstmate: {
    S: { ...S0, headR: 50, torso: 150, shW: 42, hipW: 34, upper: 73, fore: 68, thigh: 140, shin: 136, foot: 32 },
    P: { thb: -10, shb: -4, thf: 16, shf: 22, uab: -150, fab: -170, uaf: 30, faf: -60, lean: -6, tilt: -8 },
  },
  "reviewer-1": {
    S: { ...S0, headR: 50, torso: 146, shW: 38, hipW: 34, upper: 70, fore: 65, thigh: 132, shin: 128, foot: 30 },
    P: { thb: -6, shb: 0, thf: 10, shf: 6, uab: -20, fab: -60, uaf: 150, faf: 190, lean: 4, tilt: 6 },
  },
  "sailor-hammer": {
    S: { ...S0, headR: 50, torso: 150, shW: 50, hipW: 40, upper: 72, fore: 67, thigh: 128, shin: 122, foot: 32 },
    P: { thb: -18, shb: -6, thf: 24, shf: 10, uab: -160, fab: -120, uaf: 40, faf: -30, lean: -8, tilt: -4 },
  },
  "sailor-bandana": {
    S: { ...S0, headR: 53, torso: 140, shW: 48, hipW: 42, upper: 67, fore: 62, thigh: 110, shin: 106, foot: 32 },
    P: { thb: -12, shb: -2, thf: 14, shf: 4, uab: -165, fab: -175, uaf: 165, faf: 175, lean: 0, tilt: 0 },
  },
  "sailor-spyglass": {
    S: { ...S0, headR: 48, torso: 156, shW: 38, hipW: 32, upper: 73, fore: 70, thigh: 146, shin: 140, foot: 30 },
    P: { thb: -4, shb: 0, thf: 8, shf: 0, uab: -40, fab: -130, uaf: 140, faf: 250, lean: 2, tilt: -10 },
  },
  robot: {
    S: { ...S0, headR: 61, torso: 130, shW: 52, hipW: 40, upper: 62, fore: 60, thigh: 100, shin: 100, foot: 36 },
    P: { thb: -10, shb: 0, thf: 12, shf: 0, uab: -30, fab: -90, uaf: 150, faf: 170, lean: 0, tilt: 8 },
  },
};

export function drawCast(ctx, id) {
  const C = CAST[id], S = C.S, K = skeleton(S, C.P);
  const hd = K.head, R = S.headR;
  const look = LOOKS[id];
  // the back arm and leg
  look.leg(ctx, K.L.b, S, true);
  look.arm(ctx, K.A.b, S, true);
  look.torso(ctx, K, S);
  look.leg(ctx, K.L.f, S, false);
  look.head(ctx, hd, R, K);
  look.arm(ctx, K.A.f, S, false);
  return K;
}

// generic parts
const legOf = (trou, trouS, boot = PAL.boot, flare = false, w = 1) => (ctx, L, S, back) => {
  limb(ctx, L.hip, L.knee, 30 * w, 25 * w, back ? trouS : trou, back ? INK : trouS);
  limb(ctx, L.knee, L.ankle, flare ? 24 * w : 23 * w, flare ? 32 * w : 20 * w, back ? trouS : trou, back ? INK : trouS);
  const a = L.ankle;
  shape(ctx, [[a[0] - 18, a[1] - 26], [a[0] + 16, a[1] - 26], [a[0] + 20, a[1] + 4], [a[0] + 44, a[1] + 10], [a[0] + 44, a[1] + 22], [a[0] - 20, a[1] + 22]], back ? PAL.bootS : boot, PAL.bootS);
};
const armOf = (sleeve, sleeveS, cuff, hand = PAL.skin, w = 1, fist = true) => (ctx, A, S, back) => {
  limb(ctx, A.sh, A.elbow, 24 * w, 20 * w, back ? sleeveS : sleeve, back ? INK : sleeveS);
  limb(ctx, A.elbow, A.wrist, 20 * w, 17 * w, back ? sleeveS : sleeve, back ? INK : sleeveS);
  if (cuff) {
    const k = 0.78, c0 = [A.elbow[0] + (A.wrist[0] - A.elbow[0]) * k, A.elbow[1] + (A.wrist[1] - A.elbow[1]) * k];
    limb(ctx, c0, A.wrist, 15.5 * w, 15.5 * w, back ? INK : cuff, INK, 5);
  }
  shade(ctx, () => { ctx.beginPath(); ctx.arc(A.wrist[0], A.wrist[1] + 6, 19 * w, 0, Math.PI * 2); }, back ? PAL.skinS : hand, PAL.skinS, { bbox: [A.wrist[0] - 16, A.wrist[1] - 12, A.wrist[0] + 16, A.wrist[1] + 20], cut: 0.1, w: 5 });
};
const torsoPts = (K, S, { waist = 0.75, low = 0 } = {}) => {
  const n = K.neck, h = K.hip;
  return [[n[0] - S.shW, n[1] + 14], [n[0] + S.shW, n[1] + 14], [h[0] + S.hipW * waist + 6, h[1] - S.torso * 0.35], [h[0] + S.hipW, h[1] + low], [h[0] - S.hipW, h[1] + low], [h[0] - S.hipW * waist - 6, h[1] - S.torso * 0.35]];
};

const LOOKS = {
  captain: {
    leg: legOf(PAL.navy, PAL.navyS, PAL.boot, false, 1.35),
    arm: armOf(PAL.navy, PAL.navyS, PAL.gold, PAL.skin, 1.45),
    torso(ctx, K, S) {
      const n = K.neck, h = K.hip;
      // the long coat flaring out behind, red lining showing (P5 accent)
      shape(ctx, [[n[0] - S.shW * 0.9, n[1] + 30], [h[0] - S.hipW * 1.6, h[1] + 110], [h[0] - S.hipW * 0.4, h[1] + 92], [h[0] + S.hipW * 1.3, h[1] + 100], [n[0] + S.shW * 0.8, n[1] + 30]], PAL.red, PAL.redS, { cut: 0.1 });
      shape(ctx, [[n[0] - S.shW, n[1] + 12], [n[0] + S.shW, n[1] + 12], [h[0] + S.hipW * 1.05, h[1] + 20], [h[0] + S.hipW * 0.3, h[1] + 60], [h[0] - S.hipW * 1.1, h[1] + 40]], PAL.navy, PAL.navyS, { cut: 0.12 });
      // the open front: white shirt, gold buttons, the red sash
      shape(ctx, [[n[0] - 14, n[1] + 14], [n[0] + 26, n[1] + 14], [h[0] + 16, h[1] - 40], [h[0] - 12, h[1] - 40]], PAL.white, PAL.whiteS);
      shape(ctx, [[h[0] - S.hipW * 1.08, h[1] - 64], [h[0] + S.hipW * 1.08, h[1] - 74], [h[0] + S.hipW * 1.1, h[1] - 34], [h[0] - S.hipW * 1.1, h[1] - 26]], PAL.red, PAL.redS);
      shape(ctx, [[h[0] - 30, h[1] - 40], [h[0] - 50, h[1] + 40], [h[0] - 30, h[1] + 44], [h[0] - 16, h[1] - 36]], PAL.red, PAL.redS, { w: 5 });
      ctx.fillStyle = PAL.gold;
      for (let i = 0; i < 4; i++) for (const s of [-1, 1]) (ctx.beginPath(), ctx.arc(n[0] + 6 + s * 30, n[1] + 40 + i * 28, 6, 0, 7), ctx.fill(), (ctx.lineWidth = 3), ctx.stroke());
      // epaulettes with gold fringe
      for (const s of [-1, 1]) {
        const e = [n[0] + s * S.shW * 0.95, n[1] + 14];
        shade(ctx, () => { ctx.beginPath(); ctx.ellipse(e[0], e[1], 38, 18, s * 0.2, 0, Math.PI * 2); }, PAL.gold, PAL.goldS, { bbox: [e[0] - 38, e[1] - 18, e[0] + 38, e[1] + 18], cut: 0.05 });
        ctx.strokeStyle = PAL.gold;
        ctx.lineWidth = 6;
        for (let i = -3; i <= 3; i++) (ctx.beginPath(), ctx.moveTo(e[0] + i * 10, e[1] + 12), ctx.lineTo(e[0] + i * 11, e[1] + 44 + (i % 2) * 8), ctx.stroke());
      }
    },
    head(ctx, c, R) {
      ear(ctx, c, R);
      shade(ctx, faceShape(ctx, c, R, "square"), PAL.skin, PAL.skinS, { bbox: [c[0] - R, c[1] - R, c[0] + R, c[1] + R], cut: 0.3 });
      // the big beard, the 八 moustache hanging down past the jaw
      shape(ctx, [[c[0] - R * 0.95, c[1] + R * 0.1], [c[0] - R * 1.05, c[1] + R * 1.1], [c[0] - R * 0.4, c[1] + R * 1.75], [c[0] + R * 0.35, c[1] + R * 1.85], [c[0] + R * 1.05, c[1] + R * 1.15], [c[0] + R * 1.0, c[1] + R * 0.15], [c[0] + R * 0.55, c[1] + R * 0.75], [c[0] - R * 0.4, c[1] + R * 0.8]], PAL.beard, PAL.beardS, { cut: 0.2 });
      grin(ctx, [c[0], c[1] + R * 0.1], R, { w: 0.4, y: 0.55, open: 0.26 });
      for (const s of [-1, 1]) shape(ctx, [[c[0] + R * 0.1, c[1] + R * 0.45], [c[0] + R * 0.1 + s * R * 0.55, c[1] + R * 0.42], [c[0] + R * 0.1 + s * R * 0.95, c[1] + R * 1.05], [c[0] + R * 0.1 + s * R * 0.72, c[1] + R * 1.2], [c[0] + R * 0.1 + s * R * 0.42, c[1] + R * 0.7]], PAL.beardS, INK, { w: 5 });
      eyes(ctx, c, R, { gap: 0.42, h: 0.3, w: 0.2, y: -0.12, brow: 12, browW: 14 });
      // the cheek band
      ctx.fillStyle = "rgba(230,60,70,.6)";
      ctx.fillRect(c[0] - R * 0.75, c[1] + R * 0.18, R * 1.7, R * 0.1);
      tricorn(ctx, c, R, 1.55);
    },
  },
  firstmate: {
    leg: legOf(PAL.navy, PAL.navyS, PAL.brown, true, 1.0),
    arm: armOf(PAL.white, PAL.whiteS, PAL.navy, PAL.skin, 1.0),
    torso(ctx, K, S) {
      const n = K.neck, h = K.hip;
      shape(ctx, torsoPts(K, S, { waist: 0.8 }), PAL.white, PAL.whiteS, { cut: 0.1 });
      // the navy vest, open over the shirt, red piping (P5 accent)
      for (const s of [-1, 1]) shape(ctx, [[n[0] + s * 12, n[1] + 16], [n[0] + s * S.shW, n[1] + 16], [h[0] + s * S.hipW * 0.95, h[1] - 6], [h[0] + s * 16, h[1] - 12]], PAL.navy, PAL.navyS, { cut: 0.08 });
      ctx.strokeStyle = PAL.red;
      ctx.lineWidth = 4;
      for (const s of [-1, 1]) (ctx.beginPath(), ctx.moveTo(n[0] + s * 14, n[1] + 20), ctx.lineTo(h[0] + s * 18, h[1] - 14), ctx.stroke());
      // the blue neckerchief, tails flying
      shape(ctx, [[n[0] - 22, n[1] + 10], [n[0] + 24, n[1] + 10], [n[0] + 4, n[1] + 44]], PAL.blue, PAL.blueS, { w: 5 });
      shape(ctx, [[n[0] - 4, n[1] + 30], [n[0] - 60, n[1] + 70], [n[0] - 44, n[1] + 84], [n[0] + 6, n[1] + 40]], PAL.blue, PAL.blueS, { w: 5 });
      shape(ctx, [[h[0] - S.hipW, h[1] - 18], [h[0] + S.hipW, h[1] - 22], [h[0] + S.hipW, h[1] + 2], [h[0] - S.hipW, h[1] + 4]], PAL.brown, PAL.brownS, { w: 5 });
    },
    head(ctx, c, R) {
      ear(ctx, c, R);
      shade(ctx, faceShape(ctx, c, R, "sharp"), PAL.skin, PAL.skinS, { bbox: [c[0] - R, c[1] - R, c[0] + R, c[1] + R], cut: 0.3 });
      eyes(ctx, c, R, { gap: 0.4, h: 0.38, w: 0.2, y: 0.05, brow: 14, browW: 9, slant: 2 });
      grin(ctx, c, R, { w: 0.34, y: 0.58, open: 0.16 });
      spikyHair(ctx, c, R, { spikes: 9, len: 0.6 });
      sailorCap(ctx, c, R, { tilt: -16, big: 1.25 });
    },
  },
  "reviewer-1": {
    leg: legOf(PAL.olive, PAL.oliveS, PAL.brown, false, 1.0),
    arm: armOf(PAL.white, PAL.whiteS, PAL.green, PAL.skin, 1.0),
    torso(ctx, K, S) {
      const n = K.neck, h = K.hip;
      shape(ctx, torsoPts(K, S), PAL.white, PAL.whiteS, { cut: 0.1 });
      shape(ctx, [[n[0] + S.shW * 0.6, n[1] + 16], [n[0] + S.shW * 0.95, n[1] + 22], [h[0] - S.hipW * 0.7, h[1] - 6], [h[0] - S.hipW * 1.0, h[1] - 16]], PAL.brown, PAL.brownS, { w: 5 });
      shape(ctx, [[n[0] - 18, n[1] + 10], [n[0] + 20, n[1] + 10], [n[0], n[1] + 40]], PAL.green, PAL.greenS, { w: 5 });
      shape(ctx, [[h[0] - S.hipW * 1.3, h[1] - 50], [h[0] - S.hipW * 0.5, h[1] - 50], [h[0] - S.hipW * 0.55, h[1] + 10], [h[0] - S.hipW * 1.3, h[1] + 12]], PAL.brown, PAL.brownS);
      shape(ctx, [[h[0] - S.hipW, h[1] - 18], [h[0] + S.hipW, h[1] - 22], [h[0] + S.hipW, h[1] + 2], [h[0] - S.hipW, h[1] + 4]], PAL.brownS, INK, { w: 5 });
    },
    head(ctx, c, R) {
      ear(ctx, c, R);
      shade(ctx, faceShape(ctx, c, R, "sharp"), PAL.skin, PAL.skinS, { bbox: [c[0] - R, c[1] - R, c[0] + R, c[1] + R], cut: 0.3 });
      eyes(ctx, c, R, { gap: 0.4, h: 0.3, w: 0.17, y: 0.05, brow: 12, browW: 6 });
      // the round glasses: thick black frames, a white glare band (no eye glint)
      for (const s of [-1, 1]) {
        ctx.lineWidth = 9;
        ctx.strokeStyle = INK;
        ctx.beginPath();
        ctx.arc(c[0] + s * R * 0.4 + R * 0.1, c[1] + R * 0.05, R * 0.3, 0, Math.PI * 2);
        ctx.stroke();
      }
      ctx.beginPath();
      ctx.moveTo(c[0] - R * 0.04, c[1]);
      ctx.lineTo(c[0] + R * 0.24, c[1]);
      ctx.stroke();
      ctx.lineWidth = 5;
      ctx.beginPath();
      ctx.moveTo(c[0] + R * 0.05, c[1] + R * 0.6);
      ctx.lineTo(c[0] + R * 0.35, c[1] + R * 0.56);
      ctx.stroke();
      spikyHair(ctx, c, R, { spikes: 6, len: 0.35 });
      boxCap(ctx, c, R, { col: PAL.green, colS: PAL.greenS, tilt: -8, h: 0.62 });
    },
  },
  "sailor-hammer": sailor({ hat: "cap", prop: "hammer" }),
  "sailor-bandana": sailor({ hat: "red", prop: "scroll" }),
  "sailor-spyglass": sailor({ hat: "cap", prop: "spyglass" }),
  robot: {
    leg: (ctx, L, S, back) => {
      limb(ctx, L.hip, L.knee, 18, 16, back ? PAL.robotS : "#8a92a4", INK);
      limb(ctx, L.knee, L.ankle, 24, 28, back ? PAL.robotS : PAL.robot, PAL.robotS);
      const a = L.ankle;
      shape(ctx, [[a[0] - 26, a[1] - 10], [a[0] + 40, a[1] - 10], [a[0] + 44, a[1] + 22], [a[0] - 28, a[1] + 22]], PAL.orange, PAL.orangeS);
    },
    arm: (ctx, A, S, back) => {
      limb(ctx, A.sh, A.elbow, 22, 18, back ? PAL.robotS : PAL.robot, PAL.robotS);
      limb(ctx, A.elbow, A.wrist, 18, 22, back ? PAL.robotS : PAL.robot, PAL.robotS);
      shape(ctx, [[A.wrist[0] - 20, A.wrist[1] - 4], [A.wrist[0] + 20, A.wrist[1] - 4], [A.wrist[0] + 16, A.wrist[1] + 30], [A.wrist[0] - 16, A.wrist[1] + 30]], "#8a92a4", INK, { w: 5 });
      if (!back) {
        // the laptop under the arm
        const w = A.elbow;
        shape(ctx, [[w[0] - 70, w[1] + 14], [w[0] + 40, w[1] + 4], [w[0] + 46, w[1] + 24], [w[0] - 64, w[1] + 34]], "#2a2e3a", INK, { w: 5 });
      }
    },
    torso(ctx, K, S) {
      const n = K.neck, h = K.hip;
      shape(ctx, [[n[0] - S.shW, n[1] + 6], [n[0] + S.shW, n[1] + 6], [h[0] + S.hipW * 1.1, h[1] - 10], [h[0] - S.hipW * 1.1, h[1] - 10]], PAL.robot, PAL.robotS, { cut: 0.1 });
      shape(ctx, [[n[0] - 26, n[1] + 40], [n[0] + 26, n[1] + 40], [n[0], n[1] + 80]], "#2aa0ff", "#1060c0", { w: 5 });
      shape(ctx, [[h[0] - S.hipW, h[1] - 16], [h[0] + S.hipW, h[1] - 16], [h[0] + S.hipW, h[1] + 8], [h[0] - S.hipW, h[1] + 8]], PAL.orange, PAL.orangeS, { w: 5 });
    },
    head(ctx, c, R) {
      shape(ctx, [[c[0] - R * 1.1, c[1] - R * 0.85], [c[0] + R * 1.15, c[1] - R * 0.95], [c[0] + R * 1.1, c[1] + R * 0.8], [c[0] - R * 1.05, c[1] + R * 0.85]], PAL.robot, PAL.robotS, { cut: 0.25 });
      shape(ctx, [[c[0] - R * 0.8, c[1] - R * 0.5], [c[0] + R * 0.9, c[1] - R * 0.55], [c[0] + R * 0.85, c[1] + R * 0.45], [c[0] - R * 0.75, c[1] + R * 0.5]], PAL.visor, INK);
      // the eyes: white bars on black (no glint), angled confident
      ctx.fillStyle = "#e8f6ff";
      for (const s of [-1, 1]) {
        ctx.save();
        ctx.translate(c[0] + s * R * 0.36 + R * 0.05, c[1]);
        ctx.rotate(s * 0.12);
        ctx.fillRect(-R * 0.11, -R * 0.28, R * 0.22, R * 0.56);
        ctx.restore();
      }
      shape(ctx, [[c[0] - R * 1.25, c[1] - R * 0.2], [c[0] - R * 1.05, c[1] - R * 0.2], [c[0] - R * 1.05, c[1] + R * 0.3], [c[0] - R * 1.25, c[1] + R * 0.3]], PAL.orange, PAL.orangeS, { w: 5 });
      ctx.lineWidth = 6;
      ctx.strokeStyle = INK;
      ctx.beginPath();
      ctx.moveTo(c[0] + R * 0.1, c[1] - R * 0.95);
      ctx.lineTo(c[0] + R * 0.3, c[1] - R * 1.5);
      ctx.stroke();
      shade(ctx, () => { ctx.beginPath(); ctx.arc(c[0] + R * 0.3, c[1] - R * 1.6, R * 0.16, 0, Math.PI * 2); }, PAL.red, PAL.redS, { bbox: [c[0], c[1] - R * 1.8, c[0] + R * 0.5, c[1] - R * 1.4], cut: 0, w: 5 });
    },
  },
};

function sailor({ hat, prop }) {
  return {
    leg: legOf(PAL.navy, PAL.navyS, PAL.boot, true, 1.0),
    arm: (ctx, A, S, back) => {
      armOf(PAL.white, PAL.whiteS, PAL.navy)(ctx, A, S, back);
      if (back) return;
      const w = A.wrist, e = A.elbow, ang = Math.atan2(w[0] - e[0], w[1] - e[1]);
      ctx.save();
      ctx.translate(w[0], w[1]);
      ctx.rotate(-ang);
      if (prop === "hammer") {
        limb(ctx, [0, 10], [0, 90], 7, 7, PAL.brown, PAL.brownS, 5);
        shape(ctx, [[-34, 80], [34, 80], [34, 120], [-34, 120]], "#6a7080", "#3a3e4a");
      } else if (prop === "spyglass") {
        limb(ctx, [0, -30], [0, 70], 12, 16, PAL.gold, PAL.goldS, 5);
      } else {
        shape(ctx, [[-40, 0], [40, 0], [40, 24], [-40, 24]], PAL.white, PAL.whiteS, { w: 5 });
        ctx.fillStyle = PAL.red;
        ctx.fillRect(-40, 4, 80, 5);
      }
      ctx.restore();
    },
    torso(ctx, K, S) {
      const n = K.neck, h = K.hip;
      shape(ctx, torsoPts(K, S), PAL.white, PAL.whiteS, { cut: 0.1 });
      // the navy sailor collar and a neckerchief (red on the red-cap sailor)
      shape(ctx, [[n[0] - S.shW * 0.95, n[1] + 12], [n[0] + S.shW * 0.95, n[1] + 12], [n[0] + 8, n[1] + 66]], PAL.navy, PAL.navyS, { w: 5 });
      shape(ctx, [[n[0] - 14, n[1] + 40], [n[0] + 26, n[1] + 40], [n[0] + 6, n[1] + 76]], hat === "red" ? PAL.red : PAL.navy, hat === "red" ? PAL.redS : PAL.navyS, { w: 5 });
      shape(ctx, [[h[0] - S.hipW, h[1] - 18], [h[0] + S.hipW, h[1] - 22], [h[0] + S.hipW, h[1] + 2], [h[0] - S.hipW, h[1] + 4]], PAL.brown, PAL.brownS, { w: 5 });
    },
    head(ctx, c, R) {
      ear(ctx, c, R);
      shade(ctx, faceShape(ctx, c, R, hat === "red" ? "square" : "sharp"), PAL.skin, PAL.skinS, { bbox: [c[0] - R, c[1] - R, c[0] + R, c[1] + R], cut: 0.3 });
      eyes(ctx, c, R, { gap: 0.4, h: 0.36, w: 0.19, brow: 13, browW: 8 });
      grin(ctx, c, R, { w: 0.38, y: 0.56, open: prop === "scroll" ? 0.3 : 0.2 });
      blush(ctx, c, R);
      spikyHair(ctx, c, R, { spikes: prop === "hammer" ? 9 : 7, len: prop === "hammer" ? 0.7 : 0.45 });
      if (hat === "red") boxCap(ctx, c, R, { col: "#ea5a26", colS: "#9a2a10", tilt: -10, h: 0.8 });
      else sailorCap(ctx, c, R, { tilt: prop === "spyglass" ? 10 : -12 });
    },
  };
}
