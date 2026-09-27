// Firstmate Voyage: the playable ship. The pure sim (src/sim) is the truth; the
// director turns its events into rituals on deck; the battle view plays the
// kraken; the UI is the board around the ship.
//
// URL: seed, demo=1 (auto-play), speed, detail=low|high, hud=0, cam=free,
//      scene=<name> (jump to a staged moment for screenshots: order, work,
//      review, squall, merge, port, kraken, battle, decision), dpr
import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { createRenderer, createComposer } from "../engine/lighting.js";
import { countTriangles } from "../engine/materials.js";
import { createSim, step, weather } from "../sim/sim.js";
import { createWorld } from "./world.js";
import { FX } from "./fx.js";
import { Sound } from "./audio.js";
import { UI } from "./ui.js";
import { Director } from "./director.js";
import { BattleView } from "./battleview.js";

const T0 = performance.now();
const Q = new URLSearchParams(location.search);
const $ = (id) => document.getElementById(id);
const nextFrame = () => new Promise((r) => requestAnimationFrame(() => r()));

// ---------------------------------------------------------------- detail level (phones, low memory, lost context)
function autoDetail() {
  let lost = false;
  try {
    lost = !!sessionStorage.getItem("fmv-context-lost");
  } catch {}
  const touch = matchMedia("(pointer: coarse)").matches || navigator.maxTouchPoints > 1;
  const small = Math.min(screen.width, screen.height) < 600 || Math.min(innerWidth, innerHeight) < 500;
  const lowMem = navigator.deviceMemory && navigator.deviceMemory <= 4;
  return lost || touch || small || lowMem || /Android|iPhone|iPad|Mobile/i.test(navigator.userAgent) ? "low" : "high";
}
const G = {
  seed: +(Q.get("seed") || 7),
  detail: Q.get("detail") === "low" || Q.get("detail") === "high" ? Q.get("detail") : autoDetail(),
  speed: +(Q.get("speed") || 1),
  demo: Q.get("demo") === "1",
  paused: false,
  ready: false,
  errors: [],
};
const rituals = { order: true, salvo: true, port: true, salute: true, clearing: true, weather: true, kraken: true };

function showError(what, e) {
  console.warn("[voyage]", what, e);
  G.errors.push(`${what}: ${e?.message || e}`);
  ui?.error("Something could not be built: " + G.errors.join(" · "));
}

// ---------------------------------------------------------------- renderer
const canvas = $("c");
let renderer;
try {
  renderer = createRenderer(canvas);
} catch (e) {
  $("err").hidden = false;
  $("err").textContent = "WebGL is not available on this device.";
  throw e;
}
renderer.info.autoReset = false;
const lowDetail = G.detail === "low";
renderer.shadowMap.enabled = !lowDetail;
const loseExt = renderer.getContext().getExtension("WEBGL_lose_context");
let contextLost = false;
canvas.addEventListener("webglcontextlost", (e) => {
  e.preventDefault();
  contextLost = true;
  try {
    sessionStorage.setItem("fmv-context-lost", "1");
  } catch {}
  ui.loading("The graphics context was lost; restoring at low detail…");
});
canvas.addEventListener("webglcontextrestored", () => {
  // restart at low detail, keeping the voyage (the sim is the truth)
  try {
    sessionStorage.setItem("fmv-resume", JSON.stringify(sim));
  } catch {}
  const u = new URL(location.href);
  u.searchParams.set("detail", "low");
  location.replace(u.toString());
});

const camera = new THREE.PerspectiveCamera(50, innerWidth / innerHeight, 0.3, 1400);
camera.position.set(-10, 8, 20);
const controls = new OrbitControls(camera, canvas);
controls.enableDamping = true;
controls.dampingFactor = 0.08;
controls.minDistance = 4;
controls.maxDistance = 90;
controls.maxPolarAngle = Math.PI * 0.49;
controls.enabled = false;

// ---------------------------------------------------------------- the voyage
let sim = createSim(G.seed);
try {
  const resume = sessionStorage.getItem("fmv-resume");
  if (resume) {
    sim = JSON.parse(resume);
    sessionStorage.removeItem("fmv-resume");
  }
} catch {}
const sound = new Sound();
let ui, world, fx, director, battle, comp;

