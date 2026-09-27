// Screen-space layers over the stage, in one of two looks (the captain chooses):
//   "manga": shōnen battle manga. Inked panel cut-ins on screentone with speed-line
//            fields and a huge brush-heavy kanji move name (English beneath), black and
//            white impact frames, hand-lettered prompts.
//   "p5":    a stylish red-black-white graphic look. Cut-ins on red with a turning
//            starburst and the character's silhouette behind them, ransom-note lettering
//            on tilted torn panels, an all-out-attack silhouette frame on the finisher.
// Both share the one tap prompt (an approach ring that closes on the moment to tap),
// the grip / hull / gauge bars, the combo, the letterbox and the ending's title card.
const TAU = Math.PI * 2;
const ease = (k) => 1 - (1 - k) ** 3;
export const FONT = "'Barlow Semi Condensed', 'Arial Narrow', system-ui, sans-serif";
export const FONT_JP = "'Dela Gothic One', 'Hiragino Sans', 'Yu Gothic', 'Noto Sans JP', sans-serif";

let TONE = null;
// a screentone pattern (black dots on transparent), and a red one for the P5 look
function tones(ctx) {
  if (TONE) return TONE;
  const mk = (col, r, step) => {
    const c = document.createElement("canvas");
    c.width = c.height = step;
    const x = c.getContext("2d");
    x.fillStyle = col;
    x.beginPath();
    x.arc(step / 2, step / 2, r, 0, TAU);
    x.fill();
    return ctx.createPattern(c, "repeat");
  };
  TONE = { dot: mk("rgba(0,0,0,.55)", 2.2, 9), dotW: mk("rgba(255,255,255,.35)", 2, 8), dotR: mk("rgba(0,0,0,.4)", 3.2, 12) };
  return TONE;
}
// a deterministic jitter (torn edges, ransom letters)
const jit = (i, k = 1) => (Math.sin(i * 127.1 + k * 311.7) * 43758.5453) % 1;

