// Bake v3's approved crew into 2.5D cutout sprites.
//
// Each crewman is built with v3's own builders (smooth mesher, textured heads, the
// captain's approved hat), put in a rest pose, and rendered part by part through an
// orthographic camera from two facings: "q" (three-quarter, facing screen right) and
// "f" (front). Every part is cropped to its pixels and stored with its pivot (the
// joint it turns about) in character space, so the 2D game can rebuild the figure as
// a layered puppet and turn each piece about its own joint. Heads are baked once per
// expression, hands once per shape, and the hanging pieces (sash tails, kerchief
// tails, hat ribbons, epaulette fringes) as separate danglers for secondary motion.
import * as THREE from "three";
import { setMesher, setHeadDetail } from "../v3src/engine/models/chibi.js";
import { buildCaptain } from "../v3src/engine/models/captain.js";
import { buildSailor } from "../v3src/engine/models/sailor.js";
import { buildReviewer } from "../v3src/engine/models/reviewer.js";
import { buildRobot } from "../v3src/engine/models/robot.js";
import * as P from "../v3src/engine/models/props.js";
import { kit } from "../v3src/game/props.js";
import { buildFirstmate } from "../v3src/engine/models/firstmate.js"; // v3's own model (read-only snapshot)

const Q = new URLSearchParams(location.search);
const PX = +(Q.get("px") || 230); // pixels per world unit (the captain stands ~1.45 units)
const FACINGS = { q: 36, f: 0 }; // yaw in degrees toward the camera's right
const PITCH = 7;
const W = 1024, H = 1024;

const canvas = document.createElement("canvas");
canvas.width = W; canvas.height = H;
document.body.appendChild(canvas);
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true, preserveDrawingBuffer: true });
renderer.setPixelRatio(1);
renderer.setSize(W, H, false);
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.setClearColor(0x000000, 0);
const scene = new THREE.Scene();
scene.add(new THREE.HemisphereLight(0x9fc0ff, 0xf0b080, 1.25));
const sun = new THREE.DirectionalLight(0xffd6a0, 3.1);
sun.position.set(-3, 5, 6);
scene.add(sun);
const rim = new THREE.DirectionalLight(0xffe2b8, 1.2);
rim.position.set(4, 3, -4);
scene.add(rim);
const cam = new THREE.OrthographicCamera(-W / 2 / PX, W / 2 / PX, H / 2 / PX, -H / 2 / PX, 0.1, 50);

const scratch = document.createElement("canvas");
scratch.width = W; scratch.height = H;
const sx = scratch.getContext("2d", { willReadFrequently: true });

function aim(yawDeg, targetY) {
  const yaw = (yawDeg * Math.PI) / 180, pitch = (PITCH * Math.PI) / 180, r = 12;
  // the character stays put, facing +z; the camera orbits to its left so it looks screen-right
  cam.position.set(-Math.sin(yaw) * Math.cos(pitch) * r, targetY + Math.sin(pitch) * r, Math.cos(yaw) * Math.cos(pitch) * r);
  cam.lookAt(0, targetY, 0);
  cam.updateMatrixWorld(true);
}
const TY = 0.75; // camera target height (world units)
// world point -> character-space pixels: x right, y down, origin at the feet's centre
function toPx(v) {
  const p = v.clone().project(cam);
  const g = new THREE.Vector3(0, 0, 0).project(cam);
  return [Math.round((p.x - g.x) * (W / 2) * 10) / 10, Math.round(-(p.y - g.y) * (H / 2) * 10) / 10];
}
function depth(v) {
  return v.clone().applyMatrix4(cam.matrixWorldInverse).z; // larger = nearer the camera
}
function snap() {
  renderer.render(scene, cam);
  sx.clearRect(0, 0, W, H);
  sx.drawImage(canvas, 0, 0);
  const d = sx.getImageData(0, 0, W, H).data;
  let x0 = W, y0 = H, x1 = -1, y1 = -1;
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) if (d[(y * W + x) * 4 + 3] > 6) {
    if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y;
  }
  if (x1 < 0) return null;
  x0 = Math.max(0, x0 - 1); y0 = Math.max(0, y0 - 1); x1 = Math.min(W - 1, x1 + 1); y1 = Math.min(H - 1, y1 + 1);
  const w = x1 - x0 + 1, h = y1 - y0 + 1;
  const c = document.createElement("canvas");
  c.width = w; c.height = h;
  c.getContext("2d").drawImage(scratch, x0, y0, w, h, 0, 0, w, h);
  const g = new THREE.Vector3(0, 0, 0).project(cam);
  const gx = (g.x * 0.5 + 0.5) * W, gy = (-g.y * 0.5 + 0.5) * H;
  // crop origin in character space
  return { img: c.toDataURL("image/webp", 0.9), w, h, x: Math.round((x0 - gx) * 10) / 10, y: Math.round((y0 - gy) * 10) / 10 };
}

