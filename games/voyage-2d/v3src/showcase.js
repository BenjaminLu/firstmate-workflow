// Showcase: (a) hero scene after keyframe 1, (b) lineup turntable of every
// character + the kraken + props, (c) bloom / shadow / detail toggles.
//
// Robustness: scenes build progressively (sky + sea paint first, heavy models
// follow one per frame); every model build is guarded and failures show on
// screen; detail drops to "low" automatically on phones, touch devices, low
// deviceMemory, small screens or after a lost WebGL context, and the context
// is rebuilt when the browser restores it.
//
// URL params: view=hero|lineup, focus=<id>, pose, expr, allpose, bloom=0|1,
// shadows=0|1, spin=0|1, t=<seconds> (freeze), detail=low|high, dpr, hud=0,
// cam=x,y,z & tgt=x,y,z & fov (camera override for captures).
import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { createRenderer, createSky, createLights, createComposer, setShadows } from "./engine/lighting.js";
import { countTriangles, PAL, toMesh } from "./engine/materials.js";
import { VoxelGrid, M } from "./engine/voxel.js";
import { buildFrigate } from "./engine/models/frigate.js";
import { buildCaptain } from "./engine/models/captain.js";
import { buildRobot } from "./engine/models/robot.js";
import { buildSailor } from "./engine/models/sailor.js";
import { buildReviewer } from "./engine/models/reviewer.js";
import { buildCorgi } from "./engine/models/corgi.js";
import { buildParrot } from "./engine/models/parrot.js";
import { buildKraken } from "./engine/models/kraken.js";
import { buildLighthouseIsland, buildSeaStack } from "./engine/models/lighthouse.js";
import { buildSea, buildFarSea } from "./engine/models/sea.js";
import * as Props from "./engine/models/props.js";

const T0 = performance.now();
const Q = new URLSearchParams(location.search);
const FROZEN = Q.has("t") ? parseFloat(Q.get("t")) : null;
const $ = (id) => document.getElementById(id);
const canvas = $("c");

// ------------------------------------------------------------------ detail level
function autoDetail() {
  const reasons = [];
  try {
    if (sessionStorage.getItem("fmv-context-lost")) reasons.push("context lost earlier");
  } catch {}
  if (matchMedia("(pointer: coarse)").matches || navigator.maxTouchPoints > 1) reasons.push("touch device");
  if (navigator.deviceMemory && navigator.deviceMemory <= 4) reasons.push(`deviceMemory ${navigator.deviceMemory} GB`);
  if (Math.min(screen.width, screen.height) < 600 || Math.min(innerWidth, innerHeight) < 500) reasons.push("small screen");
  if (/Android|iPhone|iPad|iPod|Mobile/i.test(navigator.userAgent)) reasons.push("mobile browser");
  return { level: reasons.length ? "low" : "high", reasons };
}
const auto = autoDetail();
const state = {
  view: Q.get("view") === "lineup" ? "lineup" : "hero",
  bloom: Q.get("bloom") !== "0",
  shadows: Q.get("shadows") !== "0",
  spin: Q.get("spin") !== "0",
  focus: Q.get("focus") || null,
  detail: Q.get("detail") === "low" || Q.get("detail") === "high" ? Q.get("detail") : auto.level,
  detailReason: Q.has("detail") ? "url" : auto.reasons.join(", ") || "desktop",
};

// ------------------------------------------------------------------ status + errors on screen
const errors = [];
function showError(what, e) {
  console.warn(`[showcase] ${what} failed:`, e);
  errors.push(`${what}: ${e?.message || e}`);
  const el = $("errors");
  el.hidden = false;
  el.textContent = "Some models could not be built — " + errors.join(" · ");
}
function safe(what, fn) {
  try {
    return fn();
  } catch (e) {
    showError(what, e);
    return null;
  }
}
function setLoading(text) {
  const el = $("loading");
  el.hidden = !text;
  el.textContent = text || "";
}
const nextFrame = () => new Promise((r) => requestAnimationFrame(() => r()));

