// The director: every sim event becomes something visible and animated on the
// ship (the rituals of prototype v2 / T-086), and the cinematic camera picks a
// shot for it. It reads events; it never changes the simulation.
import * as THREE from "three";
import * as P from "../engine/models/props.js";
import { kit } from "./props.js";
import { rankName } from "../sim/sim.js";

const HEM = { working: "#2a2016", review: "#3aa590", blocked: "#c8402c", waiting: "#c9a44a", idle: "#b8b0a0", down: "#c8402c", standby: "#3aa590", walking: "#2a2016" };

export class Director {
  constructor({ world, fx, sound, ui, camera, controls, getSim, rituals }) {
    Object.assign(this, { world, fx, sound, ui, camera, controls, getSim, rituals });
    this.timers = [];
    this.shot = null; // current cinematic shot
    this.shotUntil = 0;
    this.cinematic = true;
    this.placard = null;
    this.helmSpin = null;
    this.bellSwing = null;
    this.haulers = new Set();
    this.camPos = new THREE.Vector3();
    this.camTgt = new THREE.Vector3();
    this.camInit = false;
  }
  after(sec, fn) {
    this.timers.push({ at: performance.now() / 1000 + sec, fn });
  }
  crew(id) {
    return this.world.crew[id];
  }
  worldPos(c, up = 1.6) {
    const v = new THREE.Vector3(0, c.height * up * 0.6, 0);
    return c.group.localToWorld(v);
  }
  // ---------------------------------------------------------------- pennants
  refreshPennants(s) {
    for (const m of s.crew) {
      const c = this.crew(m.id);
      if (!c) continue;
      const t = m.task ? s.tasks.find((x) => x.id === m.task) : null;
      const stateWord = { working: "working", walking: "to station", standby: "in review", blocked: "blocked", waiting: "waiting on you", down: "down", idle: "idle" }[m.state] || m.state;
      const rank = m.role === "worker" || m.role === "reviewer" ? m.rank : 0;
      const top = m.role === "worker" ? rank === 4 : rank === 2;
      const key = [m.name, m.state, m.task, rank, t?.round].join("|");
      if (c._pennantKey === key) continue;
      c._pennantKey = key;
      c.setPennant({
        name: m.role === "captain" ? "Captain" : m.role === "firstmate" ? "Firstmate" : m.name,
        line2: m.role === "worker" ? (t ? `${t.id} ${stateWord}` : rankName(m)) : m.role === "reviewer" ? rankName(m) : m.role === "captain" ? "on the bow" : "at the helm",
        line3: m.vendor && m.role !== "firstmate" ? m.vendor : "",
        hem: m.role === "captain" ? "#c8402c" : HEM[m.state] || "#2a2016",
        braid: rank,
        braidTop: top,
        reviewer: m.role === "reviewer",
      });
    }
  }
  // ---------------------------------------------------------------- camera
  // shots in ship-local space; the ship's transform places them in the world
  shotDef(name) {
    const S = this.world.ship;
    const L = (x, y, z) => S.localToWorld(new THREE.Vector3(x, y, z));
    const t = performance.now() / 1000;
    const tall = innerWidth / innerHeight < 1;
    const cap = this.crew("captain");
    const D = {
      wide: () => ({ pos: L(-2 + Math.sin(t * 0.05) * 6, 9 + Math.sin(t * 0.07) * 1.5, -30 - (tall ? 12 : 0)), tgt: L(2, 5.5, 0), fov: tall ? 66 : 50 }),
      bow: () => ({ pos: L(17, 5.5, -10 - (tall ? 4 : 0)), tgt: cap ? this.worldPos(cap, 1).add(new THREE.Vector3(0, -0.3, 0)) : L(10, 4, 0), fov: tall ? 62 : 46 }),
      helm: () => ({ pos: L(-4, 6.5, -9 - (tall ? 4 : 0)), tgt: L(-9.2, 4, 0.5), fov: tall ? 62 : 46 }),
      review: () => ({ pos: L(-2, 6, -10 - (tall ? 4 : 0)), tgt: L(-7.5, 4.2, -2.5), fov: tall ? 62 : 46 }),
      waist: () => ({ pos: L(3, 6.5, -13 - (tall ? 5 : 0)), tgt: L(1, 2.8, -1), fov: tall ? 62 : 48 }),
      salvo: () => ({ pos: L(-16, 2.6, -18 - (tall ? 6 : 0)), tgt: L(6, 2.4, -2), fov: tall ? 66 : 50 }),
      battle: () => {
        const k = this.world.kraken;
        const kp = k ? k.group.position.clone() : L(15, 0, -5);
        const mid = L(4, 5, 0).lerp(kp, 0.45);
        mid.y = 6.5;
        return { pos: L(-18, 11, -34 - (tall ? 14 : 0)), tgt: mid, fov: tall ? 70 : 54 };
      },
      port: () => ({ pos: L(-6, 16, -34), tgt: L(2, 10, 0), fov: tall ? 66 : 52 }),
    };
    return (D[name] || D.wide)();
  }
  cut(name, hold = 3.5) {
    if (!this.cinematic) return;
    this.shot = name;
    this.shotUntil = performance.now() / 1000 + hold;
  }
  updateCamera(dt) {
    if (!this.cinematic || !this.world.ship) return;
    const now = performance.now() / 1000;
    let name = this.shot && now < this.shotUntil ? this.shot : this.getSim().kraken.arms.length && !this.getSim().kraken.fled ? "battle" : "wide";
    const d = this.shotDef(name);
    if (!this.camInit) {
      this.camPos.copy(d.pos);
      this.camTgt.copy(d.tgt);
      this.camInit = true;
    }
    const k = Math.min(1, dt * 1.6);
    this.camPos.lerp(d.pos, k);
    this.camTgt.lerp(d.tgt, k);
    this.camera.position.copy(this.camPos);
    this.camera.fov += (d.fov - this.camera.fov) * k;
    this.camera.updateProjectionMatrix();
    this.camera.lookAt(this.camTgt);
    this.controls.target.copy(this.camTgt);
  }
  // ---------------------------------------------------------------- props on the ship
  ringBell(n = 1) {
    const b = this.world.ship?.userData.bell;
    for (let i = 0; i < n; i++) {
      this.after(i * 0.7, () => {
        this.bellSwing = { start: performance.now() / 1000 };
        this.sound.play("bell");
      });
    }
    void b;
  }
  spinHelm(turns = 2, dur = 1.2) {
    this.helmSpin = { start: performance.now() / 1000, dur, turns, from: this.world.ship?.userData.wheel?.rotation.z || 0 };
  }
  handoff(kind, fromC, toC, onArrive) {
    if (!fromC || !toC) return onArrive?.();
    const obj =
      kind === "pr" ? P.buildScroll({ scale: 0.05 }) : kind === "approval" ? P.buildScroll({ scale: 0.05, glow: true }) : kind === "rejection" ? kit.flag(0xd83a2c) : kind === "list" ? kit.criteriaList() : P.buildScroll({ scale: 0.05, glow: true });
    obj.scale.multiplyScalar(1.6);
    const opt = { pr: { height: 1.4, spin: 0.7 }, order: { height: 2.2, spin: Math.PI * 2 }, approval: { height: 1.0, spin: 0 }, rejection: { height: 0.7, wobble: 0.25 }, list: { height: 1.2, spin: 0 } }[kind] || {};
    this.fx.fly(obj, this.worldPos(fromC), this.worldPos(toC), { dur: 1.4, ...opt, onArrive: () => (toC.shot("bark"), toC.swellPennant(), onArrive?.()) });
    this.sound.play("paper");
  }
  raisePlacard(on, color) {
    const S = this.world.ship;
    if (on && !this.placard) {
      this.placard = kit.decisionPlacard(color);
      const fm = this.crew("captain");
      fm.group.add(this.placard);
      this.placard.position.set(0.9, fm.height + 0.1, 0);
      this.placard.scale.setScalar(0.01);
      this.placard.userData.grow = 0;
    } else if (!on && this.placard) {
      this.placard.parent?.remove(this.placard);
      this.placard = null;
    }
    void S;
  }
  // ---------------------------------------------------------------- the event map
  handle(e, s) {
    const R = this.rituals;
    const c = (id) => (id ? this.crew(id) : null);
    const w = c(e.worker);
    switch (e.type) {
      case "order": {
        if (e.resume || e.sendback) {
          this.ui.banner("Aye, captain.");
          if (R.order) this.orderRitual(s, null, e);
          break;
        }
        this.orderRitual(s, w, e);
        break;
      }
      case "worker_walk": {
        if (!w) break;
        const idx = w.slot ?? 0;
        const deck = e.station || "idle";
        const spot = this.world.stationSpot(deck, idx, e.action);
        w.clearShot("slump");
        this.haulers.delete(w.id);
        w.walkTo(spot.pos, spot.yaw, e.back ? 1.8 : 2.2, () => {
          w.baseYaw = spot.yaw;
          w.setLoop(deck === "idle" ? e.action || "lean" : e.action || "idle", spot.pos);
        });
        break;
      }
      case "work_start":
        if (w && !w.walk) w.setLoop(e.action, w.pos);
        break;
      case "commit_pushed": {
        if (!w) break;
        const deck = s.crew.find((m) => m.id === e.worker)?.station;
        w.shot(e.n % 2 && deck !== "top" ? "carryCrate" : "hammerHome");
        this.sound.play(e.n % 2 ? "thud" : "thud", 0.2);
        if (e.inBattle) this.onBattlePush?.(e);
        break;
      }
      case "gate_failed": {
        this.world.setStorm(1);
        this.fx.setRain(true, this.world.scene);
        this.world.breakLight(0.5, 0.25); // lightning
        this.sound.play("boom");
        if (R.weather && w) {
          // weather, not blame: he and up to two idle hands haul one line together
          const idle = s.crew.filter((m) => m.role === "worker" && m.state === "idle").slice(0, 2);
          const haul = [w, ...idle.map((m) => c(m.id))];
          haul.forEach((h, i) => {
            if (!h) return;
            this.haulers.add(h.id);
            const spot = this.world.stationSpot("amidships", i, "haul");
            h.walkTo(spot.pos, Math.PI, 1.4, () => h.setLoop("haul", spot.pos));
          });
        } else w?.shot("slump");
        this.cut("waist", 3.5);
        if (e.inBattle) this.onBattleStorm?.();
        break;
      }
      case "gate_green": {
        this.clearing(s);
        if (w) {
          const m = s.crew.find((x) => x.id === w.id);
          const spot = this.world.stationSpot(m.station || "idle", w.slot, m.action);
          w.walkTo(spot.pos, spot.yaw, 1.8, () => w.setLoop(m.action || "lean", spot.pos));
        }
        for (const id of this.haulers) {
          if (id === e.worker) continue;
          const h = c(id);
          const spot = this.world.stationSpot("idle", h.slot, "lean");
          h.walkTo(spot.pos, spot.yaw, 1.8, () => h.setLoop("lean", spot.pos));
        }
        this.haulers.clear();
        break;
      }
      case "pr_opened": {
        const rv = c("reviewer-1");
        this.handoff("pr", w, rv, () => rv?.setLoop("review"));
        this.cut("review", 3.5);
        break;
      }
      case "ask_pass_criteria":
        w?.shot("raiseScroll");
        this.sound.play("paper");
        break;
      case "criteria_returned": {
        const rv = c("reviewer-1");
        rv?.shot("answerList");
        this.after(0.6, () => this.handoff("list", rv, w));
        break;
      }
      case "review_rejected": {
        const rv = c("reviewer-1");
        rv?.shot("pointBack");
        rv?.setLoop("idle");
        this.after(0.3, () => this.handoff("rejection", rv, w));
        break;
      }
      case "review_approved": {
        const rv = c("reviewer-1");
        rv?.setLoop("idle");
        this.handoff("approval", rv, c("firstmate"), () => {
          if (e.firstRound && R.salute) {
            // the salute: reviewer, then the worker 0.22 s later; pennants swell; the whistle
            rv?.shot("salute");
            rv?.swellPennant();
            w?.shot("salute", 0.22);
            this.after(0.22, () => w?.swellPennant());
            this.sound.play("whistle");
            this.ui.banner("A salute: approved on the first round");
          }
        });
        this.cut("review", 3);
        break;
      }
      case "decision_requested": {
        const col = { merge: 0xf2b53a, choice: 0x1f2f86, kraken: 0xd83a2c, scope: 0x3aa590 }[e.decision.kind] || 0xf2b53a;
        this.raisePlacard(true, col);
        this.ringBell(1);
        this.cut("bow", 2.5);
        if (e.decision.task) {
          const t = s.tasks.find((x) => x.id === e.decision.task);
          const wk = t?.worker && c(t.worker);
          if (wk && e.decision.kind === "choice") wk.setLoop("idle");
        }
        break;
      }
      case "decision_answered":
        if (!s.decisions.length) this.raisePlacard(false);
        if (e.effect === "proceed" || e.effect === "rescope") {
          const t = s.tasks.find((x) => x.id === e.task);
          const m = t?.worker && s.crew.find((x) => x.id === t.worker);
          const wk = m && c(m.id);
          if (wk && m.action) wk.setLoop(m.action, wk.pos);
        }
        break;
      case "merged":
        this.salvo(s, e);
        break;
      case "making_port":
        this.after(0.9, () => {
          if (!R.port) return;
          this.fx.fireworks(this.world.ship.localToWorld(new THREE.Vector3(0, 14, 0)), 3);
          this.sound.play("fireworks");
          this.ringBell(2);
          this.ui.banner(`Making port: ${e.port}`);
          this.cut("port", 3.5);
        });
        break;
      case "promoted": {
        const m = c(e.crew);
        this.after(2.2, () => {
          m?.shot("spin");
          m?.swellPennant();
          this.ui.banner(`${e.crew} rated ${e.rank}`);
        });
        break;
      }
      case "task_new":
      case "island": {
        if (e.type === "island" && !e.spotted) break;
        // the lookout spots an island: whoever is free raises the spyglass
        const look = c("worker-3");
        const m = s.crew.find((x) => x.id === "worker-3");
        if (look && m?.state === "idle") {
          look.setLoop("lookout", look.pos);
          this.after(2.6, () => {
            const mm = this.getSim().crew.find((x) => x.id === "worker-3");
            if (mm?.state === "idle") look.setLoop("lean", look.pos);
          });
        }
        this.world.parrot?.setPose?.("flap");
        this.after(1.2, () => this.world.parrot?.setPose?.("perch"));
        break;
      }
      case "worker_crashed":
      case "vendor_unavailable": {
        w?.shot("slump");
        const fm = c("firstmate");
        if (fm) {
          this.fx.sparks(this.worldPos(fm, 1.1));
          this.sound.play("spark");
          this.after(0.5, () => this.fx.sparks(this.worldPos(fm, 1.2)));
        }
        break;
      }
      case "recovered":
        w?.clearShot("slump");
        break;
      case "kraken_arm": {
        const K = this.world.setKrakenArms(s.kraken.arms.length);
        if (K) K.riseTarget = 1;
        if (K) K.farTarget = 0;
        this.sound.play("horn");
        this.world.setStorm(Math.max(this.world.stormTarget, 0.55));
        this.cut("battle", 4);
        break;
      }
      case "battle_begin":
        this.cut("battle", 3);
        break;
      case "kraken_strike":
        this.onRealStrike?.(e);
        break;
      case "victory":
        this.onVictory?.(e);
        break;
      case "kraken_let_go":
      case "kraken_down": {
        const K = this.world.kraken;
        if (!K) break;
        if (!s.kraken.arms.length || e.type === "kraken_down") {
          K.riseTarget = 0;
          this.after(2.2, () => {
            if (!this.getSim().kraken.arms.length) this.world.setKrakenArms(0);
          });
          if (e.how === "dropped") this.fx.explode(K.group.position.clone().add(new THREE.Vector3(0, 1, 0)), 3.5, "sea");
        } else this.world.setKrakenArms(s.kraken.arms.length);
        this.world.setStorm(this.stormLevel(s));
        break;
      }
      case "kraken_far":
        if (this.world.kraken) this.world.kraken.farTarget = 1;
        break;
      case "parked":
      case "dropped":
        this.world.setStorm(this.stormLevel(s));
        break;
    }
    // weather follows the state: a squall for a red gate or a card waiting on the captain
    if (["decision_requested", "decision_answered", "gate_green", "merged", "parked", "dropped"].includes(e.type)) {
      this.world.setStorm(this.stormLevel(s));
      this.fx.setRain(this.stormLevel(s) >= 1, this.world.scene);
    }
  }
  stormLevel(s) {
    const red = Object.values(s.gate).some((g) => g === "red");
    if (red) return 1;
    if (s.kraken.arms.length && !s.kraken.fled) return 0.55;
    if (s.decisions.length) return 0.35;
    return 0;
  }
  // ---------------------------------------------------------------- rituals
  orderRitual(s, worker, e) {
    const R = this.rituals;
    const cap = this.crew("captain");
    const fm = this.crew("firstmate");
    if (!R.order) {
      this.handoff("order", fm, worker);
      return;
    }
    // D-1010: bell at 0, whistle at 180 ms, captain raises the cutlass, the helm
    // spins twice, the crew salute (250 ms + 45 ms each), the order passes
    // captain -> firstmate at 300 ms, then firstmate -> worker
    this.ringBell(1);
    this.after(0.18, () => this.sound.play("whistle"));
    cap?.shot("order");
    fm?.shot("whistle");
    this.spinHelm(2, 1.2);
    let i = 0;
    for (const m of s.crew) {
      const cm = this.crew(m.id);
      if (!cm || m.id === "captain" || m.id === "firstmate" || m.state === "walking" || m.state === "down") continue;
      cm.shot("salute", 0.25 + i++ * 0.045);
    }
    this.after(0.3, () => this.handoff("order", cap, fm, () => worker && this.handoff("order", fm, worker)));
    this.ui.banner("Aye, captain. Orders away");
    this.cut("bow", 2.4);
    this.after(2.4, () => this.cut("helm", 2.4));
  }
  clearing(s) {
    if (!this.rituals.clearing) return;
    this.world.breakLight(1.6, 0.42);
    this.world.setStorm(this.stormLevel(s));
    this.fx.setRain(false, this.world.scene);
    let i = 0;
    for (const m of s.crew) {
      const cm = this.crew(m.id);
      if (cm && m.state !== "down") cm.shot("cheer", Math.min(i++ * 0.03, 0.3));
    }
    this.sound.play("cheer");
    this.ui.banner("Clearing, and a cheer");
  }
  salvo(s, e) {
    const S = this.world.ship;
    const cap = this.crew("captain");
    cap?.shot("stamp");
    this.sound.play("thud", 0.35);
    if (!this.rituals.salvo) {
      this.ui.banner("Merged into main");
      return;
    }
    const guns = (S.userData.guns || []).filter((g) => g.side < 0);
    guns.forEach((g, i) => {
      this.after(0.35 + i * 0.075, () => {
        const p = S.localToWorld(g.pos.clone());
        this.fx.explode(p, 1, "gun", { scale: 1.2 });
      });
    });
    this.after(0.35, () => this.sound.play("salvo"));
    this.after(0.35 + guns.length * 0.075 + 0.3, () => this.ringBell(1));
    this.world.breakLight(1.6, 0.42);
    let i = 0;
    for (const m of s.crew) {
      const cm = this.crew(m.id);
      if (cm && m.state !== "down" && m.id !== "captain") cm.shot("cheer", 0.6 + i++ * 0.045);
    }
    this.ui.banner("Ahoy! Merged into main");
    this.cut("salvo", 3.2);
    this.fx.shake(0.25);
  }
  // ---------------------------------------------------------------- per frame
  update(dt) {
    const now = performance.now() / 1000;
    for (let i = this.timers.length - 1; i >= 0; i--)
      if (now >= this.timers[i].at) {
        const f = this.timers[i].fn;
        this.timers.splice(i, 1);
        f();
      }
    const U = this.world.ship?.userData;
    if (this.helmSpin && U?.wheel) {
      const k = Math.min(1, (now - this.helmSpin.start) / this.helmSpin.dur);
      const e = k < 0.5 ? 2 * k * k : 1 - Math.pow(-2 * k + 2, 2) / 2;
      U.wheel.rotation.z = this.helmSpin.from + e * this.helmSpin.turns * Math.PI * 2;
      if (k >= 1) this.helmSpin = null;
    }
    if (this.bellSwing && U?.bell) {
      const k = (now - this.bellSwing.start) / 1.8;
      U.bell.rotation.x = k >= 1 ? 0 : Math.sin(k * Math.PI * 5) * 0.38 * (1 - k);
      if (k >= 1) this.bellSwing = null;
    }
    if (this.placard) {
      this.placard.userData.grow = Math.min(1, this.placard.userData.grow + dt * 3);
      this.placard.scale.setScalar(Math.max(0.01, this.placard.userData.grow) * (1 + Math.sin(now * 3) * 0.03));
    }
    this.updateCamera(dt);
  }
}
