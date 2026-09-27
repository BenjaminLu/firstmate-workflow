// The firstmate (p4, the captain: "firstmate 應該是帥氣小子, 不是機器人"): a handsome
// young officer. Slim and long-legged, a navy coat open over a white shirt, a red
// sash, tall boots, tousled dark hair under a red bandana knotted at the side, a
// confident grin with slanted brows. Same approved style as the crew (textured face,
// eyes a black block plus white, no glint; smooth authored body with the faint grid).
// He keeps the firstmate's jobs: the helm, the whistle, relaying the order, the
// hand-offs, the salute.
import { PAL } from "../materials.js";
import { makeChibi, humanHead, bandana, torsoGrid, limbGrid, bootLeg, getMesher } from "./chibi.js";
import { crewExtras, crewTexturedHead } from "./crewSmooth.js";
import { officerBody, boxCapSmooth } from "./crewAuthored.js";
import { buildWhistle } from "./props.js";

const COAT = 0x1b2656;
const LOOK = {
  body: { scale: 1.02, head: 0.98, hand: 1.0, chest: 5, waist: 4.1, belly: 0, depth: 3, legLen: 12.5, legX: 2.3 },
  face: { eyeW: 4, eyeH: 10, eyeBot: 11, mouthW: 4, browThick: 3, browKind: "angry", browGap: 1, laugh: 0.3, whiteFrac: 0.45 },
  shape: { w: 0.97, chin: 1.12, sq: 3.5, puff: 0.45 },
};
export function buildFirstmate({ pose = "idle", expression } = {}) {
  const smooth = getMesher() === "smooth";
  const scarf = { color: 0xd8322a, dark: 0x9a1e1a, height: 5, ridge: false, rivets: false, round: 3.2, dome: 0.5 };
  const hatFn = (g) => bandana(g, { color: 0xd8322a, dark: 0x9a1e1a, tail: 0x9a1e1a, dots: false });
  const hatSmooth = () => boxCapSmooth({ ...scarf, k: 1 });
  return makeChibi({
    name: "firstmate",
    body: LOOK.body,
    expressions: ["grin", "smile", "joy", "shout", "focus", "surprise"],
    defaultExpr: expression || "grin",
    defaultPose: pose,
    headKey: "firstmate",
    texturedHead: smooth ? crewTexturedHead("firstmate") : null,
    smoothBody: smooth ? officerBody(LOOK.body) : null,
    head: (expr) =>
      humanHead(expr, {
        smoothExtras: smooth ? (a) => crewExtras({ ...a, hatFn, hatSmooth, hatName: "firstmate" }) : null,
        hair: { style: "spiky", seed: 11 },
        hat: hatFn,
        capY: 16,
        hatLift: smooth ? 0.6 : 0,
        hatTilt: [-4, -7], // worn at a rakish angle
        face: LOOK.face,
        shape: LOOK.shape,
      }),
    torso: () => torsoGrid((x, y, z) => (y <= 0 ? 0x23232e : y <= 2 ? 0xc8282a : Math.abs(x) <= 1 && z >= 2 && y >= 3 ? 0xf4f0e6 : COAT)),
    upperArm: () => limbGrid(5, () => COAT),
    forearm: () => limbGrid(5, (x, y) => (y <= -4 ? 0xf4f0e6 : y === -3 ? 0xf1b43c : COAT)),
    leg: () => bootLeg({ trousers: 0xe8e2d4, boot: 0x3a2416 }),
    props: { whistle: { build: () => buildWhistle(), side: "r" } },
    poses: {
      idle: { expr: "grin", rs: [0, 0, -8], re: [-12, 0, 0], ls: [6, 0, 14], le: [-70, 0, 0], torso: [0, 6, 0], head: [-3, -6, 0] }, // a hand on the hip
      whistle: { expr: "joy", torso: [-4, 8, 0], head: [-8, 0, 0], ik: { r: [-5, 10.5, 8], rp: [-1, -0.5, 0], l: [10, 19, 3], lp: [1, -0.4, 0] }, hr: "grip", hl: "open", props: { whistle: { aim: [-0.35, 0.5, 1] } } },
      wave: { expr: "grin", head: [0, 0, 8], ik: { r: [-12, 20, 3], rp: [-1, -0.3, 0] }, hr: "open", ls: [0, 0, 8], le: [-20, 0, 0] },
      cheer: { expr: "joy", head: [-8, 0, 0], ik: { r: [-9.5, 23, 3], l: [9.5, 23, 3] }, y: 1 },
      point: { expr: "grin", torso: [0, 10, 0], ik: { r: [-6, 12, 15] }, hr: "point", ls: [0, 0, 10], le: [-20, 0, 0] },
      salute: { expr: "focus", ik: { r: [-4, 18.5, 6], rp: [-1, 0, 0] }, hr: "open", ls: [0, 0, 6] },
    },
  });
}
