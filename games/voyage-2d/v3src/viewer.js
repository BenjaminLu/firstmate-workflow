// Model viewer: every character at every angle, beside its reference.
//
// Skills applied (see PROPORTIONS.md "round 7"):
//  - interaction: OrbitControls with damping 0.08, distance + polar limits, target
//    on the model's centre, presets that animate the camera instead of jumping
//  - lighting: "Studio" = neutral three-point rig (key + fill + rim) over a
//    hemisphere fill with one 1024 shadow map tightly fitted to the model;
//    "Scene" = the golden-hour rig from the game
//  - materials: shared material roles from materials.js (no per-mesh materials);
//    wireframe toggles the shared roles once
//  - debug/QA: window.__THREE_GAME_DIAGNOSTICS__ (renderer.info + state) and
//    window.__THREE_GAME_TEST_HOOKS__ (setState / setPausedForScreenshot) for the
//    canvas inspector; context loss / restore rebuilds at low detail
//  - UI: authored panels, 44 px touch targets, focus rings, safe areas, loading
//    and error states, fixed-width numerals in the stats readout
//
// URL params (automation): char, preset (front|q-left|q-right|side|back|top|match),
// expr, pose, light=studio|scene, ortho=1, lineup=1, ref=1, spin=0|1, wire=1,
// detail=low|high, hud=0.
import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { createRenderer, createSky, createLights } from "./engine/lighting.js";
import { materials, countTriangles, PAL, toMesh } from "./engine/materials.js";
import { VoxelGrid, M } from "./engine/voxel.js";
import { setHeadDetail } from "./engine/models/chibi.js";
import { buildCaptain } from "./engine/models/captain.js";
import { buildRobot } from "./engine/models/robot.js";
import { buildSailor } from "./engine/models/sailor.js";
import { buildReviewer } from "./engine/models/reviewer.js";
import { buildCorgi } from "./engine/models/corgi.js";
import { buildParrot } from "./engine/models/parrot.js";
import { buildKraken } from "./engine/models/kraken.js";
import { REFS } from "./viewer-refs.js";

const T0 = performance.now();
const Q = new URLSearchParams(location.search);
const $ = (id) => document.getElementById(id);
const D2R = Math.PI / 180;

// ------------------------------------------------------------------ characters
const CHARS = [
  { id: "captain", label: "Captain", build: (o) => buildCaptain(o) },
  { id: "sailor-hammer", label: "Hammer", build: (o) => buildSailor({ variant: "hammer", seed: 5, ...o }) },
  { id: "sailor-bandana", label: "Red cap", build: (o) => buildSailor({ variant: "bandana", ...o }) },
  { id: "sailor-spyglass", label: "Spyglass", build: (o) => buildSailor({ variant: "spyglass", seed: 7, ...o }) },
  { id: "sailor-laptop", label: "Laptop", build: (o) => buildSailor({ variant: "laptop", seed: 3, ...o }) },
  { id: "reviewer", label: "Reviewer", build: (o) => buildReviewer(o) },
  { id: "robot", label: "Robot", build: (o) => buildRobot(o) },
  { id: "corgi", label: "Corgi", build: (o) => buildCorgi(o), rebuildPose: true },
  { id: "parrot", label: "Parrot", build: (o) => buildParrot(o) },
  { id: "kraken", label: "Kraken", build: (o) => buildKraken({ ...o, lod: state.detail }), big: true },
];
const NEUTRAL = { robot: "eyes", corgi: "calm", parrot: "eyes", kraken: "glare" };
const LAUGH = { robot: "happy", corgi: "happy", parrot: "eyes", kraken: "angry", reviewer: "joy" };

function autoDetail() {
  let lost = false;
  try {
    lost = !!sessionStorage.getItem("fmv-context-lost");
  } catch {}
  const small = Math.min(innerWidth, innerHeight) < 500;
  const touch = matchMedia("(pointer: coarse)").matches;
  const lowMem = navigator.deviceMemory && navigator.deviceMemory <= 4;
  return lost || small || touch || lowMem ? "low" : "high";
}
const state = {
  char: CHARS.some((c) => c.id === Q.get("char")) ? Q.get("char") : "captain",
  preset: Q.get("preset") || "q-left",
  expr: Q.get("expr") || null,
  pose: Q.get("pose") || null,
  light: Q.get("light") === "scene" ? "scene" : "studio",
  ortho: Q.get("ortho") === "1",
  lineup: Q.get("lineup") === "1",
  ref: Q.get("ref") === "1",
  spin: Q.get("spin") === "1",
  wire: Q.get("wire") === "1",
  detail: Q.get("detail") === "low" || Q.get("detail") === "high" ? Q.get("detail") : autoDetail(),
  paused: false,
};

