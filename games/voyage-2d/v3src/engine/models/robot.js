// Robot first mate: white boxy body with panel lines, dark screen face with two
// glowing blue eye blocks, antenna light, articulated arms, bosun's whistle.
// Poses: whistle, wave, cheer, idle, point.  Expressions: eyes, happy, blink, wink.
import { VoxelGrid, M } from "../voxel.js";
import { PAL } from "../materials.js";
import { makeChibi, torsoGrid, limbGrid } from "./chibi.js";
import { buildWhistle } from "./props.js";

const WHITE = 0xf1f3f7;
const PANEL = 0xc9ced9;
const JOINT = 0x6d7482;
const SCREEN = 0x0e1630;
const EYE = 0x3cc4ff;

function robotHead(expr) {
  const g = new VoxelGrid({ jitter: 1, seam: 0.22, seed: 3 });
  for (let x = -8; x <= 8; x++)
    for (let y = 0; y <= 12; y++)
      for (let z = -6; z <= 6; z++) {
        const ex = Math.abs(x) === 8,
          ey = y === 0 || y === 12,
          ez = Math.abs(z) === 6;
        if (ex + ey + ez >= 2) continue;
        let c = WHITE;
        if (y === 3 && z < 0) c = PANEL; // panel seam wrapping the back
        if (Math.abs(x) === 8 && (y === 9 || y === 2)) c = PANEL;
        g.set(x, y, z, c, M.LIT, 1);
      }
  // dark screen inset with a bezel lip
  for (let x = -6; x <= 6; x++)
    for (let y = 2; y <= 10; y++) {
      const corner = (Math.abs(x) === 6) + (y === 2 || y === 10) === 2;
      if (corner) continue;
      g.set(x, y, 6, SCREEN, M.LIT, 1);
      g.del(x, y, 7);
    }
  for (let x = -7; x <= 7; x++) {
    g.set(x, 11, 7, WHITE, M.LIT, 1);
    g.set(x, 1, 7, WHITE, M.LIT, 1);
  }
  for (let y = 1; y <= 11; y++) {
    g.set(-7, y, 7, WHITE, M.LIT, 1);
    g.set(7, y, 7, WHITE, M.LIT, 1);
  }
  // eyes
  const E = (x, y) => g.set(x, y, 6, EYE, M.GLOW, 0);
  for (const cx of [-3, 3]) {
    if (expr === "happy") {
      E(cx - 1, 6);
      E(cx, 7);
      E(cx + 1, 6);
      E(cx - 2, 5);
      E(cx + 2, 5);
    } else if (expr === "blink" || (expr === "wink" && cx > 0)) {
      for (let dx = -1; dx <= 1; dx++) E(cx + dx, 5);
    } else {
      for (let dx = -1; dx <= 1; dx++) for (let y = 5; y <= 8; y++) E(cx + dx, y);
      g.set(cx - 1, 8, 6, 0xd8f4ff, M.GLOW, 0);
    }
  }
  if (expr === "happy" || expr === "wink") for (let x = -2; x <= 2; x++) E(x, x === -2 || x === 2 ? 4 : 3);
  // ear discs with a light
  for (const s of [-1, 1]) {
    g.cyl("x", s * 9, s * 9, 6, 0, 2.6, JOINT, M.METAL, 1);
    g.set(s * 10, 6, 0, EYE, M.GLOW, 0);
  }
  // antenna + light
  g.box(0, 13, 0, 0, 16, 0, JOINT, M.METAL, 1);
  g.box(-1, 13, -1, 1, 13, 1, PANEL, M.METAL, 1);
  g.ellipsoid(0, 18, 0, 1.4, 1.4, 1.4, 0x5fd6ff, M.GLOW, 0);
  return g;
}

