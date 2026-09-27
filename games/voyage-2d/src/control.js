// The captain takes the deck: in either mode (Playground and Live) he may leave the helm and
// walk his ship. It is cosmetic only: nothing here reaches the sim, the source or the board.
//
//   Q, or a tap on the captain       take the deck / back to the helm (Esc leaves too)
//   ← → or A D                       walk (A and D belong to the decision card while one is up)
//   ↑ ↓ or W S                       take the stairs, ladder or shrouds he stands at
//   E, or a tap on the prompt        lend a hand at a working crewman's station (Playground only)
//   phones: a joystick, ▲ ▼ by a stair or ladder, E by a working hand, ✕ to leave
//
// The default camera stays the director's; while the captain has the deck it follows him.
// In the fight and in the endings he goes back to the wheel and the deck is closed.
import { Z_SCREEN } from "../v3src/sim/deckplan.js";

export const HELM_KEY = "q";
const T = {
  en: { on: "You have the deck", off: "Back to the helm", hint: "← → walk · ↑ ↓ stairs · E lend a hand · Q / Esc back to the helm", hintLive: "← → walk · ↑ ↓ stairs · Q / Esc back to the helm",
    up: "Up", down: "Down", leave: "Helm", take: "Take the deck", keys: "Q or tap the captain · ← → / A D walk · ↑ ↓ / W S stairs and ladders · E lend a hand (Playground) · while a card is up, A–D and Enter answer it",
    act: { gun: "Load the gun", rig: "Haul the sail", nest: "Spot a sail", stamp: "Stamp the papers" }, morale: "Morale" },
  "zh-TW": { on: "你接手甲板", off: "回到舵輪", hint: "← → 走動 · ↑ ↓ 上下樓梯 · E 幫把手 · Q / Esc 回到舵輪", hintLive: "← → 走動 · ↑ ↓ 上下樓梯 · Q / Esc 回到舵輪",
    up: "上", down: "下", leave: "舵輪", take: "接手甲板", keys: "Q 或點船長 · ← → / A D 走動 · ↑ ↓ / W S 上下樓梯與梯子 · E 幫把手（遊樂場）· 決策卡在畫面上時，A–D 與 Enter 用來回答",
    act: { gun: "裝填火砲", rig: "拉帆", nest: "瞭望來帆", stamp: "蓋章" }, morale: "士氣" },
  "zh-CN": { on: "你接手甲板", off: "回到舵轮", hint: "← → 走动 · ↑ ↓ 上下楼梯 · E 帮把手 · Q / Esc 回到舵轮", hintLive: "← → 走动 · ↑ ↓ 上下楼梯 · Q / Esc 回到舵轮",
    up: "上", down: "下", leave: "舵轮", take: "接手甲板", keys: "Q 或点船长 · ← → / A D 走动 · ↑ ↓ / W S 上下楼梯与梯子 · E 帮把手（游乐场）· 决策卡在画面上时，A–D 与 Enter 用来回答",
    act: { gun: "装填火炮", rig: "拉帆", nest: "瞭望来帆", stamp: "盖章" }, morale: "士气" },
};
// which mini-game a station holds
export const GAME_OF = { gun: "gun", rig: "rig", lookout: "nest", review: "stamp" };

