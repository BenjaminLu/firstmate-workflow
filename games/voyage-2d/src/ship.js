// The ship, painted in vector from its layout (src/layouts.js, or a mod's): a big sailing ship in
// cutaway, her rooms open to the viewer like a dollhouse. Four classes by default (sloop, brig,
// frigate, ship of the line) for up to 7, 12, 18 and 24 hands. Ship space: x toward the bow, y
// down, the main deck's floor at y = 0; the waterline sits at world y = SEA_Y.
//
// Layers. The back layer (the rig's spars, the far side of every room, floors, walls and doors,
// stairs, furniture) is drawn behind the crew; the front layer (the hull's sawn rim, the bilge,
// the near rails, the bow and stern work) in front of them. Both are cached: a whole-ship picture
// for the wide shots, and tiles at a finer grain, made as the camera comes close (a few a frame)
// and kept while there is room. The ship of the line is ~12000 x ~10000 units: one canvas at the
// close camera's grain would be hundreds of megabytes. Sails, the wheel, the bell, the near guns
// and their recoil, the flags and the stowed work are drawn live each frame.
//
// A class change (the ship grows or trims down) cross-fades the two ships while the new one
// scales from the old one's length to its own; the crew stand in the new ship throughout.
import { SEA_Y } from "./env.js";
import { CLASSES, classFor } from "./layouts.js";
import { deckGeometry, railY, Z_SCREEN, DEPTH, BEAM, WALL } from "./deckplan.js";

const WOOD = "#6b3f22", WOOD_D = "#3c2212", WOOD_L = "#8e5a32", GOLD = "#f0b53a", GOLD_D = "#a8741c", INK = "#1c1016";

export { CLASSES, classFor };
const lerp = (a, b, k) => a + (b - a) * k;
const ease = (k) => (k <= 0 ? 0 : k >= 1 ? 1 : k * k * (3 - 2 * k));
const lift = (z) => z * Z_SCREEN;
export const RIM = 60; // the hull's sawn edge, all round the cutaway

// the walkable geometry of each spec, built once
const GEO = new WeakMap();
export function geometryOf(S) {
  if (!GEO.has(S)) GEO.set(S, deckGeometry(S));
  return GEO.get(S);
}
// the height of a deck's floor
export function levelY(S, id, G = geometryOf(S)) {
  return G.decks[id]?.y ?? (id === "nest" ? S.masts.find((m) => m.nest != null)?.nest ?? -900 : 0);
}
// the kraken's four targets along the forward half of the waist and the forecastle
export const sectionsOf = (S) => [0.45, 0.62, 0.8, 0.96].map((f) => lerp(S.main[0], S.fore[1], f));
// the open deck's floor at x (the quarterdeck, the waist, the forecastle): the hero lineup's floor
export function deckYOf(S, x) {
  if (x < S.qd[1]) return S.qd[2];
  if (x >= S.fore[0]) return S.fore[2];
  return 0;
}
export const rigTop = (S) => Math.min(...S.masts.map((m) => m.top), -600);
// the sails as drawn: [x, yTop, half, drop] per yard
export function sailBoxes(S) {
  const out = [];
  for (const m of S.masts) m.yards.forEach(([y, half], yi) => {
    const next = m.yards[yi + 1]?.[0] ?? m.base - (m.base - m.top) * 0.1;
    out.push([m.x, y, half, Math.max(40, next - y - 50)]);
  });
  return out;
}
function hullPath(ctx, S) {
  const pts = S.hull;
  ctx.beginPath();
  ctx.moveTo(pts[0][0], pts[0][1]);
  for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0], pts[i][1]);
  ctx.closePath();
}
function bowsprit(S) { const y = railY(S, S.bow); return [S.bow + S.len * 0.19, y - S.len * 0.07]; }
// the layers' extents in ship space
function boxes(S) {
  const x0 = S.stern - 300, x1 = bowsprit(S)[0] + 200, top = rigTop(S) - 420, bot = S.bottom + 80;
  const fTop = Math.min(...S.decksIn.map((d) => d.y)) - 300;
  return { back: { x0, y0: top, x1, y1: bot }, front: { x0, y0: fTop, x1, y1: bot } };
}

// ---------------------------------------------------------------- small drawing pieces
function planks(ctx, a, b, y) {
  const g = ctx.createLinearGradient(0, y - 36, 0, y);
  g.addColorStop(0, "#a9713f");
  g.addColorStop(1, "#c98d52");
  ctx.fillStyle = g;
  ctx.fillRect(a, y - 36, b - a, 38);
  ctx.strokeStyle = "rgba(60,30,10,.45)";
  ctx.lineWidth = 2;
  for (let k = 1; k < 4; k++) (ctx.beginPath(), ctx.moveTo(a, y - 36 + k * 9), ctx.lineTo(b, y - 36 + k * 9), ctx.stroke());
}
function beam(ctx, a, b, y) {
  ctx.fillStyle = "#5a3218";
  ctx.fillRect(a, y, b - a, BEAM);
  ctx.fillStyle = "#3a1e0c";
  for (let x = a + 30; x < b; x += 62) ctx.fillRect(x - 8, y + 7, 16, 16);
  ctx.fillStyle = "#c98d52";
  ctx.fillRect(a, y, b - a, 3);
}
// a flight of stairs along a link's path on the far side, the treads across its whole width
function stairs(ctx, pts, [z0, z1]) {
  const at = (z) => [pts[1], pts[2]].map(([x, y]) => [x, y - lift(z)]);
  const [f1, f2] = at(z1), [n1, n2] = at(z0);
  const len = Math.hypot(n2[0] - n1[0], n2[1] - n1[1]), n = Math.max(3, Math.round(len / 34));
  const dy = n1[1] - f1[1];
  ctx.lineCap = "round";
  ctx.strokeStyle = "#3a2010";
  ctx.lineWidth = 10;
  ctx.beginPath(); ctx.moveTo(...f1); ctx.lineTo(...f2); ctx.stroke();
  for (let i = 0; i < n; i++) {
    const k = (i + 0.5) / n, x = lerp(n1[0], n2[0], k), y = lerp(n1[1], n2[1], k);
    ctx.fillStyle = "#b07a44";
    ctx.fillRect(x - 22, y - dy - 5, 44, dy + 9);
    ctx.fillStyle = "rgba(60,30,10,.35)";
    ctx.fillRect(x - 22, y - dy * 0.5 - 1, 44, 2);
    ctx.fillStyle = "rgba(40,20,8,.6)";
    ctx.fillRect(x - 22, y + 4, 44, 3);
  }
  ctx.strokeStyle = "#3a2010";
  ctx.lineWidth = 14;
  ctx.beginPath(); ctx.moveTo(...n1); ctx.lineTo(...n2); ctx.stroke();
  ctx.strokeStyle = GOLD_D;
  ctx.lineWidth = 5;
  ctx.beginPath(); ctx.moveTo(n1[0], n1[1] - 70); ctx.lineTo(n2[0], n2[1] - 70); ctx.stroke();
  ctx.lineWidth = 3;
  for (let i = 0; i <= 3; i++) { const k = i / 3, x = lerp(n1[0], n2[0], k), y = lerp(n1[1], n2[1], k); ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(x, y - 70); ctx.stroke(); }
  ctx.lineCap = "butt";
}
function ladder(ctx, pts, z) {
  const x = pts[1][0], y0 = pts[1][1] - lift(z) - 30, y1 = pts[2][1] - lift(z);
  ctx.strokeStyle = "#7a4a22";
  ctx.lineWidth = 8;
  ctx.beginPath(); ctx.moveTo(x - 20, y0); ctx.lineTo(x - 20, y1); ctx.moveTo(x + 20, y0); ctx.lineTo(x + 20, y1); ctx.stroke();
  ctx.strokeStyle = "#b07a44";
  ctx.lineWidth = 6;
  for (let y = y1 - 20; y > y0 + 6; y -= 34) (ctx.beginPath(), ctx.moveTo(x - 20, y), ctx.lineTo(x + 20, y), ctx.stroke());
}
function hatch(ctx, x0, x1, y, zw = 100) {
  const h = 22 * Math.max(1, zw / 100);
  ctx.fillStyle = "#1a0d06";
  ctx.fillRect(x0, y - 8 - h, x1 - x0, h);
  ctx.strokeStyle = GOLD_D;
  ctx.lineWidth = 4;
  ctx.strokeRect(x0, y - 8 - h, x1 - x0, h);
}
function flightZ(G, l) {
  const o = G.obstacles.find((q) => q.kind === "stairs" && q.link === l.id);
  return o ? [o.z0 + 6, o.z1 - 6] : [l.a.z - 40, l.a.z + 40];
}
function inked(ctx, fill, draw, w = 4) {
  ctx.beginPath();
  draw();
  ctx.fillStyle = fill;
  ctx.fill();
  ctx.lineWidth = w;
  ctx.strokeStyle = INK;
  ctx.stroke();
}
function lantern(ctx, x, top) {
  const ly = top + 50;
  const g = ctx.createRadialGradient(x, ly + 26, 0, x, ly + 26, 170);
  g.addColorStop(0, "rgba(255,200,110,.34)");
  g.addColorStop(1, "rgba(255,160,60,0)");
  ctx.fillStyle = g;
  ctx.fillRect(x - 170, ly - 144, 340, 340);
  ctx.strokeStyle = INK;
  ctx.lineWidth = 3;
  ctx.beginPath(); ctx.moveTo(x, top); ctx.lineTo(x, ly + 6); ctx.stroke();
  ctx.fillStyle = GOLD_D;
  ctx.fillRect(x - 12, ly + 6, 24, 36);
  ctx.fillStyle = "#ffe29a";
  ctx.fillRect(x - 7, ly + 11, 14, 24);
}

