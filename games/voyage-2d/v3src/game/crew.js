// A crewman on deck: walks between stations, runs the deck-pooled action
// loops (prototype v2 crew table: period and amplitude per action), plays
// one-shot beats (salute, cheer, slump, promotion turn, ...) and flies a
// pennant with name, rank braid, task and vendor.
//
// Poses are forward kinematics in degrees: rs/re/ls/le = right/left shoulder
// and elbow [x, y, z], torso and head [x, y, z], legs rl/ll. Shoulder x < 0
// swings the arm forward and up; right-arm z < 0 swings it out.
import * as THREE from "three";
import { kit } from "./props.js";
import * as P from "../engine/models/props.js";

const D = Math.PI / 180;
const ease = (k) => 0.5 - 0.5 * Math.cos(Math.PI * 2 * k); // 0..1..0 over a period
const lerp = (a, b, k) => a + (b - a) * k;

// ---------------------------------------------------------------- action loops
// each returns a pose for phase ph in [0,1) and wall time t
const LOOPS = {
  idle: { T: 3, pose: () => ({ rs: [0, 0, -6], ls: [0, 0, 6], re: [-10, 0, 0], le: [-10, 0, 0] }) },
  lean: { T: 4, pose: (p) => ({ torso: [6, 0, 10], rs: [-30, 0, -24], re: [-70, 0, 0], ls: [-12, 0, 16], le: [-30, 0, 0], head: [0, 20 * Math.sin(p * 6.28), 0] }) },
  coil: { T: 1.4, pose: (p) => ({ torso: [22, 0, 0], rs: [-55 + 15 * Math.sin(p * 6.28), 0, -12 + 10 * Math.cos(p * 6.28)], ls: [-55 - 15 * Math.sin(p * 6.28), 0, 12 - 10 * Math.cos(p * 6.28)], re: [-30, 0, 0], le: [-30, 0, 0] }), prop: { deck: "coil" } },
  mend: { T: 1.2, pose: (p) => ({ torso: [18, 0, 0], head: [22, 0, 0], rs: [-48 + 10 * ease(p), 0, -6], ls: [-48, 0, 6], re: [-40 - 20 * ease(p), 0, 0], le: [-40, 0, 0] }), prop: { l: "sailcloth" } },
  lookout: { T: 4.2, pose: (p) => ({ head: [-6, 18 * Math.sin(p * 6.28), 0], torso: [0, 12 * Math.sin(p * 6.28), 0], rs: [-150, 0, 26], re: [-70, 0, 0], ls: [-110, 0, -10], le: [-50, 0, 0] }), prop: { r: "spyglass", rRot: [70, -6, 0] } },
  signal: { T: 0.8, pose: (p) => ({ rs: [-145 + 13 * Math.sin(p * 6.28), 0, -30], re: [-10, 0, 0], ls: [-20, 0, 10], le: [-20, 0, 0], head: [-8, 0, 0] }), prop: { r: "flag", rRot: [-90, 0, 0] } },
  point: { T: 3, pose: (p) => ({ y: 0.6 * ease(p), rs: [-92, 10, -10], re: [0, 0, 0], ls: [-50, 0, 20], le: [-40, 0, 0], hr: "point" }), prop: { deck: "chartTable" } },
  log: { T: 0.9, pose: (p) => ({ head: [18, 0, 0], ls: [-62, 0, 14], le: [-60, 0, 0], rs: [-58 + 8 * Math.sin(p * 6.28), 0, -10], re: [-64 + 6 * Math.sin(p * 12.56), 0, 0] }), prop: { l: "logbook", lRot: [-60, 0, 0], r: "quill", rRot: [-30, 0, 0] } },
  haul: { T: 1.25, pose: (p) => ({ torso: [-14 + 10 * ease(p), 0, 0], rs: [-70 + 30 * ease(p), 0, -4], ls: [-70 + 30 * ease(p), 0, 4], re: [-20, 0, 0], le: [-20, 0, 0], rl: [-18, 0, 0], ll: [18, 0, 0] }), prop: { rope: true } },
  capstan: { T: 4.4, pose: () => ({ torso: [24, 0, 0], rs: [-80, 0, -6], ls: [-80, 0, 6], re: [-10, 0, 0], le: [-10, 0, 0], rl: [-20, 0, 0], ll: [20, 0, 0] }), walk: "circle", prop: { deck: "capstan" } },
  carry: { T: 3.2, pose: () => ({ rs: [-78, 0, -6], ls: [-78, 0, 6], re: [-20, 0, 0], le: [-20, 0, 0] }), walk: "pace", prop: { held: "crate" } },
  climb: { T: 1.4, pose: (p) => ({ rs: [lerp(-124, -70, ease(p)), 0, -8], ls: [lerp(-70, -124, ease(p)), 0, 8], re: [-20, 0, 0], le: [-20, 0, 0], rl: [-30 * ease(p), 0, 0], ll: [-30 * (1 - ease(p)), 0, 0] }), walk: "climb" },
  hammer: { T: 0.62, pose: (p) => ({ torso: [16, 0, 0], rs: [-150 + 100 * Math.pow(Math.sin(p * Math.PI), 2), 0, -8], re: [-30, 0, 0], ls: [-40, 0, 10], le: [-40, 0, 0], hr: "grip" }), prop: { r: "hammer", rRot: [-80, 0, 0], deck: "plank" } },
  saw: { T: 0.7, pose: (p) => ({ torso: [22, 0, 0], rs: [-62 + 22 * Math.sin(p * 6.28), 0, -6], re: [-44 + 22 * Math.sin(p * 6.28), 0, 0], ls: [-40, 0, 14], le: [-40, 0, 0], hr: "grip" }), prop: { r: "saw", rRot: [-10, 0, 0], deck: "sawhorse" } },
  swab: { T: 1.5, pose: (p) => ({ torso: [22, 12 * Math.sin(p * 6.28), 0], rs: [-50 + 18 * Math.sin(p * 6.28), 0, -6], ls: [-40 + 18 * Math.sin(p * 6.28), 0, 6], re: [-20, 0, 0], le: [-40, 0, 0], hr: "grip" }), prop: { r: "swab", rRot: [60, 0, 0], deck: "bucket" } },
  // role loops
  helm: { T: 2.4, pose: (p) => ({ rs: [-64 + 12 * ease(p), 0, -8], ls: [-64 + 12 * ease(p), 0, 8], re: [-20, 0, 0], le: [-20, 0, 0] }) },
  review: { T: 4.2, pose: (p) => ({ head: [18, 14 * Math.sin(p * 6.28), 0], rs: [-80, 0, 20], re: [-60, 0, 0], ls: [-55, 0, -10], le: [-40, 0, 0], hr: "grip", hl: "open" }), prop: { r: "magnifier", rRot: [-20, 0, 0], l: "map", lRot: [-60, 0, 0] } },
};