// ------------------------------------------------------------------ renderer
let renderer;
try {
  renderer = createRenderer(canvas);
} catch (e) {
  showError("WebGL", e);
  throw e;
}
renderer.info.autoReset = false;
let contextLost = false;
canvas.addEventListener("webglcontextlost", (e) => {
  e.preventDefault(); // allow the browser to restore it
  contextLost = true;
  try {
    sessionStorage.setItem("fmv-context-lost", "1");
  } catch {}
  setLoading("Graphics context lost — waiting to restore at low detail…");
});
canvas.addEventListener("webglcontextrestored", () => {
  contextLost = false;
  setDetail("low", "context restored");
});

// ------------------------------------------------------------------ gulls
function buildGull() {
  const g = new VoxelGrid({ jitter: 1, seam: 0.15 });
  g.box(-1, 0, -3, 1, 1, 3, 0xf6f6f8);
  g.box(0, 1, 3, 0, 1, 4, 0xf6f6f8);
  g.set(0, 1, 5, 0xf2b53a);
  g.box(-1, 0, -4, 1, 0, -5, 0xd8dce4);
  for (let i = 1; i <= 7; i++) {
    const y = i < 4 ? 1 + Math.floor(i / 2) : 3 - (i - 4);
    for (const s of [-1, 1]) g.box(s * (1 + i), y, -1, s * (1 + i), y, 1, i > 5 ? 0x3a3f4a : 0xf0f2f6);
  }
  return toMesh(g, { size: 0.08, cast: false });
}