// ------------------------------------------------------------------ renderer
const canvas = $("c");
const errors = [];
function showError(what, e) {
  console.warn(`[viewer] ${what}:`, e);
  errors.push(`${what}: ${e?.message || e}`);
  $("error").hidden = false;
  $("error").textContent = "Could not build " + errors.join(" · ");
}
let renderer;
try {
  renderer = createRenderer(canvas);
} catch (e) {
  showError("WebGL", e);
  throw e;
}
renderer.shadowMap.enabled = true;
const loseExt = renderer.getContext().getExtension("WEBGL_lose_context");
let contextLost = false;
canvas.addEventListener("webglcontextlost", (e) => {
  e.preventDefault();
  contextLost = true;
  try {
    sessionStorage.setItem("fmv-context-lost", "1");
  } catch {}
  $("loading").hidden = false;
  $("loading").textContent = "Graphics context lost — restoring at low detail…";
});
canvas.addEventListener("webglcontextrestored", () => {
  contextLost = false;
  state.detail = "low";
  rebuildAll();
});

const scene = new THREE.Scene();
const persp = new THREE.PerspectiveCamera(35, 1, 0.02, 400);
const ortho = new THREE.OrthographicCamera(-1, 1, 1, -1, 0.01, 400);
let camera = state.ortho ? ortho : persp;
const controls = new OrbitControls(camera, canvas);
controls.enableDamping = true;
controls.dampingFactor = 0.08;
controls.minDistance = 0.4;
controls.maxDistance = 80;
controls.maxPolarAngle = Math.PI * 0.98;

// ------------------------------------------------------------------ lighting rigs
const studio = new THREE.Group();
{
  studio.add(new THREE.HemisphereLight(0xf4f6ff, 0x6e6a78, 1.1));
  const key = new THREE.DirectionalLight(0xfff4e6, 2.4);
  key.position.set(3, 5, 4);
  key.castShadow = true;
  key.shadow.mapSize.set(1024, 1024);
  key.shadow.bias = -0.0004;
  key.shadow.normalBias = 0.02;
  Object.assign(key.shadow.camera, { left: -2, right: 2, top: 2, bottom: -2, near: 0.5, far: 20 });
  const fill = new THREE.DirectionalLight(0xdfe8ff, 0.9);
  fill.position.set(-4, 2.5, 3);
  const rim = new THREE.DirectionalLight(0xffffff, 1.1);
  rim.position.set(-1, 3.5, -5);
  studio.add(key, key.target, fill, rim);
  studio.userData.key = key;
  // shadow-catching floor + a soft backdrop colour
  const floor = new THREE.Mesh(new THREE.CircleGeometry(6, 64), new THREE.MeshStandardMaterial({ color: 0x3a3f52, roughness: 0.95 }));
  floor.rotation.x = -Math.PI / 2;
  floor.receiveShadow = true;
  studio.add(floor);
  studio.userData.floor = floor;
}
const golden = new THREE.Group();
{
  const SUN = new THREE.Vector3(-0.5, 0.12, -0.85).normalize();
  golden.add(createSky(SUN));
  const tmp = new THREE.Scene();
  const L = createLights(tmp, { sunDir: new THREE.Vector3(0.45, 0.55, 0.7), shadowExtent: 3, mapSize: 1024 });
  for (const o of [...tmp.children]) golden.add(o);
  golden.userData.sun = L.sun;
  const deck = new VoxelGrid({ jitter: 3, seam: 0.35, seed: 5 });
  for (let x = -24; x <= 24; x++)
    for (let z = -24; z <= 24; z++) {
      if (Math.hypot(x, z) > 24) continue;
      deck.set(x, 0, z, Math.floor((x + 40) / 3) % 2 ? PAL.deck : PAL.deckB);
    }
  const d = toMesh(deck, { size: 0.12 });
  d.position.y = -0.06;
  golden.add(d);
}
function applyLight() {
  scene.remove(studio, golden);
  scene.add(state.light === "studio" ? studio : golden);
  scene.background = state.light === "studio" ? new THREE.Color(0x232838) : null;
  scene.fog = null;
  document.body.dataset.light = state.light;
}