function apply(action) {
  const r = step(sim, action);
  sim = r.state;
  for (const e of r.events) handle(e);
  if (r.events.length) ui.render(sim);
  return r.events;
}
function handle(e) {
  try {
    if (e.type === "caption") return ui.caption(e.text);
    const line = sim.log.find((l) => Math.abs(l.t - e.t) < 0.001 && l.kind === e.type);
    if (line) ui.caption(line.text);
    director.handle(e, sim);
    if (e.type === "victory") battle.victory();
    battle.sync(sim);
    director.refreshPennants(sim);
  } catch (err) {
    showError("event " + e.type, err);
  }
}

// ---------------------------------------------------------------- build, in stages
ui = new UI({
  act: (a) => act(a),
  cardAction: (kind, id) => {
    if (kind === "dispatch") apply({ type: "dispatch", task: id });
    else if (kind === "survey") apply({ type: "survey", task: id });
    else if (kind === "park") apply({ type: "park", task: id });
    else if (kind === "drop") apply({ type: "drop", task: id });
    else if (kind === "course") apply({ type: "setCourse", task: id });
    else if (kind === "face") {
      const d = sim.decisions.find((x) => x.kind === "kraken");
      if (d) ui.render(sim);
    }
  },
  answer: (id, key) => apply({ type: "answer", decision: id, key }),
  ritual: (name, on) => {
    rituals[name] = on;
    apply({ type: "ritual", name, on });
  },
  sound: () => toggleSound(),
  camera: () => toggleCamera(),
  demo: () => toggleDemo(),
  speed: () => {
    G.speed = G.speed >= 3 ? 1 : G.speed + 1;
    ui.setFlag("c-speed", false, G.speed + "×");
  },
  detail: () => {
    const u = new URL(location.href);
    u.searchParams.set("detail", G.detail === "low" ? "high" : "low");
    location.replace(u.toString());
  },
  play: (on) => battle.play(on),
  skillDown: (id) => battle.skillDown(id),
  skillUp: (id, c) => battle.skillUp(id, c),
  armTap: (i) => battle.armTap(i),
  rerender: () => ui.render(sim),
});
ui.setFlag("c-detail", false, G.detail);
ui.setFlag("c-speed", false, G.speed + "×");
if (innerWidth < 720) ui.toggle("board", false);

async function build() {
  ui.loading("Hoisting the sails…");
  world = createWorld(renderer, { detail: G.detail });
  fx = new FX(world.scene, { detail: G.detail });
  resize();
  await nextFrame();
  try {
    world.buildShip();
  } catch (e) {
    showError("the frigate", e);
  }
  ui.loading("Mustering the crew…");
  await nextFrame();
  try {
    world.buildCrew(sim.crew);
  } catch (e) {
    showError("the crew", e);
  }
  await nextFrame();
  try {
    world.buildScenery();
  } catch (e) {
    showError("the lighthouse", e);
  }
  director = new Director({ world, fx, sound, ui, camera, controls, getSim: () => sim, rituals });
  battle = new BattleView({ world, fx, sound, ui, camera, director });
  director.onBattlePush = () => battle.realPush();
  director.onBattleStorm = () => battle.realStorm();
  director.onRealStrike = (e) => battle.realStrike(e);
  // restore the scene for a resumed voyage (after a lost context)
  for (const c of sim.crew) {
    const cm = world.crew[c.id];
    if (cm && c.role === "worker" && c.station) {
      const spot = world.stationSpot(c.station, cm.slot, c.action);
      cm.pos.copy(spot.pos);
      cm.yaw = spot.yaw;
      cm.setLoop(c.action, spot.pos);
    }
  }
  if (sim.kraken.arms.length) world.setKrakenArms(sim.kraken.arms.length);
  director.refreshPennants(sim);
  ui.render(sim);
  battle.sync(sim);
  world.setStorm(director.stormLevel(sim));
  comp = createComposer(renderer, world.scene, camera, { strength: 0.42, radius: 0.35, threshold: 1.0 });
  resize();
  if (Q.get("cam") === "free") toggleCamera(true);
  if (G.demo) toggleDemo(true);
  if (Q.get("scene")) stage(Q.get("scene"));
  ui.caption("Welcome aboard, captain. Press O to give the order, or Auto-play to watch a voyage.");
  ui.loading("");
  G.ready = true;
}