export class Helm {
  constructor({ world, camera, director, ui, battle, mini, canvas }) {
    Object.assign(this, { world, camera, director, ui, battle, mini, canvas });
    this.on = false;
    this.held = new Set();
    this.stick = 0; // the joystick's x, -1..1
    this.morale = 0;
    this.linkNear = null;
    this.target = null;
    this.buildPad();
  }
  get t() { return T[this.ui.lang] || T.en; }
  get mode() { return this.ui.h.mode?.() || "playground"; }
  get captain() { return this.world.crew.captain; }
  get agent() { return this.world.agent("captain"); }
  get blocked() { return this.battle.playing || this.battle.ending || this.world.suspended; }
  toggle(force) { return (force ?? !this.on) ? this.enter() : this.leave(); }
  enter() {
    if (this.on || this.blocked || !this.agent) return false;
    this.on = true;
    this.held.clear();
    this.stick = 0;
    const a = this.agent;
    this.world.crowd.stop("captain");
    a.manual = { vx: 0 };
    this.director.follow = () => this.frame();
    document.body.classList.add("helm");
    this.ui.toast(this.t.on, { icon: "☸", ms: 2600 });
    this.renderPad();
    return true;
  }
  leave({ quiet = false } = {}) {
    if (!this.on) return false;
    this.on = false;
    this.held.clear();
    this.stick = 0;
    const a = this.agent;
    if (a) a.manual = null;
    this.director.follow = null;
    document.body.classList.remove("helm");
    if (!quiet) this.ui.toast(this.t.off, { icon: "☸", ms: 2000 });
    // he walks back to the wheel
    const c = this.captain;
    if (c) this.world.walkHome(c, () => c.setLoop("idle"));
    this.renderPad();
    return true;
  }
  // the camera's frame on him: close enough to read the deck, wide enough to see where he goes
  frame() {
    const c = this.captain;
    const [x, y] = this.world.at(c, "torso");
    const small = this.camera.W < 720;
    return { x, y: y - 40, h: small ? 1500 : 1250 };
  }
  // keys: true when used
  keyDown(k) {
    if (!this.on) return false;
    const K = k.length === 1 ? k.toLowerCase() : k;
    if (["ArrowLeft", "ArrowRight", "a", "d"].includes(K)) return this.held.add(K === "a" ? "ArrowLeft" : K === "d" ? "ArrowRight" : K), true;
    if (K === "ArrowUp" || K === "w") return this.climb(-1), true;
    if (K === "ArrowDown" || K === "s") return this.climb(1), true;
    if (K === "e") return this.interact(), true;
    return false;
  }
  keyUp(k) {
    const K = k.length === 1 ? k.toLowerCase() : k;
    this.held.delete(K === "a" ? "ArrowLeft" : K === "d" ? "ArrowRight" : K);
  }
  climb(way) {
    if (!this.on || this.mini?.active) return false;
    return this.world.crowd.takeLink("captain", way);
  }
  // the working crewman he could lend a hand to (Playground only): at a station, not walking,
  // on his deck and near him
  interactTarget() {
    if (!this.on || this.mode !== "playground" || this.mini?.active) return null;
    const a = this.agent, W = this.world;
    if (!a || a.link) return null;
    let best = null, bd = 230;
    for (const p of Object.values(W.crew)) {
      if (p.id === "captain") continue;
      const b = W.agent(p.id);
      if (!b || b.link || b.goal || b.deck !== a.deck) continue;
      let kind = null;
      if (p.id === "reviewer-1") kind = "stamp";
      else if (p.role === "worker") { const s = W.stationOf(p.id); kind = s && GAME_OF[s.kind]; }
      if (!kind) continue;
      const d = Math.abs(b.x - a.x);
      if (d < bd) (bd = d), (best = { id: p.id, kind });
    }
    return best;
  }
  interact() {
    const t = this.interactTarget();
    if (!t) return false;
    this.agent.manual.vx = 0;
    this.held.clear();
    this.stick = 0;
    return this.mini.open(t.kind, t.id);
  }
  // a won mini-game: a small morale boost, Playground only, and nothing but a show
  won(kind, id) {
    if (this.mode !== "playground") return;
    this.morale++;
    const W = this.world;
    let i = 0;
    for (const p of Object.values(W.crew)) p.shot("cheer", Math.min(0.4, i++ * 0.03));
    const p = W.crew[id];
    if (p) {
      const [x, y] = W.at(p, "head");
      for (let k = 0; k < 14; k++) W.fx.sprite("gold", x, y, { s: 16, grow: 0.5, life: 1, vx: Math.cos(k) * 380, vy: Math.sin(k) * 380 - 200, g: 600 });
    }
    this.ui.toast(`${this.t.morale} +1 · ★${this.morale}`, { icon: "★", gold: true, ms: 3000 });
    this.renderPad();
  }
  update(dt) {
    if (this.on && this.blocked) {
      // the fight or an ending: the deck closes and the captain goes back to the wheel
      this.mini?.close?.("closed");
      this.leave({ quiet: true });
    }
    if (!this.on) { this.linkNear = null; this.target = null; return; }
    const a = this.agent;
    if (!a) return;
    const k = (this.held.has("ArrowRight") ? 1 : 0) - (this.held.has("ArrowLeft") ? 1 : 0) || this.stick;
    if (a.manual) a.manual.vx = this.mini?.active ? 0 : k;
    this.linkNear = a.manual ? { up: !!this.world.crowd.linkAt(a, -1), down: !!this.world.crowd.linkAt(a, 1) } : null;
    this.target = this.interactTarget();
    this.renderPad();
  }
  // ---------------------------------------------------------------- on stage
  // the prompts over the stage: ▲▼ by the captain at a stair or ladder, E over a working hand
  draw(ctx, style) {
    if (!this.on || this.mini?.active) return;
    const W = this.world, cam = this.camera, red = style === "p5" ? "#e60012" : "#1a1410";
    const bubble = (x, y, text, key) => {
      ctx.save();
      ctx.font = "800 16px 'Barlow Semi Condensed', 'Noto Sans TC', 'Noto Sans SC', system-ui, sans-serif";
      const w = ctx.measureText(text).width + (key ? 40 : 18), h = 30;
      ctx.translate(x, y);
      if (style === "p5") ctx.rotate(-0.04);
      ctx.fillStyle = "#0c0608";
      ctx.fillRect(-w / 2 - 3, -h - 3, w + 6, h + 6);
      ctx.fillStyle = "#fff";
      ctx.fillRect(-w / 2, -h, w, h);
      if (key) {
        ctx.fillStyle = red;
        ctx.fillRect(-w / 2 + 4, -h + 4, 24, h - 8);
        ctx.fillStyle = "#fff";
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillText(key, -w / 2 + 16, -h / 2);
      }
      ctx.fillStyle = "#0c0608";
      ctx.textAlign = "left";
      ctx.textBaseline = "middle";
      ctx.fillText(text, -w / 2 + (key ? 34 : 9), -h / 2);
      ctx.restore();
    };
    const c = this.captain;
    if (c && this.linkNear && (this.linkNear.up || this.linkNear.down)) {
      const [x, y] = cam.toScreen(...W.at(c, "head", 0, -60));
      bubble(x, y - 14, [this.linkNear.up ? "▲ " + this.t.up : "", this.linkNear.down ? "▼ " + this.t.down : ""].filter(Boolean).join("  "), "");
    }
    if (this.target) {
      const p = W.crew[this.target.id];
      if (p) {
        const [x, y] = cam.toScreen(...W.at(p, "head", 0, -80));
        bubble(x, y - 8, this.t.act[this.target.kind], "E");
      }
    }
  }
  // ---------------------------------------------------------------- the phone pad
  buildPad() {
    const css = document.createElement("style");
    css.textContent = `
      #helmPad { position: fixed; inset: auto 0 calc(62px + var(--safe-b, 0px)) 0; height: 0; z-index: 6; pointer-events: none; }
      #helmPad[hidden] { display: none; }
      #helmPad .stick { position: absolute; left: calc(18px + var(--safe-l, 0px)); bottom: 0; width: 124px; height: 124px; border-radius: 50%; background: rgba(12,6,8,.45); border: 4px solid #fff; pointer-events: auto; touch-action: none; }
      #helmPad .stick i { position: absolute; left: 50%; top: 50%; width: 54px; height: 54px; margin: -27px 0 0 -27px; border-radius: 50%; background: #fff; border: 4px solid #0c0608; transition: transform .06s; }
      #helmPad .btns { position: absolute; right: calc(18px + var(--safe-r, 0px)); bottom: 0; display: flex; flex-direction: column; gap: 10px; align-items: flex-end; pointer-events: auto; }
      #helmPad button { min-width: 56px; min-height: 52px; font-size: 20px; background: #fff; color: #0c0608; border: 4px solid #0c0608; box-shadow: 4px 4px 0 #0c0608; }
      #helmPad button.act { background: var(--red, #e60012); color: #fff; }
      #helmPad button[hidden] { display: none; }
      #helmHint { position: fixed; left: 50%; bottom: calc(18px + var(--safe-b, 0px)); transform: translateX(-50%) rotate(-1.5deg); z-index: 6; background: #0c0608; color: #fff; padding: 6px 14px; font-size: 15px; white-space: nowrap; pointer-events: none; }
      #helmHint b { color: var(--gold, #f2c040); margin-left: 10px; }
      #helmHint[hidden] { display: none; }
      body.helm #prompt { display: none !important; }
      body[data-style="manga"] #helmPad button { border-radius: 14px; box-shadow: 0 0 0 3px #0c0608; border: 0; }
      body[data-style="manga"] #helmPad button.act { background: #0c0608; }
      body[data-style="manga"] #helmHint { background: #fff; color: #0c0608; border-radius: 12px; box-shadow: 0 0 0 3px #0c0608; }
      @media (max-width: 720px) { #helmHint { font-size: 12px; bottom: auto; top: calc(172px + var(--safe-t, 0px)); max-width: 94vw; white-space: normal; text-align: center; } }
    `;
    document.head.appendChild(css);
    const pad = (this.pad = document.createElement("div"));
    pad.id = "helmPad";
    pad.hidden = true;
    pad.innerHTML = `<div class="stick" aria-label="Walk"><i></i></div><div class="btns"><button data-h="up" hidden>▲</button><button data-h="down" hidden>▼</button><button data-h="act" class="act" hidden>E</button><button data-h="leave">✕</button></div>`;
    document.body.appendChild(pad);
    const hint = (this.hint = document.createElement("div"));
    hint.id = "helmHint";
    hint.hidden = true;
    document.body.appendChild(hint);
    const stick = pad.querySelector(".stick"), knob = stick.querySelector("i");
    let id = null;
    const move = (e) => {
      const r = stick.getBoundingClientRect(), dx = e.clientX - (r.left + r.width / 2), dy = e.clientY - (r.top + r.height / 2);
      const k = Math.max(-1, Math.min(1, dx / (r.width / 2)));
      this.stick = Math.abs(k) < 0.2 ? 0 : k;
      knob.style.transform = `translate(${k * 34}px, ${Math.max(-1, Math.min(1, dy / (r.height / 2))) * 34}px)`;
    };
    stick.addEventListener("pointerdown", (e) => { e.preventDefault(); id = e.pointerId; stick.setPointerCapture(id); move(e); });
    stick.addEventListener("pointermove", (e) => e.pointerId === id && move(e));
    const up = (e) => { if (e.pointerId !== id) return; id = null; this.stick = 0; knob.style.transform = ""; };
    stick.addEventListener("pointerup", up);
    stick.addEventListener("pointercancel", up);
    pad.querySelector(".btns").addEventListener("pointerdown", (e) => {
      const b = e.target.closest("[data-h]");
      if (!b) return;
      e.preventDefault();
      e.stopPropagation();
      const h = b.dataset.h;
      if (h === "up") this.climb(-1);
      else if (h === "down") this.climb(1);
      else if (h === "act") this.interact();
      else if (h === "leave") this.leave();
    });
  }
  get touch() { return matchMedia("(pointer: coarse)").matches || innerWidth < 720 || new URLSearchParams(location.search).get("touch") === "1"; }
  renderPad() {
    const show = this.on && !this.mini?.active;
    const touch = this.touch;
    this.pad.hidden = !(show && touch);
    this.hint.hidden = !show;
    if (!show) return;
    const key = [this.ui.lang, this.mode, this.morale, !!this.linkNear?.up, !!this.linkNear?.down, this.target?.kind || "", touch].join("|");
    if (this._key === key) return;
    this._key = key;
    this.hint.innerHTML = `${this.mode === "playground" ? this.t.hint : this.t.hintLive}${this.morale && this.mode === "playground" ? `<b>★ ${this.t.morale} ${this.morale}</b>` : ""}`;
    const q = (h) => this.pad.querySelector(`[data-h="${h}"]`);
    q("up").hidden = !this.linkNear?.up;
    q("down").hidden = !this.linkNear?.down;
    q("act").hidden = !this.target;
    q("act").textContent = this.target ? "E · " + this.t.act[this.target.kind] : "E";
    q("leave").textContent = "✕ " + this.t.leave;
  }
  // the Settings row: the keys, and a button to take the deck
  settingsRow(row, esc) {
    const t = this.t;
    return row(t.take, `<button data-set="helm" aria-pressed="${this.on}">Q</button><small>${esc(t.keys)}</small>`);
  }
}
export { T as HELM_TEXT, Z_SCREEN };