export class Overlay {
  constructor() {
    this.style = "manga";
    this.cuts = [];
    this.title = null;
    this.t = 0;
    this.dim = 0; this.dimTarget = 0;
    this.bars = 0; this.barsTarget = 0;
    this.speed = 0;
    this.speedCol = "255,255,255";
    this.allOut = null; // the P5 finisher frame
  }
  // { jp, en, portrait: (ctx, w, h, silhouette) => void, col: [dark, light], from, dur }
  cutin(c) { this.cuts.push({ dur: 1.25, from: 1, ...c, t: 0 }); }
  card(c) { this.title = { ...c, t: 0 }; }
  update(dt) {
    this.t += dt;
    for (const c of this.cuts) c.t += dt;
    this.cuts = this.cuts.filter((c) => c.t < c.dur);
    if (this.title) this.title.t += dt;
    if (this.allOut) (this.allOut.t += dt), this.allOut.t > this.allOut.dur && (this.allOut = null);
    const want = Math.max(this.dimTarget, this.cuts.length ? 0.6 : 0);
    this.dim += (want - this.dim) * Math.min(1, dt * 12);
    this.bars += (this.barsTarget - this.bars) * Math.min(1, dt * 5);
    this.speed = Math.max(0, this.speed - dt * 1.5);
  }
  get busy() { return this.cuts.length > 0 || !!this.allOut; }
  draw(ctx, W, H) {
    const T = tones(ctx);
    if (this.dim > 0.01) {
      ctx.fillStyle = this.style === "p5" ? `rgba(40,0,0,${this.dim})` : `rgba(6,4,14,${this.dim})`;
      ctx.fillRect(0, 0, W, H);
      if (!this.low) {
        ctx.globalAlpha = this.dim;
        ctx.fillStyle = this.style === "p5" ? T.dotR : T.dot;
        ctx.fillRect(0, 0, W, H);
        ctx.globalAlpha = 1;
      }
    }
    if (this.speed > 0.01) speedLines(ctx, W / 2, H / 2, Math.max(W, H), this.speed * (this.low ? 0.6 : 1), this.style === "p5" ? "0,0,0" : this.speedCol, this.t);
    for (const c of this.cuts) this.style === "p5" ? this._cutP5(ctx, W, H, c) : this._cutManga(ctx, W, H, c);
    if (this.allOut) this._allOut(ctx, W, H, this.allOut);
    if (this.bars > 0.01) {
      const b = H * 0.11 * this.bars;
      ctx.fillStyle = "#000";
      ctx.fillRect(0, 0, W, b);
      ctx.fillRect(0, H - b, W, b);
      if (this.style === "p5") (ctx.fillStyle = "#e60012"), ctx.fillRect(0, b - 6, W, 6), ctx.fillRect(0, H - b, W, 6);
    }
    if (this.title) this.style === "p5" ? this._titleP5(ctx, W, H, this.title) : this._titleManga(ctx, W, H, this.title);
  }
  // ---------------------------------------------------------------- manga cut-in
  _cutManga(ctx, W, H, c) {
    const T = tones(ctx);
    const k = c.t / c.dur;
    const inK = ease(Math.min(1, c.t / 0.12)), outK = c.t > c.dur - 0.16 ? ease((c.t - (c.dur - 0.16)) / 0.16) : 0;
    const bandH = Math.min(H * 0.5, W * 0.4) * (c.scale || 1), cy = H * (c.y ?? 0.45), sk = bandH * 0.3;
    const slide = ((1 - inK) - outK) * W * 1.2 * c.from;
    const [dark, light] = c.col || ["#1f2f5c", "#f2c75a"];
    ctx.save();
    ctx.translate(slide, 0);
    const panel = () => {
      ctx.beginPath();
      ctx.moveTo(-60, cy - bandH / 2 + sk);
      ctx.lineTo(W + 60, cy - bandH / 2 - sk);
      ctx.lineTo(W + 60, cy + bandH / 2 - sk);
      ctx.lineTo(-60, cy + bandH / 2 + sk);
      ctx.closePath();
    };
    ctx.save();
    panel();
    ctx.clip();
    // two flat tones, screentone over the dark one, a focus-line field toward the portrait
    ctx.fillStyle = light;
    ctx.fillRect(-60, cy - bandH, W + 120, bandH * 2);
    ctx.fillStyle = dark;
    ctx.beginPath();
    ctx.moveTo(W * 0.42, cy - bandH);
    ctx.lineTo(W + 60, cy - bandH);
    ctx.lineTo(W + 60, cy + bandH);
    ctx.lineTo(W * 0.3, cy + bandH);
    ctx.fill();
    if (!this.low) (ctx.fillStyle = T.dot), ctx.fillRect(-60, cy - bandH, W + 120, bandH * 2);
    const fx = c.from > 0 ? W * 0.24 : W * 0.76;
    speedLines(ctx, fx, cy, W, 1, "0,0,0", this.t, bandH * 0.42, this.low ? 32 : 90);
    // parallel speed lines racing through
    ctx.fillStyle = "rgba(255,255,255,.55)";
    for (let i = 0; i < (this.low ? 10 : 26); i++) {
      const y = cy - bandH / 2 - sk + ((i * 53) % 100) / 100 * (bandH + sk * 2);
      const x = ((((i * 197 + this.t * 3600 * (i % 2 ? 1 : 1.7)) % (W + 600)) + W + 600) % (W + 600)) - 300;
      ctx.fillRect(W - x, y, 200 + (i % 5) * 90, 3 + (i % 3) * 2);
    }
    const wide = c.panels && c.panels.length > 3;
    if (c.panels) panelRow(ctx, c.panels, wide ? -40 : c.from > 0 ? 20 : W * 0.5, wide ? W + 40 : c.from > 0 ? W * 0.48 : W - 20, cy - bandH / 2 - sk * 0.6, cy + bandH / 2 + sk * 0.6, "ink", k);
    else if (c.portrait) {
      ctx.save();
      ctx.translate(fx, cy);
      ctx.scale(1 + k * 0.08, 1 + k * 0.08);
      c.portrait(ctx, bandH * 2.1, bandH, false, "ink");
      ctx.restore();
    }
    ctx.restore();
    // the panel border: thick black ink, a white inner line
    for (const [col, w] of [["#000", 16], ["#fff", 5]]) {
      ctx.strokeStyle = col;
      ctx.lineWidth = w;
      panel();
      ctx.stroke();
    }
    // the move name: huge kanji, white fill, black ink outline, the English beneath
    const tx = wide ? W * 0.3 : c.from > 0 ? W * 0.5 : W * 0.05;
    const fs = Math.min(bandH * 0.5, (W * 0.46) / Math.max(2, [...c.jp].length));
    if (wide) titleSlab(ctx, tx - fs * 0.3, cy - fs * 0.85, fs * [...c.jp].length + fs * 0.6, fs * 1.75, "#000");
    ctx.textAlign = "left";
    ctx.textBaseline = "middle";
    ctx.lineJoin = "round";
    const j = c.t < 0.25 ? (jit(Math.floor(this.t * 30)) - 0.5) * 10 : 0;
    ctx.font = `400 ${fs}px ${FONT_JP}`;
    ctx.lineWidth = fs * 0.2;
    ctx.strokeStyle = "#000";
    ctx.strokeText(c.jp, tx + j, cy - fs * 0.2);
    ctx.fillStyle = "#fff";
    ctx.fillText(c.jp, tx + j, cy - fs * 0.2);
    ctx.fillStyle = light;
    ctx.save();
    ctx.globalCompositeOperation = "source-atop";
    ctx.restore();
    const es = fs * 0.34;
    ctx.font = `italic 900 ${es}px ${FONT}`;
    ctx.lineWidth = es * 0.22;
    ctx.strokeText(c.en, tx + fs * 0.06, cy + fs * 0.55);
    ctx.fillStyle = light;
    ctx.fillText(c.en, tx + fs * 0.06, cy + fs * 0.55);
    ctx.restore();
  }
  // ---------------------------------------------------------------- P5-style cut-in
  _cutP5(ctx, W, H, c) {
    const T = tones(ctx);
    const k = c.t / c.dur;
    const inK = ease(Math.min(1, c.t / 0.1)), outK = c.t > c.dur - 0.14 ? ease((c.t - (c.dur - 0.14)) / 0.14) : 0;
    const bandH = Math.min(H * 0.56, W * 0.44) * (c.scale || 1), cy = H * (c.y ?? 0.45);
    const slide = ((1 - inK) - outK) * W * 1.3 * c.from;
    ctx.save();
    ctx.translate(slide, 0);
    // a tilted torn panel
    const tilt = -0.12 * c.from;
    ctx.translate(W / 2, cy);
    ctx.rotate(tilt);
    const pw = W * 1.3, ph = bandH;
    const torn = (inset) => {
      ctx.beginPath();
      const n = 18;
      for (let i = 0; i <= n; i++) ctx.lineTo(-pw / 2 + (pw * i) / n, -ph / 2 + inset + jit(i, 1) * 26);
      for (let i = n; i >= 0; i--) ctx.lineTo(-pw / 2 + (pw * i) / n, ph / 2 - inset - jit(i, 2) * 26);
      ctx.closePath();
    };
    ctx.fillStyle = "#fff";
    torn(-14);
    ctx.fill();
    ctx.save();
    torn(0);
    ctx.clip();
    ctx.fillStyle = "#e60012";
    ctx.fillRect(-pw, -ph, pw * 2, ph * 2);
    // the turning starburst
    ctx.fillStyle = "#000";
    const px = c.from > 0 ? -W * 0.26 : W * 0.26;
    for (let i = 0; i < 16; i++) {
      const a = (i / 16) * TAU + this.t * 0.8;
      ctx.beginPath();
      ctx.moveTo(px, 0);
      ctx.lineTo(px + Math.cos(a) * W, Math.sin(a) * W);
      ctx.lineTo(px + Math.cos(a + 0.12) * W, Math.sin(a + 0.12) * W);
      ctx.fill();
    }
    if (!this.low) (ctx.fillStyle = T.dotR), ctx.fillRect(-pw, -ph, pw * 2, ph * 2);
    const wide = c.panels && c.panels.length > 3;
    if (c.panels) panelRow(ctx, c.panels, wide ? -W * 0.55 : c.from > 0 ? -W * 0.49 : W * 0.02, wide ? W * 0.55 : c.from > 0 ? -W * 0.03 : W * 0.49, -ph / 2, ph / 2, "p5", k);
    else if (c.portrait) {
      ctx.save();
      ctx.translate(px, 0);
      ctx.scale(1.02 + k * 0.1, 1.02 + k * 0.1);
      ctx.translate(26, 10); // the black silhouette, offset behind
      c.portrait(ctx, bandH * 2.1, bandH, true, "p5");
      ctx.translate(-26, -10);
      c.portrait(ctx, bandH * 2.1, bandH, false, "p5");
      ctx.restore();
    }
    ctx.restore();
    ctx.strokeStyle = "#000";
    ctx.lineWidth = 10;
    torn(0);
    ctx.stroke();
    // ransom-note lettering
    const tx = wide ? -W * 0.22 : c.from > 0 ? -W * 0.02 : -W * 0.46;
    // the montage keeps its faces: the title sits low on a slab across the panels' chests
    const ty = wide ? ph * 0.42 : 0;
    if (wide) titleSlab(ctx, tx - 24, ty - ph * 0.3, W * 0.5, ph * 0.5, "#000");
    ransom(ctx, c.en, tx, ty - ph * 0.12, Math.min(ph * (wide ? 0.2 : 0.3), W * 0.075), this.t, W * 0.46);
    ctx.font = `400 ${Math.min(ph * (wide ? 0.14 : 0.2), W * 0.05)}px ${FONT_JP}`;
    ctx.fillStyle = "#fff";
    ctx.strokeStyle = "#000";
    ctx.lineWidth = 10;
    ctx.textAlign = "left";
    ctx.strokeText(c.jp, tx + 10, ty + ph * (wide ? 0.16 : 0.28));
    ctx.fillText(c.jp, tx + 10, ty + ph * (wide ? 0.16 : 0.28));
    ctx.restore();
  }
  // the P5 finisher: black silhouettes of the crew on red, a white splash
  _allOut(ctx, W, H, A) {
    const k = A.t / A.dur, inK = ease(Math.min(1, A.t / 0.12));
    ctx.save();
    ctx.globalAlpha = k > 0.85 ? (1 - k) / 0.15 : 1;
    ctx.fillStyle = "#e60012";
    ctx.fillRect(0, 0, W, H);
    ctx.fillStyle = "#fff";
    ctx.beginPath();
    const cx = W * 0.62, cy = H * 0.42, R = Math.max(W, H) * 0.55 * inK;
    for (let i = 0; i < 28; i++) {
      const a = (i / 28) * TAU, r = R * (i % 2 ? 0.45 : 1) * (0.8 + jit(i) * 0.4);
      ctx.lineTo(cx + Math.cos(a) * r, cy + Math.sin(a) * r * 0.7);
    }
    ctx.fill();
    ctx.fillStyle = tones(ctx).dotR;
    ctx.fillRect(0, 0, W, H);
    A.draw?.(ctx, W, H, inK);
    ransom(ctx, "ALL-OUT!", W * 0.06, H * 0.2, Math.min(W * 0.09, H * 0.14), this.t);
    ctx.restore();
  }
  _titleManga(ctx, W, H, T) {
    const k = Math.min(1, T.t / 0.35);
    ctx.save();
    const fs = Math.min(W * 0.16, H * 0.2);
    const s = 1 + (1 - ease(k)) * 0.8;
    ctx.translate(W / 2, H * 0.24);
    ctx.scale(s, s);
    ctx.rotate(-0.05);
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.lineJoin = "round";
    ctx.font = `400 ${fs}px ${FONT_JP}`;
    ctx.lineWidth = fs * 0.2;
    ctx.strokeStyle = "#000";
    ctx.strokeText(T.jp, 0, 0);
    const g = ctx.createLinearGradient(0, -fs / 2, 0, fs / 2);
    g.addColorStop(0, "#fff8d0");
    g.addColorStop(0.5, "#ffd23a");
    g.addColorStop(0.52, "#e8901a");
    g.addColorStop(1, "#b8481a");
    ctx.fillStyle = g;
    ctx.fillText(T.jp, 0, 0);
    ctx.font = `italic 900 ${fs * 0.34}px ${FONT}`;
    ctx.lineWidth = fs * 0.08;
    ctx.strokeText(T.en, 0, fs * 0.66);
    ctx.fillStyle = "#fff";
    ctx.fillText(T.en, 0, fs * 0.66);
    if (T.sub) {
      ctx.font = `700 ${fs * 0.15}px ${FONT}`;
      ctx.lineWidth = 6;
      ctx.strokeText(T.sub, 0, fs * 0.98);
      ctx.fillText(T.sub, 0, fs * 0.98);
    }
    ctx.restore();
  }
  _titleP5(ctx, W, H, T) {
    const k = Math.min(1, T.t / 0.3);
    ctx.save();
    ctx.translate(-(1 - ease(k)) * W, 0);
    ctx.fillStyle = "#000";
    ctx.beginPath();
    ctx.moveTo(0, H * 0.1);
    ctx.lineTo(W * 0.78, H * 0.07);
    ctx.lineTo(W * 0.72, H * 0.36);
    ctx.lineTo(0, H * 0.4);
    ctx.fill();
    ctx.fillStyle = "#e60012";
    ctx.fillRect(0, H * 0.4, W * 0.7, 10);
    const fs = Math.min(W * 0.1, H * 0.14);
    ransom(ctx, T.en, W * 0.05, H * 0.21, fs, this.t, W * 0.62);
    ctx.font = `400 ${fs * 0.42}px ${FONT_JP}`;
    ctx.fillStyle = "#fff";
    ctx.textAlign = "left";
    ctx.fillText(T.jp + (T.sub ? "  ·  " + T.sub : ""), W * 0.06, H * 0.33);
    ctx.restore();
  }
}

