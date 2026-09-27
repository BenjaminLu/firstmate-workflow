// The captain: black tricorn with gold braid, big curly beard, navy coat with
// gold epaulettes and buttons, white ruffled shirt, belt + buckle, boots.
// Poses: point, stamp, cheer, idle, thumbsup.  Expressions: smile, joy, shout, focus.
import { M } from "../voxel.js";
import { PAL } from "../materials.js";
import { makeChibi, humanHead, tricorn, torsoGrid, limbGrid, addHand } from "./chibi.js";
import { buildStamp, buildSpyglass } from "./props.js";

const COAT = PAL.navyCoat;
const COAT_HI = 0x26315a;

export function buildCaptain({ pose = "point", expression } = {}) {
  const rig = makeChibi({
    name: "captain",
    expressions: ["smile", "joy", "shout", "focus"],
    defaultExpr: expression || "smile",
    defaultPose: pose,
    head: (expr) =>
      humanHead(expr, {
        hair: { style: "curly", capY: 12, color: PAL.hair },
        hat: tricorn,
        beardOn: true,
        mouthW: 2,
      }),
    torso: () => {
      const g = torsoGrid(
        (x, y, z) => {
          const ax = Math.abs(x);
          // coat skirt below the belt, open at the front
          if (y < 0) {
            if (z >= 2 && ax <= 2) return null;
            if (y === -4) return PAL.gold;
            return (x + y) % 5 === 0 ? COAT_HI : COAT;
          }
          // belt
          if (y === 1 || y === 2) {
            if (z === 3 && ax <= 1) return [PAL.gold, M.METAL, 1];
            return PAL.leather;
          }
          if (z === 3) {
            // open coat front: white shirt in the middle, gold-edged lapels
            if (ax <= 1 && y >= 3) return PAL.white;
            if (ax === 2 && y >= 3) return y >= 7 ? PAL.white : PAL.gold;
            if (ax === 2) return PAL.gold;
          }
          return (x * 3 + y) % 7 === 0 ? COAT_HI : COAT;
        },
        { skirt: 4 },
      );
      // shirt ruffle (jabot) and gold buttons proud of the coat
      for (const y of [5, 6, 7, 8]) g.set(0, y, 4, PAL.white, M.LIT, 1);
      g.set(-1, 7, 4, PAL.offWhite, M.LIT, 1);
      g.set(1, 6, 4, PAL.offWhite, M.LIT, 1);
      for (const x of [-4, 4]) for (const y of [3, 5, 7]) g.set(x, y, 4, PAL.gold, M.METAL, 1);
      // skirt buttons and pocket flaps
      for (const s of [-1, 1]) {
        g.box(s * 4, -2, 4, s * 5, -2, 4, PAL.gold, M.METAL, 1);
        g.box(s * 3, 0, 4, s * 3, 0, 4, PAL.gold, M.METAL, 1);
      }
      // epaulettes: gold pads with a hanging fringe
      for (const s of [-1, 1]) {
        g.box(s * 5, 9, -2, s * 8, 10, 2, PAL.gold, M.METAL, 1);
        g.box(s * 6, 11, -1, s * 7, 11, 1, PAL.goldDark, M.METAL, 1);
        for (let z = -2; z <= 2; z += 1) for (let y = 7; y <= 8; y++) if ((z + y) % 2 === 0) g.set(s * 9, y, z, PAL.gold, M.METAL, 1);
        for (let z = -2; z <= 2; z++) g.set(s * 9, 9, z, PAL.goldDark, M.METAL, 1);
      }
      // collar standing up behind the neck
      g.box(-4, 10, -3, 4, 11, -3, COAT, M.LIT, 2);
      g.box(-4, 11, -3, 4, 11, -3, PAL.gold, M.METAL, 1);
      return g;
    },
    upperArm: () =>
      limbGrid(4, (x, y, z) => (y === 0 && Math.abs(x) + Math.abs(z) === 2 ? null : COAT), { r: 1 }),
    forearm: (side, shape) => {
      const g = limbGrid(4, (x, y, z) => {
        if (y <= -2) return Math.abs(x) === 1 && Math.abs(z) === 1 ? PAL.goldDark : PAL.gold; // big gold cuff
        return COAT;
      });
      // lace at the wrist
      for (let x = -1; x <= 1; x++) g.set(x, -4, 1, PAL.white, M.LIT, 1);
      addHand(g, shape, PAL.skin, side === "l" ? 1 : -1);
      // gold cuff flare
      for (const x of [-2, 2]) g.box(x, -3, -1, x, -2, 1, PAL.gold, M.METAL, 1);
      return g;
    },
    leg: () => {
      const g = limbGrid(7, (x, y, z) => {
        if (y <= -4) return y === -4 ? 0x7a4a26 : 0x17171e; // folded boot cuff over black boots
        return PAL.navyDark;
      }, { r: 2, rz: 2 });
      g.box(-2, -7, 3, 2, -7, 3, 0x17171e, M.LIT, 2); // toe
      g.box(-2, -4, -3, 2, -4, 3, 0x8a5630, M.LIT, 2); // cuff flare
      return g;
    },
    props: {
      stamp: { build: () => buildStamp({ scale: 0.05 }), side: "r" },
      spyglass: { build: () => buildSpyglass({ scale: 0.05 }), side: "l" },
    },
    poses: {
      point: {
        expr: "shout",
        torso: [4, 10, 0],
        head: [-4, 8, 0],
        rs: [-100, 0, -18],
        re: [-8, 0, 0],
        hr: "point",
        ls: [0, 0, 32],
        le: [-70, 0, 0],
        hl: "fist",
        rl: [0, 0, -4],
        ll: [0, 0, 6],
      },
      stamp: {
        expr: "joy",
        torso: [22, 0, 0],
        head: [-10, 0, 0],
        rs: [-52, 0, -6],
        re: [-10, 0, 0],
        hr: "grip",
        ls: [-40, 0, 14],
        le: [-20, 0, 0],
        hl: "open",
        rl: [-10, 0, -3],
        ll: [18, 0, 3],
        props: { stamp: { side: "r", pos: [0, -6.5, 0], rot: [0, 0, 0] } },
      },
      cheer: {
        expr: "joy",
        torso: [-6, 0, 0],
        head: [-10, 0, 0],
        rs: [-170, 0, 18],
        re: [-10, 0, 0],
        ls: [-170, 0, -18],
        le: [-10, 0, 0],
        rl: [0, 0, -6],
        ll: [0, 0, 6],
        y: 1,
      },
      thumbsup: {
        expr: "smile",
        torso: [0, -8, 0],
        head: [0, 10, 4],
        rs: [-60, 0, -20],
        re: [-70, 0, 0],
        hr: "point",
        ls: [0, 0, 30],
        le: [-80, 0, 0],
        rl: [0, 0, -3],
        ll: [0, 0, 3],
      },
      spyglass: {
        expr: "focus",
        torso: [0, 0, 0],
        head: [-6, 0, 0],
        rs: [0, 0, 30],
        re: [-80, 0, 0],
        ls: [-150, -10, -40],
        le: [-40, 0, 0],
        hl: "grip",
        props: { spyglass: { side: "l", pos: [0, -5, 0], rot: [0, 0, 0] } },
      },
      idle: {
        expr: "smile",
        torso: [0, 0, 0],
        rs: [0, 0, -6],
        re: [-10, 0, 0],
        ls: [0, 0, 30],
        le: [-80, 0, 0],
      },
    },
  });
  return rig;
}
