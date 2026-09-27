// The director turns the board's events into the crew's rituals on deck, and chooses
// the shot: a wide establishing frame between events, close-ups and two-shots on the
// crewmen who act, a pan along the hand-off (scroll from worker to reviewer), the
// bow for the captain's cards, the gun deck for the salvo, the sky for fireworks.
// Every ritual has an off switch (customs), as in v2 and v3.
import { SEA_Y } from "./env.js";
import { CLASSES } from "./ship.js";

const CLASS_ORDER = (c) => CLASSES.indexOf(c);

export class Director {
  constructor({ world, camera, sound, ui, overlay, getSim, rituals }) {
    Object.assign(this, { world, camera, sound, ui, overlay, getSim, rituals });
    this.timers = [];
    this.clock = 0;
    this.shot = null;
    this.shotUntil = 0;
    this.cinematic = true;
    this.haulers = new Set();
    this.placard = 0;
    this.battleOn = false;
    for (const p of Object.values(world.crew)) p.onCue = (c, who) => this.cue(c, who);
  }
  after(sec, fn) { this.timers.push({ at: this.clock + sec, fn }); }
  crew(id) { return this.world.crew[id]; }
  // ---------------------------------------------------------------- shots
  frames() {
    const W = this.world, S = W.ship, K = W.kraken;
    const head = (p) => W.at(p, "head");
    const krakenUp = K.rise > 0.3 && K.far < 0.5;
    return {
      // the establishing frame (the banner): the whole ship, sails to keel, with sky and sea around it
      // the establishing frame (the banner): the whole ship, sails to keel, with sky and sea
      // around it, sized to the ship's class (and to the kraken when it is up)
      wide: () => this.shipFrame(krakenUp),
      deck: () => { const Sp = S.spec; return { x: (Sp.main[0] + Sp.main[1]) / 2, y: -420 - Sp.ride + 120, h: 1750 + 240, w: Sp.main[1] - Sp.main[0] + 900 }; },
      bow: () => { const c = this.crew("captain"); const [x, y] = head(c); return { x: x + 120, y: y + 60, h: 1150 }; },
      helm: () => { const c = this.crew("firstmate"); const [x, y] = head(c); return { x: x + 200, y: y + 60, h: 1150 }; },
      guns: () => { const g = S.gunports, lo = S.spec.gunRows[S.spec.gunRows.length - 1]; return { x: (g[0] + g[g.length - 1]) / 2, y: -S.spec.ride + lo * 0.5, h: 1300 + lo, w: g[g.length - 1] - g[0] + 1000 }; },
      sky: () => ({ x: 120, y: -1050 - S.spec.ride, h: 3000, w: 4400 }),
      kraken: () => { const [x, y] = K.headPos(); return { x: x - 300, y: y + 120, h: 2400 }; },
      battle: () => this.shipFrame(true),
      crew: () => {
        const p = this.focus;
        if (!p) return null;
        const [x, y] = head(p);
        if (this.focus2 && this.focus2 !== p) {
          const [x2, y2] = head(this.focus2);
          return { x: (x + x2) / 2, y: (y + y2) / 2 + 100, h: Math.max(1100, Math.abs(y - y2) + 900), w: Math.abs(x - x2) + 1300 };
        }
        return { x: x + p.dir * 40, y: y + 100, h: 1000 };
      },
    };
  }
  shipFrame(withKraken) {
    const S = this.world.ship.spec, K = this.world.kraken;
    // the ship rides high (her gun decks dry), so the frame follows her: sails to keel
    const top = this.world.ship.rigTop - 380 - S.ride, bot = Math.max(S.bottom - S.ride + 120, 380);
    const x0 = S.stern - 320, x1 = withKraken ? K.x + 820 : S.bow + 480;
    return { x: (x0 + x1) / 2, y: (top + bot) / 2, h: Math.max(2200, (bot - top) * 1.08), w: x1 - x0 };
  }
  defaultShot() { return this.world.kraken.rise > 0.3 && this.world.kraken.far < 0.5 ? (this.battleOn ? "battle" : "wide") : "wide"; }
  cut(name, hold = 3, { snap = false, k = 9 } = {}) {
    if (!this.cinematic || this.follow) return; // while the captain has the deck the camera is his
    if (this.battleOn && !['battle', 'kraken'].includes(name)) return; // the fight keeps its framing
    this.shot = name;
    // close-ups are brief cuts; the wide shot comes back quickly
    this.shotUntil = this.clock + (["crew", "bow", "helm", "deck", "guns"].includes(name) ? Math.min(hold * 0.6, 1.8) : hold);
    const f = this.frames()[name]?.();
    if (f) this.camera.go(f, { cut: snap, k });
  }
  cutTo(p, hold = 2.6, opts) {
    if (!p) return;
    this.focus = p;
    this.focus2 = null;
    this.cut("crew", hold, opts);
  }
  twoShot(p, q, hold = 3) {
    this.focus = p;
    this.focus2 = q;
    this.cut("crew", hold);
  }
  // ---------------------------------------------------------------- cues from the puppets
  cue(name, who) {
    const W = this.world;
    if (name === "hit") {
      const [x, y] = W.at(who, "hand_r", 0, 60);
      W.fx.sprite("spark", x, y, { s: 40, grow: 1.5, life: 0.25 });
      for (let i = 0; i < 4; i++) W.fx.sprite("gold", x, y, { s: 12, grow: 0.5, life: 0.4, vx: (Math.random() - 0.5) * 500, vy: -200 - Math.random() * 300, g: 1500 });
      this.sound.play("thud");
    } else if (name === "stamp") {
      const [x, y] = W.at(who, "hand_r", 0, 90);
      W.fx.ring(x, y, { r: 160, life: 0.4, col: "255,210,90", squash: 0.35 });
      W.fx.stop(0.06);
      W.fx.shake(0.18);
      this.sound.play("stampHit");
    } else if (name === "thud") this.sound.play("thud");
  }
  // ---------------------------------------------------------------- hand-offs
  handoff(kind, from, to, then) {
    if (!from || !to) return then?.();
    const W = this.world, img = W.images.props[kind === "rejection" ? "flag" : kind === "list" ? "criteriaList" : "scroll"];
    const a = W.at(from, "hand_r", 0, 40), b = W.at(to, "hand_r", 0, 40);
    W.fx.fly(img, a, b, { dur: 1.1, height: kind === "order" ? 320 : 200, spin: kind === "order" ? Math.PI * 2 : 0.6, scale: 0.45, glow: kind === "approval" || kind === "order", onArrive: () => { to.shot("bark"); then?.(); } });
    this.sound.play("paper");
  }
  ringBell(n = 1) { for (let i = 0; i < n; i++) this.after(i * 0.7, () => { this.world.ship.bell = 1; this.sound.play("bell"); }); }
  // ---------------------------------------------------------------- the board's events
  handle(e, sim) {
    const W = this.world, R = this.rituals, fx = W.fx;
    const P = (id) => (id ? this.crew(id) : null);
    const w = P(e.worker);
    switch (e.type) {
      case "order": {
        if (e.resume || e.sendback) { this.ui.banner("Aye, captain."); break; }
        this.orderRitual(sim, w);
        break;
      }
      case "worker_walk": {
        if (!w) break;
        // he walks the decks to his station (or his home), by the stairs and ladders
        w.clearShot("slump");
        this.haulers.delete(w.id);
        W.sendTo(w, e.station || "idle", e.station === "idle" ? "lean" : e.action || "idle"); // at his own spot he leans (his box is planned for it)
        break;
      }
      case "work_start":
        if (w && !W.agent(w.id)?.goal && !W.agent(w.id)?.link) w.setLoop(e.action);
        break;
      case "commit_pushed": {
        if (!w) break;
        w.shot(e.n % 2 ? "carryCrate" : "hammerHome");
        this.cutTo(w, 2.2);
        if (e.inBattle) this.onBattlePush?.(e);
        break;
      }
      case "gate_failed": {
        W.env.storm = 1;
        this.sound.play("boom");
        W.env.lightning = 1;
        if (R.weather && w) {
          const idle = sim.crew.filter((c) => c.role === "worker" && c.state === "idle").slice(0, 2).map((c) => P(c.id));
          // all hands to the rigging: they haul at the masts and the capstan
          [w, ...idle].forEach((p) => {
            if (!p) return;
            this.haulers.add(p.id);
            W.sendTo(p, "amidships", "haul");
          });
        } else w?.shot("slump");
        this.cut("deck", 3.4);
        break;
      }
      case "gate_green": {
        this.clearing(sim);
        if (w) {
          const c = sim.crew.find((x) => x.id === w.id);
          W.sendTo(w, c.station || "idle", c.action || "lean");
        }
        for (const id of this.haulers) {
          if (id === e.worker) continue;
          const p = P(id), c = sim.crew.find((x) => x.id === id);
          if (p) W.sendTo(p, c?.state !== "idle" && c?.station ? c.station : "idle", c?.state !== "idle" && c?.action ? c.action : "lean");
        }
        this.haulers.clear();
        break;
      }
      case "pr_opened": {
        const r = P("reviewer-1");
        this.handoff("pr", w, r, () => r?.setLoop("review"));
        if (w && r) this.twoShot(w, r, 2.6);
        break;
      }
      case "ask_pass_criteria":
        w?.shot("raiseScroll");
        this.cutTo(w, 2.2);
        this.sound.play("paper");
        break;
      case "criteria_returned": {
        const r = P("reviewer-1");
        r?.shot("answerList");
        this.twoShot(r, w, 2.6);
        this.after(0.6, () => this.handoff("list", r, w));
        break;
      }
      case "review_rejected": {
        const r = P("reviewer-1");
        r?.shot("pointBack");
        r?.setLoop("idle");
        this.twoShot(r, w, 2.6);
        this.after(0.3, () => this.handoff("rejection", r, w));
        break;
      }
      case "review_approved": {
        const r = P("reviewer-1");
        r?.setLoop("idle");
        this.handoff("approval", r, P("firstmate"), () => {
          if (e.firstRound && R.salute) {
            r?.shot("salute");
            w?.shot("salute", 0.22);
            this.sound.play("whistle");
            this.ui.banner("A salute: approved on the first round");
          }
        });
        if (e.firstRound && R.salute && w) this.twoShot(r, w, 3);
        else this.cutTo(r, 2.6);
        break;
      }
      case "decision_requested": {
        this.placard = 1;
        this.ringBell(1);
        this.cut("bow", 2.4);
        const c = this.crew("captain");
        c?.shot("pointBack");
        if (e.decision.task && e.decision.kind === "choice") {
          const t = sim.tasks.find((x) => x.id === e.decision.task);
          if (t?.worker) P(t.worker)?.setLoop("idle");
        }
        break;
      }
      case "decision_answered":
        if (!sim.decisions.length) this.placard = 0;
        if (e.effect === "proceed" || e.effect === "rescope") {
          const t = sim.tasks.find((x) => x.id === e.task), c = t?.worker && sim.crew.find((x) => x.id === t.worker);
          if (c?.action) P(c.id)?.setLoop(c.action);
        }
        break;
      case "merged":
        this.salvo(sim, e);
        break;
      case "making_port":
        this.after(1.0, () => {
          if (!R.port) return;
          W.fx.fireworks(200, -1500, 4);
          this.sound.play("fireworks");
          this.ringBell(2);
          this.ui.banner({ en: `Making port: ${e.port}`, tw: `進港：${e.port}`, cn: `进港：${e.port}` });
          this.cut("sky", 3.6);
        });
        break;
      case "promoted": {
        const p = P(e.crew);
        this.after(2.0, () => {
          this.cutTo(p, 2.4);
          p?.shot("spin");
          {
            const r = this.ui.rankWords?.(e.rank) || [e.rank, e.rank, e.rank];
            this.ui.banner({ en: `${e.crew} rated ${r[0]}`, tw: `${e.crew} 晉升為 ${r[1]}`, cn: `${e.crew} 晋升为 ${r[2]}` });
          }
          if (p) {
            const [x, y] = W.at(p, "head");
            for (let i = 0; i < 16; i++) W.fx.sprite("gold", x, y, { s: 18, grow: 0.5, life: 1, vx: Math.cos(i) * 400, vy: Math.sin(i) * 400 - 200, g: 600 });
          }
        });
        break;
      }
      case "task_new":
      case "island": {
        if (e.type === "island" && !e.spotted) break;
        const p = P("worker-3"), c = sim.crew.find((x) => x.id === "worker-3");
        if (p && c?.state === "idle") {
          p.setLoop("lookout");
          this.after(2.6, () => this.getSim().crew.find((x) => x.id === "worker-3")?.state === "idle" && p.setLoop("lean"));
        }
        break;
      }
      case "worker_crashed":
      case "vendor_unavailable": {
        w?.shot("slump");
        this.cutTo(w, 2.4);
        const f = P("firstmate");
        if (f) {
          const [x, y] = W.at(f, "head");
          for (let i = 0; i < 10; i++) W.fx.sprite("spark", x, y, { s: 20, grow: 0.3, life: 0.5, vx: (Math.random() - 0.5) * 600, vy: -300 - Math.random() * 300, g: 1200 });
          this.sound.play("spark");
        }
        break;
      }
      case "recovered":
        w?.clearShot("slump");
        w?.shot("recover");
        break;
      case "kraken_arm": {
        const K = W.kraken;
        K.setArms(sim.kraken.arms.length);
        K.riseTarget = 1;
        K.far = 0;
        this.sound.play("horn");
        W.env.storm = Math.max(W.env.storm, 0.55);
        this.cut("kraken", 3.2);
        W.fx.waterColumn(K.x - 300, 1.6);
        break;
      }
      case "battle_begin":
        this.cut("battle", 2.5);
        break;
      case "kraken_strike":
        this.onRealStrike?.(e);
        break;
      case "kraken_let_go":
      case "kraken_down": {
        const K = W.kraken;
        if (!sim.kraken.arms.length || e.type === "kraken_down") {
          K.riseTarget = 0;
          if (e.how === "dropped") W.fx.waterColumn(K.x, 2);
          this.after(2.4, () => !this.getSim().kraken.arms.length && K.setArms(0));
        } else K.setArms(sim.kraken.arms.length);
        break;
      }
      case "kraken_far":
        W.kraken.far = 1;
        break;
    }
    if (["decision_requested", "decision_answered", "gate_green", "merged", "parked", "dropped"].includes(e.type)) W.env.storm = this.stormLevel(sim);
  }
  stormLevel(sim) {
    if (Object.values(sim.gate).some((g) => g === "red")) return 1;
    if (sim.kraken.arms.length && !sim.kraken.fled) return 0.55;
    if (sim.decisions.length) return 0.3;
    return 0;
  }
  orderRitual(sim, worker) {
    const R = this.rituals, c = this.crew("captain"), f = this.crew("firstmate");
    if (!R.order) return this.handoff("order", f, worker);
    this.ringBell(1);
    this.after(0.2, () => this.sound.play("whistle"));
    c?.shot("order");
    f?.shot("whistle");
    this.world.ship.wheelV = 9;
    let i = 0;
    for (const m of sim.crew) {
      const p = this.crew(m.id);
      if (!p || m.id === "captain" || m.id === "firstmate" || m.state === "walking" || m.state === "down") continue;
      p.shot("salute", 0.25 + i++ * 0.05);
    }
    this.after(0.3, () => this.handoff("order", c, f, () => worker && this.handoff("order", f, worker)));
    this.ui.banner("Aye, captain. Orders away");
    this.cut("bow", 2.2);
    this.after(2.2, () => this.cut("helm", 2));
    if (worker) this.after(4.3, () => this.cutTo(worker, 2.8));
  }
  clearing(sim) {
    const W = this.world;
    if (!this.rituals.clearing) return;
    W.env.storm = this.stormLevel(sim);
    W.env.clearing = 1;
    let i = 0;
    for (const m of sim.crew) {
      const p = this.crew(m.id);
      if (p && m.state !== "down") p.shot("cheer", Math.min(i++ * 0.04, 0.3));
    }
    this.sound.play("cheer");
    this.ui.banner("Clearing, and a cheer");
    this.cut("deck", 3);
  }
  salvo(sim) {
    const W = this.world, S = W.ship;
    this.crew("captain")?.shot("stamp");
    this.cut("bow", 1.3);
    if (!this.rituals.salvo) return this.ui.banner("Merged into main");
    const T = 1.2;
    const rows = S.spec.gunRows.filter((y) => y <= S.spec.bottom * 0.72);
    rows.forEach((py, row) => S.gunsAt(row).forEach((x, i) => this.after(T + 0.3 + row * 0.25 + i * 0.08, () => {
      S.recoil[row * 12 + i] = 1;
      const [wx, wy] = S.toWorld(x, py);
      W.fx.muzzle(wx, wy + 20, 0, 1.3);
      W.fx.sprite("smokeW", wx, wy + 30, { s: 140, grow: 3, life: 2.2, vy: 60, add: false, drag: 1, a: 0.9 });
    })));
    this.after(T + 0.3, () => { this.sound.play("salvo"); W.fx.shake(0.3); S.kick(-3); });
    this.after(T + 1.2, () => this.ringBell(1));
    this.after(T, () => this.cut("guns", 2.6));
    let i = 0;
    for (const m of sim.crew) {
      const p = this.crew(m.id);
      if (p && m.state !== "down" && m.id !== "captain") p.shot("cheer", T + 0.6 + i++ * 0.05);
    }
    this.ui.banner("Ahoy! Merged into main");
  }
  // the ship grows (or trims down) to fit the crew: a shipyard moment, never a hard pop.
  // Scaffolding and flying planks, the hull stretching and the masts snapping in, steam and
  // sparkles, the camera pulling back to the new frame, a trilingual banner, a cheer.
  transform(cls, sim) {
    const W = this.world, S = W.ship, from = S.cls;
    const grow = CLASS_ORDER(cls) > CLASS_ORDER(from);
    if (!S.setClass(cls, 3.2)) return false;
    this.transformInfo = { cls, grow, at: this.clock };
    this.ui.banner(grow ? { en: `The ship grows: ${cls.en}`, tw: `船艦升級：${cls.tw}`, cn: `船舰升级：${cls.cn}` } : { en: `The ship trims down: ${cls.en}`, tw: `船艦縮編：${cls.tw}`, cn: `船舰缩编：${cls.cn}` }, "transform");
    if (!grow) W.regroup(sim); // shrinking: everyone steps inboard first
    // the camera pulls back past both hulls, then settles on the new one
    const both = () => {
      const a = this.shipFrame(false), sp = S.spec;
      return { ...a, h: a.h * 1.12, w: Math.max(a.w, cls.bow - cls.stern + 900) * 1.05 };
    };
    this.force = true;
    this.camera.go(both(), { k: 5 });
    this.sound.play("bell");
    const hammer = ["トンカン!", "ガシャン!", "カン!", "ドドン!"];
    for (let i = 0; i < 14; i++) this.after(0.15 + i * 0.2, () => {
      const sp = S.spec, x = grow ? (i % 2 ? sp.stern + 60 : sp.bow - 80) : (sp.stern + sp.bow) / 2 + (Math.random() - 0.5) * 600;
      const [wx, wy] = S.toWorld(x, sp.qd[2] - 40 - Math.random() * 120);
      for (let j = 0; j < 5; j++) W.fx.chip(wx, wy, (Math.random() - 0.5) * 900, -500 - Math.random() * 700, { col: j % 2 ? "#8a5a2e" : "#c98d52", s: 22 + Math.random() * 14, life: 1.6 });
      W.fx.sprite("smokeW", wx, wy + 40, { s: 160, grow: 3, life: 1.6, vy: -80, add: false, drag: 1, a: 0.7 });
      if (i % 3 === 0) W.fx.sfx(wx, wy - 180, hammer[(i / 3) % hammer.length], { col: "#ffd23a", size: 0.9 });
      if (i % 2 === 0) this.sound.play("clang");
    });
    // the masts snap in with sparkles at their tops
    this.after(1.9, () => {
      for (const m of S.rig) {
        const [wx, wy] = S.toWorld(m.x, m.top);
        W.fx.sprite("spark", wx, wy, { s: 260, grow: 1.6, life: 0.5, add: false });
        W.fx.sprite("gold", wx, wy + 60, { s: 120, grow: 2, life: 0.9 });
        W.fx.ring(wx, wy, { r: 260, life: 0.5, col: "255,230,140", w: 12 });
      }
      W.fx.sfx(...S.toWorld((S.spec.stern + S.spec.bow) / 2, S.spec.qd[2] - 600), grow ? "ジャキーン!" : "シュッ!", { col: "#fff", size: 1.3 });
      W.fx.shake(0.25);
      S.kick(grow ? -2 : 2);
    });
    this.after(3.3, () => {
      W.regroup(sim);
      let i = 0;
      for (const m of sim.crew) this.crew(m.id)?.shot("cheer", 0.2 + Math.min(i++ * 0.03, 0.5));
      this.sound.play("cheer");
      this.ringBell(2);
      this.force = false;
      this.camera.go(this.shipFrame(W.kraken.rise > 0.3 && W.kraken.far < 0.5), { k: 4 });
      this.transformInfo = null;
    });
    return true;
  }
  update(dt) {
    this.clock += dt;
    for (let i = this.timers.length - 1; i >= 0; i--) if (this.clock >= this.timers[i].at) {
      const fn = this.timers[i].fn;
      this.timers.splice(i, 1);
      fn();
    }
    const W = this.world;
    W.env.clearing = Math.max(0, W.env.clearing - dt * 0.3);
    if (this.follow && !this.force) {
      const f = this.follow();
      if (!this._following) (this.camera.go(f, { k: 7, push: 0 }), (this._following = true));
      else this.camera.def = this.camera.frame(f);
      return;
    }
    if (this._following) (this._following = false), (this._last = null), this.camera.go(this.frames()[this.defaultShot()](), { k: 5 });
    if (!this.cinematic) return;
    if (this.force) return;
    const name = this.shot && this.clock < this.shotUntil ? this.shot : this.defaultShot();
    const f = this.frames()[name]?.();
    if (f) {
      const F = this.camera.frame(f);
      if (!this.camera.def || name !== this._last) this.camera.go(f, { k: name === "crew" ? 10 : 6 });
      else this.camera.def = F; // follow the moving subject without restarting the push-in
      this._last = name;
    }
  }
}
