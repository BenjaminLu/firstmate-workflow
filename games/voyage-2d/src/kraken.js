// The kraken, painted in 2D: a great mantle rising off the bow with burning eyes, and
// one arm per held task. Each arm is a chain of segments (curl, lean and taper), drawn
// as one filled ribbon with a lighter underside and a row of suckers. An arm plays its
// attack from the battle state: it coils back and glows (the telegraph), then snaps down
// on a deck section; bound arms hang in chains; in the MAELSTROM all arms tower.
import { SEA_Y } from "./env.js";
import { drawCrest } from "./fx.js";

const lerp = (a, b, k) => a + (b - a) * k;
const TAU = Math.PI * 2;

export class Kraken {
  constructor({ low = false } = {}) {
    this.low = low;
    this.x = 1560; this.baseY = SEA_Y + 60;
    // its size: drawn scaled by k about its foot on the sea (x, SEA_Y), so it stands as tall over
    // a big ship's freeboard as it did over the small ones; positions it gives out are the world's
    this.k = 1;
    this.rise = 0; this.riseTarget = 0;
    this.t = 0;
    this.arms = [];
    this.setArms(0);
    this.expr = "glare"; // glare | angry | hurt
    this.hurt = 0; this.rear = 0; this.lunge = 0; this.flash = 0;
    this.weak = 0; // the weak point glows during a riposte window
    this.ult = 0; // the maelstrom: arms tower, eyes blaze
    this.stagger = 0;
    this.far = 0;
    this.labels = [];
    // four arms that are always there: the monster's silhouette, never an attack
    this.deco = [-560, -380, 380, 560].map((bx, i) => ({ i: 100 + i, seg: low ? 12 : 18, side: bx < 0 ? -1 : 1, baseX: bx, len: 1100 + i * 90, ph: i * 2.3, attack: null, bound: false, lift: 0, slam: 0, tip: [0, 0], deco: true }));
  }
  setArms(n) {
    const keep = this.arms;
    this.arms = Array.from({ length: n }, (_, i) => keep[i] || {
      i, seg: this.low ? 16 : 24,
      side: i % 2 ? 1 : -1,
      baseX: (i % 2 ? 1 : -1) * (180 + Math.floor(i / 2) * 150),
      len: 900 + ((i * 131) % 5) * 60,
      ph: i * 1.7,
      attack: null, // { p, target: [x, y], pattern, hit }
      bound: false, lift: 0, slam: 0, tip: [0, 0],
    });
  }
  update(dt) {
    this.t += dt;
    this.rise += (this.riseTarget - this.rise) * Math.min(1, dt * 1.4);
    this.hurt = Math.max(0, this.hurt - dt * 2);
    this.flash = Math.max(0, this.flash - dt * 5);
    this.lunge = Math.max(0, this.lunge - dt * 2.5);
    this.stagger = Math.max(0, this.stagger - dt);
    for (const a of this.arms) a.slam = Math.max(0, a.slam - dt * 1.6);
  }
  get y() { return this.baseY + (1 - this.rise) * 900 - this.rear * 60 + Math.sin(this.t * 0.9) * 14; }
  // its own space (drawn scaled by k about its foot) to the world's, and back
  toW(x, y) { return [this.x + (x - this.x) * this.k, SEA_Y + (y - SEA_Y) * this.k]; }
  toL(x, y) { return [this.x + (x - this.x) / this.k, SEA_Y + (y - SEA_Y) / this.k]; }
  _head() { return [this.x - this.lunge * 160 + Math.sin(this.stagger * 30) * this.stagger * 30, this.y - 620]; }
  headPos() { return this.toW(...this._head()); }
  enter(ctx) { ctx.save(); ctx.translate(this.x, SEA_Y); ctx.scale(this.k, this.k); ctx.translate(-this.x, -SEA_Y); }
  // an arm's centre line in its own space (a.tip is kept in the world's)
  armPoints(a) {
    const [hx] = this._head();
    const bx = hx + a.baseX, by = SEA_Y + 40;
    const n = a.seg, pts = [];
    const t = this.t;
    let ang = -Math.PI / 2 + a.side * -0.35, x = bx, y = by;
    const L = a.len * (0.3 + 0.7 * this.rise);
    const step = L / n;
    let tgt = null, k = 0;
    if (a.attack) ({ p: k } = a.attack), (tgt = a.attack.target && this.toL(...a.attack.target));
    const ult = this.ult;
    for (let i = 0; i < n; i++) {
      pts.push([x, y]);
      const s = i / (n - 1);
      let curl = Math.sin(t * 1.1 + a.ph + s * 3) * 0.08 + a.side * 0.035 * s * 2;
      if (a.bound) curl = 0.02 + Math.sin(t * 8 + i) * 0.015;
      // the telegraph: coil up and back, then (in the last 15 %) the snap to the target
      if (tgt) {
        const coil = k < 0.85 ? Math.min(1, k / 0.6) : 1 - (k - 0.85) / 0.15;
        curl += -0.11 * coil * (0.4 + s);
      }
      curl -= ult * 0.03 * s;
      ang += curl;
      x += Math.cos(ang) * step;
      y += Math.sin(ang) * step;
    }
    // aim the last half of the arm at the target during the snap / after a slam
    const hit = tgt && k > 0.85 ? (k - 0.85) / 0.15 : 0;
    const sl = Math.max(hit, a.slam);
    if (sl > 0 && (tgt || a.lastTarget)) {
      const T = tgt || this.toL(...a.lastTarget);
      if (tgt) a.lastTarget = a.attack.target;
      const start = Math.floor(n * 0.35);
      const [sx, sy] = pts[start];
      for (let i = start; i < n; i++) {
        const s = (i - start) / (n - 1 - start);
        const cx = lerp(sx, T[0], s) + Math.sin(s * Math.PI) * -160, cy = lerp(sy, T[1], s) - Math.sin(s * Math.PI) * 260;
        pts[i] = [lerp(pts[i][0], cx, sl), lerp(pts[i][1], cy, sl)];
      }
    }
    if (a.lift) for (let i = 0; i < n; i++) pts[i][1] -= a.lift * 200 * (i / n);
    a.tip = this.toW(...pts[n - 1]);
    return pts;
  }
  // the yōkai boss: cel-shaded in three flat tones, a heavy ink outline, screentone on the
  // shadow side, sharp eyes with glowing irises, and a demonic flame aura in the ultimate
  drawBody(ctx) {
    if (this.rise < 0.02) return;
    this.enter(ctx);
    this._body(ctx);
    ctx.restore();
  }
  _body(ctx) {
    const [hx, hy] = this._head();
    const t = this.t;
    for (const d of this.deco) drawArm(ctx, this.armPoints(d), d, this);
    ctx.save();
    ctx.translate(hx, hy);
    const s = 1 - this.far * 0.6;
    ctx.scale(s, s);
    ctx.rotate(-0.1 * this.rear + Math.sin(t * 0.7) * 0.03 - 0.06);
    const ult = this.ult > 0.1, flash = this.flash > 0.1;
    const mantle = () => {
      ctx.beginPath();
      ctx.moveTo(-470, 560);
      ctx.bezierCurveTo(-620, 200, -560, -320, -300, -580);
      ctx.lineTo(-200, -700); // a horned crown
      ctx.lineTo(-150, -600);
      ctx.bezierCurveTo(-40, -760, 200, -760, 300, -640);
      ctx.lineTo(420, -720);
      ctx.lineTo(400, -540);
      ctx.bezierCurveTo(560, -260, 540, 200, 480, 560);
      ctx.closePath();
    };
    if (ult) this._aura(ctx, t);
    // tone 1: the base
    ctx.fillStyle = flash ? "#ffffff" : ult ? "#8a1a4a" : "#6a2a8e";
    mantle();
    ctx.fill();
    ctx.save();
    mantle();
    ctx.clip();
    // tone 2: the shadow side, hard edged, with screentone
    ctx.fillStyle = flash ? "#dddddd" : ult ? "#4a0828" : "#3a1052";
    ctx.beginPath();
    ctx.moveTo(60, -760);
    ctx.bezierCurveTo(300, -500, 380, 0, 200, 600);
    ctx.lineTo(700, 600);
    ctx.lineTo(700, -760);
    ctx.fill();
    if (!this.low) (ctx.fillStyle = this.tone || (this.tone = toneOf(ctx))), ctx.fillRect(40, -780, 700, 1400);
    // tone 3: the lit crescent (hard edged)
    ctx.fillStyle = flash ? "#fff" : ult ? "#e0508a" : "#a860d0";
    ctx.beginPath();
    ctx.moveTo(-500, 300);
    ctx.bezierCurveTo(-560, -100, -460, -440, -240, -600);
    ctx.bezierCurveTo(-380, -380, -440, -60, -400, 320);
    ctx.fill();
    // markings: angular stripes like war paint
    ctx.fillStyle = ult ? "#200010" : "#24062e";
    for (const [x0, y0, a] of [[-260, -300, 0.4], [-120, -420, 0.2], [60, -440, -0.1], [220, -330, -0.3]]) {
      ctx.save();
      ctx.translate(x0, y0);
      ctx.rotate(a);
      ctx.beginPath();
      ctx.moveTo(0, -90);
      ctx.lineTo(22, 60);
      ctx.lineTo(-16, 60);
      ctx.fill();
      ctx.restore();
    }
    ctx.restore();
    ctx.strokeStyle = "#000";
    ctx.lineWidth = 16;
    ctx.lineJoin = "round";
    mantle();
    ctx.stroke();
    const angry = this.expr === "angry" || ult, hurt = this.expr === "hurt" || this.hurt > 0.2;
    // the eyes: sharp almonds slanting in, glowing irises, slit pupils
    for (const sx of [-1, 1]) {
      ctx.save();
      ctx.translate(sx * 170, 150);
      ctx.scale(sx, 1);
      const eye = () => {
        ctx.beginPath();
        ctx.moveTo(-150, -10 - (angry ? 30 : 12));
        ctx.quadraticCurveTo(-20, -110, 130, 40);
        ctx.quadraticCurveTo(-10, 70, -150, -10 - (angry ? 30 : 12));
        ctx.closePath();
      };
      ctx.fillStyle = "#000";
      ctx.save();
      ctx.scale(1.12, 1.25);
      eye();
      ctx.fill();
      ctx.restore();
      if (hurt) {
        ctx.strokeStyle = ult ? "#ff3a2a" : "#ffd23a";
        ctx.lineWidth = 22;
        ctx.beginPath();
        ctx.moveTo(-90, -40); ctx.lineTo(80, 30); ctx.moveTo(-90, 30); ctx.lineTo(80, -40);
        ctx.stroke();
      } else {
        ctx.fillStyle = ult ? "#ff2a1a" : "#ffcf2a";
        eye();
        ctx.fill();
        ctx.fillStyle = ult ? "#ffe0a0" : "#fff8c0";
        ctx.beginPath();
        ctx.arc(-10, 4, 36, 0, TAU);
        ctx.fill();
        ctx.fillStyle = "#000";
        ctx.beginPath();
        ctx.ellipse(-10 + Math.sin(t * 0.8) * 8, 4, 10, angry ? 44 : 38, 0, 0, TAU);
        ctx.fill();
      }
      ctx.restore();
    }
    // brows: jagged spikes
    ctx.fillStyle = "#000";
    for (const sx of [-1, 1]) {
      ctx.beginPath();
      ctx.moveTo(sx * 30, 70);
      for (let i = 0; i < 4; i++) ctx.lineTo(sx * (90 + i * 80), 20 - i * 26 - (angry ? 30 : 0) + (i % 2) * 40);
      ctx.lineTo(sx * 340, -20 - (angry ? 40 : 0));
      ctx.lineTo(sx * 60, 110);
      ctx.fill();
    }
    // the beak and fangs
    ctx.fillStyle = "#000";
    ctx.beginPath();
    ctx.moveTo(-110, 300);
    ctx.quadraticCurveTo(0, 420 + (angry ? 50 : 10), 110, 300);
    ctx.quadraticCurveTo(0, 360, -110, 300);
    ctx.fill();
    ctx.fillStyle = "#fff";
    for (const x of [-70, -25, 25, 70]) {
      ctx.beginPath();
      ctx.moveTo(x - 16, 318);
      ctx.lineTo(x, 318 + (angry ? 70 : 44) * (Math.abs(x) < 40 ? 1 : 0.7));
      ctx.lineTo(x + 16, 318);
      ctx.fill();
    }
    // eye glow (additive)
    ctx.globalCompositeOperation = "lighter";
    for (const ex of [-170, 170]) {
      const k = 0.4 + this.ult * 0.6 + (ex < 0 ? this.weak * 0.8 : 0);
      const gg = ctx.createRadialGradient(ex, 150, 0, ex, 150, 260);
      gg.addColorStop(0, ult ? `rgba(255,50,30,${k})` : `rgba(255,210,70,${k})`);
      gg.addColorStop(1, "rgba(255,120,40,0)");
      ctx.fillStyle = gg;
      ctx.fillRect(ex - 260, -110, 520, 520);
    }
    ctx.globalCompositeOperation = "source-over";
    if (this.weak > 0.05) {
      ctx.strokeStyle = "#000";
      ctx.lineWidth = 20;
      const r = 160 + Math.sin(t * 16) * 14;
      ctx.beginPath();
      ctx.arc(-170, 150, r, 0, TAU);
      ctx.stroke();
      ctx.strokeStyle = `rgba(255,240,120,${this.weak})`;
      ctx.lineWidth = 9;
      ctx.stroke();
    }
    ctx.restore();
    // ukiyo-e crests breaking round the monster where it meets the sea
    for (const [dx, h, d] of this.low ? [[-620, 150, -1], [640, 160, 1]] : [[-620, 150, -1], [-330, 110, 1], [360, 130, -1], [640, 160, 1]]) drawCrest(ctx, hx + dx, SEA_Y + 50, (h + Math.sin(t * 1.6 + dx) * 20) * this.rise, d);
  }
  // the demonic aura: flat flame tongues, black-edged, licking up round the mantle
  _aura(ctx, t) {
    ctx.save();
    for (const [col, k] of [["#000", 1.12], ["#a00020", 1.06], ["#ff3a2a", 0.98]]) {
      ctx.fillStyle = col;
      ctx.beginPath();
      const n = 22;
      for (let i = 0; i <= n; i++) {
        const u = i / n, a = Math.PI + u * Math.PI;
        const flick = Math.sin(t * 9 + i * 1.7) * 0.5 + 0.5;
        const r = (i % 2 ? 640 : 820 + flick * 260) * k * this.ult;
        ctx.lineTo(Math.cos(a) * r * 0.9, -140 + Math.sin(a) * r);
      }
      ctx.lineTo(600 * k, 560);
      ctx.lineTo(-600 * k, 560);
      ctx.fill();
    }
    ctx.restore();
  }
  eyePos() { const [x, y] = this._head(); return this.toW(x - 170, y + 150); }
  drawArms(ctx, { front = false } = {}) {
    if (this.rise < 0.02) return;
    this.enter(ctx);
    this._arms(ctx, front);
    ctx.restore();
  }
  _arms(ctx, front) {
    for (const a of this.arms) {
      // the attacking arm and bound arms are drawn in front of the ship
      const isFront = !!a.attack || a.slam > 0.02;
      if (isFront !== front) continue;
      const pts = this.armPoints(a);
      drawArm(ctx, pts, a, this);
    }
  }
}

