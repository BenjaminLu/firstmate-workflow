// The Live data source (docs/interface.md section 0): the board own state,
// read through GET /api/state and SSE /events, and the two writes the
// captain may make, POST /decisions and POST /tasks - nothing else, ever.
// This is the only module in the game that may call fetch or EventSource;
// tools/build.py Playground bundle never includes it, and its own no-network
// assertion (build.py) is what keeps a Playground page from reaching the
// board even by mistake.
//
// subscribe((view, events) => ...) mirrors the shape the interface doc
// suggests: `view` is the section 1 view model (close to /api/state, with a
// `lane` alias for `stage` so the game vocabulary reads consistently with
// the Playground sim.tasks[].lane), and `events` is the small, typed list
// section 1.7 maps board event types onto, oldest first, already
// deduplicated against what a previous snapshot recent[] already showed.
//
// command({type, ...}) is the whole of what the captain may do here: answer
// a card, or park/unpark/drop a task. Both go out with the tab own bearer
// token (never the board secret) with a JSON body; the browser adds Origin
// on its own, which is exactly the header T-122 checks. Nothing else is
// ever sent.

// docs/interface.md section 1.7: board event type -> the game own event
// name. crew_status is deliberately absent: the busiest event in the log
// must never trigger a ritual, only refresh a crewman activity or progress,
// which happens through the task and crew mapping in mapView, not here.
export const EVENT_MAP = {
  dispatched: "order",
  commit_pushed: "commit_pushed",
  pr_opened: "pr_opened",
  review_opened: "review_opened",
  gate_passed: "gate_green",
  approved: "review_approved",
  merged: "merged",
  closed: "closed",
  decision_requested: "decision_requested",
  decision_made: "decision_answered",
  ask_pass_criteria: "ask_pass_criteria",
  criteria_returned: "criteria_returned",
  worker_crashed: "worker_crashed",
  vendor_unavailable: "vendor_unavailable",
  greenlit: "greenlit",
  parked: "parked",
  unparked: "unparked",
  agent_finished: "agent_finished",
};
// review_failed splits by outcome (section 1.7): a lost round is a
// rejection, anything else (infrastructure_error, missing_review, and so
// on) is weather.
const reviewFailedEvent = (e) =>
  (e && e.data && e.data.review_outcome === "rejected") ? "review_rejected" : "gate_failed";

// one board event, mapped, or null for one the director has no ritual for
// (crew_status among them: the interface doc section 1.7 is explicit that
// it must never trigger a ritual)
export function mapEvent(e) {
  if (!e || typeof e.type !== "string") return null;
  const type = e.type === "review_failed" ? reviewFailedEvent(e) : EVENT_MAP[e.type];
  if (!type) return null;
  return { type, task: e.task ?? null, project: typeof e.project === "string" ? e.project : null,
    actor: typeof e.actor === "string" ? e.actor : null, data: e.data ?? null, ts: e.ts ?? null,
    summary: e.summary ?? null };
}

// section 1.7 point 1: the last 40 events, newest first; keep the last seen
// (ts, actor, type, task) and emit only what is newer than that, oldest
// first. A gap of more than 40 events between two snapshots is lost, by
// design - the game re-syncs from the snapshot view and never assumes it
// has seen every event.
export function newEvents(recent, seen) {
  const key = (e) => [e.ts ?? "", e.actor ?? "", e.type ?? "", e.task ?? ""].join("\u0000");
  const list = Array.isArray(recent) ? recent : [];
  const fresh = [];
  for (const e of list) { // newest first; stop at the first one already seen
    const k = key(e);
    if (seen.has(k)) break;
    fresh.push(e);
  }
  fresh.reverse(); // oldest of the new ones first
  for (const e of fresh) seen.add(key(e));
  // bound the set: only the recent[] window can ever be asked about again
  if (seen.size > 400) { const drop = seen.size - 400; let i = 0; for (const k of seen) { if (i++ >= drop) break; seen.delete(k); } }
  return fresh;
}

// docs/interface.md section 1.1 lane mapping, minus the two the board
// already resolves before the payload leaves it (untouched -> backlog or
// ready is the server own job, and parked is a stage the server already
// gives).
export const laneOf = (stage) => stage;

