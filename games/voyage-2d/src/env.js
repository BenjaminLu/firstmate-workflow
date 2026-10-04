// Sky and sea, painted in 2D layers with parallax: the sky gradient and sun, drifting
// clouds, far islands, the far sea band, the mid swell (behind the hull), the near swell
// and foam (in front of it). Weather springs drive colour, swell height and speed; the
// kraken's ultimate turns the sky crimson and spins a whirlpool.
const lerp = (a, b, k) => a + (b - a) * k;
const mix = (c1, c2, k) => c1.map((v, i) => Math.round(lerp(v, c2[i], k)));
const rgb = (c, a = 1) => `rgba(${c[0]},${c[1]},${c[2]},${a})`;

export const SEA_Y = 150; // the waterline at the hull, world units (deck at 0, up is -y)

const PAL = {
  day: { top: [58, 92, 190], mid: [128, 170, 236], hor: [255, 190, 132], sea: [22, 86, 190], seaD: [10, 40, 120], foam: [236, 246, 255], sun: [255, 226, 160] },
  squall: { top: [26, 30, 52], mid: [52, 60, 88], hor: [96, 104, 126], sea: [22, 44, 80], seaD: [8, 18, 40], foam: [196, 210, 226], sun: [160, 170, 190] },
  ult: { top: [40, 6, 30], mid: [120, 18, 48], hor: [255, 90, 60], sea: [60, 14, 60], seaD: [20, 4, 30], foam: [255, 190, 200], sun: [255, 120, 80] },
  night: { top: [8, 12, 40], mid: [30, 30, 90], hor: [120, 70, 130], sea: [10, 24, 70], seaD: [4, 8, 30], foam: [200, 210, 255], sun: [255, 230, 190] },
};