// ransom-note lettering: each letter on its own tilted tile, alternating colours and faces
export function ransom(ctx, text, x, y, fs, t = 0, maxW = Infinity) {
  // shrink to fit: the tiles are about 0.75 em wide each
  const est = [...text].length * fs * 1.02;
  if (est > maxW) fs *= maxW / est;
  const faces = [`900 ${fs}px ${FONT}`, `italic 900 ${fs * 0.92}px Georgia, serif`, `400 ${fs * 0.95}px ${FONT_JP}`, `900 ${fs * 1.05}px Impact, ${FONT}`];
  const cols = [["#fff", "#000"], ["#000", "#fff"], ["#e60012", "#fff"], ["#fff", "#e60012"]];
  ctx.save();
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  let cx = x;
  [...text].forEach((ch, i) => {
    if (ch === " ") return void (cx += fs * 0.4);
    const f = faces[(i * 7) % faces.length], [bg, fg] = cols[(i * 5 + 1) % cols.length];
    ctx.font = f;
    const w = Math.max(fs * 0.55, ctx.measureText(ch).width + fs * 0.2);
    ctx.save();
    ctx.translate(cx + w / 2, y + (jit(i, 3) - 0.5) * fs * 0.2);
    ctx.rotate((jit(i, 4) - 0.5) * 0.35);
    ctx.fillStyle = "#000";
    ctx.fillRect(-w / 2 - 4, -fs * 0.62 - 4, w + 8, fs * 1.24 + 8);
    ctx.fillStyle = bg;
    ctx.fillRect(-w / 2, -fs * 0.62, w, fs * 1.24);
    ctx.fillStyle = fg;
    ctx.fillText(ch, 0, fs * 0.04);
    ctx.restore();
    cx += w + fs * 0.06;
  });
  ctx.restore();
}

