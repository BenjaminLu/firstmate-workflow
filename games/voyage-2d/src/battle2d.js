// The kraken battle, v2.5: a pure, seedable reducer (no rendering), like v3's sim.
//
//   createBattle({ round, arms, seed })  -> battle
//   stepBattle(battle, action)           -> { battle, events }
//
// Core loop: the kraken telegraphs a strike (a wind-up bar you can read), the crew
// answer in the window: DODGE (full sail) anywhere in the late part, or PARRY (the
// cutlass) in the last sliver for a perfect block that opens a RIPOSTE window. Hits
// build the special gauge; a full gauge buys the specials. Twice in the fight (at
// 60 % and 25 % grip) the kraken lets loose its ultimate, MAELSTROM: a long wind-up,
// a brace phase (hold full sail through the swell), then the Crushing Tide with a
// parry window; a perfect parry turns the tide into the crew's own COUNTER BROADSIDE.
// At zero grip the fight waits for the finisher, and only an approval wins: the
// reviewer's APPROVED stamp and the captain's golden salvo end it.
export const TUNE = Object.freeze({
  grip: 100, // the kraken's grip (its health)
  hull: 100,
  patterns: {
    slam: { wind: 1.6, parry: 0.5, dodge: 0.6, tap: 0.55, dmg: 14, parryable: true },
    jab: { wind: 1.2, parry: 0.42, dodge: 0.5, tap: 0.45, dmg: 8, parryable: true },
    sweep: { wind: 1.8, parry: 0, dodge: 0.6, tap: 0.6, dmg: 16, parryable: false },
    ink: { wind: 1.5, parry: 0, dodge: 0, tap: 0.7, dmg: 6, parryable: false, shootable: true },
  },
  gap: { 3: 2.4, 4: 2.1, 5: 1.8 },
  fire: { dmg: 2, cooldown: 0.6 }, // tap the kraken between its strikes: fire at will
  mix: {
    3: ["slam", "jab", "slam", "ink", "jab", "sweep"],
    4: ["slam", "jab", "jab", "sweep", "slam", "ink", "jab", "slam"],
    5: ["jab", "slam", "jab", "sweep", "jab", "ink", "slam", "jab", "sweep"],
  },
  riposte: { window: 1.6, dmg: 9, crit: 15 },
  dodgeCounter: { window: 1.2, dmg: 5 },
  gauge: { parry: 30, dodge: 22, riposte: 16, hit: 3, max: 100 },
  specials: {
    broadside: { cost: 30, dmg: 3, shots: 7, charge: 1.0, zone: [0.72, 0.92], perfectBonus: 8 },
    harpoon: { cost: 50, dmg: 12, bind: 5 },
    order: { cost: 60, dmg: 4, volleys: 4 },
  },
  ultimate: {
    at: [60, 25],
    windup: 3.0, // the Maelstrom gathers (cut-in, whirlpool, arms up)
    brace: 1.6, // the swell: hold full sail through it
    strike: 1.0, // the Crushing Tide: parry in the last `parry` seconds
    parry: 0.5,
    dmg: 34,
    braceSave: 0.5, // a held brace halves the damage
    counter: 26, // the counter broadside on a perfect parry
  },
  stun: 2.4, // the crew down after a crushing hit when the hull breaks
});

function rng(b) {
  let a = (b.rng + 0x6d2b79f5) | 0;
  b.rng = a;
  let r = Math.imul(a ^ (a >>> 15), 1 | a);
  r = (r + Math.imul(r ^ (r >>> 7), 61 | r)) ^ r;
  return ((r ^ (r >>> 14)) >>> 0) / 4294967296;
}

export function createBattle({ round = 3, arms = 1, seed = 1 } = {}) {
  return {
    t: 0, seed, rng: seed | 0 || 1,
    round: Math.max(3, Math.min(5, round)), arms: Math.max(1, arms),
    grip: TUNE.grip, hull: TUNE.hull, gauge: 0, combo: 0, maxCombo: 0,
    mixIdx: 0, next: 2.0, attack: null,
    riposteUntil: 0, weak: false, counterUntil: 0,
    bound: [], boundUntil: 0,
    charge: null, // broadside charge start
    ult: null, ultDone: [],
    stunUntil: 0,
    phase: "fight", // fight | ultimate | finisher | won
    braceHeld: false,
    stats: { parries: 0, perfect: 0, dodges: 0, hits: 0, taken: 0, crits: 0, specials: 0 },
  };
}

