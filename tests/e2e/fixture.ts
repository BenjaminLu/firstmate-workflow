// A board with a crew on it, built from an event log rather than from a mock
// of the server: the page under test is the real one, reading real state
// through the real endpoints. Nothing here calls a model or the network.
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, existsSync, cpSync, rmSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";

// No import.meta here: it is ESM-only and the runner transpiles to
// CommonJS. cwd is the repository root because bin/ci.sh is the only thing
// that starts this runner and it runs from there - testDir resolves
// against the config file, not cwd, so that is not what makes this true.
export const ROOT = resolve(process.cwd());
export type Stage = "working" | "gate" | "review";
export const details = {
  en: { title:'Cache the task index', explanation:'Read the index once per refresh.', before:'Each card rereads the task file', after:'One shared index per refresh', outcome:'Index choice recorded',
    options:{A:{description:'Cache per refresh',pros:'Fewer reads',cons:'Uses memory'},B:{description:'Keep individual reads',pros:'No cache',cons:'Repeated IO'},C:{description:'Measure first',pros:'Evidence before change',cons:'Delays improvement'}}},
  'zh-TW':{title:'快取任務索引',explanation:'每次重新整理只讀取一次索引。',before:'每張卡片重讀任務檔案',after:'每次重新整理共用一份索引',outcome:'已記錄索引選擇',
    options:{A:{description:'每次重新整理建立快取',pros:'減少讀取',cons:'佔用記憶體'},B:{description:'保留各自讀取',pros:'無需快取',cons:'重複讀取'},C:{description:'先測量',pros:'取得證據再變更',cons:'延後改善'}}}
};
// an agent per entry: the board's crew are agents, so a fixture that wants
// five crewmen needs five actors, not five tasks

const EVENT_FOR: Record<Stage, string> = {
  working: "dispatched", gate: "gate_failed", review: "review_opened",
};

// The task list is one file per task under design/tasks (T-090). A spec
// reads it whole and replaces it whole; the board notices either way. In
// fm_tasks' order, not readdir's or a plain sort's: file names compared as
// versions (`sort -V`), runs of digits as numbers, so T-9 comes before
// T-10, and a dotfile is not a task. makeRoot hands stages out by position,
// so a second ordering here would stage different tasks than the board lists.
const chunks = (s: string) => s.match(/\d+|\D+/g) ?? [];
export function versionCompare(a: string, b: string): number {
  const x = chunks(a), y = chunks(b);
  for (let i = 0; i < Math.min(x.length, y.length); i++) {
    const p = x[i], q = y[i];
    if (/^\d/.test(p) && /^\d/.test(q)) {
      const d = Number(p) - Number(q);
      if (d !== 0) return d;
    } else if (p !== q) return p < q ? -1 : 1;
  }
  return x.length - y.length;
}
export function readTasks(root: string): any[] {
  const dir = join(root, "design/tasks");
  if (!existsSync(dir)) return [];
  return readdirSync(dir).filter((f) => f.endsWith(".json") && !f.startsWith(".")).sort(versionCompare)
    .map((f) => JSON.parse(readFileSync(join(dir, f), "utf8")));
}
export function writeTasks(root: string, tasks: any[]) {
  const dir = join(root, "design/tasks");
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  for (const t of tasks) writeFileSync(join(dir, `${t.id}.json`), JSON.stringify(t, null, 2) + "\n");
}