// ---------------------------------------------------------------- one-shots
// each: { dur, pose(k, t) } k = 0..1 over dur
const SHOTS = {
  salute: { dur: 0.8, pose: (k) => ({ rs: [-150, 0, -40], re: [-110, 0, 0], hr: "open", head: [-6, 0, 0], w: k < 0.2 ? k / 0.2 : k > 0.8 ? (1 - k) / 0.2 : 1 }) },
  cheer: { dur: 1.7, pose: (k) => ({ rs: [-165, 0, -20], ls: [-165, 0, 20], re: [-10, 0, 0], le: [-10, 0, 0], y: Math.max(0, Math.sin(k * Math.PI * 2)) * (k < 0.5 ? 2.4 : 1), hr: "open", hl: "open", w: k > 0.85 ? (1 - k) / 0.15 : 1 }) },
  slump: { dur: 9999, pose: () => ({ torso: [34, 0, 6], head: [26, 0, 0], rs: [8, 0, -4], ls: [8, 0, 4], re: [-4, 0, 0], le: [-4, 0, 0], y: -1.4 }) },
  spin: { dur: 1.4, pose: (k) => ({ y: Math.sin(k * Math.PI) * 4, yaw: 360 * k, rs: [-30, 0, -30], ls: [-30, 0, 30] }) },
  raiseScroll: { dur: 1.6, pose: (k) => ({ rs: [-165, 0, -10], re: [-10, 0, 0], hr: "grip", w: k < 0.15 ? k / 0.15 : k > 0.85 ? (1 - k) / 0.15 : 1 }), prop: { r: "scroll", rRot: [0, 0, 90] } },
  pointBack: { dur: 1.4, pose: (k) => ({ rs: [-95, 0, -40], re: [0, 0, 0], hr: "point", head: [0, -20, 0], w: k > 0.8 ? (1 - k) / 0.2 : 1 }) },
  answerList: { dur: 1.8, pose: (k) => ({ rs: [-100, 0, -10], re: [-30, 0, 0], hr: "grip", w: k > 0.85 ? (1 - k) / 0.15 : 1 }), prop: { r: "criteriaList", rRot: [-90, 0, 0] } },
  hammerHome: { dur: 1.4, pose: (k) => ({ torso: [24, 0, 0], rs: [-150 + 110 * Math.pow(Math.sin(k * Math.PI * 3), 2), 0, -8], re: [-30, 0, 0], hr: "grip" }), prop: { r: "hammer", rRot: [-80, 0, 0] } },
  carryCrate: { dur: 1.8, pose: () => ({ rs: [-78, 0, -6], ls: [-78, 0, 6], re: [-20, 0, 0], le: [-20, 0, 0] }), prop: { held: "crate" } },
  order: { dur: 1.8, pose: (k) => ({ rs: [-170, 0, -12], re: [-10, 0, 0], hr: "grip", head: [-10, 0, 0], w: k < 0.18 ? k / 0.18 : k > 0.85 ? (1 - k) / 0.15 : 1 }), prop: { r: "cutlass", rRot: [-60, 0, 0] } },
  stamp: { dur: 1.2, pose: (k) => ({ torso: [22 * Math.sin(k * Math.PI), 0, 0], rs: [-60 - 40 * Math.sin(k * Math.PI * 2), 0, -6], re: [-20, 0, 0], hr: "grip" }), prop: { r: "stamp", rRot: [0, 0, 0] } },
  whistle: { dur: 1.2, pose: () => ({ rs: [-110, 0, 30], re: [-90, 0, 0], hr: "grip", head: [-10, 0, 0] }), prop: { r: "whistle", rRot: [-30, 0, 0] } },
  inspect: { dur: 2.4, pose: (k) => ({ torso: [10, -10, 0], head: [12, 10 * Math.sin(k * 6.28), 0], rs: [-88, 0, 18], re: [-50, 0, 0], ls: [-50, 0, -6], le: [-40, 0, 0], hr: "grip", hl: "open" }), prop: { r: "magnifier", rRot: [-20, 0, 0], l: "map", lRot: [-60, 0, 0] } },
  bark: { dur: 1.0, pose: (k) => ({ y: Math.max(0, Math.sin(k * Math.PI * 4)) * 1.2 }) },
};