// what the view reads each frame
export function attackView(b) {
  const a = b.attack;
  if (!a) return null;
  const P = TUNE.patterns[a.pattern];
  const k = Math.max(0, Math.min(1, (b.t - a.start) / P.wind));
  return { pattern: a.pattern, p: k, arm: a.arm, section: a.section, parryZone: P.parry / P.wind, dodgeZone: P.dodge / P.wind, parryable: P.parryable, answer: a.answer, shot: a.shot };
}
export function ultView(b) {
  const u = b.ult;
  if (!u) return null;
  const T = TUNE.ultimate;
  const e = b.t - u.start;
  const stage = e < T.windup ? "windup" : e < T.windup + T.brace ? "brace" : e < T.windup + T.brace + T.strike ? "strike" : "done";
  const sStart = stage === "windup" ? 0 : stage === "brace" ? T.windup : T.windup + T.brace;
  const sDur = stage === "windup" ? T.windup : stage === "brace" ? T.brace : T.strike;
  return { stage, p: Math.min(1, (e - sStart) / sDur), total: Math.min(1, e / (T.windup + T.brace + T.strike)), braced: u.braced, parried: u.parried, parryZone: T.parry / T.strike };
}

function hit(b, ev, dmg, source, extra = {}) {
  if (b.phase === "won") return;
  const d = Math.round(dmg * (b.t < b.boundUntil ? 1.25 : 1));
  b.grip = Math.max(0, b.grip - d);
  b.stats.hits++;
  b.gauge = Math.min(TUNE.gauge.max, b.gauge + TUNE.gauge.hit);
  ev.push({ type: "hit", dmg: d, source, grip: b.grip, ...extra });
  if (b.grip <= 0 && b.phase !== "finisher") {
    b.phase = "finisher";
    b.attack = null;
    b.ult = null;
    ev.push({ type: "finisher_ready" });
  }
  // the ultimate thresholds
  for (const at of TUNE.ultimate.at) {
    if (b.grip <= at && b.grip > 0 && !b.ultDone.includes(at) && b.phase === "fight") {
      b.ultDone.push(at);
      b.pendingUlt = true;
    }
  }
}
function takeHit(b, ev, dmg, what) {
  b.hull = Math.max(0, b.hull - dmg);
  b.stats.taken++;
  b.combo = 0;
  ev.push({ type: "struck", dmg, what, hull: b.hull });
  if (b.hull <= 0) {
    b.stunUntil = b.t + TUNE.stun;
    b.hull = 45; // the carpenters patch her up; the fight goes on
    ev.push({ type: "hull_broken", until: b.stunUntil });
  }
}