export function makeRoot(stages: Stage[], withDecision = true, actors: "per-task" | "one-worker" = "per-task") {
  const d = mkdtempSync(join(tmpdir(), "fm-e2e-"));
  mkdirSync(join(d, "state/pending"), { recursive: true });
  mkdirSync(join(d, "design"), { recursive: true });
  cpSync(join(ROOT, "board"), join(d, "board"), { recursive: true });
  cpSync(join(ROOT, "i18n"), join(d, "i18n"), { recursive: true });
  cpSync(join(ROOT, "design/tasks"), join(d, "design/tasks"), { recursive: true });
  mkdirSync(join(d, 'bin'));
  // fm-config.sh is how the board reads the task list (T-090) and, with the
  // parser it loads, the project registry (T-069); without a config.yaml they
  // register nothing
  for (const f of ['fm-emit.sh','fm-diagram.sh','fm-decide.sh','watch-decisions.ts','fm-config.sh','fm-herdr.py']) cpSync(join(ROOT,'bin',f), join(d,'bin',f));

  const tasks = readTasks(ROOT);
  if (tasks.length < stages.length) {
    throw new Error(
      `the fixture wants ${stages.length} tasks and design/tasks/ has ${tasks.length}`);
  }
  const ev: string[] = [JSON.stringify({
    ts: "2026-09-21T09:00:00Z", actor: "captain", type: "greenlit",
    summary: { en: "green light", "zh-TW": "green light" },
  })];
  stages.forEach((s, i) => {
    const t = tasks[i];
    ev.push(JSON.stringify({
      ts: `2026-09-21T09:${String(i + 1).padStart(2, "0")}:00Z`,
      // "one-worker" is what a real log looks like when one agent works
      // through a queue: the crew are agents, so that is ONE crewman
      actor: actors === "one-worker" ? "worker-1"
           : s === "review" ? `reviewer-${i + 1}` : `worker-${i + 1}`,
      task: t.id, type: EVENT_FOR[s],
      summary: { en: t.title, "zh-TW": t.title },
    }));
  });
  writeFileSync(join(d, "state/events.jsonl"), ev.join("\n") + "\n");

  if (withDecision) {
    writeFileSync(join(d, "state/pending/D-1.json"), JSON.stringify({
      id: "D-1", kind: "merge", task: tasks[0].id, pr: 99,
      title: "Merge it into main", details, gates: [1, 1, 1, 1, 1, 1, 0],
    }));
    const result = spawnSync('bash', [join(d,'bin/fm-diagram.sh'),'--decision','D-1','--repo',d]);
    if (result.status !== 0) throw new Error(result.stderr.toString());
  }
  return d;
}

// A project registry naming one project, the default, on `github`. The
// repository is the test's own, never this one's, so a link to the right
// place can only come from the registry.
export function writeRegistry(root: string, github: string) {
  writeFileSync(join(root, "config.yaml"), [
    "default_project: fixture",
    "projects:",
    "  fixture:",
    "    repo: .",
    `    github: ${github}`,
    "    base: main",
    "    required_check: ci",
    "",
  ].join("\n"));
}

// the port comes from the kernel, not from a guess: a guessed port can
// collide with a leftover listener that answers /api/state, and the test
// then passes against a foreign server
async function freePort(): Promise<number> {
  const { createServer } = await import("node:net");
  return new Promise((resolve, reject) => {
    const s = createServer();
    s.once("error", reject);
    s.listen(0, "127.0.0.1", () => {
      const p = (s.address() as { port: number }).port;
      s.close(() => resolve(p));
    });
  });
}

export async function startBoard(root: string) {
  const port = await freePort();
  // the board merges by shelling out to bin/fm-merge.sh in its root, so a
  // recorder there keeps the e2e off gh without teaching the server a test
  // mode it would then be trusted with in production
  const recorder = join(root, "merge-calls");
  mkdirSync(join(root, "bin"), { recursive: true });
  const stub = join(root, "bin/fm-merge.sh");
  writeFileSync(stub, `#!/usr/bin/env bash\nprintf '%s\\n' "$*" >> "${recorder}"\necho "merged #$2"\n`);
  chmodSync(stub, 0o755);
  const proc: ChildProcess = spawn("bun", ["run", join(root, "board/server.ts")], {
    env: { ...process.env, FM_ROOT: root, FM_PORT: String(port) },
    stdio: "ignore",
  });
  const url = `http://127.0.0.1:${port}`;
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    try { if ((await fetch(`${url}/api/state`)).ok) return { url, proc, root, recorder }; }
    catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 120));
  }
  proc.kill(9);
  rmSync(root, { recursive: true, force: true });   // not only on the happy path
  throw new Error("the board did not come up");
}

export function stopBoard(b: { proc: ChildProcess; root: string }) {
  b.proc.kill(9);
  rmSync(b.root, { recursive: true, force: true });
}