// a room's far wall, by kind
const WALLS = {
  cabin: ["#5e2418", "#7a3020"], chart: ["#2f4644", "#3c5856"], workshop: ["#5a3a1e", "#6e4826"], galley: ["#4a2c1c", "#5c3826"],
  quarters: ["#4e2e18", "#5e3a20"], gundeck: ["#3e2412", "#4e2e18"], cargo: ["#2a180c", "#382010"],
};
function roomBack(ctx, r) {
  const top = r.ceil, y = r.y, [c0, c1] = WALLS[r.kind] || ["#4e2e18", "#5e3a20"];
  if (top == null) return;
  const g = ctx.createLinearGradient(0, top, 0, y);
  g.addColorStop(0, c0);
  g.addColorStop(1, c1);
  ctx.fillStyle = g;
  ctx.fillRect(r.x0, top, r.x1 - r.x0, y - top);
  ctx.strokeStyle = "rgba(12,5,2,.4)";
  ctx.lineWidth = 3;
  for (let yy = top + 26; yy < y - 30; yy += 26) (ctx.beginPath(), ctx.moveTo(r.x0, yy), ctx.lineTo(r.x1, yy), ctx.stroke());
  ctx.fillStyle = "rgba(20,8,2,.35)";
  for (let x = r.x0 + 70; x < r.x1 - 20; x += 124) ctx.fillRect(x - 9, top, 18, y - top);
  const h = y - top;
  if (r.kind === "cabin") {
    // panelling, a gold chair rail, and the great stern windows at the aft end
    ctx.strokeStyle = "rgba(255,210,140,.18)";
    ctx.lineWidth = 4;
    for (let x = r.x0 + 40; x < r.x1 - 120; x += 150) ctx.strokeRect(x, top + h * 0.2, 120, h * 0.42);
    ctx.fillStyle = GOLD_D;
    ctx.fillRect(r.x0, top + h * 0.7, r.x1 - r.x0, 8);
    const wx = r.x0 + 30, ww = Math.min(360, (r.x1 - r.x0) * 0.4);
    for (let i = 0; i < 3; i++) {
      const x = wx + i * (ww / 3);
      ctx.fillStyle = "#2a1408";
      ctx.fillRect(x, top + h * 0.16, ww / 3 - 12, h * 0.46);
      const w = ctx.createLinearGradient(0, top + h * 0.16, 0, top + h * 0.62);
      w.addColorStop(0, "#fff0b0");
      w.addColorStop(1, "#ff9a3a");
      ctx.fillStyle = w;
      ctx.fillRect(x + 6, top + h * 0.16 + 6, ww / 3 - 24, h * 0.46 - 12);
      ctx.fillStyle = "#2a1408";
      ctx.fillRect(x + (ww / 3 - 12) / 2 - 3, top + h * 0.16, 6, h * 0.46);
    }
  } else if (r.kind === "chart") {
    for (let x = r.x0 + 70; x < r.x1 - 160; x += 230) {
      ctx.fillStyle = "#e9dcb8";
      ctx.fillRect(x, top + h * 0.2, 150, 110);
      ctx.strokeStyle = "#7a5a30";
      ctx.lineWidth = 3;
      ctx.strokeRect(x, top + h * 0.2, 150, 110);
      ctx.beginPath();
      ctx.moveTo(x + 20, top + h * 0.2 + 80); ctx.bezierCurveTo(x + 50, top + h * 0.2 + 20, x + 90, top + h * 0.2 + 100, x + 130, top + h * 0.2 + 40);
      ctx.stroke();
    }
  } else if (r.kind === "galley") {
    ctx.fillStyle = "rgba(160,60,30,.35)";
    for (let yy = y - 150, row = 0; yy < y - 36; yy += 22, row++) for (let x = r.x0 + 30 + (row % 2) * 20; x < Math.min(r.x1, r.x0 + 330); x += 44) ctx.fillRect(x, yy, 40, 18);
    for (let x = r.x0 + 280; x < r.x1 - 80; x += 160) {
      ctx.strokeStyle = INK; ctx.lineWidth = 3;
      ctx.beginPath(); ctx.moveTo(x, top); ctx.lineTo(x, top + 60); ctx.stroke();
      inked(ctx, "#6a6a72", () => ctx.arc(x, top + 80, 22, 0, Math.PI));
    }
  } else if (r.kind === "workshop") {
    for (let x = r.x0 + 80; x < r.x1 - 80; x += 140) {
      ctx.strokeStyle = "#2a2a30"; ctx.lineWidth = 6;
      ctx.beginPath(); ctx.moveTo(x, top + h * 0.3); ctx.lineTo(x, top + h * 0.5); ctx.stroke();
      ctx.fillStyle = "#6a6a72"; ctx.fillRect(x - 14, top + h * 0.28, 28, 12);
    }
  }
}
// a far gunport with daylight and the far gun's breech
function farGun(ctx, x, y) {
  ctx.fillStyle = "#140a06";
  ctx.fillRect(x - 32, y - 140, 64, 58);
  const sky = ctx.createLinearGradient(0, y - 136, 0, y - 86);
  sky.addColorStop(0, "#9cc4ef");
  sky.addColorStop(1, "#3f7fc6");
  ctx.fillStyle = sky;
  ctx.fillRect(x - 26, y - 134, 52, 46);
  ctx.fillStyle = "#2c2c34";
  ctx.fillRect(x - 12, y - 120, 24, 40);
  ctx.fillStyle = "#4a2a14";
  ctx.fillRect(x - 36, y - 76, 72, 30);
  ctx.fillStyle = "#1c1c22";
  ctx.beginPath(); ctx.arc(x, y - 82, 17, 0, Math.PI * 2); ctx.fill();
  ctx.fillStyle = "#101014";
  for (const dx of [-24, 24]) (ctx.beginPath(), ctx.arc(x + dx, y - 44, 9, 0, Math.PI * 2), ctx.fill());
}
// the furniture, at its floor, lifted by its depth
function drawProp(ctx, G, p) {
  const d = G.decks[p.deck], y = d.y, x = p.x, w = p.w;
  const room = G.rooms.find((r) => r.deck === p.deck && x >= r.x0 && x <= r.x1);
  const top = room?.ceil ?? y - 300;
  switch (p.kind) {
    case "cask": {
      const yy = y - lift(DEPTH - 104) + 4;
      for (const [dx, hh] of [[-w * 0.26, 96], [w * 0.26, 84]]) {
        inked(ctx, "#6e4020", () => ctx.ellipse(x + dx, yy - hh / 2, w * 0.24, hh / 2, 0, 0, Math.PI * 2), 4);
        ctx.strokeStyle = "#2a2a30";
        ctx.lineWidth = 5;
        for (const k of [0.25, 0.75]) (ctx.beginPath(), ctx.moveTo(x + dx - w * 0.23, yy - hh * k), ctx.lineTo(x + dx + w * 0.23, yy - hh * k), ctx.stroke());
      }
      break;
    }
    case "crate": {
      const yy = y - lift(DEPTH - 104) + 4, x0 = x - w / 2;
      inked(ctx, "#8a5a2e", () => ctx.rect(x0, yy - 92, w, 92), 4);
      ctx.strokeStyle = "#4a2a14";
      ctx.lineWidth = 6;
      ctx.beginPath(); ctx.moveTo(x0 + 8, yy - 84); ctx.lineTo(x0 + w - 8, yy - 8); ctx.moveTo(x0 + w - 8, yy - 84); ctx.lineTo(x0 + 8, yy - 8); ctx.stroke();
      break;
    }
    case "workbench": case "table": case "desk": {
      const yy = y - lift(200), hh = p.kind === "desk" ? 86 : p.kind === "table" ? 78 : 74;
      const col = p.kind === "desk" ? "#5a2a14" : p.kind === "table" ? "#7a4a26" : "#8e5a32";
      ctx.fillStyle = INK;
      for (const dx of [-w / 2 + 12, w / 2 - 22]) ctx.fillRect(x + dx, yy - hh, 10, hh);
      inked(ctx, col, () => ctx.rect(x - w / 2, yy - hh - 16, w, 18), 4);
      if (p.kind === "desk") {
        inked(ctx, "#4a2210", () => ctx.rect(x - w / 2 + 8, yy - hh + 2, w - 16, hh * 0.55), 4);
        ctx.fillStyle = "#f4ead2";
        ctx.fillRect(x - 40, yy - hh - 24, 56, 8);
        ctx.fillStyle = "#fff4c8";
        ctx.fillRect(x + 40, yy - hh - 52, 8, 36);
      } else if (p.kind === "table") {
        ctx.fillStyle = "#e9dcb8";
        ctx.fillRect(x - w * 0.3, yy - hh - 22, w * 0.6, 8);
      } else {
        ctx.fillStyle = "#6a6a72";
        ctx.fillRect(x - 40, yy - hh - 26, 40, 10);
        ctx.fillStyle = "#b07a44";
        ctx.fillRect(x + 10, yy - hh - 22, 50, 6);
      }
      break;
    }
    case "stove": {
      const yy = y - lift(DEPTH - 110), x0 = x - w / 2;
      ctx.fillStyle = "#2c2c34";
      ctx.fillRect(x - 12, top, 24, yy - 150 - top);
      inked(ctx, "#2c2c34", () => ctx.rect(x0, yy - 110, w, 110), 5);
      ctx.fillStyle = "#ff7a2a";
      ctx.fillRect(x0 + 24, yy - 60, w - 48, 34);
      inked(ctx, "#4a4a52", () => ctx.rect(x - 34, yy - 150, 60, 40), 4);
      break;
    }
    case "chest": {
      const yy = y - lift(DEPTH - 80);
      inked(ctx, "#7a4a22", () => ctx.rect(x - w / 2, yy - 52, w, 52), 4);
      ctx.fillStyle = GOLD_D;
      ctx.fillRect(x - w / 2, yy - 36, w, 6);
      break;
    }
    case "capstan": {
      const yy = y - lift(DEPTH / 2) + 6;
      ctx.fillStyle = "#5a3218";
      ctx.fillRect(x - 36, yy - 64, 72, 64);
      ctx.fillStyle = "#8e5a32";
      ctx.fillRect(x - 40, yy - 72, 80, 14);
      ctx.fillStyle = GOLD_D;
      ctx.fillRect(x - 38, yy - 40, 76, 7);
      ctx.strokeStyle = WOOD;
      ctx.lineWidth = 8;
      ctx.beginPath(); ctx.moveTo(x - 90, yy - 66); ctx.lineTo(x + 90, yy - 66); ctx.stroke();
      break;
    }
    case "hammock": {
      const hy = top + 70;
      ctx.strokeStyle = "rgba(40,20,8,.6)";
      ctx.lineWidth = 2;
      ctx.beginPath(); ctx.moveTo(x - w / 2, top); ctx.lineTo(x - w / 2, hy); ctx.moveTo(x + w / 2, top); ctx.lineTo(x + w / 2, hy); ctx.stroke();
      ctx.strokeStyle = "#d8c6a4";
      ctx.lineWidth = 7;
      ctx.beginPath(); ctx.moveTo(x - w / 2, hy); ctx.quadraticCurveTo(x, hy + 70, x + w / 2, hy); ctx.stroke();
      break;
    }
    case "lantern": lantern(ctx, x, top); break;
    case "shelf": {
      const yy = top + (y - top) * 0.28;
      inked(ctx, "#4a2210", () => ctx.rect(x - w / 2, yy, w, 150), 4);
      const cols = ["#8a2020", "#1f2f5c", "#1f7a48", "#c89a2a"];
      for (let i = 0; i < 10; i++) { ctx.fillStyle = cols[i % 4]; ctx.fillRect(x - w / 2 + 10 + i * 14, yy + 14 + (i % 3) * 2, 11, 56); ctx.fillRect(x - w / 2 + 10 + i * 14, yy + 84, 11, 52 - (i % 2) * 8); }
      break;
    }
  }
}
function nestTop(ctx, m) {
  inked(ctx, WOOD, () => {
    ctx.moveTo(m.x - 216, m.nest);
    ctx.lineTo(m.x + 216, m.nest);
    ctx.lineTo(m.x + 170, m.nest + 110);
    ctx.lineTo(m.x - 170, m.nest + 110);
    ctx.closePath();
  }, 5);
  ctx.fillStyle = "rgba(0,0,0,.22)";
  ctx.fillRect(m.x - 190, m.nest + 50, 380, 10);
  planks(ctx, m.x - 206, m.x + 206, m.nest);
  ctx.fillStyle = GOLD;
  ctx.fillRect(m.x - 218, m.nest, 436, 12);
}

