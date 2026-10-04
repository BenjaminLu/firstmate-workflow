// Concept stills for the P5 / manga cast redesign (not the game): ?sheet=lineup | portraits
import { Puppet, loadImages } from "../src/puppet.js";
import { Overlay, ransom, FONT_JP } from "../src/overlay.js";
import BAKE from "../src/bake-data.js";
import { drawCast, CAST as VCAST } from "./vector.js";
import { CLASSES, drawShip, classCard } from "./ships.js";

const Q = new URLSearchParams(location.search);
const BOLD = await (await fetch("../bake/sprites-bold.json")).json();
await document.fonts.load("400 40px 'Dela Gothic One'");
await document.fonts.load("900 40px 'Barlow Semi Condensed'");
const now = await loadImages(BAKE);
const inkA = await loadImages(BAKE, { manga: { outline: 5 } });
const inkB = await loadImages(BOLD, { manga: { outline: 6 } });
const c = document.getElementById("c");
const ctx = c.getContext("2d");
const CAST = [
  ["captain", "Captain", "heroPose", 1.4],
  ["firstmate", "Firstmate", "heroFist", 1.4],
  ["reviewer-1", "Reviewer", "heroInspect", 1.4],
  ["sailor-hammer", "worker-1", "fire", 0.5],
  ["sailor-bandana", "worker-2", "cheer", 0.45],
  ["sailor-spyglass", "worker-3", "salute", 0.6],
  ["robot", "worker-4 (robot)", "heroFist", 1.4],
];

function p5Backdrop(x, y, w, h, t = 0) {
  ctx.save();
  ctx.beginPath();
  ctx.rect(x, y, w, h);
  ctx.clip();
  ctx.fillStyle = "#e60012";
  ctx.fillRect(x, y, w, h);
  ctx.fillStyle = "#000";
  const cx = x + w * 0.5, cy = y + h * 0.55;
  for (let i = 0; i < 18; i++) {
    const a = (i / 18) * Math.PI * 2 + t;
    ctx.beginPath();
    ctx.moveTo(cx, cy);
    ctx.lineTo(cx + Math.cos(a) * w, cy + Math.sin(a) * w);
    ctx.lineTo(cx + Math.cos(a + 0.12) * w, cy + Math.sin(a + 0.12) * w);
    ctx.fill();
  }
  // halftone
  ctx.fillStyle = "rgba(0,0,0,.35)";
  for (let yy = y; yy < y + h; yy += 12) for (let xx = x + ((yy / 12) % 2) * 6; xx < x + w; xx += 12) (ctx.beginPath(), ctx.arc(xx, yy, 2.6, 0, 7), ctx.fill());
  ctx.restore();
}
function paper(x, y, w, h) {
  ctx.fillStyle = "#e9e1cf";
  ctx.fillRect(x, y, w, h);
}
function label(text, x, y, fs = 34) {
  ransom(ctx, text, x, y, fs, 0, 1400);
}
function row(bake, images, y, h, tag) {
  const n = CAST.length, cw = c.width / n;
  CAST.forEach(([key, name, shot, t], i) => {
    const b = bake.crew[key];
    const scale = (h * 0.8) / 640;
    const p = new Puppet(key, b, images.crew[key], { props: images.props, scale });
    p.view = "q";
    p.x = cw * (i + 0.5);
    p.y = y + h - 26;
    p.shot(shot);
    for (let k = 0; k < t * 60; k++) p.update(1 / 60);
    p.draw(ctx);
    ctx.font = `800 20px 'Barlow Semi Condensed', sans-serif`;
    ctx.textAlign = "center";
    ctx.fillStyle = "#000";
    ctx.fillRect(p.x - 80, y + h - 24, 160, 22);
    ctx.fillStyle = "#fff";
    ctx.fillText(name, p.x, y + h - 7);
  });
  label(tag, 24, y + 36, 28);
}

