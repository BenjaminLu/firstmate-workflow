// The board. Binds loopback only, serves one page, and streams the event log.
//
//   bun run board/server.ts            0.0.0.0 is never an option here
//   FM_PORT=4173 FM_ROOT=.             the log it tails is the one the crew writes
//
// No build step and no framework: the page is a file, the stream is SSE, and
// the state endpoint is derived from events.jsonl and design/tasks/ so the
// board has no opinion the log does not already hold.
import { closeSync, constants, existsSync, fchmodSync, fstatSync, linkSync, mkdirSync, openSync, readFileSync, readdirSync, realpathSync, renameSync, statSync, unlinkSync, watch, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { homedir } from "node:os";
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
  // T-116: who it is, as separate fields the run recorded (identity.json,
  // carried on every payload as data.identity). The name of a run from
  // before them is read from its old actor once, here; its round never is,
  // since that actor's r<n> was a global counter. Unknown is null.
  name?: string | null;
  round?: number | null;
  attempt?: number | null;
  // Bounded only: done/total with a real denominator. Never a bare percent.
  progress?: { done: number; total: number } | null;
};
// A task card's crew, one chip each: never a string joined from actors.
type CrewChip = { id: string; name: string; role: Crew["role"]; round: number | null; attempt: number | null };
// What a run said about itself: the fields fm-worker.sh and fm-review.sh
// send as data.identity. Anything else is not an identity.
type Identity = { name: string | null; project: string | null; round: number | null; attempt: number | null };
const identityOf = (v: unknown): Identity | null => {
  if (!v || typeof v !== "object" || Array.isArray(v)) return null;
  const o = v as Record<string, unknown>;
  const text = (x: unknown) => typeof x === "string" && x.trim() ? x : null;
  const count = (x: unknown) => typeof x === "number" && Number.isInteger(x) && x > 0 ? x : null;
  return { name: text(o.name), project: text(o.project), round: count(o.round), attempt: count(o.attempt) };
};
// The one reading of an actor, for runs recorded before T-116 only:
// <role>-<name>-<task slug>-r<n>[<attempt mark>], as bin/fm-herdr.py's ACTOR
// reads it. An actor of another shape has no name to find.
const legacyName = (actor: string): string | null =>
  /^(?:worker|reviewer|firstmate)-(.+)-[a-z0-9]+-r[0-9]+[a-z]*$/.exec(actor)?.[1] ?? null;
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

// The lane each event gives a task (design section 8, lane derivation;
// T-118). Nothing here
// gives the captain's lane: a task is the captain's only while a card for it
// is pending, which is a fact on disk, not a point in the log. So an answered
// card leaves that lane by itself, and an approval waits in review for
// firstmate's merge card rather than at the captain's with nothing to answer.
const STAGE: Record<string, string> = {
  dispatched: "working", commit_pushed: "working", pr_opened: "review",
  gate_failed: "gate", gate_passed: "review", review_opened: "review",
  approved: "review",
  merged: "merged", closed: "closed",
  // a task whose review never happened, or whose worker died, is blocked -
  // it must not sit in a lane that says work is under way
  review_failed: "gate", worker_crashed: "gate",
};
// What a crewman is doing, which is not the same question as where its task
// sits: the one that asked the captain, or whose approval is waiting on him,
// is waiting on the captain.
const phaseOf = (type: string | undefined): CrewState | null =>
  type === "decision_requested" || type === "approved" ? "captain"
    : STAGE[type ?? ""] ? CREW_STATE(STAGE[type ?? ""]) : null;
// The one event that moves a task out of merged or closed (T-118): the
// captain's `reopened`, with a reason. Afterwards the task's lane comes from
// its later events, or from the untouched rules when there are none. Any
// other actor's, or one with no reason, is not a reopening.
const reopens = (e: Event): boolean => {
  const reason = (e.data as { reason?: unknown } | undefined)?.reason;
  return e.type === "reopened" && e.actor === "captain" && typeof reason === "string" && reason.trim() !== "";
};

// The lanes, left to right, in lifecycle order. The page reads this list
// rather than keeping its own, so the order has one source. Closed tasks are
// not a lane: they stay in the collapsed history with the merged ones.
// Backlog and ready are both untouched work, split by whether it could be
// dispatched now: backlog still waits on a dependency, ready waits on nobody.
const LANES = ["backlog", "ready", "working", "gate", "review", "captain", "merged"] as const;

// The numbers bin/fm-gate.sh gives its gates. 3 is retired (T-114), so a
// failure naming it names no gate that exists.
const GATE_NUMBERS = [1, 2, 4, 5, 6, 7];

// What the captain may do to a card, by where it sits (T-058, T-118). Any
// unfinished task can be set aside: park is reversible, drop is the closed
// event and is not, and a task with crew aboard or an open pull request asks
// first and has its crew stopped. A merged or closed task offers only
// reopening. A task parked while its card is pending stays in the captain's
// lane (the card outranks the park) and offers the parked row. POST /tasks
// refuses anything this table does not list.
const SET_ASIDE = ["park", "drop"];
const ACTIONS: Record<string, string[]> = {
  backlog: SET_ASIDE, ready: SET_ASIDE, working: SET_ASIDE, gate: SET_ASIDE,
  review: SET_ASIDE, captain: SET_ASIDE,
  parked: ["unpark", "drop"],
  merged: ["reopen"], closed: ["reopen"],
};
// the event each action writes, and the summary the log shows for it
const ACTION_EVENT: Record<string, { type: string; en: string; tw: string }> = {
  park: { type: "parked", en: "the captain parked {id}", tw: "船長擱置了 {id}" },
  unpark: { type: "unparked", en: "the captain unparked {id}", tw: "船長恢復了 {id}" },
  drop: { type: "closed", en: "the captain dropped {id}: it will not be done", tw: "船長決定不做 {id}" },
  reopen: { type: "reopened", en: "the captain reopened {id}: {reason}", tw: "船長重新開啟了 {id}：{reason}" },
};

