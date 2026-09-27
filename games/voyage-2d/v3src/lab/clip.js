// Clipping check (p4: the captain, "the faces clip"). Two measurements per character:
//
// 1. Heads, image-space poke-through. Each head is rendered in an ID pass (flat colour
//    per part: skin, hair, face hair = brows and moustache, beard, hat, hat ribbons,
//    eyes/glasses texture stays skin) from 16 views (8 yaws x 2 pitches) for every
//    expression. A poke-through is a small connected island of one part that is almost
//    entirely surrounded by another part it should lie under or over: skin showing
//    through hair, beard, hat or a brow; hair poking out through a hat; a stray hair or
//    beard shard stuck on the face. Islands smaller than MIN_PX are noise and ignored.
// 2. Bodies, geometric penetration. The character is posed by the game's own CrewMan
//    through every ritual and loop at several key times; hand and forearm vertices are
//    tested against the torso's closed body mesh (ray parity) and the deepest one is
//    reported, in head units (1 HU = the voxel face unit).
//
// ?who=captain|reviewer|sailor-*|robot  &views=16  &sheet=1 (draw the beauty sheet)
// window.__clip.run() -> { who, heads: {expr: {islands, worst}}, body: {...} }
import * as THREE from "three";
import { createRenderer, createSky, createLights } from "../engine/lighting.js";
import { setMesher } from "../engine/models/chibi.js";
import { buildCaptain } from "../engine/models/captain.js";
import { buildSailor } from "../engine/models/sailor.js";
import { buildReviewer } from "../engine/models/reviewer.js";
import { buildRobot } from "../engine/models/robot.js";
import { CrewMan } from "../game/crew.js";

const Q = new URLSearchParams(location.search);
const who = Q.get("who") || "captain";
const S = +(Q.get("px") || 256);
const renderer = createRenderer(document.getElementById("c"));
renderer.setPixelRatio(1);
renderer.setSize(S, S, false);
const scene = new THREE.Scene();
const sky = createSky(new THREE.Vector3(-0.6, 0.2, -0.7));
scene.add(sky);
createLights(scene, { sunDir: new THREE.Vector3(0.5, 0.5, 0.75).normalize(), shadowExtent: 6, mapSize: 1024 });
const B = {
  captain: () => buildCaptain({ pose: "idle" }),
  reviewer: () => buildReviewer({ pose: "idle" }),
  robot: () => buildRobot({ pose: "idle" }),
  "sailor-hammer": () => buildSailor({ variant: "hammer", pose: "idle", seed: 5 }),
  "sailor-bandana": () => buildSailor({ variant: "bandana", pose: "idle" }),
  "sailor-laptop": () => buildSailor({ variant: "laptop", pose: "idle", seed: 3 }),
  "sailor-spyglass": () => buildSailor({ variant: "spyglass", pose: "idle", seed: 7 }),
};
setMesher("smooth");
const rig = B[who]();
setMesher("voxel");
scene.add(rig.group);
rig.lockExpr = true;
const camera = new THREE.PerspectiveCamera(30, 1, 0.01, 100);

const up = (o, pred) => {
  for (let p = o; p; p = p.parent) if (pred(p)) return p;
  return null;
};
// the part a head mesh belongs to
function headClass(o, skull) {
  if (o === skull) return "skin";
  if (skull && o.parent === skull.parent && o.geometry?.type === "SphereGeometry") return "skin"; // the nose
  if (up(o, (p) => p.name === "ribbons")) return "ribbon";
  if (up(o, (p) => p.userData?.isHat)) return "hat";
  if (up(o, (p) => p.name === "beardPivot")) return "beard";
  const part = up(o, (p) => p.userData?.part)?.userData.part;
  if (part === "beard") return "facehair";
  if (part === "hair") return "hair";
  if (part === "ear") return "skin";
  return up(o, (p) => p === rig.head) ? "headother" : "body";
}
const COL = { skin: [255, 0, 255], hair: [0, 0, 255], facehair: [255, 128, 0], beard: [128, 64, 0], hat: [0, 255, 255], ribbon: [255, 255, 0], headother: [255, 255, 255], body: [0, 0, 0], bg: [0, 255, 0] };
const CLS = Object.keys(COL);
const MATS = Object.fromEntries(CLS.map((k) => [k, new THREE.MeshBasicMaterial({ color: new THREE.Color(COL[k][0] / 255, COL[k][1] / 255, COL[k][2] / 255), side: THREE.DoubleSide })]));
// which islands are faults: [island class, surrounding class]
export const FAULTS = [
  ["skin", "hair"], ["skin", "hat"], ["skin", "beard"], ["skin", "facehair"], ["skin", "ribbon"],
  ["hair", "hat"], ["hair", "skin"], ["hair", "facehair"], ["beard", "skin"], ["beard", "facehair"], ["facehair", "beard"],
  ["hair", "beard"], ["body", "skin"], ["hat", "hair"],
];
const MIN_PX = 3; // below this an island is antialiasing noise, not geometry

