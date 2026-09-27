// The voyage simulation: firstmate's crew loop as a pure, seedable reducer.
//
//   createSim(seed)            -> state
//   step(state, action)        -> { state, events }   (never mutates its input)
//
// Everything that happens is either a player action or an entry on the seeded
// schedule, fired by `tick`. The same seed and the same actions give the same
// events, frame rate independent (ticks are split at scheduled times).
// Events carry what the scene needs to animate; `log` lines are what the board
// would write.
import { CONFIG, TITLES, CREW_FIXTURE } from "./config.js";

// ---------------------------------------------------------------- seeded rng (state lives in the sim state)
function nextRand(s) {
  let a = (s.rng + 0x6d2b79f5) | 0;
  s.rng = a;
  let r = Math.imul(a ^ (a >>> 15), 1 | a);
  r = (r + Math.imul(r ^ (r >>> 7), 61 | r)) ^ r;
  return ((r ^ (r >>> 14)) >>> 0) / 4294967296;
}
const between = (s, [a, b]) => a + nextRand(s) * (b - a);
const intBetween = (s, [a, b]) => a + Math.floor(nextRand(s) * (b - a + 1));
function pickWeighted(s, weights) {
  let r = nextRand(s);
  for (let i = 0; i < weights.length; i++) {
    r -= weights[i];
    if (r <= 0) return i;
  }
  return weights.length - 1;
}

export const LANES = ["issues", "backlog", "ready", "working", "review", "merged"];
export const STATIONS = {
  // deck-pooled actions by station (prototype v2, crew table)
  top: ["lookout", "signal", "point", "log"],
  amidships: ["haul", "capstan", "carry", "climb"],
  main: ["hammer", "saw", "swab", "carry"],
  idle: ["lean", "coil", "mend"],
};

// ---------------------------------------------------------------- creation
export function createSim(seed = 1) {
  const s = {
    seed,
    rng: seed | 0 || 1,
    t: 0,
    nextTask: 101,
    nextDecision: 1100,
    tasks: [],
    crew: CREW_FIXTURE.map((c) => ({
      ...c,
      state: "idle",
      task: null,
      station: null,
      action: null,
      standing: c.standing ?? 0,
      merges: c.merges ?? 0,
      firstPass: c.firstPass ?? 0,
      approvals: c.approvals ?? 0,
      rank: 0,
      record: [],
      honours: [],
    })),
    decisions: [],
    schedule: [],
    milestones: [],
    port: 0, // index of the last port reached (M0 = home waters)
    kraken: { arms: [], battle: null, fled: false },
    gate: {}, // taskId -> "red" | "green"
    log: [],
    rituals: { port: true, salute: true, clearing: true, weather: true, kraken: true, order: true, salvo: true },
    stats: { merged: 0, dispatched: 0, approvals: 0, rejections: 0, battlesWon: 0 },
    seq: 0,
  };
  for (const c of s.crew) c.rank = rankIndex(c);
  // the opening voyage: three milestones of tasks, M1 ready, the rest behind
  const plan = [
    ["M1", 3],
    ["M2", 4],
    ["M3", 4],
  ];
  let prev = null;
  for (const [m, n] of plan) {
    const ids = [];
    for (let i = 0; i < n; i++) {
      const t = makeTask(s, m, prev && i === 0 ? [prev] : []);
      ids.push(t.id);
      prev = t.id;
    }
    s.milestones.push({ id: m, tasks: ids });
  }
  for (const t of s.tasks) t.lane = t.deps.length ? "backlog" : t.milestone === "M1" ? "ready" : "backlog";
  // Playground's kraken: the first ready task (the one dispatched first) is stubborn. The
  // seeded world holds it for two rounds past the kraken's (from_round + 2 in all), and it
  // raises no card on the way, so every simulated voyage meets the kraken early, in its first
  // two minutes, and it holds on long enough to be faced. Only the sim: Live reads the kraken
  // from the board's own review rounds (live.js).
  const stubborn = s.tasks.find((t) => t.lane === "ready");
  stubborn.rounds = Math.max(stubborn.rounds, CONFIG.kraken.from_round + 2);
  stubborn.flags.decision = false;
  // two open issues sit in the fog
  s.tasks.push(issue(s, 91, "Chart: tidewater's own voyage"));
  s.tasks.push(issue(s, 92, "Sound: ambient sea level"));
  return s;
}
function issue(s, n, title) {
  return { id: "#" + n, issue: n, title, lane: "issues", milestone: "M3", deps: [], worker: null, round: 0, approved: false, rounds: 1, flags: {} };
}
function makeTask(s, milestone, deps) {
  const id = "T-" + s.nextTask++;
  const t = {
    id,
    title: TITLES[(s.nextTask - 102) % TITLES.length],
    milestone,
    deps,
    lane: "ready",
    worker: null,
    round: 0, // review rounds so far
    approved: false,
    // what the seeded world holds for this task, drawn once when it is created
    rounds: 1 + pickWeighted(s, CONFIG.roundsWeights),
    flags: {
      ask: nextRand(s) < CONFIG.chance.askCriteria,
      decision: nextRand(s) < CONFIG.chance.decision,
      red: nextRand(s) < CONFIG.chance.gateRed,
      crash: nextRand(s) < CONFIG.chance.crash,
      vendor: nextRand(s) < CONFIG.chance.vendorDown,
    },
    commits: 0,
    course: null,
  };
  s.tasks.push(t);
  return t;
}

