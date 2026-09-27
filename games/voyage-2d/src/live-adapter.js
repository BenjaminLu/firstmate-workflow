// Live: BoardSource own view (games/voyage-2d/src/boardsource.js) -> the sim
// shape World, HUD, Director and BattleView already read in Playground
// (v3src/sim/sim.js createSim). Nothing here writes to the board, and
// nothing here invents a fact the view did not carry: a field the board
// view has no opinion on is a safe, documented default (docs/interface.md
// section 3, simulation-only), never a guess dressed as data.
const LANE_TO_SIM = {
  backlog: "backlog", ready: "ready", working: "working",
  // folded per docs/interface.md section 1.1s stated fallback: "render it
  // as working with the red badge" (gate) and the nearest live equivalent
  // for a lane the Playground sim never had (captain)
  gate: "working", review: "review", captain: "review",
  merged: "merged", parked: "backlog",
};
const CREW_STATE_TO_SIM = {
  queued: "idle", working: "working", gate: "blocked", review: "review",
  captain: "waiting", unknown: "idle",
};
const SAILOR_MODELS = ["sailor-hammer", "sailor-bandana", "sailor-spyglass"];

export function liveEmptySim(rituals) {
  return {
    seed: 0, rng: 1, t: 0, nextTask: 0, nextDecision: 0,
    tasks: [], crew: [], decisions: [], schedule: [], milestones: [],
    port: 0, kraken: { arms: [], battle: null, fled: false }, gate: {}, log: [],
    rituals: { ...rituals }, stats: { merged: 0, dispatched: 0, approvals: 0, rejections: 0, battlesWon: 0 },
    seq: 0,
  };
}

function milestonesOf(tasks) {
  const order = [];
  const byId = new Map();
  for (const t of tasks) {
    const m = t.milestone;
    if (m == null) continue;
    if (!byId.has(m)) { byId.set(m, { id: m, tasks: [] }); order.push(byId.get(m)); }
    byId.get(m).tasks.push(t.id);
  }
  return order;
}
// how many milestones in a row, from the first, have every one of their
// tasks merged: the same rule docs/interface.md section 1.6 describes for
// making port.
function portOf(milestones, tasks) {
  const byId = new Map(tasks.map((t) => [t.id, t]));
  let port = 0;
  for (const m of milestones) {
    if (m.tasks.length && m.tasks.every((id) => byId.get(id)?.lane === "merged")) port++;
    else break;
  }
  return port;
}
// a stable puppet for a crew id the game has not chosen one for yet: a hash
// of the id, not a value re-rolled every snapshot
function hashModel(id) {
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) | 0;
  return SAILOR_MODELS[Math.abs(h) % SAILOR_MODELS.length];
}
function simTask(t) {
  return {
    id: t.id, title: t.title, milestone: t.milestone, deps: t.depends_on || [],
    lane: LANE_TO_SIM[t.lane] || "backlog", stage: t.lane,
    worker: t.crew?.find((c) => c.role === "worker")?.id ?? null,
    round: t.crew?.[0]?.round ?? 0, approved: false, issue: false, course: null,
    pr: t.pr ?? null, actions: t.actions || [],
  };
}
function simCrew(c, engine) {
  return {
    id: c.id, role: c.role, name: c.crew_name || c.name || c.id,
    model: c.role === "worker" ? hashModel(c.id) : null,
    vendor: engine ? (engine.cross && c.role === "reviewer" ? engine.reviewer : engine.vendor) : null,
    state: CREW_STATE_TO_SIM[c.state] || "idle",
    task: c.task ?? null, station: null, action: null,
    standing: 0, merges: 0, firstPass: 0, approvals: 0, rank: 0, record: [], honours: [],
  };
}

// view: BoardSource own mapped view (section 1); prev: the sim last handed
// to the renderer, so ritual toggles and the running tally of past merges
// (never a fact the board itself keeps) survive one snapshot to the next.
export function viewToSim(view, prev) {
  const tasks = (view.tasks || []).filter((t) => t.lane !== "closed").map(simTask);
  const milestones = milestonesOf(tasks);
  const gate = {};
  for (const t of view.tasks || []) if (t.lane === "gate") gate[t.id] = "red";
  return {
    seed: prev?.seed ?? 0, rng: prev?.rng ?? 1, t: (prev?.t ?? 0) + 1,
    nextTask: 0, nextDecision: 0,
    tasks, milestones, port: portOf(milestones, tasks),
    crew: (view.crew || []).filter((c) => c.role !== "firstmate").map((c) => simCrew(c, view.engine)),
    // docs/interface.md section 1.3: the game answers only by a click on the
    // card, and never interprets `chosen` beyond what the board itself
    // offers - options come straight from the boards own details, not a
    // guess at their meaning.
    decisions: (view.pending || []).map((p) => ({
      id: p.id, kind: p.kind === "merge" || p.kind === "merge-untracked" ? "merge" : "choice",
      task: p.task ?? null, title: p.details?.en?.title ?? p.title ?? "",
      body: p.details?.en?.explanation ?? "",
      answerable: p.answerable !== false,
      options: ["A", "B", "C", "D"].filter((k) => p.details?.en?.options?.[k]).map((k) => ({
        key: k, ...p.details.en.options[k],
      })),
    })),
    schedule: [],
    // the kraken is not yet wired for Live in this round (a follow-up: it
    // needs a full review-round history the last-40-events window does not
    // carry); no arm ever grabs the ship until it is
    kraken: { arms: [], battle: null, fled: false },
    gate,
    log: [],
    rituals: prev?.rituals ?? {},
    stats: { merged: (view.counts?.merged) ?? 0, dispatched: 0, approvals: 0, rejections: 0,
      battlesWon: prev?.stats?.battlesWon ?? 0 },
    seq: (prev?.seq ?? 0) + 1,
  };
}