// ------------------------------------------------------------------ hero (keyframe 1)
function heroCamera(tall) {
  // kf1: low, close to the port bow, looking up at the captain; the hull runs off
  // to the right and the sails fill the top
  return tall ? { cam: [-9.5, 3.4, 9.5], tgt: [-2.5, 7.4, -6], fov: 72 } : { cam: [-11.2, 3.3, 5.6], tgt: [0.5, 7.6, -6.5], fov: 52 };
}
function buildHero(detail) {
  const low = detail === "low";
  const scene = new THREE.Scene();
  const SUN = new THREE.Vector3(-0.42, 0.085, -1).normalize();
  scene.fog = new THREE.Fog(0xf0b49a, 120, 460);
  scene.add(createSky(SUN));
  const shipPos = new THREE.Vector3(7, 0, -4);
  const lights = createLights(scene, { sunDir: new THREE.Vector3(-0.62, 0.42, 0.66), shadowCenter: new THREE.Vector3(3, 9, -4), shadowExtent: 21, mapSize: low ? 1024 : 2048 });
  const rim = new THREE.DirectionalLight(0xffa860, 1.3);
  rim.position.copy(SUN).multiplyScalar(100);
  scene.add(rim);

  const near = buildSea(low ? { cell: 0.8, width: 64, depth: 52, center: [-2, -2], amp: 0.62, sunDir: SUN } : { cell: 0.42, width: 76, depth: 60, center: [-2, -2], amp: 0.62, sunDir: SUN });
  const U = near.userData.uniforms;
  const far = buildSea({ cell: low ? 4 : 2.5, width: 380, depth: 320, center: [0, -120], sunDir: SUN, foam: false, hole: low ? [-34, -28, 30, 24] : [-40, -32, 36, 28], uniforms: U });
  scene.add(near, far, buildFarSea({ y: -2.2 }));

  const camera = new THREE.PerspectiveCamera(52, 16 / 9, 0.3, 1200);
  const hc = heroCamera(false);
  camera.position.set(...hc.cam);
  const target = new THREE.Vector3(...hc.tgt);
  camera.lookAt(target);

  const view = { scene, camera, target, lights, crew: {}, ready: false, update: () => {}, ship: null };
  let S = null;
  const gulls = [];
  view.update = (t) => {
    U.uTime.value = t;
    if (S) {
      S.position.y = shipPos.y + Math.sin(t * 0.9) * 0.08;
      S.rotation.z = Math.sin(t * 0.7) * 0.012;
      S.rotation.x = Math.sin(t * 0.55 + 1) * 0.01;
    }
    gulls.forEach((g, i) => {
      g.position.x += Math.sin(t * 0.3 + i) * 0.004;
      g.position.y += Math.sin(t * 1.3 + i) * 0.003;
    });
  };

  // heavy parts arrive one per frame so the first paint is quick
  view.building = (async () => {
    setLoading("Building the frigate…");
    await nextFrame();
    const ship = safe("frigate", () => buildFrigate({ lod: detail, lanternLights: !low }));
    if (ship) {
      S = ship.group;
      view.ship = ship;
      S.position.copy(shipPos);
      S.rotation.y = +(Q.get("rot") || Math.PI - 0.16);
      scene.add(S);
      U.uShip.value.set(shipPos.x, shipPos.z, Math.cos(-S.rotation.y), Math.sin(-S.rotation.y));
      U.uShipSize.value.set(13.4, 3.7, 1);
    }
    setLoading("Mustering the crew…");
    await nextFrame();
    if (S) {
      const sp = S.userData.spots;
      const at = S.userData.spotAt;
      const OUT = Math.PI; // a character's +z points out over the starboard rail
      const put = (what, fn, p, ry = 0, sc = 1.45) =>
        safe(what, () => {
          const rig = fn();
          rig.group.position.copy(p);
          rig.group.rotation.y = ry;
          rig.group.scale.setScalar(sc);
          S.add(rig.group);
          view.crew[what] = rig;
          return rig;
        });
      // the captain stands on a crate at the bow so the pointing arm clears the rail
      const capSpot = at(53, -1, 4.2);
      const crate = Props.buildCrate({ scale: 0.06, w: 9, h: 6, d: 9 });
      crate.position.copy(capSpot);
      S.add(crate);
      put("captain", () => buildCaptain({ pose: "point" }), capSpot.clone().add(new THREE.Vector3(0, 0.36, 0)), OUT + 0.35, 1.5);
      put("spyglass sailor", () => buildSailor({ variant: "spyglass", pose: "work" }), at(59, -1, 4), OUT + 0.9);
      put("corgi", () => buildCorgi({ pose: "sit" }), at(46, -1, 3), OUT + 0.25, 1.5);
      put("robot", () => buildRobot({ pose: "wave", expression: "eyes" }), at(35, -1, 4), OUT + 0.15);
      put("hammer sailor", () => buildSailor({ variant: "hammer", pose: "cheer" }), at(29, -1, 4), OUT + 0.05);
      put("laptop sailor", () => buildSailor({ variant: "laptop", pose: "idle", seed: 3 }), at(22, -1, 4), OUT - 0.05);
      put("bandana sailor", () => buildSailor({ variant: "bandana", pose: "cheer" }), at(14, -1, 4), OUT - 0.1);
      put("wave sailor", () => buildSailor({ variant: "hammer", pose: "wave", seed: 9 }), at(-4, -1, 4), OUT - 0.2);
      put("wheel sailor", () => buildSailor({ variant: "spyglass", pose: "idle", seed: 4 }), sp.wheel.clone(), Math.PI / 2 + 0.4);
      put("reviewer", () => buildReviewer({ pose: "read" }), at(-38, -1, 4), OUT - 0.4);
      const parrot = put("parrot", () => buildParrot({ pose: "perch" }), at(8, -1, 1.2).add(new THREE.Vector3(0, 5 * 0.2 + 0.1, 0)), OUT - 0.5, 1.8);
      void parrot;
    }
    setLoading("Raising the lighthouse…");
    await nextFrame();
    const island = safe("lighthouse island", () => buildLighthouseIsland({ lod: detail }));
    if (island) {
      island.group.position.set(-34, 0, -64);
      island.group.rotation.y = 0.5;
      scene.add(island.group);
      U.uIslands.value[0].set(-34, -64, 9.5, 1);
    }
    const stacks = [
      [-20, -120, 11, 34, 8, false],
      [-6, -140, 12, 26, 7, true],
      [12, -150, 13, 30, 9, false],
      [-44, -104, 14, 20, 6, false],
      [28, -170, 15, 38, 10, false],
    ];
    for (const [x, z, seed, h, r, arch] of stacks) {
      const st = safe("sea stack", () => buildSeaStack({ seed, h, r, arch, scale: 0.55, lod: detail }));
      if (!st) continue;
      st.position.set(x, -1, z);
      scene.add(st);
    }
    for (const [x, y, z, s] of [[-14, 16, -20, 1], [-6, 21, -30, 0.9], [-22, 12, -40, 0.8], [2, 25, -24, 1.1], [-30, 18, -60, 1.2]]) {
      const gm = buildGull();
      gm.position.set(x, y, z);
      gm.scale.setScalar(s);
      gm.rotation.y = 0.8;
      scene.add(gm);
      gulls.push(gm);
    }
    setShadows(renderer, scene, state.shadows);
    view.ready = true;
    setLoading("");
  })();
  return view;
}

