// The crew's motion tables (pass 1, motion toward 3), keyed from docs/animation-bible.md.
//
// Every one-shot is a set of key tracks in milliseconds: anticipation (a wind-up the
// other way, 12-20 % of the time), the action (v2's `pose` overshoot on snaps), a hold,
// and follow-through with a settle. Overlap is built into the evaluator: the chest reads
// its keys 30 ms late and the head 60 ms late, so the hips lead (bible rule 3).
//
// Channels (degrees unless noted):
//   rs re ls le   right/left shoulder and elbow [x, y, z]; shoulder x < 0 swings the arm
//                 forward and up; right-arm z < 0 swings it out, left-arm z > 0
//   torso head    [x, y, z]; x > 0 bends forward
//   pelvis        [x, y, z] on the hips (twist, tilt); the legs stay planted by IK
//   rl ll         leg swing [x, _, z]: authored as FK, turned into planted foot targets
//   y             vertical in body voxels (0.05 x crew scale): > 0 hops (feet leave the
//                 deck), < 0 crouches (the pelvis drops and the knees bend)
//   sq            squash and stretch on the upper body (volume kept)
//   ik            salute weight (the right hand to the hat brim by IK)
//   yaw           a turn about the vertical (promotion spin)
//   march         0..1 steps in place (carrying)
//   hr hl         hand shapes; cues: [[ms, name]] fired once as the clock passes them
import { Ease, keyed } from "../motion/ease.js";

const P = Ease.pose, A = Ease.arrive, S = Ease.inOutSine, O = Ease.outCubic, I = (k) => k * k * k, ST = Ease.strike;

// evaluate a keyed one-shot at t ms: { channel: value }, plus the blend weight
export function evalShot(def, t) {
  const out = {};
  for (const [ch, keys] of Object.entries(def.tracks)) {
    const lag = ch === "torso" ? 30 : ch === "head" ? 60 : 0;
    out[ch] = keyed(keys, t - lag);
  }
  // weight envelope: in over `in` ms, out over the last `out` ms (arrive), unless held
  const d = def.dur, win = def.in ?? 90, wout = def.out ?? 260;
  let w = Math.min(1, t / win);
  if (!def.hold && t > d - wout) w = Math.min(w, A(Math.max(0, (d - t) / wout)));
  out.w = w;
  for (const k of ["hr", "hl"]) if (def[k]) out[k] = typeof def[k] === "function" ? def[k](t) : def[k];
  return out;
}