function visibleSkull() {
  let skull = null;
  rig.head.traverse((o) => {
    if (skull || !o.isMesh || !o.material?.map?.isDataTexture) return;
    if (up(o, (p) => p.visible === false)) return;
    skull = o;
  });
  return skull;
}
function place(yaw, pitch, dist = 2.2) {
  rig.group.updateMatrixWorld(true);
  const hp = new THREE.Vector3(0, 0.3, 0);
  rig.head.localToWorld(hp);
  const k = (rig.body?.scale || 1) * (rig.body?.head || 1);
  const d = dist * k, R = Math.PI / 180;
  camera.position.set(hp.x + Math.sin(yaw * R) * Math.cos(pitch * R) * d, hp.y + Math.sin(pitch * R) * d, hp.z + Math.cos(yaw * R) * Math.cos(pitch * R) * d);
  camera.lookAt(hp);
  camera.updateMatrixWorld(true);
}
const rt = new THREE.WebGLRenderTarget(S, S);
const saved = new Map();
function idRender() {
  const skull = visibleSkull();
  scene.traverse((o) => {
    if (!o.isMesh) return;
    saved.set(o, o.material);
    o.material = MATS[headClass(o, skull)];
  });
  sky.visible = false;
  scene.background = new THREE.Color(0x00ff00);
  const tm = renderer.toneMapping;
  renderer.toneMapping = THREE.NoToneMapping;
  renderer.setRenderTarget(rt);
  renderer.render(scene, camera);
  const buf = new Uint8Array(S * S * 4);
  renderer.readRenderTargetPixels(rt, 0, 0, S, S, buf);
  renderer.setRenderTarget(null);
  renderer.toneMapping = tm;
  for (const [o, m] of saved) o.material = m;
  saved.clear();
  sky.visible = true;
  scene.background = null;
  // classify each pixel to the nearest class colour
  const cls = new Uint8Array(S * S);
  for (let i = 0; i < S * S; i++) {
    let best = 0, bd = 1e9;
    for (let c = 0; c < CLS.length; c++) {
      const [r, g, b] = COL[CLS[c]];
      const d = Math.abs(buf[i * 4] - r) + Math.abs(buf[i * 4 + 1] - g) + Math.abs(buf[i * 4 + 2] - b);
      if (d < bd) (bd = d), (best = c);
    }
    cls[i] = best;
  }
  return cls;
}
// small islands of one class enclosed by another
function islands(cls) {
  const seen = new Int32Array(S * S).fill(-1), out = [];
  const stack = [];
  for (let s = 0; s < S * S; s++) {
    if (seen[s] >= 0) continue;
    const c = cls[s];
    const pix = [];
    stack.push(s);
    seen[s] = s;
    const border = new Map();
    let edge = false;
    while (stack.length) {
      const i = stack.pop();
      pix.push(i);
      const x = i % S, y = (i / S) | 0;
      if (x === 0 || y === 0 || x === S - 1 || y === S - 1) edge = true;
      for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
        const X = x + dx, Y = y + dy;
        if (X < 0 || Y < 0 || X >= S || Y >= S) continue;
        const j = Y * S + X;
        if (cls[j] === c) {
          if (seen[j] < 0) (seen[j] = s), stack.push(j);
        } else border.set(cls[j], (border.get(cls[j]) || 0) + 1);
      }
      if (pix.length > S * S * 0.02) break; // big regions are not islands; stop early
    }
    // finish flooding so the region is not revisited
    while (stack.length) seen[stack.pop()] = s;
    if (edge || pix.length > S * S * 0.02 || pix.length < MIN_PX) continue;
    let tot = 0, top = -1, topN = 0;
    for (const [k, n] of border) {
      tot += n;
      if (n > topN) (topN = n), (top = k);
    }
    if (topN / tot < 0.85) continue;
    const pair = [CLS[c], CLS[top]];
    if (!FAULTS.some(([a, b]) => a === pair[0] && b === pair[1])) continue;
    const x0 = pix.reduce((m, i) => Math.min(m, i % S), S), y0 = pix.reduce((m, i) => Math.min(m, (i / S) | 0), S);
    out.push({ pair: pair.join(">"), px: pix.length, at: [x0, S - 1 - y0] });
  }
  return out;
}
const YAWS = [0, 40, 90, 140, 180, 220, 270, 320];
const PITCHES = [10, -12];
function heads() {
  const res = {};
  for (const e of rig.expressions) {
    rig.setExpression(e);
    const views = [];
    for (const p of PITCHES)
      for (const y of YAWS) {
        place(y, p);
        const isl = islands(idRender());
        if (isl.length) views.push({ yaw: y, pitch: p, islands: isl });
      }
    const n = views.reduce((a, v) => a + v.islands.length, 0);
    const px = views.reduce((a, v) => a + v.islands.reduce((b, i) => b + i.px, 0), 0);
    const pairs = {};
    for (const v of views) for (const i of v.islands) pairs[i.pair] = (pairs[i.pair] || 0) + i.px;
    res[e] = { islands: n, px, pairs, views };
  }
  return res;
}
// ---------------------------------------------------------------- bodies
// ray parity against the torso's own meshes (closed lofts), in the torso's local space
const ray = new THREE.Raycaster();
function torsoMeshes() {
  const out = [];
  rig.torso.traverse((o) => {
    if (!o.isMesh) return;
    if (up(o, (p) => p === rig.head || p === rig.arms?.l.sh || p === rig.arms?.r.sh)) return;
    if (up(o, (p) => p.userData?.noSkin)) return; // tails and chest lights hang free
    out.push(o);
  });
  return out;
}
function inside(p, meshes) {
  // odd hits along two directions = inside
  let votes = 0;
  for (const d of [new THREE.Vector3(1, 0.13, 0.07).normalize(), new THREE.Vector3(-0.11, 0.2, 1).normalize()]) {
    ray.set(p, d);
    let hits = 0;
    for (const m of meshes) {
      const side = m.material.side;
      m.material.side = THREE.DoubleSide;
      hits += ray.intersectObject(m, false).length;
      m.material.side = side;
    }
    votes += hits % 2;
  }
  return votes === 2;
}
function depthInto(p, meshes) {
  // distance to the nearest torso surface (approximate: 14 rays)
  let best = 1e9;
  const dirs = [];
  for (let i = 0; i < 14; i++) {
    const t = (i + 0.5) / 14, phi = Math.acos(1 - 2 * t), th = Math.PI * (1 + Math.sqrt(5)) * i;
    dirs.push(new THREE.Vector3(Math.sin(phi) * Math.cos(th), Math.cos(phi), Math.sin(phi) * Math.sin(th)));
  }
  for (const d of dirs) {
    ray.set(p, d);
    for (const m of meshes) {
      const side = m.material.side;
      m.material.side = THREE.DoubleSide;
      const h = ray.intersectObject(m, false)[0];
      m.material.side = side;
      if (h) best = Math.min(best, h.distance);
    }
  }
  return best;
}
function limbVerts() {
  const out = [];
  for (const s of ["l", "r"]) {
    const a = rig.arms?.[s];
    if (!a) continue;
    a.el.traverse((o) => {
      if (!o.isMesh || up(o, (p) => p.visible === false)) return;
      const P = o.geometry.attributes.position;
      const step = Math.max(1, Math.floor(P.count / 120));
      for (let i = 0; i < P.count; i += step) out.push([s, o, i]);
    });
  }
  return out;
}
const SHOT_LIST = ["order", "salute", "cheer", "stamp", "hammerHome", "carryCrate", "raiseScroll", "answerList", "pointBack", "whistle", "inspect", "spin"];
const LOOP_LIST = ["idle", "lean", "haul", "lookout", "review", "helm", "coil", "mend", "signal", "log", "hammer", "saw", "swab", "carry"];
function bodies() {
  const ship = new THREE.Group();
  scene.add(ship);
  scene.remove(rig.group);
  const man = new CrewMan({ id: who, role: "worker", rig, ship, scale: 1, home: new THREE.Vector3(), yaw: 0 });
  const ms = torsoMeshes();
  const hu = (rig.body?.scale || 1) * 0.05; // world size of one body unit (a = 0.05 per unit)
  const res = [];
  const test = (label) => {
    ship.updateMatrixWorld(true);
    let worst = 0, n = 0;
    const tmp = new THREE.Vector3();
    for (const [, o, i] of limbVerts()) {
      tmp.fromBufferAttribute(o.geometry.attributes.position, i);
      o.localToWorld(tmp);
      if (!inside(tmp, ms)) continue;
      const d = depthInto(tmp, ms) / hu;
      if (d > 0.35) n++;
      worst = Math.max(worst, d);
    }
    res.push({ label, worst: +worst.toFixed(2), deep: n });
  };
  for (const L of LOOP_LIST) {
    man.setLoop(L);
    for (let k = 0; k < 4; k++) {
      man.update(0.3, 0);
      test("loop:" + L + "@" + k);
    }
  }
  man.setLoop("idle");
  for (const sname of SHOT_LIST) {
    man.shot(sname);
    for (let k = 0; k < 6; k++) {
      man.update(0.22, 0);
      test("shot:" + sname + "@" + k);
    }
    man.update(2.5, 0);
  }
  scene.remove(ship);
  return res.filter((r) => r.deep > 0).sort((a, b) => b.worst - a.worst);
}
// ---------------------------------------------------------------- beauty sheet
function sheet(expr, yaws = [0, 40, 90, 140, 180, 320]) {
  rig.setExpression(expr);
  const c = document.createElement("canvas");
  c.width = S * yaws.length;
  c.height = S;
  const x = c.getContext("2d");
  for (const [i, y] of yaws.entries()) {
    place(y, 8);
    renderer.render(scene, camera);
    x.drawImage(renderer.domElement, i * S, 0);
  }
  return c.toDataURL("image/png");
}
window.__clip = {
  run({ body = true, head = true } = {}) {
    const t0 = performance.now();
    const out = { who };
    if (head && rig.head && who !== "robot") out.heads = heads();
    if (body) out.body = bodies();
    out.ms = Math.round(performance.now() - t0);
    return out;
  },
  sheet,
  expressions: rig.expressions,
};
window.__clipReady = true;