// ------------------------------------------------------------------ model building
const stage = new THREE.Group();
scene.add(stage);
const built = new Map(); // id -> { rig, holder }
function build(c) {
  setHeadDetail(state.detail);
  try {
    const rig = c.build({ pose: state.pose || undefined, expression: undefined });
    return rig;
  } catch (e) {
    showError(c.label, e);
    return null;
  }
}
function clearStage() {
  for (const o of [...stage.children]) stage.remove(o);
  built.clear();
}
function mountSingle() {
  clearStage();
  const c = CHARS.find((x) => x.id === state.char);
  const rig = build(c);
  if (!rig) return;
  const holder = new THREE.Group();
  holder.add(rig.group);
  if (c.big) holder.scale.setScalar(0.22); // the kraken shares the studio at a readable size
  stage.add(holder);
  built.set(c.id, { rig, holder, c });
  applyExprPose();
}
function mountLineup() {
  clearStage();
  const list = CHARS.filter((c) => !c.big);
  list.forEach((c, i) => {
    const rig = build(c);
    if (!rig) return;
    const holder = new THREE.Group();
    holder.position.x = (i - (list.length - 1) / 2) * 1.25;
    holder.add(rig.group);
    stage.add(holder);
    built.set(c.id, { rig, holder, c });
  });
  applyExprPose();
}
function exprFor(id, rig) {
  if (!state.expr) return null;
  if (state.expr === "neutral") return NEUTRAL[id] || (rig.expressions.includes("smile") ? "smile" : rig.expressions[0]);
  if (state.expr === "laugh") return LAUGH[id] || (rig.expressions.includes("joy") ? "joy" : rig.expressions[0]);
  return rig.expressions.includes(state.expr) ? state.expr : null;
}
function applyExprPose() {
  for (const [id, b] of built) {
    const { rig, c } = b;
    if (state.pose && rig.poses?.includes(state.pose)) {
      if (c.rebuildPose) {
        b.holder.remove(rig.group);
        setHeadDetail(state.detail);
        b.rig = c.build({ pose: state.pose });
        b.holder.add(b.rig.group);
      } else rig.setPose?.(state.pose);
    }
    const e = exprFor(id, b.rig);
    if (e) {
      b.rig.lockExpr = true;
      b.rig.setExpression?.(e);
      b.rig.expression = e;
    }
  }
  renderPickers();
}
function currentRig() {
  return built.get(state.char)?.rig || built.values().next().value?.rig;
}

// ------------------------------------------------------------------ camera presets
const tmpBox = new THREE.Box3();
function frameInfo() {
  stage.updateMatrixWorld(true);
  tmpBox.setFromObject(stage);
  const c = tmpBox.getCenter(new THREE.Vector3());
  const s = tmpBox.getSize(new THREE.Vector3());
  return { c, s, r: Math.max(s.x, s.y, s.z) * 0.5 };
}
const PRESETS = {
  front: [0, 4],
  "q-left": [40, 10],
  "q-right": [-40, 10],
  side: [90, 4],
  back: [180, 4],
  top: [0, 88],
};
let camAnim = null;
function placeCamera(presetName, instant = false) {
  state.preset = presetName;
  const { c, s, r } = frameInfo();
  let yaw, pitch, dist, target, fov;
  const rig = currentRig();
  if (presetName === "match" && !state.lineup && REFS[state.char]?.match && rig) {
    const m = REFS[state.char].match;
    if (m.expr && !state.expr) {
      rig.lockExpr = true;
      rig.setExpression?.(m.expr);
      rig.expression = m.expr;
    }
    if (rig.head) rig.head.rotation.z = (m.roll || 0) * D2R;
    stage.updateMatrixWorld(true);
    target = new THREE.Vector3();
    if (m.on === "head" && rig.head) rig.head.localToWorld(target.set(0, 0.3, 0));
    else target.copy(c);
    const k = (rig.body?.scale || 1) * (rig.body?.head || 1);
    yaw = m.yaw;
    pitch = m.pitch;
    fov = m.fov;
    dist = m.on === "head" ? m.dist * k : r * m.dist;
  } else {
    if (rig?.head && !state.lineup) rig.head.rotation.z = 0;
    [yaw, pitch] = PRESETS[presetName] || PRESETS["q-left"];
    target = c.clone();
    fov = 35;
    const fit = state.lineup ? Math.max(s.x * 0.62, s.y * 0.75) : r * 1.25;
    dist = fit / Math.tan((fov * D2R) / 2);
  }
  const dir = new THREE.Vector3(Math.sin(yaw * D2R) * Math.cos(pitch * D2R), Math.sin(pitch * D2R), Math.cos(yaw * D2R) * Math.cos(pitch * D2R));
  const to = target.clone().addScaledVector(dir, dist);
  persp.fov = fov;
  persp.updateProjectionMatrix();
  // orthographic frustum fitted to the same framing
  const halfH = (state.lineup ? Math.max(s.y * 0.62, s.x * 0.5 / aspect()) : r * 1.2) * (presetName === "match" ? 0.6 : 1);
  Object.assign(ortho, { left: -halfH * aspect(), right: halfH * aspect(), top: halfH, bottom: -halfH });
  ortho.updateProjectionMatrix();
  if (instant || state.paused) {
    camera.position.copy(to);
    controls.target.copy(target);
    camAnim = null;
  } else camAnim = { from: camera.position.clone(), fromT: controls.target.clone(), to, toT: target, t: 0 };
  // keep the studio shadow frustum tight around the model
  const key = studio.userData.key;
  key.target.position.copy(c);
  key.position.copy(c).add(new THREE.Vector3(3, 5, 4).normalize().multiplyScalar(Math.max(4, r * 4)));
  const e = Math.max(1, r * 1.3);
  Object.assign(key.shadow.camera, { left: -e, right: e, top: e, bottom: -e, near: 0.1, far: r * 10 + 10 });
  key.shadow.camera.updateProjectionMatrix();
  studio.userData.floor.scale.setScalar(Math.max(1, r * 1.6));
  renderPickers();
}
const aspect = () => innerWidth / Math.max(1, innerHeight - (state.ref && innerWidth < 720 ? innerHeight * 0.34 : 0));