// ------------------------------------------------------------------ lineup
const LINEUP = [
  { id: "captain", label: "Captain", build: (o) => buildCaptain(o) },
  { id: "robot", label: "Robot", build: (o) => buildRobot(o) },
  { id: "sailor-bandana", label: "Sailor · bandana", build: (o) => buildSailor({ variant: "bandana", ...o }) },
  { id: "sailor-laptop", label: "Sailor · laptop", build: (o) => buildSailor({ variant: "laptop", ...o, seed: 3 }) },
  { id: "sailor-hammer", label: "Sailor · hammer", build: (o) => buildSailor({ variant: "hammer", ...o, seed: 5 }) },
  { id: "sailor-spyglass", label: "Sailor · spyglass", build: (o) => buildSailor({ variant: "spyglass", ...o, seed: 7 }) },
  { id: "reviewer", label: "Reviewer", build: (o) => buildReviewer(o) },
  { id: "corgi", label: "Corgi", build: (o) => buildCorgi(o) },
  { id: "parrot", label: "Parrot", build: (o) => buildParrot(o) },
  { id: "kraken", label: "Kraken", build: (o) => buildKraken({ ...o, lod: state.detail }), big: true },
];

function pedestal(r = 9) {
  const g = new VoxelGrid({ jitter: 3, seam: 0.35 });
  for (let x = -r; x <= r; x++)
    for (let z = -r; z <= r; z++) {
      const d = Math.hypot(x, z);
      if (d > r + 0.3) continue;
      g.set(x, 0, z, d > r - 1 ? PAL.gold : Math.floor((x + 20) / 2) % 2 ? PAL.deck : PAL.deckB, d > r - 1 ? M.METAL : M.LIT);
      if (d > r - 1.5) g.set(x, -1, z, PAL.woodDark);
    }
  return toMesh(g, { size: 0.1 });
}

