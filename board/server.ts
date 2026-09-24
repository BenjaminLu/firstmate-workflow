// The board. Binds loopback only, serves one page, and streams the event log.
//
//   bun run board/server.ts            0.0.0.0 is never an option here
//   FM_PORT=4173 FM_ROOT=.             the log it tails is the one the crew writes
//
// No build step and no framework: the page is a file, the stream is SSE, and
// the state endpoint is derived from events.jsonl and design/tasks.json so the
// board has no opinion the log does not already hold.
import { existsSync, linkSync, mkdirSync, readFileSync, readdirSync, realpathSync, renameSync, statSync, unlinkSync, watch, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

// canonical from the start: on macOS /var is a symlink to /private/var, and a
// path check that compares a resolved path against an unresolved root refuses
// every legitimate file in the repository
const ROOT = realpathSync(resolve(process.env.FM_ROOT ?? "."));
const PORT = Number(process.env.FM_PORT ?? 4173);
const LOG = join(ROOT, "state/events.jsonl");
const PUBLIC = join(ROOT, "board/public");

type Event = Record<string, unknown> & { type?: string; task?: string; pr?: number };

const readEvents = (): Event[] => {
  if (!existsSync(LOG)) return [];
  return readFileSync(LOG, "utf8")
    .split("\n")
    .filter((l) => l.trim() !== "")
    .flatMap((l) => { try { return [JSON.parse(l) as Event]; } catch { return []; } });
};

// A task's state is whatever the log last said about it. The board never
// decides; it reports.
// What a crewman is, declared: every field on every entry, so a missing
// one is a type error rather than an `undefined` the client happens to
// tolerate. The state is a closed set because the client turns it into a
// class name, a dictionary key and a progress number - an open one meant
// an actor on a blocked task reached the page as `st-blocked`, which no
// stylesheet rule and no dictionary key covers.
const DECK_LIMIT = 24;   // what the ship holds; the page reads it back
type CrewState = "queued" | "working" | "gate" | "review" | "captain" | "unknown";
type Crew = {
  id: string;
  role: "firstmate" | "worker" | "reviewer";
  state: CrewState;
  task: string | null;
  title: string | null;
  activity?: Record<string, string> | null;
  crew_name?: string;
  // Bounded only: done/total with a real denominator. Never a bare percent.
  progress?: { done: number; total: number } | null;
};
// What an agent says it is. fm-review emits role "reviewer", fm-worker
// "worker"; a run that says nothing is a worker, which is what a
// dispatch is. The old version read the actor's NAME, so `rev-$$` or
// `secondmate` boarded as a worker and only a regex in one browser test
// would have noticed.
const roleOf = (actor: string, e: Event): "worker" | "reviewer" => {
  const d = (e as { data?: { role?: unknown } }).data;
  if (d && d.role === "reviewer") return "reviewer";
  if (d && d.role === "worker") return "worker";
  return actor.startsWith("reviewer") ? "reviewer" : "worker";   // older logs
};

// Missing lifecycle evidence is unknown, never inferred from task metadata.
const CREW_STATE = (s: string | undefined): CrewState =>
  s === "queued" || s === "working" || s === "gate" || s === "review" || s === "captain"
    ? s : "unknown";

const STAGE: Record<string, string> = {
  dispatched: "working", commit_pushed: "working", pr_opened: "review",
  gate_failed: "gate", gate_passed: "review", review_opened: "review",
  approved: "captain", decision_requested: "captain",
  merged: "merged", closed: "closed",
  // a task whose review never happened, or whose worker died, is blocked -
  // it must not sit in a lane that says work is under way
  review_failed: "gate", worker_crashed: "gate",
};

// The lanes, left to right, in lifecycle order. The page reads this list
// rather than keeping its own, so the order has one source. Closed tasks are
// not a lane: they stay in the collapsed history with the merged ones.
// Backlog and ready are both untouched work, split by whether it could be
// dispatched now: backlog still waits on a dependency, ready waits on nobody.
const LANES = ["backlog", "ready", "working", "gate", "review", "captain", "merged"] as const;

// The header's engine badge (V7). Read at request time, so an edit to
// config.yaml shows on the next refresh, and never hard-coded: the names are
// whatever the file says. Only the two keys the badge needs are read - the
// top-level vendor and the reviewer block's vendor - and a comment is never
// a value. No file, or no top-level vendor, is no badge rather than a guess.
const engine = (): { vendor: string; reviewer: string | null; cross: boolean } | null => {
  const file = join(ROOT, "config.yaml");
  if (!existsSync(file)) return null;
  let vendor: string | null = null, reviewer: string | null = null, block = "";
  const value = (v: string) => v.trim().replace(/^(["'])(.*)\1$/, "$2") || null;
  for (const raw of readFileSync(file, "utf8").split("\n")) {
    const line = raw.replace(/(^|\s)#.*$/, "");
    const top = /^([A-Za-z_][\w-]*):(.*)$/.exec(line);
    if (top) {
      block = top[1];
      if (block === "vendor") vendor = value(top[2]);
      continue;
    }
    const nested = /^\s+vendor:(.*)$/.exec(line);
    if (nested && block === "reviewer") reviewer = value(nested[1]);
  }
  if (!vendor) return null;
  return { vendor, reviewer, cross: reviewer !== null && reviewer !== vendor };
};

const state = () => {
  const events = readEvents();
  const pend = pending();
  const responseDir = join(ROOT, 'state/decisions');
  const responses = existsSync(responseDir) ? readdirSync(responseDir).filter(f => /^D-[0-9]{1,6}\.json$/.test(f)).flatMap(f => {
    try { return [JSON.parse(readFileSync(join(responseDir, f), 'utf8'))]; } catch { return []; }
  }) : [];
  const tasksFile = join(ROOT, "design/tasks.json");
  const defs = existsSync(tasksFile)
    ? (JSON.parse(readFileSync(tasksFile, "utf8")).tasks as Array<Record<string, unknown>>)
    : [];
  const definitions = new Map(defs.map(d => [String(d.id), d]));
  const stage = new Map<string, string>();
  const pr = new Map<string, number>();
  // merged and closed are where a task stops. Anything said about it
  // afterwards - a review round run against the branch, a late sync - is
  // about work that is already in, and letting it move the task back reads
  // as work in progress that nobody is doing.
  const FINAL = new Set(["merged", "closed"]);
  // What a card's badges are read from: the event that last moved the task,
  // whether a round-three question is still open, and where in the log the
  // task was merged. Each is a fact the log holds, never a guess.
  const moved = new Map<string, Event>();
  const asking = new Set<string>();
  const settledAt = new Map<string, number>();
  for (const [index, e] of events.entries()) {
    if (!e.task) continue;
    if (typeof e.pr === "number") pr.set(e.task, e.pr);
    if (FINAL.has(stage.get(e.task) ?? "")) continue;
    if (e.type === "ask_pass_criteria") asking.add(e.task);
    if (e.type === "criteria_returned") asking.delete(e.task);
    const s = STAGE[e.type ?? ""];
    if (s) { stage.set(e.task, s); moved.set(e.task, e); }
    if (s === "merged") settledAt.set(e.task, index);
  }
  // A pending decision is a fact on disk, not a point in a history: while
  // the card is up, the task is the captain's whatever else has been said
  // since. T-016 read as "working" because a dispatch that should never
  // have happened landed after the card went up.
  const awaiting = new Set(pend.map((p: Record<string, unknown>) => String(p.task ?? "")));
  const taskIds = [...definitions.keys()];
  for (const e of events) if (e.task && !definitions.has(e.task) && !taskIds.includes(e.task)) taskIds.push(e.task);
  // Where the log puts a task. Untouched is not yet a lane: which of backlog
  // or ready it is depends on its dependencies, decided below from this.
  const stageOf = (id: string) => {
    const terminal = FINAL.has(stage.get(id) ?? "");
    return !terminal && awaiting.has(id) ? "captain" : (stage.get(id) ?? "untouched");
  };
  // The badges a card carries. Only what an event or a pending record says:
  // the gate that failed when the failure named it, an open ASK-PASS-CRITERIA,
  // and a waiting decision with the number of options it actually offers.
  type Badge = { kind: "gate"; gate: number | null } | { kind: "ask" }
    | { kind: "decision"; id: string; options: number | null };
  const badgesOf = (id: string, at: string): Badge[] => {
    const out: Badge[] = [];
    const last = moved.get(id);
    if (at === "gate" && last?.type === "gate_failed") {
      const n = (last.data as { gate?: unknown } | undefined)?.gate;
      out.push({ kind: "gate", gate: Number.isInteger(n) && (n as number) >= 1 && (n as number) <= 7 ? n as number : null });
    }
    if (!FINAL.has(at) && asking.has(id)) out.push({ kind: "ask" });
    for (const p of pend.filter((x: Record<string, unknown>) => String(x.task ?? "") === id)) {
      const options = (p as { details?: { en?: { options?: unknown } } }).details?.en?.options;
      out.push({ kind: "decision", id: String(p.id ?? ""),
        options: options && typeof options === "object" ? Object.keys(options).length : null });
    }
    return out;
  };
  const tasks = taskIds.map((id) => {
    const d = definitions.get(id) || {};
    const depends: string[] = Array.isArray(d.depends_on) ? (d.depends_on as unknown[]).map(String) : [];
    // untouched work waiting on work that is not in yet: a dependency counts
    // as done only once it has merged, and one the log has never heard of is
    // not done. The same list decides the lane, so a card in backlog always
    // names what it waits on and a card in ready never does.
    const untouched = stageOf(id) === "untouched";
    const blockedOn = untouched ? depends.filter((dep) => stageOf(dep) !== "merged") : [];
    const at = untouched ? (blockedOn.length ? "backlog" : "ready") : stageOf(id);
    return ({
    id, title: typeof d.title === 'string' ? d.title : null, milestone: d.milestone ?? null,
    depends_on: depends,
    stage: at,
    pr: pr.get(id) ?? null,
    blocked_on: blockedOn,
    badges: badgesOf(id, at),
    // the aboard crew's names, filled in once the crew is known below
    crew: [] as string[],
    // where the merge sits in the log, so the lane can show the latest first
    merged_seq: settledAt.get(id) ?? null,
  }); });
  // The crew are AGENTS, not tasks. A crewman on the deck is something
  // that is running: firstmate, each worker or reviewer currently engaged,
  // and the captain while a decision is waiting. Drawing one figure per
  // in-flight task put pull requests on the deck instead - three tasks
  // handled by one worker looked like three of the crew, and the ship's
  // rate followed the backlog rather than the concurrency.
  //
  // An agent is engaged when the last thing it did concerns a task that is
  // not finished. github is the sync, not an agent, and is never aboard.
  // firstmate included: it is an agent like the others and it does work
  // of its own. Pinning it to "dispatching" was the board saying what the
  // role is for rather than what the agent is doing, and it is the one
  // crewman a reader most wants to be told the truth about.
  // Aboard means RUNNING. An actor whose last word was agent_finished has
  // gone home, whatever became of the task: without that, "aboard" meant
  // "ever touched a task that is not finished yet", a worker that died at
  // a gate was drawn working for ever, and the rate followed the history
  // rather than what is happening now.
  //
  // Insertion order here is the order of each actor's LAST event, oldest
  // first, because the loop deletes before it sets. That matters at the
  // one place the list is cut: `Map.set` on a key that already exists
  // keeps the original position, so without the delete the map was
  // ordered by each actor's FIRST event and a full deck showed the
  // stalest crew while the agents that had just started fell off the
  // end. Reversed below, the deck holds the ones that spoke most
  // recently, which is what a reader watching a busy ship is looking at.
  const lastByActor = new Map<string, Event>();
  const authored = (v: any): Record<string,string> | null => v && typeof v.en === 'string' && typeof v['zh-TW'] === 'string' && v.en.trim() && v['zh-TW'].trim() ? {en:v.en,'zh-TW':v['zh-TW']} : null;
  const activity = new Map<string, Record<string,string>>();
  const phases = new Map<string, CrewState>();
  const names = new Map<string,string>();
  const progress = new Map<string, { done: number; total: number }>();
  const roles = new Map<string,'worker'|'reviewer'>();
  const finished = new Set<string>();
  const handoffs: Array<Record<string,unknown>> = [];
  // Only an object with a true denominator is progress. Bare numbers, stage
  // maps and missing fields stay null — never a fake percent on the payload.
  const bounded = (v: unknown): { done: number; total: number } | null => {
    if (!v || typeof v !== "object" || Array.isArray(v)) return null;
    const o = v as { done?: unknown; total?: unknown };
    const done = typeof o.done === "number" ? o.done : Number.NaN;
    const total = typeof o.total === "number" ? o.total : Number.NaN;
    if (!Number.isFinite(done) || !Number.isFinite(total) || total <= 0 || done < 0 || done > total) {
      return null;
    }
    return { done, total };
  };
  for (const [index, e] of events.entries()) {
    const actor = String(e.actor || '');
    const data = (e.data || {}) as Record<string, any>;
    const previous = lastByActor.get(actor);
    if (e.type === 'dispatched') finished.delete(actor);
    else if (finished.has(actor)) continue;
    if (e.type === 'agent_finished') finished.add(actor);
    if (e.type === 'dispatched' || (e.task && previous?.task !== e.task)) {
      activity.delete(actor); phases.delete(actor);
      progress.delete(actor);
      if (e.type === 'dispatched') names.delete(actor);
    }
    if (typeof data.crew_name === 'string') names.set(actor, data.crew_name);
    const nextProgress = bounded(data.progress);
    if (nextProgress) progress.set(actor, nextProgress);
    if (e.type === 'dispatched' || data.role) roles.set(actor, roleOf(actor,e));
    // Mid-run authored data.activity from events describes the run.
    // Scalar titles are never treated as activity.
    const description = authored(data.activity)
      || (e.type === 'dispatched' || e.type === 'review_opened' ? authored(e.summary) : null);
    if (description) activity.set(actor,description);
    // crew_status refreshes activity/progress only; it must not invent a phase.
    if (STAGE[e.type || '']) phases.set(actor,e.type === 'dispatched'
      ? (roleOf(actor,e) === 'reviewer' ? 'review' : 'working')
      : CREW_STATE(STAGE[e.type || '']));
    const peer = (role: string) => {
      const candidates = [...lastByActor].filter(([id,event]) => id !== actor && id !== 'firstmate' && event.task === e.task && event.type !== 'agent_finished' && !finished.has(id) && (roles.get(id) || roleOf(id,event)) === role);
      // Several runs on one task are ambiguous; never pick an arbitrary actor.
      return candidates.length === 1 ? candidates[0][0] : undefined;
    };
    let kind = '', from: string | undefined, to: string | undefined;
    if (e.type === 'dispatched' && actor !== 'firstmate' && roleOf(actor,e) === 'worker') {kind='order';from='firstmate';to=actor;}
    if (e.type === 'pr_opened') {kind='work';from=actor;to=peer('reviewer');}
    if (e.type === 'review_opened') {kind='work';from=peer('worker');to=actor;}
    if (e.type === 'approved') {kind='approve';from=actor;to='firstmate';}
    if (e.type === 'review_failed' && data.review_outcome === 'rejected') {kind='reject';from=actor;to=peer('worker');}
    if (e.type === 'decision_made') {kind='order';from='firstmate';to=peer('worker');}
    if (kind) handoffs.push({identity:`handoff:${index}:${JSON.stringify(e)}`,kind,from:from || null,to:to || null,task:e.task || null});
    if (!e.actor || e.actor === "github" || e.actor === "captain") continue;
    lastByActor.delete(e.actor);
    lastByActor.set(e.actor, {...e,task:e.task || previous?.task});
  }
  for (const [actor, e] of [...lastByActor]) {
    if (e.type === "agent_finished") lastByActor.delete(actor);
  }
  const done = new Set([...stage].filter(([,value]) => FINAL.has(value)).map(([id]) => id));
  // firstmate carries its task like anyone else. Pinning it to
  // "dispatching" was the board saying what the role is FOR rather than
  // what the agent is DOING - and firstmate is the crewman a reader most
  // wants the truth about, because it is the one that works off the board.
  // firstmate is always ABOARD - it is the one that dispatches, so the
  // ship is never empty - but everything else about it is read the same
  // way as any other agent: its task if it has one, nothing if its run
  // ended. Two comments used to argue it was "an agent like the others"
  // while the code exempted it; this is the exemption, named and narrow.
  // one derivation, read twice: firstmate's state and the payload's own
  // flag were each computing this, and the page reads the flag while it
  // is handed the state - two answers to one question, in one response
  const greenlit = events.some((e) => e.type === "greenlit");
  const fm = lastByActor.get("firstmate");
  const fmTask = fm?.task && !done.has(fm.task) ? fm.task : null;
  const fmT = fmTask ? tasks.find((x) => x.id === fmTask) : undefined;
  const crew: Crew[] = [{
    id: "firstmate", role: "firstmate",
    state: greenlit ? (fm ? phases.get('firstmate') || 'unknown' : 'unknown') : "queued",
    task: fmTask, title: fmT?.title ?? null,
    activity: fm
      ? (activity.get("firstmate")
        || (fmTask
          ? authored((defs.find((d) => d.id === fmTask) as { activity?: unknown } | undefined)?.activity)
          : null)
        || null)
      : null,
    progress: fm ? (progress.get("firstmate") ?? null) : null,
    crew_name: fm ? names.get("firstmate") : undefined,
  }];
  // newest first, and firstmate is already pinned at the head: when the
  // deck overflows it is the oldest crewman that is dropped, never the
  // one that just boarded
  for (const [actor, e] of [...lastByActor].reverse()) {
    if (actor === "firstmate") continue;   // already aboard, above
    const task = e.task ?? null;
    if (!task) continue;
    // agent_finished is the answer; this is the backstop for a run that
    // never got to say it - killed, or a machine that slept. When they
    // disagree, agent_finished wins: it is checked above and has already
    // removed the actor. This only catches a run that vanished.
    if (done.has(task)) continue;
    const t = tasks.find((x) => x.id === task);
    crew.push({
      id: actor,
      // stated, not guessed: the emitter writes what it is, so renaming
      // an actor cannot silently turn every reviewer into a worker
      role: roles.get(actor) || roleOf(actor, e),
      state: phases.get(actor) || 'unknown',
      task, title: t?.title ?? null,
      crew_name: names.get(actor),
      progress: progress.get(actor) ?? null,
      // Replay/event activity wins over static task.activity; never scalar title.
      activity: activity.get(actor)
        || authored((defs.find((d) => d.id === task) as { activity?: unknown } | undefined)?.activity)
        || null,
    });
  }
  // The permanently aboard human captain is rendered separately from agents.

  // A card names who is aboard on it: the agents on the deck, not whoever
  // once touched the task. firstmate is the coordinator, not the crew on it.
  const aboard = crew.slice(0, DECK_LIMIT);
  for (const t of tasks) {
    t.crew = aboard.filter((c) => c.role !== "firstmate" && c.task === t.id).map((c) => c.crew_name || c.id);
  }

  // A refused merge stops being news once the same task or pull request is
  // merged afterwards - by a later answer on the board or any other way. The
  // record keeps what happened; the flag says it has been overtaken.
  const later = (a: unknown, b: unknown) => {
    const x = Date.parse(String(a ?? "")), y = Date.parse(String(b ?? ""));
    // event stamps are whole seconds: one in the same second is not earlier
    return !Number.isFinite(x) || !Number.isFinite(y) || x + 1000 > y;
  };
  const mergedEvents = events.filter((e) => e.type === "merged");
  const reviewed = responses.map((d: Record<string, any>) => {
    if (d?.merged?.ok !== false) return d;
    const sameWork = (task: unknown, number: unknown) =>
      (d.task != null && task != null && String(task) === String(d.task))
      || (d.pr != null && number != null && String(number) === String(d.pr));
    const superseded = mergedEvents.some((e) => sameWork(e.task, e.pr) && later(e.ts, d.ts))
      || responses.some((o: Record<string, any>) => o !== d && o?.merged?.ok === true
        && sameWork(o.task, o.pr) && later(o.ts, d.ts));
    return { ...d, superseded };
  });

  return {
    engine: engine(),
    lanes: LANES,
    // The deck holds this many. One number: the server truncates and
    // tells the page what the limit was, rather than both of them
    // knowing 24 - truncating only on the client also left the server
    // building an unbounded array into every payload.
    deckLimit: DECK_LIMIT,
    crew: crew.slice(0, DECK_LIMIT),
    greenlit,
    counts: {
      merged: tasks.filter((t) => t.stage === "merged").length,
      inflight: tasks.filter((t) => ["working", "review"].includes(t.stage)).length,
      blocked: tasks.filter((t) => t.stage === "gate").length,
      ready: tasks.filter((t) => t.stage === "ready").length,
      backlog: tasks.filter((t) => t.stage === "backlog").length,
      // one per decision on the deck: the captain is what these wait on
      waiting: pend.length,
    },
    tasks,
    // design.md is linked from a card only when there is one to open
    designDoc: existsSync(join(ROOT, "design/design.md")),
    // Full outcome stream: a busy refresh must not lose events outside recent.
    responses: reviewed,
    handoffs,
    outcomes: [...events.filter(e => e.type === "merged" || e.type === "decision_made")
      .map(e => ({ ...e, identity: e.type === "decision_made"
        ? `decision:${(e.data as any)?.decision ?? JSON.stringify(e)}` : `merge:${e.pr ?? e.task ?? JSON.stringify(e)}` })),
      ...responses.filter(d => d.identity).map(d => ({type:'decision_made',identity:d.identity,data:{decision:d.id,chosen:d.chosen}}))],
    recent: events.slice(-40).reverse(),
    pending: pend,
  };
};

// Decisions the captain has been asked for but has not answered.
// A card for a pull request that is already merged is the board lying. It
// happens whenever a merge goes through some other way - a decision file
// outlives the thing it was asking about - and the captain is then offered
// a choice that cannot be made.
const pending = () => {
  const dir = join(ROOT, "state/pending");
  if (!existsSync(dir)) return [];
  const terminal = readEvents().filter((e) => e.type === "merged" || e.type === "closed");
  const settled = new Set(
    terminal
      .filter((e) => e.type === "merged" || e.type === "closed")
      .map((e) => String((e as Record<string, unknown>).pr ?? "")),
  );
  const settledTasks = new Set(terminal.map(e => String(e.task ?? '')).filter(Boolean));
  // readdirSync order is filesystem-dependent (macOS vs Linux CI). Sort by
  // decision id so the deck and multi-card tests stay stable everywhere.
  return readdirSync(dir).filter((f) => f.endsWith(".json")).flatMap((f) => {
    try {
      const d = JSON.parse(readFileSync(join(dir, f), "utf8"));
      if (d.pr != null && settled.has(String(d.pr))) return [];
      if (d.task != null && settledTasks.has(String(d.task))) return [];
      return [d];
    } catch { return []; }
  }).sort((a, b) => String(a.id ?? "").localeCompare(String(b.id ?? ""), "en", { numeric: true }));
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

const serveFile = (name: string) => {
  const p = join(PUBLIC, name);
  if (!p.startsWith(PUBLIC) || !existsSync(p)) return new Response("not found", { status: 404 });
  const type = name.endsWith(".css") ? "text/css"
    : name.endsWith(".js") ? "text/javascript" : "text/html; charset=utf-8";
  return new Response(readFileSync(p), { headers: { "content-type": type } });
};

const server = Bun.serve({
  hostname: "127.0.0.1",          // never 0.0.0.0: this board is for one machine
  port: PORT,
  fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/api/state") return json(state());

    // the dictionaries, plus the table that derives zh-CN from zh-TW
    if (url.pathname === "/api/i18n") {
      const dir = join(ROOT, "i18n");
      const read = (f: string) =>
        existsSync(join(dir, f)) ? JSON.parse(readFileSync(join(dir, f), "utf8")) : {};
      const table = existsSync(join(dir, "tw2cn.tsv"))
        ? readFileSync(join(dir, "tw2cn.tsv"), "utf8").split("\n")
            .filter((l) => l.trim() !== "" && !l.startsWith("#"))
            .map((l) => l.split("\t")).filter((p) => p.length === 2)
        : [];
      return json({ en: read("ui.en.json"), "zh-TW": read("ui.zh-TW.json"), tw2cn: table });
    }

    if (url.pathname === "/events") {
      let stop = () => {};
      const stream = new ReadableStream({
        start(c) {
          const enc = new TextEncoder();
          const send = (event: string, data: unknown) =>
            c.enqueue(enc.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`));
          send("state", state());
          let size = existsSync(LOG) ? statSync(LOG).size : 0;
          const poll = setInterval(() => {
            const now = existsSync(LOG) ? statSync(LOG).size : 0;
            if (now !== size) { size = now; send("state", state()); }
          }, 500);
          const beat = setInterval(() => c.enqueue(enc.encode(": beat\n\n")), 15000);
          // a change to the page itself reloads every open board
          const w = existsSync(PUBLIC) ? watch(PUBLIC, () => send("reload", {})) : null;
          stop = () => { clearInterval(poll); clearInterval(beat); w?.close(); };
        },
        cancel() { stop(); },
      });
      return new Response(stream, {
        headers: { "content-type": "text/event-stream", "cache-control": "no-cache" },
      });
    }

    // The captain answers. The board writes the answer down and, for a merge,
    // calls the one script allowed to merge - it never shells out ad hoc.
    if (url.pathname === "/decisions" && req.method === "POST") {
      return req.json().then(async (body: any) => {
        const id = String(body?.id ?? "");
        const chosen = typeof body?.chosen === "string" ? body.chosen : "";
        if (!/^D-[0-9]{1,6}$/.test(id)) return json({ error: "bad decision id" }, 400);
        if (!["A", "B", "C", "custom"].includes(chosen)) return json({ error: "bad choice" }, 400);
        // Count Unicode code points, preserving the literal text including spaces.
        const text = body?.text;
        if (chosen === "custom" && (typeof text !== "string" || !text.trim()
          || [...text].length > 1000 || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f\ud800-\udfff]/u.test(text))) {
          return json({ error: "invalid custom text", code: "customInvalid" }, 400);
        }

        const p = pending().find((d: any) => d.id === id);
        const dir = join(ROOT, "state/decisions");
        mkdirSync(dir, { recursive: true });
        const file = join(dir, `${id}.json`);
        if (existsSync(file)) {
          const decision = JSON.parse(readFileSync(file, "utf8"));
          if (decision.chosen !== chosen || (chosen === "custom" && decision.text !== text))
            return json({ error: "decision already recorded differently" }, 409);
          return json({ ok: true, already: true, decision, merged: decision.merged ?? null });
        }
        if (!p) return json({ error: "no pending decision" }, 404);
        const decision = {
          id, chosen, task: p?.task ?? null, pr: typeof p?.pr === "number" ? p.pr : null, kind: p?.kind ?? "choice",
          ...(chosen === "custom" ? { text } : {}),
          note: typeof body?.note === "string" ? body.note.slice(0, 500) : "",
          ts: new Date().toISOString(),
          identity: `decision:${id}`, merged: (p.kind === 'merge' && chosen === 'A'
            ? {ok:false,out:'Merge outcome not confirmed'} : null) as null | { ok: boolean; out: string },
        };
        // Exclusive creation makes repeated requests unable to rerun a merge.
        const temporary = join(dir, `.${id}.${crypto.randomUUID()}.tmp`);
        writeFileSync(temporary, JSON.stringify(decision) + "\n", { flag: "wx" });
        try { linkSync(temporary, file); } finally { unlinkSync(temporary); }
        let eventRecorded = false;
        try {
          const emitted = Bun.spawnSync([join(ROOT, "bin/fm-emit.sh"),
          "--actor", "captain", "--type", "decision_made",
          ...(p.task ? ["--task", p.task] : []),
          "--data", JSON.stringify({ decision: id, chosen, outcome: "recorded" }),
          "--en", `${id} recorded ${chosen}`, "--tw", `${id} 已記錄 ${chosen}`],
          { env: { ...process.env, FM_ROOT: ROOT } });
          eventRecorded = emitted.exitCode === 0;
        } catch { /* the durable decision still exists; report the event failure */ }

        let merged = null;
        if (p?.kind === "merge" && chosen === "A" && typeof p.pr === "number") {
          try {
          const r = Bun.spawnSync([join(ROOT, "bin/fm-merge.sh"),
            "--pr", String(p.pr), ...(p.task ? ["--task", p.task] : []), "--repo", ROOT],
            { env: { ...process.env, FM_ROOT: ROOT } });
          merged = { ok: r.exitCode === 0, out: new TextDecoder().decode(r.stdout).trim() };
          } catch { merged = {ok:false,out:'Merge helper unavailable'}; }
        }
        decision.merged = merged;
        writeFileSync(temporary, JSON.stringify(decision) + "\n", { flag: "wx" });
        renameSync(temporary, file);
        const pf = join(ROOT, "state/pending", `${id}.json`);
        if (existsSync(pf)) unlinkSync(pf);
        return json({ ok: true, decision, merged, eventRecorded });
      }).catch(() => json({ error: "bad request" }, 400));
    }

    // Hand a file to the editor, or show it. Both refuse anything that does
    // not resolve inside the repository, and both refuse a caller that is not
    // on this machine - the board binds loopback, but a browser on it can be
    // pointed anywhere by a page the captain did not write.
    const localOnly = (r: Request) => {
      const h = new URL(r.url).hostname;
      return h === "127.0.0.1" || h === "localhost" || h === "::1";
    };
    // one check for every endpoint that takes a path: resolve it fully, then
    // insist the real thing sits inside the real root. Three copies of this
    // is three chances to write it differently.
    const inside = (p: string) => {
      if (p === "") return null;
      const abs = resolve(ROOT, p);
      if (!existsSync(abs)) return null;
      const real = realpathSync(abs);
      return real === ROOT || real.startsWith(ROOT + "/") ? real : null;
    };

    if (url.pathname === "/open") {
      if (!localOnly(req)) return json({ error: "localhost only" }, 403);
      const abs = inside(url.searchParams.get("path") ?? "");
      if (!abs) return json({ error: "outside the repository" }, 403);
      const editor = (readFileSync(join(ROOT, "config.yaml"), "utf8")
        .match(/^editor:\s*([^\s#]+)/m)?.[1] ?? "code");
      Bun.spawn([editor, abs], { stdout: "ignore", stderr: "ignore" });
      return json({ ok: true, opened: abs, editor });
    }

    if (url.pathname === "/file") {
      if (!localOnly(req)) return json({ error: "localhost only" }, 403);
      const abs = inside(url.searchParams.get("path") ?? "");
      if (!abs) return json({ error: "outside the repository" }, 403);
      if (statSync(abs).size > 512 * 1024) return json({ error: "too large to show" }, 413);
      return new Response(readFileSync(abs), { headers: { "content-type": "text/plain; charset=utf-8" } });
    }

    if (url.pathname === "/diff") {
      if (!localOnly(req)) return json({ error: "localhost only" }, 403);
      const branch = url.searchParams.get("branch") ?? "";
      if (!/^[A-Za-z0-9._\/-]{1,120}$/.test(branch)) return json({ error: "bad branch" }, 400);
      const r = Bun.spawnSync(["git", "-C", ROOT, "diff", `main...${branch}`], {});
      if (r.exitCode !== 0) return json({ error: "no such branch" }, 404);
      return new Response(r.stdout, { headers: { "content-type": "text/plain; charset=utf-8" } });
    }

    if (url.pathname === "/" || url.pathname === "") return serveFile("index.html");
    return serveFile(url.pathname.replace(/^\//, ""));
  },
});
console.log(`board on http://127.0.0.1:${server.port}  root=${ROOT}`);