// ---------------------------------------------------------------- the back layer
function drawBack(ctx, S, G, V) {
  const vis = (x0, y0, x1, y1) => !V || (x1 >= V.x0 && x0 <= V.x1 && y1 >= V.y0 && y0 <= V.y1);
  // the rig's spars: the masts above their decks, the shrouds, the stays to the bowsprit
  for (const m of S.masts) {
    if (!vis(m.x - 700, m.top - 60, m.x + 700, m.base)) continue;
    const w = 20 + (m.base - m.top) * 0.006;
    const g = ctx.createLinearGradient(m.x - w, 0, m.x + w, 0);
    g.addColorStop(0, "#5a3218");
    g.addColorStop(0.45, "#9a6436");
    g.addColorStop(1, "#4a2a14");
    ctx.fillStyle = g;
    ctx.beginPath();
    ctx.moveTo(m.x - w, m.base);
    ctx.lineTo(m.x - w * 0.5, m.top);
    ctx.lineTo(m.x + w * 0.5, m.top);
    ctx.lineTo(m.x + w, m.base);
    ctx.fill();
    ctx.fillStyle = "#2a2a30";
    for (let y = m.base - 160; y > m.top + 80; y -= 260) ctx.fillRect(m.x - w * 0.9, y, w * 1.8, 12);
    ctx.fillStyle = GOLD;
    ctx.beginPath(); ctx.arc(m.x, m.top - 18, w * 0.9, 0, Math.PI * 2); ctx.fill();
    const H = m.base - m.top, spread = Math.min(460, H * 0.12);
    ctx.strokeStyle = "rgba(40,24,14,.8)";
    ctx.lineWidth = 4;
    for (let i = 0; i < 6; i++) {
      const ty = m.top + H * (0.08 + i * 0.05);
      ctx.beginPath();
      ctx.moveTo(m.x, ty); ctx.lineTo(m.x - spread + i * 22, m.base - 70);
      ctx.moveTo(m.x, ty); ctx.lineTo(m.x + spread - i * 22, m.base - 70);
      ctx.stroke();
    }
  }
  // the ratlines up to each nest
  for (const l of G.links) if (l.kind === "shrouds") {
    const [a, b] = [l.path[1], l.path[2]];
    if (!vis(Math.min(a[0], b[0]) - 60, b[1], Math.max(a[0], b[0]) + 60, a[1])) continue;
    ctx.strokeStyle = "rgba(60,36,18,.95)";
    ctx.lineWidth = 4;
    const n = Math.round(Math.abs(b[1] - a[1]) / 46);
    for (let i = 1; i < n; i++) { const k = i / n, x = lerp(a[0], b[0], k), y = lerp(a[1], b[1], k); ctx.beginPath(); ctx.moveTo(x - 34, y); ctx.lineTo(x + 34, y); ctx.stroke(); }
    ctx.lineWidth = 5;
    ctx.beginPath(); ctx.moveTo(a[0] - 30, a[1]); ctx.lineTo(b[0] - 30, b[1]); ctx.moveTo(a[0] + 30, a[1]); ctx.lineTo(b[0] + 30, b[1]); ctx.stroke();
  }
  // the stays: masthead to masthead, the foremost to the bowsprit's end, the aftmost to the taffrail
  ctx.strokeStyle = "rgba(40,24,14,.8)";
  ctx.lineWidth = 4;
  ctx.beginPath();
  for (let i = 0; i < S.masts.length; i++) {
    const a = S.masts[i], b = S.masts[i + 1];
    if (b) (ctx.moveTo(a.x, a.top + 60), ctx.lineTo(b.x, b.base - (b.base - b.top) * 0.45));
  }
  const last = S.masts[S.masts.length - 1], [bsx, bsy] = bowsprit(S);
  if (last) (ctx.moveTo(last.x, last.top + 60), ctx.lineTo(bsx, bsy), ctx.moveTo(last.x, last.base - (last.base - last.top) * 0.4), ctx.lineTo(lerp(S.bow, bsx, 0.55), lerp(railY(S, S.bow), bsy, 0.55)));
  const first = S.masts[0];
  if (first) (ctx.moveTo(first.x, first.top + 60), ctx.lineTo(S.stern + 80, railY(S, S.stern) - 40));
  ctx.stroke();
  // the far bulwarks of the open decks, over their floors
  for (const r of G.rooms) {
    if (r.ceil != null || r.kind === "nest" || !vis(r.x0, r.y - 130, r.x1, r.y)) continue;
    ctx.fillStyle = WOOD_D;
    ctx.fillRect(r.x0, r.y - 124, r.x1 - r.x0, 124);
    ctx.fillStyle = "#4a2a16";
    for (let x = r.x0 + 40; x < r.x1; x += 150) ctx.fillRect(x - 6, r.y - 124, 12, 124);
    ctx.fillStyle = WOOD_L;
    ctx.fillRect(r.x0, r.y - 130, r.x1 - r.x0, 12);
  }
  // inside the hull: the far planking between the floors, each room's wall, floors and beams
  ctx.save();
  hullPath(ctx, S);
  ctx.clip();
  const floors = [...new Set(Object.values(G.decks).filter((d) => d.kind !== "nest").map((d) => d.y))].sort((a, b) => a - b);
  const x0 = V ? Math.max(S.stern - 60, V.x0) : S.stern - 60, x1 = V ? Math.min(S.bow + 60, V.x1) : S.bow + 60;
  {
    const g = ctx.createLinearGradient(0, floors[0], 0, floors[floors.length - 1]);
    g.addColorStop(0, "#4e2a14");
    g.addColorStop(1, "#1f1008");
    ctx.fillStyle = g;
    for (let i = 0; i < floors.length - 1; i++) {
      const y0 = floors[i] + BEAM, y1 = floors[i + 1];
      if (vis(x0, y0, x1, y1)) ctx.fillRect(x0, y0, x1 - x0, y1 - y0);
    }
    ctx.strokeStyle = "rgba(12,5,2,.45)";
    ctx.lineWidth = 3;
    for (let i = 0; i < floors.length - 1; i++) for (let y = floors[i] + BEAM + 26; y < floors[i + 1]; y += 26) if (vis(x0, y, x1, y)) (ctx.beginPath(), ctx.moveTo(x0, y), ctx.lineTo(x1, y), ctx.stroke());
  }
  for (const r of G.rooms) if (r.ceil != null && vis(r.x0, r.ceil, r.x1, r.y)) roomBack(ctx, r);
  for (const gn of G.guns) if (vis(gn.x - 40, gn.y - 200, gn.x + 40, gn.y + 100)) farGun(ctx, gn.x, G.decks[gn.deck].y);
  // the masts below their decks, down through every deck to the keel
  for (const m of S.masts) {
    if (!vis(m.x - 30, m.base, m.x + 30, S.bottom)) continue;
    const mg = ctx.createLinearGradient(m.x - 24, 0, m.x + 24, 0);
    mg.addColorStop(0, "#4a2a12");
    mg.addColorStop(0.45, "#7e5230");
    mg.addColorStop(1, "#3a200e");
    ctx.fillStyle = mg;
    ctx.fillRect(m.x - 22, m.base, 44, S.bottom - m.base);
    ctx.fillStyle = "#26262c";
    for (let y = m.base + 60; y < S.bottom; y += 180) ctx.fillRect(m.x - 24, y, 48, 9);
  }
  for (const d of Object.values(G.decks)) {
    if (d.kind === "nest" || !vis(d.x0, d.y - 40, d.x1, d.y + BEAM)) continue;
    const a = V ? Math.max(d.x0, V.x0 - 40) : d.x0, b = V ? Math.min(d.x1, V.x1 + 40) : d.x1;
    planks(ctx, a, b, d.y);
    beam(ctx, a, b, d.y);
  }
  // bulkheads: a panelled wall from floor to ceiling, a doorway under a gilt lintel where there is one
  for (const w of G.walls) {
    if (!vis(w.x - 40, w.top, w.x + 40, w.y)) continue;
    const a = w.x - WALL, b = w.x + WALL, h = w.y - w.top;
    if (w.door) {
      const dh = Math.min(280, h * 0.62);
      inked(ctx, "#5a3218", () => ctx.rect(a, w.top, b - a, h - dh - 10), 4);
      ctx.fillStyle = "#1a0d06";
      ctx.fillRect(a + 4, w.y - dh - 10, b - a - 8, dh + 6);
      ctx.fillStyle = GOLD_D;
      ctx.fillRect(a - 10, w.y - dh - 22, b - a + 20, 14);
      ctx.fillStyle = "#3a1e0c";
      ctx.fillRect(a - 4, w.y - dh - 10, 8, dh + 6);
      ctx.fillRect(b - 4, w.y - dh - 10, 8, dh + 6);
    } else inked(ctx, "#5a3218", () => ctx.rect(a, w.top, b - a, h), 4);
  }
  for (const o of G.obstacles) if (o.kind === "hatch" && vis(o.x0, G.decks[o.deck].y - 60, o.x1, G.decks[o.deck].y)) hatch(ctx, o.x0, o.x1, G.decks[o.deck].y, o.z1 - o.z0);
  for (const l of G.links) {
    if (l.kind === "shrouds") continue;
    const xs = l.path.map((p) => p[0]), ys = l.path.map((p) => p[1]);
    if (!vis(Math.min(...xs) - 40, Math.min(...ys) - 120, Math.max(...xs) + 40, Math.max(...ys) + 10)) continue;
    if (l.kind === "stairs") stairs(ctx, l.path, flightZ(G, l));
    else ladder(ctx, l.path, l.a.z);
  }
  for (const p of G.props) if (vis(p.x - p.w, G.decks[p.deck].y - 480, p.x + p.w, G.decks[p.deck].y)) drawProp(ctx, G, p);
  ctx.restore();
  // what stands on the open decks above the rail line: drawn unclipped
  for (const p of G.props) {
    const d = G.decks[p.deck];
    if (d.y > 0 || !["capstan", "workbench", "table"].includes(p.kind)) continue;
    const r = G.rooms.find((q) => q.deck === p.deck && p.x >= q.x0 && p.x <= q.x1);
    if (r?.ceil == null && vis(p.x - p.w, d.y - 200, p.x + p.w, d.y)) drawProp(ctx, G, p);
  }
}