function buildLineup(detail) {
  const low = detail === "low";
  const scene = new THREE.Scene();
  const SUN = new THREE.Vector3(-0.85, 0.1, -0.5).normalize();
  scene.fog = new THREE.Fog(0xe7b6c0, 40, 260);
  scene.add(createSky(SUN));
  const lights = createLights(scene, { sunDir: new THREE.Vector3(0.45, 0.55, 0.7), shadowCenter: new THREE.Vector3(0, 2, -2), shadowExtent: 16, mapSize: low ? 1024 : 2048 });
  const sea = buildSea({ cell: low ? 0.8 : 0.5, width: 70, depth: 60, center: [0, -10], amp: 0.35, sunDir: SUN });
  const U = sea.userData.uniforms;
  scene.add(sea, buildFarSea({ y: -2.4 }));

  const stageG = new VoxelGrid({ jitter: 3, seam: 0.35, seed: 5 });
  for (let x = -60; x <= 60; x++)
    for (let z = -22; z <= 16; z++) {
      const plank = Math.floor((x + 80) / 3);
      const edge = Math.abs(x) >= 59 || z <= -21 || z >= 15;
      stageG.set(x, 0, z, edge ? PAL.woodDeep : plank % 2 ? PAL.deck : PAL.deckB);
      if (edge) stageG.set(x, -1, z, PAL.woodDark), stageG.set(x, -2, z, PAL.woodDark);
      if (edge && (x + 60) % 8 === 0) stageG.set(x, 1, z, PAL.iron, M.METAL);
    }
  const stage = toMesh(stageG, { size: 0.2 });
  stage.position.y = 0.6;
  scene.add(stage);
  const floorY = 0.7;

  const camera = new THREE.PerspectiveCamera(40, 16 / 9, 0.1, 900);
  camera.position.set(0, 4.8, 16.5);
  const target = new THREE.Vector3(0, 2.3, -3);
  camera.lookAt(target);
  const entries = [];
  const view = { scene, camera, target, lights, entries, ready: false, update: () => {} };
  view.update = (t, dt) => {
    U.uTime.value = t;
    for (const e of entries) {
      if (!e.rig) continue;
      if (e.big) {
        e.rig.setPose(e.rig.pose, t);
        e.turn.rotation.y = state.spin && !state.focus ? Math.sin(t * 0.2) * 0.35 : 0;
      } else if (state.spin && state.focus !== e.id) e.turn.rotation.y += dt * 0.6;
      else e.turn.rotation.y = 0;
    }
  };

  view.building = (async () => {
    const chars = LINEUP.filter((e) => !e.big);
    for (const [i, e] of chars.entries()) {
      setLoading(`Building ${e.label}…`);
      if (i % 3 === 0) await nextFrame();
      const n = chars.length;
      const turn = new THREE.Group();
      turn.position.set((i - (n - 1) / 2) * 2.35, floorY, -1.2 - Math.abs(i - (n - 1) / 2) * 0.3);
      turn.add(pedestal(e.id === "parrot" || e.id === "corgi" ? 7 : 9));
      scene.add(turn);
      const holder = new THREE.Group();
      holder.position.y = 0.1;
      turn.add(holder);
      const entry = { ...e, turn, holder, rig: null };
      mount(entry, {});
      if (e.id === "parrot" && entry.rig) {
        const pg = new VoxelGrid({ jitter: 2 });
        pg.box(0, 0, 0, 0, 9, 0, 0x6b4226);
        pg.box(-3, 10, 0, 3, 10, 0, 0x6b4226);
        holder.add(toMesh(pg, { size: 0.1 }));
        entry.rig.group.position.y = 1.05;
      }
      entries.push(entry);
    }
    setLoading("Summoning the kraken…");
    await nextFrame();
    const kr = LINEUP.find((e) => e.big);
    const kTurn = new THREE.Group();
    kTurn.position.set(0, -0.4, -24);
    scene.add(kTurn);
    const kEntry = { ...kr, turn: kTurn, holder: kTurn, rig: null };
    mount(kEntry, {});
    entries.push(kEntry);

    setLoading("Stocking the hold…");
    await nextFrame();
    const props = [
      [() => Props.buildCrate({ scale: 0.08 }), -9.5],
      [() => Props.buildBarrel({ scale: 0.07 }), -8.2],
      [() => Props.buildChest({ scale: 0.07 }), -6.7],
      [() => Props.buildGlobe({ scale: 0.06 }), -5.2],
      [() => Props.buildMap({ scale: 0.04 }), -3.9],
      [() => Props.buildStamp({ scale: 0.06 }), -2.8, 0.5],
      [() => Props.buildScroll({ scale: 0.05 }), -1.9, 0.15],
      [() => Props.buildScroll({ scale: 0.05, glow: true, open: true }), -0.9, 0.6],
      [() => Props.buildFlag({ text: "WORKER", color: 0x2a45c8, dark: 0x1a2c8a, scale: 0.04, pole: 44 }), -11.6, 0, -3.4],
      [() => Props.buildFlag({ text: "REVIEWER", color: 0x2f9a4a, dark: 0x1f6b34, scale: 0.04, pole: 44 }), 9.2, 0, -3.4],
      [() => Props.buildScroll({ scale: 0.04, glow: true }), 0.4, 0.2],
      [() => Props.buildLaptop({ scale: 0.05 }), 1.6, 0.05],
      [() => Props.buildHammer({ scale: 0.06 }), 2.6, 0.1],
      [() => Props.buildSpyglass({ scale: 0.06 }), 3.5, 0.15],
      [() => Props.buildMagnifier({ scale: 0.05 }), 4.3, 0.35],
      [() => Props.buildLantern({ scale: 0.06, light: true }), 5.2],
      [() => Props.buildLantern({ scale: 0.045, light: false }), 5.9],
      [() => Props.buildCannon({ scale: 0.08 }), 7.2, 0.35],
      [() => Props.buildAnchor({ scale: 0.07 }), 8.8, 1.05],
      [() => Props.buildWheel({ scale: 0.05 }), 10.3, 0.75],
    ];
    for (const [fn, x, y = 0, z = 2.1] of props) {
      const o = safe("prop", fn);
      if (!o) continue;
      o.position.set(x, floorY + y, z);
      if (o.name === "cannon") o.rotation.y = 0.8;
      scene.add(o);
    }
    setShadows(renderer, scene, state.shadows);
    view.ready = true;
    setLoading("");
  })();
  return view;
}

