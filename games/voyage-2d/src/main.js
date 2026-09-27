// Firstmate Voyage v2.5: prototype v2's board and rituals on a 2D pirate stage, with
// v3's crew as 2.5D puppets. One Canvas2D, a frame budget, and a compositor that adds
// the feel: motion trails, a radial zoom blur on the big hits, impact frames, screen
// flashes, the vignette; then the cut-ins and the HUD on top.
import { createSim, step } from "../v3src/sim/sim.js";
import { HUD, projectOf, BOARD_ACTIONS } from "./hud.js";
import { BoardSource } from "./boardsource.js";
import { viewToSim, liveEmptySim } from "./live-adapter.js";
// Live boot: board/public/game.js loads this bundle in an iframe whose
// URL hash carries {base, token, project} - the same place T-122 own
// one-time login code travels, so it never reaches a server log or the
// top window history. Read once, then cleared, exactly as /login does it.
// Absent (no hash, or not valid JSON), the game is the Playground it has
// always been.
const LIVE = (() => {
  try {
    const h = location.hash.slice(1);
    if (!h) return null;
    const cfg = JSON.parse(decodeURIComponent(h));
    history.replaceState(null, "", location.pathname + location.search);
    return cfg && typeof cfg === "object" ? cfg : null;
  } catch { return null; }
})();
import { CLASSES } from "./ship.js";
import { CREW_FIXTURE } from "../v3src/sim/config.js";
import { loadImages, MOTION } from "./puppet.js";
// reduced motion: the crew still walk, with a smaller bob and no squash (?motion=reduce forces it)
try { MOTION.reduced = new URLSearchParams(location.search).get("motion") === "reduce" || matchMedia("(prefers-reduced-motion: reduce)").matches; } catch {}
import { World } from "./world.js";
import { Camera } from "./camera.js";
import { Director } from "./director.js";
import { BattleView } from "./battleview.js";
import { Overlay, drawImpact, drawHUD, FONT_JP } from "./overlay.js";
import { Sound2D } from "./audio2d.js";
import { nextSpecial } from "./battle2d.js";
import BAKE from "./bake-data.js";
import { Helm, HELM_KEY } from "./control.js";
import { MiniGames } from "./minigame.js";

const T0 = performance.now();
const Q = new URLSearchParams(location.search);
const $ = (id) => document.getElementById(id);

function autoDetail() {
  const touch = matchMedia("(pointer: coarse)").matches || navigator.maxTouchPoints > 1;
  const small = Math.min(screen.width, screen.height) < 600 || Math.min(innerWidth, innerHeight) < 500;
  const lowMem = navigator.deviceMemory && navigator.deviceMemory <= 4;
  return touch || small || lowMem || /Android|iPhone|iPad|Mobile/i.test(navigator.userAgent) ? "low" : "high";
}
const G = {
  seed: +(Q.get("seed") || 7),
  detail: Q.get("detail") === "low" || Q.get("detail") === "high" ? Q.get("detail") : autoDetail(),
  speed: +(Q.get("speed") || 1),
  demo: Q.get("demo") === "1",
  driver: Q.get("driver") !== "0", // tests: ?driver=0 holds the Playground's crew driver
  paused: false, ready: false, errors: [],
  frames: [], // recent frame costs (ms)
  heavy: [],
  style: "p5",
  menuPaused: false,
};
try {
  G.style = Q.get("style") || localStorage.getItem("v2d-style") || "p5";
} catch {
  G.style = Q.get("style") || "p5";
}
if (G.style !== "manga") G.style = "p5";
window.__G = G;
const rituals = { order: true, salvo: true, port: true, salute: true, clearing: true, weather: true, kraken: true };
const low = G.detail === "low";

const canvas = $("c");
const ctx = canvas.getContext("2d", { alpha: false });
const trail = document.createElement("canvas"); // the last frame, for motion trails
const tctx = trail.getContext("2d");
let W = 0, H = 0, DPR = 1;
function resize() {
  DPR = Math.min(devicePixelRatio || 1, Q.has("dpr") ? +Q.get("dpr") : low ? 1 : 1.5);
  W = innerWidth; H = innerHeight;
  canvas.width = Math.round(W * DPR); canvas.height = Math.round(H * DPR);
  trail.width = canvas.width; trail.height = canvas.height;
  camera?.resize(W, H);
  if (G.ready) ui.render(sim);
}

let sim = LIVE ? liveEmptySim(rituals) : createSim(G.seed);
const sound = new Sound2D();
let ui, world, camera, director, battle, overlay, helm, mini;

