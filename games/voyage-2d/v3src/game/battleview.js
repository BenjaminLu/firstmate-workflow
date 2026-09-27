// The battle on screen: the kraken's wind-ups, strikes into the deck or the sea,
// every blow on the HEAD with a layered explosion, the skill bar, the wind-up
// bar, counters and the weak point. The rules are the pure battle reducer
// (src/sim/battle.js); this file only draws them and forwards input.
import * as THREE from "three";
import { createBattle, stepBattle, attackState, SKILLS } from "../sim/battle.js";
import { kit } from "./props.js";

export class BattleView {
  constructor({ world, fx, sound, ui, camera, director }) {
    Object.assign(this, { world, fx, sound, ui, camera, director });
    this.b = null;
    this.playing = false;
    this.sel = 0;
    this.chainPick = [];
    this.splinters = new Map(); // section -> mesh
    this.target = null;
    this.windRear = 0;
    this.headRecoil = 0;
    this.reel = 0;
    this.pendingBlows = [];
    this.armedSkill = null;
  }
  // held tasks come from the voyage sim; the battle's round is their highest
  sync(s) {
    const arms = s.kraken.arms;
    if (!arms.length) {
      if (this.b) this.stop(true);
      this.ui.battleBand(null);
      this.ui.tags(null);
      this.ui.head(null);
      return;
    }
    const round = Math.max(3, ...arms.map((id) => s.tasks.find((t) => t.id === id)?.round || 3));
    if (this.b) {
      if (this.b.round !== round) this.b = stepBattle(this.b, { type: "setRound", round }).battle;
      if (this.b.arms !== arms.length) this.b = stepBattle(this.b, { type: "setArms", arms: arms.length }).battle;
    }
    this.round = round;
    this.held = arms.slice();
    this.inBattle = !!s.kraken.battle;
    this.ui.battleBand(this.inBattle && !s.kraken.fled ? { tasks: arms, round, playing: this.playing } : null);
  }
  play(on) {
    if (on && !this.inBattle) return;
    this.playing = on;
    if (on) {
      this.b = createBattle({ round: this.round || 3, arms: Math.max(1, this.held?.length || 1) });
      this.director.cut("battle", 2);
    } else this.stop(false);
    this.ui.battleBand(this.inBattle ? { tasks: this.held, round: this.round, playing: on } : null);
  }
  stop(clear) {
    this.playing = false;
    this.b = null;
    this.ui.windup(null);
    this.ui.skills(false);
    this.ui.ring("ring-aim", null);
    this.ui.ring("ring-brass", null);
    this.ui.ring("ring-charge", null);
    this.ui.vignette(0);
    this.clearTarget();
    if (clear) for (const m of this.splinters.values()) m.parent?.remove(m);
    if (clear) this.splinters.clear();
  }
  // ---------------------------------------------------------------- positions
  headWorld() {
    const K = this.world.kraken;
    if (!K) return null;
    return K.rig.head.localToWorld(new THREE.Vector3(0, 22 * 0.25, 4 * 0.25));
  }
  toScreen(v) {
    const p = v.clone().project(this.camera);
    return { x: (p.x * 0.5 + 0.5) * innerWidth, y: (-p.y * 0.5 + 0.5) * innerHeight, vis: p.z < 1 };
  }
  section(i) {
    const S = this.world.ship;
    const rs = S.userData.railSections;
    return S.localToWorld(rs[i % rs.length].clone());
  }
  // ---------------------------------------------------------------- input
  skillDown(id) {
    if (!this.playing || !this.b) return;
    if (id === "broadside") {
      if (this.b.aim === null) this.step({ type: "broadsideAim" });
      else this.step({ type: "broadsideFire" });
    } else if (id === "harpoon") this.step({ type: "harpoonStart" });
    else if (id === "sail") this.step({ type: "sail" });
    else if (id === "order") this.step({ type: "order" });
    else if (id === "repair") this.step({ type: "repair" });
    else if (id === "chain") {
      if (this.chainPick.length === 2) this.step({ type: "chain", arms: this.chainPick });
      else this.step({ type: "chain", arm: this.sel });
      this.chainPick = [];
    }
  }
  skillUp(id, cancel) {
    if (!this.playing || !this.b) return;
    if (id === "harpoon") this.step(cancel ? { type: "harpoonCancel" } : { type: "harpoonRelease" });
  }
  headTap() {
    if (!this.playing || !this.b) return;
    if (this.b.counterUntil && this.b.t <= this.b.counterUntil) this.step({ type: "counter" });
    else if (this.b.aim !== null) this.step({ type: "broadsideFire" });
    else this.step({ type: "broadsideAim" });
  }
  armTap(i) {
    this.sel = i;
    if (!this.playing) return;
    this.chainPick = [...this.chainPick.filter((x) => x !== i), i].slice(-2);
    if (this.chainPick.length === 2) {
      this.step({ type: "chain", arms: this.chainPick });
      this.chainPick = [];
    }
  }
  key(k, down) {
    if (!this.playing) return false;
    const map = { 1: "broadside", 2: "chain", 3: "harpoon", 4: "sail", 5: "order", 6: "repair", " ": "sail" };
    if (map[k]) {
      down ? this.skillDown(map[k]) : this.skillUp(map[k], false);
      return true;
    }
    if (k === "Enter" && down) {
      if (this.b.counterUntil) this.step({ type: "counter" });
      else this.skillDown("broadside");
      return true;
    }
    if ((k === "ArrowLeft" || k === "ArrowRight") && down) {
      this.sel = (this.sel + (k === "ArrowLeft" ? -1 : 1) + this.b.arms) % this.b.arms;
      return true;
    }
    if (k === "Escape" && down) {
      this.play(false);
      return true;
    }
    return false;
  }
  step(action) {
    if (!this.b) return;
    const r = stepBattle(this.b, action);
    this.b = r.battle;
    for (const e of r.events) this.onEvent(e);
  }
  // ---------------------------------------------------------------- real voyage events in a battle
  realStrike(e) {
    // a rejected round in battle: the kraken strikes the deck
    const sec = (e.seq || 0) % 4;
    this.strikeFx(sec, 3);
  }
  realPush() {
    const h = this.headWorld();
    if (!h) return;
    this.shotToHead(2, "push");
  }
  realStorm() {
    this.world.setStorm(1);
    this.fx.setRain(true, this.world.scene);
    this.world.breakLight(0.4, 0.3);
    this.sound.play("boom");
  }
  victory() {
    const K = this.world.kraken;
    this.sound.play("fanfare");
    this.world.breakLight(3.4, 0.5);
    this.ui.banner("Victory! Only an approval wins, and it came");
    if (K) {
      const p = K.group.position.clone();
      this.director.after(1.3, () => this.fx.explode(p.clone().add(new THREE.Vector3(0, 0.5, 0)), 3.5, "sea"));
      K.riseTarget = 0;
      K.rig.setExpression("hurt");
    }
    for (const c of Object.values(this.world.crew)) c.shot("cheer", 0.6 + Math.random() * 0);
    this.stop(true);
  }
  // ---------------------------------------------------------------- battle events -> screen
  onEvent(e) {
    const S = this.sound;
    switch (e.type) {
      case "attack_start": {
        const delay = e.delay || 0;
        this.director.after(delay, () => {
          S.play(e.pattern === "slam" || e.pattern === "feint" ? "horn" : e.pattern === "jab" ? "tick" : "rising");
          this.setTarget(e.section);
        });
        break;
      }
      case "strike":
        this.strikeFx(e.section, e.weight);
        break;
      case "into_sea": {
        const p = this.section(e.section);
        const S2 = this.world.ship;
        const out = S2.localToWorld(new THREE.Vector3(0, 0, -2.2)).sub(S2.localToWorld(new THREE.Vector3())).setY(0);
        p.add(out).setY(0);
        this.fx.explode(p, 2.5, "sea");
        S.play("splash");
        this.clearTarget();
        this.lunge(0.7);
        break;
      }
      case "dodge":
        this.world.heelKick(-16 * 0.12);
        if (e.result === "perfect") {
          S.play("chime");
          this.ui.combo(e.combo > 1 ? `Combo ×${e.combo}` : "Perfect dodge");
          this.slow = 0.48;
        } else if (e.result === "dodge") this.ui.combo("Dodged. Counter!");
        else if (e.result === "early") this.ui.combo("Too early");
        break;
      case "blow":
        this.shotToHead(e.weight, e.source, e);
        break;
      case "reel":
        this.reel = 3;
        this.ui.combo("The kraken reels");
        this.world.kraken?.rig.setExpression("hurt");
        this.director.after(3, () => this.world.kraken?.rig.setExpression("glare"));
        break;
      case "bound":
        S.play("clang");
        break;
      case "volley": {
        const Sh = this.world.ship;
        const guns = Sh.userData.guns.filter((g) => g.side < 0);
        guns.forEach((g, i) => this.director.after(i * 0.045, () => this.fx.explode(Sh.localToWorld(g.pos.clone()), 1, "gun", { scale: 1.2 })));
        S.play("salvo");
        this.world.crew.captain?.shot("order");
        let i = 0;
        for (const c of Object.values(this.world.crew)) if (c.id !== "captain") c.shot("salute", i++ * 0.03);
        break;
      }
      case "repaired": {
        const m = this.splinters.get(e.section);
        const p = this.section(e.section);
        this.fx.explode(p, 1, "repair");
        S.play("thud");
        if (m) m.parent?.remove(m);
        this.splinters.delete(e.section);
        break;
      }
      case "broadside":
        this.ui.combo(e.grade === "perfect" ? "Perfect broadside" : e.grade === "good" ? "Good broadside" : "Glancing");
        break;
      case "attack_cancel":
        this.clearTarget();
        break;
      case "cooldown":
        this.ui.combo(`${SKILLS[e.skill].name} is reloading`);
        break;
      case "nothing_to_repair":
        this.ui.combo("No splintered rail to repair");
        break;
    }
  }
  shotToHead(weight, source, e = {}) {
    const head = this.headWorld();
    if (!head) return;
    const S = this.world.ship;
    const guns = S.userData.guns.filter((g) => g.side < 0);
    const g = guns[(this.fx.n + (e.gun || 0)) % guns.length];
    const from = S.localToWorld(g.pos.clone());
    const ball = new THREE.Mesh(new THREE.SphereGeometry(0.18, 8, 6), new THREE.MeshStandardMaterial({ color: 0x2a2c34, roughness: 0.4, metalness: 0.6 }));
    if (source === "harpoon") ball.scale.set(0.6, 0.6, 4);
    this.director.after(e.delay || 0, () => {
      this.fx.explode(from, 1, "gun", { scale: 0.9 });
      this.sound.play("cannon");
      const spread = new THREE.Vector3(((this.fx.n % 3) - 1) * 0.6, ((this.fx.n % 2) - 0.5) * 0.5, 0);
      this.fx.fly(ball, from, head.clone().add(spread), {
        dur: 0.45,
        height: 1.5,
        onArrive: () => {
          this.fx.explode(head.clone().add(spread), weight, "head", { crit: !!e.crit, scale: 1.4, cam: this.camera });
          this.sound.play(e.crit ? "clang" : "boom");
          this.headRecoil = Math.min(1, 0.25 + weight * 0.12);
          const K = this.world.kraken;
          if (K) {
            K.rig.setExpression("hurt");
            this.director.after(0.5, () => this.reel <= 0 && K.rig.setExpression("glare"));
          }
          if (e.crit) this.ui.combo(`Critical hit${e.combo > 1 ? ` ×${e.combo}` : ""}!`);
        },
      });
    });
  }
  strikeFx(sec, weight) {
    const p = this.section(sec);
    this.lunge(1);
    this.director.after(0.15, () => {
      this.fx.explode(p, weight, "deck", { cam: this.camera });
      this.sound.play("boom");
      this.world.heelKick(12 + 2 * weight);
      this.clearTarget();
      if (!this.splinters.has(sec)) {
        const m = kit.plank();
        m.scale.setScalar(1.8);
        m.rotation.set(0.5, 0.3, 0.8);
        const S = this.world.ship;
        S.add(m);
        m.position.copy(S.userData.railSections[sec]).add(new THREE.Vector3(0, 0.3, 0.3));
        this.splinters.set(sec, m);
      }
    });
  }
  lunge(k) {
    const K = this.world.kraken;
    if (!K) return;
    K.lungeT = 0.46;
    K.lungeK = k;
  }
  setTarget(sec) {
    this.clearTarget();
    const ring = new THREE.Mesh(new THREE.RingGeometry(0.7, 1.0, 32), new THREE.MeshBasicMaterial({ color: 0xff4028, transparent: true, opacity: 0.8, depthWrite: false, side: THREE.DoubleSide }));
    ring.rotation.x = -Math.PI / 2;
    const glow = new THREE.Mesh(new THREE.CircleGeometry(0.8, 24), new THREE.MeshBasicMaterial({ color: 0xff5030, transparent: true, opacity: 0.4, depthWrite: false, blending: THREE.AdditiveBlending }));
    glow.rotation.x = -Math.PI / 2;
    const g = new THREE.Group();
    g.add(ring, glow);
    const S = this.world.ship;
    S.add(g);
    g.position.copy(S.userData.railSections[sec]).add(new THREE.Vector3(0, 0.15, 0.9));
    this.target = g;
  }
  clearTarget() {
    if (this.target) this.target.parent?.remove(this.target);
    this.target = null;
  }
  // ---------------------------------------------------------------- per frame
  update(dt, sim) {
    const K = this.world.kraken;
    const now = performance.now() / 1000;
    // kraken pose: arms sway, the attacking arm draws up, bound arms freeze
    let a = null;
    if (this.playing && this.b) {
      const slowK = this.slow > 0 ? 0.3 : 1;
      this.slow = Math.max(0, (this.slow || 0) - dt);
      const r = stepBattle(this.b, { type: "tick", dt: dt * slowK });
      this.b = r.battle;
      for (const e of r.events) this.onEvent(e);
      a = attackState(this.b);
      this.ui.windup(a && a.p >= 0 ? a : null);
      this.ui.skills(true, this.b.cooldowns, this.b.t);
      this.ui.vignette(this.slow > 0 ? 0.8 : 0);
      // broadside ring and harpoon charge (screen space around the head)
      const hp = this.headWorld();
      const hs = hp ? this.toScreen(hp) : null;
      const pxScale = Math.max(0.6, Math.min(2, innerHeight / 900));
      if (hs && this.b.aim !== null) {
        const k = Math.min(1, (this.b.t - this.b.aim) / 1.1);
        this.ui.ring("ring-aim", hs, (96 - 96 * k) * pxScale + 2, "#f4ead2", 3);
        this.ui.ring("ring-brass", hs, 26 * pxScale, "#c9a44a", 3);
      } else {
        this.ui.ring("ring-aim", null);
        this.ui.ring("ring-brass", null);
      }
      if (hs && this.b.charge !== null) this.ui.ring("ring-charge", hs, (14 + 44 * Math.min(1, (this.b.t - this.b.charge) / 1.5)) * pxScale, "#c8402c", 4);
      else this.ui.ring("ring-charge", null);
    } else {
      this.ui.windup(null);
      this.ui.skills(false);
    }
    if (K) {
      const lift = [];
      const frozen = [];
      if (a && this.b) {
        lift[a.arm] = a.hold ? 0.55 + Math.sin(now * 40) * 0.05 : a.p;
        for (const i of this.b.bound) frozen[i] = true;
      }
      K.rig.setPose("tower", now, { lift, frozen });
      // head rears with the bar, recoils from blows, lunges on strikes, sinks in a reel
      const rearTarget = a ? a.p * ({ slam: 1, feint: 1, combo: 0.75, jab: 0.45 }[a.pattern] || 1) : 0;
      this.windRear += (rearTarget - this.windRear) * Math.min(1, dt * 10);
      this.headRecoil = Math.max(0, this.headRecoil - dt * 2.4);
      K.rear = this.windRear + this.headRecoil * 0.6;
      if (K.lungeT > 0) {
        K.lungeT -= dt;
        K.lunge = Math.sin(Math.PI * (1 - K.lungeT / 0.46)) * (K.lungeK || 1);
      } else K.lunge = 0;
      this.reel = Math.max(0, this.reel - dt);
      if (this.reel > 0) K.rise = Math.min(K.rise, 0.82);
      // target ring pulses with the bar
      if (this.target && a) {
        this.target.scale.setScalar(1 + a.p * 0.8 + Math.sin(now * 12) * 0.08);
        this.target.children[1].material.opacity = 0.2 + 0.75 * a.p;
      }
      // HTML: the head's hit area, arm tags
      const hp = this.headWorld();
      const hs = hp && this.toScreen(hp);
      const edge = hp && this.toScreen(hp.clone().add(new THREE.Vector3(0, 3.2, 0)));
      const counter = this.b && this.b.counterUntil && this.b.t <= this.b.counterUntil;
      this.ui.head(this.inBattle && hs && hs.vis && K.rise > 0.5 && !sim.kraken.fled ? { ...hs, r: Math.abs(edge.y - hs.y) * 1.3 } : null, counter, counter && this.b.weakPoint);
      const tags = this.held?.map((id, i) => {
        const tip = K.rig.armTips[i];
        if (!tip) return { id, visible: false };
        const w = K.rig.group.localToWorld(tip.clone());
        const sc = this.toScreen(w);
        const t = sim.tasks.find((x) => x.id === id);
        return { id, round: t?.round || 3, x: sc.x, y: sc.y, visible: sc.vis && K.rise > 0.6, bound: this.b?.bound.includes(i), sel: this.playing && (this.sel === i || this.chainPick.includes(i)) };
      });
      this.ui.tags(K.rise > 0.3 && !sim.kraken.fled ? tags : null);
    } else {
      this.ui.head(null);
      this.ui.tags(null);
    }
    // the critical hit's scene flash
    this.ui.flash(this.fx.sceneFlash());
  }
}