// ---------------------------------------------------------------- helpers
const task = (s, id) => s.tasks.find((t) => t.id === id);
const crewman = (s, id) => s.crew.find((c) => c.id === id);
function rankIndex(c) {
  const table = c.role === "reviewer" ? CONFIG.ranks.reviewer : c.role === "worker" ? CONFIG.ranks.worker : null;
  if (!table) return 0;
  const v = c.role === "reviewer" ? c.approvals : c.standing;
  let r = 0;
  table.forEach(([, th], i) => v >= th && (r = i));
  return r;
}
export function rankName(c) {
  const table = c.role === "reviewer" ? CONFIG.ranks.reviewer : c.role === "worker" ? CONFIG.ranks.worker : null;
  return table ? table[c.rank][0] : c.role;
}
export function nextRank(c) {
  const table = c.role === "reviewer" ? CONFIG.ranks.reviewer : c.role === "worker" ? CONFIG.ranks.worker : null;
  return table && table[c.rank + 1] ? { name: table[c.rank + 1][0], at: table[c.rank + 1][1] } : null;
}
function emit(s, ev, type, data = {}, line) {
  ev.push({ type, t: +s.t.toFixed(3), seq: s.seq++, ...data });
  if (line) {
    s.log.unshift({ t: +s.t.toFixed(2), text: line, kind: type });
    if (s.log.length > 80) s.log.length = 80;
  }
}
function at(s, dt, type, data = {}) {
  s.schedule.push({ at: +(s.t + dt).toFixed(4), type, ...data, n: s.seq++ });
}
function unschedule(s, pred) {
  s.schedule = s.schedule.filter((e) => !pred(e));
}
function pickStation(s, t) {
  const decks = ["top", "amidships", "main"];
  const deck = decks[(parseInt(t.id.slice(2), 10) + t.round) % 3];
  const pool = STATIONS[deck];
  return { deck, action: pool[Math.floor(nextRand(s) * pool.length)] };
}
function inFlight(s) {
  return s.tasks.filter((t) => t.lane === "working" || t.lane === "review");
}
function readyUnblocked(s) {
  return s.tasks.filter((t) => t.lane === "ready");
}
export function tally(s) {
  const c = (l) => s.tasks.filter((t) => t.lane === l).length;
  return {
    merged: c("merged"),
    inFlight: inFlight(s).length,
    waiting: s.decisions.length,
    blocked: Object.values(s.gate).filter((g) => g === "red").length + s.crew.filter((w) => w.state === "down").length,
    ready: c("ready"),
    backlog: c("backlog"),
  };
}
export function weather(s) {
  if (Object.values(s.gate).some((g) => g === "red") || s.decisions.length) return "squall";
  return inFlight(s).length ? "breeze" : "calm";
}
function raiseDecision(s, ev, d) {
  const dec = { id: "D-" + s.nextDecision++, ...d };
  // the kraken's card is the urgent one: it goes to the top of the deck, so the captain sees
  // it while the kraken still holds, not after the cards already waiting
  if (dec.kind === "kraken") s.decisions.unshift(dec);
  else s.decisions.push(dec);
  emit(s, ev, "decision_requested", { decision: dec }, `${dec.id} raised: ${dec.title}`);
  return dec;
}
function promote(s, ev, c, why) {
  const r = rankIndex(c);
  if (r > c.rank) {
    c.rank = r;
    const name = rankName(c);
    c.record.unshift({ t: s.t, text: `rated ${name} (${why})` });
    emit(s, ev, "promoted", { crew: c.id, rank: name, rankIdx: r }, `${c.name} rated ${name} (${why})`);
  }
}
function heldTasks(s) {
  return s.kraken.arms.slice();
}

