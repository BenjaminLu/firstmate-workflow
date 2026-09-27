// 2.5D crew: v3's approved crewmen, baked into cutout layers (bake/bake.js), rebuilt here
// as a 2D puppet and driven by v3's own motion tables (crew-motion.js).
//
// The puppet is a small bone tree in character space (pixels at bake scale, origin at the
// feet, y down): hips -> torso -> head / arms -> forearms -> hands, hips -> legs, plus the
// hanging danglers on springs. v3's 3D joint channels ([x, y, z] degrees) become 2D turns:
// in the three-quarter view a forward swing (x) is the visible turn and the side swing (z)
// shows at 40 %; in the front view it is the other way round, and a forward swing
// foreshortens the limb instead. Every channel runs through a spring, so poses overshoot
// and settle the way v3's do; squash, bob, the promotion spin (a paper-flip turn) and
// the head's glance to camera (a swap to the front head) finish the 2.5D read.
import { evalShot, SHOTS as V3SHOTS, LOOPS } from "../v3src/game/crew-motion.js";
import { EXTRA_SHOTS } from "./shots.js";

export const SHOTS = { ...V3SHOTS, ...EXTRA_SHOTS };
const D = Math.PI / 180;
const CH3 = ["rs", "re", "ls", "le", "torso", "head", "rl", "ll", "pelvis"];
const CH1 = ["y", "ik", "yaw", "march", "sq"];
const STIFF = { rs: 520, re: 560, ls: 520, le: 560, torso: 360, head: 240, rl: 420, ll: 420, pelvis: 360, y: 520, ik: 420, yaw: 300, march: 300, sq: 600 };
const lerp = (a, b, k) => a + (b - a) * k;
const smooth = (k) => (k <= 0 ? 0 : k >= 1 ? 1 : k * k * (3 - 2 * k));
// the whole crew's motion switches: reduced motion (prefers-reduced-motion) keeps the walk but
// with a smaller bob and no squash, stretch or squash turn
export const MOTION = { reduced: false };
// the walk (Animal Crossing's soft bounce, drawn in the baked blocks): one footfall per
// STRIDE x the character's height of ground covered, so the cadence follows the speed
export const WALK = { stride: 0.36, full: 150, turn: 0.14 };

// props: where the grip sits in the baked sprite (0..1) and the angle that makes the
// prop point "along the forearm" (down the hand) in the rest pose
export const PROP_GRIP = {
  cutlass: { gx: 0.5, gy: 0.12, a: 0 },
  spyglass: { gx: 0.22, gy: 0.5, a: -90 },
  hammer: { gx: 0.5, gy: 0.9, a: 180 },
  magnifier: { gx: 0.5, gy: 0.9, a: 180 },
  map: { gx: 0.3, gy: 0.5, a: 0 },
  scroll: { gx: 0.5, gy: 0.5, a: 0 },
  stamp: { gx: 0.5, gy: 0.15, a: 0 },
  whistle: { gx: 0.2, gy: 0.5, a: -90 },
  flag: { gx: 0.05, gy: 0.5, a: -90 },
  swab: { gx: 0.5, gy: 0.2, a: 0 },
  saw: { gx: 0.5, gy: 0.1, a: 0 },
  logbook: { gx: 0.5, gy: 0.5, a: 0 },
  criteriaList: { gx: 0.5, gy: 0.1, a: 0 },
  crate: { gx: 0.5, gy: 0.5, a: 0 },
  laptop: { gx: 0.5, gy: 0.6, a: 0 },
};

// the held angle of each prop relative to "along the forearm" when a table gives none
export const PROP_REST = { cutlass: -70, spyglass: 0, hammer: -80, magnifier: -60, map: 0, scroll: 0, stamp: 0, whistle: 0, flag: -90, swab: 60, saw: -10, logbook: 0, criteriaList: -90, quill: -30 };

