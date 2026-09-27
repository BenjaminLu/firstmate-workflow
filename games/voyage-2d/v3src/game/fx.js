// Effects: layered explosions scaled by weight (motion spec "The explosion":
// hit-stop, flash, fireball, shockwave rings, debris, embers, smoke, shake),
// muzzle flashes and smoke, water columns, fireworks, rain, sparks, flying
// hand-offs. Pooled sprites and one instanced debris mesh; the scatter is
// seeded by a count, so the same blow draws the same.
import * as THREE from "three";

function radial(stops, size = 128) {
  const c = document.createElement("canvas");
  c.width = c.height = size;
  const x = c.getContext("2d");
  const g = x.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
  for (const [o, col] of stops) g.addColorStop(o, col);
  x.fillStyle = g;
  x.fillRect(0, 0, size, size);
  const t = new THREE.CanvasTexture(c);
  t.colorSpace = THREE.SRGBColorSpace;
  return t;
}
const TEX = {};
function tex(name) {
  if (TEX[name]) return TEX[name];
  const T = {
    flash: [[0, "rgba(255,255,245,1)"], [0.35, "rgba(255,236,190,0.9)"], [1, "rgba(255,200,120,0)"]],
    fire: [[0, "rgba(255,250,220,1)"], [0.25, "rgba(255,196,90,0.95)"], [0.55, "rgba(230,90,40,0.8)"], [1, "rgba(120,30,20,0)"]],
    smoke: [[0, "rgba(90,80,78,0.85)"], [0.6, "rgba(70,64,66,0.45)"], [1, "rgba(60,56,60,0)"]],
    ember: [[0, "rgba(255,240,200,1)"], [0.4, "rgba(255,180,80,0.9)"], [1, "rgba(255,120,40,0)"]],
    spark: [[0, "rgba(255,255,255,1)"], [0.3, "rgba(255,255,255,0.8)"], [1, "rgba(255,255,255,0)"]],
    mist: [[0, "rgba(240,248,255,0.9)"], [1, "rgba(220,235,255,0)"]],
    glow: [[0, "rgba(255,220,130,0.9)"], [1, "rgba(255,200,100,0)"]],
  }[name];
  TEX[name] = radial(T);
  return TEX[name];
}