function speedLines(ctx, cx, cy, R, k, col, t, inner = 0, n = 70) {
  ctx.save();
  ctx.fillStyle = `rgba(${col},${Math.min(1, 0.6 * k)})`;
  for (let i = 0; i < n; i++) {
    const a = (i / n) * TAU + jit(i + Math.floor(t * 12) * 0.01) * 0.06, r0 = Math.max(inner, R * (0.3 + (((i * 37) % 17) / 60)));
    const w = 0.004 + (i % 4) * 0.003;
    ctx.beginPath();
    ctx.moveTo(cx + Math.cos(a) * r0, cy + Math.sin(a) * r0);
    ctx.lineTo(cx + Math.cos(a - w) * R * 1.4, cy + Math.sin(a - w) * R * 1.4);
    ctx.lineTo(cx + Math.cos(a + w) * R * 1.4, cy + Math.sin(a + w) * R * 1.4);
    ctx.fill();
  }
  ctx.restore();
}

// impact frames: one frame each. "mono" is the manga frame: the picture itself, in
// black and white at full contrast; "monoInv" its negative; "red" is the P5 flash
export function drawImpact(ctx, W, H, kind, src, dpr) {
  ctx.save();
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  const w = ctx.canvas.width, h = ctx.canvas.height;
  if (kind === "white") (ctx.fillStyle = "#fffdf4"), ctx.fillRect(0, 0, w, h);
  else if (kind === "black") (ctx.fillStyle = "#000"), ctx.fillRect(0, 0, w, h);
  else if (kind === "invert") (ctx.globalCompositeOperation = "difference"), (ctx.fillStyle = "#fff"), ctx.fillRect(0, 0, w, h);
  else if ((kind === "mono" || kind === "monoInv" || kind === "red") && src) {
    ctx.filter = kind === "mono" ? "grayscale(1) contrast(9) brightness(1.15)" : kind === "monoInv" ? "grayscale(1) contrast(9) invert(1)" : "grayscale(1) contrast(9)";
    ctx.drawImage(src, 0, 0);
    ctx.filter = "none";
    if (kind === "red") (ctx.globalCompositeOperation = "screen"), (ctx.fillStyle = "#e60012"), ctx.fillRect(0, 0, w, h);
  }
  ctx.restore();
}