// ---------------------------------------------------------------- pennants
const RANK_DASH = { worker: 4, reviewer: 2 };
export function pennantTexture({ name, line2 = "", line3 = "", hem = "#2a2016", braid = 0, braidTop = false, reviewer = false }) {
  const c = document.createElement("canvas");
  c.width = 320;
  c.height = 128;
  const x = c.getContext("2d");
  // swallowtail sailcloth pennant on a brass staff
  x.fillStyle = "#c9a44a";
  x.fillRect(4, 6, 6, 118);
  x.beginPath();
  x.moveTo(10, 8);
  x.lineTo(300, 8);
  x.lineTo(270, 60);
  x.lineTo(300, 112);
  x.lineTo(10, 112);
  x.closePath();
  x.fillStyle = "#f4ead2";
  x.fill();
  x.lineWidth = 4;
  x.strokeStyle = "rgba(40,30,20,.55)";
  x.stroke();
  // state hem along the foot
  x.fillStyle = hem;
  x.fillRect(10, 100, 262, 12);
  // rank braid along the head: dashes counting the rank
  for (let i = 0; i < braid; i++) {
    x.fillStyle = braidTop ? "#c9a44a" : reviewer ? "#3aa590" : "#2a2016";
    x.fillRect(16 + i * 22, 12, 16, 7);
  }
  x.fillStyle = "#1c1a24";
  x.font = "700 30px 'Barlow Semi Condensed', 'Nunito', system-ui, sans-serif";
  x.fillText(name, 18, 50);
  x.font = "600 21px 'Barlow Semi Condensed', 'Nunito', system-ui, sans-serif";
  x.fillStyle = "#3a3444";
  if (line2) x.fillText(line2, 18, 75);
  x.font = "500 18px 'Barlow Semi Condensed', 'Nunito', system-ui, sans-serif";
  x.fillStyle = "#5a5464";
  if (line3) x.fillText(line3, 18, 95);
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.anisotropy = 4;
  return tex;
}

