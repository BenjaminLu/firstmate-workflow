// The kraken battle mini-game (T-086 README "The battle mini-game" and "The
// kraken's attacks"), as a pure, deterministic reducer:
//
//   createBattle({ round, arms })      -> battle state
//   stepBattle(b, action)              -> { battle, events }   (never mutates b)
//
// Attacks walk a fixed list by review round, never at random. Every blow lands
// on the HEAD; arms are only ever picked (chain-shot) and never hit. Skills can
// bruise and reel the kraken but never sink it: only an approval (from the
// voyage sim) wins.
export const SKILLS = Object.freeze({
  broadside: { key: "1", cd: 8, name: "Broadside" },
  chain: { key: "2", cd: 15, name: "Chain-shot" },
  harpoon: { key: "3", cd: 12, name: "Harpoon" },
  sail: { key: "4", cd: 10, name: "Full sail" },
  order: { key: "5", cd: 30, name: "Captain's order" },
  repair: { key: "6", cd: 6, name: "Repair" },
});
export const PATTERNS = Object.freeze({
  slam: { bar: 1.6, zone: 0.14, weight: 3, rear: 1 },
  jab: { bar: 0.85, zone: 0.16, weight: 2, rear: 0.45 },
  combo: { bar: 1.15, zone: 0.15, weight: 2.5, rear: 0.75, second: { beat: 0.26, bar: 0.7, zone: 0.17 } },
  feint: { bar: 1.96, zone: 0.14, weight: 3, rear: 1, hold: { at: 0.55, fill: 0.88, dur: 0.7, rest: 0.38 } },
});
const MIX = {
  3: { list: ["slam", "jab", "slam", "slam", "jab"], gap: 5.2 },
  4: { list: ["slam", "jab", "combo", "slam", "combo", "jab"], gap: 4.4 },
  5: { list: ["slam", "feint", "combo", "jab", "feint", "combo", "slam", "jab"], gap: 3.6 },
};
const RING = { from: 96, to: 0, dur: 1.1, brass: 26 }; // broadside aim ring (px in the design)
const SECTIONS = 4; // deck sections the kraken can strike

export function createBattle({ round = 3, arms = 1, seed = 1 } = {}) {
  return {
    t: 0,
    round,
    arms,
    mixIdx: 0,
    nextAttack: 2.4,
    attack: null, // { pattern, start, section, arm, part, dodge, bar, zone }
    counterUntil: 0,
    weakPoint: false,
    combo: 0,
    bruise: 0,
    reelUntil: 0,
    cooldowns: { broadside: 0, chain: 0, harpoon: 0, sail: 0, order: 0, repair: 0 },
    aim: null, // broadside aim start time
    charge: null, // harpoon charge start time
    bound: [], // arm indices, until t
    boundUntil: 0,
    orderUntil: 0,
    nextGun: 2.4,
    splinters: [], // deck sections splintered
    slowUntil: 0,
    seed,
    n: 0,
    stats: { blows: 0, perfect: 0, dodges: 0, strikes: 0, crits: 0 },
  };
}
function mixFor(round) {
  return MIX[Math.min(5, Math.max(3, round))];
}
// bar fill p (0..1) of the current attack part at time t; the feint holds
function barFill(a, t) {
  const P = PATTERNS[a.pattern];
  const e = t - a.start;
  if (a.pattern === "feint") {
    const h = P.hold;
    const t1 = h.fill;
    if (e < t1) return (e / t1) * h.at;
    if (e < t1 + h.dur) return h.at;
    return Math.min(1, h.at + ((e - t1 - h.dur) / h.rest) * (1 - h.at));
  }
  const bar = a.part === 2 ? P.second.bar : P.bar;
  return Math.min(1, e / bar);
}
function inHold(a, t) {
  if (a.pattern !== "feint") return false;
  const h = PATTERNS.feint.hold;
  const e = t - a.start;
  return e >= h.fill && e < h.fill + h.dur;
}
function zoneOf(a) {
  const P = PATTERNS[a.pattern];
  return a.part === 2 ? P.second.zone : P.zone;
}
function durationOf(a) {
  const P = PATTERNS[a.pattern];
  if (a.pattern === "feint") return P.hold.fill + P.hold.dur + P.hold.rest;
  return a.part === 2 ? P.second.bar : P.bar;
}
export function attackState(b) {
  if (!b.attack) return null;
  const a = b.attack;
  return { pattern: a.pattern, part: a.part, p: barFill(a, b.t), zone: zoneOf(a), hold: inHold(a, b.t), section: a.section, arm: a.arm, dodge: a.dodge };
}
function blow(b, ev, weight, source, extra = {}) {
  b.stats.blows++;
  b.bruise += weight;
  ev.push({ type: "blow", weight, source, target: "head", n: b.n++, ...extra });
  if (b.bruise >= 10 && b.t >= b.reelUntil) {
    b.bruise = 0;
    b.reelUntil = b.t + 3;
    if (b.attack) {
      ev.push({ type: "attack_cancel", pattern: b.attack.pattern });
      b.attack = null;
    }
    b.nextAttack = Math.max(b.nextAttack, b.reelUntil + 0.8);
    ev.push({ type: "reel", until: b.reelUntil });
  }
}
function ready(b, id) {
  return b.cooldowns[id] <= b.t;
}
function use(b, id) {
  b.cooldowns[id] = b.t + SKILLS[id].cd;
}