// the HUD: the kraken's grip across the top, hull and gauge, the combo, and the one prompt
export function drawHUD(ctx, W, H, s, style = "manga") {
  const narrow = W < 720, p5 = style === "p5";
  const bw = Math.min(W * (narrow ? 0.9 : 0.56), 720), bx = (W - bw) / 2, by = narrow ? 58 : Math.max(96, H * 0.11);
  ctx.save();
  const bar = (x, y, w, h, v, col, label, marks = []) => {
    if (!p5) return mangaBar(ctx, x, y, w, h, v, col, label, marks, narrow);
    ctx.save();
    ctx.translate(x, y);
    if (p5) ctx.transform(1, 0, -0.25, 1, 0, 0);
    ctx.fillStyle = "#000";
    ctx.fillRect(-4, -4, w + 8, h + 8);
    ctx.fillStyle = p5 ? "#fff" : "#3a2c30";
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = col;
    ctx.fillRect(0, 0, w * Math.max(0, Math.min(1, v)), h);
    for (const m of marks) (ctx.fillStyle = "#000"), ctx.fillRect(w * m - 2, -4, 4, h + 8);
    ctx.restore();
    ctx.font = `900 ${narrow ? 13 : 15}px ${FONT}`;
    ctx.textAlign = "left";
    ctx.lineWidth = 4;
    ctx.strokeStyle = "#000";
    ctx.strokeText(label, x, y - 8);
    ctx.fillStyle = "#fff";
    ctx.fillText(label, x, y - 8);
  };
  bar(bx, by, bw, 16, s.grip / 100, p5 ? "#e60012" : "#1a1410", "KRAKEN · " + (s.labels || ""), [0.6, 0.25]);
  const sw = narrow ? bw * 0.46 : Math.min(260, bw * 0.4);
  bar(bx, by + 42, sw, 11, s.hull / 100, s.hull < 35 ? (p5 ? "#ff4a2a" : "#e8801a") : p5 ? "#000" : "#6b6258", "HULL");
  bar(bx + bw - sw, by + 42, sw, 11, s.gauge / 100, s.gauge >= 100 ? "#ffd23a" : p5 ? "#e60012" : "#e8b030", s.gauge >= 100 ? "SPECIAL READY!" : "GAUGE");
  if (s.combo > 1) {
    ctx.save();
    ctx.translate(W - 24, narrow ? H * 0.5 : H * 0.34);
    ctx.rotate(-0.08);
    ctx.textAlign = "right";
    const fs = narrow ? 44 : 64;
    ctx.font = `400 ${fs}px ${FONT_JP}`;
    ctx.lineWidth = 12;
    ctx.lineJoin = "round";
    ctx.strokeStyle = "#000";
    ctx.strokeText(`${s.combo}連`, 0, 0);
    ctx.fillStyle = p5 ? "#e60012" : "#ffd23a";
    ctx.fillText(`${s.combo}連`, 0, 0);
    ctx.font = `italic 900 ${fs * 0.36}px ${FONT}`;
    ctx.lineWidth = 6;
    ctx.strokeText(`${s.combo} HIT COMBO`, 0, fs * 0.5);
    ctx.fillStyle = "#fff";
    ctx.fillText(`${s.combo} HIT COMBO`, 0, fs * 0.5);
    ctx.restore();
  }
  ctx.restore();
  if (s.prompt) drawPrompt(ctx, W, H, s.prompt, style, s.t);
}