// ------------------------------------------------------------------ UI
function btn(label, pressed, onclick, title) {
  const b = document.createElement("button");
  b.type = "button";
  b.textContent = label;
  b.setAttribute("aria-pressed", pressed);
  if (title) b.title = title;
  b.onclick = onclick;
  return b;
}
function renderPickers() {
  const chars = $("chars");
  chars.replaceChildren(
    ...CHARS.map((c) =>
      btn(c.label, !state.lineup && state.char === c.id, () => {
        state.lineup = false;
        state.char = c.id;
        state.expr = null;
        state.pose = null;
        mountSingle();
        placeCamera(state.preset === "match" ? "match" : state.preset);
        renderRef();
      }),
    ),
    btn("All (lineup)", state.lineup, () => {
      state.lineup = true;
      mountLineup();
      placeCamera(state.preset === "match" ? "front" : state.preset);
      renderRef();
    }),
  );
  const rig = currentRig();
  const exprs = ["neutral", "laugh", ...(rig?.expressions || [])];
  $("expr").replaceChildren(...exprs.map((e) => btn(e, (state.expr || "") === e, () => ((state.expr = e), applyExprPose()))));
  $("pose").replaceChildren(...(rig?.poses || []).map((p) => btn(p, (state.pose || rig.pose) === p, () => ((state.pose = p), applyExprPose()))));
  const presets = [["front", "Front"], ["q-left", "¾ left"], ["q-right", "¾ right"], ["side", "Side"], ["back", "Back"], ["top", "Top"]];
  if (!state.lineup && REFS[state.char]?.match) presets.push(["match", `Matched · ${REFS[state.char].src}`]);
  $("presets").replaceChildren(...presets.map(([id, l]) => btn(l, state.preset === id, () => placeCamera(id))));
  for (const [id, on] of [["t-light", state.light === "studio"], ["t-ref", state.ref], ["t-spin", state.spin], ["t-wire", state.wire], ["t-ortho", state.ortho]]) $(id).setAttribute("aria-pressed", on);
  $("t-light").textContent = state.light === "studio" ? "Studio light" : "Scene light";
  $("t-detail").textContent = "Detail: " + state.detail;
}
function renderRef() {
  const panel = $("ref");
  const r = REFS[state.char];
  panel.hidden = !state.ref;
  document.body.dataset.ref = state.ref ? "1" : "0";
  if (!state.ref) return resize();
  if (state.lineup || !r) {
    $("ref-imgs").replaceChildren();
    $("ref-cap").textContent = state.lineup ? "Pick one character to see its reference." : "No reference crop for this character.";
    return resize();
  }
  $("ref-imgs").replaceChildren(
    ...[r.face, r.body].filter(Boolean).map((src) => {
      const img = new Image();
      img.src = src;
      img.alt = `${state.char} reference (${r.src})`;
      img.decoding = "async";
      return img;
    }),
  );
  $("ref-cap").textContent = `Reference · ${r.src}. “Matched” puts the camera at this crop's estimated angle.`;
  resize();
}
function wire(on) {
  for (const m of Object.values(materials)) m.wireframe = on;
}
$("t-light").onclick = () => ((state.light = state.light === "studio" ? "scene" : "studio"), applyLight(), renderPickers());
$("t-ref").onclick = () => ((state.ref = !state.ref), renderRef(), renderPickers());
$("t-spin").onclick = () => ((state.spin = !state.spin), renderPickers());
$("t-wire").onclick = () => ((state.wire = !state.wire), wire(state.wire), renderPickers());
$("t-ortho").onclick = () => {
  state.ortho = !state.ortho;
  const pos = camera.position.clone();
  camera = state.ortho ? ortho : persp;
  camera.position.copy(pos);
  controls.object = camera;
  placeCamera(state.preset, true);
};
$("t-detail").onclick = () => {
  state.detail = state.detail === "low" ? "high" : "low";
  rebuildAll();
};
$("t-hide").onclick = () => document.body.classList.toggle("ui-hidden");

