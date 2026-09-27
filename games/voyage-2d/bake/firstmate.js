// The new firstmate (the captain's brief: "a handsome young man, not a robot"), built in
// the bake from v3's own parts until v3 ships its model: the banner's young sailor
// beside the captain. White sailor cap with its blue ribbon tails, a navy vest over the
// white shirt with a blue neckerchief, navy bell-bottoms, dark tousled hair, a lean
// young build and a confident grin. Same style as the crew: smooth authored body,
// textured head (eyes black block + white, no glint), subtle voxel-grid skin.
import * as THREE from "three";
import { PAL } from "../v3src/engine/materials.js";
import { makeChibi, humanHead, sailorCap, getMesher } from "../v3src/engine/models/chibi.js";
import { crewExtras, crewTexturedHead } from "../v3src/engine/models/crewSmooth.js";
import { sailorBody, sailorCapSmooth } from "../v3src/engine/models/crewAuthored.js";
import { buildMap } from "../v3src/engine/models/props.js";

const VEST = new THREE.Color(0x1f2a5c), VEST_EDGE = new THREE.Color(0xc9a44a);

// turn the white shirt's sides and back navy: a vest, the shirt showing down the front
function vest(group) {
  group.traverse((m) => {
    if (!m.isMesh || !m.geometry.attributes.color) return;
    for (let p = m.parent; p; p = p.parent) if (p.name === "kerchiefTails") return;
    const pos = m.geometry.attributes.position, col = m.geometry.attributes.color;
    let maxX = 0, minY = 1e9, maxY = -1e9;
    for (let i = 0; i < pos.count; i++) (maxX = Math.max(maxX, Math.abs(pos.getX(i)))), (minY = Math.min(minY, pos.getY(i))), (maxY = Math.max(maxY, pos.getY(i)));
    const c = new THREE.Color();
    for (let i = 0; i < pos.count; i++) {
      c.fromBufferAttribute(col, i);
      if (c.r + c.g + c.b < 2.55) continue; // only the white shirt
      const x = Math.abs(pos.getX(i)), z = pos.getZ(i), y = (pos.getY(i) - minY) / (maxY - minY || 1);
      const open = 0.22 + 0.16 * y; // the vest opens wider toward the collar
      if (z < 0 || x > open * maxX) {
        const edge = z > 0 && x < (open + 0.05) * maxX;
        col.setXYZ(i, ...(edge ? VEST_EDGE : VEST).toArray());
      }
    }
    col.needsUpdate = true;
  });
  return group;
}

export function buildFirstmate({ pose = "idle", expression } = {}) {
  const smooth = getMesher() === "smooth";
  const body = { scale: 1.02, head: 1.0, hand: 1.0, chest: 5, waist: 4.2, depth: 3, legLen: 12, legX: 2.5 };
  const kerchief = [0x2a5ad8, 0x1a3a9a];
  const auth = smooth ? sailorBody(body, { kerchief }) : null;
  const hatFn = (g) => sailorCap(g);
  return makeChibi({
    name: "firstmate",
    body,
    expressions: ["grin", "smile", "joy", "focus", "surprise"],
    defaultExpr: expression || "grin",
    defaultPose: pose,
    headKey: "firstmate-young",
    texturedHead: smooth ? crewTexturedHead("firstmate-young") : null,
    smoothBody: auth ? { ...auth, torso: () => vest(auth.torso()) } : null,
    head: (expr) => humanHead(expr, {
      smoothExtras: smooth ? (a) => crewExtras({ ...a, hatFn, hatSmooth: () => sailorCapSmooth({ band: 0x1f2a5c, emblem: 0x1f2a5c, studs: 0x2a5ad8 }), hatName: "firstmate" }) : null,
      hair: { style: "messy", seed: 11 }, hat: hatFn, capY: 15, hatTilt: [-3, 6],
      face: { eyeW: 4, eyeH: 10, mouthW: 4, browThick: 3, browKind: "flat", whiteFrac: 0.45, laugh: 0.36 },
      shape: { w: 0.98, chin: 1.12, sq: 3.6, puff: 0.5 },
    }),
    torso: () => { throw new Error("the firstmate is smooth-only"); },
    upperArm: () => null, forearm: () => null, leg: () => null,
    props: { map: { build: () => buildMap({ scale: 0.025, w: 18, d: 13 }), side: "l" } },
    poses: { idle: { expr: "grin", rs: [0, 0, -5], ls: [0, 0, 5], re: [-10, 0, 0], le: [-10, 0, 0] } },
  });
}
