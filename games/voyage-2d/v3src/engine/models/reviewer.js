// The reviewer: green bandana, round glasses, green-and-white outfit with
// crossed straps, magnifying glass. Poses: inspect, cheer, idle, read.
import { M } from "../voxel.js";
import { PAL } from "../materials.js";
import { makeChibi, humanHead, bandana, torsoGrid, limbGrid, addHand } from "./chibi.js";
import { buildMagnifier, buildMap } from "./props.js";

const G = PAL.green;
const GD = PAL.greenDark;

export function buildReviewer({ pose = "inspect", expression } = {}) {
  return makeChibi({
    name: "reviewer",
    expressions: ["smile", "focus", "joy", "surprise"],
    defaultExpr: expression,
    defaultPose: pose,
    head: (expr) =>
      humanHead(expr, {
        hair: { style: "messy", capY: 12, seed: 5 },
        hat: (g) => bandana(g, { color: G, dark: GD }),
        glassesOn: true,
      }),
    torso: () => {
      const g = torsoGrid((x, y, z) => {
        const ax = Math.abs(x);
        if (y <= 1) return y === 1 ? (z === 3 && ax <= 1 ? [PAL.gold, M.METAL, 1] : PAL.leather) : 0x3d5a36; // belt + olive trousers
        // crossed green straps over a white shirt (front and back)
        if (Math.abs(z) === 3 && (ax === y - 2 || ax === y - 3) && y <= 9) return G;
        if (z === 3 && y >= 8 && ax <= 1) return PAL.skin;
        if (y === 9 && ax >= 3) return G; // green shoulder yoke
        return PAL.white;
      });
      // green collar points + a badge
      g.box(-2, 8, 4, -1, 8, 4, G, M.CLOTH, 1);
      g.box(1, 8, 4, 2, 8, 4, G, M.CLOTH, 1);
      g.set(3, 6, 4, PAL.gold, M.METAL, 1);
      g.set(3, 5, 4, 0xffffff, M.LIT, 1);
      // satchel on the back
      g.box(-3, 2, -5, 3, 6, -4, 0x6b4a2a, M.LIT, 2);
      g.box(-3, 6, -5, 3, 6, -5, 0x563a20, M.LIT, 2);
      return g;
    },
    upperArm: () => limbGrid(4, (x, y) => (y === 0 ? G : PAL.white)),
    forearm: (side, shape) => {
      const g = limbGrid(4, (x, y) => (y === -3 ? G : PAL.white));
      addHand(g, shape, PAL.skin, side === "l" ? 1 : -1);
      return g;
    },
    leg: () => {
      const g = limbGrid(7, (x, y) => (y <= -5 ? 0x4a2e1a : 0x3d5a36), { r: 2, rz: 2 });
      g.box(-2, -7, 3, 2, -7, 3, 0x4a2e1a, M.LIT, 2);
      g.box(-2, -5, -2, 2, -5, 2, 0x5c3a22, M.LIT, 2);
      return g;
    },
    props: {
      magnifier: { build: () => buildMagnifier(), side: "r" },
      map: { build: () => buildMap({ scale: 0.03, w: 20, d: 14 }), side: "l" },
    },
    poses: {
      inspect: {
        expr: "focus",
        torso: [6, -12, 0],
        head: [4, -10, 0],
        rs: [-120, 0, 30],
        re: [-50, 0, 0],
        hr: "grip",
        ls: [-50, 0, -6],
        le: [-40, 0, 0],
        hl: "open",
        props: { magnifier: { rot: [-20, 0, 0] }, map: { side: "l", pos: [2, -6, 3], rot: [-50, 0, 0] } },
      },
      cheer: { expr: "joy", torso: [-4, 0, 0], head: [-8, 0, 0], rs: [-165, 0, 20], re: [-10, 0, 0], ls: [-165, 0, -20], le: [-10, 0, 0], y: 1, props: { magnifier: { rot: [-90, 0, 0] } } },
      read: { expr: "smile", head: [14, 0, 0], rs: [-60, 0, 14], re: [-30, 0, 0], hr: "open", ls: [-60, 0, -14], le: [-30, 0, 0], hl: "open", props: { map: { side: "l", pos: [-5, -7, 3], rot: [-50, 0, 0] } } },
      idle: { expr: "smile", rs: [0, 0, -8], re: [-60, 0, 0], ls: [0, 0, 8], le: [-10, 0, 0], hr: "grip", props: { magnifier: { rot: [-120, 0, 0] } } },
    },
  });
}