class Spring3 {
  constructor(k, v) { this.k = k; this.x = v.slice(); this.v = [0, 0, 0]; }
  step(t, dt) {
    const c = 2 * Math.sqrt(this.k) * 0.66;
    for (let i = 0; i < 3; i++) {
      this.v[i] += (-this.k * (this.x[i] - t[i]) - c * this.v[i]) * dt;
      this.x[i] += this.v[i] * dt;
    }
    return this.x;
  }
}
class Spring1 {
  constructor(k, v, z = 0.7) { this.k = k; this.x = v; this.v = 0; this.z = z; }
  step(t, dt) {
    this.v += (-this.k * (this.x - t) - 2 * Math.sqrt(this.k) * this.z * this.v) * dt;
    this.x += this.v * dt;
    return this.x;
  }
}

// 2D affine: [a b c d e f] (canvas order)
const mul = (m, n) => [m[0] * n[0] + m[2] * n[1], m[1] * n[0] + m[3] * n[1], m[0] * n[2] + m[2] * n[3], m[1] * n[2] + m[3] * n[3], m[0] * n[4] + m[2] * n[5] + m[4], m[1] * n[4] + m[3] * n[5] + m[5]];
const about = (px, py, a, sx = 1, sy = 1) => {
  const c = Math.cos(a), s = Math.sin(a);
  // T(p) R(a) S T(-p)
  const m = [c * sx, s * sx, -s * sy, c * sy, 0, 0];
  m[4] = px - (m[0] * px + m[2] * py);
  m[5] = py - (m[1] * px + m[3] * py);
  return m;
};
const apply = (m, x, y) => [m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]];

export class Puppet {
  constructor(id, bake, images, { props = {}, scale = 0.28 } = {}) {
    this.id = id;
    this.bake = bake; // bake.crew[id]
    this.img = images; // same shape as bake, with Image objects in place of data URIs
    this.propImg = props;
    this.scale = scale; // screen px per baked px at camera zoom 1
    this.view = "q";
    this.dir = 1; // +1 faces screen right
    this.x = 0; this.y = 0; // stage position (feet)
    this.clock = 0;
    this.loop = "idle"; this.loopStart = 0; this.prev = null; this.phase = (id.length * 0.37) % 1;
    this.shots = [];
    this.expr = bake.expressions[0];
    this.lockExpr = null;
    this.springs = {};
    for (const c of CH3) this.springs[c] = new Spring3(STIFF[c], [0, 0, 0]);
    for (const c of CH1) this.springs[c] = new Spring1(STIFF[c], c === "sq" ? 1 : 0);
    this.dangle = {};
    this.walk = null; this.walkPhase = 0; this.locoW = 0;
    // the walk's own state: the ground speed the world reports (locoSpeed, ship px/s), smoothed
    // by a critically damped spring (spd, spdV); the facing actually drawn (face) and the squash
    // turn's progress (turnK, 0..1)
    this.locoSpeed = 0; this.spd = 0; this.spdV = 0;
    this.face = null; this.turnK = 1;
    this.onCue = null;
    this.tint = null; // { color, a } rim / flash tint
    this.flash = 0;
    this.heroic = 0; // 0..1: hero lighting (rim glow)
    this.lastPose = {};
    this.propR = null; this.propL = null; this.propHeld = null;
    this.glance = 0; // 0..1: the head turns to camera
    this.alpha = 1;
    this.handBlend = {};
    this.workProp = null; // a prop carried at the chest while the hands are free (the robot's laptop)
  }
  get height() { return this.bake.height * this.scale; }
  setLoop(name) {
    if (!LOOPS[name]) name = "idle";
    if (name === this.loop) return;
    this.prev = { name: this.loop, start: this.loopStart, at: this.clock };
    this.loop = name; this.loopStart = this.clock;
  }
  shot(name, delay = 0) {
    const d = SHOTS[name];
    if (!d) return;
    this.shots = this.shots.filter((s) => s.name !== name);
    this.shots.push({ name, start: this.clock + delay, dur: d.dur / 1000, last: -1 });
  }
  clearShot(name) { this.shots = this.shots.filter((s) => s.name !== name); }
  walkTo(x, dur = 1.6, after) {
    this.walk = { from: this.x, to: x, t: 0, dur: Math.max(0.3, dur), after };
    if (Math.abs(x - this.x) > 1) this.dir = x > this.x ? 1 : -1;
  }
  setExpr(e) { if (this.bake.expressions.includes(e)) this.expr = e; }