function mount(entry, { pose, expr }) {
  if (entry.rig) entry.holder.remove(entry.rig.group);
  const rig = safe(entry.label, () => entry.build({ pose, expression: expr }));
  entry.rig = rig;
  if (!rig) return;
  entry.holder.add(rig.group);
  rig.group.scale.setScalar(entry.id === "corgi" ? 1.25 : 1);
}
function applyPose(entry, pose) {
  const r = entry.rig;
  if (!r) return;
  if (r.setPose && entry.id !== "corgi") safe(entry.label + " pose", () => r.setPose(pose));
  else {
    const y = r.group.position.y;
    mount(entry, { pose, expr: r.expression });
    if (entry.rig) entry.rig.group.position.y = y;
  }
  entry.pose = pose;
}

// ------------------------------------------------------------------ views, detail, resize
let hero = null,
  lineup = null;
const views = {
  hero: () => (hero ||= buildHero(state.detail)),
  lineup: () => (lineup ||= buildLineup(state.detail)),
};
let active = views[state.view]();
const controls = new OrbitControls(active.camera, canvas);
controls.enableDamping = true;
controls.target.copy(active.target);
controls.maxDistance = 120;

let comp = null;
function rebuildComposer() {
  comp?.composer.dispose?.();
  comp = createComposer(renderer, active.scene, active.camera, { strength: 0.42, radius: 0.35, threshold: 1.0 });
}
let dprCap = Q.has("dpr") ? +Q.get("dpr") : state.detail === "low" ? 1 : 1.5;
let slowFor = 0;
function adaptDpr(dt, fpsNow) {
  if (FROZEN !== null || dprCap <= 1) return;
  slowFor = fpsNow > 0 && fpsNow < 50 ? slowFor + dt : 0;
  if (slowFor > 2) {
    dprCap = 1;
    slowFor = 0;
    resize();
  }
}
function resize() {
  const w = window.innerWidth,
    h = window.innerHeight;
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, dprCap));
  renderer.setSize(w, h, false);
  active.camera.aspect = w / h;
  if (active === hero) {
    const tall = w / h < 1;
    const hc = heroCamera(tall);
    active.camera.fov = Q.has("fov") ? +Q.get("fov") : hc.fov;
    if (!Q.has("cam")) {
      active.camera.position.set(...hc.cam);
      active.target.set(...hc.tgt);
    } else {
      active.camera.position.set(...Q.get("cam").split(",").map(Number));
      if (Q.has("tgt")) active.target.set(...Q.get("tgt").split(",").map(Number));
    }
    controls.target.copy(active.target);
    active.camera.lookAt(active.target);
  }
  if (active === lineup && !state.focus) active.camera.fov = w / h < 1 ? 64 : 40;
  active.camera.updateProjectionMatrix();
  rebuildComposer();
}
function setView(v) {
  state.view = v;
  active = views[v]();
  controls.object = active.camera;
  controls.target.copy(active.target);
  $("v-hero").setAttribute("aria-pressed", v === "hero");
  $("v-lineup").setAttribute("aria-pressed", v === "lineup");
  $("lineup-ui").hidden = v !== "lineup";
  document.body.dataset.view = v;
  setShadows(renderer, active.scene, state.shadows);
  resize();
  active.building?.then(() => {
    if (v === "lineup") renderChips();
  });
}
function disposeScene(view) {
  view?.scene.traverse((o) => {
    if (o.geometry) o.geometry.dispose();
  });
}
function setDetail(level, why) {
  state.detail = level;
  state.detailReason = why;
  dprCap = level === "low" ? 1 : Q.has("dpr") ? +Q.get("dpr") : 1.5;
  disposeScene(hero);
  disposeScene(lineup);
  hero = lineup = null;
  $("q-detail").textContent = `Detail: ${level}`;
  $("q-detail").title = `detail ${level} (${why})`;
  setView(state.view);
}