function advance(b, ev, dt) {
  const end = b.t + dt;
  // step in small slices so every threshold lands in order
  while (b.t < end - 1e-9) {
    const h = Math.min(0.02, end - b.t);
    b.t += h;
    if (b.boundUntil && b.t >= b.boundUntil) {
      b.bound = [];
      b.boundUntil = 0;
      ev.push({ type: "unbound" });
    }
    // the crew's guns: weight 1 every 2.4 s (1.2 s under the captain's order)
    if (b.t >= b.nextGun) {
      b.nextGun = b.t + (b.t < b.orderUntil ? 1.2 : 2.4);
      blow(b, ev, 1, "crew");
    }
    // next attack from the round's fixed list; bound arms and a reel pause it
    if (!b.attack && b.t >= b.nextAttack && b.t >= b.reelUntil) {
      const mix = mixFor(b.round);
      const pattern = mix.list[b.mixIdx % mix.list.length];
      b.mixIdx++;
      let arm = b.mixIdx % Math.max(1, b.arms);
      for (let k = 0; k < b.arms && b.bound.includes(arm); k++) arm = (arm + 1) % b.arms;
      if (b.bound.includes(arm)) {
        b.nextAttack = b.t + 1;
        continue;
      }
      b.attack = { pattern, start: b.t, section: b.mixIdx % SECTIONS, arm, part: 1, dodge: null };
      ev.push({ type: "attack_start", pattern, section: b.attack.section, arm, part: 1, bar: durationOf(b.attack), zone: zoneOf(b.attack) });
    }
    const a = b.attack;
    if (a && a.pattern === "feint" && !a.heldSaid && inHold(a, b.t)) {
      a.heldSaid = true;
      ev.push({ type: "feint_hold" });
    }
    if (a && b.t - a.start >= durationOf(a)) {
      const P = PATTERNS[a.pattern];
      if (a.dodge === "dodge" || a.dodge === "perfect") {
        ev.push({ type: "into_sea", section: a.section, arm: a.arm, pattern: a.pattern });
      } else {
        const w = a.pattern === "feint" && a.dodge === "early_hold" ? 4 : P.weight;
        b.stats.strikes++;
        b.combo = 0;
        if (!b.splinters.includes(a.section)) b.splinters.push(a.section);
        ev.push({ type: "strike", section: a.section, arm: a.arm, weight: w, pattern: a.pattern });
      }
      if (a.pattern === "combo" && a.part === 1) {
        b.attack = { pattern: "combo", start: b.t + P.second.beat, section: (a.section + 1) % SECTIONS, arm: a.arm, part: 2, dodge: null };
        ev.push({ type: "attack_start", pattern: "combo", section: b.attack.section, arm: a.arm, part: 2, bar: P.second.bar, zone: P.second.zone, delay: P.second.beat });
      } else {
        b.attack = null;
        b.nextAttack = b.t + mixFor(b.round).gap;
      }
    }
    if (b.counterUntil && b.t >= b.counterUntil) {
      b.counterUntil = 0;
      b.weakPoint = false;
      ev.push({ type: "counter_close" });
    }
  }
}