  _loopPose(name, start, t) {
    const L = LOOPS[name] || LOOPS.idle;
    const ph = ((((t - start) / L.T + this.phase) % 1) + 1) % 1;
    const p = { ...L.pose(ph, t) };
    if (L.hr && !p.hr) p.hr = L.hr;
    if (L.prop) p.prop = L.prop;
    return p;
  }
  update(dt) {
    this.clock += dt;
    const t = this.clock;
    // the ground speed: the world walks him along the decks (the crowd), or a scripted walkTo
    let target = this.locoExt ? this.locoSpeed || 0 : 0;
    if (this.walk) {
      const w = this.walk;
      w.t += dt;
      const k = Math.min(1, w.t / w.dur), e = k * k * (3 - 2 * k);
      const nx = lerp(w.from, w.to, e);
      target = dt > 0 ? Math.abs(nx - this.x) / dt : 0;
      this.x = nx;
      if (k >= 1) { this.walk = null; w.after?.(); }
    }
    this._gait(Math.min(600, target), dt);
    let pose = this._loopPose(this.loop, this.loopStart, t);
    if (this.prev) {
      const k = (t - this.prev.at) / 0.3;
      if (k >= 1) this.prev = null;
      else pose = blend(this._loopPose(this.prev.name, this.prev.start, t), pose, smooth(k));
    }
    // the walk takes over the limbs (and the loop's head and hips) as the gait comes in; the
    // loop fades back in as he stops
    if (this.locoW > 0.01) pose = blend(pose, this._walkPose(), this.locoW);
    let prop = pose.prop || null;
    for (const s of this.shots) {
      if (t < s.start) continue;
      const ms = (t - s.start) * 1000, def = SHOTS[s.name];
      if (ms >= def.dur) continue;
      const o = evalShot(def, ms);
      pose = blend(pose, o, o.w);
      if (def.prop && o.w > 0.3) prop = def.prop;
      if (def.expr && o.w > 0.3 && !this.lockExpr) this.expr = this.bake.expressions.includes(def.expr) ? def.expr : this.expr;
      for (const [at, name] of def.cues || []) if (at > s.last && at <= ms) this.onCue?.(name, this);
      s.last = ms;
    }
    this.shots = this.shots.filter((s) => t < s.start + s.dur);
    this.pose = pose;
    this.prop = prop;
    const sdt = Math.min(dt, 1 / 30) / 2;
    const out = {};
    for (let i = 0; i < 2; i++) {
      for (const c of CH3) out[c] = this.springs[c].step(pose[c] || [0, 0, 0], sdt);
      for (const c of CH1) out[c] = this.springs[c].step(pose[c] ?? (c === "sq" ? 1 : 0), sdt);
    }
    out.hr = pose.hr; out.hl = pose.hl;
    this.cur = out;
    // danglers: driven by the torso's and head's angular velocity and the bob
    const drive = (out.torso[0] - (this.lastPose.torso ?? out.torso[0])) / Math.max(dt, 1e-3) + (out.y - (this.lastPose.y ?? out.y)) * 30 / Math.max(dt, 1e-3) + this.dir * Math.min(40, this.spd * 0.15);
    this.lastPose.torso = out.torso[0]; this.lastPose.y = out.y;
    for (const k of ["sashTails", "kerchiefTails", "ribbons", "fringe_l", "fringe_r"]) {
      const s = (this.dangle[k] ||= new Spring1(k.startsWith("fringe") ? 60 : 30, 0, 0.18));
      s.v += -drive * 0.004 * (k === "ribbons" ? 1.4 : 1);
      s.step(Math.sin(t * 1.3 + k.length) * 0.05, Math.min(dt, 1 / 30));
      s.x = Math.max(-0.9, Math.min(0.9, s.x));
    }
    this.flash = Math.max(0, this.flash - dt * 4);
    for (const hb of Object.values(this.handBlend)) hb.t += dt / 0.09;
    // turning: a quick squash turn (the body narrows, flips at the middle and springs back)
    // instead of an instant mirror
    if (this.face == null) this.face = this.dir;
    if (this.dir !== this.face) {
      this.face = this.dir;
      if (!MOTION.reduced && dt > 0) (this.turnK = 0), (this.springs.sq.v += 2.2);
    }
    this.turnK = Math.min(1, this.turnK + dt / WALK.turn);
  }
  // the gait: the ground speed through a critically damped spring (ease in, ease out), the
  // walk cycle advanced by the ground covered, and on stopping the stride finishes to the
  // feet-together pose instead of freezing mid-step
  _gait(target, dt) {
    const w = 8;
    for (let left = dt; left > 1e-6;) {
      const h = Math.min(left, 1 / 120);
      left -= h;
      this.spdV += (w * w * (target - this.spd) - 2 * w * this.spdV) * h;
      this.spd = Math.max(0, this.spd + this.spdV * h);
    }
    const stride = Math.max(40, this.bake.height * this.scale * WALK.stride);
    this.walkPhase += (this.spd * dt) / stride;
    if (target < 1 && this.spd < WALK.full * 0.5) {
      const n = Math.round(this.walkPhase);
      this.walkPhase += (n - this.walkPhase) * Math.min(1, dt * 8);
    }
    // the loop hands over to the walk (and back) over about a quarter second, whatever the jolt
    const want = smooth(this.spd / WALK.full);
    this.locoW += Math.max(-dt / 0.3, Math.min(dt / 0.25, want - this.locoW));
  }
  // the walk pose at this point of the cycle: legs and arms in opposition (the arms a touch
  // behind the legs, in a small arc), a soft bob with a squash on each footfall and a stretch
  // as he passes over the foot, a lean into the walk (more while speeding up), the head nodding
  // a beat after the body
  _walkPose() {
    const R = MOTION.reduced, ph = this.walkPhase * Math.PI;
    const k = Math.max(0.45, Math.min(1, this.spd / 280));
    const s = Math.sin(ph), sa = Math.sin(ph - 0.35), c2 = Math.cos(ph) ** 2, s2 = s * s;
    const lag = Math.sin(ph - 0.9) ** 2;
    const lean = 5 + 4 * k + Math.max(-3, Math.min(4, this.spdV * 0.006));
    return {
      rs: [22 * k * sa, 0, -7], ls: [-22 * k * sa, 0, 7],
      re: [-24 - 8 * k * Math.max(0, sa), 0, 0], le: [-24 - 8 * k * Math.max(0, -sa), 0, 0],
      rl: [-26 * k * s, 0, 0], ll: [26 * k * s, 0, 0],
      torso: [lean, 0, 0],
      head: [-lean * 0.45 + (R ? 0 : 3 * lag * k), 0, 0],
      pelvis: [0, 7 * k * s, 0],
      y: R ? 0.1 * c2 : (0.32 * c2 - 0.3 * s2) * k,
      sq: R ? 1 : 1 + (0.035 * c2 - 0.075 * s2 * s2) * k,
    };
  }