// Manga's bars: a framed paper panel, the value inked in over a screentone, the label in a
// small balloon above it (the page's own HUD, as the HTML HUD is in Manga)
let tone = null;
function screentone(ctx) {
  if (tone !== null) return tone;
  try {
    const c = document.createElement("canvas");
    c.width = c.height = 6;
    const g = c.getContext("2d");
    g.fillStyle = "rgba(26,20,16,.35)";
    g.beginPath();
    g.arc(3, 3, 1.2, 0, TAU);
    g.fill();
    tone = ctx.createPattern(c, "repeat");
  } catch {
    tone = false;
  }
  return tone;
}
function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}
function mangaBar(ctx, x, y, w, h, v, col, label, marks, narrow) {
  const INK = "#1a1410", PAPER = "#f6eedb";
  ctx.save();
  ctx.fillStyle = INK; // the panel's drop, offset like a printed frame
  roundRect(ctx, x - 2, y + 1, w + 8, h + 7, 5);
  ctx.fill();
  roundRect(ctx, x - 4, y - 4, w + 8, h + 8, 5);
  ctx.fill();
  roundRect(ctx, x, y, w, h, 3);
  ctx.fillStyle = PAPER;
  ctx.fill();
  const t = screentone(ctx);
  if (t) (ctx.fillStyle = t), ctx.fill();
  const fw = w * Math.max(0, Math.min(1, v));
  if (fw > 0.5) {
    ctx.save();
    roundRect(ctx, x, y, w, h, 3);
    ctx.clip();
    ctx.fillStyle = col;
    ctx.fillRect(x, y, fw, h);
    ctx.fillStyle = "rgba(255,255,255,.35)"; // a pen highlight along the top
    ctx.fillRect(x, y + 2, fw, Math.max(2, h * 0.18));
    ctx.restore();
  }
  ctx.fillStyle = INK;
  for (const m of marks) ctx.fillRect(x + w * m - 2, y - 4, 4, h + 8);
  // the label in a balloon, a tab on the frame's top edge
  const fs = narrow ? 12 : 14;
  ctx.font = `400 ${fs}px ${FONT_JP}`;
  const tw = ctx.measureText(label).width, bh = fs + 6, bx = x + 6, by = y - bh + 1;
  roundRect(ctx, bx, by, tw + 16, bh, bh / 2);
  ctx.fillStyle = "#fff";
  ctx.fill();
  ctx.lineWidth = 3;
  ctx.strokeStyle = INK;
  ctx.stroke();
  ctx.fillStyle = INK;
  ctx.textAlign = "left";
  ctx.textBaseline = "middle";
  ctx.fillText(label, bx + 8, by + bh / 2 + 1);
  ctx.restore();
}

