// Playground only: lending a hand at a working crewman's station. Four short games (each under
// 15 s, skippable with Esc or the Skip button), in both styles and three languages:
//   gun    loading rhythm: tap as the ring meets the gold, four times (swab, powder, ball, ram)
//   rig    hauling sail: left, right, left, right, before the sail slips back
//   nest   spotting a sail: bring the spyglass onto the sail and call it, three times
//   stamp  stamping: stamp each paper as it passes under the stamp
// A win is a small morale boost (Helm.won): the crew cheer, a star on the deck's hint. It is a
// show only: nothing here reaches the sim, the source or the board, and Live never opens one.
const T = {
  en: {
    skip: "Skip", win: "Well done!", lose: "Not this time", time: "s", tap: "TAP",
    gun: ["LOAD THE GUN", "装填!", "Tap (Space / E) as the ring meets the gold", ["Swab", "Powder", "Ball", "Ram"]],
    rig: ["HAUL THE SAIL", "帆を上げろ!", "Left, right, left, right: ← → (or tap each side)"],
    nest: ["SPOT A SAIL", "帆影発見!", "← → move the spyglass · Space / E (or tap) on the sail"],
    stamp: ["STAMP IT", "承認!", "Space / E (or tap) as each paper passes under the stamp"],
  },
  "zh-TW": {
    skip: "略過", win: "幹得好！", lose: "這次沒成功", time: "秒", tap: "點擊",
    gun: ["裝填火砲", "装填!", "圓圈碰到金色時點擊（空白鍵 / E）", ["清膛", "裝藥", "裝彈", "壓實"]],
    rig: ["拉帆", "帆を上げろ!", "左、右、左、右：← →（或輪流點左右兩側）"],
    nest: ["瞭望來帆", "帆影発見!", "← → 移動望遠鏡 · 對準帆影按空白鍵 / E（或點擊）"],
    stamp: ["蓋章", "承認!", "文件經過印章下方時按空白鍵 / E（或點擊）"],
  },
  "zh-CN": {
    skip: "略过", win: "干得好！", lose: "这次没成功", time: "秒", tap: "点击",
    gun: ["装填火炮", "装填!", "圆圈碰到金色时点击（空格 / E）", ["清膛", "装药", "装弹", "压实"]],
    rig: ["拉帆", "帆を上げろ!", "左、右、左、右：← →（或轮流点左右两侧）"],
    nest: ["瞭望来帆", "帆影発見!", "← → 移动望远镜 · 对准帆影按空格 / E（或点击）"],
    stamp: ["盖章", "承認!", "文件经过印章下方时按空格 / E（或点击）"],
  },
};
export const MINI_LIMIT = 12; // seconds; every game ends by then
const GAMES = {
  // four beats: a ring closes on the gold band; a tap inside it is a hit; three hits win
  gun: {
    start(g) { g.beat = 0; g.hits = 0; g.bt = 0; g.need = 3; g.beats = 4; g.len = 1.15; g.marks = []; },
    update(g, dt) {
      g.bt += dt;
      if (g.bt > g.len + 0.2) (g.marks.push(false), g.beat++, (g.bt = 0));
      if (g.beat >= g.beats) return g.hits >= g.need;
    },
    ring(g) { return 1.6 - (g.bt / g.len) * 1.2; }, // 1.6 -> 0.4, gold at 1.0 +- 0.14
    press(g) {
      if (g.beat >= g.beats) return;
      const hit = Math.abs(this.ring(g) - 1) < 0.14;
      g.marks.push(hit);
      if (hit) g.hits++;
      g.beat++;
      g.bt = 0;
      g.flash = hit ? 1 : -1;
    },
    best(g) { return Math.abs(this.ring(g) - 1) < 0.05; },
    draw(g, x, W, H, P) {
      const cx = W / 2, cy = H * 0.52, R = Math.min(W, H) * 0.24;
      x.lineWidth = 16;
      x.strokeStyle = P.gold;
      x.beginPath(); x.arc(cx, cy, R, 0, Math.PI * 2); x.stroke();
      x.lineWidth = 3;
      x.strokeStyle = P.ink;
      x.beginPath(); x.arc(cx, cy, R * 1.14, 0, Math.PI * 2); x.arc(cx, cy, R * 0.86, 0, Math.PI * 2); x.stroke();
      if (g.beat < g.beats) {
        x.lineWidth = 8;
        x.strokeStyle = P.accent;
        x.beginPath(); x.arc(cx, cy, Math.max(4, R * this.ring(g)), 0, Math.PI * 2); x.stroke();
      }
      // the cannon's muzzle in the middle
      x.fillStyle = "#26262c";
      x.beginPath(); x.arc(cx, cy, R * 0.34, 0, Math.PI * 2); x.fill();
      x.fillStyle = "#050505";
      x.beginPath(); x.arc(cx, cy, R * 0.18, 0, Math.PI * 2); x.fill();
      const steps = g.t[3];
      steps.forEach((s, i) => {
        const bx = W * (0.14 + i * 0.24), by = H * 0.9;
        x.fillStyle = i < g.marks.length ? (g.marks[i] ? P.gold : P.dim) : i === g.beat ? P.paper : P.dim;
        x.fillRect(bx - 50, by - 20, 100, 30);
        x.strokeStyle = P.ink;
        x.lineWidth = 3;
        x.strokeRect(bx - 50, by - 20, 100, 30);
        x.fillStyle = P.ink;
        x.fillText(s, bx, by - 4);
      });
    },
  },
  // haul: alternate left and right; each good pull lifts the sail, it slips back slowly
  rig: {
    start(g) { g.p = 0; g.last = 0; },
    update(g, dt) { if (g.p >= 0.999) return true; g.p = Math.max(0, g.p - dt * 0.07); },
    press(g, side) {
      if (!side || side === g.last) return void (g.flash = -1);
      g.last = side;
      g.p = Math.min(1, g.p + 0.085);
      g.flash = 1;
    },
    draw(g, x, W, H, P) {
      const top = H * 0.16, bot = H * 0.82, mx = W / 2;
      x.fillStyle = P.wood;
      x.fillRect(mx - 8, top - 10, 16, bot - top + 30);
      const sy = bot - (bot - top) * g.p;
      x.fillStyle = "#fbf1dc";
      x.strokeStyle = P.ink;
      x.lineWidth = 4;
      x.beginPath(); x.moveTo(mx - 120, sy); x.lineTo(mx + 120, sy); x.quadraticCurveTo(mx + 140, sy + 60, mx + 110, sy + 110); x.quadraticCurveTo(mx, sy + 130, mx - 110, sy + 110); x.quadraticCurveTo(mx - 140, sy + 60, mx - 120, sy); x.fill(); x.stroke();
      x.fillStyle = P.accent;
      x.fillRect(mx - 124, sy - 8, 248, 12);
      for (const [s, lx] of [[-1, W * 0.15], [1, W * 0.85]]) {
        x.fillStyle = g.last === s ? P.gold : P.paper;
        x.fillRect(lx - 40, H * 0.5 - 30, 80, 60);
        x.strokeStyle = P.ink;
        x.strokeRect(lx - 40, H * 0.5 - 30, 80, 60);
        x.fillStyle = P.ink;
        x.fillText(s < 0 ? "←" : "→", lx, H * 0.5 + 8);
      }
    },
  },
  // spot: a sail shows on the horizon; bring the spyglass onto it and call it; three spots win
  nest: {
    start(g) { g.rx = 0.5; g.spots = 0; g.need = 3; g.next(g); },
    next(g) { g.sx = 0.12 + g.rnd() * 0.76; g.st = 0; },
    update(g, dt) {
      g.rx = Math.max(0.04, Math.min(0.96, g.rx + g.dir * dt * 0.55));
      g.st += dt;
      if (g.st > 3.2) this.next(g);
      if (g.spots >= g.need) return true;
    },
    press(g, _, at) {
      if (at != null) g.rx = at;
      if (Math.abs(g.rx - g.sx) < 0.07) (g.spots++, (g.flash = 1), this.next(g));
      else g.flash = -1;
    },
    best(g) { return Math.abs(g.rx - g.sx) < 0.03; },
    steer(g) { return Math.sign(g.sx - g.rx) * (Math.abs(g.sx - g.rx) > 0.02 ? 1 : 0); },
    draw(g, x, W, H, P) {
      const hy = H * 0.55;
      x.fillStyle = "#7fb0e0";
      x.fillRect(0, 0, W, hy);
      x.fillStyle = "#1c56b8";
      x.fillRect(0, hy, W, H - hy);
      // the sail far off, bobbing
      const sx = g.sx * W, sy = hy - 8 + Math.sin(g.st * 3) * 3, a = Math.min(1, g.st * 2);
      x.globalAlpha = a;
      x.fillStyle = "#fbf1dc";
      x.beginPath(); x.moveTo(sx, sy - 44); x.lineTo(sx + 22, sy - 8); x.lineTo(sx - 18, sy - 8); x.fill();
      x.fillStyle = "#3a2010";
      x.fillRect(sx - 20, sy - 8, 40, 8);
      x.globalAlpha = 1;
      // the spyglass circle
      const rx = g.rx * W, R = Math.min(W, H) * 0.14;
      x.strokeStyle = P.ink;
      x.lineWidth = 8;
      x.beginPath(); x.arc(rx, hy - 20, R, 0, Math.PI * 2); x.stroke();
      x.strokeStyle = P.accent;
      x.lineWidth = 3;
      x.beginPath(); x.moveTo(rx - R, hy - 20); x.lineTo(rx + R, hy - 20); x.moveTo(rx, hy - 20 - R); x.lineTo(rx, hy - 20 + R); x.stroke();
      for (let i = 0; i < g.need; i++) {
        x.fillStyle = i < g.spots ? P.gold : P.dim;
        x.beginPath(); x.arc(W * 0.4 + i * 44, H * 0.9, 14, 0, Math.PI * 2); x.fill();
        x.strokeStyle = P.ink; x.lineWidth = 3; x.stroke();
      }
    },
  },
  // stamp: papers slide under the stamp; stamp each as it passes; four of five win
  stamp: {
    start(g) { g.papers = [0, 1, 2, 3, 4].map((i) => ({ x: 1.25 + i * 0.52, done: 0 })); g.hits = 0; g.need = 4; g.speed = 0.36; g.down = 0; },
    update(g, dt) {
      for (const p of g.papers) p.x -= dt * g.speed;
      g.down = Math.max(0, g.down - dt * 5);
      if (g.papers.every((p) => p.x < -0.2) || g.hits >= g.need) return g.hits >= g.need;
    },
    press(g) {
      g.down = 1;
      const p = g.papers.find((q) => !q.done && Math.abs(q.x - 0.5) < 0.07);
      if (p) (p.done = 1), g.hits++, (g.flash = 1);
      else g.flash = -1;
    },
    best(g) { return g.papers.some((q) => !q.done && Math.abs(q.x - 0.5) < 0.02); },
    draw(g, x, W, H, P) {
      const by = H * 0.66;
      x.fillStyle = P.wood;
      x.fillRect(0, by + 44, W, 14);
      for (const p of g.papers) {
        const px = p.x * W;
        if (px < -80 || px > W + 80) continue;
        x.fillStyle = "#fbf1dc";
        x.fillRect(px - 50, by - 60, 100, 104);
        x.strokeStyle = P.ink; x.lineWidth = 3; x.strokeRect(px - 50, by - 60, 100, 104);
        x.fillStyle = "rgba(0,0,0,.25)";
        for (let k = 0; k < 4; k++) x.fillRect(px - 36, by - 44 + k * 18, 72, 5);
        if (p.done) {
          x.save(); x.translate(px, by - 8); x.rotate(-0.2);
          x.strokeStyle = P.accent; x.lineWidth = 5; x.strokeRect(-40, -18, 80, 36);
          x.fillStyle = P.accent; x.font = "900 18px 'Dela Gothic One', sans-serif"; x.fillText("OK", 0, 7);
          x.restore();
        }
      }
      // the stamp over the middle
      const sy = H * 0.12 + g.down * (by - 70 - H * 0.12);
      x.fillStyle = P.wood;
      x.fillRect(W / 2 - 16, sy - 70, 32, 60);
      x.fillStyle = P.accent;
      x.fillRect(W / 2 - 46, sy - 12, 92, 26);
      x.strokeStyle = P.ink; x.lineWidth = 3; x.strokeRect(W / 2 - 46, sy - 12, 92, 26);
      for (let i = 0; i < g.need; i++) {
        x.fillStyle = i < g.hits ? P.gold : P.dim;
        x.fillRect(W * 0.36 + i * 40, H * 0.92 - 12, 28, 18);
      }
    },
  },
};

