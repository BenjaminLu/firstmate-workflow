// Effects in world space, pooled and capped for phones: sprites (flash, fire, smoke,
// sparks, glow), debris chips, shockwave rings, water columns, cannonballs with smoke
// trails, fireworks (with their reflection on the sea), damage numbers. Screen-space
// feel (trauma shake, hit-stop, impact frames, flashes) lives here too, read by the
// camera and the frame compositor.
import { SEA_Y } from "./env.js";

const TAU = Math.PI * 2;
function glowTex(stops, size = 128) {
  const c = document.createElement("canvas");
  c.width = c.height = size;
  const x = c.getContext("2d");
  const g = x.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
  for (const [k, col] of stops) g.addColorStop(k, col);
  x.fillStyle = g;
  x.fillRect(0, 0, size, size);
  return c;
}
let TEX = null;
// hand-drawn look: every effect texture is 2-3 flat tones with a black ink outline
function cel(size, draw) {
  const c = document.createElement("canvas");
  c.width = c.height = size;
  const x = c.getContext("2d");
  x.translate(size / 2, size / 2);
  x.lineJoin = "round";
  draw(x, size / 2);
  return c;
}
function blob(x, r, n, jag, seed) {
  x.beginPath();
  for (let i = 0; i <= n; i++) {
    const a = (i / n) * TAU, k = 1 - jag * (0.5 + 0.5 * Math.sin(i * 2.3 + seed) * Math.cos(i * 1.7 + seed * 3));
    x.lineTo(Math.cos(a) * r * k, Math.sin(a) * r * k);
  }
  x.closePath();
}
function flameShape(x, r, seed) {
  x.beginPath();
  const n = 9;
  for (let i = 0; i < n; i++) {
    const a = (i / n) * TAU - Math.PI / 2, a2 = ((i + 0.5) / n) * TAU - Math.PI / 2;
    const tip = r * (0.85 + 0.15 * Math.sin(i * 3.1 + seed));
    x.lineTo(Math.cos(a) * tip, Math.sin(a) * tip);
    x.lineTo(Math.cos(a2) * r * 0.55, Math.sin(a2) * r * 0.55);
  }
  x.closePath();
}
function tex() {
  if (TEX) return TEX;
  const S = 160, R = 72;
  const layered = (tones, shape) => cel(S, (x, h) => {
    shape(x, R);
    x.fillStyle = "#000";
    x.lineWidth = 10;
    x.stroke();
    tones.forEach(([col, k], i) => {
      x.save();
      x.scale(k, k);
      if (i) x.translate(R * 0.08 * i, -R * 0.1 * i);
      shape(x, R);
      x.fillStyle = col;
      x.fill();
      x.restore();
    });
  });
  const burst = (x, r) => {
    x.beginPath();
    for (let i = 0; i < 24; i++) {
      const a = (i / 24) * TAU, rr = i % 2 ? r * 0.42 : r * (0.8 + (i % 4 ? 0 : 0.2));
      x.lineTo(Math.cos(a) * rr, Math.sin(a) * rr);
    }
    x.closePath();
  };
  const puff = (x, r) => {
    x.beginPath();
    for (const [dx, dy, rr] of [[-0.35, 0.15, 0.5], [0.3, 0.2, 0.48], [0, -0.25, 0.55], [0.05, 0.3, 0.45]]) (x.moveTo(dx * r + rr * r, dy * r), x.arc(dx * r, dy * r, rr * r, 0, TAU));
  };
  TEX = {
    flash: layered([["#fff", 1], ["#fff7c8", 0.55]], burst),
    fire: layered([["#e8401a", 1], ["#ff9a1a", 0.7], ["#fff27a", 0.4]], (x, r) => flameShape(x, r, 1)),
    smoke: layered([["#5a5460", 1], ["#8a8494", 0.6]], puff),
    smokeW: layered([["#c8c2cc", 1], ["#f4f0f6", 0.65]], puff),
    spark: cel(96, (x, h) => {
      const st = (r) => { x.beginPath(); for (let i = 0; i < 8; i++) { const a = (i / 8) * TAU, rr = i % 2 ? r * 0.18 : r; x.lineTo(Math.cos(a) * rr, Math.sin(a) * rr); } x.closePath(); };
      st(44); x.fillStyle = "#000"; x.fill(); st(34); x.fillStyle = "#fff"; x.fill();
    }),
    gold: glowTex([[0, "rgba(255,250,220,1)"], [0.3, "rgba(255,210,90,.9)"], [1, "rgba(255,170,40,0)"]]),
    mist: layered([["#cfe6ff", 1], ["#ffffff", 0.7]], puff),
    ink: layered([["#1a0424", 1], ["#3a0c4a", 0.5]], (x, r) => blob(x, r, 20, 0.3, 2)),
    purple: layered([["#6a1a9a", 1], ["#c050f0", 0.66], ["#ffd0ff", 0.34]], (x, r) => flameShape(x, r, 4)),
    aura: glowTex([[0, "rgba(120,200,255,.9)"], [0.5, "rgba(80,140,255,.5)"], [1, "rgba(60,80,255,0)"]]),
  };
  return TEX;
}

