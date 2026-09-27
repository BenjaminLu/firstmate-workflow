// The game world: golden-hour sea, the frigate with her crew at their posts,
// the lighthouse, and the kraken waiting below. Built in stages so the first
// frame (sky and sea) paints before the heavy models.
import * as THREE from "three";
import { createSky, createLights } from "../engine/lighting.js";
import { VoxelGrid } from "../engine/voxel.js";
import { toMesh } from "../engine/materials.js";
import { setHeadDetail } from "../engine/models/chibi.js";
import { buildFrigate, V } from "../engine/models/frigate.js";
import { buildCaptain } from "../engine/models/captain.js";
import { buildRobot } from "../engine/models/robot.js";
import { buildSailor } from "../engine/models/sailor.js";
import { buildReviewer } from "../engine/models/reviewer.js";
import { buildCorgi } from "../engine/models/corgi.js";
import { buildParrot } from "../engine/models/parrot.js";
import { buildKraken } from "../engine/models/kraken.js";
import { buildLighthouseIsland, buildSeaStack } from "../engine/models/lighthouse.js";
import { buildSea, buildFarSea } from "../engine/models/sea.js";
import * as Props from "../engine/models/props.js";
import { CrewMan } from "./crew.js";

export const SUN = new THREE.Vector3(0.12, 0.085, -1).normalize();
const SHIP_POS = new THREE.Vector3(7, 0, -4);
const SHIP_YAW = Math.PI - 0.16;
const WORKER_MODEL = {
  "sailor-hammer": (o) => buildSailor({ variant: "hammer", seed: 5, ...o }),
  "sailor-bandana": (o) => buildSailor({ variant: "bandana", ...o }),
  "sailor-spyglass": (o) => buildSailor({ variant: "spyglass", seed: 7, ...o }),
  "sailor-laptop": (o) => buildSailor({ variant: "laptop", seed: 3, ...o }),
};

// deck slots in voxel x along the ship, per station and worker index
const SLOTS = {
  top: [-38, -58, -46, -63],
  amidships: [-24, -6, -14, 6],
  main: [14, 30, 22, 36],
  idle: [-28, 18, 8, -18],
};