function showError(what, e) {
  console.warn("[voyage2d]", what, e);
  G.errors.push(`${what}: ${e?.message || e}`);
  ui?.error("Something could not be built: " + G.errors.join(" · "));
}
function apply(action) {
  const r = step(sim, action);
  sim = r.state;
  for (const e of r.events) handle(e);
  if (r.events.length) ui.render(sim);
  return r.events;
}
function handle(e) {
  try {
    if (e.type === "caption") return;
    ui.event(e, sim);
    director.handle(e, sim);
    battle.sync(sim);
    // "Proceed: fight" on the kraken's card starts the fight: no second tap on the kraken
    if (e.type === "battle_begin" && !battle.playing && !battle.ending) battle.play(true);
  } catch (err) {
    showError("event " + e.type, err);
  }
}

ui = new HUD({
  // the captain's two board actions: set work aside (park / drop, where the board allows it),
  // and answer a card by clicking it. In Playground both only change the simulated voyage.
  // docs/interface.md section 2: a card offers only what the boards own
  // tasks[].actions lists (park, unpark, drop); the board itself refuses
  // anything else, so forwarding any kind here invents no new write.
  cardAction: (kind, id) => { source.command({ type: kind, task: id }); },
  answer: (id, key) => source.command({ type: "answer", decision: id, chosen: key }),
  ritual: (name, on) => { rituals[name] = on; ui.setFlag("r-" + name, on); apply({ type: "ritual", name, on }); },
  sound: () => toggleSound(),
  camera: () => toggleCamera(),
  speed: () => { G.speed = G.speed >= 3 ? 1 : G.speed + 1; ui.setFlag("c-speed", false, G.speed + "×"); },
  detail: () => { const u = new URL(location.href); u.searchParams.set("detail", low ? "high" : "low"); location.replace(u.toString()); },
  style: () => styleToggle(),
  pause: (on) => { G.menuPaused = on; },
  play: (on) => battle.play(on),
  prompt: () => promptAct(),
  shipInfo: () => world?.cls,
  mode: () => MODE,
  hands: (v) => setHands(sim.crew.length + (+v || 0)),
  handsRange: () => (MODE === "playground" ? [MIN_CREW, MAX_CREW] : null),
  crewAt: (id) => crewAt(id),
  helm: () => helm?.toggle(),
  settingsExtra: (row, esc) => helm?.settingsRow(row, esc) || "",
});
ui.setFlag("c-detail", false, G.detail);
ui.setFlag("c-speed", false, G.speed + "×");
ui.setFlag("style", false, G.style);

// ---------------------------------------------------------------- the mode
// Two modes. Live (later, inside the board): the board's data, and the captain's answers go to
// POST /decisions. Playground (this standalone build): the simulated voyage, driven by the sim
// on its own. Playground has no network code at all: the build refuses fetch, XHR, WebSocket
// and sendBeacon, so nothing in it can ever reach the board.
const MODE = LIVE ? "live" : "playground";
// Live: BoardSource is the whole seam (docs/interface.md section 2). It
// reads GET /api/state and SSE /events and writes only POST /decisions and
// POST /tasks, with the tab own bearer token; nothing else ever leaves the
// page. Playground: the captain own commands only ever change the sim.
const source = LIVE
  ? new BoardSource({ base: LIVE.base || "", token: LIVE.token || "", project: LIVE.project || null,
      onError: (e) => showError("board connection", e) })
  : {
  mode: MODE,
  writes: 0,
  command(c) {
    source.writes++;
    if (c.type === "answer") return apply({ type: "answer", decision: c.decision, key: c.chosen });
    if (c.type === "park" || c.type === "drop") {
      const t = sim.tasks.find((x) => x.id === c.task);
      if (!t || !BOARD_ACTIONS[t.lane]?.includes(c.type)) return [];
      return apply({ type: c.type, task: c.task });
    }
    return [];
  },
};
// Live: BoardSource own snapshots and mapped events drive the same render
// pipeline apply() uses for a local action - viewToSim translates one
// /api/state view into the sim shape World, HUD, Director and BattleView
// already read, and each mapped event still goes through handle(), so every
// ritual keys off the same board event vocabulary either way.
let unsubscribeLive = null;
if (MODE === "live") {
  unsubscribeLive = source.subscribe((view, events) => {
    try {
      sim = viewToSim(view, sim);
      for (const e of events) handle(e);
      if (G.ready) ui.render(sim);
    } catch (e) { showError("live snapshot", e); }
  });
}