function tick(b, ev, dt) {
  const end = b.t + dt;
  while (b.t < end - 1e-9) {
    const h = Math.min(0.01, end - b.t);
    b.t += h;
    if (b.boundUntil && b.t >= b.boundUntil) (b.bound = []), (b.boundUntil = 0), ev.push({ type: "unbound" });
    if (b.riposteUntil && b.t > b.riposteUntil) (b.riposteUntil = 0), (b.weak = false), ev.push({ type: "riposte_closed" });
    if (b.phase === "finisher" || b.phase === "won") continue;
    // the ultimate
    if (b.ult) {
      const T = TUNE.ultimate, e = b.t - b.ult.start;
      if (!b.ult.said.brace && e >= T.windup) (b.ult.said.brace = true), ev.push({ type: "ult_brace" });
      if (b.ult.said.brace && e < T.windup + T.brace && b.braceHeld) b.ult.braceTime += h;
      if (!b.ult.said.strike && e >= T.windup + T.brace) {
        b.ult.said.strike = true;
        b.ult.braced = b.ult.braceTime >= T.brace * 0.6 || !!b.ult.tapBraced;
        ev.push({ type: "ult_strike", braced: b.ult.braced });
      }
      if (e >= T.windup + T.brace + T.strike) {
        const u = b.ult;
        b.ult = null;
        b.phase = "fight";
        b.next = b.t + 2.4;
        b.ultReadyAt = b.t + 9; // a breath before the second maelstrom
        if (u.parried) {
          b.stats.perfect++;
          ev.push({ type: "ult_countered" });
          b.gauge = TUNE.gauge.max;
          hit(b, ev, T.counter, "counter_broadside", { big: true, crit: true });
        } else {
          const dmg = Math.round(T.dmg * (u.braced ? T.braceSave : 1));
          ev.push({ type: "ult_landed", braced: u.braced });
          takeHit(b, ev, dmg, "maelstrom");
        }
      }
      continue;
    }
    if (b.pendingUlt && !b.attack && b.t >= (b.ultReadyAt || 0)) {
      b.pendingUlt = false;
      b.phase = "ultimate";
      b.ult = { start: b.t, braceTime: 0, braced: false, parried: false, said: {} };
      b.riposteUntil = 0;
      ev.push({ type: "ult_start" });
      continue;
    }
    if (b.t < b.stunUntil) continue;
    // start an attack
    if (!b.attack && b.t >= b.next) {
      const mix = TUNE.mix[b.round];
      const pattern = mix[b.mixIdx % mix.length];
      b.mixIdx++;
      let arm = Math.floor(rng(b) * b.arms);
      for (let i = 0; i < b.arms && b.bound.includes(arm); i++) arm = (arm + 1) % b.arms;
      if (b.bound.includes(arm)) {
        b.next = b.t + 0.8;
        continue;
      }
      b.attack = { pattern, start: b.t, arm, section: Math.floor(rng(b) * 4), answer: null, shot: false };
      const P = TUNE.patterns[pattern];
      ev.push({ type: "attack_start", pattern, arm, section: b.attack.section, wind: P.wind, parryable: P.parryable });
    }
    const a = b.attack;
    if (a) {
      const P = TUNE.patterns[a.pattern];
      if (b.t - a.start >= P.wind) {
        b.attack = null;
        b.next = b.t + TUNE.gap[b.round] * (0.8 + rng(b) * 0.4);
        if (a.answer === "parry") {
          b.stats.parries++;
          b.stats.perfect++;
          b.combo++;
          b.maxCombo = Math.max(b.maxCombo, b.combo);
          b.gauge = Math.min(TUNE.gauge.max, b.gauge + TUNE.gauge.parry);
          b.riposteUntil = b.t + TUNE.riposte.window;
          b.weak = true;
          ev.push({ type: "parried", pattern: a.pattern, section: a.section, combo: b.combo });
        } else if (a.answer === "dodge") {
          b.stats.dodges++;
          b.combo++;
          b.maxCombo = Math.max(b.maxCombo, b.combo);
          b.gauge = Math.min(TUNE.gauge.max, b.gauge + TUNE.gauge.dodge);
          b.riposteUntil = b.t + TUNE.dodgeCounter.window;
          b.weak = false;
          ev.push({ type: "dodged", pattern: a.pattern, section: a.section, combo: b.combo });
        } else if (a.shot) {
          ev.push({ type: "ink_shot" });
        } else {
          ev.push({ type: "strike", pattern: a.pattern, section: a.section, arm: a.arm });
          takeHit(b, ev, P.dmg, a.pattern);
        }
      }
    }
    // the broadside charge overflows: fired automatically at full
    if (b.charge !== null && b.t - b.charge > TUNE.specials.broadside.charge * 1.35) fireBroadside(b, ev);
  }
}