// The board task -> the game task: the interface doc field table, section
// 1.1, read straight off /api/state. `lane` is `stage` under its game name;
// every other field keeps the board own name so a value that disagrees
// between v1 and the game is a bug, not a synonym.
export function mapTask(t) {
  return {
    id: t.id, key: t.key ?? [t.project ?? "", t.id].join("/"), title: t.title ?? null,
    project: t.project ?? null, milestone: t.milestone ?? null,
    lane: laneOf(t.stage), stage: t.stage,
    depends_on: Array.isArray(t.depends_on) ? t.depends_on.slice() : [],
    blocked_on: Array.isArray(t.blocked_on) ? t.blocked_on.slice() : [],
    blocked_by: Array.isArray(t.blocked_by) ? t.blocked_by.map((b) => ({ ...b })) : [],
    pr: t.pr ?? null, pr_url: t.pr_url ?? null,
    actions: Array.isArray(t.actions) ? t.actions.slice() : [],
    badges: Array.isArray(t.badges) ? t.badges.map((b) => ({ ...b })) : [],
    crew: Array.isArray(t.crew) ? t.crew.map((c) => ({ ...c })) : [],
    merged_seq: t.merged_seq ?? null,
    confirm: t.confirm === true,
  };
}

// docs/interface.md section 1.2: the crewman own fields, plus a stable
// puppet choice for a crew id the game has not seen a model for (a hash, not
// a guess re-rolled every snapshot, so a crewman does not change puppet
// mid-run).
const SAILOR_MODELS = ["sailor-hammer", "sailor-bandana", "sailor-spyglass"];
function hashModel(id) {
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) | 0;
  return SAILOR_MODELS[Math.abs(h) % SAILOR_MODELS.length];
}
export function mapCrew(c, engine) {
  return {
    id: c.id, role: c.role, name: c.crew_name || c.name || c.id,
    task: c.task ?? null, title: c.title ?? null, project: c.project ?? null,
    state: c.state ?? "unknown",
    activity: c.activity ?? null, progress: c.progress ?? null,
    round: c.round ?? null, attempt: c.attempt ?? null,
    model: c.role === "worker" ? hashModel(c.id) : null,
    vendor: engine ? (engine.cross && c.role === "reviewer" ? engine.reviewer : engine.vendor) : null,
  };
}

// The full view model (section 1): everything the game renderer needs, read
// once per snapshot. `raw` is exactly one /api/state (or SSE `state`)
// payload.
export function mapView(raw) {
  const engine = raw.engine ?? null;
  return {
    lanes: Array.isArray(raw.lanes) ? raw.lanes.slice() : [],
    projects: Array.isArray(raw.projects) ? raw.projects.slice() : [],
    default_project: raw.default_project ?? null,
    project: raw.project ?? null,
    deckLimit: raw.deckLimit ?? 24,
    greenlit: raw.greenlit === true,
    engine,
    counts: { ...(raw.counts ?? {}) },
    tasks: Array.isArray(raw.tasks) ? raw.tasks.map(mapTask) : [],
    crew: Array.isArray(raw.crew) ? raw.crew.map((c) => mapCrew(c, engine)) : [],
    pending: Array.isArray(raw.pending) ? raw.pending.map((p) => ({ ...p })) : [],
    responses: Array.isArray(raw.responses) ? raw.responses.map((r) => ({ ...r })) : [],
    handoffs: Array.isArray(raw.handoffs) ? raw.handoffs.map((h) => ({ ...h })) : [],
    outcomes: Array.isArray(raw.outcomes) ? raw.outcomes.map((o) => ({ ...o })) : [],
    recent: Array.isArray(raw.recent) ? raw.recent.slice() : [],
    pr_urls: raw.pr_urls ?? {},
    pr_urls_by_project: raw.pr_urls_by_project ?? {},
  };
}

// The two writes the captain may make (section 2), and nothing else. Every
// other action the Playground offers - dispatch, survey, set course,
// approve, reject, merge, push, the checks, hands aboard, mini-games,
// captain movement - stays local or is not offered at all in Live, per the
// interface doc; command() below is the whole of the seam.
const WRITE_HEADERS = { "content-type": "application/json" };