// ---------------------------------------------------------------- hands aboard
// The ship's class follows the crew: hire a hand past a class's cap and the ship grows (a
// shipyard moment); dismiss hands and she trims down. From 7 (a sloop) to 24 (a ship of the line).
const MIN_CREW = CREW_FIXTURE.length, MAX_CREW = CLASSES[CLASSES.length - 1].cap;
const SAILOR_MODELS = ["sailor-hammer", "sailor-bandana", "sailor-spyglass"];
function newHand(n) {
  return { id: `worker-${n}`, role: "worker", name: `worker-${n}`, model: SAILOR_MODELS[n % 3], vendor: ["claude · opus-5", "claude · sonnet-5", "cursor-agent · composer"][n % 3],
    state: "idle", task: null, station: null, action: null, standing: 0, merges: 0, firstPass: 0, approvals: 0, rank: 0, record: [], honours: [] };
}
function addHands(n) {
  const crew = sim.crew.slice();
  const added = [];
  for (let i = 0; i < n && crew.length < MAX_CREW; i++) {
    const k = Math.max(0, ...crew.filter((c) => c.role === "worker").map((c) => parseInt(c.id.split("-")[1], 10) || 0)) + 1;
    const h = newHand(k);
    crew.push(h);
    added.push(h.id);
  }
  sim = { ...sim, crew };
  return added;
}
function syncShip({ instant = false } = {}) {
  const want = world.syncCrew(sim.crew);
  if (want) instant ? (world.ship.setClass(want, 0), world.regroup(sim)) : director.transform(want, sim);
  else world.regroup(sim); // the same ship: everyone steps to his new spot, apart
  ui.render(sim);
}
function hire(n = 1) {
  if (!G.ready) return [];
  const added = addHands(n);
  for (const id of added.slice(-2)) ui.event({ type: "hired", crew: id }, sim);
  syncShip();
  return added;
}
function dismiss(n = 1) {
  if (!G.ready) return [];
  const gone = [];
  for (let i = 0; i < n && sim.crew.length > MIN_CREW; i++) {
    // the newest idle hand goes ashore; a hand at work stays until the work is done
    const w = sim.crew.filter((c) => c.role === "worker" && c.state === "idle" && !CREW_FIXTURE.some((f) => f.id === c.id)).pop();
    if (!w) break;
    sim = { ...sim, crew: sim.crew.filter((c) => c !== w) };
    gone.push(w.id);
  }
  for (const id of gone.slice(-2)) ui.event({ type: "dismissed", crew: id }, sim);
  syncShip();
  return gone;
}
// Playground only: the captain sets the crew size freely (Settings, "Hands aboard", and the
// + / - keys), from the fixture's 7 to the 24 a ship of the line carries. Once he has, the
// crew driver leaves the count to him. Live has no such control: the board's crew list rules.
function setHands(n) {
  if (MODE !== "playground" || !G.ready) return sim.crew.length;
  crewDriver.captain = true;
  n = Math.max(MIN_CREW, Math.min(MAX_CREW, Math.round(n)));
  if (n > sim.crew.length) hire(n - sim.crew.length);
  else if (n < sim.crew.length) dismiss(sim.crew.length - n);
  return sim.crew.length;
}

async function build() {
  ui.loading("Hoisting the sails…");
  // concept pass: ?crewstyle=manga inks and cel-shades the crew at load; a concept bake
  // (the bold proportions) can be handed in by the test tools as window.__CONCEPT_BAKE
  const bake = window.__CONCEPT_BAKE || BAKE;
  const images = await loadImages(bake, { manga: Q.get("crewstyle") === "manga" ? { outline: 5 } : null });
  if (Q.has("crew")) addHands(Math.max(0, Math.min(MAX_CREW, +Q.get("crew")) - sim.crew.length));
  world = new World({ bake, images, low, crewCount: sim.crew.length });
  world.syncCrew(sim.crew);
  world.projectCol = (id) => projectOf(sim.crew.find((c) => c.id === id), sim)?.col || null;
  for (const p of Object.values(world.crew)) (p.alpha = 1), (p.arriving = false);
  camera = new Camera();
  overlay = new Overlay();
  overlay.style = G.style;
  overlay.low = low;
  document.body.dataset.style = G.style;
  resize();
  director = new Director({ world, camera, sound, ui, overlay, getSim: () => sim, rituals });
  battle = new BattleView({ world, camera, sound, ui, overlay, director, apply, getSim: () => sim });
  world.behindHook = (c) => battle.wave > 0.01 && battle.wave < 0.8 && battle.drawWave(c);
  director.onRealStrike = (e) => battle.realStrike(e);
  // the captain may take the deck (cosmetic; never writes), and lend a hand (Playground only)
  mini = new MiniGames({ ui, world, mode: () => ui.h.mode?.() || MODE, onWin: (k, id) => helm.won(k, id) });
  helm = new Helm({ world, camera, director, ui, battle, mini, canvas });
  world.control = helm;
  director.onBattlePush = () => battle.realPush();
  camera.go(director.frames().wide(), { cut: true });
  ui.render(sim);
  battle.sync(sim);
  if (!Q.get("scene")) (ui.toast(ui.t.welcome, { icon: "⚓", ms: 7000 }), (G.welcome = true));
  else stage(Q.get("scene"));
  ui.loading("");
  G.ready = true;
  G.readyMs = Math.round(performance.now() - T0);
}