// ---------------------------------------------------------------- staged moments (screenshots, QA, the playground)
function stage(name) {
  const tick = (sec) => {
    for (let i = 0; i < sec * 10; i++) apply({ type: "tick", dt: 0.1 });
  };
  const answerAll = (key = "A") => {
    for (let i = 0; i < 6 && sim.decisions.length; i++) apply({ type: "answer", key });
  };
  if (name === "order") apply({ type: "dispatch" });
  if (name === "work" || name === "review" || name === "squall" || name === "merge" || name === "decision") {
    apply({ type: "dispatch" });
    apply({ type: "dispatch" });
    apply({ type: "dispatch" });
    tick(4);
  }
  if (name === "review") apply({ type: "openPR" });
  if (name === "squall") apply({ type: "redCheck" });
  if (name === "merge") {
    const t = sim.tasks.find((x) => x.lane === "working");
    apply({ type: "approve", task: t.id });
    apply({ type: "merge" });
  }
  if (name === "decision") {
    const t = sim.tasks.find((x) => x.lane === "working");
    apply({ type: "approve", task: t.id });
  }
  if (name === "port") {
    for (const id of sim.milestones[0].tasks) {
      apply({ type: "dispatch", task: id });
      apply({ type: "approve", task: id });
      apply({ type: "merge" });
    }
  }
  if (name === "kraken" || name === "battle") {
    apply({ type: "dispatch" });
    apply({ type: "dispatch" });
    const ids = sim.tasks.filter((x) => x.lane === "working").map((x) => x.id);
    for (const id of ids) for (let i = 0; i < 3; i++) apply({ type: "reject", task: id });
    if (name === "battle") {
      const d = sim.decisions.find((x) => x.kind === "kraken");
      if (d) apply({ type: "answer", decision: d.id, key: "A" });
      battle.play(true);
    }
  }
  return { state: name };
}

// ---------------------------------------------------------------- input
function act(a) {
  if (!G.ready) return;
  const map = { newTask: "newTask", dispatch: "dispatch", openPR: "openPR", merge: "merge", approve: "approve", reject: "reject", redCheck: "redCheck", greenCheck: "greenCheck", push: "push" };
  if (map[a]) apply({ type: map[a] });
}
function toggleSound(force) {
  sound.enable(force ?? !sound.on);
  ui.setFlag("b-sound", sound.on);
  ui.setFlag("c-sound", sound.on, sound.on ? "On" : "Off");
}
function toggleCamera(force) {
  const free = force ?? director.cinematic;
  director.cinematic = !free;
  controls.enabled = free;
  ui.setFlag("b-cam", free);
  ui.setFlag("c-cine", !free, free ? "Off" : "On");
}
function toggleDemo(force) {
  G.demo = force ?? !G.demo;
  bot.next = 0;
  ui.setFlag("b-demo", G.demo);
  ui.setFlag("c-demo", G.demo, G.demo ? "On" : "Off");
  if (G.demo && sim.kraken.battle && !battle.playing) battle.play(true);
}
addEventListener("keydown", (e) => {
  if (!G.ready || e.metaKey || e.ctrlKey || e.altKey) return;
  if (e.target.closest?.("input, textarea")) return;
  const k = e.key;
  // while playing, the battle's keys come first (T-086)
  if (battle.key(k, true)) {
    e.preventDefault();
    return;
  }
  // a card on the table takes A-D and Enter
  if (sim.decisions.length && ui.decisionShown && /^[a-dA-D]$/.test(k)) {
    ui.choose(k.toUpperCase());
    return;
  }
  if (sim.decisions.length && ui.decisionShown && k === "Enter") {
    ui.confirm();
    return;
  }
  const K = k.toLowerCase();
  const acts = { n: "newTask", o: "dispatch", u: "openPR", m: "merge", v: "approve", j: "reject", h: "push", f: "redCheck", g: "greenCheck" };
  if (acts[K]) return act(acts[K]);
  if (K === "b") ui.toggle("board");
  else if (K === "l") ui.toggle("roster") || ui.render(sim);
  else if (K === "k") ui.toggle("customs");
  else if (K === "s") toggleSound();
  else if (K === "c") toggleCamera();
  else if (K === "p") toggleDemo();
  else if (K === "x") document.body.classList.toggle("nohud");
  else if (k === "Escape") ui.minimise();
});
addEventListener("keyup", (e) => {
  if (G.ready && battle.key(e.key, false)) e.preventDefault();
});
// the head is the battle's only hit target: tap to aim / fire / counter, hold to charge the harpoon
{
  const hh = $("headhit");
  let holdTimer = null;
  hh.addEventListener("pointerdown", (e) => {
    e.preventDefault();
    hh.setPointerCapture?.(e.pointerId);
    holdTimer = setTimeout(() => {
      holdTimer = "held";
      battle.skillDown("harpoon");
    }, 220);
  });
  const up = (e) => {
    if (holdTimer === "held") battle.skillUp("harpoon", e.type === "pointercancel" || e.type === "lostpointercapture");
    else if (holdTimer && e.type === "pointerup") battle.headTap();
    clearTimeout(holdTimer);
    holdTimer = null;
  };
  hh.addEventListener("pointerup", up);
  hh.addEventListener("pointercancel", up);
  hh.addEventListener("lostpointercapture", up);
  $("windup").addEventListener("pointerdown", (e) => {
    e.preventDefault();
    battle.skillDown("sail");
  });
}