function fireBroadside(b, ev) {
  const S = TUNE.specials.broadside;
  const k = (b.t - b.charge) / S.charge;
  b.charge = null;
  const grade = k >= S.zone[0] && k <= S.zone[1] ? "perfect" : k >= 0.45 && k <= 1.1 ? "good" : "weak";
  b.stats.specials++;
  ev.push({ type: "broadside", grade });
  const n = grade === "weak" ? 3 : S.shots;
  for (let i = 0; i < n; i++) hit(b, ev, S.dmg, "broadside", { gun: i, delay: i * 0.08 });
  if (grade === "perfect") hit(b, ev, S.perfectBonus, "broadside", { heavy: true, delay: n * 0.08 + 0.1, crit: true });
  // an ink blob in the air is shot down by a broadside
  if (b.attack?.pattern === "ink") b.attack.shot = true;
}

export function stepBattle(battle, action) {
  const b = structuredClone(battle);
  const ev = [];
  act(b, ev, action);
  return { battle: b, events: ev };
}

// the one input of the click-first game: a tap does whatever the moment asks for
function tapAction(b, ev) {
  const now = b.t;
  if (b.phase === "won") return;
  if (b.phase === "finisher") {
    if (!b.finisherGo) (b.finisherGo = true), ev.push({ type: "finisher_go" });
    return;
  }
  if (b.ult) {
    const u = ultView(b);
    if (u.stage === "brace") {
      if (!b.ult.tapBraced) (b.ult.tapBraced = true), ev.push({ type: "bracing" });
    } else if (u.stage === "strike" && u.p >= 1 - u.parryZone) act(b, ev, { type: "parry" });
    else ev.push({ type: "wait" });
    return;
  }
  const a = b.attack;
  if (a && !a.answer) {
    const P = TUNE.patterns[a.pattern];
    const left = P.wind - (now - a.start);
    if (left > P.tap) return void ev.push({ type: "wait" }); // too soon: no penalty, just wait
    if (a.pattern === "ink") return void ((a.answer = "shot"), (a.shot = true), ev.push({ type: "ink_shot_ok" }));
    if (P.parryable) (a.answer = "parry"), ev.push({ type: "parry_ok", pattern: a.pattern });
    else (a.answer = "dodge"), ev.push({ type: "dodge_ok", pattern: a.pattern });
    return;
  }
  if (a) return;
  if (b.riposteUntil && now <= b.riposteUntil) return act(b, ev, { type: "parry" });
  // nothing to answer: fire at will
  if (now >= (b.fireReadyAt || 0)) {
    b.fireReadyAt = now + TUNE.fire.cooldown;
    hit(b, ev, TUNE.fire.dmg, "shot");
  }
}

// the special button: one press, the next special in the rotation, at a full gauge
export function nextSpecial(b) {
  const order = b.arms > 1 ? ["broadside", "harpoon", "order"] : ["broadside", "order"];
  return order[(b.specialIdx || 0) % order.length];
}