// staged states for tests and screenshots (v3's list, plus the battle's set pieces)
function stage(name) {
  if (G.welcome) (G.welcome = false), ui.dismissCaption();
  const tick = (sec) => { for (let i = 0; i < sec * 10; i++) apply({ type: "tick", dt: 0.1 }); };
  if (name === "order") apply({ type: "dispatch" });
  if (["work", "review", "squall", "merge", "decision"].includes(name)) (apply({ type: "dispatch" }), apply({ type: "dispatch" }), apply({ type: "dispatch" }), tick(4));
  if (name === "review") apply({ type: "openPR" });
  if (name === "squall") apply({ type: "redCheck" });
  if (name === "merge") { const t = sim.tasks.find((x) => x.lane === "working"); apply({ type: "approve", task: t.id }); apply({ type: "merge" }); }
  if (name === "decision") { const t = sim.tasks.find((x) => x.lane === "working"); apply({ type: "approve", task: t.id }); }
  if (name === "port") for (const id of sim.milestones[0].tasks) (apply({ type: "dispatch", task: id }), apply({ type: "approve", task: id }), apply({ type: "merge" }));
  if (["kraken", "battle", "ultimate", "finisher", "victory"].includes(name)) {
    apply({ type: "dispatch" });
    apply({ type: "dispatch" });
    const ids = sim.tasks.filter((x) => x.lane === "working").map((x) => x.id);
    for (const id of ids) for (let i = 0; i < 3; i++) apply({ type: "reject", task: id });
    world.kraken.rise = 1;
    if (name !== "kraken") {
      const d = sim.decisions.find((x) => x.kind === "kraken");
      if (d) apply({ type: "answer", decision: d.id, key: "A" });
      if (!battle.playing) battle.play(true);
      if (Q.has("grip")) battle.b.grip = +Q.get("grip"); // tests: start a fight part-way
      if (name === "ultimate") (battle.b.pendingUlt = true), (battle.b.next = 99);
      if (name === "finisher" || name === "victory") {
        battle.b.gauge = 100;
        battle.b.grip = 4;
        battle.step({ type: "harpoon" });
      }
      if (name === "victory") battle.finish();
    }
  }
  camera.go(director.frames()[director.defaultShot()](), { cut: true });
  return { state: name };
}

