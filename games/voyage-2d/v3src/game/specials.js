// Special moves (p4: the captain, "the specials must look incredibly cool"). Each
// special plays one authored sequence, fighting-game-super style:
//
//   0.00  the world stops (hit-stop), the scene darkens to the actor, a charge glow
//   0.05  CUT-IN: a skewed banner slams in with speed lines, the actor's portrait
//         (rendered live from the game's own model) and the move's name
//   0.75  the banner tears out; release: the move's own projectiles and trails
//   hit   IMPACT FRAME: one inverted frame, one white frame, focus lines on the hit,
//         shockwave rings, a heavy hit-stop and shake, a motion-blur smear, debris
//         and a water eruption, the damage number punched on screen, a camera punch-in
//   +0.6  aftermath: smoke, steam, embers settle, the light comes back
//
// The finisher adds slow motion and a dutch angle. The kraken's ultimate is the
// reverse: its cut-in, the sky going dark and the whole kraken rearing (the wind-up
// the player must read), then the counter window.
//
// Timing data (MOVES) is plain data so tests can check every move is authored.
import * as THREE from "three";

export const MOVES = Object.freeze({
  order: { name: "CAPTAIN'S ORDER", sub: "Every gun, fire as she bears!", actor: "captain", colour: ["#c8282a", "#ffcf4a"], hold: 0.7, dmgColour: "#ffcf4a" },
  broadside: { name: "PERFECT BROADSIDE", sub: "Brass on the mark", actor: "captain", colour: ["#1d2648", "#f1b43c"], hold: 0.62, dmgColour: "#ffe28a" },
  harpoon: { name: "FULL-DRAW HARPOON", sub: "Everything on one line", actor: "worker-1", colour: ["#0e5f7a", "#8fe6ff"], hold: 0.62, dmgColour: "#b6f2ff" },
  chain: { name: "CHAIN-SHOT", sub: "Bind the arms", actor: "worker-2", colour: ["#3a3f4a", "#d7dde8"], hold: 0.58, dmgColour: "#e6ecf5" },
  crit: { name: "WEAK POINT!", sub: "Counter on the eye", actor: "reviewer-1", colour: ["#14602e", "#7cf29a"], hold: 0.55, dmgColour: "#9dff9d" },
  finisher: { name: "FINISHER: MERGE STRIKE", sub: "Approved. All hands!", actor: "captain", colour: ["#6a0f10", "#ffd76a"], hold: 0.95, dmgColour: "#ffffff", slowmo: true, dutch: 14 },
  ultimate: { name: "ABYSS SLAM", sub: "The kraken rises. Read it!", actor: "kraken", colour: ["#2a0f4a", "#c77dff"], hold: 1.0, dmgColour: "#ff5a5a", enemy: true },
});