// ---------------------------------------------------------------- the front layer
function drawFront(ctx, S, G, V) {
  const vis = (x0, y0, x1, y1) => !V || (x1 >= V.x0 && x0 <= V.x1 && y1 >= V.y0 && y0 <= V.y1);
  const low = Math.max(...Object.values(G.decks).filter((d) => d.kind !== "nest").map((d) => d.y));
  ctx.save();
  hullPath(ctx, S);
  ctx.clip();
  // the bilge under the hold's floor: the hull's outside, planked, dark below the waterline
  if (vis(S.stern, low + BEAM, S.bow, S.bottom)) {
    const g = ctx.createLinearGradient(0, low, 0, S.bottom);
    g.addColorStop(0, "#4a2614");
    g.addColorStop(1, "#141018");
    ctx.fillStyle = g;
    ctx.fillRect(S.stern - 50, low + BEAM, S.len + 100, S.bottom - low);
    ctx.strokeStyle = "rgba(0,0,0,.35)";
    ctx.lineWidth = 3;
    for (let y = low + BEAM + 26; y < S.bottom; y += 26) (ctx.beginPath(), ctx.moveTo(S.stern, y), ctx.lineTo(S.bow, y), ctx.stroke());
  }
  // the sawn rim all round: planking seen in section, a gold wale along it
  ctx.lineJoin = "round";
  hullPath(ctx, S);
  ctx.lineWidth = RIM * 2 + 10;
  ctx.strokeStyle = INK;
  ctx.stroke();
  ctx.lineWidth = RIM * 2 - 6;
  ctx.strokeStyle = "#6b3f22";
  ctx.stroke();
  ctx.lineWidth = RIM * 2 - 40;
  ctx.strokeStyle = "#8a5430";
  ctx.stroke();
  ctx.lineWidth = 10;
  ctx.strokeStyle = GOLD;
  ctx.stroke();
  ctx.restore();
  ctx.strokeStyle = INK;
  ctx.lineWidth = 9;
  ctx.lineJoin = "round";
  hullPath(ctx, S);
  ctx.stroke();
  // the stern: the rudder, a quarter gallery with its lit windows, the stern lantern
  {
    const top = railY(S, S.stern), sx = S.stern;
    if (vis(sx - 200, top - 200, sx + 600, S.bottom)) {
      const rx = sx + S.len * 0.062;
      inked(ctx, "#4a2a14", () => { ctx.moveTo(rx, S.wl - 160); ctx.lineTo(rx - 90, S.wl - 100); ctx.lineTo(rx - 130, S.bottom - 30); ctx.lineTo(rx + 10, S.bottom - 20); ctx.closePath(); }, 6);
      const gy = top + 110, gh = 260;
      inked(ctx, "#5a2a14", () => { ctx.moveTo(sx - 10, gy); ctx.lineTo(sx + 190, gy); ctx.quadraticCurveTo(sx + 230, gy + gh * 0.5, sx + 180, gy + gh); ctx.lineTo(sx + 10, gy + gh); ctx.closePath(); }, 5);
      for (let i = 0; i < 2; i++) {
        const w = ctx.createLinearGradient(0, gy + 20, 0, gy + gh - 20);
        w.addColorStop(0, "#fff0b0");
        w.addColorStop(1, "#ff9a3a");
        ctx.fillStyle = w;
        ctx.fillRect(sx + 24 + i * 76, gy + 30, 56, gh - 70);
      }
      ctx.fillStyle = GOLD;
      ctx.fillRect(sx - 14, gy - 10, 216, 14);
      ctx.fillStyle = "#2a2a30";
      ctx.fillRect(sx - 16, top - 120, 30, 60);
    }
  }
  // the near rails of the open decks, with balusters (in front of the crew's feet)
  const rail = (a, b, y, h) => {
    if (!vis(a, y - h - 20, b, y + 20)) return;
    ctx.fillStyle = GOLD_D;
    ctx.fillRect(a, y - h - 12, b - a, 14);
    ctx.fillStyle = GOLD;
    ctx.fillRect(a, y - h - 12, b - a, 5);
    ctx.fillStyle = "#5a3018";
    for (let x = a + 10; x < b - 6; x += 40) {
      ctx.beginPath();
      ctx.moveTo(x, y - h);
      ctx.quadraticCurveTo(x + 9, y - h / 2, x, y);
      ctx.lineTo(x + 12, y);
      ctx.quadraticCurveTo(x + 3, y - h / 2, x + 12, y - h);
      ctx.fill();
    }
  };
  for (const r of G.rooms) if (r.ceil == null && r.kind !== "nest") rail(r.x0, r.x1, r.y + 12, 40);
  // the bow: the bowsprit and jib-boom, the head rail, the figurehead
  {
    const fy = railY(S, S.bow), bx = S.bow, [px, py] = bowsprit(S);
    if (vis(bx - 400, py - 100, px + 100, S.wl)) {
      for (const [col, w] of [[INK, 44], ["#5a3218", 34], [GOLD, 8]]) {
        ctx.strokeStyle = col;
        ctx.lineWidth = w;
        ctx.beginPath(); ctx.moveTo(bx - 260, fy + 30); ctx.lineTo(px, py); ctx.stroke();
      }
      ctx.lineWidth = 6;
      ctx.strokeStyle = GOLD_D;
      ctx.beginPath(); ctx.moveTo(bx - 40, fy + 40); ctx.quadraticCurveTo(bx + 120, fy + 80, bx + 150, fy + 190); ctx.stroke();
      inked(ctx, GOLD, () => {
        ctx.moveTo(bx - 20, fy + 60);
        ctx.quadraticCurveTo(bx + 170, fy + 120, bx + 120, fy + 260);
        ctx.quadraticCurveTo(bx + 80, fy + 330, bx - 30, fy + 310);
        ctx.quadraticCurveTo(bx + 40, fy + 180, bx - 40, fy + 80);
        ctx.closePath();
      }, 5);
    }
  }
  // the name plate on the bilge
  {
    const cx = (S.main[0] + S.main[1]) / 2, py = low + BEAM + 40, ph = Math.max(50, Math.min(90, S.bottom - py - 40)), pw = ph * 9;
    if (vis(cx - pw, py, cx + pw, py + ph) && S.bottom - py > 80) {
      ctx.fillStyle = "#2a1408";
      ctx.fillRect(cx - pw / 2, py, pw, ph);
      ctx.strokeStyle = GOLD;
      ctx.lineWidth = 6;
      ctx.strokeRect(cx - pw / 2, py, pw, ph);
      ctx.fillStyle = GOLD;
      ctx.font = `italic 800 ${Math.round(ph * 0.72)}px 'Barlow Semi Condensed', system-ui, sans-serif`;
      ctx.textAlign = "center";
      ctx.fillText("FIRSTMATE", cx, py + ph * 0.78);
    }
  }
}