// the prompt: an approach ring closing on the target; when it meets the inner ring, TAP
export function drawPrompt(ctx, W, H, P, style, t) {
  const p5 = style === "p5";
  let [x, y] = P.at;
  const r0 = Math.min(W, H) * (P.quiet ? 0.045 : 0.075);
  x = Math.max(r0 + 10, Math.min(W - r0 - 10, x));
  y = Math.max(r0 + 110, Math.min(H - r0 - 130, y));
  ctx.save();
  ctx.lineJoin = "round";
  if (P.quiet) {
    // fire at will: a small crosshair on the kraken's eye
    ctx.globalAlpha = P.ready ? 0.9 : 0.4;
    ctx.strokeStyle = "#000";
    ctx.lineWidth = 7;
    ctx.beginPath();
    ctx.arc(x, y, r0, 0, TAU);
    ctx.stroke();
    ctx.strokeStyle = p5 ? "#e60012" : "#fff";
    ctx.lineWidth = 3;
    ctx.stroke();
    for (let i = 0; i < 4; i++) {
      const a = (i / 4) * TAU + t;
      ctx.beginPath();
      ctx.moveTo(x + Math.cos(a) * r0 * 0.6, y + Math.sin(a) * r0 * 0.6);
      ctx.lineTo(x + Math.cos(a) * r0 * 1.35, y + Math.sin(a) * r0 * 1.35);
      ctx.stroke();
    }
    ctx.font = `900 ${Math.round(r0 * 0.42)}px ${FONT}`;
    ctx.textAlign = "center";
    ctx.lineWidth = 5;
    ctx.strokeStyle = "#000";
    ctx.strokeText(P.text, x, y + r0 * 1.8);
    ctx.fillStyle = "#fff";
    ctx.fillText(P.text, x, y + r0 * 1.8);
    ctx.restore();
    return;
  }
  const pulse = P.ready ? 1 + Math.sin(t * 18) * 0.08 : 1;
  // the target
  ctx.fillStyle = P.ready ? (p5 ? "rgba(230,0,18,.55)" : "rgba(255,210,58,.4)") : "rgba(0,0,0,.25)";
  ctx.beginPath();
  ctx.arc(x, y, r0 * pulse, 0, TAU);
  ctx.fill();
  ctx.strokeStyle = "#000";
  ctx.lineWidth = 12;
  ctx.stroke();
  ctx.strokeStyle = P.col;
  ctx.lineWidth = 6;
  ctx.stroke();
  // the approach ring
  if (!P.ready || P.p < 1) {
    const R = r0 * (1 + 2.2 * (1 - P.p));
    ctx.strokeStyle = "#000";
    ctx.lineWidth = 9;
    ctx.beginPath();
    ctx.arc(x, y, R, 0, TAU);
    ctx.stroke();
    ctx.strokeStyle = "#fff";
    ctx.lineWidth = 4;
    ctx.stroke();
  } else {
    // burst lines round the ready target
    ctx.strokeStyle = "#000";
    ctx.lineWidth = 8;
    for (let i = 0; i < 12; i++) {
      const a = (i / 12) * TAU + t * 2;
      ctx.beginPath();
      ctx.moveTo(x + Math.cos(a) * r0 * 1.25, y + Math.sin(a) * r0 * 1.25);
      ctx.lineTo(x + Math.cos(a) * r0 * (1.6 + (i % 2) * 0.3), y + Math.sin(a) * r0 * (1.6 + (i % 2) * 0.3));
      ctx.stroke();
    }
  }
  // the word
  const fs = Math.round(r0 * (P.ready ? 0.7 : 0.5));
  if (p5 && P.ready) ransom(ctx, P.text.replace(/^TAP! /, "TAP!"), x - r0 * 1.9, y - r0 * 1.9, fs * 0.8, t);
  else {
    ctx.font = P.ready ? `400 ${fs}px ${FONT_JP}` : `italic 900 ${fs}px ${FONT}`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.lineWidth = fs * 0.24;
    ctx.strokeStyle = "#000";
    ctx.save();
    ctx.translate(x, y - r0 * 1.75);
    ctx.rotate(-0.06);
    ctx.scale(pulse, pulse);
    ctx.strokeText(P.text, 0, 0);
    ctx.fillStyle = P.ready ? P.col : "#fff";
    ctx.fillText(P.text, 0, 0);
    ctx.restore();
  }
  if (P.sub) {
    ctx.font = `800 ${Math.round(r0 * 0.3)}px ${FONT}`;
    ctx.textAlign = "center";
    ctx.lineWidth = 5;
    ctx.strokeStyle = "#000";
    ctx.strokeText(P.sub.toUpperCase(), x, y + r0 * 1.55);
    ctx.fillStyle = "#fff";
    ctx.fillText(P.sub.toUpperCase(), x, y + r0 * 1.55);
  }
  ctx.restore();
}