// ---------------------------------------------------------------- the crew loop
function dispatch(s, ev, taskId) {
  const t = taskId ? task(s, taskId) : readyUnblocked(s).sort((a, b) => (a.course ?? 99) - (b.course ?? 99))[0];
  if (!t || t.lane !== "ready") {
    emit(s, ev, "caption", { text: "Nothing is ready to dispatch." });
    return;
  }
  const w = s.crew.find((c) => c.role === "worker" && c.state === "idle");
  if (!w) {
    emit(s, ev, "caption", { text: "Every hand is busy; the order waits for a free worker." });
    return;
  }
  const st = pickStation(s, t);
  t.lane = "working";
  t.worker = w.id;
  w.state = "walking";
  w.task = t.id;
  w.station = st.deck;
  w.action = st.action;
  s.stats.dispatched++;
  emit(s, ev, "order", { task: t.id, worker: w.id }, `Order: ${t.id} to ${w.name}. Aye, captain. Orders away.`);
  emit(s, ev, "card_move", { task: t.id, from: "ready", to: "working" });
  emit(s, ev, "worker_walk", { worker: w.id, station: st.deck, action: st.action, task: t.id });
  at(s, CONFIG.timing.walk, "work_start", { task: t.id });
}
function scheduleWork(s, t) {
  const n = intBetween(s, CONFIG.timing.commits);
  let dt = between(s, CONFIG.timing.firstPush);
  for (let i = 0; i < n; i++) {
    at(s, dt, "push", { task: t.id, last: i === n - 1, first: i === 0 });
    dt += between(s, CONFIG.timing.pushGap);
  }
}