// ---------------------------------------------------------------- the auto-play captain (seeded, deterministic by sim time)
const bot = { next: 0, newAt: 30 };
function botStep() {
  if (!G.demo || sim.t < bot.next) return;
  bot.next = sim.t + 1.6;
  const d = sim.decisions[0];
  if (d) {
    // reads the card, then answers: merge on merge cards, fight the kraken, proceed on choices
    const key = d.kind === "merge" ? "A" : d.kind === "kraken" ? "A" : d.kind === "scope" ? "A" : ["A", "A", "B"][Math.floor(sim.t) % 3];
    ui.decisionShown = d.id;
    ui.choose(key);
    apply({ type: "answer", decision: d.id, key });
    return;
  }
  if (sim.kraken.battle && !battle.playing) battle.play(true);
  if (sim.tasks.some((t) => t.lane === "ready") && sim.crew.some((c) => c.role === "worker" && c.state === "idle")) return apply({ type: "dispatch" });
  if (sim.t > bot.newAt && sim.tasks.filter((t) => t.lane === "ready").length < 1) {
    bot.newAt = sim.t + 40;
    apply({ type: "newTask" });
  }
}
function botBattle() {
  if (!G.demo || !battle.playing || !battle.b) return;
  const b = battle.b;
  const a = b.attack;
  if (a) {
    const st = { p: 0, ...(battle.b && (() => import.meta && null)()) };
    void st;
  }
  // read the bar: full sail inside the perfect zone, then counter
  const at = battle.b.attack ? battle.b : null;
  if (at) {
    const s = at.attack;
    const e = at.t - s.start;
    const dur = s.pattern === "feint" ? 1.96 : s.part === 2 ? 0.7 : { slam: 1.6, jab: 0.85, combo: 1.15 }[s.pattern];
    const zone = s.part === 2 ? 0.17 : { slam: 0.14, jab: 0.16, combo: 0.15, feint: 0.14 }[s.pattern];
    if (!s.dodge && e / dur > 1 - zone * 0.6 && e < dur && at.cooldowns.sail <= at.t) battle.skillDown("sail");
  }
  if (b.counterUntil && b.t <= b.counterUntil && b.t > b.slowUntil) battle.step({ type: "counter" });
  if (!a) {
    if (b.cooldowns.broadside <= b.t && b.aim === null) battle.step({ type: "broadsideAim" });
    else if (b.aim !== null && b.t - b.aim >= 0.8) battle.step({ type: "broadsideFire" });
    else if (b.cooldowns.order <= b.t) battle.step({ type: "order" });
    else if (b.splinters.length && b.cooldowns.repair <= b.t) battle.step({ type: "repair" });
    else if (b.cooldowns.chain <= b.t && b.arms > 1) battle.step({ type: "chain", arm: 0 });
  }
}