function rebuildAll() {
  $("loading").hidden = false;
  $("loading").textContent = "Building models…";
  requestAnimationFrame(() =>
    requestAnimationFrame(() => {
      state.lineup ? mountLineup() : mountSingle();
      wire(state.wire);
      placeCamera(state.preset, true);
      $("loading").hidden = true;
      ready = true;
    }),
  );
}

function resize() {
  const w = innerWidth,
    h = innerHeight;
  const refH = state.ref && w < 720 ? Math.round(h * 0.34) : 0; // bottom sheet on phones
  renderer.setPixelRatio(Math.min(devicePixelRatio || 1, state.detail === "low" ? 1 : 1.5));
  renderer.setSize(w, h - refH, false);
  canvas.style.height = h - refH + "px";
  persp.aspect = w / (h - refH);
  persp.updateProjectionMatrix();
  if (ready) placeCamera(state.preset, true);
}
addEventListener("resize", resize);

// ------------------------------------------------------------------ loop
let ready = false;
const clock = new THREE.Clock();
let fps = 0,
  acc = 0,
  n = 0;
function frame() {
  requestAnimationFrame(frame);
  if (contextLost) return;
  const dt = Math.min(clock.getDelta(), 0.1);
  if (camAnim) {
    camAnim.t = Math.min(1, camAnim.t + dt * 2.5);
    const k = 1 - (1 - camAnim.t) ** 3;
    camera.position.lerpVectors(camAnim.from, camAnim.to, k);
    controls.target.lerpVectors(camAnim.fromT, camAnim.toT, k);
    if (camAnim.t >= 1) camAnim = null;
  }
  if (state.spin && !state.paused) stage.rotation.y += dt * 0.6;
  else if (!state.spin) stage.rotation.y = 0;
  const k = built.get("kraken");
  if (k && !state.paused) k.rig.setPose(k.rig.pose, clock.elapsedTime);
  controls.update();
  renderer.render(scene, camera);
  acc += dt;
  n++;
  if (acc > 0.5) {
    fps = n / acc;
    acc = 0;
    n = 0;
    const c = countTriangles(scene);
    $("stats").textContent = `${fps.toFixed(0).padStart(3)} fps · ${(c.triangles / 1000).toFixed(0).padStart(4)}k tris · ${String(renderer.info.render.calls).padStart(3)} draws · ${state.detail}`;
  }
}

// diagnostics + QA hooks (threejs-debug-profiler / threejs-qa-release)
window.__THREE_GAME_DIAGNOSTICS__ = {
  renderer: renderer.info,
  get state() {
    return { ...state, ready, errors, loadMs: timing.ready };
  },
};
const timing = { ready: null };
window.__THREE_GAME_TEST_HOOKS__ = {
  setState(name) {
    if (PRESETS[name] || name === "match") {
      placeCamera(name, true);
      return { state: name };
    }
    throw new Error("unknown state " + name);
  },
  setPausedForScreenshot(p) {
    state.paused = !!p;
    return { paused: state.paused };
  },
};
window.__viewer = { state, placeCamera, rebuildAll, loseContext: () => loseExt?.loseContext(), restoreContext: () => loseExt?.restoreContext(), get ready() { return ready; } };

applyLight();
wire(state.wire);
if (Q.get("hud") === "0") document.body.classList.add("ui-hidden", "no-hud");
$("loading").hidden = false;
requestAnimationFrame(frame);
// first frame paints the studio, then the models build
requestAnimationFrame(() =>
  requestAnimationFrame(() => {
    state.lineup ? mountLineup() : mountSingle();
    placeCamera(state.preset, true);
    renderRef();
    resize();
    placeCamera(state.preset, true);
    $("loading").hidden = true;
    ready = true;
    timing.ready = Math.round(performance.now() - T0);
  }),
);