// scheduled item -> state change + events
function fire(s, ev, e) {
  const t = e.task ? task(s, e.task) : null;
  if (t && (t.lane === "parked" || t.lane === "dropped" || t.lane === "merged")) return;
  const w = t && t.worker ? crewman(s, t.worker) : null;
  switch (e.type) {
    case "work_start": {
      if (!w) return;
      w.state = "working";
      emit(s, ev, "work_start", { task: t.id, worker: w.id, station: w.station, action: w.action });
      if (t.flags.ask && t.round === 0) {
        at(s, 1.2, "ask", { task: t.id });
        t.flags.ask = false;
      }
      if (t.flags.decision && t.round === 0) {
        t.flags.decision = false;
        at(s, 2.0, "decide", { task: t.id });
        return;
      }
      if (t.flags.crash) {
        t.flags.crash = false;
        at(s, 3.4, "crash", { task: t.id });
        return;
      }
      scheduleWork(s, t);
      return;
    }
    case "ask":
      emit(s, ev, "ask_pass_criteria", { task: t.id, worker: w?.id, reviewer: "reviewer-1" }, `${t.id}: ${w?.name} asked for the pass criteria`);
      at(s, CONFIG.timing.criteriaReply, "criteria", { task: t.id });
      return;
    case "criteria":
      emit(s, ev, "criteria_returned", { task: t.id, worker: w?.id, reviewer: "reviewer-1", items: 3 + (parseInt(t.id.slice(2), 10) % 3) }, `${t.id}: the reviewer returned the pass criteria`);
      return;
    case "decide": {
      if (w) w.state = "waiting";
      raiseDecision(s, ev, {
        kind: "choice",
        task: t.id,
        title: `How should ${t.id} land?`,
        body: `${w?.name} needs the captain's call on ${t.title.toLowerCase()} before going on.`,
        options: [
          { key: "A", label: "As specced", pro: "Keeps the plan", con: "The larger change", effect: "proceed" },
          { key: "B", label: "Rescope smaller", pro: "One review round fewer", con: "Leaves a follow-up", effect: "rescope" },
          { key: "C", label: "Park it", pro: "Frees the worker", con: "The task waits", effect: "park" },
        ],
      });
      return;
    }
    case "crash": {
      if (!w) return;
      const vendor = t.flags.vendor;
      w.state = "down";
      emit(s, ev, vendor ? "vendor_unavailable" : "worker_crashed", { task: t.id, worker: w.id }, vendor ? `${w.name}: ${w.vendor} is unavailable` : `${w.name} crashed on ${t.id}`);
      at(s, CONFIG.timing.crashRecover, "recover", { task: t.id });
      return;
    }
    case "recover": {
      if (!w) return;
      w.state = "working";
      emit(s, ev, "recovered", { task: t.id, worker: w.id }, `${w.name} re-dispatched on ${t.id}`);
      scheduleWork(s, t);
      return;
    }
    case "push": {
      if (!w) return;
      t.commits++;
      emit(s, ev, "commit_pushed", { task: t.id, worker: w.id, n: t.commits, inBattle: !!battleHolds(s, t.id) }, `${t.id}: ${w.name} pushed commit ${t.commits}`);
      if (t.flags.red && e.first) {
        t.flags.red = false;
        s.gate[t.id] = "red";
        w.state = "blocked";
        emit(s, ev, "gate_failed", { task: t.id, worker: w.id }, `${t.id}: the gate is red (weather, not blame)`);
        at(s, between(s, CONFIG.timing.redToGreen), "green", { task: t.id, last: e.last });
        return;
      }
      if (e.last) at(s, between(s, CONFIG.timing.prAfter), "pr", { task: t.id });
      return;
    }
    case "green": {
      if (s.gate[t.id] !== "red") return;
      s.gate[t.id] = "green";
      if (w) w.state = "working";
      emit(s, ev, "gate_green", { task: t.id, worker: w?.id }, `${t.id}: the check turned green`);
      if (e.last) at(s, between(s, CONFIG.timing.prAfter), "pr", { task: t.id });
      else at(s, between(s, CONFIG.timing.pushGap), "push", { task: t.id, last: true });
      return;
    }
    case "pr":
      openPR(s, ev, t);
      return;
    case "verdict":
      verdict(s, ev, t, e.force);
      return;
    case "fix":
      if (!w) return;
      t.commits++;
      w.state = "working";
      emit(s, ev, "commit_pushed", { task: t.id, worker: w.id, n: t.commits, fix: true, inBattle: !!battleHolds(s, t.id) }, `${t.id}: ${w.name} pushed a fix`);
      at(s, 2.2, "pr", { task: t.id, again: true });
      return;
  }
}
function openPR(s, ev, t) {
  const w = crewman(s, t.worker);
  if (t.lane !== "working" && !(t.lane === "review")) return;
  const from = t.lane;
  t.lane = "review";
  if (w) w.state = "standby";
  emit(s, ev, "pr_opened", { task: t.id, worker: w?.id, reviewer: "reviewer-1", round: t.round + 1 }, `${t.id}: pull request ${t.round ? "updated" : "opened"} by ${w?.name}`);
  if (from !== "review") emit(s, ev, "card_move", { task: t.id, from, to: "review" });
  unschedule(s, (e) => e.task === t.id && e.type === "verdict");
  at(s, between(s, CONFIG.timing.review), "verdict", { task: t.id });
}
function verdict(s, ev, t, force) {
  if (t.lane !== "review") return;
  const rev = crewman(s, "reviewer-1");
  const w = crewman(s, t.worker);
  t.round++;
  const approve = force ? force === "approve" : t.round >= t.rounds;
  if (approve) {
    t.approved = true;
    rev.approvals++;
    s.stats.approvals++;
    const first = t.round === 1;
    emit(s, ev, "review_approved", { task: t.id, worker: w?.id, reviewer: rev.id, firstRound: first, round: t.round }, `${t.id}: approved on round ${t.round}${first ? " (a salute)" : ""}`);
    promote(s, ev, rev, `${rev.approvals} approvals`);
    if (s.kraken.arms.includes(t.id)) releaseArm(s, ev, t.id, "victory");
    raiseDecision(s, ev, {
      kind: "merge",
      task: t.id,
      title: `Merge ${t.id}?`,
      body: `${t.title}. Approved on round ${t.round}; the seven gates are green.`,
      options: [
        { key: "A", label: "Merge", pro: "Makes way on the voyage", con: "—", effect: "merge" },
        { key: "B", label: "Send back", pro: "Another look", con: "One more round", effect: "sendback" },
        { key: "C", label: "Hold", pro: "Waits for the next port", con: "The task idles", effect: "hold" },
      ],
    });
  } else {
    s.stats.rejections++;
    emit(s, ev, "review_rejected", { task: t.id, worker: w?.id, reviewer: rev.id, round: t.round, inBattle: !!battleHolds(s, t.id) }, `${t.id}: round ${t.round} rejected; back to the station`);
    if (w) {
      w.state = "walking";
      emit(s, ev, "worker_walk", { worker: w.id, station: w.station, action: w.action, task: t.id, back: true });
    }
    if (t.round >= CONFIG.kraken.from_round && !s.kraken.arms.includes(t.id) && s.kraken.arms.length < CONFIG.kraken.max_arms) {
      s.kraken.arms.push(t.id);
      s.kraken.fled = false;
      emit(s, ev, "kraken_arm", { task: t.id, arms: s.kraken.arms.slice(), round: t.round }, `The kraken holds ${t.id} (round ${t.round})`);
      if (!s.decisions.some((d) => d.kind === "kraken")) {
        raiseDecision(s, ev, {
          kind: "kraken",
          task: t.id,
          title: `The kraken holds ${t.id}`,
          body: `${t.id} is at review round ${t.round} without approval. Face it, or let it go.`,
          options: [
            { key: "A", label: "Proceed: fight", pro: "The battle begins; play along", con: "Only an approval wins", effect: "battle" },
            { key: "B", label: "Rescope", pro: "It needs one round less", con: "The kraken waits far off", effect: "rescope" },
            { key: "C", label: "Park", pro: "The arm lets go", con: "The task waits in parked", effect: "park" },
            { key: "D", label: "Drop", pro: "The kraken goes down whole", con: "The work is dropped", effect: "drop" },
          ],
        });
      }
    } else if (battleHolds(s, t.id)) {
      emit(s, ev, "kraken_strike", { task: t.id, weight: 3 }, `The kraken strikes the deck: ${t.id} rejected again`);
    }
    t.lane = "working";
    emit(s, ev, "card_move", { task: t.id, from: "review", to: "working" });
    at(s, between(s, CONFIG.timing.fixPush), "fix", { task: t.id });
  }
}
function battleHolds(s, id) {
  return s.kraken.battle && s.kraken.arms.includes(id);
}
function releaseArm(s, ev, id, how) {
  s.kraken.arms = s.kraken.arms.filter((a) => a !== id);
  const w = s.tasks.find((t) => t.id === id)?.worker;
  if (how === "victory" && s.kraken.battle) {
    s.stats.battlesWon++;
    for (const cid of [w, "reviewer-1"]) {
      const c = cid && crewman(s, cid);
      if (c) {
        c.honours.unshift(`Beat the kraken for ${id}`);
        c.record.unshift({ t: s.t, text: `honour: the kraken beaten for ${id}` });
      }
    }
    emit(s, ev, "victory", { task: id, arms: s.kraken.arms.slice() }, `Victory: ${id} approved, the kraken lets go`);
  } else emit(s, ev, "kraken_let_go", { task: id, arms: s.kraken.arms.slice(), how }, `The kraken lets go of ${id}`);
  if (!s.kraken.arms.length) {
    s.kraken.battle = null;
    emit(s, ev, "kraken_down", { how });
  }
  s.decisions = s.decisions.filter((d) => !(d.kind === "kraken" && d.task === id));
}
function merge(s, ev, t) {
  const w = crewman(s, t.worker);
  t.lane = "merged";
  s.stats.merged++;
  delete s.gate[t.id];
  s.decisions = s.decisions.filter((d) => d.task !== t.id || d.kind !== "merge");
  const first = t.round === 1;
  emit(s, ev, "card_move", { task: t.id, from: "review", to: "merged" });
  emit(s, ev, "merged", { task: t.id, worker: w?.id, firstPass: first }, `${t.id} merged into main. Ahoy!`);
  if (w) {
    w.merges++;
    if (first) w.firstPass++;
    w.standing = w.merges + w.firstPass * CONFIG.ranks.first_pass_bonus;
    w.record.unshift({ t: s.t, text: `merged ${t.id}${first ? " on the first review" : ""}` });
    promote(s, ev, w, `${w.merges} merged, ${w.firstPass} on the first review`);
    w.state = "idle";
    w.task = null;
    w.station = null;
    w.action = null;
    emit(s, ev, "worker_walk", { worker: w.id, station: "idle", action: "lean", task: null });
  }
  // dependencies: a backlog task whose deps are all merged becomes ready
  for (const b of s.tasks)
    if (b.lane === "backlog" && b.deps.length && b.deps.every((d) => task(s, d)?.lane === "merged")) {
      b.lane = "ready";
      emit(s, ev, "card_move", { task: b.id, from: "backlog", to: "ready" }, `${b.id} is ready (its last dependency merged)`);
      emit(s, ev, "island", { task: b.id });
    }
  // milestone: all its tasks merged -> making port, and the next milestone opens
  const mi = s.milestones.findIndex((m) => m.tasks.includes(t.id));
  const m = s.milestones[mi];
  if (m && m.tasks.every((id) => task(s, id).lane === "merged") && s.port < mi + 1) {
    s.port = mi + 1;
    emit(s, ev, "making_port", { milestone: m.id, port: CONFIG.ports[mi + 1]?.name ?? m.id, index: mi + 1 }, `${m.id} complete: the ship makes port at ${CONFIG.ports[mi + 1]?.name}`);
    const next = s.milestones[mi + 1];
    if (next)
      for (const id of next.tasks) {
        const b = task(s, id);
        if (b.lane === "backlog" && b.deps.every((d) => task(s, d)?.lane === "merged")) {
          b.lane = "ready";
          emit(s, ev, "card_move", { task: b.id, from: "backlog", to: "ready" });
          emit(s, ev, "island", { task: b.id });
        }
      }
  }
}
function park(s, ev, t, how = "parked") {
  const w = t.worker && crewman(s, t.worker);
  const from = t.lane;
  t.lane = how;
  unschedule(s, (e) => e.task === t.id);
  delete s.gate[t.id];
  s.decisions = s.decisions.filter((d) => d.task !== t.id);
  if (w) {
    w.state = "idle";
    w.task = null;
    emit(s, ev, "worker_walk", { worker: w.id, station: "idle", action: "coil", task: null });
  }
  if (s.kraken.arms.includes(t.id)) {
    if (how === "dropped") {
      // a drop sends the whole kraken down, whatever else it holds
      s.kraken.fled = true;
      s.kraken.battle = null;
      emit(s, ev, "kraken_down", { how: "dropped", still: s.kraken.arms.filter((a) => a !== t.id) });
      s.kraken.arms = s.kraken.arms.filter((a) => a !== t.id);
    } else releaseArm(s, ev, t.id, "parked");
  }
  emit(s, ev, "card_move", { task: t.id, from, to: how });
  emit(s, ev, how, { task: t.id }, `${t.id} ${how}`);
}