  // the bone transforms in character space for the current pose
  _bones() {
    const F = this.bake.facings[this.view], J = F.joints, o = this.cur || { rs: [0, 0, 0], re: [0, 0, 0], ls: [0, 0, 0], le: [0, 0, 0], torso: [0, 0, 0], head: [0, 0, 0], rl: [0, 0, 0], ll: [0, 0, 0], pelvis: [0, 0, 0], y: 0, sq: 1, ik: 0, yaw: 0, march: 0 };
    const q = this.view === "q";
    const U = 0.05 * 230; // one body voxel in baked pixels
    const B = {};
    const yb = o.y > 0 ? -o.y * U * 1.1 : -o.y * U * 0.9; // hop lifts, crouch lowers the hips
    const root = [1, 0, 0, 1, 0, o.y > 0 ? yb : 0];
    const hipDrop = o.y < 0 ? yb : 0;
    const hp = J.hips.p;
    const pel = (q ? o.pelvis[1] * 0.2 : o.pelvis[2]) * D;
    B.hips = mul(root, mul([1, 0, 0, 1, 0, hipDrop], about(hp[0], hp[1], pel)));
    const sq = Math.max(0.82, Math.min(1.18, o.sq || 1));
    const tq = q ? (o.torso[0] + o.pelvis[0] * 0.3) * D : -o.torso[2] * D;
    const twist = q ? 1 - Math.min(0.12, Math.abs(o.torso[1]) / 400) : 1;
    B.torso = mul(B.hips, about(J.torso.p[0], J.torso.p[1], tq, twist / Math.sqrt(sq), sq));
    const hq = q ? o.head[0] * D * 0.8 : -o.head[2] * D;
    const hTurn = q ? o.head[1] : 0;
    B.head = mul(B.torso, mul([1, 0, 0, 1, hTurn * 0.25, 0], about(J.head.p[0], J.head.p[1], hq)));
    // limbs: v3's joint Euler (XYZ) turned into a 3D direction, projected through the
    // baked view, then measured against the rest pose: the 2D turn and the length ratio
    const R = q ? [0.809, 0.588] : [1, 0]; // the view's right vector (x, z)
    const proj = (d) => [d[0] * R[0] + d[2] * R[1], -d[1]];
    const ang = (v) => Math.atan2(-v[0], v[1]);
    const dirOf = (x, z) => { const cx = Math.cos(x * D), sx = Math.sin(x * D), cz = Math.cos(z * D), sz = Math.sin(z * D); return [sz, -cz * cx, -cz * sx]; };
    const dir2 = (x, z, e) => {
      const cx = Math.cos(x * D), sx = Math.sin(x * D), cz = Math.cos(z * D), sz = Math.sin(z * D), ce = Math.cos(e * D), se = Math.sin(e * D);
      return [ce * sz, -ce * cz * cx + se * sx, -ce * cz * sx - se * cx];
    };
    const turn = (d, d0) => {
      const v = proj(d), v0 = proj(d0), l = Math.hypot(...v), l0 = Math.hypot(...v0) || 1;
      return [ang(v) - ang(v0), Math.max(0.38, Math.min(1.25, l / l0))];
    };
    const arm = (s) => {
      const sh = o[s === "r" ? "rs" : "ls"], el = o[s === "r" ? "re" : "le"];
      const rz = s === "l" ? 7 : -7;
      let [a1, f1] = turn(dirOf(sh[0], sh[2]), dirOf(0, rz));
      let [a2, f2] = turn(dir2(sh[0], sh[2], el[0]), dir2(0, rz, -8));
      if (s === "r" && o.ik > 0.01) {
        // the salute: the hand to the hat brim
        const k = Math.min(1, o.ik);
        const [s1, g1] = turn(dirOf(-150, -60), dirOf(0, rz)), [s2, g2] = turn(dir2(-150, -60, -110), dir2(0, rz, -8));
        a1 = lerp(a1, s1, k); f1 = lerp(f1, g1, k); a2 = lerp(a2, s2, k); f2 = lerp(f2, g2, k);
      }
      const sp = J["uarm_" + s].p, ep = J["farm_" + s].p;
      const upL = about(sp[0], sp[1], a1, 1, f1);
      const [ex, ey] = apply(upL, ep[0], ep[1]);
      const foL = mul([1, 0, 0, 1, ex - ep[0], ey - ep[1]], about(ep[0], ep[1], a2, 1, f2));
      B["uarm_" + s] = mul(B.torso, upL);
      B["farm_" + s] = mul(B.torso, foL);
      B["hand_" + s] = B["farm_" + s];
    };
    arm("l"); arm("r");
    for (const s of ["l", "r"]) {
      const lg = o[s === "r" ? "rl" : "ll"];
      const rz = s === "l" ? 2 : -2;
      const [a, f] = turn(dirOf(lg[0], lg[2] + rz), dirOf(0, rz));
      let lift = 0;
      if (o.march > 0.01) lift = o.march * Math.max(0, Math.sin(this.clock * 7 + (s === "l" ? Math.PI : 0))) * 12;
      // two-segment legs: the knee bends in a crouch and on the lifting step
      const sw = this.locoW * Math.max(0, Math.sin(this.walkPhase * Math.PI + (s === "l" ? Math.PI : 0)));
      const crouch = o.y < 0 ? Math.min(1.2, -o.y * 0.22) : 0;
      const knee = crouch + sw * 0.55 + (lift ? 0.5 : 0);
      const thigh = mul(B.hips, mul([1, 0, 0, 1, 0, -lift - hipDrop * 0.6], about(J["leg_" + s].p[0], J["leg_" + s].p[1], a - knee * 0.5, 1, Math.min(1, f + 0.15))));
      B["leg_" + s] = thigh;
      const kp = J["knee_" + s]?.p || [J["leg_" + s].p[0], (J["leg_" + s].p[1] + 0) / 2];
      B["shin_" + s] = mul(thigh, about(kp[0], kp[1], knee));
    }
    for (const k of ["sashTails", "kerchiefTails", "fringe_l", "fringe_r"]) if (J[k]) B[k] = mul(B.torso, about(J[k].p[0], J[k].p[1], this.dangle[k]?.x || 0));
    if (J.ribbons) B.ribbons = mul(B.head, about(J.ribbons.p[0], J.ribbons.p[1], this.dangle.ribbons?.x || 0));
    return B;
  }
  // world position of a joint (for effects, hand-offs, cut-ins), in stage pixels
  jointAt(name, dx = 0, dy = 0) {
    const B = this._bones(), J = this.bake.facings[this.view].joints;
    const m = B[name] || B.torso;
    const p = J[name]?.p || J.torso.p;
    const [x, y] = apply(m, p[0] + dx, p[1] + dy);
    return [this.x + x * this.scale * this.dir, this.y + y * this.scale];
  }
  handTip(s = "r") {
    const J = this.bake.facings[this.view].joints;
    const hp = J["hand_" + s].p;
    return this.jointAt("hand_" + s, 0, 30) && (() => {
      const B = this._bones();
      const [x, y] = apply(B["hand_" + s], hp[0], hp[1] + 30);
      return [this.x + x * this.scale * this.dir, this.y + y * this.scale];
    })();
  }

