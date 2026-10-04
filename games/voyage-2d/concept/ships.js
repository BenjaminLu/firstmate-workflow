// The ship grows with the crew (concept): four classes in the style bible's inked look, and
// the transform storyboard. Every agent keeps a spot on a deck; classes step at 7/12/18/24.
import { drawCast } from "./vector.js";
import { ransom, FONT_JP } from "../src/overlay.js";

const INK = "#0c0608";
export const CLASSES = [
  { id: "sloop", n: 7, len: 900, masts: [0.1], decks: 1, guns: 3, en: "SLOOP", tw: "單桅帆船", cn: "单桅帆船" },
  { id: "brig", n: 12, len: 1250, masts: [-0.2, 0.25], decks: 1, guns: 5, en: "BRIG", tw: "雙桅橫帆船", cn: "双桅横帆船" },
  { id: "frigate", n: 18, len: 1650, masts: [-0.3, 0.02, 0.32], decks: 2, guns: 7, en: "FRIGATE", tw: "巡防艦", cn: "巡防舰" },
  { id: "line", n: 24, len: 2050, masts: [-0.34, -0.02, 0.3], decks: 3, guns: 9, tall: 1.25, en: "SHIP OF THE LINE", tw: "戰列艦", cn: "战列舰" },
];
const KEYS = ["captain", "firstmate", "reviewer-1", "sailor-hammer", "sailor-bandana", "sailor-spyglass", "robot"];

function ink(ctx, path, fill, w = 6) {
  path();
  ctx.fillStyle = fill;
  ctx.fill();
  ctx.lineWidth = w;
  ctx.strokeStyle = INK;
  ctx.lineJoin = "round";
  ctx.stroke();
}

// draw a class at the origin (waterline centre); k in 0..1 builds it in (masts, sails, planks)
export function drawShip(ctx, C, { crew = C.n, build = 1, sails = 1, scaffold = 0 } = {}) {
  const L = C.len, hh = 150 + C.decks * 70, top = -hh;
  const tall = C.tall || 1;
  // masts and sails (behind the hull)
  C.masts.forEach((m, i) => {
    const x = m * L, H = (720 + (i === 1 ? 160 : 0)) * tall * (C.id === "sloop" ? 0.9 : 1);
    const k = Math.min(1, Math.max(0, sails * 1.3 - i * 0.15));
    if (k <= 0) return;
    ink(ctx, () => { ctx.beginPath(); ctx.rect(x - 14, top - H * k, 28, H * k); }, "#6b3f22", 5);
    const rows = C.id === "sloop" ? 2 : 3;
    for (let r = 0; r < rows; r++) {
      const y0 = top - H * k + 60 + r * (H * 0.28), w = (170 - r * 18) * (C.id === "line" ? 1.2 : 1) * k, h = H * 0.24 * k;
      ink(ctx, () => {
        ctx.beginPath();
        ctx.moveTo(x - w, y0);
        ctx.lineTo(x + w, y0);
        ctx.quadraticCurveTo(x + w + 40, y0 + h * 0.5, x + w * 0.9, y0 + h);
        ctx.lineTo(x - w * 0.9, y0 + h);
        ctx.quadraticCurveTo(x - w + 20, y0 + h * 0.5, x - w, y0);
      }, r === 1 && i === Math.floor(C.masts.length / 2) ? "#e60012" : "#fbf1dc", 6);
      ctx.fillStyle = INK;
      ctx.fillRect(x - w - 14, y0 - 8, w * 2 + 28, 12);
    }
    // the flag on the main mast
    if (i === Math.floor(C.masts.length / 2)) ink(ctx, () => { ctx.beginPath(); ctx.moveTo(x, top - H * k); ctx.lineTo(x - 130, top - H * k + 30); ctx.lineTo(x, top - H * k + 70); }, INK, 4);
  });
  // the hull: grows by length and decks; unbuilt planks are scaffolding
  const hull = () => {
    ctx.beginPath();
    ctx.moveTo(-L / 2 - 40, top);
    ctx.lineTo(L / 2 - 60, top);
    ctx.quadraticCurveTo(L / 2 + 90, top - 40, L / 2 + 120, top - 70);
    ctx.quadraticCurveTo(L / 2 + 40, 60, L / 2 - 120, 150);
    ctx.lineTo(-L / 2 + 80, 150);
    ctx.quadraticCurveTo(-L / 2 - 60, 100, -L / 2 - 40, top);
    ctx.closePath();
  };
  ink(ctx, hull, "#5c321a", 8);
  ctx.save();
  hull();
  ctx.clip();
  ctx.fillStyle = "#3a1e10";
  ctx.fillRect(-L, 30, L * 2, 200); // the dark wale
  ctx.fillStyle = "rgba(0,0,0,.35)"; // the hard shadow under the rail
  ctx.fillRect(-L, top, L * 2, 26);
  for (let d = 0; d < C.decks; d++) {
    const y = top + 60 + d * 70;
    ctx.fillStyle = "#f2c040";
    ctx.fillRect(-L, y - 34, L * 2, 8);
    const n = C.guns;
    for (let g = 0; g < n; g++) {
      const x = -L * 0.4 + (g / (n - 1)) * L * 0.78;
      ink(ctx, () => { ctx.beginPath(); ctx.rect(x - 22, y - 18, 44, 36); }, "#140a08", 4);
    }
  }
  if (build < 1) {
    // the unbuilt stern end: bare ribs, the planks still to snap in
    const x0 = -L / 2 - 60 + L * build;
    ctx.fillStyle = "rgba(20,10,6,.85)";
    ctx.fillRect(x0, top - 10, L, 400);
    ctx.strokeStyle = "#c98d52";
    ctx.lineWidth = 12;
    for (let x = x0 + 20; x < L; x += 70) (ctx.beginPath(), ctx.moveTo(x, top), ctx.quadraticCurveTo(x + 20, 60, x - 10, 160), ctx.stroke());
  }
  ctx.restore();
  // the rail and the name
  ctx.fillStyle = "#f2c040";
  ctx.fillRect(-L / 2 - 40, top - 16, L - 20, 12);
  ctx.fillStyle = INK;
  ctx.fillRect(-L / 2 - 40, top - 4, L - 20, 4);
  if (scaffold > 0) {
    // shipyard scaffolding at the growing end
    ctx.save();
    ctx.globalAlpha = scaffold;
    ctx.strokeStyle = "#8a6a3a";
    ctx.lineWidth = 10;
    const sx = -L / 2 - 180;
    for (let i = 0; i < 4; i++) (ctx.beginPath(), ctx.moveTo(sx + i * 60, 150), ctx.lineTo(sx + i * 60, top - 260), ctx.stroke());
    for (let j = 0; j < 5; j++) (ctx.beginPath(), ctx.moveTo(sx - 20, 120 - j * 90), ctx.lineTo(sx + 200, 120 - j * 90), ctx.stroke());
    ctx.restore();
  }
  // the crew: every agent a spot along the decks (the top deck, then the raised decks)
  const slots = Math.max(1, crew);
  for (let i = 0; i < slots; i++) {
    const row = i % 2, x = -L * 0.44 + ((i + 0.5) / slots) * L * 0.86, y = top - 6 - row * 0;
    ctx.save();
    ctx.translate(x, y - (row ? 0 : 0));
    const s = 0.34 * (i === 0 ? 1.15 : 1);
    ctx.scale(i % 3 === 1 ? -s : s, s);
    drawCast(ctx, i === 0 ? "captain" : i === 1 ? "firstmate" : i === 2 ? "reviewer-1" : KEYS[3 + (i % 4)]);
    ctx.restore();
  }
}