// ---------------------------------------------------------------- actions
function answer(s, ev, decisionId, key) {
  const d = decisionId ? s.decisions.find((x) => x.id === decisionId) : s.decisions[0];
  if (!d) return;
  const opt = d.options.find((o) => o.key === key) || d.options[0];
  s.decisions = s.decisions.filter((x) => x !== d);
  const t = task(s, d.task);
  emit(s, ev, "decision_answered", { decision: d.id, kind: d.kind, key: opt.key, effect: opt.effect, task: d.task }, `${d.id}: the captain chose ${opt.key} (${opt.label})`);
  switch (opt.effect) {
    case "proceed": {
      const w = crewman(s, t.worker);
      if (w) w.state = "working";
      emit(s, ev, "order", { task: t.id, worker: t.worker, resume: true }, `Aye, captain: ${t.id} proceeds`);
      scheduleWork(s, t);
      break;
    }
    case "rescope":
      t.rounds = Math.max(t.round + 1, t.rounds - 1);
      if (d.kind === "choice") {
        const w = crewman(s, t.worker);
        if (w) w.state = "working";
        scheduleWork(s, t);
      } else {
        emit(s, ev, "kraken_far", { task: t.id }, `${t.id} rescoped: the kraken waits far off`);
        s.kraken.fled = true;
      }
      break;
    case "park":
      park(s, ev, t, "parked");
      break;
    case "drop":
      park(s, ev, t, "dropped");
      break;
    case "battle":
      s.kraken.battle = { task: t.id, since: s.t };
      emit(s, ev, "battle_begin", { task: t.id, arms: s.kraken.arms.slice(), rounds: t.round }, `The battle for ${t.id} begins`);
      break;
    case "merge":
      if (t.lane === "review" && t.approved) merge(s, ev, t);
      break;
    case "sendback":
      t.approved = false;
      t.rounds = t.round + 1;
      openPR(s, ev, t);
      emit(s, ev, "order", { task: t.id, worker: t.worker, sendback: true }, `${t.id} sent back for another look`);
      break;
    case "hold":
      emit(s, ev, "caption", { text: `${t.id} held; press M to merge it later.` });
      t.held = true;
      break;
  }
}