const DANGLERS = ["sashTails", "kerchiefTails", "ribbons", "fringe_l", "fringe_r"];
function partsOf(rig) {
  const map = new Map();
  map.set(rig.head, "head");
  map.set(rig.torso, "torso");
  map.set(rig.hips, "hips");
  for (const s of ["l", "r"]) {
    map.set(rig.arms[s].sh, "uarm_" + s);
    map.set(rig.arms[s].el, "farm_" + s);
    map.set(rig.arms[s].wrist, "hand_" + s);
    map.set(rig.legs[s], "leg_" + s);
  }
  rig.root.traverse((o) => DANGLERS.includes(o.name) && map.set(o, o.name));
  const propObjs = new Set(Object.values(rig.props || {}).map((p) => p.obj));
  const meshes = [];
  rig.root.traverse((m) => {
    if (!m.isMesh && !m.isPoints) return;
    let n = m, key = null;
    for (; n; n = n.parent) {
      if (propObjs.has(n)) { key = "prop"; break; }
      if (map.has(n)) { key = map.get(n); break; }
    }
    meshes.push([m, key || "root"]);
  });
  return { map, meshes };
}
function isShown(o) { for (let v = o; v; v = v.parent) if (v.visible === false) return false; return true; }

function restPose(rig) {
  const z = (o) => o && o.rotation.set(0, 0, 0);
  z(rig.torso); z(rig.head); z(rig.hips);
  rig.hips.quaternion.identity();
  for (const s of ["l", "r"]) {
    const k = s === "l" ? 1 : -1;
    rig.arms[s].sh.rotation.set(0, 0, (k * 7 * Math.PI) / 180);
    rig.arms[s].el.rotation.set((-8 * Math.PI) / 180, 0, 0);
    const L = rig.legs[s];
    L.rotation.set(0, 0, (k * 2 * Math.PI) / 180);
    L.userData.knee?.quaternion.identity();
    L.userData.ankle?.quaternion.identity();
  }
  rig.root.position.set(0, 0, 0);
  for (const p of Object.values(rig.props || {})) p.obj.visible = false;
  rig.setHand("r", "fist"); rig.setHand("l", "fist");
  rig.root.updateMatrixWorld(true);
}

function bakeRig(id, rig, { exprs, hands = ["fist", "open", "grip", "point"] }) {
  scene.add(rig.root);
  restPose(rig);
  const out = { id, facings: {} };
  const bb = new THREE.Box3().setFromObject(rig.root);
  out.height = Math.round((bb.max.y - bb.min.y) * PX);
  for (const [fk, yaw] of Object.entries(FACINGS)) {
    aim(yaw, TY);
    const { map, meshes } = partsOf(rig);
    const joints = {};
    for (const [node, name] of map) {
      const wp = node.getWorldPosition(new THREE.Vector3());
      joints[name] = { p: toPx(wp), z: Math.round(depth(wp) * 1000) / 1000 };
    }
    // the elbow and wrist positions (children) so the puppet can chain
    for (const s of ["l", "r"]) {
      const k = rig.legs[s].userData.knee, a = rig.legs[s].userData.ankle;
      if (k) joints["knee_" + s] = { p: toPx(k.getWorldPosition(new THREE.Vector3())), z: 0 };
      if (a) joints["ankle_" + s] = { p: toPx(a.getWorldPosition(new THREE.Vector3())), z: 0 };
    }
    const F = { joints, parts: {}, heads: {}, hands: {} };
    const only = (key, extra = () => true) => {
      for (const [m, k] of meshes) m.userData.__v ??= m.visible;
      for (const [m, k] of meshes) m.visible = k === key && m.userData.__v && extra(m);
    };
    const restore = () => { for (const [m] of meshes) m.visible = m.userData.__v; };
    const keys = [...new Set(meshes.map(([, k]) => k))].filter((k) => !["prop", "root", "head", "hand_l", "hand_r"].includes(k));
    for (const k of keys) {
      only(k);
      const s = snap();
      restore();
      if (s) F.parts[k] = s;
    }
    // heads, one per expression (the head joint's subtree, danglers excluded)
    for (const e of exprs) {
      rig.setExpression(e);
      rig.root.updateMatrixWorld(true);
      for (const [m] of meshes) m.userData.__v = m.visible;
      only("head");
      const s = snap();
      restore();
      if (s) F.heads[e] = s;
    }
    rig.setExpression(exprs[0]);
    // hands: each shape, each side
    for (const side of ["l", "r"]) {
      F.hands[side] = {};
      for (const h of hands) {
        rig.setHand(side, h);
        rig.root.updateMatrixWorld(true);
        for (const [m] of meshes) m.userData.__v = m.visible;
        only("hand_" + side);
        const s = snap();
        restore();
        if (s) F.hands[side][h] = s;
      }
      rig.setHand(side, "fist");
    }
    // a full-figure portrait for the roster and the porthole
    for (const [m] of meshes) m.userData.__v = m.visible;
    for (const [m, k] of meshes) m.visible = k !== "prop" && m.userData.__v;
    F.whole = snap();
    restore();
    for (const [m] of meshes) delete m.userData.__v;
    out.facings[fk] = F;
  }
  scene.remove(rig.root);
  return out;
}