// the black slab a title sits on when the montage fills the band behind it
function titleSlab(ctx, x, y, w, h, col) {
  ctx.save();
  ctx.fillStyle = col;
  ctx.beginPath();
  ctx.moveTo(x + h * 0.12, y);
  ctx.lineTo(x + w, y + h * 0.04);
  ctx.lineTo(x + w - h * 0.12, y + h);
  ctx.lineTo(x, y + h * 0.95);
  ctx.closePath();
  ctx.fill();
  ctx.strokeStyle = "#fff";
  ctx.lineWidth = 6;
  ctx.stroke();
  ctx.restore();
}
// a row of slanted portrait panels (the bigger ships' multi-panel cut-ins and the montage)
function panelRow(ctx, portraits, x0, x1, y0, y1, style, k) {
  const n = portraits.length, w = (x1 - x0) / n, sl = (y1 - y0) * 0.18;
  portraits.forEach((draw, i) => {
    const a = x0 + i * w, b = a + w;
    const inK = Math.min(1, Math.max(0, k * 6 - i * 0.35)); // the panels slam in one after another
    if (inK <= 0) return;
    ctx.save();
    ctx.translate(0, (1 - inK) * (i % 2 ? -1 : 1) * (y1 - y0));
    ctx.beginPath();
    ctx.moveTo(a + sl, y0);
    ctx.lineTo(b + sl, y0);
    ctx.lineTo(b - sl, y1);
    ctx.lineTo(a - sl, y1);
    ctx.closePath();
    ctx.fillStyle = style === "p5" ? (i % 2 ? "#fff" : "#e60012") : i % 2 ? "#f2e6c8" : "#1f2f5c";
    ctx.fill();
    ctx.save();
    ctx.clip();
    const h = y1 - y0;
    ctx.translate((a + b) / 2, (y0 + y1) / 2 + h * 0.08);
    draw(ctx, h * 1.6, h * 0.62, false, style === "p5" ? "p5" : "ink");
    ctx.restore();
    ctx.lineWidth = 10;
    ctx.strokeStyle = "#000";
    ctx.stroke();
    ctx.restore();
  });
}