// ---------------------------------------------------------------- the cache
// A layer drawn once as a whole-ship picture (for the wide shots) and in tiles at a finer grain
// as the camera comes close. A tile is TILE device pixels square; a few are made per frame (the
// whole-ship picture stands in for the rest until they are), and the oldest go when too many.
const TILE = 512;
class Layer {
  constructor(draw, S, G, box, { low = false } = {}) {
    Object.assign(this, { draw, S, G, box, low });
    this.w = box.x1 - box.x0; this.h = box.y1 - box.y0;
    const maxPx = low ? 2.5e6 : 9e6, maxSide = low ? 2048 : 4096;
    this.r0 = Math.min(maxSide / this.w, maxSide / this.h, Math.sqrt(maxPx / (this.w * this.h)));
    this.rMax = low ? 0.6 : 1.2;
    this.tiles = new Map();
    this.cap = low ? 28 : 64;
    this.made = 0;
  }
  whole() {
    if (!this.ov) {
      const c = document.createElement("canvas");
      c.width = Math.ceil(this.w * this.r0);
      c.height = Math.ceil(this.h * this.r0);
      const x = c.getContext("2d");
      x.scale(this.r0, this.r0);
      x.translate(-this.box.x0, -this.box.y0);
      this.draw(x, this.S, this.G, null);
      this.ov = c;
    }
    return this.ov;
  }
  // draw what shows of the layer; px: device pixels per ship unit; V: the view in ship space
  paint(ctx, px, V, budget) {
    const ov = this.whole(), B = this.box;
    let r = this.r0;
    while (r < px * 0.85 && r * 2 <= this.rMax * 1.001) r *= 2;
    if (r <= this.r0 * 1.01) return void ctx.drawImage(ov, B.x0, B.y0, this.w, this.h);
    const tw = TILE / r;
    const i0 = Math.max(0, Math.floor((V.x0 - B.x0) / tw)), i1 = Math.min(Math.ceil(this.w / tw) - 1, Math.floor((V.x1 - B.x0) / tw));
    const j0 = Math.max(0, Math.floor((V.y0 - B.y0) / tw)), j1 = Math.min(Math.ceil(this.h / tw) - 1, Math.floor((V.y1 - B.y0) / tw));
    for (let i = i0; i <= i1; i++) for (let j = j0; j <= j1; j++) {
      const k = r.toFixed(4) + ":" + i + ":" + j, x = B.x0 + i * tw, y = B.y0 + j * tw;
      let t = this.tiles.get(k);
      if (t) (this.tiles.delete(k), this.tiles.set(k, t));
      else if (budget.n > 0) {
        budget.n--;
        t = document.createElement("canvas");
        t.width = t.height = TILE;
        const c = t.getContext("2d");
        c.scale(r, r);
        c.translate(-x, -y);
        c.beginPath();
        c.rect(x, y, tw, tw);
        c.clip();
        this.draw(c, this.S, this.G, { x0: x - 60, y0: y - 60, x1: x + tw + 60, y1: y + tw + 60 });
        this.tiles.set(k, t);
        this.made++;
        while (this.tiles.size > this.cap) this.tiles.delete(this.tiles.keys().next().value);
      }
      if (t) ctx.drawImage(t, x, y, tw + 0.5 / r, tw + 0.5 / r);
      else {
        // (not made yet: the whole-ship picture's piece stands in)
        const sx = (x - B.x0) * this.r0, sy = (y - B.y0) * this.r0, sw = Math.min(tw * this.r0, ov.width - sx), sh = Math.min(tw * this.r0, ov.height - sy);
        if (sw > 0 && sh > 0) ctx.drawImage(ov, sx, sy, sw, sh, x, y, sw / this.r0, sh / this.r0);
      }
    }
  }
}