function act(b, ev, action) {
  const now = () => b.t;
  switch (action.type) {
    case "tap":
      tapAction(b, ev);
      break;
    case "special": {
      if (b.phase !== "fight" || b.ult) break;
      if (b.gauge < TUNE.gauge.max) {
        ev.push({ type: "no_gauge", special: "special" });
        break;
      }
      const kind = nextSpecial(b);
      b.specialIdx = (b.specialIdx || 0) + 1;
      b.gauge = TUNE.specials[kind].cost;
      if (kind === "broadside") {
        b.gauge -= TUNE.specials.broadside.cost;
        b.charge = now() - TUNE.specials.broadside.charge * 0.82; // the button always fires in the gold
        fireBroadside(b, ev);
      } else act(b, ev, { type: kind });
      break;
    }
    case "tick":
      tick(b, ev, action.dt);
      break;
    case "dodge": {
      // full sail: late in a dodgeable wind-up; also braces during the ultimate
      if (b.ult) break;
      const a = b.attack;
      if (!a) {
        ev.push({ type: "whiff", what: "dodge" });
        break;
      }
      const P = TUNE.patterns[a.pattern];
      const left = P.wind - (now() - a.start);
      if (a.answer) break;
      if (P.dodge && left <= P.dodge && left >= 0) (a.answer = "dodge"), ev.push({ type: "dodge_ok", pattern: a.pattern });
      else (a.answer = "early"), ev.push({ type: "dodge_early", pattern: a.pattern });
      break;
    }
    case "brace":
      b.braceHeld = !!action.on;
      if (action.on && b.ult && ultView(b).stage === "brace") ev.push({ type: "bracing" });
      break;
    case "parry": {
      if (b.phase === "finisher") break;
      if (b.ult) {
        const T = TUNE.ultimate, e = now() - b.ult.start, s0 = T.windup + T.brace;
        const left = s0 + T.strike - e;
        if (e >= s0 && left <= T.parry && left >= 0 && !b.ult.parried && !b.ult.tried) (b.ult.parried = true), ev.push({ type: "ult_parry" });
        else if (e >= s0 && !b.ult.parried) (b.ult.tried = true), ev.push({ type: "parry_miss", ult: true });
        break;
      }
      // the parry doubles as the riposte when a window is open
      if (b.riposteUntil && now() <= b.riposteUntil && !b.attack) {
        const crit = b.weak;
        b.stats.crits += crit ? 1 : 0;
        b.combo++;
        b.maxCombo = Math.max(b.maxCombo, b.combo);
        b.gauge = Math.min(TUNE.gauge.max, b.gauge + TUNE.gauge.riposte);
        b.riposteUntil = 0;
        b.weak = false;
        hit(b, ev, crit ? TUNE.riposte.crit + Math.min(6, b.combo) : TUNE.dodgeCounter.dmg, "riposte", { crit, combo: b.combo });
        break;
      }
      const a = b.attack;
      if (!a || a.answer) {
        ev.push({ type: "whiff", what: "parry" });
        break;
      }
      const P = TUNE.patterns[a.pattern];
      const left = P.wind - (now() - a.start);
      if (P.parryable && left <= P.parry && left >= 0) (a.answer = "parry"), ev.push({ type: "parry_ok", pattern: a.pattern });
      else (a.answer = "early"), ev.push({ type: "parry_miss", pattern: a.pattern });
      break;
    }
    case "broadsideStart":
      if (b.phase === "finisher" || b.ult) break;
      if (b.gauge < TUNE.specials.broadside.cost) {
        ev.push({ type: "no_gauge", special: "broadside" });
        break;
      }
      if (b.charge === null) (b.gauge -= TUNE.specials.broadside.cost), (b.charge = now()), ev.push({ type: "broadside_charge" });
      break;
    case "broadsideFire":
      if (b.charge !== null) fireBroadside(b, ev);
      break;
    case "harpoon": {
      if (b.phase === "finisher" || b.ult) break;
      const S = TUNE.specials.harpoon;
      if (b.gauge < S.cost) {
        ev.push({ type: "no_gauge", special: "harpoon" });
        break;
      }
      b.gauge -= S.cost;
      b.stats.specials++;
      const arm = action.arm ?? b.attack?.arm ?? 0;
      b.bound = [...new Set([...b.bound, arm, (arm + 1) % b.arms])];
      b.boundUntil = now() + S.bind;
      if (b.attack && b.bound.includes(b.attack.arm)) ev.push({ type: "attack_cancel", pattern: b.attack.pattern }), (b.attack = null), (b.next = now() + 1.6);
      ev.push({ type: "harpoon", arms: b.bound });
      hit(b, ev, S.dmg, "harpoon", { big: true, delay: 0.55 });
      break;
    }
    case "order": {
      if (b.phase === "finisher" || b.ult) break;
      const S = TUNE.specials.order;
      if (b.gauge < S.cost) {
        ev.push({ type: "no_gauge", special: "order" });
        break;
      }
      b.gauge -= S.cost;
      b.stats.specials++;
      ev.push({ type: "all_hands" });
      for (let i = 0; i < S.volleys; i++) hit(b, ev, S.dmg, "order", { delay: 0.7 + i * 0.22, volley: i });
      break;
    }
    case "finish":
      if (b.phase !== "finisher") break;
      b.phase = "won";
      ev.push({ type: "finisher" });
      ev.push({ type: "won", stats: b.stats, maxCombo: b.maxCombo });
      break;
    case "setRound":
      b.round = Math.max(3, Math.min(5, action.round));
      break;
    case "setArms":
      b.arms = Math.max(1, action.arms);
      break;
  }
}