function newTask(s, ev) {
  const m = s.milestones[Math.min(s.milestones.length - 1, s.port)] || s.milestones[0];
  const t = makeTask(s, m.id, []);
  m.tasks.push(t.id);
  t.lane = "ready";
  emit(s, ev, "task_new", { task: t.id, lane: "ready" }, `${t.id} joined the plan: ${t.title}`);
  emit(s, ev, "island", { task: t.id, spotted: true });
}

function targetTask(s, id) {
  if (id) return task(s, id);
  const b = s.kraken.battle && task(s, s.kraken.battle.task);
  if (b) return b;
  return inFlight(s).sort((a, b) => parseInt(a.id.slice(2)) - parseInt(b.id.slice(2)))[0];
}

export function step(state, action) {
  const s = structuredClone(state);
  const ev = [];
  switch (action.type) {
    case "tick": {
      const end = s.t + Math.max(0, action.dt);
      // fire scheduled items in time order, splitting the tick at each
      for (let guard = 0; guard < 500; guard++) {
        s.schedule.sort((a, b) => a.at - b.at || a.n - b.n);
        const e = s.schedule[0];
        if (!e || e.at > end) break;
        s.schedule.shift();
        s.t = Math.max(s.t, e.at);
        fire(s, ev, e);
      }
      s.t = end;
      break;
    }
    case "newTask":
      newTask(s, ev);
      break;
    case "dispatch":
      dispatch(s, ev, action.task);
      break;
    case "openPR": {
      const t = action.task ? task(s, action.task) : inFlight(s).find((x) => x.lane === "working" && crewman(s, x.worker)?.state === "working");
      if (t && t.lane === "working") {
        unschedule(s, (e) => e.task === t.id && (e.type === "push" || e.type === "pr" || e.type === "fix"));
        openPR(s, ev, t);
      } else emit(s, ev, "caption", { text: "No working task can open a pull request right now." });
      break;
    }
    case "answer":
      answer(s, ev, action.decision, action.key);
      break;
    case "merge": {
      // the pending merge card's task, or else an approved task held in review
      const d = s.decisions.find((x) => x.kind === "merge");
      const t = d ? task(s, d.task) : s.tasks.find((x) => x.lane === "review" && x.approved);
      if (t) {
        if (d) {
          s.decisions = s.decisions.filter((x) => x !== d);
          emit(s, ev, "decision_answered", { decision: d.id, kind: "merge", key: "A", effect: "merge", task: t.id });
        }
        merge(s, ev, t);
      } else emit(s, ev, "caption", { text: "Nothing approved is waiting to merge." });
      break;
    }
    case "approve":
    case "reject": {
      const t = targetTask(s, action.task);
      if (t && t.lane === "review") {
        unschedule(s, (e) => e.task === t.id && e.type === "verdict");
        verdict(s, ev, t, action.type);
      } else if (t && t.lane === "working") {
        unschedule(s, (e) => e.task === t.id && ["push", "pr", "fix"].includes(e.type));
        openPR(s, ev, t);
        unschedule(s, (e) => e.task === t.id && e.type === "verdict");
        verdict(s, ev, task(s, t.id), action.type);
      } else emit(s, ev, "caption", { text: "No task in flight for that verdict." });
      break;
    }
    case "push": {
      const t = targetTask(s, action.task);
      const w = t && crewman(s, t.worker);
      if (t && w) {
        t.commits++;
        emit(s, ev, "commit_pushed", { task: t.id, worker: w.id, n: t.commits, inBattle: !!battleHolds(s, t.id) }, `${t.id}: ${w.name} pushed commit ${t.commits}`);
      }
      break;
    }
    case "redCheck": {
      const t = targetTask(s, action.task);
      if (t) {
        s.gate[t.id] = "red";
        const w = crewman(s, t.worker);
        if (w && w.state === "working") w.state = "blocked";
        emit(s, ev, "gate_failed", { task: t.id, worker: w?.id, inBattle: !!battleHolds(s, t.id) }, `${t.id}: the gate is red (weather, not blame)`);
      }
      break;
    }
    case "greenCheck": {
      const id = Object.keys(s.gate).find((k) => s.gate[k] === "red");
      if (id) {
        unschedule(s, (e) => e.task === id && e.type === "green");
        fire(s, ev, { type: "green", task: id, last: false });
      } else emit(s, ev, "caption", { text: "No red check to turn green." });
      break;
    }
    case "crash": {
      const t = targetTask(s, action.task);
      if (t && t.worker) fire(s, ev, { type: "crash", task: t.id });
      break;
    }
    case "park":
    case "drop": {
      const t = task(s, action.task);
      if (t && !["merged", "parked", "dropped"].includes(t.lane)) park(s, ev, t, action.type === "park" ? "parked" : "dropped");
      break;
    }
    case "survey": {
      const t = task(s, action.task);
      if (t && t.lane === "issues") {
        raiseDecision(s, ev, {
          kind: "scope",
          task: t.id,
          title: `Survey ${t.id}: ${t.title}`,
          body: `The firstmate drafted a spec. Its pull request will say "Closes ${t.id}".`,
          options: [
            { key: "A", label: "Approve the spec", pro: "The island clears the fog", con: "—", effect: "spec" },
            { key: "B", label: "Skip", pro: "Hides the issue", con: "Stays in the fog", effect: "skip" },
          ],
        });
      }
      break;
    }
    case "setCourse": {
      const t = task(s, action.task);
      if (t && t.lane === "ready") {
        t.course = s.tasks.filter((x) => x.course !== null && x.course !== undefined).length + 1;
        emit(s, ev, "course_set", { task: t.id, course: t.course }, `Course set: ${t.id} is ${t.course}${["st", "nd", "rd"][t.course - 1] || "th"}`);
      }
      break;
    }
    case "ritual":
      s.rituals[action.name] = !!action.on;
      break;
  }
  // survey answers turn issues into tasks
  for (const e of ev)
    if (e.type === "decision_answered" && e.kind === "scope") {
      const t = task(s, e.task);
      if (e.effect === "spec" && t) {
        const nt = makeTask(s, t.milestone, []);
        nt.title = t.title;
        nt.lane = "ready";
        s.milestones.find((m) => m.id === t.milestone)?.tasks.push(nt.id);
        t.lane = "surveyed";
        ev.push({ type: "card_move", task: t.id, from: "issues", to: "surveyed", t: s.t, seq: s.seq++ });
        ev.push({ type: "task_new", task: nt.id, lane: "ready", fromIssue: t.id, t: s.t, seq: s.seq++ });
        ev.push({ type: "island", task: nt.id, spotted: true, t: s.t, seq: s.seq++ });
      } else if (t) {
        t.lane = "skipped";
        ev.push({ type: "card_move", task: t.id, from: "issues", to: "skipped", t: s.t, seq: s.seq++ });
      }
    }
  return { state: s, events: ev };
}

// convenience for the view and the tests
export function crewOf(s, id) {
  return crewman(s, id);
}
export function taskOf(s, id) {
  return task(s, id);
}
export function held(s) {
  return heldTasks(s);
}