// --- Crew liveness (T-118) --------------------------------------------------
// A crewman is aboard only while its run is alive, and the launcher side, not
// the board, says when it is not: bin/fm-herdr.py's deck reconcile checks each
// aboard actor's recorded process and gives one whose process is gone, and
// that never said agent_finished, one `agent_lost` event through fm-emit. The
// board reads that event like agent_finished for the deck, shows it once in
// the log, and blocks the task unless a later event has moved it.

// --- Card effects (T-118) ----------------------------------------------------
// What an answer does, by the one script that owns it. A card names the effect
// of each option in its details (`details.effect`, e.g. {"C":"park"}); a merge
// card, a task's or an untracked one (T-119), that names none merges on A and
// holds on B and C, as it always has -
// sending work back starts a worker, so only a card that says so does it. An
// option with no effect, and a custom answer, is recorded and nothing else.
// bin/fm-decide.sh refuses a card naming any effect not listed here.
const EFFECTS = ["merge", "hold", "park", "drop", "dispatch", "send_back"] as const;
type Effect = typeof EFFECTS[number];
// the words the decision_made summary uses, in the second language it carries
const EFFECT_TW: Record<Effect, string> = { merge: "合併", hold: "暫緩", park: "擱置", drop: "不做", dispatch: "派工", send_back: "退回重做" };
const OUTCOME_TW: Record<string, string> = { done: "已完成", failed: "失敗", recorded: "已記錄", running: "進行中" };
const effectOf = (p: Record<string, any>, chosen: string): Effect | null => {
  if (chosen === "custom") return null;
  const named = p?.details?.effect?.[chosen];
  if (typeof named === "string") return (EFFECTS as readonly string[]).includes(named) ? named as Effect : null;
  if (p?.kind === "merge" || p?.kind === "merge-untracked") return chosen === "A" ? "merge" : "hold";
  return null;
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
// guessed. A skill update's card, D-SK-<n>, is fm-decide.sh's SKILL_ID
// (T-112): fm.sh self-update raises it, fm-decide.sh --await and fm-ready.sh
// read its answer under that pattern only, and it names no owner.
// --- task grammar (T-119) ---
// The TypeScript twin of bin/fm-emit.sh's task-id grammar, the one place the
// scripts read it from; tests/board.test.sh lifts this block out and runs it
// against the shell functions over one table, so the two cannot drift. A
// task is T-<3+ digits> or SK-<3+ digits>. A branch names its task, prefix in
// either case, the hyphen after it optional, the number whole (t-117-… is
// T-117, sk-001-… is SK-001, t-1170-… is T-1170); a title leads with it and
// a colon ("T-117: …"); a pull request's task is its branch's, else its
// title's. A decision id holds a task's key, the task without its hyphen,
// and card ids have always taken T-<letters and digits> too; an owned
// decision id is D-<project>-<key>-<n>, and ownerOf reads its project, task
// and n back out of it.
//
// It is one function in plain JavaScript, with no type in it, because the
// board's page reads it too: the server puts it in front of diagram.js when
// it serves that file (GRAMMAR_JS below), so the page holds no copy of it.
function taskGrammar() {
  const TASK_ID = /^(T|SK)-[0-9]{3,}$/;
  const TASK_KEY = "T[A-Za-z0-9]{1,32}|SK[0-9]{3,}";
  const OWNED = new RegExp(`^D-([a-z0-9-]{1,24})-(${TASK_KEY})-([1-9][0-9]{0,5})$`);
  const isTask = (id) => typeof id === "string" && TASK_ID.test(id);
  const taskOfBranch = (branch) => {
    const m = /^([tT]|[sS][kK])-?([0-9]{3,})(-.*)?$/.exec(typeof branch === "string" ? branch : "");
    return m ? `${m[1].toUpperCase()}-${m[2]}` : null;
  };
  const taskOfTitle = (title) => {
    const m = /^((T|SK)-[0-9]{3,}):/.exec(typeof title === "string" ? title : "");
    return m ? m[1] : null;
  };
  const taskOfPr = (branch, title) => taskOfBranch(branch) ?? taskOfTitle(title);
  const taskKey = (id) =>
    isTask(id) ? id.replace("-", "")
      : typeof id === "string" && /^T-[A-Za-z0-9]{1,32}$/.test(id) ? `T${id.slice(2)}` : null;
  const taskOfKey = (key) => {
    const k = typeof key === "string" ? key : "";
    return /^SK[0-9]{3,}$/.test(k) ? `SK-${k.slice(2)}`
      : new RegExp(`^(?:${TASK_KEY})$`).test(k) ? `T-${k.slice(1)}` : null;
  };
  const ownerOf = (id) => {
    const m = OWNED.exec(String(id ?? ""));
    return m ? { project: m[1], task: taskOfKey(m[2]), n: Number(m[3]) } : null;
  };
  return { OWNED, isTask, taskOfBranch, taskOfTitle, taskOfPr, taskKey, taskOfKey, ownerOf };
}
const { OWNED: OWNED_DECISION, isTask, taskOfBranch, taskOfTitle, taskOfPr, taskKey, taskOfKey, ownerOf } = taskGrammar();
// --- end task grammar ---
// what the server puts in front of diagram.js: the same function, as source
const GRAMMAR_JS = `var TASK_GRAMMAR = (${taskGrammar.toString()})();\n`;
const OLD_DECISION = /^D-[0-9]{1,6}$/;
const SKILL_DECISION = /^D-SK-[0-9]{3,}$/;
const isDecisionId = (id: string) => OLD_DECISION.test(id) || OWNED_DECISION.test(id) || SKILL_DECISION.test(id);
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
  // The captain's own word: the last of parked / unparked wins. Since T-118
  // it holds for any unfinished task, in flight or not; unparking returns the
  // task to the lane its other events give it.
  const parked = new Set<string>();
  // tasks something other than a decision card has moved
  const worked = new Set<string>();
  // where in the log each task was last given a lane, and where each actor
  // last spoke: a lost crewman blocks only a task nothing has moved since
  const movedAt = new Map<string, number>();
  const spokeAt = new Map<string, number>();
  // the pull request each task opened itself, which a reopened task shows
  // again rather than one a card raised under the wrong task merged
  const opened = new Map<string, number>();
  for (const [index, e] of events.entries()) {
    const actor = String(e.actor ?? "");
    const spoke = spokeAt.get(actor) ?? -1;
    spokeAt.set(actor, index);
    if (!e.task) continue;
    const k = ek(e);
    const n = prNumber(e.pr);
    if (n) pr.set(k, n);
    if (n && e.type === "pr_opened") opened.set(k, n);
    // The captain's reopening is the one way out of merged or closed. The
    // task starts again from nothing: its later events place it, or, with
    // none, the untouched rules do. On an unfinished task it does nothing.
    if (reopens(e)) {
      if (!FINAL.has(stage.get(k) ?? "")) continue;
      stage.delete(k); moved.delete(k); movedAt.delete(k); settledAt.delete(k);
      worked.delete(k); parked.delete(k); asking.delete(k);
      const own = opened.get(k);
      if (own) pr.set(k, own); else pr.delete(k);
      continue;
    }
    if (FINAL.has(stage.get(k) ?? "")) continue;
    if (e.type === "parked") parked.add(k);
    if (e.type === "unparked") parked.delete(k);
    if (e.type === "ask_pass_criteria") asking.add(k);
    if (e.type === "criteria_returned") asking.delete(k);
    // A lost crewman blocks its task, unless the task has been given a lane
    // since the crewman last spoke - a redispatch, another round's review.
    // Kept out of STAGE: bin/fm-ready.sh replays STAGE's keys as the events
    // that take work off its ready list, and a loss never starts work.
    const s = e.type === "agent_lost" ? ((movedAt.get(k) ?? -1) <= spoke ? "gate" : undefined) : STAGE[e.type ?? ""];
    if (s) { stage.set(k, s); moved.set(k, e); movedAt.set(k, index); worked.add(k); }
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
    | { kind: "decision"; id: string; options: number | null }
    | { kind: "lost"; actor: string } | { kind: "parked" };
  const badgesOf = (id: string, at: string): Badge[] => {
    const out: Badge[] = [];
    const last = moved.get(id);
    if (at === "gate" && last?.type === "gate_failed") {
      const n = (last.data as { gate?: unknown } | undefined)?.gate;
      out.push({ kind: "gate", gate: GATE_NUMBERS.includes(n as number) ? n as number : null });
    }
    // T-118: blocked because its crewman was lost, which the card names
    if (at === "gate" && last?.type === "agent_lost") out.push({ kind: "lost", actor: String(last.actor ?? "") });
    // a pending card outranks a park, so a task parked while its card is up
    // stays in the captain's lane, and the card says it is parked
    if (at === "captain" && parked.has(id)) out.push({ kind: "parked" });
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
  // where its dependencies say without the page working that out. Since
  // T-118 any unfinished task can be parked, and unparking one in flight
  // returns it to the lane its events give it. Precedence (design section 8,
  // lane derivation): a reopening has already been folded in above; then
  // final; then a pending card; then the captain's park; then the log, where
  // a lost crewman has already blocked its task.
  const laneOf = (id: string): string => {
    const s = stageOf(id);
    if (FINAL.has(s) || s === "captain") return s;
    if (parked.has(id)) return "parked";
    if (s !== "untouched") return s;
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
    // about is not the captain's to park. Any final task can be reopened.
    // A parked task whose card is pending stays in the captain's lane, and
    // offers what a parked task offers: unpark, not a second park.
    actions: FINAL.has(at) || definitions.has(id)
      ? (ACTIONS[at === "captain" && parked.has(id) ? "parked" : at] ?? []) : [],
    // whether setting it aside asks first: crew aboard or an open pull
    // request, filled in once the crew is known below
    confirm: false,
    badges: badgesOf(id, at),
    // the aboard crew, one chip each, filled in once the crew is known below
    crew: [] as CrewChip[],
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
  const identities = new Map<string, Identity>();
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
    // T-118: a run the launcher side found lost has left the deck as surely
    // as one that finished, and an agent_finished after it changes nothing
    if (e.type === 'agent_finished' || e.type === 'agent_lost') finished.add(actor);
    // a crewman moving to another project's task of the same id has moved
    if (e.type === 'dispatched' || (e.task && (previous?.task !== e.task || projectOf(previous) !== projectOf(e)))) {
      activity.delete(actor); phases.delete(actor);
      progress.delete(actor);
      if (e.type === 'dispatched') { names.delete(actor); identities.delete(actor); }
    }
    if (typeof data.crew_name === 'string') names.set(actor, data.crew_name);
    const said = identityOf(data.identity);
    if (said) identities.set(actor, said);
    const nextProgress = bounded(data.progress);
    if (nextProgress) progress.set(actor, nextProgress);
    if (e.type === 'dispatched' || data.role) roles.set(actor, roleOf(actor,e));
    // Mid-run authored data.activity from events describes the run.
    // Scalar titles are never treated as activity.
    const description = authored(data.activity)
      || (e.type === 'dispatched' || e.type === 'review_opened' ? authored(e.summary) : null);
    if (description) activity.set(actor,description);
    // crew_status refreshes activity/progress only; it must not invent a phase.
    const phase = phaseOf(e.type);
    if (phase) phases.set(actor,e.type === 'dispatched'
      ? (roleOf(actor,e) === 'reviewer' ? 'review' : 'working')
      : phase);
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
    if (e.type === "agent_finished" || e.type === "agent_lost") lastByActor.delete(actor);
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
    const who = identities.get(actor);
    // the project the run recorded; an old run's is its events'
    const project = who?.project ?? projectOf(e);
    const t = taskAt(project, task);
    const named = names.get(actor);
    crew.push({
      id: actor,
      // stated, not guessed: the emitter writes what it is, so renaming
      // an actor cannot silently turn every reviewer into a worker
      role: roles.get(actor) || roleOf(actor, e),
      state: phases.get(actor) || 'unknown',
      task, title: t?.title ?? null,
      project: project || null,
      crew_name: named,
      // the fields the run sent; for a run that sent none, the name its old
      // actor or its crew_name gives, and a round nobody knows
      name: who?.name ?? (named && named !== actor ? named : null) ?? legacyName(actor),
      round: who?.round ?? null,
      attempt: who?.attempt ?? null,
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
      .map((c) => ({ id: c.id, name: c.name || c.crew_name || c.id, role: c.role,
        round: c.round ?? null, attempt: c.attempt ?? null }));
  }
  // bin/fm-herdr.py's deck reconcile follows each agent_lost with the
  // agent_finished (`data.status: process_gone`) that has always closed a
  // vanished run; the log shows the loss and not that close as well
  const closesLoss = new Set<Event>();
  const lostLast = new Set<string>();
  for (const e of events) {
    const actor = String(e.actor ?? "");
    if (e.type === "agent_finished" && lostLast.has(actor)
      && (e.data as { status?: unknown } | undefined)?.status === "process_gone") closesLoss.add(e);
    if (e.type === "agent_lost") lostLast.add(actor); else lostLast.delete(actor);
  }
  // setting aside a task with crew aboard or an open pull request asks first
  // and stops that crew; the pull request is left open
  for (const t of tasks) t.confirm = t.crew.length > 0 || (t.pr !== null && !FINAL.has(t.stage));

  // A refused merge stops being news once the same task or pull request is
  // merged afterwards - by a later answer on the board or any other way. The
  // record keeps what happened; the flag says it has been overtaken. Both
  // are keyed by project: another project's merge of its T-001 is not this.
  const mergedEvents = events.filter((e) => e.type === "merged");
  // An answer whose effect failed stays up, with its reason, until what it
  // asked for has happened some other way: the task parked, closed or
  // dispatched after the answer. A merge's failure is the refusal below.
  const EFFECT_EVENT: Record<string, string> = { park: "parked", drop: "closed", dispatch: "dispatched", send_back: "dispatched" };
  const reviewed = responses.map((d: Record<string, any>) => {
    const merge = mergeOf(d);
    const overtaken = d.effect_outcome === "failed" && EFFECT_EVENT[d.effect] !== undefined
      && events.some((e) => e.type === EFFECT_EVENT[d.effect] && e.task != null && String(e.task) === String(d.task)
        && projectOf(e) === projectOf(d) && later(e.ts, d.ts));
    const shown = { ...d, merge, ...(merge === "running" ? { merge_unknown: unknownOutcome.has(String(d.id)) } : {}),
      ...(d.effect_outcome === "failed" ? { effect_superseded: overtaken } : {}) };
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
    // a lost run shows once: its agent_lost, not also the agent_finished the
    // deck reconcile closes it with
    recent: events.filter((e) => mine(e) && !closesLoss.has(e)).slice(-40).reverse().map(linked),
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
  const logged = readEvents();
  const terminal = logged.filter((e) => e.type === "merged" || e.type === "closed");
  // (project, pr) and (project, task) are the keys: another project's merged
  // #7 does not settle this project's card for #7. Naming none is the default's.
  const def = defaultProject();
  const within = (p: unknown, k: unknown) => `${typeof p === "string" && p ? p : def}\u0000${String(k ?? "")}`;
  const settled = new Set(
    terminal
      .filter((e) => e.type === "merged" || e.type === "closed")
      .map((e) => within((e as Record<string, unknown>).project, (e as Record<string, unknown>).pr)),
  );
  // A card whose task is merged or closed is shown, never hidden (T-118): a
  // card raised under the wrong task - the merge card for #96 filed under
  // T-117 - must stay where the captain can see it. It says the task is final.
  // The same reading as the board's lanes: the first merged or closed makes a
  // task final, and only the captain's reopening undoes it.
  const finalTasks = new Map<string, string>();
  for (const e of logged) {
    if (!e.task) continue;
    const k = within((e as Record<string, unknown>).project, e.task);
    if (reopens(e)) finalTasks.delete(k);
    else if ((e.type === "merged" || e.type === "closed") && !finalTasks.has(k)) finalTasks.set(k, e.type);
  }
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
      const final = d.task != null ? finalTasks.get(within(d.project, d.task)) ?? null : null;
      // answerable: POST /decisions takes this id; a card under any other
      // name is listed, and the page shows the refusal when it is answered
      return [{ card: { ...d, owner: ownerOf(d.id), answerable: isDecisionId(String(d.id ?? "")), task_final: final }, at: asked(d, f) }];
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
    rewrite(file, { ...d, merge, ...(merge === "failed" ? { merge_reason: reason } : {}), merge_settled: new Date().toISOString(),
      // the answer's effect was the merge, and this is how it ended
      ...(d.effect === "merge" ? { effect_outcome: merge === "merged" ? "done" : "failed", effect_reason: reason } : {}) });
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
const startMerge = (id: string, project: string, pr: number, task: string | null, onProject: string[], untracked = false) => {
  mkdirSync(MERGING, { recursive: true });
  const log = join(MERGING, `${project || "_default"}.out`);
  let child;
  try {
    const fd = openSync(log, "w");
    try {
      child = spawn(join(ROOT, "bin/fm-merge.sh"),
        ["--pr", String(pr), ...(untracked ? ["--untracked"] : task ? ["--task", task] : []), ...onProject, "--repo", ROOT],
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
// --- Setting a task aside, and what an answer does (T-118) -----------------
const decode = (b: Uint8Array | undefined) => new TextDecoder().decode(b ?? new Uint8Array()).trim();
const lastLine = (s: string) => s.split("\n").filter((l) => l.trim()).pop() ?? "";
// one captain event through the one writer of the log
const emitCaptain = (args: string[]): { ok: boolean; error: string } => {
  try {
    const r = Bun.spawnSync([join(ROOT, "bin/fm-emit.sh"), "--actor", "captain", ...args], { env: childEnv(), stdin: "ignore" });
    return { ok: r.exitCode === 0, error: r.exitCode === 0 ? "" : lastLine(decode(r.stderr)) || `fm-emit.sh exited ${r.exitCode}` };
  } catch { return { ok: false, error: "fm-emit.sh could not be started" }; }
};
const onProjectOf = (project: string) => project && project !== defaultProject() ? ["--project", project] : [];
// what ps says a process is running, or "" once it is gone
const commandOf = (pid: number): string => {
  try {
    const r = Bun.spawnSync(["ps", "-o", "command=", "-p", String(pid)], { stdin: "ignore", env: childEnv() });
    return r.exitCode === 0 ? decode(r.stdout) : "";
  } catch { return ""; }
};
// Stop every crewman on a task, by the stop path main has (T-107's `fm.sh
// stop` has not merged): SIGTERM to the round's own script - bin/fm-worker.sh
// publishes its pid at state/worktrees/<task>.pid, and its TERM trap saves and
// pushes the worktree before it exits - to every run's script named in its
// process.json, and to each vendor CLI its attempts' execution.json name. A pid
// is signalled only while ps still shows the program it was recorded for, so
// a pid the system has since handed to someone else is left alone. The pull
// request is never touched.
const SAFE_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const stopCrew = (project: string, task: string): { stopped: string[]; failed: string[] } => {
  const out = { stopped: [] as string[], failed: [] as string[] }, done = new Set<number>();
  const signal = (label: string, pid: unknown, token: unknown) => {
    if (typeof pid !== "number" || !Number.isSafeInteger(pid) || pid <= 1 || done.has(pid)) return;
    if (typeof token !== "string" || !token) return;
    const cmd = commandOf(pid);
    if (!cmd || !cmd.includes(token)) return;   // gone, or no longer ours
    done.add(pid);
    try { process.kill(pid, "SIGTERM"); out.stopped.push(label); }
    catch (e) { out.failed.push(`${label}: ${(e as { code?: string }).code ?? "not stopped"}`); }
  };
  if (!SAFE_NAME.test(task)) return out;
  const pidfile = join(ROOT, "state/worktrees", `${task}.pid`);
  try {
    const pid = Number(readFileSync(pidfile, "utf8").trim());
    signal(`worker ${pid}`, pid, "fm-worker.sh");
  } catch { /* no worker published */ }
  const runs = join(ROOT, "state/runs");
  let names: string[] = [];
  try { names = readdirSync(runs).filter((n) => SAFE_NAME.test(n)); } catch { /* no runs */ }
  for (const actor of names) {
    const who = readJson<Record<string, unknown>>(join(runs, actor, "identity.json"));
    if (!who || who.task !== task) continue;
    if ((typeof who.project === "string" && who.project ? who.project : defaultProject()) !== project) continue;
    // each attempt's vendor CLI, as bin/fm-herdr.py recorded it on launch
    let attempts: string[] = [];
    try { attempts = readdirSync(join(runs, actor)).filter((n) => SAFE_NAME.test(n)); } catch { /* none */ }
    for (const a of attempts) {
      const cli = readJson<Record<string, unknown>>(join(runs, actor, a, "execution.json"));
      if (cli?.started === true) signal(`${actor} ${cli.pid}`, cli.pid, cli.token);
    }
    const proc = readJson<Record<string, unknown>>(join(runs, actor, "process.json"));
    if (proc) signal(`${actor} ${proc.pid}`, proc.pid, proc.token);
  }
  return out;
};
type Carried = { outcome: "done" | "failed" | "recorded" | "running"; reason: string; stopped?: string[] };
// park or drop: the parked or closed event, then the crew stopped. The event
// first, so a crewman that dies saying something cannot move the task back.
const setAside = (project: string, task: string, action: "park" | "drop", decision: string | null): Carried => {
  const spec = ACTION_EVENT[action];
  const via = decision ? { en: ` (${decision})`, tw: `（${decision}）` } : { en: "", tw: "" };
  const r = emitCaptain(["--type", spec.type, "--task", task, ...onProjectOf(project),
    ...(decision ? ["--data", JSON.stringify({ decision })] : []),
    "--en", spec.en.replace("{id}", task) + via.en, "--tw", spec.tw.replace("{id}", task) + via.tw]);
  if (!r.ok) return { outcome: "failed", reason: `the ${spec.type} event was not written: ${r.error}` };
  const stop = stopCrew(project, task);
  if (stop.failed.length) return { outcome: "failed", reason: `${spec.type}, but crew not stopped: ${stop.failed.join("; ")}`, stopped: stop.stopped };
  return { outcome: "done", reason: "", stopped: stop.stopped };
};
// dispatch: bin/fm-dispatch.sh --task, the captain's order, which still holds
// the task for greenlit, dependencies, park, drop and the concurrency limit
// and says which held it. It prints the id of a task it started. Awaited,
// not spawnSync: a slow dispatcher must not freeze the rest of the board.
const dispatchTask = async (project: string, task: string): Promise<Carried> => {
  try {
    const child = Bun.spawn([join(ROOT, "bin/fm-dispatch.sh"), "--task", task, "--repo", ROOT],
      { env: { ...childEnv(), ...(project && project !== defaultProject() ? { FM_PROJECT: project } : {}) },
        stdin: "ignore", stdout: "pipe", stderr: "pipe", cwd: ROOT });
    const timer = setTimeout(() => child.kill(), 60_000);
    const [out, err, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    clearTimeout(timer);
    if (code === 0 && out.split("\n").includes(task)) return { outcome: "done", reason: "" };
    return { outcome: "failed", reason: lastLine(err) || lastLine(out) || `fm-dispatch.sh exited ${code}` };
  } catch { return { outcome: "failed", reason: "fm-dispatch.sh could not be started" }; }
};
// send back: another worker round on the same branch and pull request, by
// bin/fm-worker.sh, which holds the task's own lock, so a second round on top
// of a running one refuses rather than doubling up. It runs detached; a round
// that refuses within the first seconds is reported with what it said.
const sendBack = async (project: string, task: string, pr: number | null): Promise<Carried> => {
  if (!SAFE_NAME.test(task)) return { outcome: "failed", reason: "no task to send back" };
  const dir = join(ROOT, "state/dispatch");
  mkdirSync(dir, { recursive: true });
  const log = join(dir, `${task}.log`);
  let child;
  try {
    const fd = openSync(log, "a");
    try {
      child = spawn(join(ROOT, "bin/fm-worker.sh"), ["--task", task, "--repo", ROOT, ...(pr ? ["--pr", String(pr)] : [])],
        { detached: true, stdio: ["ignore", fd, fd], env: { ...childEnv(), ...(project && project !== defaultProject() ? { FM_PROJECT: project } : {}) } });
    } finally { closeSync(fd); }
  } catch { return { outcome: "failed", reason: "fm-worker.sh could not be started" }; }
  const exited = await new Promise<number | null | "running">((settled) => {
    const timer = setTimeout(() => settled("running"), 3000);
    child.on("error", () => { clearTimeout(timer); settled(127); });
    child.on("exit", (code) => { clearTimeout(timer); settled(code); });
  });
  child.unref();
  if (exited === "running" || exited === 0) return { outcome: "done", reason: "" };
  let said = "";
  try { said = lastLine(readFileSync(log, "utf8")); } catch { /* none */ }
  return { outcome: "failed", reason: (said || `fm-worker.sh exited ${exited ?? "on a signal"}`).slice(0, 500) };
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

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });

// --- Who may write (design section 8, the board's trust boundary; T-122) ---
// The board binds loopback, and on macOS the OS sandbox cannot keep a crew
// round off one loopback port while leaving it the others, so every route
// that writes or starts a program asks for a credential no crew round and no
// other web page can read or fetch. It is a secret of 256 random bits in a
// file of the operator's own, outside the repository, made once and kept
// across restarts: `<config>/firstmate/board-<port>.secret`, mode 0600, where
// <config> is $XDG_CONFIG_HOME when that is an absolute path and ~/.config
// otherwise. Nothing the board sends, logs or emits carries it.
//   - the captain's tab holds a token derived from it, given once in exchange
//     for a one-time code (/login) the opener derives from it, and kept in
//     that tab's sessionStorage;
//   - a script on the operator's machine sends the secret itself.
// Both go as `Authorization: Bearer`, which a browser never adds on its own.
// There is no cookie: a browser sends a cookie for 127.0.0.1 to every port on
// it, so any loopback server the captain's browser visits would receive it.
// Either way the request also carries the board's own Origin and a JSON body,
// so no form and no page of another origin gets through.
const CONFIG_DIR = join((() => {
  const x = process.env.XDG_CONFIG_HOME ?? "";
  return x.startsWith("/") ? x : join(homedir(), ".config");
})(), "firstmate");
const secretFile = (port: number) => join(CONFIG_DIR, `board-${port}.secret`);
// Made only when missing, through a link from a file written whole, so a
// board that dies half way never leaves an empty secret behind. One that is
// there is read through a descriptor that refuses a symlink, and must be the
// operator's own regular file holding 64 hex digits or more.
const loadSecret = (port: number): string => {
  mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
  const dir = realpathSync(CONFIG_DIR);
  if (dir === ROOT || dir.startsWith(ROOT + "/"))
    throw new Error("the board's secret must live outside the repository; set XDG_CONFIG_HOME elsewhere");
  const file = secretFile(port);
  if (!existsSync(file)) {
    const temporary = join(CONFIG_DIR, `.board-${port}.${crypto.randomUUID()}.tmp`);
    writeFileSync(temporary, randomBytes(32).toString("hex") + "\n", { flag: "wx", mode: 0o600 });
    try { linkSync(temporary, file); } catch (e) { if ((e as { code?: string }).code !== "EEXIST") throw e; }
    finally { unlinkSync(temporary); }
  }
  const fd = openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const st = fstatSync(fd);
    if (!st.isFile() || st.uid !== process.getuid?.()) throw new Error("the secret file is not the operator's own regular file");
    if (st.mode & 0o077) fchmodSync(fd, 0o600);
    const secret = readFileSync(fd, "utf8").trim();
    if (!/^[0-9a-f]{64,}$/.test(secret)) throw new Error("the secret file holds no secret; remove it and restart the board");
    return secret;
  } finally { closeSync(fd); }
};
// set once the port is known, before the first request is served
let SECRET = "", ORIGINS: string[] = [], STARTED = 0;
const mac = (message: string) => createHmac("sha256", SECRET).update(message).digest("hex");
const same = (a: string, b: string) => {
  const x = Buffer.from(a), y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
};
// The tab's token: derived from the secret and the board's origin, so it
// outlives a board restart exactly as long as the secret does. Removing the
// secret file and restarting the board revokes every token at once.
const sessionToken = () => mac(`session:${ORIGINS[0]}`);
// The secret (a script) or the tab's token (the captain's page). A cookie is
// never read: what a browser volunteers says nothing about who is asking.
const mayWrite = (req: Request) => {
  const m = /^Bearer ([^\s]+)$/.exec(req.headers.get("authorization") ?? "");
  return m !== null && (same(m[1], SECRET) || same(m[1], sessionToken()));
};
// A one-time code: <issued ms>.<nonce>.<mac>, the mac over the board's origin,
// the time and the nonce. Good for 60 seconds from its issue, never for one
// issued before this board started, and once: a used nonce is kept until its
// code would have expired anyway. FM_BOARD_CODE_TTL_MS can shorten the 60
// seconds, never lengthen them, so a test can see expiry on its own.
const CODE_TTL = Math.min(60_000, Number(process.env.FM_BOARD_CODE_TTL_MS) || 60_000);
const usedCodes = new Map<string, number>();
const redeem = (code: unknown): boolean => {
  const m = /^([0-9]{13})\.([0-9a-f]{32})\.([0-9a-f]{64})$/.exec(typeof code === "string" ? code : "");
  if (!m) return false;
  const issued = Number(m[1]), now = Date.now();
  for (const [n, until] of usedCodes) if (until < now) usedCodes.delete(n);
  if (!same(m[3], mac(`login:${ORIGINS[0]}:${m[1]}.${m[2]}`))) return false;
  if (issued < STARTED || issued > now + 2_000 || now - issued > CODE_TTL || usedCodes.has(m[2])) return false;
  usedCodes.set(m[2], issued + CODE_TTL);
  return true;
};
// Every refusal is 403 with a code the page translates; nothing is written.
const refuse = (code: string, error: string) => json({ error, code }, 403);
const isJson = (req: Request) => /^application\/json\s*(;|$)/i.test(req.headers.get("content-type") ?? "");
const writeRefusal = (req: Request): Response | null => {
  if (!mayWrite(req)) return refuse("writeCredential", "this board is read-only without the captain's credential");
  if (!ORIGINS.includes(req.headers.get("origin") ?? "")) return refuse("writeOrigin", "not from the board's own page");
  if (!isJson(req)) return refuse("writeJson", "json only");
  return null;
};
// The page that takes the one-time code out of the address, trades it for the
// tab's token, keeps that in this tab's sessionStorage (one origin, port
// included, one tab) and replaces itself, so the code stays in neither the
// address bar nor the history. It holds nothing of its own.
const LOGIN_PAGE = `<!doctype html><meta charset="utf-8"><title>firstmate</title><script>
(async () => {
  const code = location.hash.slice(1) || new URLSearchParams(location.search).get("code") || "";
  history.replaceState(null, "", "/login");
  const r = await fetch("/login", { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ code }) }).then(x => x.ok ? x.json() : null).catch(() => null);
  if (r && typeof r.token === "string") sessionStorage.setItem("board.token", r.token);
  location.replace("/");
})();
</script>`;

const serveFile = (name: string) => {
  const p = join(PUBLIC, name);
  if (!p.startsWith(PUBLIC + "/") || !existsSync(p)) return new Response("not found", { status: 404 });
  // the real file, not wherever a link in the tree points
  const real = realpathSync(p), pub = realpathSync(PUBLIC);
  if (!real.startsWith(pub + "/") || !statSync(real).isFile()) return new Response("not found", { status: 404 });
  const type = name.endsWith(".css") ? "text/css"
    : name.endsWith(".js") ? "text/javascript" : "text/html; charset=utf-8";
  return new Response(readFileSync(real), { headers: { "content-type": type } });
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

    // whether this tab may write: the page disables its controls and says so
    // when it may not. A yes or a no, never the credential.
    if (url.pathname === "/api/session") return json({ writable: mayWrite(req) });

    // The captain's tab gets in once, through the one-time address the opener
    // made (bin/fm-herdr.py board_login_url). The code is traded here for the
    // tab's token, in the body and never as a cookie; a wrong, used or expired
    // one changes nothing.
    if (url.pathname === "/login" && req.method === "POST") {
      if (!ORIGINS.includes(req.headers.get("origin") ?? "")) return refuse("writeOrigin", "not from the board's own page");
      if (!isJson(req)) return refuse("writeJson", "json only");
      return req.json().then((body: any) => redeem(body?.code)
        ? json({ ok: true, token: sessionToken() }, 200, { "cache-control": "no-store" })
        : refuse("loginRefused", "that code is wrong, used or expired"))
        .catch(() => refuse("loginRefused", "that code is wrong, used or expired"));
    }
    if (url.pathname === "/login") {
      return new Response(LOGIN_PAGE, { headers: { "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store", "referrer-policy": "no-referrer" } });
    }

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
      const refused = writeRefusal(req);
      if (refused) return refused;
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
        // A merge card is its task's, or belongs to no task (T-119): an
        // untracked card merges its pull request with --untracked and hands
        // fm-merge.sh no task, whatever its file says; a task's card hands
        // only a task the grammar holds, and fm-merge.sh refuses it unless
        // the pull request is that task's. What the answer does (T-118) is
        // carried out below by the script that owns it.
        const untracked = p.kind === "merge-untracked";
        const effect = effectOf(p, chosen);
        const merging = effect === "merge" && (p.kind === "merge" || untracked) && prNumber(p.pr) !== null && typeof p.pr === "number";
        const mergeTask = untracked ? null : taskKey(p.task) !== null ? String(p.task) : null;
        if (merging && !untracked && p.task != null && mergeTask === null)
          return json({ error: "a merge card names a task id", task: String(p.task) }, 409);
        // One merge at a time within a project. Refused before anything is
        // published or emitted, so the card stays pending as it was; nothing
        // awaits before the record below is created, so no second answer can
        // slip in between, and one that comes later finds the record.
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
          // the effect the answer carries, and until it is carried out, running
          effect,
          effect_outcome: effect ? "running" : "recorded",
        };
        // Exclusive creation makes repeated requests unable to rerun a merge,
        // or any other effect.
        const temporary = join(dir, `.${id}.${crypto.randomUUID()}.tmp`);
        writeFileSync(temporary, JSON.stringify(decision) + "\n", { flag: "wx" });
        try { linkSync(temporary, file); } finally { unlinkSync(temporary); }
        // Carried out now, by the one script that owns each effect, and never
        // silently: the outcome is done, failed with its reason, or recorded
        // for an option with no effect. A merge runs in the background and
        // its record says how it ended.
        const cardProject = projectOf(p);
        const task = typeof p.task === "string" && p.task ? p.task : null;
        let carried: Carried = { outcome: "recorded", reason: "" };
        if (effect === "merge") carried = merging ? { outcome: "running", reason: "" }
          : { outcome: "failed", reason: "a merge needs a merge card with a pull request" };
        else if (effect === "hold") carried = { outcome: "done", reason: "" };
        else if (effect && !task) carried = { outcome: "failed", reason: "the card names no task" };
        else if (effect === "park" || effect === "drop") {
          const now = state().tasks.find((x) => x.id === task && (x.project ?? "") === cardProject);
          carried = now?.stage === "merged" || (now?.stage === "closed" && effect === "park")
            ? { outcome: "failed", reason: `${task} is already ${now.stage}` }
            : now?.stage === (effect === "park" ? "parked" : "closed") ? { outcome: "done", reason: `${task} was already ${now.stage}` }
            : setAside(cardProject, task!, effect, id);
        }
        else if (effect === "dispatch") carried = await dispatchTask(cardProject, task!);
        else if (effect === "send_back") carried = await sendBack(cardProject, task!, prNumber(p.pr));
        if (effect && effect !== "merge") {
          const now = readJson<Record<string, unknown>>(file) ?? decision;
          rewrite(file, { ...now, effect_outcome: carried.outcome, effect_reason: carried.reason,
            ...(carried.stopped ? { stopped: carried.stopped } : {}) });
        }
        let eventRecorded = false;
        const said = effect
          ? { en: `${id}: ${chosen}, ${effect.replace("_", " ")} ${carried.outcome}${carried.reason ? `: ${carried.reason}` : ""}`,
              tw: `${id}：${chosen}，${EFFECT_TW[effect]}${OUTCOME_TW[carried.outcome]}${carried.reason ? `：${carried.reason}` : ""}` }
          : { en: `${id} recorded ${chosen}`, tw: `${id} 已記錄 ${chosen}` };
        try {
          const emitted = Bun.spawnSync([join(ROOT, "bin/fm-emit.sh"),
          "--actor", "captain", "--type", "decision_made",
          ...(p.task ? ["--task", p.task] : []), ...onProject,
          "--data", JSON.stringify({ decision: id, chosen, outcome: carried.outcome,
            ...(effect ? { effect } : {}), ...(carried.reason ? { reason: carried.reason } : {}) }),
          "--en", said.en, "--tw", said.tw],
          { env: childEnv() });
          eventRecorded = emitted.exitCode === 0;
        } catch { /* the durable decision still exists; report the event failure */ }

        // the helper runs in the background; the answer does not wait for it
        if (merging) startMerge(id, projectOf(p), p.pr, mergeTask, onProject, untracked);
        const pf = join(ROOT, "state/pending", `${id}.json`);
        if (existsSync(pf)) unlinkSync(pf);
        const stored = readJson<Record<string, unknown>>(file) ?? decision;
        return json({ ok: true, decision: stored, merge: mergeOf(stored), eventRecorded,
          effect, outcome: carried.outcome, ...(carried.reason ? { reason: carried.reason } : {}) });
      }).catch(() => json({ error: "bad request" }, 400));
    }

    // The captain parks, unparks or drops a task (T-058). Written as a captain
    // event through fm-emit.sh like every other board write; the plan in
    // design/tasks/ is never touched. The check and the write run with
    // nothing in between - spawnSync holds the only thread - so two clicks
    // cannot both pass the check. Declared JSON only, like every write: a
    // cross-site form can post text/plain without asking first.
    if (url.pathname === "/tasks" && req.method === "POST") {
      const refused = writeRefusal(req);
      if (refused) return refused;
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
        // T-118: a task with crew aboard or an open pull request is set aside
        // only once the captain has confirmed it, and a reopening always asks
        const confirmed = body?.confirm === true;
        if ((action === "reopen" || ((action === "park" || action === "drop") && task.confirm)) && !confirmed)
          return json({ error: `confirm before you ${action} ${id}`, code: "confirmRequired",
            crew: task.crew.map((c) => c.id), pr: task.pr }, 409);
        if (action === "reopen") {
          const reason = typeof body?.reason === "string" ? body.reason.trim() : "";
          if (!reason || [...reason].length > 500 || /[\u0000-\u001f\u007f-\u009f\ud800-\udfff]/u.test(reason))
            return json({ error: "reopening needs a reason", code: "reopenNeedsReason" }, 400);
          const r = emitCaptain(["--type", "reopened", "--task", id, ...onProjectOf(project),
            "--data", JSON.stringify({ reason, from: task.stage }),
            // functions, not strings: a `$&` in the reason is text, not a pattern
            "--en", spec.en.replace("{id}", () => id).replace("{reason}", () => reason),
            "--tw", spec.tw.replace("{id}", () => id).replace("{reason}", () => reason)]);
          if (!r.ok) return json({ error: "the event was not written", out: r.error }, 500);
          return json({ ok: true, task: id, action, event: spec.type });
        }
        if (action === "park" || action === "drop") {
          // the event, then the crew stopped; the pull request is left open
          const r = setAside(project, id, action, null);
          if (r.outcome !== "done" && !r.stopped)
            return json({ error: "the event was not written", out: r.reason }, 500);
          return json({ ok: r.outcome === "done", task: id, action, event: spec.type,
            stopped: r.stopped ?? [], pr_left_open: task.pr, ...(r.outcome === "done" ? {} : { error: r.reason }) },
            r.outcome === "done" ? 200 : 500);
        }
        const r = emitCaptain(["--type", spec.type, "--task", id, ...onProjectOf(project),
          "--en", spec.en.replace("{id}", id), "--tw", spec.tw.replace("{id}", id)]);
        if (!r.ok) return json({ error: "the event was not written", out: r.error }, 500);
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

    // Starting a program is a write: POST with the credential, the path in a
    // JSON body. A GET, which any link or image can make, starts nothing.
    if (url.pathname === "/open") {
      if (req.method !== "POST") return json({ error: "POST only" }, 405, { allow: "POST" });
      const refused = writeRefusal(req);
      if (refused) return refused;
      if (!localOnly(req)) return json({ error: "localhost only" }, 403);
      return req.json().then((body: any) => {
        const abs = inside(typeof body?.path === "string" ? body.path : "");
        if (!abs) return json({ error: "outside the repository" }, 403);
        const editor = (readFileSync(join(ROOT, "config.yaml"), "utf8")
          .match(/^editor:\s*([^\s#]+)/m)?.[1] ?? "code");
        Bun.spawn([editor, abs], { stdout: "ignore", stderr: "ignore", env: childEnv() });
        return json({ ok: true, opened: abs, editor });
      }).catch(() => json({ error: "bad request" }, 400));
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
    // diagram.js reads owned decision ids through the task grammar, which it
    // gets here, in front of the file, and holds no copy of (T-119)
    if (url.pathname === "/diagram.js") {
      const f = serveFile("diagram.js");
      return f.ok ? f.text().then((s) => new Response(GRAMMAR_JS + s, { headers: f.headers })) : f;
    }
    return serveFile(url.pathname.replace(/^\//, ""));
  },
});
// The credential is keyed by the port, which FM_PORT=0 learns only now. No
// request is served before this runs: it is the same synchronous turn.
try {
  SECRET = loadSecret(server.port);
  ORIGINS = [`http://127.0.0.1:${server.port}`, `http://localhost:${server.port}`];
  STARTED = Date.now();
} catch (e) {
  // the log is under state/, so it names neither the secret nor its path
  const code = (e as { code?: string }).code;
  console.error(`board refused to start: ${code ? `the secret file could not be used (${code})` : (e as Error).message}`);
  server.stop(true);
  process.exit(1);
}
console.log(`board on http://127.0.0.1:${server.port}  root=${ROOT}`);