export function stepBattle(battle, action) {
  const b = structuredClone(battle);
  const ev = [];
  switch (action.type) {
    case "tick":
      advance(b, ev, action.dt * (b.t < b.slowUntil ? 0.3 : 1));
      break;
    case "sail": {
      // Full sail: read the bar. Too early (or into a feint's hold) reloads and
      // the strike lands; a dodge in the window costs nothing and opens a
      // counter; the perfect zone slows the world and shows the weak point.
      if (!ready(b, "sail")) {
        ev.push({ type: "cooldown", skill: "sail" });
        break;
      }
      const a = b.attack;
      if (!a || b.t < a.start) {
        use(b, "sail");
        ev.push({ type: "dodge", result: "nothing", reload: true });
        break;
      }
      const p = barFill(a, b.t);
      if (inHold(a, b.t) || p < 0.5) {
        use(b, "sail");
        a.dodge = a.pattern === "feint" && inHold(a, b.t) ? "early_hold" : "early";
        b.combo = 0;
        ev.push({ type: "dodge", result: "early", reload: true, p });
      } else if (p >= 1 - zoneOf(a)) {
        a.dodge = "perfect";
        b.combo++;
        b.stats.perfect++;
        b.stats.dodges++;
        b.slowUntil = b.t + 0.48;
        b.counterUntil = b.t + 0.48 + 2;
        b.weakPoint = true;
        ev.push({ type: "dodge", result: "perfect", combo: b.combo, p });
      } else {
        a.dodge = "dodge";
        b.combo = 0;
        b.stats.dodges++;
        b.counterUntil = b.t + 1.5;
        b.weakPoint = false;
        ev.push({ type: "dodge", result: "dodge", p });
      }
      break;
    }
    case "counter": {
      if (!b.counterUntil || b.t > b.counterUntil) {
        ev.push({ type: "no_counter" });
        break;
      }
      if (b.weakPoint) {
        const w = Math.min(6, 4.5 + 0.5 * Math.max(0, b.combo - 1));
        b.stats.crits++;
        blow(b, ev, w, "crit", { crit: true, combo: b.combo });
      } else blow(b, ev, 3.2, "counter");
      b.counterUntil = 0;
      b.weakPoint = false;
      break;
    }
    case "broadsideAim":
      if (!ready(b, "broadside")) ev.push({ type: "cooldown", skill: "broadside" });
      else if (b.aim === null) {
        b.aim = b.t;
        ev.push({ type: "broadside_aim", dur: RING.dur });
      }
      break;
    case "broadsideFire": {
      if (b.aim === null) break;
      const k = Math.min(1, (b.t - b.aim) / RING.dur);
      const r = RING.from + (RING.to - RING.from) * k;
      const off = Math.abs(r - RING.brass);
      const grade = off <= 5 ? "perfect" : off <= 14 ? "good" : "glancing";
      const w = grade === "perfect" ? 3 : grade === "good" ? 2 : 1;
      b.aim = null;
      use(b, "broadside");
      ev.push({ type: "broadside", grade, off: +off.toFixed(1) });
      for (let i = 0; i < 3; i++) blow(b, ev, w, "broadside", { gun: i, delay: i * 0.09 });
      if (grade === "perfect") blow(b, ev, 3.5, "broadside", { gun: 3, delay: 0.3, heavy: true });
      break;
    }
    case "chain": {
      if (!ready(b, "chain")) {
        ev.push({ type: "cooldown", skill: "chain" });
        break;
      }
      const arms = (action.arms && action.arms.length === 2 ? action.arms : [action.arm ?? 0, ((action.arm ?? 0) + 1) % Math.max(1, b.arms)]).map((x) => x % Math.max(1, b.arms));
      use(b, "chain");
      b.bound = [...new Set(arms)];
      b.boundUntil = b.t + 6;
      if (b.attack && b.bound.includes(b.attack.arm)) {
        ev.push({ type: "attack_cancel", pattern: b.attack.pattern });
        b.attack = null;
        b.nextAttack = b.t + 1.5;
      }
      ev.push({ type: "bound", arms: b.bound, until: b.boundUntil });
      blow(b, ev, 2, "chain");
      break;
    }
    case "harpoonStart":
      if (!ready(b, "harpoon")) ev.push({ type: "cooldown", skill: "harpoon" });
      else if (b.charge === null) {
        b.charge = b.t;
        ev.push({ type: "harpoon_charge" });
      }
      break;
    case "harpoonRelease": {
      if (b.charge === null) break;
      const k = Math.min(1, (b.t - b.charge) / 1.5);
      const w = 1 + Math.round(k * 3);
      b.charge = null;
      use(b, "harpoon");
      ev.push({ type: "harpoon", weight: w });
      blow(b, ev, w, "harpoon");
      if (w === 4) blow(b, ev, 2, "harpoon", { delay: 0.15, second: true });
      break;
    }
    case "harpoonCancel":
      b.charge = null;
      break;
    case "order":
      if (!ready(b, "order")) {
        ev.push({ type: "cooldown", skill: "order" });
        break;
      }
      use(b, "order");
      b.orderUntil = b.t + 5;
      b.nextGun = Math.min(b.nextGun, b.t + 1.2);
      ev.push({ type: "volley" });
      blow(b, ev, 1.5, "order", { delay: 0.5 });
      blow(b, ev, 1.5, "order", { delay: 0.7 });
      break;
    case "repair": {
      if (!ready(b, "repair")) {
        ev.push({ type: "cooldown", skill: "repair" });
        break;
      }
      const sec = action.section ?? b.splinters[0];
      if (sec === undefined || !b.splinters.includes(sec)) {
        ev.push({ type: "nothing_to_repair" });
        break;
      }
      use(b, "repair");
      b.splinters = b.splinters.filter((x) => x !== sec);
      ev.push({ type: "repaired", section: sec });
      break;
    }
    case "setRound":
      b.round = action.round;
      break;
    case "setArms":
      b.arms = Math.max(1, action.arms);
      break;
    case "hit": // a real push from the voyage: a hit on the head
      blow(b, ev, 2, "push");
      break;
  }
  return { battle: b, events: ev };
}