export class FX {
  constructor(scene, { detail = "high" } = {}) {
    this.scene = scene;
    this.low = detail === "low";
    this.parts = [];
    this.n = 0;
    this.trauma = 0;
    this.hitstop = 0;
    this.slow = 0;
    this.flashes = []; // scene flash intensity 0..1 (critical hit)
    this.light = 0; // light breaking (clearing)
    // debris: one instanced mesh of small cubes
    const MAX = this.low ? 300 : 900;
    this.debris = new THREE.InstancedMesh(new THREE.BoxGeometry(1, 1, 1), new THREE.MeshStandardMaterial({ roughness: 0.8, vertexColors: false }), MAX);
    this.debris.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
    this.debris.count = 0;
    this.debris.frustumCulled = false;
    this.debris.castShadow = false;
    scene.add(this.debris);
    this.chips = [];
    this.maxChips = MAX;
    this.rings = [];
    this.rain = null;
    this.flyers = [];
  }
  seeded(k) {
    const x = Math.sin((this.n * 97.13 + k * 13.7) * 12.9898) * 43758.5453;
    return x - Math.floor(x);
  }
  sprite(name, pos, { scale = 1, grow = 1, life = 1, rise = 0, color = 0xffffff, add = true, vel = null, gravity = 0, drift = null, delay = 0, fade = "out" } = {}) {
    const m = new THREE.SpriteMaterial({ map: tex(name), color, transparent: true, depthWrite: false, blending: add ? THREE.AdditiveBlending : THREE.NormalBlending, opacity: 0 });
    const s = new THREE.Sprite(m);
    s.position.copy(pos);
    s.scale.setScalar(scale);
    s.renderOrder = 10;
    this.scene.add(s);
    this.parts.push({ s, age: -delay, life, scale, grow, rise, vel: vel ? vel.clone() : null, gravity, drift, fade });
    return s;
  }
  ring(pos, { radius = 3, life = 0.6, color = 0xfff2d8, width = 0.18, normal = null, delay = 0 } = {}) {
    const geo = new THREE.RingGeometry(0.92, 1, 48);
    const mat = new THREE.MeshBasicMaterial({ color, transparent: true, side: THREE.DoubleSide, depthWrite: false, blending: THREE.AdditiveBlending, opacity: 0 });
    const r = new THREE.Mesh(geo, mat);
    r.position.copy(pos);
    if (normal) r.lookAt(pos.clone().add(normal));
    this.scene.add(r);
    this.rings.push({ r, age: -delay, life, radius, width });
    return r;
  }
  chip(pos, vel, { color = 0x3b3d46, size = 0.18, life = 1.2, gravity = 12 } = {}) {
    if (this.chips.length >= this.maxChips) this.chips.shift();
    this.chips.push({ p: pos.clone(), v: vel.clone(), c: new THREE.Color(color), size, life, age: 0, gravity, spin: this.seeded(this.chips.length) * 10 });
  }
  shake(amount) {
    this.trauma = Math.min(1, this.trauma + amount);
  }
  // ---------------------------------------------------------------- the explosion
  // kind: "head" (iron chips), "deck" (oak splinters), "sea" (water column), "repair", "gun"
  explode(pos, w = 1, kind = "head", { crit = false, scale = 1, cam = null } = {}) {
    this.n++;
    const S = scale;
    const hs = (24 + 22 * (crit ? w + 2 : w)) / 1000;
    if (kind !== "repair" && kind !== "gun") this.hitstop = Math.max(this.hitstop, hs);
    if (kind === "sea") return this.waterColumn(pos, w, S);
    if (kind === "repair") {
      this.ring(pos, { radius: 1.2 * S, life: 0.6, color: 0xffc860 });
      this.sprite("glow", pos, { scale: 1.6 * S, grow: 1.4, life: 0.7 });
      for (let i = 0; i < 10; i++) this.chip(pos, new THREE.Vector3((this.seeded(i) - 0.5) * 3, 2 + this.seeded(i + 9) * 3, (this.seeded(i + 3) - 0.5) * 3), { color: i % 3 ? 0xd8b47a : 0xffd070, size: 0.08, life: 0.8, gravity: 9 });
      return;
    }
    if (kind === "gun") {
      this.sprite("flash", pos, { scale: 1.1 * S, grow: 1.8, life: 0.34 });
      this.sprite("smoke", pos, { scale: 0.8 * S, grow: 3.4, life: 1.7, rise: 0.8, add: false, drift: new THREE.Vector3(0.4, 0.1, 0) });
      return;
    }
    const k = S * (kind === "deck" ? 0.7 : 1);
    // flash
    this.sprite("flash", pos, { scale: (1.2 + 1.0 * w) * k, grow: 1.5 / 0.55, life: 0.15 + 0.03 * w });
    // fireball
    this.sprite("fire", pos, { scale: (1 + 0.9 * w) * k * 0.6, grow: 2.2, life: 0.36 + 0.07 * w, rise: 0.6 * k });
    if (crit) this.sprite("spark", pos, { scale: 2.4 * k, grow: 1.3, life: 0.3 + 0.04 * w });
    // shockwave rings (two from weight 3, three for a crit)
    const toCam = cam ? cam.position.clone().sub(pos).normalize() : null;
    const nr = crit ? 3 : w >= 3 ? 2 : 1;
    for (let i = 0; i < nr; i++) this.ring(pos, { radius: (3.6 + 2.6 * w) * k * 0.5, life: 0.38 + 0.06 * w + i * 0.16, delay: i * 0.09, normal: toCam, width: 0.2 });
    // debris
    const nd = Math.round((3 + 3 * w) * (crit ? 1.5 : 1) * (this.low ? 0.5 : 1));
    const debrisColor = kind === "deck" ? [0x8a5230, 0x6a3e20, 0xb07c48] : [0x3b3d46, 0x5c606b, 0x4a2f6e];
    for (let i = 0; i < nd; i++) {
      const a = this.seeded(i) * Math.PI * 2;
      const up = 3 + this.seeded(i + 11) * (3 + w);
      const out = (2 + this.seeded(i + 23) * 2.5) * (1 + w * 0.3);
      this.chip(pos, new THREE.Vector3(Math.cos(a) * out, up, Math.sin(a) * out), { color: debrisColor[i % 3], size: (0.14 + this.seeded(i + 5) * 0.16) * k, life: 0.62 + 0.09 * w + 0.4 });
    }
    // embers
    const ne = Math.round((3 + 3 * w) * (crit ? 1.5 : 1) * (this.low ? 0.5 : 1));
    for (let i = 0; i < ne; i++) {
      const v = new THREE.Vector3((this.seeded(i + 40) - 0.5) * 2, 2.4 + this.seeded(i + 41) * 2.2 * (1 + w * 0.3), (this.seeded(i + 42) - 0.5) * 2);
      this.sprite("ember", pos, { scale: 0.22 * k, grow: 0.6, life: 0.7 + 0.16 * w, vel: v, delay: this.seeded(i + 43) * 0.16, color: i % 2 ? 0xffc050 : 0xff7a3a });
    }
    // smoke
    const ns = Math.round((1 + w) * (crit ? 1.5 : 1) * (this.low ? 0.6 : 1));
    for (let i = 0; i < ns; i++) {
      const o = new THREE.Vector3((this.seeded(i + 60) - 0.5) * w * 0.5, 0, (this.seeded(i + 61) - 0.5) * w * 0.5).multiplyScalar(k);
      this.sprite("smoke", pos.clone().add(o), { scale: (1 + 0.6 * w) * k * 0.6, grow: 1.9, life: 1.1 + 0.18 * w, rise: (1.8 + 0.8 * w) * 0.4 * k, add: false, delay: 0.05 * i });
    }
    this.shake((0.18 + 0.1 * w) * (crit ? 1.3 : 1) * (kind === "deck" ? 1.15 : 1));
    if (crit) this.flashes.push({ age: 0, life: 0.26, peak: 0.7 });
  }
  waterColumn(pos, w = 2.5, S = 1) {
    for (let i = 0; i < 26; i++) {
      const a = this.seeded(i) * Math.PI * 2;
      const r = this.seeded(i + 7) * 0.8;
      this.chip(pos.clone().add(new THREE.Vector3(Math.cos(a) * r, 0, Math.sin(a) * r)), new THREE.Vector3(Math.cos(a) * 1.4, 6 + this.seeded(i + 3) * 5 * (w / 2.5), Math.sin(a) * 1.4), { color: i % 3 ? 0xf2f8ff : 0x9fd0ff, size: 0.22 * S, life: 1.4, gravity: 10 });
    }
    for (let i = 0; i < 4; i++) this.sprite("mist", pos.clone().add(new THREE.Vector3(0, 1 + i, 0)), { scale: 2.5 * S, grow: 1.8, life: 1.3, rise: 1.2, add: false, delay: i * 0.08 });
    this.shake(0.15);
  }
  fireworks(center, bursts = 3) {
    const cols = [0xf2b53a, 0xfff4dc, 0x3aa590, 0xd83a2c];
    for (let b = 0; b < bursts; b++) {
      const c = center.clone().add(new THREE.Vector3((b - 1) * 5, 6 + b * 1.5, (b % 2) * 3));
      for (let i = 0; i < 22; i++) {
        const a = (i / 22) * Math.PI * 2;
        const e = (this.seeded(i + b * 30) - 0.5) * 1.6;
        const v = new THREE.Vector3(Math.cos(a) * 6, 3 + e * 3, Math.sin(a) * 6);
        this.sprite("spark", c, { scale: 0.5, grow: 0.4, life: 1.1, vel: v, gravity: 5, delay: b * 0.32, color: cols[(i + b) % 4] });
      }
      this.sprite("flash", c, { scale: 3, grow: 2, life: 0.35, delay: b * 0.32, color: cols[b % 4] });
    }
  }
  sparks(pos, n = 14, color = 0x7fd8ff) {
    for (let i = 0; i < n; i++) {
      const v = new THREE.Vector3((this.seeded(i) - 0.5) * 5, 2 + this.seeded(i + 1) * 4, (this.seeded(i + 2) - 0.5) * 5);
      this.sprite("spark", pos, { scale: 0.25, grow: 0.3, life: 0.6, vel: v, gravity: 9, color, delay: this.seeded(i + 3) * 0.3 });
    }
    this.sprite("flash", pos, { scale: 1.2, grow: 1.5, life: 0.25, color });
  }
  // an object flying on an arc (hand-offs: order, pull request, approval, rejection)
  fly(obj, from, to, { dur = 1.4, height = 2.2, spin = 0, wobble = 0, onArrive } = {}) {
    this.scene.add(obj);
    obj.position.copy(from);
    this.flyers.push({ obj, from: from.clone(), to: to.clone(), dur, height, spin, wobble, age: 0, onArrive });
  }
  setRain(on, scene) {
    if (on && !this.rain) {
      const N = this.low ? 500 : 1400;
      const g = new THREE.InstancedMesh(new THREE.BoxGeometry(0.03, 0.9, 0.03), new THREE.MeshBasicMaterial({ color: 0xb8c6e8, transparent: true, opacity: 0.5, depthWrite: false }), N);
      g.frustumCulled = false;
      const seeds = Array.from({ length: N }, (_, i) => [this.seeded(i * 3), this.seeded(i * 3 + 1), this.seeded(i * 3 + 2)]);
      this.rain = { g, seeds, on: 1 };
      scene.add(g);
    }
    if (this.rain) this.rain.target = on ? 1 : 0;
  }
  update(dt, camera) {
    // real dt drives effects (they stay live during hit-stop)
    this.hitstop = Math.max(0, this.hitstop - dt);
    for (let i = this.parts.length - 1; i >= 0; i--) {
      const p = this.parts[i];
      p.age += dt;
      if (p.age < 0) continue;
      const k = p.age / p.life;
      if (k >= 1) {
        this.scene.remove(p.s);
        p.s.material.dispose();
        this.parts.splice(i, 1);
        continue;
      }
      const sc = p.scale * (1 + (p.grow - 1) * (1 - Math.pow(1 - k, 3)));
      p.s.scale.setScalar(sc);
      p.s.material.opacity = k < 0.1 ? k / 0.1 : 1 - (k - 0.1) / 0.9;
      if (p.vel) {
        p.vel.y -= p.gravity * dt;
        p.s.position.addScaledVector(p.vel, dt);
      }
      if (p.rise) p.s.position.y += (p.rise * dt) / p.life;
      if (p.drift) p.s.position.addScaledVector(p.drift, dt);
    }
    for (let i = this.rings.length - 1; i >= 0; i--) {
      const r = this.rings[i];
      r.age += dt;
      if (r.age < 0) continue;
      const k = r.age / r.life;
      if (k >= 1) {
        this.scene.remove(r.r);
        r.r.geometry.dispose();
        r.r.material.dispose();
        this.rings.splice(i, 1);
        continue;
      }
      const e = 1 - Math.pow(1 - k, 3);
      r.r.scale.setScalar(Math.max(0.01, r.radius * e));
      r.r.material.opacity = (1 - k) * 0.9;
      if (camera && !r.normalSet) r.r.quaternion.copy(camera.quaternion);
    }
    // debris chips
    const m4 = new THREE.Matrix4();
    const q = new THREE.Quaternion();
    const e = new THREE.Euler();
    let n = 0;
    for (let i = this.chips.length - 1; i >= 0; i--) {
      const c = this.chips[i];
      c.age += dt;
      if (c.age > c.life) {
        this.chips.splice(i, 1);
        continue;
      }
      c.v.y -= c.gravity * dt;
      c.p.addScaledVector(c.v, dt);
    }
    for (const c of this.chips) {
      e.set(c.age * c.spin, c.age * c.spin * 0.7, 0);
      q.setFromEuler(e);
      const s = c.size * (1 - Math.max(0, (c.age / c.life - 0.7) / 0.3));
      m4.compose(c.p, q, new THREE.Vector3(s, s, s));
      this.debris.setMatrixAt(n, m4);
      this.debris.setColorAt(n, c.c);
      n++;
    }
    this.debris.count = n;
    this.debris.instanceMatrix.needsUpdate = true;
    if (this.debris.instanceColor) this.debris.instanceColor.needsUpdate = true;
    // hand-off flyers
    for (let i = this.flyers.length - 1; i >= 0; i--) {
      const f = this.flyers[i];
      f.age += dt;
      const k = Math.min(1, f.age / f.dur);
      const ee = k < 0.5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2;
      f.obj.position.lerpVectors(f.from, f.to, ee);
      f.obj.position.y += Math.sin(Math.PI * ee) * f.height;
      if (f.wobble) f.obj.position.x += Math.sin(ee * Math.PI * 6) * f.wobble * (1 - ee);
      f.obj.rotation.y = ee * f.spin;
      if (k >= 1) {
        this.scene.remove(f.obj);
        this.flyers.splice(i, 1);
        f.onArrive?.();
      }
    }
    // rain
    if (this.rain) {
      const r = this.rain;
      r.on += ((r.target ?? 0) - r.on) * Math.min(1, dt * 1.5);
      r.g.visible = r.on > 0.02;
      r.g.material.opacity = 0.5 * r.on;
      if (r.g.visible && camera) {
        const t = performance.now() / 1000;
        const c = camera.position;
        r.seeds.forEach(([a, b, cc], i) => {
          const x = c.x + (a - 0.5) * 60,
            z = c.z + (b - 0.5) * 60 - 10;
          const y = 30 - (((t * 26 + cc * 30) % 30) + 30) % 30;
          m4.makeRotationZ(0.18).setPosition(x, y, z);
          r.g.setMatrixAt(i, m4);
        });
        r.g.instanceMatrix.needsUpdate = true;
      }
    }
    for (let i = this.flashes.length - 1; i >= 0; i--) {
      this.flashes[i].age += dt;
      if (this.flashes[i].age > this.flashes[i].life) this.flashes.splice(i, 1);
    }
    this.light = Math.max(0, this.light - dt * 0.0);
  }
  // screen shake on top of the camera rig (trauma^2)
  applyShake(camera, dt, t) {
    this.trauma = Math.max(0, this.trauma - 1.4 * dt);
    if (this.trauma <= 0) return;
    const s = this.trauma * this.trauma;
    const n = (k) => {
      const x = Math.sin(t * 32 * 12.9898 + k * 78.233) * 43758.5453;
      return (x - Math.floor(x)) * 2 - 1;
    };
    camera.position.x += 0.55 * s * n(1);
    camera.position.y += 0.55 * s * n(2);
    camera.rotation.z += 0.08 * s * n(3);
  }
  sceneFlash() {
    return this.flashes.reduce((a, f) => Math.max(a, f.peak * (1 - f.age / f.life)), 0);
  }
}