function rowVector(y, h, tag) {
  const n = CAST.length, cw = c.width / n;
  CAST.forEach(([key, name], i) => {
    ctx.save();
    const sc = (h * 0.8) / 640;
    ctx.translate(cw * (i + 0.5), y + h - 30);
    ctx.scale(sc, sc);
    drawCast(ctx, key);
    ctx.restore();
    ctx.font = `800 20px 'Barlow Semi Condensed', sans-serif`;
    ctx.textAlign = "center";
    ctx.fillStyle = "#000";
    ctx.fillRect(cw * (i + 0.5) - 80, y + h - 24, 160, 22);
    ctx.fillStyle = "#fff";
    ctx.fillText(name, cw * (i + 0.5), y + h - 7);
  });
  label(tag, 24, y + 36, 28);
}
// ---------------------------------------------------------------- the ship grows (concept)
const INK = "#0c0608";
function burst(x, y, r, fill = "#fff", n = 14) {
  ctx.beginPath();
  for (let i = 0; i < n * 2; i++) { const a = (i / (n * 2)) * Math.PI * 2, rr = i % 2 ? r * 0.45 : r * (0.85 + ((i * 37) % 5) / 20); ctx.lineTo(x + Math.cos(a) * rr, y + Math.sin(a) * rr); }
  ctx.closePath();
  ctx.fillStyle = fill;
  ctx.fill();
  ctx.lineWidth = Math.max(3, r * 0.06);
  ctx.strokeStyle = INK;
  ctx.stroke();
}
function puff(x, y, r, col = "#e8e2ea") {
  ctx.beginPath();
  for (const [dx, dy, k] of [[-0.4, 0.1, 0.55], [0.35, 0.15, 0.5], [0, -0.3, 0.6]]) (ctx.moveTo(x + dx * r + k * r, y + dy * r), ctx.arc(x + dx * r, y + dy * r, k * r, 0, 7));
  ctx.fillStyle = col;
  ctx.fill();
  ctx.lineWidth = 4;
  ctx.strokeStyle = INK;
  ctx.stroke();
}
function sfx(text, x, y, fs, col = "#ffd23a", rot = -0.1) {
  ctx.save();
  ctx.translate(x, y);
  ctx.rotate(rot);
  ctx.font = `400 ${fs}px ${FONT_JP}`;
  ctx.textAlign = "center";
  ctx.lineJoin = "round";
  ctx.lineWidth = fs * 0.22;
  ctx.strokeStyle = INK;
  ctx.strokeText(text, 0, 0);
  ctx.fillStyle = col;
  ctx.fillText(text, 0, 0);
  ctx.restore();
}
function sea(x, y, w, h, sky = ["#3a5ad8", "#9ab8f0"]) {
  const g = ctx.createLinearGradient(0, y, 0, y + h);
  g.addColorStop(0, sky[0]);
  g.addColorStop(0.62, sky[1]);
  g.addColorStop(0.63, "#1a3a8a");
  g.addColorStop(1, "#0a1a4a");
  ctx.fillStyle = g;
  ctx.fillRect(x, y, w, h);
}
function frameTag(n, text, x, y) {
  ctx.save();
  ctx.fillStyle = INK;
  ctx.fillRect(x, y, 56, 56);
  ctx.fillStyle = "#fff";
  ctx.font = "900 34px 'Barlow Semi Condensed', sans-serif";
  ctx.textAlign = "center";
  ctx.fillText(n, x + 28, y + 40);
  ctx.restore();
  ransom(ctx, text, x + 70, y + 28, 24, 0, 700);
}
function banner3(x, y, w) {
  // the trilingual P5 banner
  ctx.save();
  ctx.translate(x, y);
  ctx.rotate(-0.05);
  ctx.fillStyle = INK;
  ctx.fillRect(0, 0, w, 120);
  ctx.fillStyle = "#e60012";
  ctx.fillRect(0, 120, w * 0.9, 8);
  ransom(ctx, "THE SHIP GROWS: FRIGATE", 18, 40, 30, 0, w - 40);
  ctx.font = `400 24px ${FONT_JP}`;
  ctx.fillStyle = "#fff";
  ctx.textAlign = "left";
  ctx.fillText("船艦升級：巡防艦 · 船舰升级：巡防舰", 20, 98);
  ctx.restore();
}
function shipAt(C, x, y, sc, o = {}) {
  ctx.save();
  ctx.translate(x, y);
  ctx.scale(sc, sc);
  drawShip(ctx, C, o);
  ctx.restore();
}
if (Q.get("sheet") === "ships") {
  c.width = 1920;
  c.height = 1100;
  ctx.fillStyle = INK;
  ctx.fillRect(0, 0, 1920, 1100);
  CLASSES.forEach((C, i) => classCard(ctx, C, (i % 2) * 965, Math.floor(i / 2) * 555, 955, 545));
} else if (Q.get("sheet") === "transform") {
  c.width = 1920;
  c.height = 1100;
  ctx.fillStyle = INK;
  ctx.fillRect(0, 0, 1920, 1100);
  const [, brig, frig] = CLASSES;
  const F = (i) => [(i % 2) * 965, Math.floor(i / 2) * 555, 955, 545];
  // 1: a new hand joins the brig (13 of 12)
  let [x, y, w, h] = F(0);
  ctx.save(); ctx.beginPath(); ctx.rect(x, y, w, h); ctx.clip();
  sea(x, y, w, h);
  shipAt(brig, x + w * 0.5, y + h * 0.7, 0.36, { crew: 12 });
  ctx.save(); ctx.translate(x + w * 0.86, y + h * 0.7 - 70); ctx.scale(0.36, 0.36); drawCast(ctx, "sailor-bandana"); ctx.restore();
  burst(x + w * 0.86, y + h * 0.36, 34, "#ffd23a", 8);
  ctx.fillStyle = INK; ctx.fillRect(x + 20, y + h - 90, 420, 56);
  ctx.fillStyle = "#fff"; ctx.font = "800 22px 'Barlow Semi Condensed'"; ctx.fillText("worker-11 joins · 13 agents · the brig holds 12", x + 36, y + h - 54);
  ctx.restore();
  frameTag(1, "A NEW HAND JOINS", x + 16, y + 16);
  // 2: the shipyard: the camera pulls back, the hull stretches, planks fly, steam
  [x, y, w, h] = F(1);
  ctx.save(); ctx.beginPath(); ctx.rect(x, y, w, h); ctx.clip();
  sea(x, y, w, h, ["#5a4a8a", "#e8b890"]);
  shipAt(frig, x + w * 0.52, y + h * 0.72, 0.3, { crew: 13, build: 0.62, sails: 0.25, scaffold: 1 });
  for (let i = 0; i < 9; i++) { ctx.save(); ctx.translate(x + w * (0.08 + i * 0.05), y + h * (0.25 + (i % 3) * 0.08)); ctx.rotate(i * 0.7); ctx.fillStyle = "#b8804a"; ctx.fillRect(-40, -8, 80, 16); ctx.lineWidth = 4; ctx.strokeStyle = INK; ctx.strokeRect(-40, -8, 80, 16); ctx.restore(); }
  for (let i = 0; i < 5; i++) puff(x + w * (0.1 + i * 0.07), y + h * (0.55 - i * 0.05), 40 + i * 6);
  sfx("トンカン!", x + w * 0.24, y + h * 0.2, 60, "#fff");
  ctx.restore();
  frameTag(2, "SHIPYARD · PULL BACK", x + 16, y + 16);
  // 3: snap: masts and sails snap in, sparkles, speed lines
  [x, y, w, h] = F(2);
  ctx.save(); ctx.beginPath(); ctx.rect(x, y, w, h); ctx.clip();
  sea(x, y, w, h, ["#e60012", "#ffb0a0"]);
  ctx.fillStyle = INK;
  for (let i = 0; i < 40; i++) { const a = (i / 40) * 6.283, cx = x + w * 0.5, cy = y + h * 0.4; ctx.beginPath(); ctx.moveTo(cx + Math.cos(a) * 200, cy + Math.sin(a) * 200); ctx.lineTo(cx + Math.cos(a - 0.02) * 900, cy + Math.sin(a - 0.02) * 900); ctx.lineTo(cx + Math.cos(a + 0.02) * 900, cy + Math.sin(a + 0.02) * 900); ctx.fill(); }
  shipAt(frig, x + w * 0.5, y + h * 0.72, 0.32, { crew: 13, sails: 0.8 });
  for (let i = 0; i < 7; i++) burst(x + w * (0.2 + i * 0.1), y + h * (0.22 + (i % 2) * 0.12), 22, "#fff", 4);
  sfx("ガシャン!", x + w * 0.5, y + h * 0.16, 76, "#ffd23a", 0.06);
  ctx.restore();
  frameTag(3, "SNAP! MASTS AND SAILS", x + 16, y + 16);
  // 4: the frigate, the banner in three languages
  [x, y, w, h] = F(3);
  ctx.save(); ctx.beginPath(); ctx.rect(x, y, w, h); ctx.clip();
  sea(x, y, w, h);
  shipAt(frig, x + w * 0.5, y + h * 0.74, 0.3, { crew: 13 });
  banner3(x + 40, y + 70, w - 80);
  ctx.restore();
  frameTag(4, "THE SHIP GROWS", x + 16, y + 16);
} else if (Q.get("sheet") === "specials") {
  // the same special (the broadside) at each class, escalating
  c.width = 1920;
  c.height = 1100;
  ctx.fillStyle = INK;
  ctx.fillRect(0, 0, 1920, 1100);
  const F = (i) => [(i % 2) * 965, Math.floor(i / 2) * 555, 955, 545];
  const portraitStrip = (x, y, w, h, keys) => {
    const n = keys.length, pw = w / n;
    keys.forEach((k, i) => {
      ctx.save();
      ctx.beginPath();
      ctx.moveTo(x + i * pw + 20, y); ctx.lineTo(x + (i + 1) * pw + 20, y); ctx.lineTo(x + (i + 1) * pw - 20, y + h); ctx.lineTo(x + i * pw - 20, y + h); ctx.closePath();
      ctx.fillStyle = i % 2 ? "#e60012" : "#fff"; ctx.fill(); ctx.lineWidth = 8; ctx.strokeStyle = INK; ctx.stroke(); ctx.clip();
      ctx.translate(x + (i + 0.5) * pw, y + h * 1.9);
      ctx.scale(h / 280, h / 280);
      drawCast(ctx, k);
      ctx.restore();
    });
  };
  CLASSES.forEach((C, i) => {
    const [x, y, w, h] = F(i);
    ctx.save(); ctx.beginPath(); ctx.rect(x, y, w, h); ctx.clip();
    const big = i;
    sea(x, y, w, h, big === 3 ? ["#5a0010", "#e05050"] : big === 2 ? ["#2a3a8a", "#e8a070"] : ["#3a5ad8", "#9ab8f0"]);
    const sc = [0.42, 0.34, 0.28, 0.24][i], sx = x + w * (0.42 - i * 0.02), sy = y + h * 0.78;
    shipAt(C, sx, sy, sc);
    // muzzle flashes: one gun, two, the whole deck, every deck in waves
    const L = C.len * sc, top = (150 + C.decks * 70) * sc;
    const rows = [1, 1, 1, 3][i], per = [1, 2, 7, 9][i];
    for (let r = 0; r < rows; r++) for (let g = 0; g < per; g++) {
      const gx = sx - L * 0.4 + (per === 1 ? L * 0.6 : (g / (per - 1)) * L * 0.78), gy = sy - top + (60 + r * 70) * sc;
      burst(gx + 40, gy, [30, 38, 44, 50][i] * (1 - r * 0.15), r === 0 ? "#fff27a" : "#ffb040", 8);
      puff(gx + 90, gy - 10, [26, 34, 40, 46][i]);
    }
    // the impact on the kraken side, escalating
    const ix = x + w * 0.88, iy = y + h * 0.42;
    if (i >= 1) for (let k = 0; k < i + 1; k++) { ctx.beginPath(); ctx.ellipse(ix, iy, 60 + k * 70 + i * 30, (60 + k * 70 + i * 30) * 0.8, 0, 0, 7); ctx.lineWidth = 16 - k * 3; ctx.strokeStyle = INK; ctx.stroke(); ctx.lineWidth = 8 - k; ctx.strokeStyle = "#fff"; ctx.stroke(); }
    burst(ix, iy, [60, 100, 150, 240][i], i === 3 ? "#fff" : "#ffd23a", 12 + i * 3);
    if (i >= 2) { // sea-splitting column
      ctx.fillStyle = "#eaf6ff"; ctx.beginPath(); ctx.moveTo(ix - 120, y + h); ctx.lineTo(ix - 40, iy + 40); ctx.lineTo(ix + 40, iy + 40); ctx.lineTo(ix + 120, y + h); ctx.fill(); ctx.lineWidth = 8; ctx.strokeStyle = INK; ctx.stroke();
    }
    sfx(["ドン", "ドドン!", "ドドドド!!", "ドォォォン!!!"][i], ix - 30, iy - [60, 90, 130, 170][i], [44, 60, 76, 96][i]);
    // the cut-in: a strip, a bigger strip, three panels, the whole crew montage
    if (i === 0) portraitStrip(x + 30, y + 90, 260, 110, ["captain"]);
    if (i === 1) portraitStrip(x + 30, y + 90, 420, 130, ["captain", "firstmate"]);
    if (i === 2) portraitStrip(x + 30, y + 80, 620, 150, ["captain", "firstmate", "reviewer-1"]);
    if (i === 3) {
      ctx.fillStyle = "#000"; ctx.fillRect(x, y, w, 60); ctx.fillRect(x, y + h - 60, w, 60); // the letterbox: slow-mo, camera push
      portraitStrip(x + 20, y + 70, w - 40, 150, ["captain", "firstmate", "reviewer-1", "sailor-hammer", "sailor-bandana", "sailor-spyglass", "robot"]);
    }
    ctx.restore();
    frameTag(i + 1, `${C.en} · ${["ONE GUN, SMALL CUT-IN", "TWIN BROADSIDE, BIGGER SHOCKWAVE", "FULL BARRAGE, 3-PANEL CUT-IN, SEA SPLITS", "EVERY DECK IN WAVES, CREW MONTAGE, SLOW-MO"][i]}`, x + 16, y + h - 76 - (i === 3 ? 0 : -50));
  });
} else if (Q.get("sheet") === "mock") {
  // a game frame with the vector cast composited where the crew stand
  const bg = new Image();
  bg.src = `./${Q.get("bg")}.png`;
  await bg.decode();
  const J = await (await fetch(`./${Q.get("bg")}.json`)).json();
  const pos = J.pos || J;
  c.width = bg.width;
  c.height = bg.height;
  ctx.drawImage(bg, 0, 0);
  const k = J.vw ? bg.width / J.vw : 1; // device pixels per CSS pixel
  ctx.scale(k, k);
  pos.sort((a, b) => a.y - b.y);
  for (const p of pos) {
    const key = p.key === "robot" ? "robot" : p.key;
    if (!VCAST[key]) continue;
    ctx.save();
    ctx.translate(p.x, p.y + 2);
    const sc = p.h / 600;
    ctx.scale(sc * (p.dir < 0 ? -1 : 1), sc);
    drawCast(ctx, key);
    ctx.restore();
  }
} else if (Q.get("sheet") === "vector") {
  c.width = 1920;
  c.height = 640;
  p5Backdrop(0, 0, 1920, 640, 0.25);
  rowVector(0, 640, "C · HAND-DRAWN VECTOR, 浮誇");
} else if (Q.get("sheet") === "compare") {
  c.width = 1920;
  c.height = 980;
  paper(0, 0, 1920, 480);
  row(BAKE, now, 0, 480, "NOW · SOFT 3D BAKE");
  p5Backdrop(0, 490, 1920, 490, 0.25);
  rowVector(490, 490, "C · HAND-DRAWN VECTOR, 浮誇");
} else if (Q.get("sheet") !== "portraits") {
  c.width = 1920;
  c.height = 1500;
  const h = 480;
  paper(0, 0, 1920, h);
  row(BAKE, now, 0, h, "NOW · SOFT 3D BAKE");
  p5Backdrop(0, h + 10, 1920, h, 0.1);
  row(BAKE, inkA, h + 10, h, "A · INKED CEL, SAME BUILD");
  p5Backdrop(0, 2 * h + 20, 1920, h, 0.4);
  row(BOLD, inkB, 2 * h + 20, h, "B · 浮誇 BOLD PROPORTIONS");
} else {
  // three hero portraits in the P5 cut-in frame, the bold inked cast
  const W = 1600, H = 900;
  c.width = W;
  c.height = H * 3 + 20;
  const ov = new Overlay();
  ov.style = "p5";
  ov.t = 0.5;
  [["captain", "海賊船長", "THE CAPTAIN", ["#1f2f5c", "#ffd23a"]], ["firstmate", "一等航海士", "THE FIRSTMATE", ["#1f2f5c", "#9ad8ff"]], ["reviewer-1", "審査官", "THE REVIEWER", ["#0c3a2a", "#7af0b0"]]].forEach(([key, jp, en], i) => {
    ctx.save();
    ctx.translate(0, i * (H + 10));
    ctx.beginPath();
    ctx.rect(0, 0, W, H);
    ctx.clip();
    ctx.fillStyle = "#1a0a10";
    ctx.fillRect(0, 0, W, H);
    const portrait = (x, w, h, sil) => {
      // the vector character, big: the head and chest fill the panel
      const sc = (h * 2.3) / 640;
      x.save();
      x.translate(0, h * (key === "firstmate" ? 1.8 : 1.55));
      x.scale(sc, sc);
      if (sil) x.filter = "brightness(0)";
      drawCast(x, key);
      x.restore();
      x.filter = "none";
    };
    ov._cutP5(ctx, W, H, { jp, en, portrait, from: i % 2 ? -1 : 1, dur: 99, t: 0.6, y: 0.5 });
    ctx.restore();
  });
}
window.__ok = true;