function drawArm(ctx, pts, a, K) {
  const n = pts.length;
  const edges = (P) => {
    const L = [], R = [];
    for (let i = 0; i < n; i++) {
      const p = P[i], q = P[Math.min(n - 1, i + 1)], o = P[Math.max(0, i - 1)];
      let dx = q[0] - o[0], dy = q[1] - o[1];
      const d = Math.hypot(dx, dy) || 1;
      dx /= d; dy /= d;
      const w = lerp(a.deco ? 90 : 110, 12, Math.pow(i / (n - 1), 0.85));
      L.push([p[0] - dy * w, p[1] + dx * w]);
      R.push([p[0] + dy * w, p[1] - dx * w]);
    }
    return [L, R];
  };
  const [L, R] = edges(pts);
  const shape = (L, R) => {
    ctx.beginPath();
    ctx.moveTo(...L[0]);
    for (const p of L) ctx.lineTo(...p);
    for (let i = n - 1; i >= 0; i--) ctx.lineTo(...R[i]);
    ctx.closePath();
  };
  // smear frames: while it lashes, ghosts of the last frames trail behind with speed lines
  const lashing = !K.low && ((a.attack && a.attack.p > 0.85) || a.slam > 0.6);
  if (lashing && a.prevPts) {
    const [pl, pr] = edges(a.prevPts);
    ctx.fillStyle = "rgba(20,0,30,.35)";
    shape(pl, pr);
    ctx.fill();
    ctx.strokeStyle = "rgba(0,0,0,.8)";
    ctx.lineWidth = 6;
    for (let i = Math.floor(n * 0.4); i < n; i += 2) {
      ctx.beginPath();
      ctx.moveTo(...a.prevPts[i]);
      ctx.lineTo(...pts[i]);
      ctx.stroke();
    }
  }
  a.prevPts = pts.map((p) => p.slice());
  const ult = K.ult > 0.1;
  ctx.fillStyle = a.bound ? "#4a3a5a" : ult ? "#6a1040" : "#5a2078";
  shape(L, R);
  ctx.fill();
  // the underside: a flat light band
  ctx.fillStyle = ult ? "#ff8aa8" : "#e890c0";
  ctx.beginPath();
  ctx.moveTo(...R[0]);
  for (let i = 0; i < n; i++) ctx.lineTo(lerp(R[i][0], pts[i][0], 0.5), lerp(R[i][1], pts[i][1], 0.5));
  for (let i = n - 1; i >= 0; i--) ctx.lineTo(...R[i]);
  ctx.fill();
  // dry-brush streaks along the arm (sumi-e); phones skip them
  if (!K.low) {
  ctx.strokeStyle = "rgba(10,0,20,.55)";
  ctx.lineWidth = 5;
  ctx.setLineDash([40, 18, 12, 22]);
  for (const k of [0.25, 0.7]) {
    ctx.beginPath();
    for (let i = 0; i < n - 2; i++) ctx.lineTo(lerp(L[i][0], pts[i][0], k), lerp(L[i][1], pts[i][1], k));
    ctx.stroke();
  }
  ctx.setLineDash([]);
  }
  // suckers: ink rings
  for (let i = 1; i < n - 1; i += 2) {
    const r = lerp(18, 4, i / n);
    ctx.beginPath();
    ctx.arc(lerp(R[i][0], pts[i][0], 0.25), lerp(R[i][1], pts[i][1], 0.25), r, 0, TAU);
    ctx.fillStyle = "#fbe0ec";
    ctx.fill();
    if (!K.low) (ctx.lineWidth = 4), (ctx.strokeStyle = "#000"), ctx.stroke();
  }
  ctx.strokeStyle = "#000";
  ctx.lineWidth = 11;
  ctx.lineJoin = "round";
  shape(L, R);
  ctx.stroke();
  // the telegraph: a big inked warning burst on the tip, gold (parry) or red (unblockable)
  const glow = a.attack ? Math.min(1, a.attack.p / 0.5) : 0;
  if (glow > 0.05) {
    const [tx, ty] = pts[n - 1];
    const unp = a.attack && !a.attack.parryable;
    const vs = K.viewScale || 1;
    ctx.save();
    ctx.translate(tx, ty);
    ctx.rotate(K.t * 4);
    const r = (140 + 60 * Math.sin(K.t * 20)) * glow * vs;
    ctx.beginPath();
    for (let i = 0; i < 16; i++) {
      const aa = (i / 16) * TAU, rr = i % 2 ? r * 0.5 : r;
      ctx.lineTo(Math.cos(aa) * rr, Math.sin(aa) * rr);
    }
    ctx.closePath();
    ctx.fillStyle = unp ? "#ff2a1a" : "#ffd23a";
    ctx.fill();
    ctx.lineWidth = 10;
    ctx.strokeStyle = "#000";
    ctx.stroke();
    ctx.restore();
  }
  if (a.bound) {
    ctx.strokeStyle = "#000";
    ctx.lineWidth = 22;
    for (const i of [Math.floor(n * 0.4), Math.floor(n * 0.6)]) {
      ctx.beginPath();
      ctx.moveTo(...L[i]);
      ctx.lineTo(...R[i]);
      ctx.stroke();
    }
    ctx.strokeStyle = "#c9c9d6";
    ctx.lineWidth = 12;
    ctx.setLineDash([22, 10]);
    for (const i of [Math.floor(n * 0.4), Math.floor(n * 0.6)]) {
      ctx.beginPath();
      ctx.moveTo(...L[i]);
      ctx.lineTo(...R[i]);
      ctx.stroke();
    }
    ctx.setLineDash([]);
  }
}
function toneOf(ctx) {
  const c = document.createElement("canvas");
  c.width = c.height = 14;
  const x = c.getContext("2d");
  x.fillStyle = "rgba(0,0,0,.4)";
  x.beginPath();
  x.arc(7, 7, 3.2, 0, TAU);
  x.fill();
  return ctx.createPattern(c, "repeat");
}