// a class card: the ship, its crew count and the trilingual class name
export function classCard(ctx, C, x, y, w, h) {
  ctx.save();
  ctx.beginPath();
  ctx.rect(x, y, w, h);
  ctx.clip();
  const g = ctx.createLinearGradient(0, y, 0, y + h);
  g.addColorStop(0, "#3a5ad8");
  g.addColorStop(0.62, "#9ab8f0");
  g.addColorStop(0.63, "#1a3a8a");
  g.addColorStop(1, "#0a1a4a");
  ctx.fillStyle = g;
  ctx.fillRect(x, y, w, h);
  const sc = Math.min((w * 0.82) / (C.len + 400), (h * 0.62) / 1250);
  ctx.translate(x + w * 0.52, y + h * 0.66);
  ctx.scale(sc, sc);
  drawShip(ctx, C);
  ctx.restore();
  ctx.save();
  ransom(ctx, C.en, x + 18, y + 38, 30, 0, w * 0.7);
  ctx.font = `400 22px ${FONT_JP}`;
  ctx.fillStyle = "#fff";
  ctx.strokeStyle = INK;
  ctx.lineWidth = 6;
  ctx.textAlign = "left";
  const t = `${C.tw} · ${C.cn}`;
  ctx.strokeText(t, x + 20, y + 86);
  ctx.fillText(t, x + 20, y + 86);
  // the crew count badge
  ctx.translate(x + w - 110, y + 20);
  ctx.rotate(0.06);
  ctx.fillStyle = "#e60012";
  ctx.fillRect(0, 0, 92, 70);
  ctx.strokeStyle = INK;
  ctx.lineWidth = 6;
  ctx.strokeRect(0, 0, 92, 70);
  ctx.fillStyle = "#fff";
  ctx.font = `900 40px 'Barlow Semi Condensed', sans-serif`;
  ctx.textAlign = "center";
  ctx.fillText(`≤${C.n}`, 46, 44);
  ctx.font = `800 14px 'Barlow Semi Condensed', sans-serif`;
  ctx.fillText("AGENTS", 46, 62);
  ctx.restore();
}