  draw(ctx, { shadow = true } = {}) {
    const F = this.bake.facings[this.view], I = this.img.facings[this.view], J = F.joints;
    const B = this._bones();
    const o = this.cur || {};
    ctx.save();
    ctx.globalAlpha = this.alpha;
    ctx.translate(this.x, this.y);
    // the promotion spin: a paper-flip turn about the vertical
    let sx = this.dir;
    // the squash turn: narrow, flip at the middle, spring back
    if (this.turnK < 1) {
      const m = Math.abs(1 - 2 * this.turnK);
      sx = (this.turnK < 0.5 ? -this.dir : this.dir) * Math.max(0.22, m * m * (3 - 2 * m));
    }
    const yaw = (o.yaw || 0) * D;
    if (yaw) sx *= Math.cos(yaw) >= 0 ? Math.max(0.08, Math.cos(yaw)) : -Math.max(0.08, -Math.cos(yaw));
    ctx.scale(sx * this.scale, this.scale);
    if (shadow) {
      const hop = Math.max(0, o.y || 0);
      ctx.fillStyle = `rgba(20,12,30,${0.28 - Math.min(0.15, hop * 0.03)})`;
      ctx.beginPath();
      ctx.ellipse(0, 4, 150 * (1 - Math.min(0.3, hop * 0.05)), 26, 0, 0, Math.PI * 2);
      ctx.fill();
    }
    const base = ctx.getTransform();
    const draw = (spr, m, alpha = 1) => {
      if (!spr) return;
      ctx.setTransform(base.multiply(new DOMMatrix(m)));
      if (alpha < 1) ctx.globalAlpha = this.alpha * alpha;
      ctx.drawImage(spr.im, spr.x, spr.y, spr.w, spr.h);
      if (alpha < 1) ctx.globalAlpha = this.alpha;
    };
    // a leg in two pieces, split at the knee (the thigh on the hip, the shin on the knee)
    const drawLeg = (k, spr) => {
      const s = k.slice(4), kp = J["knee_" + s]?.p;
      if (!kp || !B["shin_" + s]) return draw(spr, B[k]);
      for (const [m, top] of [[B["shin_" + s], false], [B[k], true]]) {
        ctx.setTransform(base.multiply(new DOMMatrix(m)));
        ctx.save();
        ctx.beginPath();
        if (top) ctx.rect(spr.x - 10, spr.y - 10, spr.w + 20, kp[1] + 6 - spr.y + 10);
        else ctx.rect(spr.x - 10, kp[1] - 6, spr.w + 20, spr.y + spr.h - kp[1] + 16);
        ctx.clip();
        ctx.drawImage(spr.im, spr.x, spr.y, spr.w, spr.h);
        ctx.restore();
      }
    };
    const tz = J.torso.z;
    const far = (k) => J[k] && J[k].z < tz - 0.08;
    const armParts = (s) => {
      const out = [["uarm_" + s, I.parts["uarm_" + s]], ["farm_" + s, I.parts["farm_" + s]]];
      out.push(["prop_" + s, null]);
      const shape = I.hands[s][(s === "r" ? o.hr : o.hl) || (this.prop?.[s] ? "grip" : "fist")] ? (s === "r" ? o.hr : o.hl) || (this.prop?.[s] ? "grip" : "fist") : "fist";
      const hb = (this.handBlend[s] ||= { cur: shape, prev: null, t: 1 });
      if (hb.cur !== shape) (hb.prev = hb.cur), (hb.cur = shape), (hb.t = 0);
      if (hb.prev && hb.t < 1) out.push(["handPrev_" + s, I.hands[s][hb.prev]]);
      out.push(["hand_" + s, I.hands[s][shape]]);
      return out;
    };
    const legs = ["leg_l", "leg_r"].sort((a, b) => J[a].z - J[b].z);
    const order = [];
    for (const l of legs) order.push([l, I.parts[l]]);
    for (const k of ["ribbons"]) if (I.parts[k] && J[k].z < J.head.z) order.push([k, I.parts[k]]);
    for (const s of ["l", "r"]) if (far("uarm_" + s)) order.push(...armParts(s));
    for (const k of ["fringe_l", "fringe_r"]) if (I.parts[k] && far(k)) order.push([k, I.parts[k]]);
    order.push(["torso", I.parts.torso]);
    if (this.workProp && !this.shots.length && !this.prop) order.push(["work", null]);
    for (const k of ["sashTails", "kerchiefTails"]) if (I.parts[k]) order.push([k, I.parts[k]]);
    if (this.propHeld) order.push(["held", null]);
    const glanceView = this.glance > 0.5 && this.view === "q" ? "f" : this.view;
    order.push(["head", (this.img.facings[glanceView] || I).heads[this.expr] || I.heads[this.bake.expressions[0]]]);
    for (const k of ["ribbons"]) if (I.parts[k] && J[k].z >= J.head.z) order.push([k, I.parts[k]]);
    for (const s of ["l", "r"]) if (!far("uarm_" + s)) order.push(...armParts(s));
    for (const k of ["fringe_l", "fringe_r"]) if (I.parts[k] && !far(k)) order.push([k, I.parts[k]]);
    for (const [k, spr] of order) {
      if (k.startsWith("leg_")) { drawLeg(k, spr); continue; }
      if (k.startsWith("handPrev_") || k.startsWith("hand_")) {
        // hand shapes crossfade over 90 ms instead of popping
        const s = k.slice(-1), hb = this.handBlend[s];
        const t = hb ? Math.min(1, hb.t) : 1;
        draw(spr, B["hand_" + s], k.startsWith("handPrev_") ? 1 - t : hb?.prev ? t : 1);
        continue;
      }
      if (k === "work") {
        const pi = this.propImg[this.workProp];
        if (!pi) continue;
        const tp = J.torso.p;
        ctx.setTransform(base.multiply(new DOMMatrix(mul(B.torso, [1, 0, 0, 1, tp[0] + 30, tp[1] + 40]))));
        const ps = 0.5;
        ctx.drawImage(pi.im, (-pi.w * ps) / 2, (-pi.h * ps) / 2, pi.w * ps, pi.h * ps);
        continue;
      }
      if (k.startsWith("prop_")) {
        const s = k.slice(5), name = this.prop?.[s];
        const pi = name && this.propImg[name];
        if (!pi) continue;
        const g = PROP_GRIP[name] || { gx: 0.5, gy: 0.5, a: 0 };
        const hp = J["hand_" + s].p;
        const rot = ((this.prop[s + "Rot2"] ?? PROP_REST[name] ?? 0) + g.a) * D;
        const m = mul(B["hand_" + s], [Math.cos(rot), Math.sin(rot), -Math.sin(rot), Math.cos(rot), hp[0], hp[1] + 40]);
        ctx.setTransform(base.multiply(new DOMMatrix(m)));
        const ps = name === "cutlass" ? 1.15 : 0.75;
        ctx.drawImage(pi.im, -pi.w * g.gx * ps, -pi.h * g.gy * ps, pi.w * ps, pi.h * ps);
        continue;
      }
      if (k === "held") {
        const pi = this.propImg[this.propHeld];
        if (!pi) continue;
        const tp = J.torso.p;
        ctx.setTransform(base.multiply(new DOMMatrix(mul(B.torso, [1, 0, 0, 1, tp[0] + 90, tp[1] - 110]))));
        ctx.drawImage(pi.im, -pi.w / 2, -pi.h / 2);
        continue;
      }
      const m = B[k === "head" ? "head" : k] || B.torso;
      if (k === "head" && glanceView !== this.view) {
        // the front head over the three-quarter body: centre it on the neck
        const hs = spr, hp = J.head.p, fp = this.bake.facings.f.joints.head.p;
        ctx.setTransform(base.multiply(new DOMMatrix(m)));
        ctx.drawImage(hs.im, hs.x + hp[0] - fp[0], hs.y + hp[1] - fp[1], hs.w, hs.h);
        continue;
      }
      draw(spr, m);
    }
    ctx.restore();
  }
}