export class FX {
  constructor({ low = false } = {}) {
    this.low = low;
    this.max = low ? 260 : 700;
    this.parts = [];
    this.rings = [];
    this.chips = [];
    this.balls = [];
    this.fire = []; // fireworks shells and stars
    this.nums = [];
    this.trauma = 0;
    this.hitstop = 0;
    this.slow = 0; // slow-motion factor time left
    this.impact = []; // impact frames: { t, kind: 'white'|'invert'|'black' }
    this.flash = 0; this.flashCol = "255,255,255";
    this.n = 0;
    this.wind = 0;
    this.flyers = [];
    this.sfxs = [];
    this.waves = [];
    this.viewScale = 1;
  }
  // a thing handed across the deck: an image flown on an arc, spinning, then onArrive
  fly(img, from, to, { dur = 1.1, height = 260, spin = 0, scale = 0.5, glow = false, onArrive } = {}) {
    this.flyers.push({ img, from, to, dur, height, spin, scale, glow, onArrive, t: 0 });
  }
  rnd(i) { const s = Math.sin((this.n * 97.13 + i * 13.7) * 12.9898) * 43758.5453; return s - Math.floor(s); }
  sprite(kind, x, y, { s = 60, grow = 2, life = 0.6, vx = 0, vy = 0, g = 0, add = true, delay = 0, rot = 0, drag = 0, a = 1 } = {}) {
    if (this.parts.length >= this.max) this.parts.shift();
    this.parts.push({ kind, x, y, s, grow, life, age: -delay, vx, vy, g, add, rot, drag, a });
  }
  ring(x, y, { r = 300, life = 0.5, col = "255,240,200", w = 18, delay = 0, squash = 1 } = {}) {
    if (this.rings.length >= 8) this.rings.shift(); // a volley reads as one blast, not a moire
    this.rings.push({ x, y, r, life, age: -delay, col, w, squash });
  }
  chip(x, y, vx, vy, { col = "#6b3f22", s = 16, life = 1.4, g = 1600 } = {}) {
    if (this.chips.length >= this.max / 2) this.chips.shift();
    this.chips.push({ x, y, vx, vy, col, s, life, age: 0, g, spin: (Math.random() - 0.5) * 20, a: 0 });
  }
  shake(k) { this.trauma = Math.min(1, this.trauma + k); }
  stop(sec) { this.hitstop = Math.max(this.hitstop, sec); }
  impactFrames(seq) { let t = 0; for (const k of seq) this.impact.push({ at: t, kind: k }), (t += 1 / 30); this.impactT = 0; }
  screenFlash(a = 0.8, col = "255,255,255") { this.flash = Math.max(this.flash, a); this.flashCol = col; }
  number(x, y, v, { crit = false, col = null } = {}) {
    this.nums.push({ x, y, v, crit, col, age: 0, life: crit ? 1.3 : 0.9, vx: (Math.random() - 0.5) * 120 });
  }