export function createWorld(renderer, { detail = "high" } = {}) {
  const low = detail === "low";
  setHeadDetail(detail);
  const scene = new THREE.Scene();
  scene.fog = new THREE.Fog(0xf0b49a, 120, 460);
  const sky = createSky(SUN);
  scene.add(sky);
  // storm veil: a dark shell inside the sky that the squall fades in
  const veil = new THREE.Mesh(new THREE.SphereGeometry(800, 24, 12), new THREE.MeshBasicMaterial({ color: 0x2a3148, transparent: true, opacity: 0, side: THREE.BackSide, depthWrite: false, fog: false }));
  veil.renderOrder = -9;
  scene.add(veil);
  const lights = createLights(scene, { sunDir: new THREE.Vector3(-0.62, 0.42, 0.66), shadowCenter: new THREE.Vector3(3, 9, -4), shadowExtent: 22, mapSize: low ? 1024 : 2048 });
  const rim = new THREE.DirectionalLight(0xffa860, 1.3);
  rim.position.copy(SUN).multiplyScalar(100);
  const front = new THREE.DirectionalLight(0xffd2a0, 1.4);
  front.position.set(-80, 40, 70);
  scene.add(rim, front);
  const near = buildSea(low ? { cell: 0.8, width: 70, depth: 56, center: [2, -2], amp: 0.62, sunDir: SUN } : { cell: 0.42, width: 80, depth: 64, center: [2, -2], amp: 0.62, sunDir: SUN });
  const U = near.userData.uniforms;
  const far = buildSea({ cell: low ? 4 : 2.5, width: 400, depth: 340, center: [0, -120], sunDir: SUN, foam: false, hole: low ? [-33, -30, 37, 26] : [-38, -34, 42, 30], uniforms: U });
  scene.add(near, far, buildFarSea({ y: -2.2 }));

  const world = {
    scene,
    lights,
    sky,
    veil,
    seaU: U,
    ship: null,
    shipRig: null,
    crew: {},
    kraken: null,
    storm: 0,
    stormTarget: 0,
    heel: 0,
    heelV: 0,
    lightBreak: 0,
    ready: false,
    detail,
  };

  world.buildShip = () => {
    const ship = buildFrigate({ lod: detail, lanternLights: !low, brace: 0.95 });
    const S = ship.group;
    S.position.copy(SHIP_POS);
    S.rotation.y = SHIP_YAW;
    scene.add(S);
    world.ship = S;
    world.shipRig = ship;
    U.uShip.value.set(SHIP_POS.x, SHIP_POS.z, Math.cos(-SHIP_YAW), Math.sin(-SHIP_YAW));
    U.uShipSize.value.set(13.4, 3.7, 1);
  };

  const at = (x, side = -1, inset = 5) => world.ship.userData.spotAt(x, side, inset);
  world.stationSpot = (deck, idx, action) => {
    if (action === "climb") return { pos: at(4 - idx * 2, -1, 1.2), yaw: Math.PI };
    if (action === "capstan") return { pos: at(-12, 1, 9.5), yaw: 0 };
    const xs = SLOTS[deck] || SLOTS.idle;
    const x = xs[idx % xs.length];
    const side = deck === "idle" && idx % 2 ? 1 : -1;
    const pos = at(x, side, deck === "idle" ? 2.4 : 5);
    // face the rail for lookout / lean / haul; along the deck otherwise
    const yaw = ["lookout", "lean", "haul", "signal"].includes(action) ? (side < 0 ? Math.PI : 0) : side < 0 ? Math.PI * 0.75 : Math.PI * 0.25;
    return { pos, yaw };
  };

  world.buildCrew = (simCrew) => {
    const S = world.ship;
    const put = (id, role, rig, pos, yaw, scale = 1.6) => {
      const c = new CrewMan({ id, role, rig, ship: S, scale, home: pos, yaw });
      world.crew[id] = c;
      return c;
    };
    // the captain stands on a crate at the bow (kf1)
    const capSpot = at(53, -1, 4.2);
    const crate = Props.buildCrate({ scale: 0.06, w: 9, h: 6, d: 9 });
    crate.position.copy(capSpot);
    S.add(crate);
    const capPos = capSpot.clone().add(new THREE.Vector3(0, 0.36, 0));
    const cap = put("captain", "captain", buildCaptain({ pose: "idle" }), capPos, Math.PI + 0.2, 1.75);
    cap.setLoop("idle");
    // the firstmate (the robot) at the helm on the quarterdeck
    const fm = put("firstmate", "firstmate", buildRobot({ pose: "idle" }), at(-48, 1, 9.2), Math.PI / 2, 1.6);
    fm.setLoop("helm");
    // the reviewer on the quarterdeck by the starboard rail
    const rv = put("reviewer-1", "reviewer", buildReviewer({ pose: "idle" }), at(-36, -1, 3.5), Math.PI * 0.9, 1.6);
    rv.setLoop("idle");
    // workers at their idle posts
    const workers = simCrew.filter((c) => c.role === "worker");
    workers.forEach((w, i) => {
      const spot = world.stationSpot("idle", i, "lean");
      const c = put(w.id, "worker", WORKER_MODEL[w.model]({ pose: "idle" }), spot.pos, spot.yaw, 1.55);
      c.slot = i;
      c.setLoop("lean", spot.pos);
    });
    // the corgi by the captain, the parrot on the stern rail
    const corgi = buildCorgi({ pose: "sit" });
    corgi.group.position.copy(at(46, -1, 3));
    corgi.group.rotation.y = Math.PI + 0.25;
    corgi.group.scale.setScalar(1.5);
    S.add(corgi.group);
    world.corgi = corgi;
    const parrot = buildParrot({ pose: "perch" });
    parrot.group.position.copy(at(-30, -1, 1.2)).add(new THREE.Vector3(0, 1.0, 0));
    parrot.group.rotation.y = Math.PI - 0.5;
    parrot.group.scale.setScalar(1.8);
    S.add(parrot.group);
    world.parrot = parrot;
  };

  world.buildScenery = () => {
    const island = buildLighthouseIsland({ lod: detail });
    island.group.position.set(-14, 0, -74);
    island.group.rotation.y = 0.5;
    scene.add(island.group);
    U.uIslands.value[0].set(-14, -74, 9.5, 1);
    const stacks = low
      ? [[8, -140, 12, 26, 7, true], [-30, -110, 14, 20, 6, false]]
      : [[-2, -120, 11, 34, 8, false], [8, -140, 12, 26, 7, true], [22, -150, 13, 30, 9, false], [-30, -110, 14, 20, 6, false]];
    for (const [x, z, seed, h, r, arch] of stacks) {
      const st = buildSeaStack({ seed, h, r, arch, scale: 0.55, lod: detail });
      st.position.set(x, -1, z);
      scene.add(st);
    }
    world.gulls = [];
    for (const [x, y, z] of [[-14, 16, -20], [-6, 21, -30], [2, 25, -24]]) {
      const g = new VoxelGrid({ jitter: 1, seam: 0.15 });
      g.box(-1, 0, -3, 1, 1, 3, 0xf6f6f8);
      g.set(0, 1, 5, 0xf2b53a);
      for (let i = 1; i <= 7; i++) {
        const yy = i < 4 ? 1 + Math.floor(i / 2) : 3 - (i - 4);
        for (const s of [-1, 1]) g.box(s * (1 + i), yy, -1, s * (1 + i), yy, 1, i > 5 ? 0x3a3f4a : 0xf0f2f6);
      }
      const m = toMesh(g, { size: 0.08, cast: false });
      m.position.set(x, y, z);
      m.rotation.y = 0.8;
      scene.add(m);
      world.gulls.push(m);
    }
  };

  // the kraken: built with one arm per held task, off the starboard bow
  world.setKrakenArms = (n) => {
    if (world.kraken && world.kraken.rig.armCount === n) return world.kraken;
    let prev = world.kraken;
    if (prev) scene.remove(prev.group);
    if (!n) {
      world.kraken = null;
      return null;
    }
    const rig = buildKraken({ pose: "tower", expression: "glare", tentacles: Math.min(8, Math.max(1, n)), segments: low ? 18 : 26, lod: detail });
    const group = new THREE.Group();
    group.add(rig.group);
    rig.group.scale.setScalar(0.85);
    const local = new THREE.Vector3(74 * V, -1, -26 * V * 1.4);
    group.position.copy(world.ship.localToWorld(local.clone()));
    group.rotation.y = SHIP_YAW + Math.PI * 0.85;
    scene.add(group);
    world.kraken = { rig, group, rise: prev ? prev.rise : 0, riseTarget: 1, base: group.position.clone(), rear: 0, lunge: 0, far: prev?.far || 0, farTarget: 0 };
    return world.kraken;
  };

  // weather and light
  world.setStorm = (v) => (world.stormTarget = v);
  world.breakLight = (dur = 1.6, peak = 0.42) => (world.lightBreak = Math.max(world.lightBreak, peak), (world.lightDur = dur));
  world.heelKick = (k) => (world.heelV += k);

  world.update = (dt, t) => {
    U.uTime.value = t;
    // storm: the veil, fog and light follow the weather on a spring
    world.storm += (world.stormTarget - world.storm) * Math.min(1, dt * 0.9);
    const s = world.storm;
    veil.material.opacity = s * 0.62;
    scene.fog.color.setRGB(0.94 - 0.64 * s, 0.7 - 0.44 * s, 0.6 - 0.28 * s);
    scene.fog.near = 120 - 80 * s;
    scene.fog.far = 460 - 250 * s;
    U.uAmp.value = 0.62 + 0.45 * s;
    lights.sun.intensity = 3.5 * (1 - 0.6 * s) * (1 + world.lightBreak * 0.8);
    lights.hemi.intensity = 1.15 * (1 - 0.3 * s) + world.lightBreak * 0.8;
    front.intensity = 1.4 * (1 - 0.4 * s);
    world.lightBreak = Math.max(0, world.lightBreak - dt * (0.42 / (world.lightDur || 1.6)));
    // the ship: swell, heel spring (strikes, full sail)
    if (world.ship) {
      world.heelV += (-world.heel * 38 - world.heelV * 5.5) * dt;
      world.heel += world.heelV * dt;
      world.ship.position.y = SHIP_POS.y + Math.sin(t * 0.9) * (0.08 + 0.12 * s);
      world.ship.rotation.z = Math.sin(t * 0.7) * (0.012 + 0.02 * s) + world.heel * 0.02;
      world.ship.rotation.x = Math.sin(t * 0.55 + 1) * (0.01 + 0.015 * s);
    }
    for (const [i, g] of (world.gulls || []).entries()) {
      g.position.x += Math.sin(t * 0.3 + i) * 0.004;
      g.position.y += Math.sin(t * 1.3 + i) * 0.003;
    }
    // the kraken rises, rears, lunges; far off after a rescope
    const K = world.kraken;
    if (K) {
      K.rise += (K.riseTarget - K.rise) * Math.min(1, dt * 1.6);
      K.far += (K.farTarget - K.far) * Math.min(1, dt * 1.2);
      K.group.position.copy(K.base);
      K.group.position.y += -16 * (1 - K.rise) - 2 * K.rear * 0 + K.lunge * -1.2;
      const toShip = world.ship.position.clone().sub(K.base).setY(0).normalize();
      K.group.position.addScaledVector(toShip, K.lunge * 3 - K.far * 60);
      const sc = 1 - K.far * 0.7;
      K.group.scale.setScalar(sc);
      K.rig.group.rotation.x = -K.rear * 0.12 + K.lunge * 0.18;
      K.group.visible = K.rise > 0.02;
    }
    for (const c of Object.values(world.crew)) c.update(dt, t);
  };
  world.shipPos = SHIP_POS;
  return world;
}