const CSS = `
#sp-root{position:fixed;inset:0;pointer-events:none;z-index:40;overflow:hidden}
#sp-dark{position:absolute;inset:0;background:radial-gradient(ellipse at var(--fx,50%) var(--fy,50%),rgba(0,0,0,0) 0,rgba(6,4,18,.55) 38%,rgba(4,2,12,.88) 100%);opacity:0;transition:opacity .12s}
#sp-cut{position:absolute;left:-12%;right:-12%;top:31%;height:34%;transform:skewY(-7deg) translateX(120%);opacity:0}
#sp-cut.in{animation:spIn .11s cubic-bezier(.2,.9,.3,1.2) forwards}
#sp-cut.out{animation:spOut .16s cubic-bezier(.6,0,.9,.4) forwards}
@keyframes spIn{0%{transform:skewY(-7deg) translateX(120%);opacity:1}100%{transform:skewY(-7deg) translateX(0);opacity:1}}
@keyframes spOut{0%{transform:skewY(-7deg) translateX(0);opacity:1}100%{transform:skewY(-7deg) translateX(-130%);opacity:1}}
#sp-cut .band{position:absolute;inset:0;background:linear-gradient(90deg,var(--c0) 0%,var(--c0) 55%,var(--c1) 100%);box-shadow:0 0 0 6px #000,0 0 0 10px var(--c1),0 18px 50px rgba(0,0,0,.7)}
#sp-cut .lines{position:absolute;inset:0;background:repeating-linear-gradient(90deg,rgba(255,255,255,.0) 0 22px,rgba(255,255,255,.22) 22px 26px,rgba(255,255,255,0) 26px 70px),repeating-linear-gradient(90deg,rgba(0,0,0,0) 0 9px,rgba(0,0,0,.18) 9px 11px);background-size:180px 100%,60px 100%;animation:spLines .18s linear infinite;mix-blend-mode:screen}
@keyframes spLines{from{background-position:0 0,0 0}to{background-position:-180px 0,-60px 0}}
#sp-cut .por{position:absolute;left:14%;top:-18%;height:136%;aspect-ratio:1;object-fit:cover;transform:skewY(7deg);filter:drop-shadow(8px 0 0 #000) drop-shadow(-4px 0 0 var(--c1));-webkit-mask-image:linear-gradient(90deg,transparent 0,#000 18%,#000 82%,transparent 100%);mask-image:linear-gradient(90deg,transparent 0,#000 18%,#000 82%,transparent 100%)}
#sp-cut .txt{position:absolute;left:47%;right:12%;top:50%;transform:translateY(-50%) skewY(7deg) skewX(-10deg);font-family:'Barlow Semi Condensed','Nunito',system-ui,sans-serif;text-transform:uppercase}
#sp-cut .who{font-weight:800;font-size:clamp(14px,2.4vw,26px);letter-spacing:.3em;color:var(--c1);text-shadow:2px 2px 0 #000}
#sp-cut .move{font-weight:900;font-style:italic;font-size:clamp(30px,7.2vw,96px);line-height:.92;color:#fff;-webkit-text-stroke:3px #000;paint-order:stroke fill;text-shadow:6px 6px 0 #000,0 0 30px var(--c1)}
#sp-cut .sub{font-weight:700;font-size:clamp(12px,2vw,22px);color:#fff;text-shadow:2px 2px 0 #000;margin-top:.3em;letter-spacing:.06em}
#sp-focus{position:absolute;inset:-20%;opacity:0;background:repeating-conic-gradient(from 0deg at var(--fx,50%) var(--fy,50%),rgba(255,255,255,0) 0deg 2.2deg,rgba(255,255,255,.55) 2.2deg 2.6deg,rgba(255,255,255,0) 2.6deg 7deg);-webkit-mask-image:radial-gradient(circle at var(--fx,50%) var(--fy,50%),transparent 0 16%,#000 42%);mask-image:radial-gradient(circle at var(--fx,50%) var(--fy,50%),transparent 0 16%,#000 42%)}
#sp-imp{position:absolute;inset:0;opacity:0;background:#fff}
#sp-imp.inv{opacity:1;background:#fff;mix-blend-mode:difference}
#sp-imp.white{opacity:1;background:#fff;mix-blend-mode:normal}
.sp-dmg{position:absolute;font-family:'Barlow Semi Condensed','Nunito',system-ui,sans-serif;font-weight:900;font-style:italic;color:var(--c,#fff);-webkit-text-stroke:3px #000;paint-order:stroke fill;text-shadow:5px 5px 0 #000;transform:translate(-50%,-50%) scale(2.4);opacity:0;animation:spDmg 1.15s cubic-bezier(.2,1.4,.4,1) forwards;white-space:nowrap}
.sp-dmg small{display:block;font-size:.34em;letter-spacing:.2em;text-align:center}
@keyframes spDmg{0%{opacity:1;transform:translate(-50%,-50%) scale(2.6) rotate(-8deg)}14%{opacity:1;transform:translate(-50%,-50%) scale(.9) rotate(-4deg)}22%{transform:translate(-50%,-50%) scale(1.08) rotate(-4deg)}75%{opacity:1;transform:translate(-50%,-80%) scale(1) rotate(-4deg)}100%{opacity:0;transform:translate(-50%,-110%) scale(1) rotate(-4deg)}}
#sp-tele{position:absolute;left:0;right:0;top:12%;text-align:center;font-family:'Barlow Semi Condensed','Nunito',system-ui,sans-serif;font-weight:900;font-style:italic;font-size:clamp(22px,4.4vw,54px);color:#ff6a6a;-webkit-text-stroke:2px #000;paint-order:stroke fill;text-shadow:4px 4px 0 #000,0 0 24px #c77dff;opacity:0;letter-spacing:.08em}
#sp-tele.on{animation:spTele .5s ease-in-out infinite alternate}
@keyframes spTele{from{opacity:.55;transform:scale(1)}to{opacity:1;transform:scale(1.06)}}
body.sp-blur canvas#c{filter:blur(2.5px) contrast(1.15) saturate(1.2)}
body.sp-hot canvas#c{filter:contrast(1.3) saturate(1.35) brightness(1.08)}
`;

