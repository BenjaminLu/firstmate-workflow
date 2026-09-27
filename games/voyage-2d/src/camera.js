// A virtual 2D camera with a cinematographer's habits: shots are framings (a centre,
// a view height in world units, a dutch angle), reached by a critically damped glide or
// a hard cut; hits add a punch-in that springs back; trauma adds shake (squared, so
// small knocks barely move it and big ones snap); the slow push-in keeps a held shot
// alive. Portrait screens widen the framing so the subject still fits across.
const lerp = (a, b, k) => a + (b - a) * k;

class Glide {
  constructor(v, k = 18) { this.x = v; this.v = 0; this.k = k; }
  step(t, dt, k = this.k) {
    const c = 2 * Math.sqrt(k);
    this.v += (-k * (this.x - t) - c * this.v) * dt;
    this.x += this.v * dt;
    return this.x;
  }
  snap(v) { this.x = v; this.v = 0; }
}

export class Camera {
  constructor() {
    this.x = new Glide(0); this.y = new Glide(-400); this.h = new Glide(2400); this.rot = new Glide(0);
    this.punch = new Glide(1, 260);
    this.punchT = 1;
    this.shot = null; this.until = 0; this.def = null;
    this.k = 12;
    this.t = 0;
    this.W = 1; this.H = 1;
    this.push = 0; this.cutAt = 0;
  }
  resize(W, H) { this.W = W; this.H = H; }
  get aspect() { return this.W / this.H; }
  // a framing: { x, y, h, w? (a width that must fit), rot? }
  frame(f) {
    let h = f.h;
    // portrait screens keep the middle nine tenths of a wide frame (the bigger ships stay whole)
    const w = f.w ? (this.aspect < 1 ? f.w * 0.9 : f.w) : this.aspect < 1 ? f.h * 0.8 : 0;
    if (w) h = Math.max(h, w / this.aspect);
    return { x: f.x, y: f.y, h, rot: f.rot || 0 };
  }
  go(f, { cut = false, k = 12, hold = 0, push = 0.06 } = {}) {
    const F = this.frame(f);
    this.def = F;
    this.k = k;
    this.pushAmt = push;
    this.cutAt = this.t;
    this.until = hold ? this.t + hold : 0;
    if (cut) this.x.snap(F.x), this.y.snap(F.y), this.h.snap(F.h), this.rot.snap(F.rot);
  }
  kick(zoom = 1.08) { this.punch.x = zoom; this.punch.v = 0; }
  update(dt, fx) {
    this.t += dt;
    const F = this.def;
    if (!F) return;
    const pushK = 1 - (this.pushAmt || 0) * Math.min(1, (this.t - this.cutAt) / 4); // the slow push-in
    this.x.step(F.x, dt, this.k);
    this.y.step(F.y, dt, this.k);
    this.h.step(F.h * pushK, dt, this.k);
    this.rot.step(F.rot, dt, this.k * 0.6);
    this.punch.step(1, dt);
    const tr = fx.trauma * fx.trauma;
    const n = (s) => { const v = Math.sin(this.t * 41.3 * 12.9898 + s * 78.233) * 43758.5453; return (v - Math.floor(v)) * 2 - 1; };
    this.sx = tr * 60 * n(1);
    this.sy = tr * 60 * n(2);
    this.sr = tr * 0.05 * n(3);
  }
  get zoom() { return (this.H / this.h.x) * this.punch.x; }
  apply(ctx) {
    const z = this.zoom;
    ctx.translate(this.W / 2, this.H / 2);
    ctx.rotate(this.rot.x + (this.sr || 0));
    ctx.scale(z, z);
    ctx.translate(-this.x.x + (this.sx || 0), -this.y.x + (this.sy || 0));
  }
  view() {
    const z = this.zoom, hw = this.W / 2 / z + 200, hh = this.H / 2 / z + 200;
    return { x0: this.x.x - hw, x1: this.x.x + hw, y0: this.y.x - hh, y1: this.y.x + hh };
  }
  toScreen(wx, wy) {
    const z = this.zoom, c = Math.cos(this.rot.x), s = Math.sin(this.rot.x);
    const dx = (wx - this.x.x) * z, dy = (wy - this.y.x) * z;
    return [this.W / 2 + dx * c - dy * s, this.H / 2 + dx * s + dy * c];
  }
}
export { lerp };