function toggleSound(force) {
  sound.enable(force ?? !sound.on);
  ui.setFlag("b-sound", sound.on);
  ui.setFlag("c-sound", sound.on, sound.on ? "On" : "Off");
}
function toggleCamera(force) {
  const free = force ?? director.cinematic;
  director.cinematic = !free;
  ui.setFlag("b-cam", free);
  ui.setFlag("c-cine", !free, free ? "Off" : "On");
  if (free) camera.go(director.frames().wide());
}
// The keys, in order of precedence:
//   1. Esc closes what is open, the innermost first: the menu, the crew card, a mini-game,
//      the decision card (folded away), then the captain's walk (back to the helm).
//   2. The fight's keys, in the fight.
//   3. A mini-game's keys while it is open (Space, E, the arrows).
//   4. The decision card's keys while it is on screen: A–D and Enter answer it, so they win over
//      the captain's walk (A and D walk only while no card is up).
//   5. The captain's walk: ← → A D, ↑ ↓ W S, E, and Q to take or leave the deck. While he has
//      the deck, S walks (sound stays in Settings).
//   6. The rest: B L T K menus, S sound, C camera, X HUD, + = - hands aboard.
addEventListener("keydown", (e) => {
  if (!G.ready || e.metaKey || e.ctrlKey || e.altKey) return;
  if (e.target.closest?.("input, textarea")) return;
  const k = e.key;
  if (e.repeat) return helm?.on && /^(Arrow(Left|Right)|[adAD])$/.test(k) && !(sim.decisions.length && ui.decisionShown && /^[adAD]$/.test(k)) ? e.preventDefault() : undefined;
  if (ui.menuOpen && k === "Escape") return ui.toggle(null);
  if (ui.crewId && k === "Escape") return (ui.crewPinned = false), ui.hideCrew();
  if (battle.key(k, true)) return e.preventDefault();
  if (mini.active && mini.key(k, true)) return e.preventDefault();
  if (sim.decisions.length && ui.decisionShown && /^[a-dA-D]$/.test(k)) return ui.choose(k.toUpperCase());
  if (sim.decisions.length && ui.decisionShown && k === "Enter") return ui.confirm();
  if (k === "Escape" && sim.decisions.length && ui.decisionShown && !ui.minimised) return ui.minimise();
  if (helm.on && k === "Escape") return helm.leave();
  if (k.toLowerCase() === HELM_KEY && !battle.playing && !battle.ending) return helm.toggle(), e.preventDefault();
  if (helm.on && helm.keyDown(k)) return e.preventDefault();
  if (MODE === "playground" && !battle.playing && !battle.ending && (k === "+" || k === "=" || k === "-")) return setHands(sim.crew.length + (k === "-" ? -1 : 1));
  const K = k.toLowerCase();
  if (K === "b") ui.toggle("board");
  else if (K === "l") ui.toggle("roster");
  else if (K === "t") ui.toggle("chart");
  else if (K === "k") ui.toggle("settings");
  else if (K === "s") toggleSound();
  else if (K === "c") toggleCamera();
  else if (K === "x") document.body.classList.toggle("nohud");
  else if (k === "Escape") sim.decisions.length ? ui.minimise() : ui.toggle("board");
});
addEventListener("keyup", (e) => {
  if (!G.ready) return;
  helm?.keyUp(e.key);
  if (mini?.active) mini.key(e.key, false);
});
addEventListener("blur", () => helm?.held.clear());
// The boss key (T-125): Esc twice within about 400 ms, from anywhere,
// on the second keydown, before the next frame. A capture-phase listener
// of its own, so a single Esc keeps every meaning it already has (closing
// a menu, a card, a mini-game) and a text field or the decision card own
// keys are never swallowed - this only ever adds a teardown, and never
// calls preventDefault or stopPropagation.
let lastEscAt = -1;
const BOSS_KEY_WINDOW_MS = 400;
function bossKeyTeardown() {
  cancelAnimationFrame(rafId);
  sound.enable(false);
  if (unsubscribeLive) { try { unsubscribeLive(); } catch { /* already gone */ } unsubscribeLive = null; }
  G.ready = false;
  if (window.__voyage2d) window.__voyage2d.bossKeyFired = true;
  try { if (window.parent && window.parent !== window) window.parent.postMessage({ type: "voyage2d:boss-key" }, location.origin); } catch { /* not embedded, or a foreign parent */ }
  dispatchEvent(new CustomEvent("voyage2d:boss-key"));
}
addEventListener("keydown", (e) => {
  if (e.key !== "Escape" || e.metaKey || e.ctrlKey || e.altKey) return;
  const now = performance.now();
  if (now - lastEscAt < BOSS_KEY_WINDOW_MS) { lastEscAt = -1; bossKeyTeardown(); }
  else lastEscAt = now;
}, { capture: true });
// ---------------------------------------------------------------- click / tap first
// In the fight a tap anywhere does what the prompt says. Out of it, the one thing to tap on
// stage is the kraken once the captain has chosen to fight (to take the fight up again).
// Cards are answered on the card only; the crew tap for their detail card.
function styleToggle() {
  G.style = G.style === "p5" ? "manga" : "p5";
  overlay.style = G.style;
  document.body.dataset.style = G.style;
  ui.setFlag("style", false, G.style);
  try { localStorage.setItem("v2d-style", G.style); } catch {}
}
const specialBtn = $("special");
specialBtn?.addEventListener("pointerdown", (e) => { e.preventDefault(); e.stopPropagation(); battle.special(); });
function stageTargets() {
  if (!world || battle.playing || battle.ending) return [];
  const K = world.kraken;
  if (!sim.kraken.battle || K.rise < 0.5 || sim.kraken.fled) return [];
  return [{ id: "kraken", at: camera.toScreen(...K.eyePos()), r: 160, key: "tFight", act: () => battle.play(true) }];
}
// ---------------------------------------------------------------- the crew's detail cards
// Hover (or focus, or tap) a crewman for his card; one at a time; a second tap or Esc closes it.
function crewAt(id) {
  const p = world?.crew[id];
  if (!p) return null;
  return camera.toScreen(...world.at(p, "head", 0, -40));
}
function crewHit(x, y) {
  if (!world || battle.playing || battle.ending) return null;
  let best = null, bd = 1e9;
  for (const p of Object.values(world.crew)) {
    if (p.alpha < 0.5) continue;
    const [hx, hy] = crewAt(p.id), [fx, fy] = camera.toScreen(...world.ship.toWorld(p.x, p.y));
    const r = Math.max(22, Math.abs(fy - hy) * 0.45);
    if (x < hx - r || x > hx + r || y < hy - r * 0.6 || y > fy) continue;
    const d = Math.abs(x - hx);
    if (d < bd) (bd = d), (best = p.id);
  }
  return best;
}
// the one prompt at the bottom does what the ring on stage points at
function promptAct() {
  if (!G.ready) return;
  if (G.welcome) (G.welcome = false), ui.dismissCaption();
  stageTargets()[0]?.act();
}
canvas.addEventListener("pointerdown", (e) => {
  if (!G.ready) return;
  if (G.welcome) (G.welcome = false), ui.dismissCaption();
  if (battle.playing) return void battle.tap();
  const hit = stageTargets().find((t) => Math.hypot(e.clientX - t.at[0], e.clientY - t.at[1]) < t.r + 40);
  if (hit) return hit.act();
  const who = crewHit(e.clientX, e.clientY);
  // a tap on the captain: he takes the deck (or goes back to the helm)
  if (who === "captain") return (ui.crewPinned = false), ui.hideCrew(), helm.toggle();
  if (who && !(ui.crewId === who && ui.crewPinned)) (ui.crewPinned = true), ui.showCrew(who, crewAt(who));
  else (ui.crewPinned = false), ui.hideCrew();
});
canvas.addEventListener("pointermove", (e) => {
  if (!G.ready) return;
  const who = e.pointerType === "mouse" ? crewHit(e.clientX, e.clientY) : null;
  if (who && !ui.crewPinned) ui.showCrew(who, crewAt(who));
  else if (!who && !ui.crewPinned && ui.crewId) ui.hideCrew();
  canvas.style.cursor = battle.playing || who || stageTargets().some((t) => Math.hypot(e.clientX - t.at[0], e.clientY - t.at[1]) < t.r + 40) ? "pointer" : "default";
});
// the one on-stage hint out of battle: a pulsing ring on the first thing to tap
function drawStageHint() {
  const t0 = stageTargets()[0];
  if (!t0 || overlay.busy) return;
  const [x, y] = t0.at, k = 1 + Math.sin(performance.now() / 160) * 0.08;
  ctx.save();
  ctx.lineWidth = 10;
  ctx.strokeStyle = "#000";
  ctx.beginPath();
  ctx.arc(x, y, t0.r * 0.6 * k, 0, Math.PI * 2);
  ctx.stroke();
  ctx.lineWidth = 5;
  ctx.strokeStyle = G.style === "p5" ? "#e60012" : "#ffd23a";
  ctx.stroke();
  ctx.restore();
}