export class Specials {
  constructor({ world, fx, sound, director, renderer, camera }) {
    Object.assign(this, { world, fx, sound, director, renderer, camera });
    this.portraits = new Map();
    this.timers = [];
    this.busy = 0;
    const st = document.createElement("style");
    st.textContent = CSS;
    document.head.appendChild(st);
    const root = document.createElement("div");
    root.id = "sp-root";
    root.innerHTML = `<div id="sp-dark"></div><div id="sp-focus"></div><div id="sp-cut"><div class="band"></div><div class="lines"></div><img class="por" alt=""><div class="txt"><div class="who"></div><div class="move"></div><div class="sub"></div></div></div><div id="sp-tele"></div><div id="sp-imp"></div>`;
    document.body.appendChild(root);
    this.el = (id) => document.getElementById(id);
    this.root = root;
  }
  after(s, fn) {
    this.timers.push({ at: performance.now() / 1000 + s, fn });
  }
  update() {
    const now = performance.now() / 1000;
    for (let i = this.timers.length - 1; i >= 0; i--)
      if (now >= this.timers[i].at) {
        const f = this.timers[i].fn;
        this.timers.splice(i, 1);
        f();
      }
  }
  // ---------------------------------------------------------------- portrait
  // the actor's head, rendered from the live model onto a transparent square: a
  // three-quarter hero angle, a little from below, with a hard rim light
  portrait(id) {
    if (this.portraits.has(id)) return this.portraits.get(id);
    const R = this.renderer, W = this.world;
    const target = id === "kraken" ? W.kraken?.rig.head : W.crew[id]?.rig.head;
    if (!target) return "";
    const LAYER = 7;
    const holder = id === "kraken" ? W.kraken.group : W.crew[id].group;
    const tagged = [];
    holder.traverse((o) => {
      if (o.isMesh || o.isSkinnedMesh || o.isSprite === false) {
        o.layers.enable(LAYER);
        tagged.push(o);
      }
    });
    const lights = [];
    W.scene.traverse((o) => o.isLight && (o.layers.enable(LAYER), lights.push(o)));
    const rim = new THREE.DirectionalLight(0xffe0b0, 3.2);
    const key = new THREE.DirectionalLight(0xffffff, 1.2);
    rim.layers.set(LAYER);
    key.layers.set(LAYER);
    W.scene.add(rim, key, rim.target, key.target);
    holder.updateMatrixWorld(true);
    const head = target.getWorldPosition(new THREE.Vector3());
    const up = id === "kraken" ? 4.5 : 0.28 * (W.crew[id].scale || 1.5);
    head.y += up;
    const fwd = new THREE.Vector3(0, 0, 1).applyQuaternion(holder.getWorldQuaternion(new THREE.Quaternion()));
    const side = new THREE.Vector3(fwd.z, 0, -fwd.x);
    const dist = id === "kraken" ? 26 : 2.1 * (W.crew[id].scale || 1.5);
    const cam = new THREE.PerspectiveCamera(28, 1, 0.05, 200);
    cam.position.copy(head).addScaledVector(fwd, dist).addScaledVector(side, dist * 0.42).add(new THREE.Vector3(0, -dist * 0.12, 0));
    cam.lookAt(head);
    cam.layers.set(LAYER);
    rim.position.copy(head).addScaledVector(fwd, -5).addScaledVector(side, -6).add(new THREE.Vector3(0, 4, 0));
    rim.target.position.copy(head);
    key.position.copy(cam.position).add(new THREE.Vector3(0, 3, 0));
    key.target.position.copy(head);
    const S = 320;
    const rt = new THREE.WebGLRenderTarget(S, S);
    const bg = W.scene.background, fog = W.scene.fog;
    W.scene.background = null;
    W.scene.fog = null;
    const clear = R.getClearAlpha();
    R.setClearAlpha(0);
    R.setRenderTarget(rt);
    R.clear();
    R.render(W.scene, cam);
    const px = new Uint8Array(S * S * 4);
    R.readRenderTargetPixels(rt, 0, 0, S, S, px);
    R.setRenderTarget(null);
    R.setClearAlpha(clear);
    W.scene.background = bg;
    W.scene.fog = fog;
    W.scene.remove(rim, key, rim.target, key.target);
    for (const o of tagged) o.layers.disable(LAYER);
    for (const l of lights) l.layers.disable(LAYER);
    rt.dispose();
    const c = document.createElement("canvas");
    c.width = c.height = S;
    const x = c.getContext("2d");
    const im = x.createImageData(S, S);
    for (let y = 0; y < S; y++) im.data.set(px.subarray((S - 1 - y) * S * 4, (S - y) * S * 4), y * S * 4);
    x.putImageData(im, 0, 0);
    const url = c.toDataURL("image/png");
    this.portraits.set(id, url);
    return url;
  }
  // ---------------------------------------------------------------- pieces
  screen(v) {
    const p = v.clone().project(this.camera);
    return { x: (p.x * 0.5 + 0.5) * innerWidth, y: (-p.y * 0.5 + 0.5) * innerHeight };
  }
  focusAt(v) {
    const s = v ? this.screen(v) : { x: innerWidth / 2, y: innerHeight / 2 };
    this.root.style.setProperty("--fx", ((s.x / innerWidth) * 100).toFixed(1) + "%");
    this.root.style.setProperty("--fy", ((s.y / innerHeight) * 100).toFixed(1) + "%");
  }
  cutIn(kind) {
    const M = MOVES[kind];
    const cut = this.el("sp-cut");
    cut.style.setProperty("--c0", M.colour[0]);
    cut.style.setProperty("--c1", M.colour[1]);
    cut.querySelector(".por").src = this.portrait(M.actor) || "";
    cut.querySelector(".who").textContent = M.actor === "kraken" ? "THE KRAKEN" : M.actor === "captain" ? "THE CAPTAIN" : this.world.crew[M.actor]?.id?.toUpperCase().replace("-", " ") || "";
    cut.querySelector(".move").textContent = M.name;
    cut.querySelector(".sub").textContent = M.sub;
    cut.classList.remove("out");
    void cut.offsetWidth;
    cut.classList.add("in");
    this.sound.play("cutin");
    this.after(M.hold, () => {
      cut.classList.remove("in");
      cut.classList.add("out");
      this.after(0.2, () => cut.classList.remove("out"));
    });
  }
  dark(on, at) {
    if (at) this.focusAt(at);
    this.el("sp-dark").style.opacity = on ? 1 : 0;
  }
  // the impact frame: inverted, white, then the focus lines hold for a beat
  impactFrame(at, { heavy = false } = {}) {
    this.focusAt(at);
    const imp = this.el("sp-imp"), foc = this.el("sp-focus");
    imp.className = "inv";
    document.body.classList.add("sp-hot");
    this.after(0.034, () => (imp.className = "white"));
    this.after(0.068, () => (imp.className = heavy ? "inv" : ""));
    this.after(heavy ? 0.1 : 0.07, () => {
      imp.className = "";
      document.body.classList.add("sp-blur");
    });
    this.after(0.2, () => document.body.classList.remove("sp-blur"));
    foc.style.transition = "none";
    foc.style.opacity = 1;
    this.after(0.35, () => {
      foc.style.transition = "opacity .35s";
      foc.style.opacity = 0;
      document.body.classList.remove("sp-hot");
    });
  }
  damage(at, value, colour, label = "") {
    const s = this.screen(at);
    const d = document.createElement("div");
    d.className = "sp-dmg";
    d.style.left = s.x + "px";
    d.style.top = s.y - innerHeight * 0.08 + "px";
    d.style.fontSize = Math.min(150, 46 + value * 11) + "px";
    d.style.setProperty("--c", colour);
    d.innerHTML = `${Math.round(value * 100)}${label ? `<small>${label}</small>` : ""}`;
    this.root.appendChild(d);
    this.after(1.3, () => d.remove());
  }
  // shockwave, eruption, debris, embers and smoke at a hit, scaled by weight
  eruption(at, w) {
    const fx = this.fx;
    for (let k = 0; k < 3; k++) fx.ring(at, { radius: 4 + w * 2.2 + k * 3, life: 0.45 + k * 0.14, width: 0.3, delay: k * 0.05, color: k ? 0xffd9a0 : 0xffffff });
    fx.sprite("flash", at, { scale: 5 + w * 1.4, grow: 2.2, life: 0.22 });
    fx.sprite("fire", at, { scale: 3 + w, grow: 2.6, life: 0.55, rise: 1.2 });
    const sea = at.clone();
    sea.y = 0.2;
    fx.waterColumn(sea, 2 + w * 0.6, 1.4 + w * 0.2);
    for (let i = 0; i < 18 + w * 4; i++) {
      const a = fx.seeded(i + 90) * Math.PI * 2, sp = 5 + fx.seeded(i + 91) * 7;
      fx.chip(at, new THREE.Vector3(Math.cos(a) * sp, 4 + fx.seeded(i + 92) * 8, Math.sin(a) * sp), { color: i % 3 ? 0x4b2a5e : 0xbfa0ff, size: 0.25 + fx.seeded(i) * 0.35, life: 1.5 });
    }
    for (let i = 0; i < 4; i++) fx.sprite("smoke", at.clone().add(new THREE.Vector3((fx.seeded(i + 7) - 0.5) * 3, 1, (fx.seeded(i + 8) - 0.5) * 3)), { scale: 3 + w * 0.5, grow: 2.2, life: 2.2, rise: 2.5, add: false, delay: 0.25 + i * 0.08 });
  }
  // ---------------------------------------------------------------- the sequence
  // run(kind, { source: world pos of the move's origin, target: world pos of the hit,
  //             weight, onRelease: () => fire the projectiles, landsIn: seconds })
  run(kind, { source = null, target = null, weight = 3, onRelease = null, landsIn = 0.45 } = {}) {
    const M = MOVES[kind];
    if (!M) return;
    const fx = this.fx, D = this.director;
    this.busy++;
    // stop the world; darken to the actor; charge glow at the source
    fx.hitstop = Math.max(fx.hitstop, M.hold + 0.1);
    this.dark(true, source || target);
    if (source) {
      fx.sprite("glow", source, { scale: 4, grow: 0.3, life: M.hold + 0.2, color: 0xffe2a0 });
      for (let i = 0; i < 16; i++) {
        const a = (i / 16) * Math.PI * 2;
        const from = source.clone().add(new THREE.Vector3(Math.cos(a) * 3, 1 + fx.seeded(i) * 2, Math.sin(a) * 3));
        fx.sprite("spark", from, { scale: 0.45, life: M.hold, vel: source.clone().sub(from).multiplyScalar(1 / M.hold), color: 0xfff0b0 });
      }
    }
    this.sound.play(M.enemy ? "ultimateHorn" : "charge");
    D.punch?.(0.82, M.hold + 0.3);
    this.cutIn(kind);
    // release
    this.after(M.hold + 0.08, () => {
      this.dark(false);
      onRelease?.();
      if (!target) return (this.busy = Math.max(0, this.busy - 1));
      this.after(landsIn, () => {
        this.impactFrame(target, { heavy: weight >= 5 });
        fx.hitstop = Math.max(fx.hitstop, 0.09 + weight * 0.02);
        fx.shake(Math.min(1, 0.45 + weight * 0.1));
        this.eruption(target, weight);
        this.sound.play("impact");
        this.damage(target, weight, M.dmgColour, M.name.split(":")[0]);
        D.punch?.(0.72, 0.5);
        if (M.slowmo) {
          fx.timeScale = 0.22;
          D.dutch?.(M.dutch || 12, 2.2);
          this.after(1.6, () => (fx.timeScale = 1));
        }
        this.after(0.6, () => (this.busy = Math.max(0, this.busy - 1)));
      });
    });
  }
  // the kraken's ultimate: its cut-in, the telegraph banner while the bar fills
  ultimate(bar, head) {
    this.run("ultimate", { source: head, target: null });
    const t = this.el("sp-tele");
    t.textContent = "ABYSS SLAM! FULL SAIL ON THE BRASS!";
    t.classList.add("on");
    this.world.setStorm(1);
    this.world.breakLight(0.3, 0);
    this.after(bar, () => t.classList.remove("on"));
  }
}