export class BoardSource {
  // opts: { base, token, project, fetchImpl, EventSourceImpl, onError }
  // base is the board own origin (empty for same-origin, or
  // http://127.0.0.1:4173 in a test); token is the tab session token
  // (never the board secret), sent as `Authorization: Bearer` exactly as
  // T-122 requires, alongside the browser own Origin header, which fetch
  // can neither read nor override.
  constructor(opts = {}) {
    this.mode = "live";
    this.base = opts.base ?? "";
    this.token = opts.token ?? "";
    this.project = opts.project ?? null;
    this.fetchImpl = opts.fetchImpl ?? (typeof fetch === "function" ? fetch : null);
    this.EventSourceImpl = opts.EventSourceImpl ?? (typeof EventSource === "function" ? EventSource : null);
    this.onError = typeof opts.onError === "function" ? opts.onError : () => {};
    this.writes = 0;
    this._es = null;
    this._seen = new Set();
  }
  _url(path) {
    const q = this.project ? "?project=" + encodeURIComponent(this.project) : "";
    return this.base + path + q;
  }
  _authed() {
    return this.token ? { authorization: "Bearer " + this.token } : {};
  }
  // cb(view, events): called once per SSE `state` (which the board already
  // sends immediately on connect, so there is no separate initial fetch to
  // race against it), and again whenever the connection reloads (the board
  // own `reload` event, which the game re-subscribes to like the board page
  // does, rather than reading a copy of that behaviour).
  subscribe(cb) {
    if (!this.EventSourceImpl) throw new Error("no EventSource available");
    const connect = () => {
      const es = new this.EventSourceImpl(this._url("/events"));
      this._es = es;
      es.addEventListener("state", (ev) => {
        let raw;
        try { raw = JSON.parse(ev.data); } catch { return; }
        const view = mapView(raw);
        const events = newEvents(raw.recent, this._seen).map(mapEvent).filter(Boolean);
        cb(view, events);
      });
      es.addEventListener("reload", () => { es.close(); this._seen.clear(); connect(); });
      es.onerror = () => { this.onError(new Error("the board event stream dropped")); };
    };
    connect();
    return () => { this.disconnect(); };
  }
  disconnect() {
    if (this._es) { try { this._es.close(); } catch { /* already closed */ } this._es = null; }
  }
  // The one function every write goes through. A refused write resolves
  // with {ok:false, error, code}; the caller shows the board own translated
  // refusal (the `code` field, T-122 own vocabulary) rather than inventing a
  // message the board never sent.
  async _post(path, body) {
    if (!this.fetchImpl) return { ok: false, error: "no network available", code: null };
    this.writes++;
    try {
      const res = await this.fetchImpl(this.base + path, {
        method: "POST", headers: { ...WRITE_HEADERS, ...this._authed() }, body: JSON.stringify(body),
      });
      const json = await res.json().catch(() => ({}));
      if (!res.ok) return { ok: false, error: json.error ?? ("refused (" + res.status + ")"), code: json.code ?? null, status: res.status };
      return { ok: true, ...json };
    } catch (e) {
      return { ok: false, error: e && e.message ? e.message : "the request could not be sent", code: null };
    }
  }
  // command(c): the whole of section 2. Anything else is a programming
  // error in the caller, not a write the board would ever be asked to make.
  command(c) {
    if (!c || typeof c.type !== "string") return Promise.resolve({ ok: false, error: "bad command", code: null });
    if (c.type === "answer") {
      const body = { id: c.decision, chosen: c.chosen };
      if (c.chosen === "custom" && typeof c.text === "string") body.text = c.text;
      if (typeof c.note === "string") body.note = c.note;
      return this._post("/decisions", body);
    }
    if (c.type === "park" || c.type === "unpark" || c.type === "drop") {
      const body = { task: c.task, action: c.type };
      if (c.project) body.project = c.project;
      if (c.confirm) body.confirm = true;
      return this._post("/tasks", body);
    }
    return Promise.resolve({ ok: false, error: "not a board write: " + c.type, code: null });
  }
}