// ---------------------------------------------------------------- the Playground's crew
// The simulated voyage runs itself, as the real one does: the firstmate dispatches ready work
// to free hands, the reviewers do their rounds (the sim's schedule), new work joins the plan,
// and hands come aboard when work waits and go ashore when they idle. The captain is never
// played: cards wait for his click, and the fight for him.
const crewDriver = { next: 0, newAt: 30, hands: 60 };
function playgroundTick() {
  if (MODE !== "playground" || !G.driver || sim.t < crewDriver.next || battle.ending || G.menuPaused || Q.has("scene")) return;
  crewDriver.next = sim.t + 1.6;
  const ready = sim.tasks.filter((t) => t.lane === "ready").length;
  const idle = sim.crew.filter((c) => c.role === "worker" && c.state === "idle").length;
  if (ready && idle) return apply({ type: "dispatch" });
  if (sim.t > crewDriver.newAt && ready < 1) return (crewDriver.newAt = sim.t + 40), apply({ type: "newTask" });
  if (!crewDriver.captain && sim.t > crewDriver.hands && !world.ship.transforming) {
    crewDriver.hands = sim.t + 45;
    if (ready >= 2 && !idle && sim.crew.length < MAX_CREW) hire(Math.min(ready, 3));
    else if (idle >= 3 && sim.crew.length > MIN_CREW) dismiss(1);
  }
}
// the auto-play fighter taps exactly like a player: when the prompt is ready, and the
// special button when it lights
function botFight() {
  if (!(G.demo || window.__botFight) || !battle.playing || !battle.b) return;
  const P = battle.prompt();
  if (P && P.ready && (!P.quiet || Math.random() < 0.08)) battle.tap();
  if (battle.specialReady()) battle.special();
}

// ---------------------------------------------------------------- the frame
let last = performance.now(), fpsN = 0, fpsT = 0, rafId = 0;
G.fps = 0;
function frame(now) {
  rafId = requestAnimationFrame(frame);
  const dtReal = Math.min(0.1, (now - last) / 1000);
  last = now;
  if (!G.ready) return;
  const t0 = performance.now();
  try {
    const fx = world.fx;
    if (window.__freezeOnImpact && fx.impact.length) (G.paused = true), (window.__freezeOnImpact = false);
    const freeze = fx.hitstop > 0;
    const scale = freeze ? 0 : fx.slow > 0 ? 0.3 : 1;
    const paused = G.paused || G.menuPaused;
    const dt = paused ? 0 : dtReal * scale;
    // the board waits while the crew fight (and while they take their bow)
    if (!paused && !freeze && !battle.ending && !battle.playing) apply({ type: "tick", dt: dtReal * G.speed });
    playgroundTick();
    botFight();
    helm.update(dt);
    if (!G.menuPaused) mini.update(dtReal);
    world.update(dt);
    battle.update(dt, sim);
    director.update(paused ? 0 : dtReal);
    fx.viewScale = Math.max(1, Math.min(2.2, camera.h.x / 1500));
    world.heroLight = battle.heroLight || 0;
    fx.update(paused ? 0 : dtReal, world.env); // effects keep their real time (feedback stays live in hit-stop)
    camera.update(paused ? 0 : dtReal, fx);
    overlay.update(paused ? 0 : dtReal);
    render();
    ui.setPrompt(battle.playing || battle.ending ? null : stageTargets()[0], battle);
    if (ui.crewId) { const at = crewAt(ui.crewId); at ? ui.placeCrew(at) : ui.hideCrew(); }
  } catch (e) {
    if (G.errors.length < 3) showError("frame", e);
  }
  const cost = performance.now() - t0;
  if (cost > 12 && G.heavy.length < 40 && world) G.heavy.push({ c: +cost.toFixed(1), cut: overlay.cuts.length, imp: world.fx.impact[0]?.kind || "", parts: world.fx.parts.length, chips: world.fx.chips.length, sfx: world.fx.sfxs.length, balls: world.fx.balls.length, zb: !!battle.zoomBlur, ult: world.env.ult > 0.1, wave: battle.wave });
  G.frames.push(cost);
  if (G.frames.length > 240) G.frames.shift();
  fpsN++;
  fpsT += dtReal;
  if (fpsT > 0.5) (G.fps = Math.round(fpsN / fpsT)), (fpsN = 0), (fpsT = 0);
}