// ---------------------------------------------------------------- the crewman
const propCache = new Map();
function makeProp(name) {
  const f = {
    spyglass: () => P.buildSpyglass(),
    hammer: () => P.buildHammer(),
    magnifier: () => P.buildMagnifier({ scale: 0.038 }),
    map: () => P.buildMap({ scale: 0.025, w: 18, d: 13 }),
    scroll: () => P.buildScroll({ scale: 0.035, glow: true }),
    stamp: () => P.buildStamp({ scale: 0.05 }),
    whistle: () => P.buildWhistle(),
    ...kit,
  }[name];
  return f ? f() : new THREE.Group();
}
function propOf(owner, name) {
  const key = owner + "|" + name;
  if (!propCache.has(key)) propCache.set(key, makeProp(name));
  return propCache.get(key);
}

export class CrewMan {
  constructor({ id, role, rig, ship, scale = 1.5, home, yaw = 0 }) {
    this.id = id;
    this.role = role;
    this.rig = rig;
    this.ship = ship;
    this.group = new THREE.Group(); // walk position (ship-local)
    this.group.add(rig.group);
    rig.group.scale.multiplyScalar(scale);
    this.scale = scale;
    ship.add(this.group);
    this.pos = home.clone();
    this.home = home.clone();
    this.group.position.copy(home);
    this.yaw = yaw;
    this.baseYaw = yaw;
    this.loop = "idle";
    this.loopStart = 0;
    this.phaseOffset = (id.length * 0.37) % 1;
    this.walk = null; // { from, to, t, dur, yawTo, after }
    this.shots = []; // active one-shots { name, start, dur }
    this.slumped = false;
    this.anchor = null; // station anchor for circle/pace/climb loops
    this.cur = {}; // smoothed pose
    this.handR = null;
    this.handL = null;
    this.deckProp = null;
    this.heldProp = null;
    this.ropeProp = null;
    this.pennant = null;
    this.pennantScale = 1;
    this.pennantSwell = 0;
    this.height = 1;
    rig.setPose?.(rig.poses.includes("idle") ? "idle" : rig.poses[0]);
    this._measure();
  }
  _measure() {
    const b = new THREE.Box3().setFromObject(this.rig.group);
    this.height = b.max.y - b.min.y;
  }
  setPennant(opts) {
    const tex = pennantTexture(opts);
    if (!this.pennant) {
      this.pennant = new THREE.Sprite(new THREE.SpriteMaterial({ map: tex, depthWrite: false, transparent: true }));
      this.pennant.renderOrder = 5;
      this.group.add(this.pennant);
    } else {
      this.pennant.material.map.dispose();
      this.pennant.material.map = tex;
      this.pennant.material.needsUpdate = true;
    }
    this.pennant.position.set(0, this.height + 0.55, 0);
  }
  swellPennant() {
    this.pennantSwell = 1;
  }
  walkTo(to, yaw, dur = 2.2, after) {
    this.walk = { from: this.pos.clone(), to: to.clone(), t: 0, dur: Math.max(0.3, dur), yawFrom: this.yaw, yawTo: yaw ?? this.yaw, after };
  }
  setLoop(name, anchor) {
    if (!LOOPS[name]) name = "idle";
    this.loop = name;
    this.anchor = anchor ? anchor.clone() : this.pos.clone();
    this.loopStart = performance.now() / 1000;
    this._props();
  }
  shot(name, delay = 0) {
    const s = SHOTS[name];
    if (!s) return;
    const now = performance.now() / 1000;
    this.shots = this.shots.filter((x) => x.name !== name);
    this.shots.push({ name, start: now + delay, dur: s.dur });
    if (name === "slump") this.slumped = true;
  }
  clearShot(name) {
    this.shots = this.shots.filter((x) => x.name !== name);
    if (name === "slump") this.slumped = false;
  }
  _attach(side, name, rot) {
    const key = side === "r" ? "handR" : "handL";
    if (this[key]?.userData.propName === name) return;
    if (this[key]) this[key].parent?.remove(this[key]);
    this[key] = null;
    if (!name) return;
    const p = propOf(this.id + side, name);
    p.userData.propName = name;
    const hand = this.rig.arms?.[side]?.hand;
    if (!hand) return;
    hand.add(p);
    p.position.set(0, 0, 0);
    p.rotation.set(...(rot || [0, 0, 0]).map((v) => v * D));
    this[key] = p;
  }
  _props(shotProp) {
    const pr = shotProp || LOOPS[this.loop]?.prop || {};
    // one-shot props replace hand props while they run
    this._attach("r", pr.r, pr.rRot);
    this._attach("l", pr.l, pr.lRot);
    if (!shotProp) {
      // deck props stand at the station
      if (this.deckProp) this.ship.remove(this.deckProp);
      this.deckProp = null;
      if (pr.deck) {
        this.deckProp = propOf(this.id + "deck", pr.deck);
        this.ship.add(this.deckProp);
        const fwd = new THREE.Vector3(Math.sin(this.yaw), 0, Math.cos(this.yaw));
        this.deckProp.position.copy(this.anchor || this.pos).addScaledVector(fwd, pr.deck === "capstan" ? 0 : 0.75);
        this.deckProp.scale.setScalar(this.scale * 0.9);
      }
    }
    const held = pr.held;
    if (this.heldProp && this.heldProp.userData.propName !== held) {
      this.rig.torso.remove(this.heldProp);
      this.heldProp = null;
    }
    if (held && !this.heldProp) {
      this.heldProp = propOf(this.id + "held", held);
      this.heldProp.userData.propName = held;
      this.rig.torso.add(this.heldProp);
      this.heldProp.position.set(0, 0.2, 0.42);
    }
    if (pr.rope && !this.ropeProp) {
      this.ropeProp = kit.rope(2.4);
      this.rig.torso.add(this.ropeProp);
      this.ropeProp.position.set(0, 0.3, 1.4);
      this.ropeProp.rotation.x = -0.35;
    } else if (!pr.rope && this.ropeProp && !shotProp) {
      this.rig.torso.remove(this.ropeProp);
      this.ropeProp = null;
    }
  }
  update(dt, now) {
    // walking
    let walking = false;
    if (this.walk) {
      const w = this.walk;
      w.t += dt;
      const k = Math.min(1, w.t / w.dur);
      const e = k * k * (3 - 2 * k);
      this.pos.lerpVectors(w.from, w.to, e);
      const dir = new THREE.Vector3().subVectors(w.to, w.from);
      if (dir.lengthSq() > 0.01 && k < 0.9) this.yaw = Math.atan2(dir.x, dir.z);
      else this.yaw = lerp(this.yaw, w.yawTo, Math.min(1, dt * 6));
      walking = k < 1;
      if (k >= 1) {
        this.walk = null;
        this.yaw = w.yawTo;
        w.after?.();
      }
    }
    // loop phase
    const L = LOOPS[this.loop] || LOOPS.idle;
    const ph = (((now - this.loopStart) / L.T + this.phaseOffset) % 1 + 1) % 1;
    let pose = walking
      ? { rs: [30 * Math.sin(now * 8), 0, -6], ls: [-30 * Math.sin(now * 8), 0, 6], rl: [-28 * Math.sin(now * 8), 0, 0], ll: [28 * Math.sin(now * 8), 0, 0], re: [-20, 0, 0], le: [-20, 0, 0], y: Math.abs(Math.sin(now * 8)) * 0.8 }
      : this.slumped
        ? SHOTS.slump.pose(0)
        : L.pose(ph, now);
    // loop-driven positions
    if (!walking && !this.slumped && this.anchor) {
      if (L.walk === "circle") {
        const a = ph * Math.PI * 2;
        this.pos.set(this.anchor.x + Math.cos(a) * 0.85, this.anchor.y, this.anchor.z + Math.sin(a) * 0.85);
        this.yaw = -a;
      } else if (L.walk === "pace") {
        const e = ease(ph);
        this.pos.copy(this.anchor).add(new THREE.Vector3(Math.sin(this.baseYaw + Math.PI / 2), 0, Math.cos(this.baseYaw + Math.PI / 2)).multiplyScalar((e - 0.5) * 2.4));
        this.yaw = this.baseYaw + (ph < 0.5 ? Math.PI / 2 : -Math.PI / 2);
        pose.y = Math.abs(Math.sin(now * 7)) * 0.6;
      } else if (L.walk === "climb") {
        this.pos.copy(this.anchor);
        this.pos.y += 0.6 + ease(ph * 0.5) * 1.4;
      }
    }
    // one-shots override, weighted
    let shotProp = null;
    let yawAdd = 0;
    for (const s of this.shots) {
      if (now < s.start) continue;
      const k = (now - s.start) / s.dur;
      if (k >= 1) continue;
      const sp = SHOTS[s.name].pose(k, now);
      const w = sp.w ?? 1;
      for (const j of ["rs", "re", "ls", "le", "torso", "head", "rl", "ll"]) if (sp[j]) pose[j] = (pose[j] || [0, 0, 0]).map((v, i) => lerp(v, sp[j][i], w));
      if (sp.y !== undefined) pose.y = lerp(pose.y || 0, sp.y, w);
      if (sp.hr) pose.hr = sp.hr;
      if (sp.hl) pose.hl = sp.hl;
      if (sp.yaw) yawAdd += sp.yaw * D;
      if (SHOTS[s.name].prop) shotProp = SHOTS[s.name].prop;
    }
    this.shots = this.shots.filter((s) => now < s.start + s.dur);
    this._props(shotProp);
    // smooth toward the pose
    const kk = Math.min(1, dt * 14);
    const R = (o, key) => {
      const target = pose[key] || [0, 0, 0];
      const c = (this.cur[key] ||= [0, 0, 0]);
      for (let i = 0; i < 3; i++) c[i] = lerp(c[i], target[i], kk);
      o?.rotation.set(c[0] * D, c[1] * D, c[2] * D);
    };
    const r = this.rig;
    if (r.arms) {
      R(r.arms.r.sh, "rs");
      R(r.arms.r.el, "re");
      R(r.arms.l.sh, "ls");
      R(r.arms.l.el, "le");
      R(r.torso, "torso");
      R(r.head, "head");
      R(r.legs.r, "rl");
      R(r.legs.l, "ll");
      r.setHand?.("r", pose.hr || (this.handR ? "grip" : "fist"));
      r.setHand?.("l", pose.hl || (this.handL ? "grip" : "fist"));
    }
    this.cur.y = lerp(this.cur.y || 0, pose.y || 0, kk);
    this.group.position.copy(this.pos);
    this.group.position.y += this.cur.y * 0.05 * this.scale;
    this.group.rotation.y = this.yaw + yawAdd;
    // pennant swell (arrival, salute, promotion)
    if (this.pennant) {
      this.pennantSwell = Math.max(0, this.pennantSwell - dt / 0.8);
      const s = 1 + 0.1 * Math.sin(Math.PI * (1 - this.pennantSwell)) * (this.pennantSwell > 0 ? 1 : 0);
      this.pennant.scale.set(1.5 * s, 0.6 * s, 1);
      this.pennant.position.y = this.height + 0.55 + this.cur.y * 0.05 * this.scale * 0;
    }
  }
}
export { LOOPS, SHOTS };