  // a cannon shot: muzzle flash + smoke at the gun, a ball that flies an arc to the target
  cannon(from, to, { onHit, dur = 0.55, height = 260, big = false, gold = false, delay = 0 } = {}) {
    this.balls.push({ from, to, t: -delay, dur, height, onHit, big, gold, fired: false, trail: [] });
  }
  muzzle(x, y, dir = 1, s = 1) {
    this.n++;
    this.sprite("flash", x, y, { s: 90 * s, grow: 2.2, life: 0.16 });
    this.sprite("fire", x + dir * 40 * s, y, { s: 70 * s, grow: 1.8, life: 0.28 });
    for (let i = 0; i < (this.low ? 3 : 6); i++) this.sprite("smokeW", x + dir * 30 * s, y, { s: 60 * s, grow: 3.2, life: 1.6 + this.rnd(i), vx: dir * (120 + this.rnd(i + 3) * 160) * s, vy: -40 - this.rnd(i + 5) * 60, add: false, drag: 1.4, a: 0.9 });
  }
  explode(x, y, w = 1, { crit = false, deck = false, purple = false, rings = true } = {}) {
    this.n++;
    const vs = this.viewScale || 1; // big enough to read in the wide shot
    this.sprite("flash", x, y, { s: (120 + 60 * w) * (crit ? 1.5 : 1) * vs, grow: 2.4, life: 0.14 + 0.03 * w, add: false });
    this.sprite(purple ? "purple" : "fire", x, y, { s: (90 + 50 * w) * vs, grow: 2.2, life: 0.4 + 0.06 * w, add: false });
    if (crit) this.sprite("spark", x, y, { s: 260 * vs, grow: 1.4, life: 0.3, add: false });
    if (rings) for (let k = 0; k < (crit ? 3 : w >= 3 ? 2 : 1); k++) this.ring(x, y, { r: (200 + 110 * w) * vs, life: 0.36 + 0.06 * w + k * 0.12, delay: k * 0.07, w: (22 - k * 5) * vs });
    const nc = Math.round((5 + 4 * w) * (crit ? 1.5 : 1) * (this.low ? 0.5 : 1));
    const cols = deck ? ["#6b3f22", "#8e5a32", "#3c2212"] : purple ? ["#6a2488", "#e88ab8", "#2c0c3c"] : ["#3b3b46", "#5c5c6a", "#4a4a5e"];
    for (let i = 0; i < nc; i++) {
      const a = this.rnd(i) * TAU, sp = (500 + this.rnd(i + 11) * 700) * (1 + w * 0.2);
      this.chip(x, y, Math.cos(a) * sp * vs, (Math.sin(a) * sp - 500) * vs, { col: cols[i % 3], s: (14 + this.rnd(i + 5) * 20) * vs });
    }
    for (let i = 0; i < Math.round((4 + 3 * w) * (this.low ? 0.5 : 1)); i++) this.sprite("fire", x, y, { s: 22, grow: 0.5, life: 0.7 + 0.15 * w, vx: (this.rnd(i + 40) - 0.5) * 900, vy: -300 - this.rnd(i + 41) * 700, g: 1400, delay: this.rnd(i + 43) * 0.12 });
    for (let i = 0; i < Math.round((1 + w) * (this.low ? 0.6 : 1)); i++) this.sprite("smoke", x + (this.rnd(i + 60) - 0.5) * 80 * w, y, { s: (70 + 30 * w) * vs, grow: 2.4, life: 1.2 + 0.2 * w, vy: -80 - 30 * w, add: false, a: 0.8, delay: 0.05 * i });
    this.shake((0.16 + 0.08 * w) * (crit ? 1.3 : 1));
  }
  waterColumn(x, w = 1) {
    this.n++;
    w *= Math.sqrt(this.viewScale || 1);
    this.wave(x, w, (this.n % 2) * 2 - 1);
    for (let i = 0; i < (this.low ? 14 : 30); i++) {
      const a = this.rnd(i) * TAU, r = this.rnd(i + 7) * 40;
      this.chip(x + Math.cos(a) * r, SEA_Y, Math.cos(a) * 180, -(700 + this.rnd(i + 3) * 900) * w, { col: i % 3 ? "#eef6ff" : "#9fcfff", s: 18 * w, life: 1.4, g: 1500 });
    }
    for (let i = 0; i < 4; i++) this.sprite("mist", x, SEA_Y - 60 - i * 60 * w, { s: 180 * w, grow: 1.8, life: 1.2, add: false, vy: -80, delay: i * 0.06 });
    this.ring(x, SEA_Y + 10, { r: 320 * w, life: 0.8, col: "230,245,255", squash: 0.25 });
  }
  fireworks(cx, top, n = 3, { palette } = {}) {
    const P = palette || ["255,210,90", "255,245,220", "90,210,190", "230,70,60", "180,120,255", "120,200,255"];
    for (let k = 0; k < n; k++) {
      const x = cx + (k - (n - 1) / 2) * 520 + (this.rnd(k) - 0.5) * 200, y = top - this.rnd(k + 9) * 380;
      this.fire.push({ kind: "shell", x, y: SEA_Y + 40, tx: x, ty: y, age: -k * 0.28, life: 0.9, col: P[k % P.length], col2: P[(k + 2) % P.length], trail: [] });
    }
  }
  _burst(f) {
    const N = this.low ? 44 : 110;
    for (let i = 0; i < N; i++) {
      const a = (i / N) * TAU + this.rnd(i) * 0.1, sp = 620 + this.rnd(i + 4) * 460 * (i % 2 ? 1 : 0.6);
      this.fire.push({ kind: "star", x: f.x, y: f.y, vx: Math.cos(a) * sp, vy: Math.sin(a) * sp, age: 0, life: 1.6 + this.rnd(i) * 0.6, col: i % 3 ? f.col : f.col2, trail: [] });
    }
    this.sprite("flash", f.x, f.y, { s: 360, grow: 2, life: 0.35 });
  }
  update(dt, env) {
    this.hitstop = Math.max(0, this.hitstop - dt);
    this.slow = Math.max(0, this.slow - dt);
    this.flash = Math.max(0, this.flash - dt * 3.2);
    this.trauma = Math.max(0, this.trauma - dt * 1.3);
    if (this.impact.length) {
      this.impactT = (this.impactT || 0) + dt;
      this.impact = this.impact.filter((f) => this.impactT < f.at + 1 / 30);
    }
    for (let i = this.parts.length - 1; i >= 0; i--) {
      const p = this.parts[i];
      p.age += dt;
      if (p.age < 0) continue;
      if (p.age >= p.life) { this.parts.splice(i, 1); continue; }
      p.vy += p.g * dt;
      if (p.drag) (p.vx *= Math.exp(-p.drag * dt)), (p.vy *= Math.exp(-p.drag * dt));
      p.x += (p.vx + (p.add ? 0 : this.wind * 60)) * dt;
      p.y += p.vy * dt;
    }
    for (let i = this.rings.length - 1; i >= 0; i--) if ((this.rings[i].age += dt) > this.rings[i].life) this.rings.splice(i, 1);
    for (let i = this.chips.length - 1; i >= 0; i--) {
      const c = this.chips[i];
      c.age += dt;
      c.vy += c.g * dt;
      c.x += c.vx * dt;
      c.y += c.vy * dt;
      c.a += c.spin * dt;
      if (c.y > SEA_Y + 80 || c.age > c.life) this.chips.splice(i, 1);
    }
    for (let i = this.balls.length - 1; i >= 0; i--) {
      const b = this.balls[i];
      b.t += dt;
      if (b.t < 0) continue;
      const k = Math.min(1, b.t / b.dur);
      const e = k;
      b.x = b.from[0] + (b.to[0] - b.from[0]) * e;
      b.y = b.from[1] + (b.to[1] - b.from[1]) * e - Math.sin(Math.PI * e) * b.height;
      b.trail.push([b.x, b.y]);
      if (b.trail.length > 10) b.trail.shift();
      if (!this.low && Math.random() < 0.5) this.sprite("smokeW", b.x, b.y, { s: b.big ? 40 : 22, grow: 2, life: 0.5, add: false, a: 0.5 });
      if (k >= 1) { this.balls.splice(i, 1); b.onHit?.(b); }
    }
    for (let i = this.fire.length - 1; i >= 0; i--) {
      const f = this.fire[i];
      f.age += dt;
      if (f.age < 0) continue;
      if (f.kind === "shell") {
        const k = Math.min(1, f.age / f.life), e = 1 - (1 - k) ** 2;
        f.x = f.tx + Math.sin(f.age * 12) * 6;
        f.y = SEA_Y + 40 + (f.ty - SEA_Y - 40) * e;
        f.trail.push([f.x, f.y]);
        if (f.trail.length > 8) f.trail.shift();
        if (k >= 1) { this.fire.splice(i, 1); this._burst(f); }
      } else {
        f.vy += 260 * dt;
        f.vx *= Math.exp(-1.6 * dt);
        f.vy *= Math.exp(-1.6 * dt);
        f.x += f.vx * dt;
        f.y += f.vy * dt;
        f.trail.push([f.x, f.y]);
        if (f.trail.length > (this.low ? 3 : 6)) f.trail.shift();
        if (f.age > f.life) this.fire.splice(i, 1);
      }
    }
    for (let i = this.flyers.length - 1; i >= 0; i--) {
      const f = this.flyers[i];
      f.t += dt;
      if (f.t >= f.dur) { this.flyers.splice(i, 1); f.onArrive?.(); }
    }
    for (let i = this.sfxs.length - 1; i >= 0; i--) if ((this.sfxs[i].age += dt) > this.sfxs[i].life) this.sfxs.splice(i, 1);
    for (let i = this.waves.length - 1; i >= 0; i--) if ((this.waves[i].age += dt) > this.waves[i].life) this.waves.splice(i, 1);
    for (let i = this.nums.length - 1; i >= 0; i--) {
      const n = this.nums[i];
      n.age += dt;
      n.x += n.vx * dt;
      n.y -= 140 * dt * (1 - n.age / n.life);
      if (n.age > n.life) this.nums.splice(i, 1);
    }
  }
  drawFireworks(ctx, reflect = false) {
    ctx.save();
    ctx.globalCompositeOperation = "lighter";
    if (reflect) {
      ctx.translate(0, SEA_Y * 2 + 60);
      ctx.scale(1, -0.55);
      ctx.globalAlpha = 0.4;
    }
    for (const f of this.fire) {
      if (f.age < 0) continue;
      const a = f.kind === "star" ? Math.max(0, 1 - f.age / f.life) : 1;
      ctx.strokeStyle = `rgba(${f.col},${a * 0.7})`;
      ctx.lineWidth = f.kind === "shell" ? 8 : 6;
      ctx.beginPath();
      f.trail.forEach(([x, y], j) => (j ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
      ctx.stroke();
      const T = tex().spark;
      const s = f.kind === "shell" ? 50 : 30 * (0.6 + a * 0.6);
      ctx.fillStyle = `rgba(${f.col},${a * 0.55})`;
      ctx.beginPath();
      ctx.arc(f.x, f.y, s * 0.9, 0, TAU);
      ctx.fill();
      ctx.globalAlpha = (reflect ? 0.4 : 1) * a;
      ctx.drawImage(T, f.x - s / 2, f.y - s / 2, s, s);
      ctx.globalAlpha = reflect ? 0.4 : 1;
    }
    ctx.restore();
  }
  draw(ctx) {
    const T = tex();
    // debris
    // debris: sharp ink shards
    ctx.lineJoin = "miter";
    for (const c of this.chips) {
      ctx.save();
      ctx.translate(c.x, c.y);
      ctx.rotate(c.a);
      ctx.globalAlpha = Math.max(0, 1 - Math.max(0, c.age / c.life - 0.7) / 0.3);
      ctx.beginPath();
      ctx.moveTo(-c.s * 0.7, -c.s * 0.25);
      ctx.lineTo(c.s * 0.8, 0);
      ctx.lineTo(-c.s * 0.3, c.s * 0.35);
      ctx.closePath();
      ctx.fillStyle = c.col;
      ctx.fill();
      ctx.lineWidth = Math.max(2, c.s * 0.16);
      ctx.strokeStyle = "#000";
      ctx.stroke();
      ctx.restore();
    }
    // cannonballs with a streak
    for (const b of this.balls) {
      if (b.t < 0 || !b.trail.length) continue;
      ctx.strokeStyle = b.gold ? "rgba(255,210,90,.8)" : "rgba(255,240,220,.55)";
      ctx.lineWidth = b.big ? 28 : 12;
      ctx.lineCap = "round";
      ctx.beginPath();
      b.trail.forEach(([x, y], j) => (j ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
      ctx.stroke();
      ctx.fillStyle = b.gold ? "#ffd86a" : "#1c1c22";
      ctx.beginPath();
      ctx.arc(b.x, b.y, (b.big ? 34 : 18) * (this.viewScale || 1), 0, TAU);
      ctx.fill();
      ctx.strokeStyle = b.gold ? "#000" : "#fff";
      ctx.lineWidth = 4;
      ctx.stroke();
      if (b.gold) ctx.drawImage(T.gold, b.x - 120, b.y - 120, 240, 240);
    }
    // sprites: normal first, then additive
    for (const pass of [false, true]) {
      ctx.save();
      if (pass) ctx.globalCompositeOperation = "lighter";
      for (const p of this.parts) {
        if (p.age < 0 || p.add !== pass) continue;
        const k = p.age / p.life;
        const s = p.s * (1 + (p.grow - 1) * (1 - (1 - k) ** 3));
        ctx.globalAlpha = p.a * (k < 0.1 ? k / 0.1 : 1 - (k - 0.1) / 0.9);
        ctx.drawImage(T[p.kind] || T.flash, p.x - s / 2, p.y - s / 2, s, s);
      }
      ctx.restore();
    }
    // shockwave rings
    for (const r of this.rings) {
      if (r.age < 0) continue;
      const k = r.age / r.life, e = 1 - (1 - k) ** 3;
      // an inked shockwave: a black ring round a white one
      ctx.beginPath();
      ctx.ellipse(r.x, r.y, Math.max(1, r.r * e), Math.max(1, r.r * e * r.squash), 0, 0, TAU);
      ctx.strokeStyle = `rgba(0,0,0,${(1 - k) * 0.9})`;
      ctx.lineWidth = r.w * (1 - k * 0.6) + 8;
      ctx.stroke();
      ctx.strokeStyle = `rgba(${r.col},${(1 - k)})`;
      ctx.lineWidth = r.w * (1 - k * 0.6);
      ctx.stroke();
    }
  }
  drawFlyers(ctx) {
    for (const f of this.flyers) {
      const k = Math.min(1, f.t / f.dur), e = k < 0.5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2;
      const x = f.from[0] + (f.to[0] - f.from[0]) * e, y = f.from[1] + (f.to[1] - f.from[1]) * e - Math.sin(Math.PI * e) * f.height;
      ctx.save();
      ctx.translate(x, y);
      if (f.glow) ctx.drawImage(tex().gold, -110, -110, 220, 220);
      ctx.rotate(e * f.spin);
      const im = f.img;
      if (im) ctx.drawImage(im.im, (-im.w * f.scale) / 2, (-im.h * f.scale) / 2, im.w * f.scale, im.h * f.scale);
      ctx.restore();
    }
  }
  // hand-lettered SFX (onomatopoeia) that pop on impacts
  sfx(x, y, text, { col = "#fff", size = 1, rot = null } = {}) {
    if (this.sfxs.length > 12) this.sfxs.shift();
    this.sfxs.push({ x, y, text, col, size: size * (this.viewScale || 1), rot: rot ?? (this.rnd(this.sfxs.length + 3) - 0.5) * 0.5, age: 0, life: 0.9 });
  }
  // a ukiyo-e wave crest (Hokusai curl with claw foam) rising out of the sea
  wave(x, w = 1, dir = 1) {
    if (this.waves.length > 8) this.waves.shift();
    this.waves.push({ x, w: w * (this.viewScale || 1), dir, age: 0, life: 1.3 });
  }
  drawWaves(ctx) {
    for (const v of this.waves) drawCrest(ctx, v.x, SEA_Y + 30, 260 * v.w * Math.sin(Math.PI * Math.min(1, v.age / v.life)) + 1, v.dir);
  }
  drawNumbers(ctx) {
    for (const f of this.sfxs) {
      const k = f.age / f.life, pop = k < 0.1 ? 2 - k * 10 : 1;
      ctx.save();
      ctx.translate(f.x, f.y - k * 40);
      ctx.rotate(f.rot);
      ctx.scale(pop * f.size, pop * f.size);
      ctx.globalAlpha = k > 0.75 ? (1 - k) / 0.25 : 1;
      ctx.font = `400 150px 'Dela Gothic One', 'Hiragino Sans', sans-serif`;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.lineJoin = "round";
      ctx.lineWidth = 34;
      ctx.strokeStyle = "#000";
      ctx.strokeText(f.text, 0, 0);
      if (!this.low) (ctx.lineWidth = 12), (ctx.strokeStyle = "#fff"), ctx.strokeText(f.text, 0, 0);
      ctx.fillStyle = f.col;
      ctx.fillText(f.text, 0, 0);
      ctx.restore();
    }
    for (const n of this.nums) {
      const k = n.age / n.life;
      const pop = k < 0.12 ? 1 + (0.12 - k) * 6 : 1;
      ctx.save();
      ctx.translate(n.x, n.y);
      ctx.scale(pop, pop);
      ctx.globalAlpha = k > 0.7 ? (1 - k) / 0.3 : 1;
      ctx.scale(this.viewScale || 1, this.viewScale || 1);
      ctx.font = `italic 900 ${n.crit ? 110 : 70}px 'Barlow Semi Condensed', system-ui, sans-serif`;
      ctx.textAlign = "center";
      ctx.lineWidth = 14;
      ctx.strokeStyle = "#1c1016";
      ctx.strokeText(String(n.v), 0, 0);
      ctx.fillStyle = n.col || (n.crit ? "#ffd23a" : "#fff8ec");
      ctx.fillText(String(n.v), 0, 0);
      if (n.crit) {
        ctx.font = "italic 900 40px 'Barlow Semi Condensed', system-ui, sans-serif";
        ctx.strokeText("CRITICAL", 0, -92);
        ctx.fillStyle = "#ff6a3a";
        ctx.fillText("CRITICAL", 0, -92);
      }
      ctx.restore();
    }
  }
  get timeScale() { return this.hitstop > 0 ? 0 : this.slow > 0 ? 0.3 : 1; }
}

// the Hokusai crest: a curling body in two blues, a white foam lip with claw fingers,
// all inked. dir: +1 curls to the right, -1 to the left
export function drawCrest(ctx, x, y, h, dir = 1) {
  if (h < 4) return;
  ctx.save();
  ctx.translate(x, y);
  ctx.scale(dir, 1);
  ctx.lineJoin = "round";
  const body = () => {
    ctx.beginPath();
    ctx.moveTo(-h * 0.9, 0);
    ctx.bezierCurveTo(-h * 0.7, -h * 0.5, -h * 0.35, -h * 1.05, h * 0.15, -h * 1.0);
    ctx.bezierCurveTo(h * 0.55, -h * 0.95, h * 0.7, -h * 0.6, h * 0.45, -h * 0.45);
    ctx.bezierCurveTo(h * 0.3, -h * 0.35, h * 0.2, -h * 0.55, h * 0.3, -h * 0.62);
    ctx.bezierCurveTo(h * 0.1, -h * 0.5, h * 0.2, -h * 0.2, h * 0.7, 0);
    ctx.closePath();
  };
  body();
  ctx.fillStyle = "#1a3a8a";
  ctx.fill();
  ctx.save();
  body();
  ctx.clip();
  ctx.fillStyle = "#2f6ad0";
  ctx.beginPath();
  ctx.ellipse(-h * 0.2, -h * 0.35, h * 0.5, h * 0.3, -0.5, 0, TAU);
  ctx.fill();
  ctx.strokeStyle = "rgba(220,240,255,.8)";
  ctx.lineWidth = Math.max(2, h * 0.025);
  for (let i = 1; i < 4; i++) {
    ctx.beginPath();
    ctx.moveTo(-h * (0.85 - i * 0.12), -h * 0.05);
    ctx.bezierCurveTo(-h * (0.6 - i * 0.1), -h * (0.4 + i * 0.1), -h * 0.2, -h * (0.75 + i * 0.04), h * 0.1, -h * (0.8 + i * 0.03));
    ctx.stroke();
  }
  ctx.restore();
  ctx.strokeStyle = "#000";
  ctx.lineWidth = Math.max(3, h * 0.035);
  body();
  ctx.stroke();
  // the foam lip with its claw fingers
  ctx.fillStyle = "#fff";
  for (let i = 0; i < 7; i++) {
    const a = -Math.PI * 0.95 + i * 0.3, cx = h * 0.15 + Math.cos(a) * h * 0.42, cy = -h * 0.62 + Math.sin(a) * h * 0.38;
    ctx.beginPath();
    ctx.arc(cx, cy, h * 0.08, 0, TAU);
    ctx.moveTo(cx, cy);
    ctx.quadraticCurveTo(cx + h * 0.12, cy + h * 0.02, cx + h * 0.1, cy + h * 0.14);
    ctx.fill();
    ctx.stroke();
  }
  ctx.restore();
}