// closeup framing for a lineup entry
function focusOn(id) {
  state.focus = id;
  if (!lineup) return;
  const cam = lineup.camera;
  if (!id) {
    cam.position.set(0, 4.8, 16.5);
    lineup.target.set(0, 2.3, -3);
  } else {
    const e = lineup.entries.find((x) => x.id === id);
    if (!e) return;
    const p = new THREE.Vector3();
    e.turn.getWorldPosition(p);
    if (e.big) {
      cam.position.set(p.x + 9, p.y + 9, p.z + 40);
      lineup.target.set(p.x, p.y + 6.5, p.z);
    } else {
      const h = id === "corgi" ? 0.7 : id === "parrot" ? 1.45 : 1.15;
      cam.position.set(p.x + 0.9, p.y + h + 0.25, p.z + 4.8);
      lineup.target.set(p.x, p.y + h, p.z);
    }
  }
  cam.fov = id ? 30 : 40;
  cam.updateProjectionMatrix();
  controls.target.copy(lineup.target);
  renderChips();
}

// ------------------------------------------------------------------ UI
function current() {
  if (!lineup) return null;
  return lineup.entries.find((e) => e.id === (state.focus || "captain"));
}
function renderChips() {
  if (!lineup) return;
  const chips = $("chips");
  chips.innerHTML = "";
  const all = document.createElement("button");
  all.textContent = "All";
  all.setAttribute("aria-pressed", !state.focus);
  all.onclick = () => focusOn(null);
  chips.append(all);
  for (const e of lineup.entries) {
    const b = document.createElement("button");
    b.textContent = e.label;
    b.setAttribute("aria-pressed", state.focus === e.id);
    b.onclick = () => focusOn(e.id);
    chips.append(b);
  }
  const c = current();
  $("now").innerHTML = c?.rig ? `<b>${c.label}</b> · pose <b>${c.rig.pose || c.pose || c.rig.poses[0]}</b> · expression <b>${c.rig.expression || c.rig.expressions[0]}</b> · poses: ${c.rig.poses.join(", ")}` : "";
}
function cyclePose(e) {
  if (!e?.rig) return;
  const list = e.rig.poses;
  const cur = list.indexOf(e.rig.pose ?? e.pose ?? list[0]);
  applyPose(e, list[(cur + 1) % list.length]);
}
function cycleExpr(e) {
  if (!e?.rig) return;
  const list = e.rig.expressions;
  const next = list[(list.indexOf(e.rig.expression ?? list[0]) + 1) % list.length];
  e.rig.lockExpr = true;
  safe(e.label + " expression", () => e.rig.setExpression(next));
  e.rig.expression = next;
}
$("b-pose").onclick = () => (cyclePose(current()), renderChips());
$("b-expr").onclick = () => (cycleExpr(current()), renderChips());
$("b-all").onclick = () => {
  lineup?.entries.forEach((e) => cyclePose(e));
  renderChips();
};
$("b-spin").onclick = () => {
  state.spin = !state.spin;
  $("b-spin").setAttribute("aria-pressed", state.spin);
};
$("v-hero").onclick = () => setView("hero");
$("v-lineup").onclick = () => setView("lineup");
$("q-bloom").onclick = () => {
  state.bloom = !state.bloom;
  $("q-bloom").setAttribute("aria-pressed", state.bloom);
};
$("q-shadows").onclick = () => {
  state.shadows = !state.shadows;
  $("q-shadows").setAttribute("aria-pressed", state.shadows);
  setShadows(renderer, active.scene, state.shadows);
};
$("q-detail").onclick = () => setDetail(state.detail === "low" ? "high" : "low", "toggle");
$("q-bloom").setAttribute("aria-pressed", state.bloom);
$("q-shadows").setAttribute("aria-pressed", state.shadows);
$("q-detail").textContent = `Detail: ${state.detail}`;
$("q-detail").title = `detail ${state.detail} (${state.detailReason})`;
$("b-spin").setAttribute("aria-pressed", state.spin);
window.addEventListener("resize", resize);

