// Sailors: white cap with navy band and anchor, navy-and-white uniform with a
// neckerchief, black hair, big eyes. Variants: bandana (red), laptop, hammer, spyglass.
import { M } from "../voxel.js";
import { PAL } from "../materials.js";
import { makeChibi, humanHead, sailorCap, bandana, torsoGrid, limbGrid, addHand } from "./chibi.js";
import { buildHammer, buildLaptop, buildSpyglass, buildScroll } from "./props.js";

export const SAILOR_VARIANTS = ["bandana", "laptop", "hammer", "spyglass"];

function sailorTorso() {
  const N = PAL.navy;
  const g = torsoGrid((x, y, z) => {
    const ax = Math.abs(x);
    if (y <= 1) return y === 1 && z === 3 && ax <= 1 ? [PAL.gold, M.METAL, 1] : y === 1 ? PAL.leather : N; // belt over navy trousers
    // square sailor collar on the back with a white stripe
    if (z === -3 && y >= 5) return y === 6 || ax === 3 ? PAL.white : ax <= 4 ? N : PAL.white;
    // V collar at the front
    if (z === 3) {
      const v = y - 4; // V edges
      if (ax === v || ax === v + 1) return N;
      if (ax < v) return y >= 8 ? PAL.skin : PAL.offWhite; // undershirt / neck
    }
    if (y === 9 && ax >= 3) return N; // collar over the shoulders
    return PAL.white;
  });
  // neckerchief knot + tails
  g.box(-1, 4, 4, 1, 5, 4, N, M.CLOTH, 1);
  g.set(0, 3, 4, N, M.CLOTH, 1);
  g.set(-1, 2, 4, PAL.navyDark, M.CLOTH, 1);
  g.set(1, 2, 4, PAL.navyDark, M.CLOTH, 1);
  // anchor patch on the chest pocket
  g.set(-3, 6, 4, N, M.LIT, 1);
  g.set(-3, 5, 4, N, M.LIT, 1);
  g.set(-4, 5, 4, N, M.LIT, 1);
  g.set(-2, 5, 4, N, M.LIT, 1);
  return g;
}

function sailorArm() {
  return limbGrid(4, (x, y, z) => (y === -3 ? PAL.navy : PAL.white));
}
function sailorForearm(side, shape) {
  const g = limbGrid(4, (x, y) => (y === -3 ? PAL.navy : y === -2 ? PAL.white : PAL.white));
  g.box(-1, -3, -1, 1, -3, 1, PAL.navy, M.LIT, 1);
  addHand(g, shape, PAL.skin, side === "l" ? 1 : -1);
  return g;
}
function sailorLeg() {
  const g = limbGrid(7, (x, y) => (y <= -6 ? 0x1b1b22 : PAL.navy), { r: 2, rz: 2 });
  g.box(-2, -7, 3, 2, -7, 3, 0x1b1b22, M.LIT, 2);
  g.box(-2, -5, -2, 2, -5, 2, 0x26356e, M.LIT, 2); // bell-bottom band
  return g;
}

const POSES = {
  idle: { expr: "smile", rs: [0, 0, -8], ls: [0, 0, 8], re: [-12, 0, 0], le: [-12, 0, 0] },
  cheer: { expr: "joy", torso: [-4, 0, 0], head: [-8, 0, 0], rs: [-165, 0, 20], re: [-15, 0, 0], ls: [-165, 0, -20], le: [-15, 0, 0], y: 1 },
  wave: { expr: "smile", head: [0, 0, 6], rs: [-10, 0, -150], re: [0, 0, 30], hr: "open", ls: [0, 0, 8], le: [-12, 0, 0] },
  salute: { expr: "focus", rs: [-120, 0, -60], re: [-100, 0, 0], hr: "open", ls: [0, 0, 6], le: [0, 0, 0] },
};

export function buildSailor({ variant = "hammer", pose, expression, seed = 1 } = {}) {
  const hatFn = variant === "bandana" ? (g) => bandana(g, { color: PAL.red, dark: PAL.redDark }) : (g) => sailorCap(g);
  const poses = { ...POSES };
  const props = {};
  if (variant === "hammer") {
    props.hammer = { build: () => buildHammer(), side: "r" };
    poses.work = { expr: "shout", torso: [10, -10, 0], head: [6, 8, 0], rs: [-150, 0, -10], re: [-40, 0, 0], hr: "grip", ls: [-40, 0, 10], le: [-30, 0, 0], props: { hammer: { rot: [-60, 0, 0] } } };
    poses.strike = { expr: "focus", torso: [18, -10, 0], head: [-4, 8, 0], rs: [-70, 0, -10], re: [-10, 0, 0], hr: "grip", ls: [-40, 0, 10], le: [-30, 0, 0], props: { hammer: { rot: [20, 0, 0] } } };
  }
  if (variant === "laptop") {
    props.laptop = { build: () => buildLaptop(), side: "r" };
    poses.work = { expr: "focus", torso: [6, 0, 0], head: [14, 0, 0], rs: [-55, 0, 10], re: [-25, 0, 0], hr: "open", ls: [-55, 0, -10], le: [-25, 0, 0], hl: "open", props: { laptop: { side: "r", pos: [-3, -7, 3], rot: [58, 0, -8] } } };
    poses.idle = { ...poses.idle, props: { laptop: { side: "l", pos: [2, -3, 2], rot: [80, 90, 0] } } };
  }
  if (variant === "spyglass") {
    props.spyglass = { build: () => buildSpyglass(), side: "r" };
    poses.work = { expr: "focus", head: [-4, -6, 0], rs: [-150, 0, 26], re: [-70, 0, 0], hr: "grip", ls: [-110, 0, -10], le: [-50, 0, 0], props: { spyglass: { rot: [70, -6, 0], pos: [0, -5, 0] } } };
  }
  if (variant === "bandana") {
    props.scroll = { build: () => buildScroll({ glow: true, scale: 0.035 }), side: "r" };
    poses.work = { expr: "joy", torso: [-4, 0, 0], rs: [-150, 0, -30], re: [-20, 0, 0], ls: [-60, 0, 20], le: [-60, 0, 0], props: { scroll: { pos: [0, -6, 0], rot: [0, 0, 90] } } };
  }
  const defaultPose = pose || (poses.work ? "work" : "idle");
  return makeChibi({
    name: "sailor-" + variant,
    expressions: ["smile", "joy", "shout", "focus", "surprise"],
    defaultExpr: expression,
    defaultPose,
    head: (expr) =>
      humanHead(expr, {
        hair: { style: "messy", capY: variant === "bandana" ? 12 : 11, seed },
        hat: hatFn,
      }),
    torso: sailorTorso,
    upperArm: sailorArm,
    forearm: sailorForearm,
    leg: sailorLeg,
    props,
    poses,
  });
}
