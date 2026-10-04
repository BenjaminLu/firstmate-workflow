// Live mode's kraken, read from the board's own event log (board/server.ts events.jsonl, as
// /api/state's recent[] and the SSE snapshots carry it). Pure: events in, arms out.
//
// The rule (the captain's, docs/interface.md section 1.4):
// - a task's review round is counted from its own events: review_opened opens one, a
//   review_failed with data.review_outcome "rejected" is a round lost;
// - a task that has lost three rounds since it was last approved (its review has gone past
//   three rounds) grabs the ship: one arm per task, up to the arm cap (Playground's 8); a task
//   past the cap waits and takes the next arm that comes free, oldest first;
// - an arm lets go when its task is approved (the one way to beat the kraken: the finisher
//   unlocks on it), merged, parked or dropped (the board's "closed");
// - nothing here, and nothing in the fight, writes to the board.
// A task is its project and its id: two projects' T-004 are two tasks.
export const KRAKEN = Object.freeze({ fromRound: 3, maxArms: 8 });
const LET_GO = { approved: "approved", merged: "merged", closed: "dropped", parked: "parked" };

export const taskKey = (e, defaultProject = "") => `${typeof e.project === "string" && e.project ? e.project : defaultProject}/${e.task}`;

// every task's review, as the log tells it
export function reviewRounds(events, { defaultProject = "" } = {}) {
  const out = new Map();
  for (const e of events) {
    if (!e || !e.task) continue;
    const k = taskKey(e, defaultProject);
    const r = out.get(k) || { key: k, task: e.task, rounds: 0, lost: 0, lostSince: 0, approvals: 0, final: null };
    if (e.type === "review_opened") r.rounds++;
    if (e.type === "review_failed" && e.data?.review_outcome === "rejected") (r.lost++, r.lostSince++);
    if (e.type === "approved") (r.approvals++, (r.lostSince = 0));
    if (e.type === "merged" || e.type === "closed") r.final = e.type;
    out.set(k, r);
  }
  return out;
}

// replay the log into the kraken: the arms held now, and what happened on the way
// (kraken_arm / kraken_let_go, with why and the event that did it)
export function krakenFromEvents(events, { defaultProject = "", maxArms = KRAKEN.maxArms, fromRound = KRAKEN.fromRound } = {}) {
  const lost = new Map(); // rounds lost since the task was last approved or let go
  const final = new Set();
  const arms = []; // task keys, in the order they grabbed
  const waiting = []; // past the cap: next in line for a free arm
  const happened = [];
  const grab = (k, at) => {
    if (arms.includes(k) || final.has(k)) return;
    if (arms.length >= maxArms) return void (waiting.includes(k) || waiting.push(k));
    arms.push(k);
    happened.push({ type: "kraken_arm", task: k, round: lost.get(k), at });
  };
  const letGo = (k, why, at) => {
    const w = waiting.indexOf(k);
    if (w >= 0) waiting.splice(w, 1);
    lost.set(k, 0);
    const i = arms.indexOf(k);
    if (i < 0) return;
    arms.splice(i, 1);
    happened.push({ type: "kraken_let_go", task: k, why, victory: why === "approved", at });
    // the freed arm takes the task that has waited longest
    while (waiting.length && arms.length < maxArms) {
      const next = waiting.shift();
      if ((lost.get(next) || 0) >= fromRound && !final.has(next)) grab(next, at);
    }
  };
  events.forEach((e, at) => {
    if (!e || !e.task) return;
    const k = taskKey(e, defaultProject);
    if (final.has(k)) return;
    if (e.type === "review_failed" && e.data?.review_outcome === "rejected") {
      lost.set(k, (lost.get(k) || 0) + 1);
      if (lost.get(k) >= fromRound) grab(k, at);
    } else if (LET_GO[e.type]) {
      if (e.type === "merged" || e.type === "closed") final.add(k);
      letGo(k, LET_GO[e.type], at);
    }
  });
  return { arms, waiting, happened };
}