export class MiniGames {
  constructor({ ui, mode, onWin, world }) {
    Object.assign(this, { ui, mode, onWin, world });
    this.active = null;
    this.results = [];
    this.build();
  }
  get t() { return T[this.ui.lang] || T.en; }
  build() {
    const css = document.createElement("style");
    css.textContent = `
      #mini { position: fixed; inset: 0; z-index: 30; display: grid; place-items: center; background: rgba(12,6,8,.55); }
      #mini[hidden] { display: none; }
      #mini .panel { width: min(640px, 94vw); background: #fff; border: 6px solid #0c0608; box-shadow: 12px 12px 0 #e60012; transform: rotate(-1deg); padding: 12px 14px 14px; display: flex; flex-direction: column; gap: 8px; }
      #mini h2 { margin: 0; font-size: 30px; display: flex; gap: 12px; align-items: baseline; }
      #mini h2 i { font-style: normal; font-family: "Dela Gothic One", sans-serif; font-weight: 400; color: #e60012; font-size: 24px; }
      #mini p { margin: 0; font-size: 15px; font-weight: 700; }
      #mini canvas { width: 100%; aspect-ratio: 16 / 8; background: #f2efe8; border: 3px solid #0c0608; touch-action: none; display: block; }
      #mini footer { display: flex; justify-content: space-between; align-items: center; }
      #mini footer b { font-size: 22px; }
      #mini footer button { background: #0c0608; color: #fff; min-height: 44px; padding: 0 18px; }
      #mini .res { font-size: 26px; min-height: 30px; }
      body[data-style="manga"] #mini { background: rgba(246,238,219,.55); }
      body[data-style="manga"] #mini .panel { border: 0; border-radius: 18px; box-shadow: 0 0 0 5px #0c0608, 8px 9px 0 5px #0c0608; transform: none; background-image: radial-gradient(rgba(0,0,0,.08) 1.2px, transparent 1.4px); background-size: 7px 7px; background-color: #fff; }
      body[data-style="manga"] #mini h2 i { color: #0c0608; }
      body[data-style="manga"] #mini canvas { border-radius: 10px; }
      body[data-style="manga"] #mini footer button { border-radius: 16px; }
    `;
    document.head.appendChild(css);
    const el = (this.el = document.createElement("div"));
    el.id = "mini";
    el.hidden = true;
    el.setAttribute("role", "dialog");
    el.innerHTML = `<div class="panel"><h2><span data-m="title"></span><i data-m="jp"></i></h2><p data-m="how"></p><canvas width="640" height="320"></canvas><div class="res" data-m="res"></div><footer><b data-m="time"></b><button data-m="skip"></button></footer></div>`;
    document.body.appendChild(el);
    this.cv = el.querySelector("canvas");
    el.querySelector('[data-m="skip"]').addEventListener("click", () => this.close("skipped"));
    this.cv.addEventListener("pointerdown", (e) => {
      if (!this.active) return;
      e.preventDefault();
      const r = this.cv.getBoundingClientRect(), u = (e.clientX - r.left) / r.width;
      this.press(u < 0.5 ? -1 : 1, u);
    });
  }
  // open a station's game (Playground only); false when it may not open
  open(kind, crewId) {
    if (this.active || this.mode() !== "playground" || !GAMES[kind]) return false;
    let seed = 1 + this.results.length * 7919 + (crewId || "").length * 31;
    const g = { kind, crewId, t: this.t[kind], clock: 0, dir: 0, flash: 0, done: null, rnd: () => ((seed = (seed * 16807) % 2147483647) / 2147483647) };
    g.next = (x) => GAMES.nest.next(x);
    GAMES[kind].start(g);
    this.active = g;
    this.el.hidden = false;
    document.body.classList.add("minigame");
    this.labels();
    return true;
  }
  labels() {
    const g = this.active, t = this.t, m = (k) => this.el.querySelector(`[data-m="${k}"]`);
    if (!g) return;
    g.t = t[g.kind];
    m("title").textContent = g.t[0];
    m("jp").textContent = g.t[1];
    m("how").textContent = g.t[2];
    m("skip").textContent = g.done ? "OK" : t.skip + " · Esc";
    m("res").textContent = g.done === "won" ? t.win : g.done === "lost" ? t.lose : "";
  }
  // Esc skips; Space, E and the arrows play
  key(k, down = true) {
    if (!this.active) return false;
    const g = this.active;
    if (k === "Escape") return this.close(g.done ? g.done : "skipped"), true;
    if (g.done) { if (k === " " || k === "Enter" || k.toLowerCase() === "e") this.close(g.done); return true; }
    if (g.kind === "nest" && (k === "ArrowLeft" || k === "ArrowRight" || k === "a" || k === "d")) return (g.dir = down ? (k === "ArrowLeft" || k === "a" ? -1 : 1) : 0), true;
    if (!down) return true;
    if (k === "ArrowLeft" || k.toLowerCase() === "a") return this.press(-1), true;
    if (k === "ArrowRight" || k.toLowerCase() === "d") return this.press(1), true;
    if (k === " " || k.toLowerCase() === "e") return this.press(0), true;
    return true; // the game has the keys while it is open (Esc, the menu and the card come first)
  }
  press(side, at) {
    const g = this.active;
    if (!g || g.done) return;
    GAMES[g.kind].press(g, side, g.kind === "nest" ? at : undefined);
  }
  update(dt) {
    const g = this.active;
    if (!g) return;
    if (!g.done) {
      g.clock += dt;
      // the test bot plays a perfect game
      if (window.__miniBot) this.bot(g);
      const r = GAMES[g.kind].update(g, dt);
      if (r === true) this.finish("won");
      else if (r === false || g.clock >= MINI_LIMIT) this.finish("lost");
    } else if ((g.after = (g.after || 0) + dt) > 1.6) return this.close(g.done); // the result shows a moment, then it closes
    g.flash *= Math.exp(-dt * 6);
    this.draw();
  }
  bot(g) {
    const G = GAMES[g.kind];
    if (g.kind === "rig") return this.press(g.last === -1 ? 1 : -1);
    if (g.kind === "nest") { g.dir = G.steer(g); if (G.best(g)) this.press(0); return; }
    if (G.best?.(g)) this.press(0);
  }
  finish(res) {
    const g = this.active;
    g.done = res;
    this.labels();
    if (res === "won") this.onWin?.(g.kind, g.crewId);
  }
  close(res = "skipped") {
    const g = this.active;
    if (!g) return;
    this.results.push({ kind: g.kind, crew: g.crewId, result: g.done || res, secs: +g.clock.toFixed(2) });
    this.active = null;
    this.el.hidden = true;
    document.body.classList.remove("minigame");
  }
  draw() {
    const g = this.active, x = this.cv.getContext("2d"), W = this.cv.width, H = this.cv.height;
    const manga = document.body.dataset.style === "manga";
    const P = manga ? { ink: "#1a1410", paper: "#fff", gold: "#1a1410", accent: "#1a1410", dim: "#d8d0c0", wood: "#5a4a3a" } : { ink: "#0c0608", paper: "#fff", gold: "#f2c040", accent: "#e60012", dim: "#cfc8bd", wood: "#6b3f22" };
    x.setTransform(1, 0, 0, 1, 0, 0);
    x.clearRect(0, 0, W, H);
    x.fillStyle = manga ? "#fff" : "#f2efe8";
    x.fillRect(0, 0, W, H);
    if (manga) {
      // screentone
      x.fillStyle = "rgba(0,0,0,.07)";
      for (let yy = 0; yy < H; yy += 7) for (let xx = (yy / 7) % 2 ? 3 : 0; xx < W; xx += 7) x.fillRect(xx, yy, 2, 2);
    }
    x.font = "800 20px 'Barlow Semi Condensed', 'Noto Sans TC', 'Noto Sans SC', sans-serif";
    x.textAlign = "center";
    GAMES[g.kind].draw(g, x, W, H, P);
    if (Math.abs(g.flash) > 0.05) {
      x.fillStyle = g.flash > 0 ? `rgba(242,192,64,${0.3 * g.flash})` : `rgba(230,0,18,${0.25 * -g.flash})`;
      x.fillRect(0, 0, W, H);
    }
    const left = Math.max(0, MINI_LIMIT - g.clock);
    const tm = this.el.querySelector('[data-m="time"]');
    const s = g.done ? "" : `${left.toFixed(1)} ${this.t.time}`;
    if (tm.textContent !== s) tm.textContent = s;
  }
}
export { T as MINI_TEXT, GAMES };