// ---------------------------------------------------------------- loop
function resize() {
  const w = innerWidth,
    h = innerHeight;
  const cap = Q.has("dpr") ? +Q.get("dpr") : lowDetail ? 1 : 1.5;
  renderer.setPixelRatio(Math.min(devicePixelRatio || 1, cap));
  renderer.setSize(w, h, false);
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
  comp?.composer.setSize(w, h);
  if (G.ready) ui.render(sim);
}
addEventListener("resize", resize);

let last = performance.now();
let frames = 0,
  fps = 0,
  facc = 0,
  fn = 0,
  uiAcc = 0;
const timing = { firstFrame: null, ready: null };
function frame() {
  requestAnimationFrame(frame);
  if (contextLost) return;
  const nowMs = performance.now();
  const dt = Math.min(0.1, (nowMs - last) / 1000);
  last = nowMs;
  const now = nowMs / 1000;
  if (!G.ready) {
    // paint the sky and the sea once, then wait for the finished scene (weak GPUs)
    if (world && !frames) {
      renderer.render(world.scene, camera);
      frames = 1;
      timing.firstFrame = Math.round(nowMs - T0);
    }
    return;
  }
  renderer.info.reset();
  try {
    const hit = fx.hitstop > 0;
    if (!G.paused && !hit) {
      apply({ type: "tick", dt: dt * G.speed });
      botStep();
      botBattle();
    }
    world.update(G.paused ? 0 : dt, now);
    director.update(dt);
    battle.update(G.paused || hit ? 0 : dt, sim);
    fx.update(dt, camera);
    if (!director.cinematic) controls.update();
    fx.applyShake(camera, dt, now);
    comp.composer.render();
  } catch (e) {
    if (!G.errors.length) showError("render", e);
  }
  uiAcc += dt;
  if (uiAcc > 0.5) {
    uiAcc = 0;
    ui.renderChart(sim);
  }
  frames++;
  facc += dt;
  fn++;
  if (facc > 0.5) {
    fps = fn / facc;
    facc = 0;
    fn = 0;
  }
  if (timing.ready === null) timing.ready = Math.round(nowMs - T0);
}

// ---------------------------------------------------------------- QA hooks (threejs-qa-release, threejs-debug-profiler)
window.__THREE_GAME_DIAGNOSTICS__ = {
  renderer: {
    get calls() {
      return renderer.info.render.calls;
    },
    get triangles() {
      return renderer.info.render.triangles;
    },
    get geometries() {
      return renderer.info.memory.geometries;
    },
    get textures() {
      return renderer.info.memory.textures;
    },
  },
  get state() {
    return { ready: G.ready, detail: G.detail, fps, t: sim.t, weather: weather(sim), merged: sim.stats.merged, kraken: sim.kraken.arms.length, battle: !!battle?.playing, errors: G.errors, timing };
  },
};
window.__THREE_GAME_TEST_HOOKS__ = {
  setState(name) {
    const ok = ["order", "work", "review", "squall", "merge", "port", "kraken", "battle", "decision", "active-play"];
    if (!ok.includes(name)) throw new Error("unknown state " + name);
    return name === "active-play" ? { state: name } : stage(name);
  },
  setPausedForScreenshot(p) {
    G.paused = !!p;
    return { paused: G.paused };
  },
  seed(n) {
    sim = createSim(n);
    ui.render(sim);
    return { seed: n };
  },
};
window.__voyage = {
  get sim() {
    return sim;
  },
  get battle() {
    return battle;
  },
  apply,
  stage,
  G,
  timing,
  loseContext: () => loseExt?.loseContext(),
  restoreContext: () => loseExt?.restoreContext(),
  get world() {
    return world;
  },
};

if (Q.get("hud") === "0") document.body.classList.add("nohud");
requestAnimationFrame(frame);
build().catch((e) => showError("build", e));