// ---------------------------------------------------------------- one-shots (ms)
export const SHOTS = {
  // ORDER (v2 + bible): the captain draws back 0-120 (arm to +14), the cutlass up 120-440
  // with the pose overshoot, held high, then back to his pose over 320 ms at 1800
  order: {
    dur: 1800,
    out: 320,
    tracks: {
      rs: [[0, [0, 0, -8]], [120, [14, 0, -16], S], [440, [-158, 0, -30], P], [900, [-150, 0, -26], S], [1480, [-154, 0, -28], S]],
      re: [[0, [-10, 0, 0]], [120, [-48, 0, 0], S], [440, [-4, 0, 0], P], [1480, [-10, 0, 0], S]],
      ls: [[0, [0, 0, 6]], [120, [-24, 0, 18], S], [440, [14, 0, 26], P], [1480, [8, 0, 20], S]],
      le: [[0, [-10, 0, 0]], [440, [-30, 0, 0], P]],
      torso: [[0, [0, 0, 0]], [120, [6, -10, 0], S], [440, [-8, 8, 0], P], [1480, [-5, 5, 0], S]],
      head: [[0, [0, 0, 0]], [120, [6, 0, 0], S], [440, [-14, 0, 0], P], [1480, [-9, 0, 0], S]],
      pelvis: [[0, [0, 0, 0]], [120, [0, -6, 0], S], [440, [0, 6, 0], P], [1480, [0, 3, 0], S]],
      rl: [[0, [0, 0, -4]], [440, [-10, 0, -8], P]],
      ll: [[0, [0, 0, 4]], [440, [8, 0, 8], P]],
      y: [[0, 0], [120, -0.9, S], [300, 0.5, O], [520, 0, A]],
      sq: [[0, 1], [120, 0.94, S], [300, 1.06, O], [600, 1, A]],
    },
    hr: "grip",
    prop: { r: "cutlass", rRot: [72, 0, 0] }, // the blade carries the arm's line up and a little forward
  },
  // SALUTE (bible): a 120 ms dip, the hand up to the brim by IK in 180 ms (arrive), a hold
  // of 650, a drop over 300; the chest comes up proud and the heels close (attention)
  salute: {
    dur: 1250,
    out: 300,
    tracks: {
      ik: [[0, 0], [150, 0], [300, 1, A], [950, 1], [1060, 0, S]],
      // FK under the IK: the same arm (measured from the IK solve), so the snap and the
      // drop take the short way (no swing out through the side)
      // (the hand passes close by the chest on the way up and down: elbow folded)
      rs: [[0, [0, 0, -6]], [120, [8, 0, -10], S], [210, [-44, 30, -70], S], [300, [-32, 61, -128], A], [950, [-32, 61, -128]], [1080, [-34, 30, -62], S], [1250, [0, 0, -6], A]],
      re: [[0, [-10, 0, 0]], [120, [-24, 0, 0], S], [210, [-110, 0, 0], S], [300, [-33, 2, -8], A], [950, [-33, 2, -8]], [1080, [-105, 0, 0], S], [1250, [-10, 0, 0], A]],
      torso: [[0, [0, 0, 0]], [120, [9, 0, 0], S], [300, [-6, 0, 0], P], [950, [-4, 0, 0], S], [1250, [0, 0, 0], A]],
      head: [[0, [0, 0, 0]], [120, [8, 0, 0], S], [300, [-9, 0, 0], P], [950, [-6, 0, 0]], [1250, [0, 0, 0], A]],
      ls: [[0, [0, 0, 6]], [120, [-6, 0, 10], S], [300, [3, 0, 3], P], [950, [3, 0, 3]]],
      le: [[0, [-10, 0, 0]], [300, [-2, 0, 0], P]],
      rl: [[0, [0, 0, 0]], [300, [0, 0, 3], P]],
      ll: [[0, [0, 0, 0]], [300, [0, 0, -3], P]],
      y: [[0, 0], [120, -0.7, S], [300, 0.25, O], [480, 0, A]],
      sq: [[0, 1], [120, 0.95, S], [300, 1.04, O], [520, 1, A]],
    },
    hr: "open",
  },
  // CHEER (v2 clearing + salvo): a crouch with the arms back, then up with the arms
  // flung high; hops of 12 then 5 (v2), landing squashes, fists pump, arms come down
  cheer: {
    dur: 1700,
    out: 300,
    tracks: {
      rs: [[0, [0, 0, -6]], [150, [22, 0, -14], S], [330, [-170, 0, -26], P], [700, [-160, 0, -22], S], [900, [-172, 0, -28], S], [1100, [-150, 0, -20], S], [1300, [-168, 0, -26], S]],
      ls: [[0, [0, 0, 6]], [170, [22, 0, 14], S], [375, [-170, 0, 26], P], [745, [-160, 0, 22], S], [945, [-172, 0, 28], S], [1145, [-150, 0, 20], S], [1345, [-168, 0, 26], S]],
      re: [[0, [-10, 0, 0]], [150, [-50, 0, 0], S], [330, [-8, 0, 0], P], [1100, [-40, 0, 0], S], [1300, [-8, 0, 0], S]],
      le: [[0, [-10, 0, 0]], [170, [-50, 0, 0], S], [375, [-8, 0, 0], P], [1145, [-40, 0, 0], S], [1345, [-8, 0, 0], S]],
      torso: [[0, [0, 0, 0]], [150, [14, 0, 0], S], [330, [-8, 0, 0], P], [1100, [-4, 0, 3], S], [1300, [-8, 0, -3], S]],
      head: [[0, [0, 0, 0]], [150, [10, 0, 0], S], [330, [-14, 0, 0], P], [1300, [-10, 0, 0], S]],
      y: [[0, 0], [150, -1.1, S], [240, 0.4, O], [430, 3.0, O], [600, 0, I], [660, -0.9, O], [760, 0, A], [860, 1.3, O], [960, 0, I], [1010, -0.5, O], [1120, 0, A]],
      sq: [[0, 1], [150, 0.92, S], [260, 1.08, O], [430, 1.02], [600, 1.06], [660, 0.9, O], [800, 1, A], [960, 1.03], [1010, 0.94, O], [1150, 1, A]],
    },
    hr: "open",
    hl: "open",
  },
  // SLUMP (crash): a stagger back 150 ms, then he folds (squash 0.9, head down 26) and holds
  slump: {
    dur: 9e9,
    hold: true,
    tracks: {
      torso: [[0, [0, 0, 0]], [150, [-12, 0, -4], O], [620, [34, 0, 6], I], [800, [30, 0, 5], A]],
      head: [[0, [0, 0, 0]], [150, [-10, 0, 0], O], [620, [28, 0, 0], I], [850, [24, 0, 0], A]],
      rs: [[0, [0, 0, -6]], [150, [22, 0, -34], O], [620, [10, 0, -4], I], [850, [8, 0, -4], A]],
      ls: [[0, [0, 0, 6]], [150, [22, 0, 34], O], [620, [10, 0, 4], I], [850, [8, 0, 4], A]],
      re: [[0, [-10, 0, 0]], [620, [-4, 0, 0], I]],
      le: [[0, [-10, 0, 0]], [620, [-4, 0, 0], I]],
      rl: [[0, [0, 0, 0]], [150, [10, 0, -4], O], [620, [-12, 0, -8], I]],
      ll: [[0, [0, 0, 0]], [150, [6, 0, 4], O], [620, [-6, 0, 10], I]],
      y: [[0, 0], [150, 0.3, O], [620, -1.9, I], [760, -1.6, A]],
      sq: [[0, 1], [150, 1.03, O], [620, 0.88, I], [820, 0.92, A]],
    },
  },
  // RECOVERED: stands up with a stretch (1.05) and shakes it off
  recover: {
    dur: 1500,
    out: 350,
    tracks: {
      torso: [[0, [30, 0, 5]], [380, [-10, 0, 0], P], [560, [2, 0, 8], S], [700, [2, 0, -8], S], [840, [0, 0, 6], S], [980, [0, 0, 0], A]],
      head: [[0, [24, 0, 0]], [380, [-12, 0, 0], P], [560, [0, 16, 0], S], [700, [0, -16, 0], S], [840, [0, 10, 0], S], [980, [0, 0, 0], A]],
      rs: [[0, [8, 0, -4]], [380, [-150, 0, -30], P], [700, [-20, 0, -14], S], [1100, [0, 0, -6], A]],
      ls: [[0, [8, 0, 4]], [380, [-150, 0, 30], P], [700, [-20, 0, 14], S], [1100, [0, 0, 6], A]],
      re: [[0, [-4, 0, 0]], [380, [-6, 0, 0], P], [700, [-30, 0, 0], S]],
      le: [[0, [-4, 0, 0]], [380, [-6, 0, 0], P], [700, [-30, 0, 0], S]],
      y: [[0, -1.6], [380, 0.4, P], [620, 0, A]],
      sq: [[0, 0.92], [380, 1.05, P], [700, 1, A]],
    },
    hr: "open",
    hl: "open",
  },
  // PROMOTION (v2): a 120 ms crouch, up 10 px with a full turn over 1.4 s (arrive), down,
  // a land squash 0.92
  spin: {
    dur: 1800,
    tracks: {
      y: [[0, 0], [120, -0.9, S], [320, 1.7, O], [1300, 1.3, S], [1520, 0, I], [1580, -0.8, O], [1720, 0, A]],
      yaw: [[0, 0], [120, -8, S], [1520, 360, A]],
      rs: [[0, [0, 0, -6]], [120, [10, 0, -10], S], [320, [-40, 0, -58], P], [1520, [-30, 0, -40], S], [1700, [0, 0, -6], A]],
      ls: [[0, [0, 0, 6]], [120, [10, 0, 10], S], [320, [-40, 0, 58], P], [1520, [-30, 0, 40], S], [1700, [0, 0, 6], A]],
      torso: [[0, [0, 0, 0]], [120, [10, 0, 0], S], [320, [-6, 0, 0], P], [1520, [4, 0, 0], S], [1720, [0, 0, 0], A]],
      head: [[0, [0, 0, 0]], [320, [-10, 0, 0], P], [1520, [2, 0, 0], S]],
      sq: [[0, 1], [120, 0.94, S], [320, 1.06, O], [900, 1], [1580, 0.92, O], [1720, 1, A]],
    },
    hr: "open",
    hl: "open",
  },
  // PULL REQUEST (v2): the worker raises the scroll 0-200 (a wind-up down first), holds it
  // high while it leaves his hand, then the arm follows through down
  raiseScroll: {
    dur: 1600,
    tracks: {
      rs: [[0, [0, 0, -6]], [120, [18, 0, -8], S], [330, [-166, 0, -12], P], [900, [-160, 0, -10], S], [1250, [-110, 0, -14], S]],
      re: [[0, [-10, 0, 0]], [120, [-60, 0, 0], S], [330, [-8, 0, 0], P], [1250, [-30, 0, 0], S]],
      ls: [[0, [0, 0, 6]], [330, [-20, 0, 18], P]],
      torso: [[0, [0, 0, 0]], [120, [8, 0, 0], S], [330, [-7, -6, 0], P], [1250, [0, 0, 0], S]],
      head: [[0, [0, 0, 0]], [120, [6, 0, 0], S], [330, [-16, 0, 0], P], [1250, [-4, 0, 0], S]],
      y: [[0, 0], [120, -0.6, S], [330, 0.3, O], [520, 0, A]],
      sq: [[0, 1], [120, 0.95, S], [330, 1.04, O], [560, 1, A]],
    },
    hr: "grip",
    prop: { r: "scroll", rRot: [0, 0, 90] },
  },
  // REJECTION (v2): the reviewer's head shake (250 ms), then a coil and a point back
  pointBack: {
    dur: 1700,
    tracks: {
      head: [[0, [0, 0, 0]], [60, [4, -16, 0], S], [125, [4, 16, 0], S], [190, [4, -11, 0], S], [250, [2, 0, 0], S], [540, [-4, -20, 0], P], [1400, [-2, -18, 0]]],
      rs: [[0, [0, 0, -6]], [330, [-40, 0, 12], S], [540, [-96, 0, -42], P], [1400, [-92, 0, -40], S]],
      re: [[0, [-10, 0, 0]], [330, [-70, 0, 0], S], [540, [0, 0, 0], P]],
      ls: [[0, [0, 0, 6]], [540, [-10, 0, 14], P], [1400, [-40, 0, 10], S]],
      le: [[0, [-10, 0, 0]], [540, [-60, 0, 0], P]],
      torso: [[0, [0, 0, 0]], [330, [4, 12, 0], S], [540, [-4, -16, 0], P], [1400, [-2, -12, 0], S]],
      pelvis: [[0, [0, 0, 0]], [330, [0, 8, 0], S], [540, [0, -10, 0], P]],
      rl: [[0, [0, 0, 0]], [540, [-14, 0, -6], P]],
      y: [[0, 0], [330, -0.5, S], [540, 0.2, O], [700, 0, A]],
    },
    hr: (t) => (t > 380 ? "point" : "fist"),
  },
  // CRITERIA: the list comes up with a small wind-up and is held out
  answerList: {
    dur: 1800,
    tracks: {
      rs: [[0, [0, 0, -6]], [150, [12, 0, -6], S], [400, [-104, 0, -10], P], [1400, [-98, 0, -10], S]],
      re: [[0, [-10, 0, 0]], [150, [-60, 0, 0], S], [400, [-28, 0, 0], P]],
      torso: [[0, [0, 0, 0]], [150, [6, 0, 0], S], [400, [-4, 0, 0], P]],
      head: [[0, [0, 0, 0]], [400, [8, 0, 0], P]],
      y: [[0, 0], [150, -0.4, S], [400, 0.15, O], [560, 0, A]],
    },
    hr: "grip",
    prop: { r: "criteriaList", rRot: [-90, 0, 0] },
  },
  // COMMIT (hammer home): three blows; each a wind-up with a hold at the top (15 %), a fast
  // strike, contact (cue: a 35 ms hitstop, 2 sparks, a thud), a recoil
  hammerHome: {
    dur: 1500,
    tracks: {
      rs: [[0, [-40, 0, -8]], [140, [-150, 0, -8], S], [200, [-154, 0, -8]], [300, [-40, 0, -8], ST], [360, [-50, 0, -8], O], [520, [-150, 0, -8], S], [580, [-154, 0, -8]], [680, [-40, 0, -8], ST], [740, [-50, 0, -8], O], [900, [-156, 0, -8], S], [990, [-160, 0, -8]], [1090, [-36, 0, -8], ST], [1180, [-48, 0, -8], O]],
      re: [[0, [-30, 0, 0]], [140, [-50, 0, 0], S], [300, [-10, 0, 0], ST], [520, [-50, 0, 0], S], [680, [-10, 0, 0], ST], [900, [-56, 0, 0], S], [1090, [-8, 0, 0], ST]],
      ls: [[0, [-40, 0, 10]], [300, [-46, 0, 10]]],
      le: [[0, [-40, 0, 0]]],
      torso: [[0, [16, 0, 0]], [140, [6, 0, 0], S], [300, [26, 0, 0], ST], [520, [6, 0, 0], S], [680, [26, 0, 0], ST], [900, [2, -4, 0], S], [1090, [30, 0, 0], ST], [1300, [18, 0, 0], A]],
      head: [[0, [8, 0, 0]], [300, [14, 0, 0], ST], [1090, [16, 0, 0], ST]],
      y: [[0, 0], [140, 0.2, S], [300, -0.6, ST], [520, 0.2, S], [680, -0.6, ST], [900, 0.3, S], [1090, -0.9, ST], [1300, 0, A]],
      rl: [[0, [-10, 0, -6]]],
      ll: [[0, [12, 0, 6]]],
    },
    cues: [[300, "hit"], [680, "hit"], [1090, "hit"]],
    hr: "grip",
    prop: { r: "hammer", rRot: [-80, 0, 0] },
  },
  // COMMIT (carry): a 200 ms crouch to the crate (squash 0.94), a lift (stretch 1.04),
  // carry in place (steps), set down with a thud, rise
  carryCrate: {
    dur: 2000,
    tracks: {
      torso: [[0, [0, 0, 0]], [220, [32, 0, 0], S], [480, [-2, 0, 0], P], [1450, [-2, 0, 0]], [1680, [28, 0, 0], S], [1900, [4, 0, 0], A]],
      head: [[0, [0, 0, 0]], [220, [18, 0, 0], S], [480, [-4, 0, 0], P], [1680, [14, 0, 0], S]],
      rs: [[0, [0, 0, -6]], [220, [-48, 0, -10], S], [480, [-80, 0, -6], P], [1680, [-50, 0, -8], S]],
      ls: [[0, [0, 0, 6]], [220, [-48, 0, 10], S], [480, [-80, 0, 6], P], [1680, [-50, 0, 8], S]],
      re: [[0, [-10, 0, 0]], [220, [-10, 0, 0]], [480, [-24, 0, 0], P]],
      le: [[0, [-10, 0, 0]], [220, [-10, 0, 0]], [480, [-24, 0, 0], P]],
      y: [[0, 0], [220, -1.4, S], [480, 0.2, O], [600, 0, A], [1680, -1.3, S], [1900, 0, A]],
      sq: [[0, 1], [220, 0.94, S], [480, 1.04, O], [640, 1, A], [1680, 0.95, S], [1900, 1, A]],
      march: [[0, 0], [480, 0], [560, 1], [1400, 1], [1480, 0]],
    },
    cues: [[1680, "thud"]],
    prop: { held: "crate" },
  },
  // MERGE (v2 + bible): the stamp wind-up 0-200 (squash 0.9, arm up), lands at 260 (cue:
  // a 60 ms hitstop, trauma 0.15, the card slides), recoil and settle
  stamp: {
    dur: 1300,
    tracks: {
      rs: [[0, [-20, 0, -6]], [200, [-150, 0, -10], O], [260, [-42, 0, -6], I], [360, [-54, 0, -6], O], [900, [-50, 0, -6], S]],
      re: [[0, [-20, 0, 0]], [200, [-60, 0, 0], O], [260, [-12, 0, 0], I], [900, [-20, 0, 0], S]],
      ls: [[0, [0, 0, 6]], [200, [10, 0, 20], O], [260, [-30, 0, 12], I]],
      torso: [[0, [0, 0, 0]], [200, [-9, 0, 0], O], [260, [26, 0, 0], I], [420, [20, 0, 0], O], [900, [16, 0, 0], S]],
      head: [[0, [0, 0, 0]], [200, [-12, 0, 0], O], [260, [12, 0, 0], I], [900, [4, 0, 0], S]],
      y: [[0, 0], [200, 0.4, O], [260, -1.2, I], [420, -0.7, O], [900, -0.4, S], [1200, 0, A]],
      sq: [[0, 1], [200, 1.05, O], [260, 0.9, I], [420, 1.0, A]],
    },
    cues: [[260, "stamp"]],
    hr: "grip",
    prop: { r: "stamp", rRot: [0, 0, 0] },
  },
  // the firstmate's whistle during the order: up to the mouth, two blows (chest pumps)
  whistle: {
    dur: 1300,
    tracks: {
      rs: [[0, [0, 0, -8]], [120, [10, 0, -4], S], [320, [-112, 0, 30], P]],
      re: [[0, [-10, 0, 0]], [320, [-92, 0, 0], P]],
      torso: [[0, [0, 0, 0]], [120, [6, 0, 0], S], [320, [-6, 0, 0], P], [560, [-2, 0, 0], S], [760, [-8, 0, 0], S], [980, [-3, 0, 0], S]],
      head: [[0, [0, 0, 0]], [320, [-12, 0, 0], P]],
      sq: [[0, 1], [320, 1.05, P], [560, 0.98, S], [760, 1.05, S], [980, 1, S]],
    },
    hr: "grip",
    prop: { r: "whistle", rRot: [-30, 0, 0] },
  },
  inspect: {
    dur: 2400,
    tracks: {
      torso: [[0, [0, 0, 0]], [300, [12, -10, 0], P]],
      head: [[0, [0, 0, 0]], [300, [14, -8, 0], P], [900, [12, 10, 0], S], [1500, [12, -8, 0], S], [2000, [12, 6, 0], S]],
      rs: [[0, [0, 0, -6]], [300, [-88, 0, 18], P]],
      re: [[0, [-10, 0, 0]], [300, [-50, 0, 0], P]],
      ls: [[0, [0, 0, 6]], [300, [-50, 0, -6], P]],
      le: [[0, [-10, 0, 0]], [300, [-40, 0, 0], P]],
    },
    hr: "grip",
    hl: "open",
    prop: { r: "magnifier", rRot: [-20, 0, 0], l: "map", lRot: [-60, 0, 0] },
  },
  // ARRIVAL (v2): the receiver jolts from +10 px at 108 % and settles over 550 ms (arrive)
  bark: {
    dur: 700,
    in: 1,
    tracks: {
      y: [[0, 0], [70, 1.2, O], [550, 0, A]],
      sq: [[0, 1], [70, 1.08, O], [550, 1, A]],
      head: [[0, [0, 0, 0]], [70, [-10, 0, 0], O], [550, [0, 0, 0], A]],
    },
  },
};