function robotTorso() {
  const g = torsoGrid(
    (x, y, z) => {
      const ax = Math.abs(x);
      if (y <= 0) return JOINT; // waist ring
      if (y === 5 || (z === 3 && ax === 4 && y > 0)) return PANEL; // panel lines
      if (z === -3 && (ax === 2 || y === 7)) return PANEL;
      return WHITE;
    },
    { W: 5, H: 8, D: 3 },
  );
  // chest light: a downward blue triangle, plus two small buttons
  const T = [
    [-2, 8],
    [-1, 8],
    [0, 8],
    [1, 8],
    [2, 8],
    [-1, 7],
    [0, 7],
    [1, 7],
    [0, 6],
  ];
  for (const [x, y] of T) g.set(x, y - 1, 4, EYE, M.GLOW, 0);
  g.set(-3, 3, 4, 0xff6a5a, M.GLOW, 0);
  g.set(3, 3, 4, 0x7dff9a, M.GLOW, 0);
  // backpack
  g.box(-3, 2, -5, 3, 7, -4, PANEL, M.METAL, 1);
  g.box(-2, 3, -6, 2, 6, -6, JOINT, M.METAL, 1);
  // neck
  g.box(-2, 9, -1, 2, 9, 1, JOINT, M.METAL, 1);
  return g;
}

export function buildRobot({ pose = "whistle", expression } = {}) {
  return makeChibi({
    name: "robot",
    expressions: ["eyes", "happy", "blink", "wink"],
    defaultExpr: expression,
    defaultPose: pose,
    neckY: 10,
    head: robotHead,
    torso: robotTorso,
    upperArm: () => {
      const g = limbGrid(4, (x, y) => (y === 0 ? JOINT : WHITE));
      g.ellipsoid(0, 0, 0, 1.8, 1.8, 1.8, JOINT, M.METAL, 1);
      return g;
    },
    forearm: (side, shape) => {
      const g = limbGrid(4, (x, y) => (y === 0 ? JOINT : y === -3 ? PANEL : WHITE));
      g.ellipsoid(0, 0, 0, 1.5, 1.5, 1.5, JOINT, M.METAL, 1);
      // claw hand: palm + three fingers
      g.box(-1, -4, -1, 1, -5, 1, JOINT, M.METAL, 1);
      if (shape === "open") {
        g.box(-1, -6, 1, -1, -7, 1, JOINT, M.METAL, 1);
        g.box(1, -6, 1, 1, -7, 1, JOINT, M.METAL, 1);
        g.box(0, -6, -1, 0, -7, -1, JOINT, M.METAL, 1);
      } else {
        g.box(-1, -6, -1, 1, -6, 1, JOINT, M.METAL, 1);
        g.set(0, -5, 2, JOINT, M.METAL, 1);
        if (shape === "grip") g.del(0, -6, 0);
      }
      return g;
    },
    leg: () => {
      const g = limbGrid(7, (x, y) => (y >= -2 ? JOINT : WHITE), { r: 2, rz: 2 });
      g.box(-2, -7, 3, 2, -6, 3, WHITE, M.LIT, 1);
      g.box(-2, -7, -2, 2, -7, 3, PANEL, M.LIT, 1);
      return g;
    },
    props: { whistle: { build: () => buildWhistle(), side: "r" } },
    poses: {
      whistle: {
        expr: "happy",
        torso: [-4, 8, 0],
        head: [-6, 0, 0],
        rs: [-125, 0, 26],
        re: [-45, 0, 0],
        hr: "grip",
        ls: [-30, 0, 30],
        le: [-40, 0, 0],
        hl: "open",
        rl: [0, 0, -8],
        ll: [0, 0, 8],
        props: { whistle: { rot: [60, 0, 0], pos: [0, -5.5, 0] } },
      },
      wave: { expr: "eyes", head: [0, 0, 8], rs: [-10, 0, -150], re: [0, 0, 25], hr: "open", ls: [0, 0, 10], le: [-20, 0, 0] },
      cheer: { expr: "happy", head: [-8, 0, 0], rs: [-165, 0, 22], re: [-10, 0, 0], ls: [-165, 0, -22], le: [-10, 0, 0], y: 1 },
      point: { expr: "eyes", torso: [0, 10, 0], rs: [-95, 0, -10], re: [0, 0, 0], hr: "open", ls: [0, 0, 12], le: [-20, 0, 0] },
      idle: { expr: "eyes", rs: [0, 0, -10], re: [-20, 0, 0], ls: [0, 0, 10], le: [-20, 0, 0] },
    },
  });
}