function bakeProp(name, obj, { yaw = 36, rot = [0, 0, 0] } = {}) {
  const g = new THREE.Group();
  g.add(obj);
  obj.rotation.set(...rot.map((d) => (d * Math.PI) / 180));
  scene.add(g);
  aim(yaw, 0);
  g.updateMatrixWorld(true);
  const s = snap();
  scene.remove(g);
  return s;
}

// the bold (浮誇) variant: manga proportions on v3's rigs. Smaller heads, longer legs and
// arms, wider shoulders on the captain, bigger hats; the rig groups are rescaled, so the
// parts stay v3's own meshes. (Concept pass: dynamic hair is not reshaped.)
const BOLD = {
  captain: { head: 0.82, legs: 1.3, arms: 1.18, chest: [1.22, 1.08], hat: 1.3 },
  firstmate: { head: 0.76, legs: 1.5, arms: 1.25, chest: [0.94, 1.12], hat: 1.12 },
  "reviewer-1": { head: 0.8, legs: 1.4, arms: 1.2, chest: [0.96, 1.08], hat: 1.15 },
  robot: { head: 1.0, legs: 1.15, arms: 1.15, chest: [1.12, 1.05], hat: 1 },
  default: { head: 0.8, legs: 1.38, arms: 1.2, chest: [1.02, 1.08], hat: 1.18 },
};
function exaggerate(id, rig) {
  const B = BOLD[id] || BOLD.default;
  rig.headScale.scale.multiplyScalar(B.head);
  rig.head.traverse((o) => o.userData?.isHat && o.scale.multiplyScalar(B.hat / B.head > 1 ? B.hat : 1));
  for (const s of ["l", "r"]) {
    rig.legs[s].scale.y *= B.legs;
    rig.arms[s].sh.scale.y *= B.arms;
  }
  rig.hips.position.y *= B.legs;
  rig.torso.scale.x *= B.chest[0];
  rig.torso.scale.z *= B.chest[0];
  rig.torso.scale.y *= B.chest[1];
}
async function main() {
  setMesher("smooth");
  setHeadDetail("high");
  const crew = {
    captain: () => buildCaptain({ pose: "idle" }),
    firstmate: () => buildFirstmate({ pose: "idle" }), // the young officer (the captain's brief), v3's build
    robot: () => buildRobot({ pose: "idle" }), // now a worker (worker-4)
    "reviewer-1": () => buildReviewer({ pose: "idle" }),
    "sailor-hammer": () => buildSailor({ variant: "hammer", pose: "idle", seed: 5 }),
    "sailor-bandana": () => buildSailor({ variant: "bandana", pose: "idle" }),
    "sailor-spyglass": () => buildSailor({ variant: "spyglass", pose: "idle", seed: 7 }),
  };
  const only = Q.get("only");
  const res = { px: PX, facings: FACINGS, crew: {}, props: {} };
  for (const [id, fn] of Object.entries(crew)) {
    if (only && only !== id) continue;
    const rig = fn();
    if (Q.get("variant") === "bold") exaggerate(id, rig);
    const exprs = rig.expressions.filter((e) => e !== "shout" && e !== "blink" && e !== "wink");
    res.crew[id] = bakeRig(id, rig, { exprs });
    res.crew[id].expressions = exprs;
    await new Promise((r) => setTimeout(r, 0));
  }
  if (!only) {
    const props = {
      spyglass: [P.buildSpyglass(), { rot: [0, 90, 0] }],
      hammer: [P.buildHammer(), { rot: [90, 0, 0] }],
      magnifier: [P.buildMagnifier({ scale: 0.038 }), { rot: [90, 0, 0] }],
      map: [P.buildMap({ scale: 0.025, w: 18, d: 13 }), { rot: [70, 0, 0] }],
      scroll: [P.buildScroll({ scale: 0.035, glow: true }), {}],
      stamp: [P.buildStamp(), {}],
      whistle: [P.buildWhistle(), { rot: [0, 90, 0] }],
      cutlass: [kit.cutlass(), { rot: [90, 0, 0] }],
      flag: [kit.flag(), { rot: [0, 90, 0] }],
      crate: [kit.crate(), {}],
      laptop: [P.buildLaptop(), {}],
      criteriaList: [kit.criteriaList(), {}],
      placard: [kit.decisionPlacard(), { rot: [0, 0, 0] }],
      logbook: [kit.logbook(), {}],
      swab: [kit.swab(), { rot: [90, 0, 0] }],
      saw: [kit.saw(), { rot: [90, 0, 0] }],
    };
    for (const [k, [o, opt]] of Object.entries(props)) {
      o.scale.multiplyScalar(1.6);
      res.props[k] = bakeProp(k, o, opt);
    }
  }
  window.__bake = res;
  document.title = "baked";
}
main().catch((e) => { console.error(e); window.__bakeErr = String(e.stack || e); });