function render() {
  const fx = world.fx;
  const blurK = battle.blur;
  ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
  ctx.save();
  camera.apply(ctx);
  world.draw(ctx, camera);
  battle.drawWorld(ctx);
  if (director.placard) placard(ctx);
  ctx.restore();
  // motion trails: the last frame ghosted over this one while things move fast
  if (blurK > 0.02 && !low) {
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.globalAlpha = Math.min(0.4, blurK * 0.45);
    ctx.drawImage(trail, 0, 0);
    ctx.globalAlpha = 1;
  }
  // the radial zoom blur on the big hits
  const zb = battle.zoomBlur;
  if (zb && zb.k > 0.02 && !low) { // phones skip the radial blur (a full-frame copy per frame)
    const [sx, sy] = camera.toScreen(zb.x, zb.y);
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    tctx.setTransform(1, 0, 0, 1, 0, 0);
    tctx.drawImage(canvas, 0, 0);
    for (const [s, a] of low ? [[1.06, 0.35]] : [[1.04, 0.3], [1.09, 0.22], [1.15, 0.15]]) {
      ctx.globalAlpha = a * Math.min(1, zb.k);
      const cx = sx * DPR, cy = sy * DPR;
      ctx.drawImage(trail, cx - cx * s, cy - cy * s, canvas.width * s, canvas.height * s);
    }
    ctx.globalAlpha = 1;
  }
  if (blurK > 0.02 && !low) (tctx.setTransform(1, 0, 0, 1, 0, 0), tctx.drawImage(canvas, 0, 0));
  ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
  // screen tints: the squall, the maelstrom, the vignette, the ink
  const E = world.env;
  if (E.ult > 0.02) (ctx.fillStyle = `rgba(120,0,20,${0.18 * E.ult})`), ctx.fillRect(0, 0, W, H);
  const vg = ctx.createRadialGradient(W / 2, H / 2, Math.min(W, H) * 0.35, W / 2, H / 2, Math.max(W, H) * 0.75);
  vg.addColorStop(0, "rgba(10,6,20,0)");
  vg.addColorStop(1, `rgba(10,6,20,${0.35 + 0.3 * Math.max(E.storm, E.ult)})`);
  ctx.fillStyle = vg;
  ctx.fillRect(0, 0, W, H);
  if (battle.ink > 0) {
    ctx.fillStyle = `rgba(20,4,30,${Math.min(0.85, battle.ink * 0.5)})`;
    for (let i = 0; i < 7; i++) {
      ctx.beginPath();
      ctx.arc(W * (0.2 + ((i * 0.37) % 0.7)), H * (0.25 + ((i * 0.53) % 0.5)), 90 + (i % 3) * 60, 0, Math.PI * 2);
      ctx.fill();
    }
  }
  if (fx.flash > 0.01) (ctx.fillStyle = `rgba(${fx.flashCol},${fx.flash})`), ctx.fillRect(0, 0, W, H);
  overlay.draw(ctx, W, H);
  const hs = battle.hud();
  if (hs && !overlay.busy && !battle.ending) {
    const P = battle.prompt();
    drawHUD(ctx, W, H, { ...hs, prompt: P && { ...P, text: ui.tr(P.text), sub: ui.tr(P.sub) }, t: world.env.t }, G.style);
  }
  if (!battle.playing && !window.__noStageHint) drawStageHint();
  helm.draw(ctx, G.style);
  if (battle.callout && !overlay.busy && !overlay.cuts.length) callout(battle.callout);
  if (fx.impact.length) {
    tctx.setTransform(1, 0, 0, 1, 0, 0);
    tctx.drawImage(canvas, 0, 0);
    drawImpact(ctx, W, H, fx.impact[0].kind, trail, DPR);
  }
  // the special button lights at a full gauge
  if (specialBtn) {
    const on = battle.specialReady();
    if (on !== !specialBtn.hidden) specialBtn.hidden = !on;
    if (on) {
      const n = nextSpecial(battle.b);
      const lab = { broadside: ["舷側斉射", "BROADSIDE"], harpoon: ["魚叉鎖鏈", "HARPOON"], order: ["総員砲撃", "ALL HANDS"] }[n];
      if (specialBtn.dataset.k !== n + ui.lang) (specialBtn.dataset.k = n + ui.lang), (specialBtn.innerHTML = `<b>${lab[0]}</b><small>${lab[1]} · ${ui.t.tap}</small>`);
    }
  }
}
function callout(c) {
  const k = c.t / 1.2, s = c.t < 0.12 ? 1.5 - c.t * 4 : 1;
  ctx.save();
  ctx.translate(W / 2, W < 720 ? H * 0.45 : H * 0.36);
  ctx.scale(s, s);
  ctx.globalAlpha = k > 0.75 ? (1 - k) / 0.25 : 1;
  const fs = Math.min(52, W / 14);
  ctx.font = `400 ${fs}px ${FONT_JP}`;
  ctx.textAlign = "center";
  ctx.lineWidth = fs * 0.16;
  ctx.strokeStyle = "#0c0810";
  ctx.lineJoin = "round";
  ctx.strokeText(c.text, 0, 0);
  ctx.fillStyle = c.col;
  ctx.fillText(c.text, 0, 0);
  ctx.restore();
}
// the captain's decision placard, raised overhead while a card waits
function placard(ctx) {
  const c = world.crew.captain;
  if (!c) return;
  const im = world.images.props.placard;
  const [x, y] = world.at(c, "head", 0, -330);
  ctx.save();
  ctx.translate(x + 60, y - 40 + Math.sin(world.env.t * 3) * 8);
  ctx.rotate(0.08);
  const s = 0.45;
  if (im) ctx.drawImage(im.im, (-im.w * s) / 2, (-im.h * s) / 2, im.w * s, im.h * s);
  ctx.restore();
}