setView(state.view);
if (Q.get("hud") === "0") document.querySelectorAll(".hud, .controls, .stats, #loading").forEach((el) => (el.style.display = "none"));
active.building.then(() => {
  if (state.view !== "lineup") return;
  if (state.focus) focusOn(state.focus);
  if (Q.has("cam")) {
    lineup.camera.position.set(...Q.get("cam").split(",").map(Number));
    if (Q.has("tgt")) lineup.target.set(...Q.get("tgt").split(",").map(Number));
    controls.target.copy(lineup.target);
  }
  const e = current();
  if (e && Q.get("pose")) applyPose(e, Q.get("pose"));
  if (e?.rig && Q.get("expr")) {
    e.rig.lockExpr = true;
    e.rig.setExpression(Q.get("expr"));
    e.rig.expression = Q.get("expr");
  }
  if (Q.get("allpose")) lineup.entries.forEach((x) => x.rig?.poses.includes(Q.get("allpose")) && applyPose(x, Q.get("allpose")));
  renderChips();
});

// ------------------------------------------------------------------ loop
const clock = new THREE.Clock();
let fpsAcc = 0,
  fpsN = 0,
  fps = 0,
  statT = 0,
  frames = 0,
  readyFrames = 0;
const timing = { firstFrame: null, ready: null };
function frame() {
  requestAnimationFrame(frame);
  if (contextLost) return;
  const dt = Math.min(clock.getDelta(), 0.1);
  const t = FROZEN ?? clock.elapsedTime;
  renderer.info.reset();
  try {
    active.update(t, FROZEN !== null ? 0 : dt);
    controls.update();
    if (state.bloom) comp.composer.render();
    else renderer.render(active.scene, active.camera);
  } catch (e) {
    if (!errors.length) showError("render", e);
  }
  frames++;
  if (frames === 1) timing.firstFrame = Math.round(performance.now() - T0);
  fpsAcc += dt;
  fpsN++;
  if (fpsAcc > 0.5) {
    fps = fpsN / fpsAcc;
    fpsAcc = 0;
    fpsN = 0;
  }
  adaptDpr(dt, fps);
  statT += dt;
  if (statT > 0.5 || frames === 2 || readyFrames === 1) {
    statT = 0;
    const c = countTriangles(active.scene);
    const info = renderer.info.render;
    $("stats").textContent = `${fps.toFixed(0)} fps · ${(c.triangles / 1000).toFixed(0)}k tris · ${info.calls} draws · dpr ${renderer.getPixelRatio()} · detail ${state.detail}`;
    window.__showcase.stats = { fps, ...c, calls: info.calls, dpr: renderer.getPixelRatio(), detail: state.detail, detailReason: state.detailReason };
  }
  if (active.ready) {
    readyFrames++;
    if (readyFrames === 1) timing.ready = Math.round(performance.now() - T0);
    if (readyFrames === 3) window.__showcase.ready = true;
  }
}
window.__showcase = {
  ready: false,
  state,
  timing,
  errors,
  setView,
  setDetail,
  focusOn,
  cyclePose: () => cyclePose(current()),
  cycleExpr: () => cycleExpr(current()),
  get lineup() {
    return lineup;
  },
  get hero() {
    return hero;
  },
  loseContext: () => renderer.getContext().getExtension("WEBGL_lose_context")?.loseContext(),
  restoreContext: () => renderer.getContext().getExtension("WEBGL_lose_context")?.restoreContext(),
};
requestAnimationFrame(frame);