function blend(a, b, w) {
  if (w <= 0) return a;
  const o = { ...a };
  for (const c of CH3) if (b[c]) o[c] = (a[c] || [0, 0, 0]).map((v, i) => lerp(v, b[c][i], w));
  for (const c of CH1) if (b[c] !== undefined) o[c] = lerp(a[c] ?? (c === "sq" ? 1 : 0), b[c], w);
  for (const c of ["hr", "hl"]) if (b[c] && w > 0.5) o[c] = b[c];
  if (b.prop && w > 0.5) o.prop = b.prop;
  return o;
}

// decode baked data URIs into images (once), keeping the bake's shape
import { mangaize } from "./manga.js";
export async function loadImages(bake, { manga = null } = {}) {
  const jobs = [];
  const im = (s) => {
    if (!s) return null;
    const o = { w: s.w, h: s.h, x: s.x, y: s.y, im: new Image() };
    jobs.push(new Promise((r) => { o.im.onload = o.im.onerror = r; }));
    o.im.src = s.img;
    return o;
  };
  const crew = {};
  for (const [id, c] of Object.entries(bake.crew)) {
    const facings = {};
    for (const [fk, F] of Object.entries(c.facings)) {
      const parts = {}, heads = {}, hands = { l: {}, r: {} };
      for (const [k, s] of Object.entries(F.parts)) parts[k] = im(s);
      for (const [k, s] of Object.entries(F.heads)) heads[k] = im(s);
      for (const side of ["l", "r"]) for (const [k, s] of Object.entries(F.hands[side] || {})) hands[side][k] = im(s);
      facings[fk] = { parts, heads, hands, whole: im(F.whole) };
    }
    crew[id] = { facings };
  }
  const props = {};
  for (const [k, s] of Object.entries(bake.props || {})) props[k] = im(s);
  await Promise.all(jobs);
  if (manga) {
    // the one look: every sprite cel-shaded and inked once, at load
    const all = [];
    for (const c of Object.values(crew)) for (const F of Object.values(c.facings)) {
      all.push(...Object.values(F.parts), ...Object.values(F.heads), ...Object.values(F.hands.l), ...Object.values(F.hands.r), F.whole);
    }
    all.push(...Object.values(props));
    for (const o of all) {
      if (!o) continue;
      const r = mangaize(o.im, manga);
      o.im = r.canvas;
      o.x -= r.pad; o.y -= r.pad; o.w += r.pad * 2; o.h += r.pad * 2;
    }
  }
  return { crew, props };
}