export class Env {
  constructor({ low = false } = {}) {
    this.low = low;
    this.t = 0;
    this.storm = 0; // 0..1 squall
    this.ult = 0; // 0..1 the kraken's maelstrom
    this.night = 0; // 0..1 victory night for fireworks
    this.clearing = 0; // god rays
    this.swell = 0.5;
    this.speed = 0.35; // sailing speed (the sea scrolls left)
    this.scroll = 0;
    this.whirl = 0; // whirlpool strength
    this.whirlX = 1500;
    this.lightning = 0;
    this.clouds = Array.from({ length: low ? 6 : 11 }, (_, i) => ({ x: (i * 997) % 6000 - 3000, y: -1500 - ((i * 331) % 700), s: 0.6 + ((i * 7) % 5) / 6, p: 0.15 + ((i * 13) % 7) / 30 }));
    this.gulls = Array.from({ length: 4 }, (_, i) => ({ x: -600 + i * 400, y: -1200 - i * 120, ph: i }));
    this.islands = [{ x: -2600, w: 900, h: 260 }, { x: 2400, w: 1300, h: 340, lighthouse: true }, { x: 5200, w: 700, h: 200 }];
    this.k = 1; // the sky's scale: the clouds, the sun and the far islands keep their place round a big ship
  }
  pal() {
    let p = mixPal(PAL.day, PAL.squall, this.storm);
    p = mixPal(p, PAL.ult, this.ult);
    p = mixPal(p, PAL.night, this.night);
    return p;
  }
  update(dt) {
    this.t += dt;
    this.scroll += dt * (60 + this.speed * 220);
    this.whirl += (this.ult - this.whirl) * Math.min(1, dt * 1.5);
    this.lightning = Math.max(0, this.lightning - dt * 3);
    if ((this.storm > 0.6 || this.ult > 0.5) && Math.random() < dt * 0.25) this.lightning = 1;
  }
  // the sea surface height at world x (for the ship's bob and spray)
  waveAt(x, layer = 1) {
    const t = this.t, s = this.scroll, A = (26 + this.swell * 34 + this.storm * 40 + this.ult * 30) * layer;
    return A * (0.55 * Math.sin((x + s) * 0.0042 + t * 0.9) + 0.3 * Math.sin((x + s * 1.3) * 0.009 - t * 1.4) + 0.15 * Math.sin((x + s * 0.7) * 0.021 + t * 2.1));
  }
  // camera view rectangle in world units: { x0, x1, y0, y1 }
  drawSky(ctx, v, cam) {
    const p = this.pal();
    const g = ctx.createLinearGradient(0, v.y0, 0, SEA_Y);
    g.addColorStop(0, rgb(p.top));
    g.addColorStop(0.55, rgb(p.mid));
    g.addColorStop(1, rgb(p.hor));
    ctx.fillStyle = g;
    ctx.fillRect(v.x0, v.y0, v.x1 - v.x0, SEA_Y - v.y0 + 40);
    // stars at night
    if (this.night > 0.05) {
      ctx.fillStyle = `rgba(255,255,255,${this.night * 0.8})`;
      for (let i = 0; i < 90; i++) {
        const x = v.x0 + ((i * 7919) % 1000) / 1000 * (v.x1 - v.x0), y = v.y0 + ((i * 104729) % 1000) / 1000 * (SEA_Y - v.y0) * 0.7;
        const tw = 0.5 + 0.5 * Math.sin(this.t * 2 + i);
        ctx.fillRect(x, y, 2.4 * tw + 0.6, 2.4 * tw + 0.6);
      }
    }
    // the sun (parallax: it barely moves with the camera)
    const K = this.k, sx = cam.x * 0.92 - 900 * K, sy = -520 * K + cam.y * 0.9;
    const sun = ctx.createRadialGradient(sx, sy, 0, sx, sy, 900 * K);
    sun.addColorStop(0, rgb(p.sun, 0.95 * (1 - this.night)));
    sun.addColorStop(0.08, rgb(p.sun, 0.75 * (1 - this.night)));
    sun.addColorStop(0.3, rgb(p.hor, 0.25 * (1 - this.storm)));
    sun.addColorStop(1, rgb(p.hor, 0));
    ctx.fillStyle = sun;
    ctx.fillRect(sx - 900 * K, sy - 900 * K, 1800 * K, 1800 * K);
    // crepuscular rays in the clearing
    if (this.clearing > 0.02) {
      ctx.save();
      ctx.globalCompositeOperation = "lighter";
      for (let i = 0; i < 9; i++) {
        const a = -0.35 + i * 0.13 + Math.sin(this.t * 0.2 + i) * 0.02;
        ctx.fillStyle = `rgba(255,220,150,${0.06 * this.clearing})`;
        ctx.beginPath();
        ctx.moveTo(sx, sy);
        ctx.lineTo(sx + Math.cos(a) * 5000, sy + Math.sin(a) * 5000 + 2500);
        ctx.lineTo(sx + Math.cos(a + 0.05) * 5000, sy + Math.sin(a + 0.05) * 5000 + 2500);
        ctx.fill();
      }
      ctx.restore();
    }
    // clouds: soft stacks of puffs, parallax by depth
    for (const c of this.clouds) {
      const P = 7000 * K, x = ((((c.x * K - this.scroll * c.p * 0.2 - cam.x * (1 - c.p)) % P) + P) % P) - P / 2 + cam.x;
      const y = c.y * K + cam.y * (1 - c.p) * 0.5;
      drawCloud(ctx, x, y, 260 * c.s * Math.sqrt(K), this.storm, this.ult, p);
    }
    if (this.lightning > 0.01) {
      ctx.fillStyle = `rgba(230,220,255,${this.lightning * 0.35})`;
      ctx.fillRect(v.x0, v.y0, v.x1 - v.x0, v.y1 - v.y0);
      if (this.lightning > 0.8) {
        ctx.strokeStyle = `rgba(255,255,255,${this.lightning})`;
        ctx.lineWidth = 6;
        ctx.beginPath();
        let x = cam.x + 800 + Math.sin(this.t * 13) * 600, y = v.y0;
        ctx.moveTo(x, y);
        while (y < SEA_Y - 300) (x += (Math.sin(y * 0.37 + this.t * 50) * 120)), (y += 140), ctx.lineTo(x, y);
        ctx.stroke();
      }
    }
    // gulls
    if (this.storm < 0.5 && this.ult < 0.3) {
      ctx.strokeStyle = "rgba(40,40,60,.75)";
      ctx.lineWidth = 5;
      for (const g2 of this.gulls) {
        const x = ((g2.x + this.t * 60 - cam.x * 0.3) % 3000) + cam.x * 0.3 - 1500, y = g2.y * Math.sqrt(K) + Math.sin(this.t + g2.ph) * 30, f = Math.sin(this.t * 6 + g2.ph) * 14;
        ctx.beginPath();
        ctx.moveTo(x - 34, y - f);
        ctx.quadraticCurveTo(x - 14, y - 16, x, y);
        ctx.quadraticCurveTo(x + 14, y - 16, x + 34, y - f);
        ctx.stroke();
      }
    }
  }
  drawFar(ctx, v, cam) {
    const p = this.pal();
    // islands on the horizon (parallax 0.25)
    const K = this.k;
    for (const is of this.islands) {
      const x = is.x * K - this.scroll * 0.08 + cam.x * 0.75, P = 9000 * K;
      const wx = ((((x - cam.x) % P) + P) % P) - P / 2 + cam.x;
      ctx.fillStyle = rgb(mix(mix(p.hor, [60, 70, 110], 0.6), [20, 20, 40], this.night), 0.95);
      ctx.beginPath();
      ctx.moveTo(wx - is.w / 2, SEA_Y - 50);
      ctx.bezierCurveTo(wx - is.w * 0.3, SEA_Y - 50 - is.h, wx + is.w * 0.1, SEA_Y - 50 - is.h * 1.2, wx + is.w / 2, SEA_Y - 50);
      ctx.fill();
      if (is.lighthouse) {
        ctx.fillStyle = rgb(mix([240, 230, 220], [40, 40, 60], this.night * 0.6));
        ctx.fillRect(wx + 60, SEA_Y - 50 - is.h * 1.15 - 160, 40, 170);
        ctx.fillStyle = `rgba(255,220,120,${0.6 + 0.4 * Math.sin(this.t * 2)})`;
        ctx.fillRect(wx + 56, SEA_Y - 50 - is.h * 1.15 - 190, 48, 30);
      }
    }
    // the far sea band
    const g = ctx.createLinearGradient(0, SEA_Y - 60, 0, v.y1);
    g.addColorStop(0, rgb(mix(p.hor, p.sea, 0.55)));
    g.addColorStop(0.25, rgb(p.sea));
    g.addColorStop(1, rgb(p.seaD));
    ctx.fillStyle = g;
    ctx.fillRect(v.x0, SEA_Y - 60, v.x1 - v.x0, v.y1 - SEA_Y + 60);
    // glints on the far water
    ctx.fillStyle = rgb(p.sun, 0.35 * (1 - this.storm) * (1 - this.night));
    for (let i = 0; i < (this.low ? 20 : 50); i++) {
      const gx = cam.x * 0.92 - 900 + ((i * 373 + this.scroll * 0.3) % 1600) - 800, gy = SEA_Y - 40 + ((i * 97) % 90);
      ctx.fillRect(gx, gy, 30 + ((i * 13) % 40), 3);
    }
    // the whirlpool of the maelstrom
    if (this.whirl > 0.02) {
      ctx.save();
      ctx.translate(this.whirlX, SEA_Y + 20);
      ctx.scale(1, 0.22);
      for (let r = 80; r < 1400; r += 70) {
        ctx.strokeStyle = `rgba(${r % 140 ? "255,120,160" : "30,0,40"},${this.whirl * 0.45 * (1 - r / 1500)})`;
        ctx.lineWidth = 26;
        ctx.beginPath();
        const a0 = this.t * (4 - r / 500) + r * 0.01;
        ctx.arc(0, 0, r, a0, a0 + Math.PI * 1.3);
        ctx.stroke();
      }
      ctx.restore();
    }
  }
  _band(ctx, v, y0, amp, layer, fill, foam, foamW = 6) {
    const step = this.low ? 60 : 36;
    ctx.beginPath();
    ctx.moveTo(v.x0 - 50, v.y1 + 50);
    for (let x = v.x0 - 50; x <= v.x1 + 50; x += step) ctx.lineTo(x, y0 + this.waveAt(x * layer + layer * 400, amp));
    ctx.lineTo(v.x1 + 50, v.y1 + 50);
    ctx.closePath();
    ctx.fillStyle = fill;
    ctx.fill();
    if (foam) {
      ctx.strokeStyle = foam;
      ctx.lineWidth = foamW;
      ctx.beginPath();
      for (let x = v.x0 - 50; x <= v.x1 + 50; x += step) {
        const y = y0 + this.waveAt(x * layer + layer * 400, amp);
        x === v.x0 - 50 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
      }
      ctx.stroke();
    }
  }
  drawMid(ctx, v) {
    const p = this.pal();
    this._band(ctx, v, SEA_Y - 10, 0.7, 0.8, rgb(mix(p.sea, p.foam, 0.08)), rgb(p.foam, 0.35), 5);
  }
  drawNear(ctx, v) {
    const p = this.pal();
    const g = ctx.createLinearGradient(0, SEA_Y + 60, 0, v.y1 + 50);
    g.addColorStop(0, rgb(mix(p.sea, p.foam, 0.12)));
    g.addColorStop(1, rgb(p.seaD));
    this._band(ctx, v, SEA_Y + 70, 1, 1.25, g, rgb(p.foam, 0.85), 9);
    // foam flecks riding the near crest
    ctx.fillStyle = rgb(p.foam, 0.7);
    const step = this.low ? 140 : 80;
    for (let x = Math.floor(v.x0 / step) * step; x < v.x1; x += step) {
      const y = SEA_Y + 70 + this.waveAt(x * 1.25 + 500, 1);
      const k = Math.sin(x * 0.07 + this.t * 3);
      if (k > 0.3) ctx.fillRect(x + k * 20, y + 10 + k * 8, 14, 6);
    }
    // the second, lowest swell
    this._band(ctx, v, SEA_Y + 190, 1.2, 1.6, rgb(mix(p.seaD, p.sea, 0.35)), rgb(p.foam, 0.55), 7);
  }
}

function mixPal(a, b, k) {
  if (k <= 0) return a;
  const o = {};
  for (const key of Object.keys(a)) o[key] = mix(a[key], b[key], Math.min(1, k));
  return o;
}
function drawCloud(ctx, x, y, s, storm, ult, p) {
  const base = mix(mix([255, 236, 226], [110, 116, 140], storm), [150, 50, 80], ult);
  const shade = mix(mix([226, 170, 196], [70, 74, 100], storm), [90, 20, 50], ult);
  ctx.fillStyle = rgb(shade, 0.9);
  for (const [dx, dy, r] of [[-0.9, 0.25, 0.55], [0, 0.3, 0.6], [0.9, 0.25, 0.5]]) {
    ctx.beginPath();
    ctx.arc(x + dx * s, y + dy * s, r * s, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.fillStyle = rgb(base, 0.95);
  for (const [dx, dy, r] of [[-0.6, 0, 0.5], [0.1, -0.25, 0.62], [0.75, 0.05, 0.45], [-0.1, 0.12, 0.5]]) {
    ctx.beginPath();
    ctx.arc(x + dx * s, y + dy * s, r * s, 0, Math.PI * 2);
    ctx.fill();
  }
}
