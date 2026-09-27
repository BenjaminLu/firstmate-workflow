// The battle on screen: the reducer (battle2d.js) says what happens, this makes it loud.
// Every strike and every special is a staged sequence: anticipation (a telegraph you
// can read), the cut-in for specials, the hit with impact frames, hit-stop, shake, a
// punch-in, debris and water, a damage number, then a clear aftermath. The kraken's
// MAELSTROM is the set piece: crimson sky, whirlpool, a tidal wall, brace, parry, and
// the crew's counter broadside. The finisher ties the fight to the board: only an
// approval wins, so the reviewer stamps APPROVED and the captain fires the golden gun.
import { createBattle, stepBattle, attackView, ultView, TUNE } from "./battle2d.js";
import { SEA_Y } from "./env.js";
import { drawCrest } from "./fx.js";

const TAU = Math.PI * 2;

export class BattleView {
  constructor({ world, camera, sound, ui, overlay, director, apply, getSim }) {
    Object.assign(this, { world, camera, sound, ui, overlay, director, apply, getSim });
    this.b = null;
    this.playing = false;
    this.inBattle = false;
    this.held = [];
    this.gripGhost = 1;
    this.slashes = [];
    this.wave = 0;
    this.waveX = 0; // the tidal wall
    this.bracing = false;
    this.charging = false;
    this.chains = [];
    this.ending = null;
    this.zoomBlur = null; // { x, y, k } world point
    this.blur = 0;
  }
  sync(sim) {
    const arms = sim.kraken.arms;
    this.held = arms.slice();
    this.inBattle = !!sim.kraken.battle && !sim.kraken.fled;
    if (!arms.length && this.b && !this.ending) this.stop();
    const round = Math.max(3, ...arms.map((id) => sim.tasks.find((t) => t.id === id)?.round || 3));
    if (this.b) {
      if (this.b.round !== round) this.b = stepBattle(this.b, { type: "setRound", round }).battle;
      if (this.b.arms !== Math.max(1, arms.length)) this.b = stepBattle(this.b, { type: "setArms", arms: arms.length }).battle;
    }
    this.round = round;
    this.ui.battleBand(this.inBattle && !this.ending ? { tasks: arms, round, playing: this.playing } : null);
    this.world.kraken.labels = arms;
  }
  play(on) {
    if (on && !this.inBattle) return;
    this.playing = on;
    this.director.battleOn = on;
    if (on) {
      this.b = createBattle({ round: this.round || 3, arms: Math.max(1, this.held.length), seed: 7 });
      this.gripGhost = 1;
      this.director.cut("battle", 2.5);
      this.sound.play("horn");
      this.ui.banner("All hands! Read the arm, parry at the gold");
    } else this.stop();
    this.ui.battleBand(this.inBattle ? { tasks: this.held, round: this.round, playing: on } : null);
    document.body.classList.toggle("battle", on);
  }
  stop() {
    this.playing = false;
    this.b = null;
    this.director.battleOn = false;
    for (const a of this.world.kraken.arms) ((a.attack = null), (a.bound = false), (a.lift = 0));
    this.world.kraken.ult = 0;
    this.world.env.ult = 0;
    this.overlay.barsTarget = 0;
    this.camera.def && (this.camera.def.rot = 0);
    document.body.classList.remove("battle");
  }
  step(action) {
    if (!this.b) return;
    const r = stepBattle(this.b, action);
    this.b = r.battle;
    for (const e of r.events) this.onEvent(e);
  }
  // ---------------------------------------------------------------- input
  // ---------------------------------------------------------------- input: one tap
  // A click or a tap anywhere on the stage does what the moment asks (parry, dodge, shoot
  // the ink down, riposte, brace, parry the tide, fire at will, start the finisher). The
  // special button takes the next special at a full gauge. Keys are optional shortcuts.
  tap() {
    if (!this.playing || !this.b || this.finishing || this.ending) return false;
    this.step({ type: "tap" });
    return true;
  }
  special() {
    if (!this.playing || !this.b) return false;
    this.step({ type: "special" });
    return true;
  }
  key(k, down) {
    if (!this.playing || !this.b) return false;
    const K = k.toLowerCase();
    if ([" ", "j", "enter"].includes(K)) return (down && this.tap(), true);
    if (K === "k") return (down && this.special(), true);
    if (K === "escape" && down) return (this.play(false), true);
    return false;
  }
  finish() {
    if (this.b?.phase === "finisher" && !this.finishing) this.step({ type: "tap" });
  }
  // the one prompt on screen: what a tap does now, where to look, and how soon
  prompt() {
    if (!this.playing || !this.b || this.ending) return null;
    const b = this.b,
      W = this.world,
      cam = this.camera;
    const scr = (p) => cam.toScreen(p[0], p[1]);
    if (this.finishing) return null;
    if (b.phase === "finisher")
      return {
        kind: "finisher",
        text: "TAP! 承認",
        sub: "only an approval wins",
        at: scr(this.headWorld()),
        p: 1,
        ready: true,
        col: "#ffd23a",
      };
    const u = ultView(b);
    if (u) {
      const at = scr(W.ship.toWorld(0, -380));
      if (u.stage === "windup")
        return { kind: "ult", text: "ゴゴゴ… MAELSTROM", sub: "get ready", at, p: u.p * 0.5, ready: false, col: "#ff5a3a" };
      if (u.stage === "brace")
        return {
          kind: "brace",
          text: this.b.ult.tapBraced ? "BRACED!" : "TAP! BRACE",
          sub: "the swell is coming",
          at,
          p: 1,
          ready: !this.b.ult.tapBraced,
          col: "#7ab8ff",
        };
      const k = Math.min(1, u.p / (1 - u.parryZone));
      return {
        kind: "tide",
        text: k >= 1 ? "TAP! PARRY" : "WAIT…",
        sub: "the crushing tide",
        at,
        p: k,
        ready: k >= 1 && !u.parried,
        col: "#ffd23a",
      };
    }
    const a = attackView(b);
    if (a && !a.answer) {
      const arm = W.kraken.arms[a.arm % Math.max(1, W.kraken.arms.length)];
      const at = scr(arm?.tip?.[0] ? arm.tip : W.sectionWorld(a.section));
      const zone = TUNE.patterns[a.pattern].tap / TUNE.patterns[a.pattern].wind;
      const k = Math.min(1, a.p / (1 - zone));
      const verb = a.pattern === "ink" ? "SHOOT" : a.parryable ? "PARRY" : "DODGE";
      return {
        kind: "attack",
        text: k >= 1 ? "TAP! " + verb : "WAIT…",
        sub: { slam: "slam", jab: "jab", sweep: "sweep · unblockable", ink: "ink" }[a.pattern],
        at,
        p: k,
        ready: k >= 1,
        col: a.pattern === "ink" ? "#b88aff" : a.parryable ? "#ffd23a" : "#7ab8ff",
      };
    }
    if (b.riposteUntil > b.t && !b.attack)
      return {
        kind: "riposte",
        text: b.weak ? "TAP! 反撃" : "TAP! COUNTER",
        sub: b.weak ? "the weak point" : "counter",
        at: scr(this.headWorld()),
        p: 1,
        ready: true,
        col: "#ffd23a",
      };
    return {
      kind: "fire",
      text: "TAP TO FIRE",
      sub: "fire at will",
      at: scr(this.headWorld()),
      p: 1,
      ready: b.t >= (b.fireReadyAt || 0),
      col: "#fff",
      quiet: true,
    };
  }
  specialReady() {
    return !!(this.playing && this.b && this.b.phase === "fight" && !this.b.ult && this.b.gauge >= 100 && !this.overlay.busy);
  }
  // ---------------------------------------------------------------- the events
  C(id) {
    return this.world.crew[id];
  }
  headWorld() {
    return this.world.kraken.eyePos();
  }
  onEvent(e) {
    const W = this.world,
      K = W.kraken,
      fx = W.fx,
      S = W.ship,
      cam = this.camera,
      snd = this.sound,
      D = this.director;
    switch (e.type) {
      case "attack_start": {
        const a = K.arms[e.arm % Math.max(1, K.arms.length)];
        if (a) a.attack = { p: 0, target: W.sectionWorld(e.section), pattern: e.pattern, parryable: e.parryable };
        snd.play(e.pattern === "slam" ? "horn" : e.pattern === "sweep" ? "rising" : "tick");
        cam.kick(1.03);
        if (e.pattern === "ink") K.expr = "angry";
        break;
      }
      case "parry_ok": {
        const c = this.C("captain");
        c?.shot("parry");
        for (const p of Object.values(W.crew)) if (p !== c && Math.random() < 0.5) p.shot("parry", 0.05);
        snd.play("parry");
        const a = this.activeArm();
        const tip = a?.tip || W.sectionWorld(1);
        fx.sprite("spark", tip[0], tip[1], { s: 420, grow: 1.6, life: 0.3 });
        fx.sfx(tip[0], tip[1] - 160, "ガキン!", { col: "#ffd23a", size: 1.2 });
        fx.ring(tip[0], tip[1], { r: 420, life: 0.35, col: "255,230,140", w: 26 });
        for (let i = 0; i < 18; i++)
          fx.sprite("gold", tip[0], tip[1], { s: 22, grow: 0.4, life: 0.6, vx: Math.cos(i) * 900, vy: Math.sin(i) * 900, g: 900 });
        this.impact(1);
        fx.stop(0.14);
        fx.slow = 0.5;
        cam.kick(1.12);
        this.overlay.speed = 1;
        this.ui.combo?.("PARRY!");
        this.say("PARRY!", "#ffd23a");
        break;
      }
      case "parried": {
        const a = K.arms[this.lastArm ?? 0];
        if (a) ((a.attack = null), (a.slam = 0.6), (a.lastTarget = [a.tip[0] + 400, a.tip[1] - 300]));
        K.stagger = 0.5;
        K.weak = 1;
        K.expr = "hurt";
        D.after(0.6, () => (K.expr = "glare"));
        break;
      }
      case "parry_miss":
        this.say("TOO EARLY", "#aaa");
        break;
      case "dodge_ok":
        S.kick(-10);
        snd.play("whoosh");
        W.env.speed = 1.2;
        D.after(1.2, () => (W.env.speed = 0.35));
        this.blur = 0.6;
        this.say("FULL SAIL!", "#7ab8ff");
        break;
      case "dodged": {
        const a = this.activeArm(true);
        if (a) ((a.attack = null), (a.slam = 1), (a.lastTarget = [a.tip[0] + 300, SEA_Y + 40]));
        fx.waterColumn(W.sectionWorld(e.section)[0] + 500, 1.3);
        fx.sfx(W.sectionWorld(e.section)[0] + 500, SEA_Y - 380, "ザバァ", { col: "#9ad8ff", size: 1 });
        snd.play("splash");
        break;
      }
      case "dodge_early":
        this.say("TOO EARLY", "#aaa");
        break;
      case "strike": {
        const a = this.activeArm(true);
        if (a) ((a.attack = null), (a.slam = 1), (a.lastTarget = W.sectionWorld(e.section)));
        const [x, y] = W.sectionWorld(e.section);
        const heavy = e.pattern === "slam" || e.pattern === "sweep";
        fx.explode(x, y, heavy ? 3 : 2, { deck: true });
        fx.sfx(x, y - 200, "バキッ!", { col: "#ff4a2a", size: heavy ? 1.3 : 1 });
        fx.wave(x + 300, heavy ? 1.4 : 1, 1);
        this.impact(heavy ? 1 : 0);
        fx.stop(heavy ? 0.12 : 0.07);
        fx.screenFlash(0.35, "255,60,40");
        S.kick(heavy ? 16 : 9);
        S.damage.push({ x: S.sections[e.section % 4], t: S.t });
        cam.kick(1.08);
        snd.play("impact");
        for (const p of Object.values(W.crew))
          if (Math.abs(p.x - S.sections[e.section % 4]) < 380 && !p.aloft) p.shot("flinch", Math.random() * 0.05);
        if (e.pattern === "ink") this.ink = 2.2;
        break;
      }
      case "struck": {
        const [x, y] = S.toWorld(0, -300);
        fx.number(x, y, `-${e.dmg}`, { col: "#ff5a3a" });
        break;
      }
      case "hull_broken":
        this.say("THE HULL CRACKS!", "#ff5a3a");
        for (const p of Object.values(W.crew)) p.shot("slump", Math.random() * 0.1);
        D.after(TUNE.stun, () => {
          for (const p of Object.values(W.crew)) (p.clearShot("slump"), p.shot("recover"));
          this.say("Patched! Back to the guns", "#7ad06a");
        });
        break;
      case "riposte_closed":
        K.weak = 0;
        break;
      case "hit":
        this.onHit(e);
        break;
      case "broadside_charge":
        this.charging = true;
        this.C("captain")?.shot("charge");
        snd.play("charge");
        break;
      case "broadside": {
        this.charging = false;
        const perfect = e.grade === "perfect";
        if (perfect) this.cutin("captain", "舷側斉射", "BROADSIDE!", ["#6a1a10", "#ffd23a"]);
        this.C("captain")?.shot("fire", perfect ? 0.9 : 0);
        this.volleyAt = perfect ? 1.25 : 0.15;
        this.camRun(
          [
            [this.volleyAt - 0.1, () => this.gunsShot(), { cut: true }],
            [this.volleyAt + 0.62, () => this.krakenShot(1500, 0.06), { cut: true }],
          ],
          this.volleyAt + 2.4,
        );
        break;
      }
      case "harpoon": {
        this.cutin("sailor-hammer", "魚叉鎖鏈", "HARPOON & CHAIN", ["#0e3a4a", "#7ae0ff"]);
        const w = Object.values(W.crew).find((p) => p.role === "worker");
        w?.shot("riposte", 0.9);
        this.camRun(
          [
            [
              1.1,
              () => {
                const [bx, by] = S.chaserWorld();
                const [kx, ky] = this.headWorld();
                return { x: (bx + kx) / 2, y: (by + ky) / 2 - 100, h: 1700, rot: 0.03 };
              },
              { cut: true },
            ],
            [1.45, () => this.krakenShot(1300, 0.08), { cut: true }],
          ],
          3.2,
        );
        D.after(1.2, () => {
          const from = S.chaserWorld();
          for (const i of e.arms) {
            const a = K.arms[i % K.arms.length];
            if (!a) continue;
            a.bound = true;
            this.chains.push({ a, from, t: 0 });
          }
          snd.play("clang");
          fx.shake(0.5);
          fx.stop(0.1);
          this.impact(1);
          cam.kick(1.1);
        });
        break;
      }
      case "unbound":
        for (const a of K.arms) a.bound = false;
        this.chains = [];
        break;
      case "attack_cancel":
        for (const a of K.arms) a.attack = null;
        break;
      case "all_hands": {
        this.cutin("firstmate", "総員砲撃", "ALL HANDS!", ["#1f2f5c", "#9ad8ff"]);
        let i = 0;
        for (const p of Object.values(W.crew)) p.shot("salute", 0.8 + i++ * 0.04);
        D.after(1.7, () => {
          const [hx, hy] = this.headWorld();
          fx.sfx(hx - 250, hy - 250, "ドドドド", { col: "#9ad8ff", size: 1.2 });
        });
        this.C("captain")?.shot("fire", 1.0);
        this.camRun(
          [
            [1.1, { x: 0, y: -300 - W.ship.spec.ride, h: 1150 }, { cut: true }],
            [1.6, () => this.gunsShot(), { cut: true }],
            [2.1, () => this.krakenShot(1600, -0.05), { cut: true }],
          ],
          3.8,
        );
        break;
      }
      case "ult_start":
        this.ultStart();
        break;
      case "ult_brace": {
        this.camRun([[0, { x: 520, y: -760 - W.ship.spec.ride * 0.5, h: 2900, rot: -0.06 }, { k: 6 }]], TUNE.ultimate.brace + TUNE.ultimate.strike + 0.2);
        this.overlay.barsTarget = 1;
        snd.play("rumble");
        for (const p of Object.values(W.crew)) p.shot("charge", Math.random() * 0.1);
        this.say("THE SWELL — BRACE!", "#7ab8ff");
        break;
      }
      case "ult_strike":
        this.say(e.braced ? "BRACED! NOW PARRY" : "THE CRUSHING TIDE!", e.braced ? "#7ab8ff" : "#ff5a3a");
        cam.kick(1.06);
        break;
      case "ult_parry":
        this.ultParry();
        break;
      case "ult_countered":
        this.ultEnd();
        break;
      case "ult_landed":
        this.ultLanded(e);
        break;
      case "finisher_ready":
        K.expr = "hurt";
        K.riseTarget = 0.85;
        K.stagger = 3;
        this.say("THE KRAKEN REELS — ONLY AN APPROVAL WINS", "#ffd23a");
        D.cut("battle", 3);
        for (const a of K.arms) a.attack = null;
        break;
      case "no_gauge":
        this.say("NOT ENOUGH GAUGE", "#aaa");
        break;
      case "won":
        this.won(e);
        break;
      case "finisher_go":
        this.finisherSequence();
        break;
      case "wait":
        this.say("WAIT FOR IT…", "#dddddd");
        break;
      case "bracing":
        this.say("BRACED!", "#7ab8ff");
        for (const p of Object.values(W.crew)) p.shot("parry", Math.random() * 0.08);
        break;
      case "ink_shot_ok": {
        const a = this.activeArm();
        const tip = a?.tip || this.headWorld();
        const from = S.portWorld(3);
        fx.muzzle(from[0], from[1], 1);
        snd.play("cannon");
        fx.cannon(from, tip, {
          dur: 0.35,
          height: 200,
          onHit: () => {
            fx.explode(tip[0], tip[1], 2, { purple: true });
            fx.sfx?.(tip[0], tip[1] - 120, "バシュッ", { col: "#b88aff" });
          },
        });
        this.say("SHOT DOWN!", "#b88aff");
        break;
      }
    }
  }
  activeArm(clear) {
    const K = this.world.kraken;
    const i = K.arms.findIndex((a) => a.attack);
    if (i >= 0) this.lastArm = i;
    return K.arms[i >= 0 ? i : (this.lastArm ?? 0)];
  }
  say(text, col) {
    this.callout = { text, col, t: 0 };
  }
  // a staged camera run for a special: [[at, framing, opts]], then back to the fight
  camRun(steps, hold) {
    hold = Math.min(hold, 2.4); // close-ups are brief; back to the wide fight
    const D = this.director;
    D.force = true;
    this.camToken = (this.camToken || 0) + 1;
    const tok = this.camToken;
    for (const [at, f, o] of steps)
      D.after(at, () => tok === this.camToken && this.camera.go(typeof f === "function" ? f() : f, { k: 14, ...(o || {}) }));
    D.after(hold, () => {
      if (tok === this.camToken) ((D.force = false), D.cut("battle", 1.5));
    });
  }
  gunsShot() {
    const [x, y] = this.world.ship.toWorld(-190, this.world.ship.spec.gunRows[0] - 10);
    return { x: x + 250, y: y - 120, h: 900, rot: -0.04 };
  }
  krakenShot(h = 1500, rot = 0.05) {
    const [x, y] = this.headWorld();
    return { x: x + 60, y: y + 60, h, rot };
  }
  // style-aware impact frames: manga goes black and white, the P5 look flashes red
  impact(level = 1) {
    const p5 = this.overlay.style === "p5";
    const seq = p5
      ? [["red"], ["red", "monoInv"], ["monoInv", "red", "monoInv"], ["red", "monoInv", "black", "red", "monoInv"]][level]
      : [["mono"], ["mono", "monoInv"], ["monoInv", "mono", "monoInv"], ["monoInv", "mono", "black", "monoInv", "mono"]][level];
    // phones: the same beats as plain flashes (no full-frame filter)
    this.world.fx.impactFrames(
      this.world.low ? seq.map((k) => (k === "mono" ? "white" : k === "monoInv" ? "invert" : k === "red" ? "black" : k)) : seq,
    );
  }
  cutin(who, jp, en, col, extra = {}) {
    const W = this.world;
    const portrait =
      who === "kraken"
        ? (ctx, w, h, sil) => {
            ctx.save();
            ctx.scale(h / 900, h / 900);
            const K = W.kraken;
            const [hx, hy] = K.headPos();
            ctx.translate(-hx + 60, -hy - 120);
            if (sil) ctx.filter = "brightness(0)";
            K.drawBody(ctx);
            ctx.restore();
          }
        : this.portraitOf(who);
    // the bigger the ship, the bigger the cut-in: a small strip (sloop), the full band
    // (brig), three panels (frigate), the whole crew's montage with slow motion (the line)
    const L = who === "kraken" || extra.escalate === false ? 1 : W.level;
    let panels = null;
    if (L >= 2) {
      const ids = [
        who,
        "firstmate",
        "captain",
        "reviewer-1",
        ...Object.values(W.crew)
          .filter((p) => p.role === "worker")
          .map((p) => p.id),
      ];
      const uniq = [...new Set(ids)].filter((id) => W.crew[id]).slice(0, L >= 3 ? 7 : 3);
      panels = uniq.map((id) => this.portraitOf(id));
    }
    this.overlay.cutin({
      jp,
      en,
      portrait,
      col,
      panels,
      scale: L === 0 ? 0.72 : 1,
      from: extra.from || 1,
      dur: (extra.dur || 1.25) * (L >= 3 ? 1.3 : 1),
      y: extra.y,
    });
    this.sound.play("cutin");
    this.world.fx.stop(0.05);
    if (L >= 3 && who !== "kraken") {
      this.overlay.barsTarget = 1;
      this.director.after(2.6, () => !this.world.env.ult && !this.ending && (this.overlay.barsTarget = 0));
    }
  }
  portraitOf(id) {
    const W = this.world;
    return (ctx, w, h, sil, style) => {
      const key = W.crew[id]?.bakeKey || id;
      const im = W.images.crew[key]?.facings.f.whole;
      if (!im) return;
      const s = (h * 1.9) / im.h,
        x = (-im.w * s) / 2,
        y = -h * 0.72,
        iw = im.w * s,
        ih = im.h * s;
      if (sil || style === "ink") {
        // a black silhouette: the P5 shadow behind, or the manga ink outline around
        ctx.filter = "brightness(0)";
        if (sil) ctx.drawImage(im.im, x, y, iw, ih);
        else
          for (const [dx, dy] of [
            [-6, 0],
            [6, 0],
            [0, -6],
            [0, 6],
          ])
            ctx.drawImage(im.im, x + dx, y + dy, iw, ih);
        ctx.filter = "none";
        if (sil) return;
      }
      ctx.filter = style === "ink" ? "contrast(1.25) saturate(1.25)" : "contrast(1.2)";
      ctx.drawImage(im.im, x, y, iw, ih);
      ctx.filter = "none";
    };
  }
  // the impact grows with the ship: splits the sea (frigate), and on the ship of the line the
  // sky flashes, the camera punches in and the moment holds longer
  classImpact(x, y) {
    const W = this.world,
      L = W.level,
      fx = W.fx;
    if (L >= 2) fx.waterColumn(x, 1.4 + L * 0.35);
    if (L >= 3) {
      W.env.lightning = 1;
      fx.stop(0.12);
      fx.slow = Math.max(fx.slow, 0.5);
      this.camera.kick(1.16);
      this.impact(2);
    }
  }
  // ---------------------------------------------------------------- hits on the kraken
  onHit(e) {
    const W = this.world,
      K = W.kraken,
      fx = W.fx,
      S = W.ship,
      D = this.director;
    const [ex, ey] = this.headWorld();
    const Lv = W.level,
      grow = 1 + 0.3 * Lv;
    // in a volley only the last ball carries the number and the shock rings: the rest are its thunder
    const land = (big = 1, crit = false, gold = false, final = true) => {
      const x = ex + (Math.random() - 0.5) * 240,
        y = ey + (Math.random() - 0.5) * 200;
      fx.explode(x, y, big * (final ? grow : 1) * (crit && final ? 1.5 : 1), { crit: crit && final, purple: !gold, rings: final });
      if (final) fx.number(x, y - 60, e.dmg, { crit });
      K.hurt = 0.4;
      K.flash = crit ? 1 : 0.4;
      K.stagger = Math.max(K.stagger, crit ? 0.6 : 0.25);
      this.sound.play(crit ? "clang" : "boom");
      if (final) fx.sfx(x + 40, y - 150, crit ? "ズバッ!" : big >= 3 ? "ドォン!" : "ドン!", {
        col: crit ? "#ffd23a" : gold ? "#ffe07a" : "#fff",
        size: (crit ? 1.25 : big >= 3 ? 1.1 : 0.75) * (1 + 0.2 * Lv),
      });
      if (crit && final) (this.impact(2), fx.stop(0.16), this.camera.kick(1.14), (this.overlay.speed = 1));
    };
    const delay = e.delay || 0;
    if (e.source === "riposte") {
      const c = this.C("captain");
      c?.shot("riposte");
      if (e.crit) this.cutin("captain", "反撃", "RIPOSTE!", ["#5a1010", "#ffd23a"], { dur: 0.8 });
      if (e.crit) this.camRun([[0.72, () => this.krakenShot(1100, -0.1), { cut: true }]], 1.9);
      D.after(e.crit ? 0.75 : 0.18, () => {
        // the slash: a crescent through the eye, then the burst
        this.slashes.push({ x: ex, y: ey, t: 0, r: 420, a: -0.6 });
        this.blur = 0.8;
        land(e.crit ? 4.5 : 2, e.crit);
        this.zoomBlur = { x: ex, y: ey, k: 1 };
      });
      return;
    }
    if (e.source === "broadside" || e.source === "order" || e.source === "counter_broadside") {
      const gun = e.gun ?? e.volley ?? Math.floor(Math.random() * S.gunports.length);
      const big = e.heavy || e.source === "counter_broadside";
      const extraDelay =
        e.source === "broadside"
          ? (this.volleyAt ?? 0.1) - (e.delay || 0) + (e.gun ?? 0) * 0.09
          : e.source === "counter_broadside"
            ? 1.1
            : e.source === "order"
              ? 1.6
              : 0;
      // the volley grows with the class: one gun (sloop), a pair (brig), a trio (frigate),
      // every gun deck firing in waves (the line)
      const rowsN = Lv >= 3 ? S.spec.gunRows.filter((y) => y <= S.spec.bottom * 0.72).length : 1;
      const per = e.source === "counter_broadside" ? S.gunports.length : [1, 2, 3, 3][Lv];
      D.after(delay + extraDelay, () => {
        if (e.source !== "shot" && (e.heavy || e.source === "counter_broadside" || (e.gun ?? 0) === 0)) this.classImpactPending = true;
        for (let row = 0; row < rowsN; row++)
          for (let k = 0; k < per; k++) {
            const i = (gun + k) % S.gunports.length;
            D.after(k * 0.07 + row * 0.22, () => {
              S.recoil[row * 12 + i] = 1;
              const from = S.portWorld(i, row);
              fx.muzzle(from[0], from[1], 1, big ? 1.6 : 1);
              S.kick(-2);
              this.sound.play("cannon");
              const last = row === rowsN - 1 && k === per - 1;
              fx.cannon(from, [ex + (Math.random() - 0.5) * 200, ey + (Math.random() - 0.5) * 160], {
                dur: 0.5,
                height: 420,
                big,
                gold: big,
                onHit: () => (
                  land(big ? 4.5 : e.source === "broadside" ? 2.2 : 1.6, !!e.crit, big, last),
                  last && this.classImpactPending && ((this.classImpactPending = false), this.classImpact(ex, ey))
                ),
              });
            });
          }
      });
      return;
    }
    if (e.source === "harpoon") {
      D.after(1.2 + delay, () => (land(2.5, false), this.classImpact(ex, ey)));
      return;
    }
    if (e.source === "shot") {
      // fire at will: one gun, one ball
      const i = (this.fireGun = ((this.fireGun || 0) + 1) % S.gunports.length);
      S.recoil[i] = 1;
      const from = S.portWorld(i);
      fx.muzzle(from[0], from[1], 1, 0.9);
      this.sound.play("cannon");
      fx.cannon(from, [ex + (Math.random() - 0.5) * 260, ey + (Math.random() - 0.5) * 200], {
        dur: 0.42,
        height: 300,
        onHit: () => land(1.2),
      });
      return;
    }
    D.after(delay, () => land(1));
  }
  // ---------------------------------------------------------------- the MAELSTROM
  ultStart() {
    const W = this.world,
      K = W.kraken,
      D = this.director;
    this.cutin("kraken", "大渦", "MAELSTROM", ["#3a0010", "#ff5a3a"], { from: -1, dur: 1.6 });
    W.env.ult = 1;
    K.ult = 1;
    K.expr = "angry";
    for (const a of K.arms) ((a.attack = null), (a.lift = 1));
    this.sound.play("horn");
    this.sound.play("rumble", 0.4);
    D.cut("kraken", 3.2);
    this.camera.def && this.camera.go({ ...D.frames().kraken(), rot: -0.07 }, { k: 5 });
    D.force = true;
    D.after(1.6, () => (D.force = false));
    this.overlay.barsTarget = 1;
    W.fx.waterColumn(K.x - 500, 2);
    W.fx.waterColumn(K.x + 300, 2);
    for (let i = 0; i < 4; i++)
      this.director.after(0.3 + i * 0.35, () => {
        const [hx, hy] = K.headPos();
        W.fx.sfx(hx + (i % 2 ? 520 : -560), hy - 300 + i * 160, "ゴゴゴ", { col: "#ff5a3a", size: 1.1, rot: i % 2 ? 0.25 : -0.25 });
      });
    this.wave = 0.01;
  }
  ultParry() {
    const W = this.world,
      fx = W.fx,
      D = this.director;
    this.sound.play("parry");
    this.impact(3);
    fx.stop(0.28);
    fx.slow = 1.2;
    this.camera.kick(1.2);
    this.overlay.speed = 1.3;
    this.overlay.speedCol = "255,220,120";
    for (const p of Object.values(W.crew)) p.shot("parry");
    this.cutin("captain", "逆転斉射", "COUNTER BROADSIDE", ["#5a3a08", "#ffd23a"], { dur: 1.4 });
    D.after(1.2, () => {
      this.C("captain")?.shot("fire");
      this.wave = -1;
    });
    this.say("PERFECT PARRY!", "#ffd23a");
  }
  ultLanded(e) {
    const W = this.world,
      fx = W.fx,
      S = W.ship;
    this.wave = 2; // the wall comes down on the deck
    this.impact(2);
    fx.stop(0.2);
    fx.shake(1);
    fx.screenFlash(0.6, "120,180,255");
    S.kick(24);
    this.sound.play("impact");
    this.sound.play("splash", 0.1);
    for (let i = 0; i < 4; i++) fx.waterColumn(S.toWorld(-600 + i * 400, 0)[0], 1.8);
    for (const p of Object.values(W.crew)) p.shot(e.braced ? "flinch" : "slump", Math.random() * 0.1);
    if (!e.braced)
      this.director.after(2, () => {
        for (const p of Object.values(W.crew)) (p.clearShot("slump"), p.shot("recover"));
      });
    this.ultEnd();
  }
  ultEnd() {
    const W = this.world,
      K = W.kraken;
    this.director.after(1.4, () => {
      W.env.ult = 0;
      K.ult = 0;
      K.expr = "glare";
      for (const a of K.arms) a.lift = 0;
      this.overlay.barsTarget = 0;
      if (this.wave !== 0) this.wave = 0;
      this.director.cut("battle", 2);
    });
  }
  // the P5 finisher frame: the whole crew in black silhouette over red, leaping in
  allOutFrame() {
    const W = this.world,
      ids = [
        "captain",
        "firstmate",
        "reviewer-1",
        ...Object.values(W.crew)
          .filter((p) => p.role === "worker")
          .map((p) => p.id),
      ];
    this.overlay.allOut = {
      t: 0,
      dur: 1.0,
      draw: (ctx, w, h, k) => {
        ids.forEach((id, i) => {
          const im = W.images.crew[W.crew[id]?.bakeKey]?.facings.q.whole;
          if (!im) return;
          const s = (h * (id === "captain" ? 0.62 : 0.42)) / im.h;
          const x = w * (0.02 + (i / ids.length) * 0.9) - (1 - k) * 300,
            y = h * (id === "captain" ? 0.3 : 0.44 + (i % 2) * 0.08);
          ctx.save();
          ctx.translate(x, y);
          ctx.rotate(-0.12 + (i % 3) * 0.08);
          ctx.filter = "brightness(0)";
          ctx.drawImage(im.im, 0, 0, im.w * s, im.h * s);
          ctx.filter = "none";
          ctx.restore();
        });
      },
    };
  }
  // ---------------------------------------------------------------- the finisher and the ending
  finisherSequence() {
    this.finishing = true;
    const W = this.world,
      K = W.kraken,
      fx = W.fx,
      S = W.ship,
      D = this.director;
    const r = this.C("reviewer-1"),
      c = this.C("captain");
    // 1. the reviewer's stamp: APPROVED
    this.cutin("reviewer-1", "承認", "APPROVED", ["#0c3a2a", "#7af0b0"], { dur: 1.3 });
    r?.shot("heroInspect");
    D.after(1.1, () => {
      this.sound.play("stampHit");
      this.impact(0);
      const [x, y] = W.at(r, "head");
      fx.ring(x, y - 100, { r: 380, life: 0.6, col: "122,240,176", w: 30 });
      this.stamp = { t: 0 };
    });
    // 2. the captain: ONLY AN APPROVAL WINS
    D.after(1.8, () => {
      r?.clearShot("heroInspect");
      this.cutin("captain", "承認之砲", "ONLY AN APPROVAL WINS", ["#5a3a08", "#ffd23a"], { dur: 1.6 });
      c?.shot("charge");
      this.aura = { who: "captain", t: 0 };
      this.sound.play("charge");
    });
    D.after(3.4, () => {
      c?.clearShot("charge");
      this.aura = null;
      c?.shot("fire");
      D.force = true;
      const [bx, by] = W.at(c, "head");
      this.camera.go({ x: bx + 380, y: by + 60, h: 1250 }, { k: 16 }); // the gun and the captain behind it
    });
    D.after(3.8, () => {
      S.chaser = 1;
      const from = S.chaserWorld();
      fx.muzzle(from[0], from[1], 1, 2.4);
      this.sound.play("cannon");
      this.sound.play("boom", 0.05);
      fx.shake(0.5);
      this.blur = 1;
      const [ex, ey] = this.headWorld();
      fx.cannon(from, [ex, ey], {
        dur: 0.7,
        height: 380,
        big: true,
        gold: true,
        onHit: () => {
          this.step({ type: "finish" });
          this.camera.go({ x: ex - 100, y: ey + 80, h: 1500, rot: 0.08 }, { cut: true }); // cut to the hit, dutch
          D.after(1.4, () => (D.force = false));
          this.impact(3);
          if (this.overlay.style === "p5") this.allOutFrame();
          fx.stop(0.35);
          fx.slow = 1.5;
          this.camera.kick(1.25);
          this.overlay.speed = 1.6;
          this.overlay.speedCol = "255,230,140";
          this.zoomBlur = { x: ex, y: ey, k: 1.4 };
          for (let i = 0; i < 5; i++)
            D.after(i * 0.12, () => fx.explode(ex + (Math.random() - 0.5) * 500, ey + (Math.random() - 0.5) * 400, 3.5, { crit: i === 0 }));
          fx.number(ex, ey - 120, 999, { crit: true });
          fx.sfx(ex - 60, ey - 380, "ドォォン!!", { col: "#ffd23a", size: 2.1, rot: -0.12 });
          this.sound.play("impact");
          K.expr = "hurt";
          K.flash = 1;
        },
      });
    });
  }
  won() {
    const W = this.world,
      K = W.kraken,
      D = this.director;
    // only an approval wins: the held tasks are approved on the board
    const sim = this.getSim();
    document.body.classList.add("ending");
    D.after(1.2, () => {
      for (const id of sim.kraken.arms.slice()) this.apply({ type: "approve", task: id });
      K.riseTarget = 0;
      for (let i = 0; i < 3; i++) D.after(i * 0.3, () => W.fx.waterColumn(K.x + (i - 1) * 400, 2.2));
      this.sound.play("splash");
    });
    D.after(2.2, () => this.heroEnding());
  }
  heroEnding() {
    const W = this.world,
      D = this.director,
      fx = W.fx,
      ov = this.overlay;
    this.stop();
    this.finishing = false;
    this.ending = { t: 0 };
    D.force = true;
    W.env.night = 0.75;
    W.env.storm = 0;
    W.env.clearing = 1.5;
    this.sound.play("victoryMusic");
    // the crew gather amidships and face us: the captain in the middle, his firstmate at his
    // right hand, the reviewer at his left, then the hands outward; a second rank on the gangway
    // when the ship is big (every face in the picture, up to 24)
    W.suspend(); // the lineup is the ending's own; walking resumes after it
    const S = W.ship.spec, sp = 150 * W.ship.cls.crewScale;
    const workers = Object.values(W.crew).filter((p) => p.role === "worker");
    const order = ["captain", "firstmate", "reviewer-1", ...workers.map((p) => p.id)].filter((id) => W.crew[id]);
    const cx = Math.max(S.main[0] + 300, Math.min(S.main[1] - 300, 0)), cap = Math.max(5, Math.floor((S.main[1] - S.main[0] - 160) / sp) | 1);
    const offs = (i) => (i === 0 ? 0 : (i % 2 ? 1 : -1) * Math.ceil(i / 2));
    const marks = {};
    order.forEach((id, i) => {
      const back = i >= cap, j = back ? i - cap : i;
      marks[id] = { x: cx + offs(j) * sp + (back ? sp / 2 : 0), off: back ? -30 : 0 }; // the second rank on the far side of the waist
    });
    for (const [id, m] of Object.entries(marks)) {
      const p = W.crew[id];
      p.clearShot("slump");
      p.aloft = false;
      p.deckOff = m.off;
      p.walkTo(m.x, 1.1, () => {
        p.view = "f";
        p.dir = 1;
        p.setLoop("idle");
      });
    }
    const span = Math.min(order.length, cap) * sp + 500;
    this.heroFrame = { x: cx, w: Math.max(1500, span) };
    document.body.classList.add("ending");
    this.savedPlacard = D.placard;
    D.placard = 0;
    this.camera.go({ x: cx, y: -600 - S.ride, h: 1800, w: Math.max(2500, span + 800) }, { k: 4 });
    D.after(1.3, () => {
      ov.barsTarget = 1;
      for (const p of Object.values(W.crew)) ((p.view = "f"), (p.dir = 1));
      order.forEach((id, i) =>
        W.crew[id]?.shot(id === "captain" ? "heroPose" : id === "reviewer-1" ? "heroInspect" : "heroFist", i * 0.08),
      );
      this.sound.play("whoosh");
      this.camera.go({ x: cx, y: -470 - S.ride - (order.length > cap ? 60 : 0), h: 1150, w: this.heroFrame.w }, { k: 3, push: 0.1 });
      this.heroLight = 1;
    });
    const volley = (k) =>
      D.after(1.6 + k * 1.1, () => {
        fx.fireworks(cx + ((k % 3) - 1) * 250 * Math.max(1, this.heroFrame.w / 1500), -950 - S.ride - (k % 2) * 150, 3 + (k % 2) + (W.level >= 3 ? 2 : 0));
        this.sound.play("fireworks");
      });
    for (let k = 0; k < 6; k++) volley(k);
    // the freeze frame and the title card
    D.after(3.0, () => {
      fx.impactFrames(["white"]);
      fx.stop(1.1);
      this.freeze = 1.1;
      ov.card({ jp: "勝利!", en: "VICTORY", sub: this.ui.tr ? this.ui.tr("the kraken lets go · approved on the board") : "the kraken lets go · approved on the board" });
    });
    D.after(10.5, () => this.endEnding());
  }
  endEnding() {
    const W = this.world,
      D = this.director,
      ov = this.overlay;
    this.ending = null;
    D.force = false;
    document.body.classList.remove("ending");
    D.placard = this.getSim().decisions.length ? 1 : 0;
    ov.barsTarget = 0;
    ov.title = null;
    this.heroLight = 0;
    W.env.night = 0;
    for (const p of Object.values(W.crew)) {
      p.view = "q";
      for (const s of ["heroPose", "heroFist", "heroInspect"]) p.clearShot(s);
    }
    // everyone walks back to his spot on this ship's decks: hands at work to their stations
    W.resume(this.getSim());
  }
  // ---------------------------------------------------------------- per frame
  update(dt, sim) {
    const W = this.world,
      K = W.kraken;
    if (this.ending) this.ending.t += dt;
    this.freeze = Math.max(0, (this.freeze || 0) - dt);
    this.blur = Math.max(0, this.blur - dt * 1.4);
    if (this.zoomBlur) ((this.zoomBlur.k -= dt * 2.2), this.zoomBlur.k <= 0 && (this.zoomBlur = null));
    for (const s of this.slashes) s.t += dt;
    this.slashes = this.slashes.filter((s) => s.t < 0.45);
    for (const c of this.chains) c.t += dt;
    if (this.callout) ((this.callout.t += dt), this.callout.t > 1.2 && (this.callout = null));
    if (this.stamp) ((this.stamp.t += dt), this.stamp.t > 2 && (this.stamp = null));
    this.ink = Math.max(0, (this.ink || 0) - dt);
    if (this.playing && this.b) {
      const r = stepBattle(this.b, { type: "tick", dt: dt * (W.fx.slow > 0 ? 0.35 : 1) });
      this.b = r.battle;
      for (const e of r.events) this.onEvent(e);
      const av = attackView(this.b);
      if (av) {
        const a = K.arms[av.arm % Math.max(1, K.arms.length)];
        if (a && a.attack) a.attack.p = av.p;
      }
      this.gripGhost += (this.b.grip / 100 - this.gripGhost) * Math.min(1, dt * 1.5);
      const u = ultView(this.b);
      // the tidal wall rises through the brace and comes down in the strike
      if (u) this.wave = u.stage === "windup" ? u.p * 0.3 : u.stage === "brace" ? 0.3 + u.p * 0.5 : 0.8 + u.p * 0.4;
    }
    if (this.wave < 0) this.wave = Math.min(0, this.wave + dt * 1.2);
    else if (this.wave >= 2) this.wave = Math.max(0, this.wave - dt * 1.2) || 0;
    if (this.heroLight) this.heroLight = Math.min(1, this.heroLight + dt);
  }
  // the world-space extras: the tidal wall, chains, slashes, hero light, stamp
  drawWorld(ctx) {
    const W = this.world,
      K = W.kraken;
    if (this.heroLight) {
      const [x, y] = W.ship.toWorld(0, -400);
      ctx.save();
      ctx.globalCompositeOperation = "lighter";
      for (let i = 0; i < 12; i++) {
        const a = -Math.PI / 2 + (i - 5.5) * 0.16 + Math.sin(W.env.t * 0.6 + i) * 0.03;
        const g = ctx.createLinearGradient(x, y, x + Math.cos(a) * 2200, y + Math.sin(a) * 2200);
        g.addColorStop(0, `rgba(255,220,140,${0.28 * this.heroLight})`);
        g.addColorStop(1, "rgba(255,200,120,0)");
        ctx.fillStyle = g;
        ctx.beginPath();
        ctx.moveTo(x, y);
        ctx.lineTo(x + Math.cos(a - 0.05) * 2200, y + Math.sin(a - 0.05) * 2200);
        ctx.lineTo(x + Math.cos(a + 0.05) * 2200, y + Math.sin(a + 0.05) * 2200);
        ctx.fill();
      }
      const gl = ctx.createRadialGradient(x, y + 200, 0, x, y + 200, 900);
      gl.addColorStop(0, `rgba(255,210,120,${0.35 * this.heroLight})`);
      gl.addColorStop(1, "rgba(255,160,60,0)");
      ctx.fillStyle = gl;
      ctx.fillRect(x - 900, y - 700, 1800, 1800);
      ctx.restore();
    }
    for (const c of this.chains) {
      const a = c.a;
      if (!a.bound) continue;
      const k = Math.min(1, c.t / 0.25);
      const [tx, ty] = a.tip;
      ctx.strokeStyle = "#c9c9d6";
      ctx.lineWidth = 20;
      ctx.setLineDash([30, 10]);
      ctx.beginPath();
      ctx.moveTo(c.from[0], c.from[1]);
      ctx.quadraticCurveTo(
        (c.from[0] + tx) / 2,
        Math.max(c.from[1], ty) + 200,
        c.from[0] + (tx - c.from[0]) * k,
        c.from[1] + (ty - c.from[1]) * k,
      );
      ctx.stroke();
      ctx.setLineDash([]);
    }
    for (const s of this.slashes) {
      const k = s.t / 0.45,
        e = 1 - (1 - Math.min(1, k * 3)) ** 3;
      ctx.save();
      ctx.translate(s.x, s.y);
      ctx.rotate(s.a);
      // a brush-stroke crescent: fat in the middle, tapering to points, inked
      const a0 = -1.4,
        a1 = -1.4 + 2.8 * e,
        fat = 90 * (1 - k * 0.7);
      const crescent = (r, w) => {
        ctx.beginPath();
        for (let i = 0; i <= 24; i++) {
          const u = i / 24,
            a = a0 + (a1 - a0) * u;
          ctx.lineTo(Math.cos(a) * (r + w * Math.sin(Math.PI * u)), Math.sin(a) * (r + w * Math.sin(Math.PI * u)));
        }
        for (let i = 24; i >= 0; i--) {
          const u = i / 24,
            a = a0 + (a1 - a0) * u;
          ctx.lineTo(Math.cos(a) * r, Math.sin(a) * r);
        }
        ctx.closePath();
      };
      ctx.globalAlpha = 1 - k * 0.6;
      crescent(s.r, fat + 16);
      ctx.fillStyle = "#000";
      ctx.fill();
      crescent(s.r + 8, fat);
      ctx.fillStyle = "#fffbe6";
      ctx.fill();
      ctx.restore();
    }
    if (this.wave >= 0.8) this.drawWave(ctx);
    if (this.aura) this.drawAura(ctx);
    if (this.stamp) {
      const r = this.C("reviewer-1");
      if (r) {
        const [x, y] = W.at(r, "head");
        const k = Math.min(1, this.stamp.t / 0.18);
        ctx.save();
        ctx.translate(x, y - 330);
        ctx.rotate(-0.18);
        ctx.scale(2.4 - 1.4 * k, 2.4 - 1.4 * k);
        ctx.globalAlpha = Math.min(1, 2 - this.stamp.t);
        ctx.strokeStyle = "#2ec27e";
        ctx.lineWidth = 16;
        ctx.strokeRect(-260, -70, 520, 140);
        ctx.fillStyle = "#2ec27e";
        ctx.font = "italic 900 110px 'Barlow Semi Condensed', system-ui, sans-serif";
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillText("APPROVED", 0, 6);
        ctx.restore();
      }
    }
  }
  // the charge-up aura: swirling ribbons of light and flame tongues round the fighter
  drawAura(ctx) {
    const p = this.C(this.aura.who);
    if (!p) return;
    const [x, y] = this.world.at(p, "torso", 0, -60);
    const t = this.world.env.t,
      R = p.height * 0.9;
    ctx.save();
    ctx.translate(x, y);
    ctx.globalCompositeOperation = "lighter";
    for (let i = 0; i < 6; i++) {
      const a0 = t * (3 + i * 0.4) + i;
      ctx.strokeStyle = i % 2 ? "rgba(120,200,255,.8)" : "rgba(255,220,120,.8)";
      ctx.lineWidth = 14 - i;
      ctx.beginPath();
      ctx.ellipse(0, 0, R * (0.7 + i * 0.07), R * (1.1 + i * 0.05), 0.3 * Math.sin(i), a0, a0 + 2.2);
      ctx.stroke();
    }
    ctx.globalCompositeOperation = "source-over";
    for (let i = 0; i < 9; i++) {
      const fx0 = (i - 4) * R * 0.2,
        h = R * (0.8 + 0.4 * Math.abs(Math.sin(t * 9 + i * 1.3)));
      ctx.beginPath();
      ctx.moveTo(fx0 - 28, R * 0.7);
      ctx.quadraticCurveTo(fx0 - 10, R * 0.7 - h * 0.6, fx0 + Math.sin(t * 7 + i) * 20, R * 0.7 - h);
      ctx.quadraticCurveTo(fx0 + 10, R * 0.7 - h * 0.5, fx0 + 28, R * 0.7);
      ctx.fillStyle = "rgba(120,200,255,.55)";
      ctx.fill();
      ctx.lineWidth = 4;
      ctx.strokeStyle = "#000";
      ctx.stroke();
    }
    ctx.restore();
  }
  drawWave(ctx) {
    const W = this.world,
      K = W.kraken,
      S = W.ship;
    const wv = this.wave;
    if (!(wv > 0.01 && wv < 2.5)) return;
    // the tidal wall: rising between the kraken and the ship, then curling over the deck
    const k = wv >= 2 ? 1 - (wv - 2) : Math.min(1, wv);
    const h = 300 + 1150 * Math.min(1, k);
    const x0 = wv >= 2 ? S.x - 600 * (1 - (wv - 2)) : K.x - 150 - 1300 * Math.min(1, Math.max(0, wv - 0.8) / 0.4);
    const t = W.env.t;
    const top = SEA_Y - h;
    const lip = Math.min(1, Math.max(0, (wv - 0.7) / 0.5)); // the crest curls over as it comes
    ctx.save();
    const g = ctx.createLinearGradient(0, top, 0, SEA_Y + 100);
    g.addColorStop(0, "rgba(210,245,255,.97)");
    g.addColorStop(0.12, "rgba(70,150,210,.95)");
    g.addColorStop(0.55, "rgba(30,70,150,.95)");
    g.addColorStop(1, "rgba(40,10,60,.97)");
    ctx.fillStyle = g;
    const face = () => {
      ctx.beginPath();
      ctx.moveTo(x0 + 1600, SEA_Y + 220);
      ctx.lineTo(x0 + 1600, top + h * 0.15);
      ctx.bezierCurveTo(x0 + 1100, top - 60, x0 + 500, top - 90, x0 + 120, top + 40);
      // the curling lip
      ctx.bezierCurveTo(
        x0 - 180 - 260 * lip,
        top + 120,
        x0 - 260 - 200 * lip,
        top + 380 * (0.6 + lip * 0.6),
        x0 - 60 - 100 * lip,
        top + 420 + 200 * lip,
      );
      ctx.bezierCurveTo(x0 + 40, top + 300, x0 - 60, top + h * 0.7, x0 - 160, SEA_Y + 220);
      ctx.closePath();
    };
    face();
    ctx.fill();
    // the inner curl shadow and the glassy face streaks
    ctx.save();
    face();
    ctx.clip();
    ctx.strokeStyle = "rgba(200,240,255,.25)";
    ctx.lineWidth = 14;
    for (let i = 0; i < 9; i++) {
      const y = top + 120 + i * (h / 10);
      ctx.beginPath();
      ctx.moveTo(x0 - 100, y + Math.sin(t * 2 + i) * 20);
      ctx.bezierCurveTo(x0 + 400, y - 60, x0 + 900, y + 40, x0 + 1600, y - 30);
      ctx.stroke();
    }
    ctx.restore();
    // the foam crest
    ctx.strokeStyle = "rgba(255,255,255,.95)";
    ctx.lineWidth = 40;
    ctx.lineCap = "round";
    ctx.beginPath();
    ctx.moveTo(x0 + 1600, top + h * 0.15);
    ctx.bezierCurveTo(x0 + 1100, top - 60, x0 + 500, top - 90, x0 + 120, top + 40);
    ctx.bezierCurveTo(
      x0 - 180 - 260 * lip,
      top + 120,
      x0 - 260 - 200 * lip,
      top + 380 * (0.6 + lip * 0.6),
      x0 - 60 - 100 * lip,
      top + 420 + 200 * lip,
    );
    ctx.stroke();
    drawCrest(ctx, x0 + 60, top + 520 * (0.6 + lip * 0.6), 360 * lip + 1, -1);
    // spray blowing off the crest
    ctx.fillStyle = "rgba(240,250,255,.85)";
    for (let i = 0; i < (W.low ? 14 : 34); i++) {
      const u = i / 34,
        x = x0 + 1500 - u * 1500 - 200 * lip * u + Math.sin(t * 7 + i) * 30,
        y = top - 40 - Math.abs(Math.sin(t * 5 + i * 1.7)) * 160 * (1 - u * 0.5);
      ctx.beginPath();
      ctx.arc(x, y, 8 + (i % 4) * 6, 0, TAU);
      ctx.fill();
    }
    ctx.restore();
  }
  hud() {
    if (!this.playing || !this.b) return null;
    const b = this.b;
    return {
      grip: b.grip,
      gripGhost: this.gripGhost,
      hull: b.hull,
      gauge: b.gauge,
      combo: b.combo,
      attack: attackView(b),
      ult: ultView(b),
      labels: this.held.join(" · "),
      riposte: b.riposteUntil > b.t,
      weak: b.weak,
      finisher: b.phase === "finisher" && !this.finishing,
      charge: b.charge !== null ? (b.t - b.charge) / TUNE.specials.broadside.charge : null,
      zone: TUNE.specials.broadside.zone,
      bracing: this.bracing,
    };
  }
  // --- the real board's pressure while fighting (v3's hooks)
  realStrike(e) {
    const i = (e.seq || 0) % 4,
      W = this.world;
    const [x, y] = W.sectionWorld(i);
    W.fx.explode(x, y, 3, { deck: true });
    W.ship.kick(14);
    this.sound.play("impact");
  }
  realPush() {
    const W = this.world;
    const [ex, ey] = this.headWorld();
    const from = W.ship.portWorld(2);
    W.fx.muzzle(from[0], from[1], 1);
    W.fx.cannon(from, [ex, ey], { onHit: () => W.fx.explode(ex, ey, 2, { purple: true }) });
    this.sound.play("cannon");
  }
}