addEventListener("resize", resize);
resize();
rafId = requestAnimationFrame(frame);
build().catch((e) => showError("build", e));

// ---------------------------------------------------------------- test hooks
window.__voyage2d = {
  bossKeyFired: false, mode: MODE,
  prompt: () => battle?.prompt() || null,
  targets: () => stageTargets().map(({ id, at, key }) => ({ id, at, label: ui.t[key] })),
  hire, dismiss, setHands, get ui() { return ui; }, get helm() { return helm; }, get mini() { return mini; }, source,
  // proof and test staging: a hand to a station now (the sim's deck names), the captain set down
  // beside someone (the nearest clear spot; the crowd's rules still hold)
  station(id, station, action) { const p = world.crew[id]; return world.sendTo(p, station, action); },
  placeCaptain(nearId, dx = 110) {
    const C = world.crowd, a = C.get("captain"), b = C.get(nearId);
    if (!a || !b) return false;
    C.stop("captain");
    const q = C.findFree(b.deck, b.x + dx, b.z + 60, a.r, a);
    if (!q) return false;
    Object.assign(a, q, { link: null });
    return q;
  },
  specialReady: () => battle?.specialReady() || false,
  get sim() { return sim; }, get battle() { return battle; }, get world() { return world; }, get camera() { return camera; }, get director() { return director; }, get overlay() { return overlay; },
  apply, stage, G,
  // fire one special on cue (proof shots): broadside, harpoon, order, riposte, ult, finisher
  special(name) {
    if (!battle.playing) stage("battle");
    const b = battle.b;
    b.gauge = 100;
    b.attack = null;
    b.next = b.t + 30;
    if (name !== "ult" && name !== "finisher") Object.assign(b, { grip: 100, ult: null, phase: "fight", pendingUlt: false, ultDone: [60, 25] });
    world.env.ult = 0;
    world.kraken.ult = 0;
    for (const a of world.kraken.arms) a.attack = null;
    if (name === "broadside") { battle.step({ type: "broadsideStart" }); b.charge = null; battle.b.charge = battle.b.t - 0.82; battle.step({ type: "broadsideFire" }); }
    if (name === "harpoon") battle.step({ type: "harpoon" });
    if (name === "order") battle.step({ type: "order" });
    if (name === "riposte") { battle.b.riposteUntil = battle.b.t + 1; battle.b.weak = true; world.kraken.weak = 1; battle.step({ type: "parry" }); }
    if (name === "ult") { battle.b.pendingUlt = true; battle.b.gauge = 0; }
    if (name === "finisher") { battle.b.grip = 3; battle.step({ type: "harpoon" }); battle.finish(); }
    return name;
  },
  perf() {
    const f = G.frames.slice().sort((a, b) => a - b);
    const pct = (p) => f[Math.min(f.length - 1, Math.floor(f.length * p))] || 0;
    return { fps: G.fps, n: f.length, p50: +pct(0.5).toFixed(2), p95: +pct(0.95).toFixed(2), max: +pct(1).toFixed(2), detail: G.detail, readyMs: G.readyMs, particles: world.fx.parts.length, dpr: DPR };
  },
};
window.__THREE_GAME_TEST_HOOKS__ = {
  setState(s) { return stage(s); },
  setPausedForScreenshot(p) { G.paused = !!p; return { paused: G.paused }; },
};