export class Ship {
  constructor({ low = false, cls = CLASSES[2] } = {}) {
    this.low = low;
    this.x = 0; this.y = 0; this.roll = 0; this.pitch = 0;
    this.heel = 0; this.heelV = 0;
    this.t = 0;
    this.wind = 0.5;
    this.chaser = 0;
    this.wheel = 0; this.wheelV = 0;
    this.bell = 0;
    this.damage = [];
    this.cls = cls;
    this.spec = cls;
    this.G = geometryOf(cls);
    this.from = null;
    this.k = 1; // 0..1 through a class change
    this.y = -cls.ride;
    this.recoil = Array(256).fill(0);
    this.budget = { n: 0 };
    // what the ship shows of the voyage (set by the world each frame): the stowed work in the
    // hold, the merged work's flags, a decision on the captain's desk
    this.cargo = 0; this.flags = []; this.decision = false;
    // the kraken's fight: the manned guns (their keys, row * 64 + i) trained on it, and where it is
    // (ship space); see gunAim
    this.manned = new Set(); this.aimAt = null;
    this.layers = this._layers(cls, this.G);
  }
  _layers(S, G) {
    const B = boxes(S);
    return { back: new Layer(drawBack, S, G, B.back, { low: this.low }), front: new Layer(drawFront, S, G, B.front, { low: this.low }) };
  }
  // grow (or shrink) to a class; `dur` seconds, cross-faded meanwhile
  setClass(cls, dur = 3.2) {
    if (cls === this.cls && this.k >= 1) return false;
    this.from = dur > 0 ? { spec: this.spec, G: this.G, layers: this.layers } : null;
    this.cls = cls;
    this.spec = cls;
    this.G = geometryOf(cls);
    this.layers = this._layers(cls, this.G);
    this.k = dur > 0 ? 0 : 1;
    this.dur = dur;
    return true;
  }
  get transforming() { return this.k < 1; }
  // the new ship's scale during a class change: from the old one's length to its own
  get xs() { return this.k >= 1 || !this.from ? 1 : lerp(this.from.spec.len / this.spec.len, 1, ease(this.k)); }
  gunsAt(row = 0) { return this.G.guns.filter((g) => g.row === row).map((g) => g.x); }
  get gunports() { return this.gunsAt(0); }
  get gunY() { return this.spec.gunRows[0]; }
  get ride() { return this.spec.ride; }
  get rigTop() { return rigTop(this.spec) * this.xs; }
  get rig() { return this.spec.masts; }
  levelY(id) { return levelY(this.spec, id, this.G); }
  get sections() { return sectionsOf(this.spec); }
  deckY(x) { return deckYOf(this.spec, x); }
  kick(deg) { this.heelV += deg; }
  update(dt, env) {
    this.t += dt;
    if (this.k < 1) {
      this.k = Math.min(1, this.k + dt / this.dur);
      if (this.k >= 1) this.from = null;
    }
    const half = this.spec.len / 2;
    const bow = env.waveAt(this.x + half, 1), stern = env.waveAt(this.x - half, 1);
    this.y += ((bow + stern) / 2 * 0.8 - this.spec.ride * this.xs - this.y) * Math.min(1, dt * 3);
    this.pitch += (Math.atan2(bow - stern, half * 2) * 0.5 - this.pitch) * Math.min(1, dt * 3);
    this.heelV += (-30 * this.heel - 3.2 * this.heelV) * dt;
    this.heel += this.heelV * dt;
    this.roll = this.pitch + (this.heel * Math.PI) / 180 * 0.5;
    for (let i = 0; i < this.recoil.length; i++) this.recoil[i] = Math.max(0, this.recoil[i] - dt * 3);
    this.chaser = Math.max(0, this.chaser - dt * 3);
    this.wheelV *= Math.exp(-dt * 1.5);
    this.wheel += this.wheelV * dt;
    this.bell = Math.max(0, this.bell - dt * 0.6);
    this.damage = this.damage.filter((d) => this.t - d.t < 60);
  }
  toShip(wx, wy) {
    const s = this.xs, c = Math.cos(-this.roll), sn = Math.sin(-this.roll), dx = wx - this.x, dy = wy - this.y;
    return [(dx * c - dy * sn) / s, (dx * sn + dy * c) / s];
  }
  // A manned gun in the fight is trained on the kraken. A broadside gun cannot fire through the
  // bow, but its crew train it forward with handspikes as far as its port allows, and the kraken's
  // bulk off the bow fills that arc: drawn side-on, its barrel points forward and up (or down) at
  // the monster, its elevation held to what a carriage allows (20° up, 15° down); the shot leaves
  // from its muzzle. Returns the pivot, the angle (canvas: y down) and the muzzle, in ship space.
  gunAim(gn) {
    const py = this.G.decks[gn.deck].y - 58, px = gn.x, [tx, ty] = this.aimAt || [px + 1000, py];
    const want = Math.atan2(ty - py, Math.max(1, tx - px)), ang = Math.max(-0.35, Math.min(0.26, want));
    const L = 118;
    return { pivot: [px, py], ang, want, tip: [px + Math.cos(ang) * L, py + Math.sin(ang) * L] };
  }
  // the manned guns, bow first
  mannedGuns(row = null) {
    const gs = this.G.guns.filter((g) => this.manned.has(g.row * 64 + g.i) && (row == null || g.row === row));
    return gs.sort((a, b) => b.x - a.x);
  }
  toWorld(x, y) {
    const s = this.xs, c = Math.cos(this.roll), sn = Math.sin(this.roll);
    x *= s; y *= s;
    return [this.x + x * c - y * sn, this.y + x * sn + y * c];
  }
  enter(ctx) {
    ctx.save();
    ctx.translate(this.x, this.y);
    ctx.rotate(this.roll);
    const s = this.xs;
    if (s !== 1) ctx.scale(s, s);
  }
  // the camera's view in ship space, and the device pixels per ship unit
  _view(ctx, cam) {
    const m = ctx.getTransform(), px = Math.hypot(m.a, m.b);
    if (!cam) return { px, V: null };
    const v = cam.view(), s = this.xs, c = Math.cos(-this.roll), sn = Math.sin(-this.roll);
    const xs = [], ys = [];
    for (const [wx, wy] of [[v.x0, v.y0], [v.x1, v.y0], [v.x0, v.y1], [v.x1, v.y1]]) {
      const dx = wx - this.x, dy = wy - this.y;
      xs.push((dx * c - dy * sn) / s);
      ys.push((dx * sn + dy * c) / s);
    }
    return { px, V: { x0: Math.min(...xs), x1: Math.max(...xs), y0: Math.min(...ys), y1: Math.max(...ys) } };
  }
  _paint(ctx, cam, which) {
    const { px, V } = this._view(ctx, cam);
    if (this.from) {
      // the old ship fades out, stretching to the new one's length; the new one fades in
      const e = ease(this.k), so = lerp(1, this.spec.len / this.from.spec.len, e) / this.xs;
      const O = this.from.layers[which], L = this.layers[which];
      ctx.save();
      ctx.globalAlpha = 1 - e;
      ctx.scale(so, so);
      ctx.drawImage(O.whole(), O.box.x0, O.box.y0, O.w, O.h);
      ctx.restore();
      ctx.save();
      ctx.globalAlpha = e;
      ctx.drawImage(L.whole(), L.box.x0, L.box.y0, L.w, L.h);
      ctx.restore();
      return;
    }
    this.layers[which].paint(ctx, px, V || this.layers[which].box, this.budget);
  }
  // before the crew: the rig's spars, the rooms, then the sails, the wheel, the bell, the stowed work
  drawBack(ctx, cam) {
    this.budget.n = this.low ? 2 : 3; // tiles made per frame (both layers)
    this.enter(ctx);
    this._paint(ctx, cam, "back");
    if (!this.from || this.k > 0.5) {
      ctx.save();
      if (this.from) ctx.globalAlpha = ease((this.k - 0.5) * 2);
      this._sails(ctx);
      this._wheel(ctx);
      this._bell(ctx);
      this._cargo(ctx);
      this._desk(ctx);
      ctx.restore();
    }
    ctx.restore();
  }
  drawFront(ctx, cam) {
    this.enter(ctx);
    this._paint(ctx, cam, "front");
    if (!this.from) {
      this._guns(ctx);
      this._flags(ctx);
      this._lanterns(ctx);
    }
    for (const d of this.damage) {
      const a = Math.max(0, 1 - (this.t - d.t) / 60);
      ctx.fillStyle = `rgba(20,8,4,${0.7 * a})`;
      ctx.beginPath();
      ctx.moveTo(d.x - 50, -40); ctx.lineTo(d.x - 10, -10); ctx.lineTo(d.x + 30, -44); ctx.lineTo(d.x + 44, 6); ctx.lineTo(d.x - 40, 12);
      ctx.fill();
    }
    ctx.restore();
  }
  // room plaques: each room's name on a small board under its ceiling, in the viewer's language,
  // a readable size on screen (only when the camera is close enough to read the rooms)
  drawPlaques(ctx, cam, lang) {
    if (this.from) return;
    const z = cam.zoom;
    if (z < 0.1) return;
    const key = lang === "zh-TW" ? "zh-TW" : lang === "zh-CN" ? "zh-CN" : "en";
    this.enter(ctx);
    const k = Math.min(3.4, 1 / z);
    ctx.font = `800 ${Math.round(15 * k)}px 'Barlow Semi Condensed', 'Noto Sans TC', 'Noto Sans SC', system-ui, sans-serif`;
    ctx.textBaseline = "middle";
    ctx.textAlign = "left";
    ctx.globalAlpha = Math.min(1, (z - 0.1) / 0.06) * 0.92;
    const L = this.spec.layout;
    for (const r of this.G.rooms) {
      const src = (L.rooms || []).find((q) => q.id === r.id)?.label || (r.kind === "nest" ? NEST : null);
      const text = src?.[key] || src?.en;
      if (!text) continue;
      const x = r.x0 + 70, y = (r.ceil ?? r.y - 330) + 20 + 13 * k;
      const w = ctx.measureText(text).width + 22 * k;
      ctx.fillStyle = "rgba(20,10,6,.8)";
      ctx.fillRect(x, y - 13 * k, w, 26 * k);
      ctx.fillStyle = GOLD;
      ctx.fillRect(x, y - 13 * k, 5 * k, 26 * k);
      ctx.fillStyle = "#fff4dc";
      ctx.fillText(text, x + 13 * k, y + 1);
    }
    ctx.restore();
  }
  _sails(ctx) {
    const S = this.spec, w = 0.35 + this.wind * 0.8;
    // (the mainmast: the tallest; it flies the black flag and its topsail carries the emblem)
    const mainI = S.masts.reduce((b, m, i) => (m.base - m.top > S.masts[b].base - S.masts[b].top ? i : b), 0);
    S.masts.forEach((m, mi) => {
      const f = (m.base - m.top) / 1900; // the sails' detail scales with the mast
      m.yards.forEach(([y, half], yi) => {
        const next = m.yards[yi + 1]?.[0] ?? m.base - (m.base - m.top) * 0.1;
        const h = Math.max(40, next - y - 50);
        const bel = (22 + 60 * w) * f * (1 + 0.08 * Math.sin(this.t * 2.2 + y));
        ctx.fillStyle = "#4a2a14";
        ctx.fillRect(m.x - half - 20 * f, y - 12 * f, (half + 20 * f) * 2, 18 * f);
        const g = ctx.createLinearGradient(m.x - half, 0, m.x + half, 0);
        g.addColorStop(0, "#d8c6a4");
        g.addColorStop(0.5, "#fbf1dc");
        g.addColorStop(1, "#e2cfae");
        ctx.fillStyle = g;
        ctx.beginPath();
        ctx.moveTo(m.x - half, y);
        ctx.lineTo(m.x + half, y);
        ctx.quadraticCurveTo(m.x + half + bel * 0.6, y + h * 0.55, m.x + half * 0.92, y + h);
        ctx.quadraticCurveTo(m.x, y + h + bel * 0.35, m.x - half * 0.92, y + h);
        ctx.quadraticCurveTo(m.x - half + bel * 0.3, y + h * 0.5, m.x - half, y);
        ctx.fill();
        ctx.strokeStyle = "rgba(150,110,70,.35)";
        ctx.lineWidth = 5 * Math.sqrt(f);
        for (const k of [-0.5, 0, 0.5]) (ctx.beginPath(), ctx.moveTo(m.x + k * half, y + 10), ctx.quadraticCurveTo(m.x + k * half + bel * 0.3, y + h * 0.5, m.x + k * half * 0.92, y + h - 10), ctx.stroke());
        ctx.strokeStyle = "#c8402c";
        ctx.lineWidth = 12 * Math.sqrt(f);
        ctx.beginPath();
        ctx.moveTo(m.x + half * 0.92, y + h);
        ctx.quadraticCurveTo(m.x, y + h + bel * 0.35, m.x - half * 0.92, y + h);
        ctx.stroke();
        if (mi === mainI && yi === Math.min(1, m.yards.length - 1)) {
          ctx.save();
          ctx.translate(m.x + bel * 0.12, y + h * 0.5);
          ctx.scale(f * 1.2, f * 1.2);
          ctx.fillStyle = "#1f2f5c";
          star(ctx, 0, 0, 90, 38, 8);
          ctx.fillStyle = GOLD;
          ctx.beginPath(); ctx.arc(0, 0, 30, 0, Math.PI * 2); ctx.fill();
          ctx.fillStyle = "#1f2f5c";
          ctx.font = "900 44px system-ui, sans-serif";
          ctx.textAlign = "center";
          ctx.textBaseline = "middle";
          ctx.fillText("⚓", 0, 3);
          ctx.restore();
        }
      });
      if (m.nest != null) nestTop(ctx, m);
    });
    // the jib from the foremast to the bowsprit
    const last = S.masts[S.masts.length - 1], [bx, by] = bowsprit(S);
    if (last) {
      ctx.fillStyle = "#f4ead2";
      ctx.beginPath();
      ctx.moveTo(last.x + 40, last.top + (last.base - last.top) * 0.12);
      ctx.quadraticCurveTo(lerp(last.x, bx, 0.6) + w * 80, lerp(last.top, by, 0.55), bx - 40, by + 20);
      ctx.lineTo(last.x + 80, last.base - (last.base - last.top) * 0.3);
      ctx.fill();
    }
    // the black flag at the mainmast's head
    const m = S.masts[mainI];
    if (!m) return;
    const f = (m.base - m.top) / 1900;
    const fx = m.x, fy = m.top - 30 * f;
    ctx.fillStyle = "#15151c";
    ctx.beginPath();
    ctx.moveTo(fx, fy);
    for (let i = 0; i <= 10; i++) ctx.lineTo(fx - i * 30 * f, fy + Math.sin(this.t * 7 - i * 0.7) * 10 * f * (i / 10) * (0.5 + w));
    for (let i = 10; i >= 0; i--) ctx.lineTo(fx - i * 30 * f, fy + 150 * f + Math.sin(this.t * 7 - i * 0.7) * 10 * f * (i / 10) * (0.5 + w));
    ctx.fill();
    ctx.save();
    ctx.translate(fx, fy);
    ctx.scale(f, f);
    ctx.fillStyle = "#f4ead2";
    const cx = -150, cy = 72 + Math.sin(this.t * 7 - 3.5) * 5;
    ctx.beginPath(); ctx.arc(cx, cy - 8, 30, 0, Math.PI * 2); ctx.fill();
    ctx.fillRect(cx - 18, cy + 14, 36, 18);
    ctx.fillStyle = "#15151c";
    ctx.fillRect(cx - 16, cy - 16, 12, 12);
    ctx.fillRect(cx + 4, cy - 16, 12, 12);
    ctx.strokeStyle = "#f4ead2";
    ctx.lineWidth = 9;
    ctx.beginPath(); ctx.moveTo(cx - 56, cy - 40); ctx.lineTo(cx + 56, cy + 52); ctx.moveTo(cx + 56, cy - 40); ctx.lineTo(cx - 56, cy + 52); ctx.stroke();
    ctx.restore();
  }
  wheelPos() { return [this.G.wheelX, this.spec.qd[2] - 112]; }
  _wheel(ctx) {
    ctx.save();
    ctx.translate(...this.wheelPos());
    ctx.fillStyle = "#4a2a14";
    ctx.fillRect(-12, 20, 24, 92);
    ctx.rotate(this.wheel);
    ctx.strokeStyle = "#7a4522";
    ctx.lineWidth = 12;
    ctx.beginPath(); ctx.arc(0, 0, 58, 0, Math.PI * 2); ctx.stroke();
    ctx.lineWidth = 8;
    for (let i = 0; i < 8; i++) {
      const a = (i / 8) * Math.PI * 2;
      ctx.beginPath(); ctx.moveTo(Math.cos(a) * 12, Math.sin(a) * 12); ctx.lineTo(Math.cos(a) * 82, Math.sin(a) * 82); ctx.stroke();
    }
    ctx.fillStyle = GOLD;
    ctx.beginPath(); ctx.arc(0, 0, 14, 0, Math.PI * 2); ctx.fill();
    ctx.restore();
  }
  _bell(ctx) {
    const b = this.G.props.find((p) => p.kind === "bell");
    const x = b ? b.x : this.spec.qd[1] - 40, y = b ? this.G.decks[b.deck].y : this.spec.qd[2];
    ctx.save();
    ctx.translate(x, y - 180);
    ctx.fillStyle = "#4a2a14";
    ctx.fillRect(-40, -12, 80, 12);
    ctx.fillRect(-36, 0, 10, 180);
    ctx.rotate(Math.sin(this.t * 14) * 0.5 * this.bell);
    ctx.fillStyle = GOLD;
    ctx.beginPath();
    ctx.moveTo(-10, 0); ctx.quadraticCurveTo(-26, 30, -30, 56); ctx.lineTo(30, 56); ctx.quadraticCurveTo(26, 30, 10, 0);
    ctx.fill();
    ctx.restore();
  }
  // the stowed work (ready and backlog tasks): crates stacked on the hold's casks
  _cargo(ctx) {
    const n = Math.min(24, this.cargo | 0);
    if (!n) return;
    const room = this.G.rooms.find((r) => r.kind === "cargo");
    if (!room) return;
    const y = room.y - lift(DEPTH - 104) - 92, x0 = room.x0 + 140, per = Math.max(1, Math.floor((room.x1 - room.x0 - 280) / 120));
    for (let i = 0; i < n; i++) {
      const x = x0 + (i % per) * 120, yy = y - Math.floor(i / per) * 70;
      ctx.fillStyle = i % 2 ? "#b8864a" : "#a67438";
      ctx.fillRect(x, yy - 64, 100, 64);
      ctx.strokeStyle = INK;
      ctx.lineWidth = 4;
      ctx.strokeRect(x, yy - 64, 100, 64);
      ctx.fillStyle = "#e60012";
      ctx.fillRect(x + 36, yy - 50, 28, 36);
    }
  }
  // a decision waits: the card on the captain's desk, sealed in red, under the candle's glow
  _desk(ctx) {
    if (!this.decision) return;
    const d = this.G.props.find((p) => p.kind === "desk");
    if (!d) return;
    const y = this.G.decks[d.deck].y - lift(200) - 86 - 20, x = d.x - 10;
    const g = ctx.createRadialGradient(x, y, 0, x, y, 220);
    g.addColorStop(0, `rgba(255,220,130,${0.4 + 0.1 * Math.sin(this.t * 4)})`);
    g.addColorStop(1, "rgba(255,180,80,0)");
    ctx.fillStyle = g;
    ctx.fillRect(x - 220, y - 220, 440, 440);
    ctx.save();
    ctx.translate(x, y - 20 + Math.sin(this.t * 3) * 4);
    ctx.rotate(-0.08);
    ctx.fillStyle = "#fff";
    ctx.fillRect(-46, -30, 92, 60);
    ctx.lineWidth = 5;
    ctx.strokeStyle = INK;
    ctx.strokeRect(-46, -30, 92, 60);
    ctx.fillStyle = "#e60012";
    ctx.beginPath(); ctx.arc(26, 16, 14, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = INK;
    ctx.fillRect(-34, -18, 50, 6);
    ctx.fillRect(-34, -4, 40, 6);
    ctx.restore();
  }
  // the merged work's flags: a string of signal flags from the aftmost masthead to the taffrail
  _flags(ctx) {
    const n = Math.min(16, this.flags.length);
    if (!n) return;
    const S = this.spec, m = S.masts[0];
    if (!m) return;
    const a = [m.x, m.top + 40], b = [S.stern + 60, railY(S, S.stern) - 60];
    ctx.strokeStyle = "rgba(30,20,10,.9)";
    ctx.lineWidth = 4;
    ctx.beginPath(); ctx.moveTo(...a); ctx.lineTo(...b); ctx.stroke();
    const sz = 30 + (m.base - m.top) * 0.012;
    for (let i = 0; i < n; i++) {
      const k = (i + 1) / (n + 1), x = lerp(a[0], b[0], k), y = lerp(a[1], b[1], k), sway = Math.sin(this.t * 5 + i) * 6;
      ctx.fillStyle = this.flags[i] || "#e60012";
      ctx.beginPath();
      ctx.moveTo(x, y); ctx.lineTo(x + sz * 0.9 + sway, y + sz * 0.5); ctx.lineTo(x, y + sz);
      ctx.closePath();
      ctx.fill();
      ctx.strokeStyle = INK;
      ctx.lineWidth = 3;
      ctx.stroke();
    }
  }
  _guns(ctx) {
    const G = this.G;
    for (const gn of G.guns) {
      const x = gn.x, y = G.decks[gn.deck].y, i = gn.i;
      const r = this.recoil[(gn.row * 64 + i) % this.recoil.length];
      if (this.manned.has(gn.row * 64 + i) && this.aimAt) { this._trained(ctx, gn, r); continue; }
      ctx.save();
      ctx.translate(x, y - 3);
      ctx.fillStyle = "#5a3218";
      ctx.fillRect(-44, -46, 88, 40);
      ctx.fillStyle = "#3a1e0c";
      ctx.fillRect(-44, -12, 88, 6);
      ctx.fillStyle = "#1c1016";
      for (const dx of [-30, 30]) (ctx.beginPath(), ctx.arc(dx, -8, 11, 0, Math.PI * 2), ctx.fill());
      ctx.translate(0, -75);
      const k = 1 - r * 0.25;
      ctx.fillStyle = "#26262c";
      ctx.beginPath(); ctx.arc(0, 0, 26 * k, 0, Math.PI * 2); ctx.fill();
      ctx.fillStyle = "#050505";
      ctx.beginPath(); ctx.arc(0, 0, 14 * k, 0, Math.PI * 2); ctx.fill();
      ctx.strokeStyle = "#5a5a66";
      ctx.lineWidth = 5;
      ctx.beginPath(); ctx.arc(0, 0, 26 * k, 0, Math.PI * 2); ctx.stroke();
      ctx.restore();
    }
    const [cx, cy] = this.chaserLocal();
    ctx.save();
    ctx.translate(cx - 100 - this.chaser * 30, cy);
    ctx.fillStyle = "#26262c";
    ctx.beginPath(); ctx.moveTo(-60, -20); ctx.lineTo(90, -14); ctx.lineTo(90, 14); ctx.lineTo(-60, 22); ctx.fill();
    ctx.fillStyle = "#3a3a44";
    ctx.fillRect(84, -18, 14, 36);
    ctx.fillStyle = "#5a3018";
    ctx.beginPath(); ctx.arc(-30, 30, 18, 0, Math.PI * 2); ctx.arc(40, 30, 18, 0, Math.PI * 2); ctx.fill();
    ctx.restore();
  }
  // a gun trained forward, side-on: the carriage and its trucks, the barrel on its trunnions at its
  // aim, pulled back along its axis when it fires
  _trained(ctx, gn, r) {
    const { pivot: [px, py], ang } = this.gunAim(gn), y = this.G.decks[gn.deck].y;
    ctx.save();
    ctx.translate(px, y - 3);
    ctx.fillStyle = "#5a3218";
    ctx.beginPath(); ctx.moveTo(-58, -8); ctx.lineTo(40, -8); ctx.lineTo(28, -52); ctx.lineTo(-40, -52); ctx.closePath(); ctx.fill();
    ctx.lineWidth = 4; ctx.strokeStyle = "#1c1016"; ctx.stroke();
    ctx.fillStyle = "#1c1016";
    for (const dx of [-38, 26]) (ctx.beginPath(), ctx.arc(dx, -8, 12, 0, Math.PI * 2), ctx.fill());
    ctx.translate(0, py - y + 3);
    ctx.rotate(ang);
    ctx.translate(-r * 34, 0);
    ctx.fillStyle = "#26262c";
    ctx.beginPath(); ctx.moveTo(-54, -17); ctx.lineTo(112, -12); ctx.lineTo(112, 12); ctx.lineTo(-54, 17); ctx.closePath(); ctx.fill();
    ctx.lineWidth = 4; ctx.strokeStyle = "#0c0608"; ctx.stroke();
    ctx.fillStyle = "#3a3a44";
    ctx.fillRect(104, -16, 16, 32);
    ctx.beginPath(); ctx.arc(-58, 0, 12, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = "#5a5a66";
    ctx.fillRect(-30, -17, 8, 34);
    ctx.fillRect(40, -14, 8, 28);
    ctx.restore();
  }
  _lanterns(ctx) {
    const S = this.spec, y = railY(S, S.stern) - 90;
    ctx.save();
    ctx.globalCompositeOperation = "lighter";
    for (const x of [S.stern, this.G.wheelX]) {
      const g = ctx.createRadialGradient(x, y, 0, x, y, 110);
      const f = 0.55 + 0.1 * Math.sin(this.t * 9 + x);
      g.addColorStop(0, `rgba(255,210,120,${f})`);
      g.addColorStop(1, "rgba(255,150,60,0)");
      ctx.fillStyle = g;
      ctx.fillRect(x - 110, y - 110, 220, 220);
    }
    ctx.restore();
  }
  // clip to everything but the hull (world view rectangle minus the hull, even-odd)
  clipOutHull(ctx, v) {
    ctx.beginPath();
    ctx.rect(v.x0 - 50, v.y0 - 50, v.x1 - v.x0 + 100, v.y1 - v.y0 + 100);
    const pts = this.spec.hull;
    ctx.moveTo(...this.toWorld(...pts[0]));
    for (let i = pts.length - 1; i > 0; i--) ctx.lineTo(...this.toWorld(...pts[i]));
    ctx.closePath();
    ctx.clip("evenodd");
  }
  // the sea inside the cut: a tint below the waterline and the line itself
  drawWater(ctx, env) {
    this.enter(ctx);
    hullPath(ctx, this.spec);
    ctx.clip();
    const S = this.spec, x0 = S.stern - 120, x1 = S.bow + 120, s = this.xs;
    const wy = (x) => (SEA_Y + env.waveAt(this.x + x * s, 1) * 0.6 - this.y) / s - x * Math.tan(this.roll);
    ctx.beginPath();
    ctx.moveTo(x0, wy(x0));
    for (let x = x0; x <= x1; x += 60) ctx.lineTo(x, wy(x));
    ctx.lineTo(x1, S.bottom + 60);
    ctx.lineTo(x0, S.bottom + 60);
    ctx.closePath();
    ctx.fillStyle = "rgba(22,86,190,.3)";
    ctx.fill();
    ctx.beginPath();
    for (let x = x0; x <= x1; x += 60) x === x0 ? ctx.moveTo(x, wy(x)) : ctx.lineTo(x, wy(x));
    ctx.strokeStyle = "rgba(236,246,255,.85)";
    ctx.lineWidth = 6;
    ctx.stroke();
    ctx.restore();
  }
  chaserLocal() { return [this.spec.fore[1] - 40, this.spec.fore[2] - 60]; }
  // a gun port in world space (the guns nearest the bow: the kraken is off the bow)
  portWorld(i, row = 0) {
    // (in the fight, the manned guns trained on the kraken: from their muzzles)
    const m = this.aimAt && this.mannedGuns(row % Math.max(1, this.spec.gunRows.length)).length ? this.mannedGuns(row % Math.max(1, this.spec.gunRows.length)) : this.aimAt ? this.mannedGuns() : [];
    if (m.length) return this.toWorld(...this.gunAim(m[i % m.length]).tip);
    const g = this.fwdGun(i, row);
    return this.toWorld(g?.x ?? 0, this.spec.gunRows[g?.row ?? 0] ?? 70);
  }
  fwdGun(i, row = 0) {
    const r = row % Math.max(1, this.spec.gunRows.length);
    let gs = this.G.guns.filter((g) => g.row === r);
    if (!gs.length) gs = this.G.guns.filter((g) => g.row === 0);
    const fwd = gs.slice(-Math.min(gs.length, 8));
    return fwd[i % Math.max(1, fwd.length)] || null;
  }
  // a gun fires: its muzzle recoils (row: its gun deck, i: its place in the row; fwd: counted among
  // the guns nearest the bow, as portWorld counts them)
  fire(row, i, fwd = false) {
    const m = fwd && this.aimAt ? (this.mannedGuns(row).length ? this.mannedGuns(row) : this.mannedGuns()) : [];
    const g = m.length ? m[i % m.length] : fwd ? this.fwdGun(i, row) : this.G.guns.filter((q) => q.row === row)[i];
    if (g) this.recoil[(g.row * 64 + g.i) % this.recoil.length] = 1;
  }
  chaserWorld() { const [x, y] = this.chaserLocal(); return this.toWorld(x + 100, y); }
}
const NEST = { en: "Crow's nest · review", "zh-TW": "瞭望台 · 審查", "zh-CN": "瞭望台 · 审查" };

function star(ctx, x, y, R, r, n) {
  ctx.beginPath();
  for (let i = 0; i < n * 2; i++) {
    const a = (i / (n * 2)) * Math.PI * 2 - Math.PI / 2, rr = i % 2 ? r : R;
    ctx.lineTo(x + Math.cos(a) * rr, y + Math.sin(a) * rr);
  }
  ctx.fill();
}
export { SEA_Y };