// ---------------------------------------------------------------- loops (phase 0..1)
const osc = (p) => {
  const s = Math.sin(p * Math.PI * 2);
  return Math.sign(s) * Math.abs(s) ** 0.6;
};
const ease = (k) => {
  const e = 0.5 - 0.5 * Math.cos(Math.PI * 2 * k);
  return e * e * (3 - 2 * e);
};
const lerp = (a, b, k) => a + (b - a) * k;
// a keyed loop: keys in phase (0..1), wrapped
const kl = (tracks) => (p) => {
  const o = {};
  for (const [ch, keys] of Object.entries(tracks)) o[ch] = keyed(keys, p);
  return o;
};
export const LOOPS = {
  idle: { T: 3, pose: () => ({ rs: [0, 0, -6], ls: [0, 0, 6], re: [-10, 0, 0], le: [-10, 0, 0], rl: [0, 0, -2], ll: [0, 0, 2] }) },
  lean: { T: 4, pose: (p) => ({ torso: [6, 0, 10], rs: [-30, 0, -24], re: [-70, 0, 0], ls: [-12, 0, 16], le: [-30, 0, 0], head: [0, 20 * osc(p), 0], pelvis: [0, 0, -6], rl: [4, 0, -3], ll: [-6, 0, 6] }) },
  coil: { T: 1.4, pose: (p) => ({ torso: [22, 0, 0], y: -0.5, rs: [-55 + 15 * osc(p), 0, -12 + 10 * osc(p + 0.25)], ls: [-55 - 15 * osc(p), 0, 12 - 10 * osc(p + 0.25)], re: [-30, 0, 0], le: [-30, 0, 0], rl: [-8, 0, -4], ll: [8, 0, 4] }), prop: { deck: "coil" } },
  mend: { T: 1.2, pose: (p) => ({ torso: [18, 0, 0], head: [22, 0, 0], y: -0.4, rs: [-48 + 10 * ease(p), 0, -6], ls: [-48, 0, 6], re: [-40 - 20 * ease(p), 0, 0], le: [-40, 0, 0] }), prop: { l: "sailcloth" } },
  lookout: { T: 4.2, pose: (p) => ({ head: [-6, 18 * osc(p), 0], torso: [0, 12 * osc(p - 0.02), 0], pelvis: [0, 5 * osc(p - 0.05), 0], rs: [-150, 0, 26], re: [-70, 0, 0], ls: [-110, 0, -10], le: [-50, 0, 0], rl: [-6, 0, -4], ll: [6, 0, 4] }), prop: { r: "spyglass", rRot: [70, -6, 0] } },
  signal: { T: 0.8, pose: (p) => ({ rs: [-145 + 13 * osc(p), 0, -30], re: [-10, 0, 0], ls: [-20, 0, 10], le: [-20, 0, 0], head: [-8, 0, 0] }), prop: { r: "flag", rRot: [-90, 0, 0] } },
  point: { T: 3, pose: (p) => ({ y: 0.6 * ease(p), head: [4 * ease(p - 0.03), 0, 0], rs: [-92, 10, -10], re: [0, 0, 0], ls: [-50, 0, 20], le: [-40, 0, 0], hr: "point" }), prop: { deck: "chartTable" } },
  log: { T: 0.9, pose: (p) => ({ head: [18, 0, 0], ls: [-62, 0, 14], le: [-60, 0, 0], rs: [-58 + 8 * osc(p), 0, -10], re: [-64 + 6 * osc(2 * p), 0, 0] }), prop: { l: "logbook", lRot: [-60, 0, 0], r: "quill", rRot: [-30, 0, 0] } },
  // HAUL (bible): reach, a pull with the pose snap, a 12 % hold at full pull (the knees
  // bend, the body leans back), recover; the rope tightens on each pull
  haul: {
    T: 1.25,
    pose: kl({
      rs: [[0, [-82, 0, -4]], [0.45, [-36, 0, -4], P], [0.57, [-38, 0, -4]], [1, [-82, 0, -4], S]],
      ls: [[0, [-82, 0, 4]], [0.45, [-36, 0, 4], P], [0.57, [-38, 0, 4]], [1, [-82, 0, 4], S]],
      re: [[0, [-8, 0, 0]], [0.45, [-52, 0, 0], P], [0.57, [-50, 0, 0]], [1, [-8, 0, 0], S]],
      le: [[0, [-8, 0, 0]], [0.45, [-52, 0, 0], P], [0.57, [-50, 0, 0]], [1, [-8, 0, 0], S]],
      torso: [[0, [12, 0, 0]], [0.45, [-16, 0, 0], P], [0.57, [-15, 0, 0]], [1, [12, 0, 0], S]],
      head: [[0, [6, 0, 0]], [0.45, [-10, 0, 0], P], [1, [6, 0, 0], S]],
      y: [[0, 0.2], [0.45, -1.1, P], [0.57, -1.0], [1, 0.2, S]],
      tension: [[0, 0.2], [0.45, 1, P], [0.57, 1], [0.8, 0.3, S], [1, 0.2]],
      rl: [[0, [-24, 0, -6]]],
      ll: [[0, [18, 0, 6]]],
    }),
    prop: { rope: true },
    cues: [[0.45, "pull"]],
  },
  capstan: { T: 4.4, pose: () => ({ torso: [24, 0, 0], rs: [-80, 0, -6], ls: [-80, 0, 6], re: [-10, 0, 0], le: [-10, 0, 0] }), walk: "circle", prop: { deck: "capstan" } },
  carry: { T: 3.2, pose: () => ({ rs: [-78, 0, -6], ls: [-78, 0, 6], re: [-20, 0, 0], le: [-20, 0, 0] }), walk: "pace", prop: { held: "crate" } },
  climb: { T: 1.4, pose: (p) => ({ rs: [lerp(-124, -70, ease(p)), 0, -8], ls: [lerp(-70, -124, ease(p)), 0, 8], re: [-20, 0, 0], le: [-20, 0, 0], rl: [-30 * ease(p), 0, 0], ll: [-30 * (1 - ease(p)), 0, 0] }), walk: "climb", noIK: true },
  // HAMMER (bible): the arm from the top (held 15 %) down to the plank, the head of the
  // swing at 45 %; contact: a 35 ms local hitstop, 2 sparks, a thud
  hammer: {
    T: 0.62,
    pose: kl({
      rs: [[0, [-150, 0, -8]], [0.15, [-153, 0, -8]], [0.45, [-40, 0, -8], ST], [0.55, [-50, 0, -8], O], [1, [-150, 0, -8], S]],
      re: [[0, [-44, 0, 0]], [0.15, [-46, 0, 0]], [0.45, [-10, 0, 0], ST], [1, [-44, 0, 0], S]],
      torso: [[0, [8, 0, 0]], [0.15, [6, 0, 0]], [0.45, [24, 0, 0], ST], [1, [8, 0, 0], S]],
      head: [[0, [6, 0, 0]], [0.45, [14, 0, 0], ST], [1, [6, 0, 0], S]],
      y: [[0, 0.1], [0.45, -0.5, ST], [0.6, -0.3, O], [1, 0.1, S]],
      ls: [[0, [-40, 0, 10]]],
      le: [[0, [-40, 0, 0]]],
      rl: [[0, [-10, 0, -6]]],
      ll: [[0, [12, 0, 6]]],
    }),
    hr: "grip",
    prop: { r: "hammer", rRot: [-80, 0, 0], deck: "plank" },
    cues: [[0.45, "hit"]],
  },
  saw: { T: 0.7, pose: (p) => ({ torso: [22, 0, 0], y: -0.4, rs: [-62 + 22 * osc(p), 0, -6], re: [-44 + 22 * osc(p), 0, 0], ls: [-40, 0, 14], le: [-40, 0, 0], pelvis: [0, 4 * osc(p - 0.05), 0], rl: [-12, 0, -6], ll: [14, 0, 6] }), hr: "grip", prop: { r: "saw", rRot: [-10, 0, 0], deck: "sawhorse" } },
  swab: { T: 1.5, pose: (p) => ({ torso: [22, 12 * osc(p), 0], pelvis: [0, -8 * osc(p - 0.04), 0], rs: [-50 + 18 * osc(p), 0, -6], ls: [-40 + 18 * osc(p), 0, 6], re: [-20, 0, 0], le: [-40, 0, 0], y: -0.3, rl: [-8, 0, -6], ll: [8, 0, 6] }), hr: "grip", prop: { r: "swab", rRot: [60, 0, 0], deck: "bucket" } },
  helm: { T: 2.4, pose: (p) => ({ rs: [-64 + 12 * ease(p), 0, -8], ls: [-64 + 12 * ease(p), 0, 8], re: [-20, 0, 0], le: [-20, 0, 0], head: [0, 6 * ease(p - 0.05), 0] }) },
  review: { T: 4.2, pose: (p) => ({ head: [18, 14 * osc(p), 0], torso: [6, 5 * osc(p - 0.03), 0], rs: [-80, 0, 20], re: [-60, 0, 0], ls: [-55, 0, -10], le: [-40, 0, 0] }), hr: "grip", hl: "open", prop: { r: "magnifier", rRot: [-20, 0, 0], l: "map", lRot: [-60, 0, 0] } },
};
