// The board. Binds loopback only, serves one page, and streams the event log.
//
//   bun run board/server.ts            0.0.0.0 is never an option here
//   FM_PORT=4173 FM_ROOT=.             the log it tails is the one the crew writes
//
// No build step and no framework: the page is a file, the stream is SSE, and
// the state endpoint is derived from events.jsonl and design/tasks/ so the
// board has no opinion the log does not already hold.
import { closeSync, existsSync, linkSync, mkdirSync, openSync, readFileSync, readdirSync, realpathSync, renameSync, statSync, unlinkSync, watch, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { join, resolve } from "node:path";

// canonical from the start: on macOS /var is a symlink to /private/var, and a
// path check that compares a resolved path against an unresolved root refuses
// every legitimate file in the repository
const ROOT = realpathSync(resolve(process.env.FM_ROOT ?? "."));
const PORT = Number(process.env.FM_PORT ?? 4173);
const LOG = join(ROOT, "state/events.jsonl");
const PUBLIC = join(ROOT, "board/public");
// The environment of every child the board starts, FM_PROJECT removed: a
// project is what a card or an event names, never whatever the shell that
// started the board exported. Without this a card naming no project - the
// default's - was merged by fm-merge.sh in the shell's project while the
// board's marker said the default held the merge.
const childEnv = (): Record<string, string | undefined> => {
  const { FM_PROJECT: _, ...env } = process.env;
  return { ...env, FM_ROOT: ROOT };
};

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
  // the project of the task it is on; none for a taskless firstmate
  project?: string | null;
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

// What the captain may do to a card, by where it sits (T-058). Only work
// nobody has started can be set aside: park is reversible, drop is the
// closed event and is not. A task in flight or later offers nothing, and
// POST /tasks refuses anything this table does not list.
const ACTIONS: Record<string, string[]> = {
  ready: ["park", "drop"], backlog: ["park", "drop"], parked: ["unpark", "drop"],
};
// the event each action writes, and the summary the log shows for it
const ACTION_EVENT: Record<string, { type: string; en: string; tw: string }> = {
  park: { type: "parked", en: "the captain parked {id}", tw: "船長擱置了 {id}" },
  unpark: { type: "unparked", en: "the captain unparked {id}", tw: "船長恢復了 {id}" },
  drop: { type: "closed", en: "the captain dropped {id}: it will not be done", tw: "船長決定不做 {id}" },
};

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

// The projects (design section 15.4, T-054): each registered name with the
// repository its pull requests live on (`github`, owner/repo) and the task
// list its cards are titled from, read through bin/fm-config.sh, the one
// resolver every script uses, so the board refuses a malformed registry
// exactly as they do. FM_PROJECT is not passed on, so the shell that started
// the server cannot move the default. No registry, no github, or a refused
// registry is no repository - the page then shows plain text, never a
// guessed link - and the board is the one default project it always was.
// Read at request time like the engine badge; the answer is kept only while
// config.yaml is unchanged, so an edit shows on the next refresh.
type Registered = { github: string | null; tasks: string | null };
type Registry = { name: string | null; projects: Map<string, Registered> };
const PROJECT_NAME = /^[a-z0-9-]{1,24}$/;
let registryRead: (Registry & { stamp: string }) | null = null;
const registry = (): Registry => {
  const file = join(ROOT, "config.yaml"), lib = join(ROOT, "bin/fm-config.sh");
  if (!existsSync(file) || !existsSync(lib)) return { name: null, projects: new Map() };
  const st = statSync(file);
  const stamp = `${st.ino}:${st.size}:${st.mtimeMs}:${st.ctimeMs}`;
  if (registryRead?.stamp === stamp) return registryRead;
  let name: string | null = null;
  const projects = new Map<string, Registered>();
  try {
    // One pass for all of it is safe: the registry refuses every lookup when
    // any entry lacks an owner/repo github (T-046), so either every project
    // answers or none does, and a refusal leaves the board with no registry.
    const r = Bun.spawnSync(["bash", "-c",
      '. "$1" && name="$(fm_project_resolve "" "$2")" && printf "%s\\n" "$name" && names="$(fm_projects "$2")" || exit 1\n' +
      'for n in $names; do g="$(fm_project_get "$n" github "$2")" && t="$(fm_project_get "$n" tasks "$2")" || exit 1\n' +
      '  printf "%s\\t%s\\t%s\\n" "$n" "$g" "$t"; done',
      "fm-board", lib, file], { env: childEnv(), cwd: ROOT });
    const [n = "", ...rows] = r.exitCode === 0 ? new TextDecoder().decode(r.stdout).trim().split("\n") : [];
    name = PROJECT_NAME.test(n) ? n : null;
    for (const row of name ? rows : []) {
      const [p = "", g = "", t = ""] = row.split("\t");
      if (!PROJECT_NAME.test(p)) continue;
      projects.set(p, {
        github: /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(g) ? g : null,
        // the registry refuses an absolute path or one that climbs out
        tasks: t && !t.startsWith("/") && !t.split("/").includes("..") ? t : null,
      });
    }
  } catch { name = null; projects.clear(); }
  registryRead = { stamp, name, projects };
  return registryRead;
};

// A task list (T-090): one file per task in a directory, read through
// bin/fm-config.sh's fm_tasks - the one reader every script uses - so the
// board and the dispatcher cannot disagree about what a task is. Read at
// request time; each directory's answer is kept only while none of its task
// files has changed. No directory, no library or a file that does not parse
// is no task list, never half of one.
const tasksRead = new Map<string, { stamp: string; defs: Array<Record<string, unknown>> }>();
const taskDefs = (rel: string): Array<Record<string, unknown>> => {
  const dir = join(ROOT, rel), lib = join(ROOT, "bin/fm-config.sh");
  if (!existsSync(dir) || !existsSync(lib)) return [];
  let stamp = "";
  try {
    const d = statSync(dir);
    stamp = `${d.ino}:${d.mtimeMs}|` + readdirSync(dir).filter(f => f.endsWith(".json")).sort().map(f => {
      const st = statSync(join(dir, f));
      return `${f}:${st.ino}:${st.size}:${st.mtimeMs}:${st.ctimeMs}`;
    }).join("|");
  } catch { return []; }
  const kept = tasksRead.get(rel);
  if (kept?.stamp === stamp) return kept.defs;
  let defs: Array<Record<string, unknown>> = [];
  try {
    const r = Bun.spawnSync(["bash", "-c", '. "$1" && fm_tasks "$2"', "fm-board", lib, rel], { env: childEnv(), cwd: ROOT });
    if (r.exitCode === 0) {
      defs = new TextDecoder().decode(r.stdout).split("\n").filter(Boolean).map(line => JSON.parse(line));
    }
  } catch { defs = []; }
  tasksRead.set(rel, { stamp, defs });
  return defs;
};
// the project an event or card naming none belongs to (design section 15.4)
const defaultProject = (): string => registry().name ?? "";
// what a record says it belongs to: its own `project`, else the default
const projectOf = (o: unknown): string => {
  const p = (o as { project?: unknown } | null | undefined)?.project;
  return typeof p === "string" && p ? p : defaultProject();
};
// the repository of a project's pull requests, or null when there is none
const repoOf = (project: string): string | null => registry().projects.get(project)?.github ?? null;
// a task, a pull request or a decision is known by (project, id): two
// projects' T-004 are two cards, and another project's #7 is not this one's
const keyOf = (project: string, id: unknown) => `${project}\u0000${String(id ?? "")}`;
// The one reading of a pull request number, for every place the board takes
// one: a positive integer, or the same digits as a string. The page never
// judges a number itself; it links what this lets through and nothing else.
const PR_DIGITS = "[1-9][0-9]{0,8}";
const prNumber = (n: unknown): number | null => {
  const v = typeof n === "string" && new RegExp(`^${PR_DIGITS}$`).test(n) ? Number(n) : n;
  return Number.isSafeInteger(v) && (v as number) > 0 ? v as number : null;
};
// A decision id (design section 15.4): the old D-<digits> and D-SK-<n>, or
// one that names its owner, D-<project>-<task>-<n> - a registry name, the
// task id without its hyphen, and n from 1. The board lists and answers all
// three; an owned id's project and task are read out of the id itself, never
// guessed.
const OLD_DECISION = /^D-(SK-)?[0-9]{1,6}$/;
const OWNED_DECISION = /^D-([a-z0-9-]{1,24})-(T[A-Za-z0-9]{1,32})-([1-9][0-9]{0,5})$/;
const isDecisionId = (id: string) => OLD_DECISION.test(id) || OWNED_DECISION.test(id);
const ownerOf = (id: unknown): { project: string; task: string; n: number } | null => {
  const m = OWNED_DECISION.exec(String(id ?? ""));
  return m ? { project: m[1], task: `T-${m[2].slice(1)}`, n: Number(m[3]) } : null;
};
// the pull request's page, or null when there is no number or no repository
const pullUrl = (repo: string | null, n: unknown): string | null => {
  const k = prNumber(n);
  return repo && k ? `https://github.com/${repo}/pull/${k}` : null;
};
// Every #n written anywhere in what /api/state returns - a log summary, a
// title, a decision's text, a crewman's activity - with its URL. The page
// links a #n in text through this map only. The page's pattern is the same
// one, with the same lead: no word character before the '#'.
const mentioned = (repo: string | null, value: unknown, out: Record<string, string> = {}): Record<string, string> => {
  if (!repo) return out;
  const find = new RegExp(`(?<!\\w)#(${PR_DIGITS})(?![0-9])`, "g");
  const walk = (v: unknown): void => {
    if (typeof v === "string") { for (const m of v.matchAll(find)) out[m[1]] = pullUrl(repo, m[1])!; }
    else if (Array.isArray(v)) v.forEach(walk);
    else if (v && typeof v === "object") Object.values(v).forEach(walk);
  };
  walk(value);
  return out;
};

// The answered decisions on disk, whatever shape of id they carry.
const RESPONSES = join(ROOT, "state/decisions");
const readResponses = (): Array<Record<string, any>> => existsSync(RESPONSES)
  ? readdirSync(RESPONSES).filter(f => f.endsWith(".json") && isDecisionId(f.slice(0, -5))).flatMap(f => {
    try { return [JSON.parse(readFileSync(join(RESPONSES, f), "utf8"))]; } catch { return []; }
  }) : [];
// Where a merge answered on the board stands (design section 5.2): running
// while the helper has not exited, then merged or failed. A record written
// before merges ran in the background says the same with merged.ok.
type MergeOutcome = "running" | "merged" | "failed";
const mergeOf = (d: Record<string, any> | null | undefined): MergeOutcome | null =>
  d?.merge === "running" || d?.merge === "merged" || d?.merge === "failed" ? d.merge
    : d?.merged?.ok === true ? "merged" : d?.merged?.ok === false ? "failed" : null;
// the running merges whose outcome GitHub could not tell the board: the card
// says so by name, and the project's turn stays held until it can
const unknownOutcome = new Set<string>();

// Each project's task list, as the registry names it: a directory of task
// files (T-090). A tree with no registry has the one design/tasks/ it always had.
const taskLists = (): Array<{ project: string; defs: Array<Record<string, unknown>> }> => {
  const reg = registry(), def = defaultProject();
  // The default project's list is design/tasks/ unless the registry names
  // one that exists: an entry that leaves `tasks` to its default
  // (projects/<name>/tasks) must not empty the board it always had.
  const dirs: Array<[string, string]> = reg.projects.size
    ? [...reg.projects].map(([name, p]) => {
      const rel = p.tasks ?? `projects/${name}/tasks`;
      return [name, name === def && !existsSync(join(ROOT, rel)) ? "design/tasks" : rel];
    })
    : [[def, "design/tasks"]];
  // the default project first, so a board of one project reads as before
  dirs.sort((a, b) => Number(b[0] === def) - Number(a[0] === def));
  return dirs.map(([project, rel]) => ({ project, defs: taskDefs(rel) }));
};

// `only` is ?project=: that project's work, cards and log, and the counts of
// those. Without it, every project on one page (design section 15.10 point 4).
const state = (only: string | null = null) => {
  const events = readEvents();
  const def = defaultProject();
  // every record that carries a pr number carries its URL beside it, on its
  // own project's repository
  const linked = <T extends Record<string, unknown>>(o: T): T & { pr_url?: string | null } =>
    o && typeof o === "object" && o.pr != null ? { ...o, pr_url: pullUrl(repoOf(projectOf(o)), o.pr) } : o;
  const pend = pending();
  const responses = readResponses();
  // a task is its project and its id; `key` is how the rest of this reads one
  const definitions = new Map<string, Record<string, unknown>>();
  const taskIds: Array<{ project: string; id: string }> = [];
  for (const list of taskLists()) for (const d of list.defs) {
    const k = keyOf(list.project, d.id);
    if (definitions.has(k)) continue;
    definitions.set(k, d);
    taskIds.push({ project: list.project, id: String(d.id) });
  }
  const ek = (e: Event) => keyOf(projectOf(e), e.task);
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
  // The captain's own word on untouched work: the last of parked / unparked
  // wins. It only ever matters while the task is untouched - once work has
  // started, the stage the log gives it is what the card shows.
  const parked = new Set<string>();
  // tasks something other than a decision card has moved
  const worked = new Set<string>();
  for (const [index, e] of events.entries()) {
    if (!e.task) continue;
    const k = ek(e);
    const n = prNumber(e.pr);
    if (n) pr.set(k, n);
    if (FINAL.has(stage.get(k) ?? "")) continue;
    if (e.type === "parked") parked.add(k);
    if (e.type === "unparked") parked.delete(k);
    if (e.type === "ask_pass_criteria") asking.add(k);
    if (e.type === "criteria_returned") asking.delete(k);
    const s = STAGE[e.type ?? ""];
    if (s) { stage.set(k, s); moved.set(k, e); }
    if (s && e.type !== "decision_requested") worked.add(k);
    if (s === "merged") settledAt.set(k, index);
  }
  // A pending decision is a fact on disk, not a point in a history: while
  // the card is up, the task is the captain's whatever else has been said
  // since. T-016 read as "working" because a dispatch that should never
  // have happened landed after the card went up.
  const awaiting = new Set(pend.map((p: Record<string, unknown>) => keyOf(projectOf(p), p.task)));
  const known = new Set(taskIds.map((t) => keyOf(t.project, t.id)));
  for (const e of events) {
    if (!e.task || known.has(ek(e))) continue;
    known.add(ek(e));
    taskIds.push({ project: projectOf(e), id: e.task });
  }
  // Where the log puts a task. Untouched is not yet a lane: which of backlog
  // or ready it is depends on its dependencies, decided below from this.
  // A task that turns ready gets a readiness card before anyone starts it
  // (T-059), and bin/fm-ready.sh records that card's id in state/ready/.
  // While nothing else has moved the task and no other card is up, that card
  // is the task waiting to be judged, not the task at the captain's.
  // fm-ready.sh judges the default project's tasks only, so a record under
  // state/ready/ is about that project's task of that id and no other's.
  const projectOfKey = (k: string) => k.slice(0, k.indexOf("\u0000"));
  const idOfKey = (k: string) => k.slice(k.indexOf("\u0000") + 1);
  const readinessCard = (id: string): string | null => {
    const f = join(ROOT, "state/ready", `${id}.json`);
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id) || !existsSync(f)) return null;
    try { return String(JSON.parse(readFileSync(f, "utf8")).decision ?? "") || null; } catch { return null; }
  };
  const judging = (id: string) => {
    if (worked.has(id) || projectOfKey(id) !== def) return false;
    const card = readinessCard(idOfKey(id));
    return card !== null && pend.every((p: Record<string, unknown>) =>
      keyOf(projectOf(p), p.task) !== id || String(p.id ?? "") === card);
  };
  const stageOf = (id: string) => {
    const terminal = FINAL.has(stage.get(id) ?? "");
    if (!terminal && judging(id)) return "untouched";
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
    for (const p of pend.filter((x: Record<string, unknown>) => keyOf(projectOf(x), x.task) === id)) {
      const options = (p as { details?: { en?: { options?: unknown } } }).details?.en?.options;
      out.push({ kind: "decision", id: String(p.id ?? ""),
        options: options && typeof options === "object" ? Object.keys(options).length : null });
    }
    return out;
  };
  // a dependency is a task of the same project: another project's T-001
  // merging does not unblock this one's
  const dependsOf = (id: string): string[] => {
    const d = definitions.get(id);
    return d && Array.isArray(d.depends_on)
      ? (d.depends_on as unknown[]).map((dep) => keyOf(projectOfKey(id), dep)) : [];
  };
  // untouched work waiting on work that is not in yet: a dependency counts
  // as done only once it has merged, and one the log has never heard of is
  // not done. The same list decides the lane, so a card in backlog always
  // names what it waits on and a card in ready never does.
  const blockersOf = (id: string) =>
    stageOf(id) === "untouched" ? dependsOf(id).filter((dep) => stageOf(dep) !== "merged") : [];
  // A parked task keeps the blockers it would have, so unparking it lands
  // where its dependencies say without the page working that out.
  const laneOf = (id: string): string => {
    if (stageOf(id) !== "untouched") return stageOf(id);
    if (parked.has(id)) return "parked";
    return blockersOf(id).length ? "backlog" : "ready";
  };
  const tasks = taskIds.map(({ project, id: taskId }) => {
    const id = keyOf(project, taskId);
    const d = definitions.get(id) || {};
    const depends = dependsOf(id);
    const blockedOn = blockersOf(id);
    const at = laneOf(id);
    return ({
    id: taskId,
    // whose task it is: a project's name is data, shown as it is written.
    // `key` is the one string that tells two projects' T-004 apart.
    project: project || null, key: `${project}/${taskId}`,
    title: typeof d.title === 'string' ? d.title : null, milestone: d.milestone ?? null,
    depends_on: depends.map(idOfKey),
    stage: at,
    pr: pr.get(id) ?? null,
    pr_url: pullUrl(repoOf(project), pr.get(id)),
    blocked_on: blockedOn.map(idOfKey),
    // why each blocker blocks: a dependency the captain parked or dropped
    // will not arrive on its own, and the card has to say so. One neither
    // the plan nor the log knows is unknown, not ready.
    blocked_by: blockedOn.map((dep) => ({ id: idOfKey(dep),
      stage: definitions.has(dep) || stage.has(dep) ? laneOf(dep) : "unknown" })),
    // only work the plan lists can be set aside: a task the log alone knows
    // about is not the captain's to park
    actions: definitions.has(id) ? (ACTIONS[at] ?? []) : [],
    badges: badgesOf(id, at),
    // the aboard crew's names, filled in once the crew is known below
    crew: [] as string[],
    // where the merge sits in the log, so the lane can show the latest first
    merged_seq: settledAt.get(id) ?? null,
  }); });
  const taskAt = (project: string, id: unknown) =>
    tasks.find((x) => keyOf(x.project ?? "", x.id) === keyOf(project, id));
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
    // a crewman moving to another project's task of the same id has moved
    if (e.type === 'dispatched' || (e.task && (previous?.task !== e.task || projectOf(previous) !== projectOf(e)))) {
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
      const candidates = [...lastByActor].filter(([id,event]) => id !== actor && id !== 'firstmate' && ek(event) === ek(e) && event.type !== 'agent_finished' && !finished.has(id) && (roles.get(id) || roleOf(id,event)) === role);
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
    if (kind) handoffs.push({identity:`handoff:${index}:${JSON.stringify(e)}`,kind,from:from || null,to:to || null,task:e.task || null,
      ...(e.task ? { project: projectOf(e) || null } : {})});
    if (!e.actor || e.actor === "github" || e.actor === "captain") continue;
    lastByActor.delete(e.actor);
    // an event naming no task keeps the task, and so the project, it was on
    lastByActor.set(e.actor, e.task ? {...e, project: projectOf(e)} : {...e, task: previous?.task, project: previous ? projectOf(previous) : projectOf(e)});
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
  const fmTask = fm?.task && !done.has(ek(fm)) ? fm.task : null;
  const fmT = fmTask ? taskAt(projectOf(fm), fmTask) : undefined;
  const planned = (e: Event) => authored((definitions.get(ek(e)) as { activity?: unknown } | undefined)?.activity);
  const crew: Crew[] = [{
    id: "firstmate", role: "firstmate",
    state: greenlit ? (fm ? phases.get('firstmate') || 'unknown' : 'unknown') : "queued",
    task: fmTask, title: fmT?.title ?? null,
    // firstmate is every project's; the project is the one of the task it is on
    project: fmTask ? projectOf(fm) || null : null,
    activity: fm
      ? (activity.get("firstmate")
        || (fmTask ? planned(fm!) : null)
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
    if (done.has(ek(e))) continue;
    const t = taskAt(projectOf(e), task);
    crew.push({
      id: actor,
      // stated, not guessed: the emitter writes what it is, so renaming
      // an actor cannot silently turn every reviewer into a worker
      role: roles.get(actor) || roleOf(actor, e),
      state: phases.get(actor) || 'unknown',
      task, title: t?.title ?? null,
      project: projectOf(e) || null,
      crew_name: names.get(actor),
      progress: progress.get(actor) ?? null,
      // Replay/event activity wins over static task.activity; never scalar title.
      activity: activity.get(actor) || planned(e) || null,
    });
  }
  // The permanently aboard human captain is rendered separately from agents.

  // A card names who is aboard on it: the agents on the deck, not whoever
  // once touched the task. firstmate is the coordinator, not the crew on it.
  // Filtered by ?project= below, so this is every project's deck.
  const aboard = crew.slice(0, DECK_LIMIT);
  for (const t of tasks) {
    t.crew = aboard.filter((c) => c.role !== "firstmate" && c.task === t.id && (c.project ?? "") === (t.project ?? ""))
      .map((c) => c.crew_name || c.id);
  }

  // A refused merge stops being news once the same task or pull request is
  // merged afterwards - by a later answer on the board or any other way. The
  // record keeps what happened; the flag says it has been overtaken. Both
  // are keyed by project: another project's merge of its T-001 is not this.
  const mergedEvents = events.filter((e) => e.type === "merged");
  const reviewed = responses.map((d: Record<string, any>) => {
    const merge = mergeOf(d);
    const shown = { ...d, merge, ...(merge === "running" ? { merge_unknown: unknownOutcome.has(String(d.id)) } : {}) };
    if (merge !== "failed") return shown;
    const sameWork = (o: Record<string, unknown>) => projectOf(o) === projectOf(d) && (
      (d.task != null && o.task != null && String(o.task) === String(d.task))
      || (d.pr != null && o.pr != null && String(o.pr) === String(d.pr)));
    const superseded = mergedEvents.some((e) => sameWork(e) && later(e.ts, d.ts))
      || responses.some((o: Record<string, any>) => o !== d && mergeOf(o) === "merged"
        && sameWork(o) && later(o.ts, d.ts));
    return { ...shown, superseded };
  });

  // The projects on the board, the default first: more than one is what
  // makes the page put a project chip on every card, bubble and decision.
  // Every lane card, card and answer counts, whatever its shape; firstmate,
  // who is every project's, names none.
  const seen = new Set<string>([def]);
  for (const x of [...tasks, ...pend, ...responses] as Array<Record<string, unknown>>) seen.add(projectOf(x));
  for (const c of crew) if (c.role !== "firstmate") seen.add(projectOf(c));
  const projects = [...seen].filter(Boolean);
  // ?project= keeps that project's records; firstmate, who is every
  // project's, stays aboard
  const mine = (o: unknown) => only === null || projectOf(o) === only;
  const shownTasks = tasks.filter(mine);
  const shownPending = pend.filter(mine);
  const shownCrew = crew.filter((c) => c.role === "firstmate" || mine(c));

  const outcomeOf = (e: Event) => e.type === "decision_made"
    ? `decision:${(e.data as any)?.decision ?? JSON.stringify(e)}`
    // the default project's merges keep the identity they always had
    : projectOf(e) === def ? `merge:${e.pr ?? e.task ?? JSON.stringify(e)}`
    : `merge:${projectOf(e)}:${e.pr ?? e.task ?? JSON.stringify(e)}`;
  const out = {
    engine: engine(),
    lanes: LANES,
    projects,
    // what a record naming no project belongs to, and the filter in force
    default_project: def || null,
    project: only,
    // The deck holds this many. One number: the server truncates and
    // tells the page what the limit was, rather than both of them
    // knowing 24 - truncating only on the client also left the server
    // building an unbounded array into every payload.
    deckLimit: DECK_LIMIT,
    crew: shownCrew.slice(0, DECK_LIMIT),
    greenlit,
    counts: {
      merged: shownTasks.filter((t) => t.stage === "merged").length,
      inflight: shownTasks.filter((t) => ["working", "review"].includes(t.stage)).length,
      blocked: shownTasks.filter((t) => t.stage === "gate").length,
      ready: shownTasks.filter((t) => t.stage === "ready").length,
      backlog: shownTasks.filter((t) => t.stage === "backlog").length,
      parked: shownTasks.filter((t) => t.stage === "parked").length,
      // one per decision on the deck: the captain is what these wait on,
      // every project's or only the filtered one's
      waiting: shownPending.length,
    },
    tasks: shownTasks,
    // design.md is linked from a card only when there is one to open
    designDoc: existsSync(join(ROOT, "design/design.md")),
    // Full outcome stream: a busy refresh must not lose events outside recent.
    responses: reviewed.filter(mine).map(linked),
    handoffs: handoffs.filter((h) => !("project" in h) || mine(h)),
    outcomes: [...events.filter(e => (e.type === "merged" || e.type === "decision_made") && mine(e))
      .map(e => linked({ ...e, identity: outcomeOf(e) })),
      ...responses.filter(d => d.identity && mine(d)).map(d => ({type:'decision_made',identity:d.identity,data:{decision:d.id,chosen:d.chosen}}))],
    recent: events.filter(mine).slice(-40).reverse().map(linked),
    pending: shownPending.map(linked),
  };
  // Every #n in text links to its own project's pull request: a log line,
  // a card and a crewman's activity each read the map of the project they
  // belong to. `pr_urls` is the default project's, which is every #n on a
  // board of one project.
  const byProject: Record<string, Record<string, string>> = {};
  for (const list of [out.tasks, out.crew, out.pending, out.responses, out.recent, out.outcomes, out.handoffs] as unknown[][])
    for (const x of list) {
      const p = projectOf(x);
      byProject[p] = mentioned(repoOf(p), x, byProject[p] ?? {});
    }
  return { ...out, pr_urls: byProject[def] ?? {}, pr_urls_by_project: byProject };
};

// whether `a` happened at or after `b`. Event stamps are whole seconds, so
// one in the same second is not earlier.
const later = (a: unknown, b: unknown) => {
  const x = Date.parse(String(a ?? "")), y = Date.parse(String(b ?? ""));
  return !Number.isFinite(x) || !Number.isFinite(y) || x + 1000 > y;
};

// when the board first saw each pending card's file, by file name
const firstSeen = new Map<string, number>();
// Decisions the captain has been asked for but has not answered.
// A card for a pull request that is already merged is the board lying. It
// happens whenever a merge goes through some other way - a decision file
// outlives the thing it was asking about - and the captain is then offered
// a choice that cannot be made.
const pending = () => {
  const dir = join(ROOT, "state/pending");
  if (!existsSync(dir)) return [];
  const terminal = readEvents().filter((e) => e.type === "merged" || e.type === "closed");
  // (project, pr) and (project, task) are the keys: another project's merged
  // #7 does not settle this project's card for #7. Naming none is the default's.
  const def = defaultProject();
  const within = (p: unknown, k: unknown) => `${typeof p === "string" && p ? p : def}\u0000${String(k ?? "")}`;
  const settled = new Set(
    terminal
      .filter((e) => e.type === "merged" || e.type === "closed")
      .map((e) => within((e as Record<string, unknown>).project, (e as Record<string, unknown>).pr)),
  );
  const settledTasks = new Set(terminal.filter(e => e.task).map(e => within((e as Record<string, unknown>).project, e.task)));
  // Oldest request first, every project's cards in one list (design section
  // 15.10 point 4), so a card never hides behind another project's and
  // answering one never reorders the rest. A record that states its own `ts`
  // is taken at its word. Otherwise it is when the file was written, as the
  // board first saw it: bin/fm-decide.sh creates a card once, with noclobber,
  // and nothing else writes one, and should anything rewrite a card anyway it
  // keeps its place while the board runs. The id settles a tie, never
  // readdirSync, whose order differs between macOS and Linux.
  const files = readdirSync(dir).filter((f) => f.endsWith(".json"));
  for (const f of [...firstSeen.keys()]) if (!files.includes(f)) firstSeen.delete(f);
  const asked = (d: Record<string, unknown>, f: string) => {
    const t = Date.parse(String(d.ts ?? ""));
    if (Number.isFinite(t)) return t;
    if (!firstSeen.has(f)) firstSeen.set(f, statSync(join(dir, f)).mtimeMs);
    return firstSeen.get(f)!;
  };
  return files.flatMap((f) => {
    try {
      const d = JSON.parse(readFileSync(join(dir, f), "utf8"));
      if (d.pr != null && settled.has(within(d.project, d.pr))) return [];
      if (d.task != null && settledTasks.has(within(d.project, d.task))) return [];
      return [{ card: { ...d, owner: ownerOf(d.id) }, at: asked(d, f) }];
    } catch { return []; }
  }).sort((a, b) => a.at - b.at
    || String(a.card.id ?? "").localeCompare(String(b.card.id ?? ""), "en", { numeric: true }))
    .map((x) => x.card);
};

// --- Merges run after the answer, not inside it (design sections 5.2, 15.10) ---
// One merge at a time within a project, any number across projects. The
// board is the only writer of a decision record's `merge`: it publishes
// "running", starts bin/fm-merge.sh detached under the project's merge
// marker, and rewrites the record to "merged" or "failed" when the helper
// exits. A helper that dies without a word - or a board that restarts while
// one runs - is recovered from the marker, the log and GitHub, never guessed.
const MERGING = join(ROOT, "state/merging");
// a tree with no registry has one project with no name; no name can begin
// with an underscore, so its marker cannot be taken for a project's
const markerOf = (project: string) => join(MERGING, `${project || "_default"}.json`);
type Marker = { decision: string; project: string; pr: number; task: string | null; pid: number; started: string; ts: string };
const readJson = <T,>(file: string): T | null => {
  try { return JSON.parse(readFileSync(file, "utf8")) as T; } catch { return null; }
};
// when a process started, as ps prints it: with the pid, what tells the
// helper the board started apart from a later process given the same pid
const startedAt = (pid: number): string => {
  try {
    const r = Bun.spawnSync(["ps", "-o", "lstart=", "-p", String(pid)], { stdin: "ignore", env: childEnv() });
    return r.exitCode === 0 ? new TextDecoder().decode(r.stdout).trim().replace(/\s+/g, " ") : "";
  } catch { return ""; }
};
const alive = (m: Marker | null): boolean => {
  if (!m || !Number.isSafeInteger(m.pid) || m.pid <= 1 || !m.started) return false;
  try { process.kill(m.pid, 0); } catch (e) { if ((e as { code?: string }).code !== "EPERM") return false; }
  return startedAt(m.pid) === m.started;
};
// write a record whole or not at all: a reader never sees half of one
const rewrite = (file: string, record: unknown) => {
  const temporary = join(RESPONSES, `.${crypto.randomUUID()}.tmp`);
  writeFileSync(temporary, JSON.stringify(record) + "\n", { flag: "wx" });
  renameSync(temporary, file);
};
// the merges this board process started and is waiting on itself
const ours = new Set<string>();
// A running record's outcome, written once. The marker goes with it, so the
// project's turn is free the moment the record says how it ended.
const settle = (id: string, merge: "merged" | "failed", reason = "") => {
  const file = join(RESPONSES, `${id}.json`);
  const d = readJson<Record<string, any>>(file);
  unknownOutcome.delete(id);
  if (d && mergeOf(d) === "running") {
    rewrite(file, { ...d, merge, ...(merge === "failed" ? { merge_reason: reason } : {}), merge_settled: new Date().toISOString() });
  }
  const marker = markerOf(projectOf(d));
  if (readJson<Marker>(marker)?.decision === id) { try { unlinkSync(marker); } catch { /* already gone */ } }
};
// a project's turn is held while any of its records says running, whether
// this board started it, a previous one did, or its outcome is unknown
const mergeRunningIn = (project: string) =>
  readResponses().some((d) => mergeOf(d) === "running" && projectOf(d) === project);
const HELPER_STOPPED = "the merge helper stopped before recording an outcome";
// Start the helper for an answered merge card. Detached, with its output in
// a file: a board restarting under bun --watch neither kills it nor leaves
// it writing into a closed pipe.
const startMerge = (id: string, project: string, pr: number, task: string | null, onProject: string[]) => {
  mkdirSync(MERGING, { recursive: true });
  const log = join(MERGING, `${project || "_default"}.out`);
  let child;
  try {
    const fd = openSync(log, "w");
    try {
      child = spawn(join(ROOT, "bin/fm-merge.sh"),
        ["--pr", String(pr), ...(task ? ["--task", task] : []), ...onProject, "--repo", ROOT],
        { detached: true, stdio: ["ignore", fd, fd], env: childEnv() });
    } finally { closeSync(fd); }
  } catch { settle(id, "failed", "Merge helper unavailable"); return; }
  ours.add(id);
  const reasonOf = (code: number | null) => {
    let said = "";
    try { said = readFileSync(log, "utf8").trim().split("\n").filter((l) => l.trim()).pop() ?? ""; } catch { /* none */ }
    return (said || `the merge helper exited ${code ?? "on a signal"}`).slice(0, 500);
  };
  child.on("error", () => { ours.delete(id); settle(id, "failed", "Merge helper unavailable"); });
  child.on("exit", (code) => {
    ours.delete(id);
    settle(id, code === 0 ? "merged" : "failed", code === 0 ? "" : reasonOf(code));
  });
  // not unref'd: the board runs until it is stopped anyway, and its exit
  // handler above is how the record learns the outcome
  if (!child.pid) return;
  const marker: Marker = { decision: id, project, pr, task, pid: child.pid, started: startedAt(child.pid), ts: new Date().toISOString() };
  writeFileSync(markerOf(project), JSON.stringify(marker) + "\n");
};
// What GitHub says of a pull request: MERGED, OPEN, CLOSED, or null when it
// cannot be read. Asynchronous, so a slow gh never stalls the board.
// Only ever on the repository the registry names for the record's project.
// A project the registry does not name - unregistered since, or a registry
// that refuses - has no repository, and its outcome is unknown: gh is not
// asked at all, because without --repo it answers for the checkout the board
// runs in, which is some other project's #n.
const GH = process.env.FM_GH || "gh";
const githubState = async (project: string, pr: number): Promise<string | null> => {
  const repo = repoOf(project);
  if (!repo) return null;
  try {
    const p = Bun.spawn([GH, "pr", "view", String(pr), "--repo", repo, "--json", "state"],
      { cwd: ROOT, stdin: "ignore", stdout: "pipe", stderr: "ignore", env: childEnv() });
    const timer = setTimeout(() => p.kill(), 20_000);
    const [code, text] = await Promise.all([p.exited, new Response(p.stdout).text()]);
    clearTimeout(timer);
    if (code !== 0) return null;
    const s = (JSON.parse(text) as { state?: unknown }).state;
    return s === "MERGED" || s === "OPEN" || s === "CLOSED" ? s : null;
  } catch { return null; }
};
// On start and on every poll while a record says running: a helper still
// alive is left to finish; one that is gone has its outcome read from a
// merged event for the card's (project, pr) after the answer, then from
// GitHub. If GitHub cannot be read the record stays running, marked unknown,
// and the next poll tries again.
let recovering = false;
const recover = async () => {
  if (recovering) return;
  recovering = true;
  try {
    for (const d of readResponses()) {
      const id = String(d.id ?? "");
      if (mergeOf(d) !== "running" || ours.has(id)) continue;
      const project = projectOf(d);
      const marker = readJson<Marker>(markerOf(project));
      if (marker?.decision === id && alive(marker)) { unknownOutcome.delete(id); continue; }
      const pr = prNumber(d.pr);
      const logged = pr !== null && readEvents().some((e) => e.type === "merged"
        && projectOf(e) === project && prNumber(e.pr) === pr && later(e.ts, d.ts));
      if (logged) { settle(id, "merged"); continue; }
      const gh = pr === null ? null : await githubState(project, pr);
      // the record may have been settled while GitHub was being asked
      if (mergeOf(readJson(join(RESPONSES, `${id}.json`))) !== "running") continue;
      if (gh === "MERGED") settle(id, "merged");
      else if (gh === "OPEN" || gh === "CLOSED") settle(id, "failed", HELPER_STOPPED);
      else unknownOutcome.add(id);
    }
  } finally { recovering = false; }
};
const anyRunning = () => readResponses().some((d) => mergeOf(d) === "running" && !ours.has(String(d.id ?? "")));
if (anyRunning()) void recover();
setInterval(() => { if (anyRunning()) void recover(); }, 1000);

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
    // ?project= shows one project; without it, or with no project's name,
    // every project is on the board
    const asked = url.searchParams.get("project") ?? "";
    const only = PROJECT_NAME.test(asked) ? asked : null;
    if (url.pathname === "/api/state") return json(state(only));

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
          send("state", state(only));
          // the log is not all the board shows: a merge's outcome lands in
          // its decision record, and an unknown one is known only here
          const stamp = () => [LOG, RESPONSES, join(ROOT, "state/pending")]
            .map((f) => { try { const s = statSync(f); return `${s.size}:${s.mtimeMs}`; } catch { return "-"; } })
            .join("|") + `|${[...unknownOutcome].sort().join(",")}`;
          let size = stamp();
          const poll = setInterval(() => {
            const now = stamp();
            if (now !== size) { size = now; send("state", state(only)); }
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
        if (!isDecisionId(id)) return json({ error: "bad decision id" }, 400);
        if (!["A", "B", "C", "D", "custom"].includes(chosen)) return json({ error: "bad choice" }, 400);
        // Count Unicode code points, preserving the literal text including spaces.
        const text = body?.text;
        if (chosen === "custom" && (typeof text !== "string" || !text.trim()
          || [...text].length > 1000 || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f\ud800-\udfff]/u.test(text))) {
          return json({ error: "invalid custom text", code: "customInvalid" }, 400);
        }

        const p = pending().find((d: any) => d.id === id);
        const dir = RESPONSES;
        mkdirSync(dir, { recursive: true });
        const file = join(dir, `${id}.json`);
        if (existsSync(file)) {
          // the stored record, with whatever merge it holds by now
          const decision = JSON.parse(readFileSync(file, "utf8"));
          if (decision.chosen !== chosen || (chosen === "custom" && decision.text !== text))
            return json({ error: "decision already recorded differently" }, 409);
          return json({ ok: true, already: true, decision, merge: mergeOf(decision) });
        }
        if (!p) return json({ error: "no pending decision" }, 404);
        // D exists only on a card that offers it: a readiness card's drop (T-059)
        if (chosen === "D" && !p.details?.en?.options?.D) return json({ error: "bad choice" }, 400);
        // the card's project is what its request recorded. A card recording
        // none is the default project's - a tree with no registry names its
        // ids by the self project but has no registry to merge by name on -
        // so the id's owner is never passed on as a --project
        const project = typeof p.project === "string" && p.project ? p.project : null;
        const onProject = project ? ["--project", project] : [];
        const merging = p.kind === "merge" && chosen === "A" && prNumber(p.pr) !== null && typeof p.pr === "number";
        // One merge at a time within a project. Refused before anything is
        // published or emitted, so the card stays pending as it was; nothing
        // below awaits, so no second answer can slip in between.
        if (merging && mergeRunningIn(projectOf(p)))
          return json({ error: "a merge is already running in this project", code: "mergeBusy", project: projectOf(p) || null }, 409);
        const decision: Record<string, unknown> = {
          id, chosen, task: p?.task ?? null, pr: typeof p?.pr === "number" ? p.pr : null, kind: p?.kind ?? "choice",
          ...(project ? { project } : {}),
          ...(chosen === "custom" ? { text } : {}),
          note: typeof body?.note === "string" ? body.note.slice(0, 500) : "",
          ts: new Date().toISOString(),
          identity: `decision:${id}`,
          // published running; the helper's exit rewrites it to merged or failed
          merge: merging ? "running" : null,
        };
        // Exclusive creation makes repeated requests unable to rerun a merge.
        const temporary = join(dir, `.${id}.${crypto.randomUUID()}.tmp`);
        writeFileSync(temporary, JSON.stringify(decision) + "\n", { flag: "wx" });
        try { linkSync(temporary, file); } finally { unlinkSync(temporary); }
        let eventRecorded = false;
        try {
          const emitted = Bun.spawnSync([join(ROOT, "bin/fm-emit.sh"),
          "--actor", "captain", "--type", "decision_made",
          ...(p.task ? ["--task", p.task] : []), ...onProject,
          "--data", JSON.stringify({ decision: id, chosen, outcome: "recorded" }),
          "--en", `${id} recorded ${chosen}`, "--tw", `${id} 已記錄 ${chosen}`],
          { env: childEnv() });
          eventRecorded = emitted.exitCode === 0;
        } catch { /* the durable decision still exists; report the event failure */ }

        // the helper runs in the background; the answer does not wait for it
        if (merging) startMerge(id, projectOf(p), p.pr, p.task ?? null, onProject);
        const pf = join(ROOT, "state/pending", `${id}.json`);
        if (existsSync(pf)) unlinkSync(pf);
        const stored = readJson<Record<string, unknown>>(file) ?? decision;
        return json({ ok: true, decision: stored, merge: mergeOf(stored), eventRecorded });
      }).catch(() => json({ error: "bad request" }, 400));
    }

    // The captain parks, unparks or drops a task (T-058). Written as a captain
    // event through fm-emit.sh like every other board write; the plan in
    // design/tasks/ is never touched. The check and the write run with
    // nothing in between - spawnSync holds the only thread - so two clicks
    // cannot both pass the check. Declared JSON only: a cross-site form can
    // post text/plain without asking first, but not application/json.
    if (url.pathname === "/tasks" && req.method === "POST") {
      if (!/^application\/json\b/i.test(req.headers.get("content-type") ?? ""))
        return json({ error: "json only" }, 415);
      return req.json().then((body: any) => {
        const id = typeof body?.task === "string" ? body.task : "";
        const action = typeof body?.action === "string" ? body.action : "";
        const spec = Object.hasOwn(ACTION_EVENT, action) ? ACTION_EVENT[action] : null;
        if (!spec) return json({ error: "bad action" }, 400);
        // a task is its project and its id; naming none is the default's
        const project = typeof body?.project === "string" && body.project ? body.project : defaultProject();
        const task = state().tasks.find((x) => x.id === id && (x.project ?? "") === project);
        if (!task) return json({ error: "no such task" }, 404);
        if (!task.actions.includes(action))
          return json({ error: `cannot ${action} a task that is ${task.stage}`, stage: task.stage }, 409);
        // the default project's events name none, exactly as before
        const onProject = project && project !== defaultProject() ? ["--project", project] : [];
        const r = Bun.spawnSync([join(ROOT, "bin/fm-emit.sh"),
          "--actor", "captain", "--type", spec.type, "--task", id, ...onProject,
          "--en", spec.en.replace("{id}", id), "--tw", spec.tw.replace("{id}", id)],
          { env: childEnv() });
        if (r.exitCode !== 0)
          return json({ error: "the event was not written", out: new TextDecoder().decode(r.stderr).trim() }, 500);
        return json({ ok: true, task: id, action, event: spec.type });
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
      Bun.spawn([editor, abs], { stdout: "ignore", stderr: "ignore", env: childEnv() });
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
      const r = Bun.spawnSync(["git", "-C", ROOT, "diff", `main...${branch}`], { env: childEnv() });
      if (r.exitCode !== 0) return json({ error: "no such branch" }, 404);
      return new Response(r.stdout, { headers: { "content-type": "text/plain; charset=utf-8" } });
    }

    if (url.pathname === "/" || url.pathname === "") return serveFile("index.html");
    return serveFile(url.pathname.replace(/^\//, ""));
  },
});
console.log(`board on http://127.0.0.1:${server.port}  root=${ROOT}`);
