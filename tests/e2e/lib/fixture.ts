// A board with a crew on it, built from an event log rather than from a mock
// of the server: the page under test is the real one, reading real state
// through the real endpoints. Nothing here calls a model or the network.
import { appendFileSync, mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, existsSync, cpSync, rmSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHmac, randomUUID } from "node:crypto";
import { test as base, type Page } from "@playwright/test";

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

// CI builds before starting Playwright. Direct e2e invocations can locate that
// output, or build in an isolated copy so parallel workers never share scratch.
let voyageBundle: string | undefined;
let captainSprite: Buffer;
function liveBundle(): string {
  if (voyageBundle !== undefined) return voyageBundle;
  const artifact=join(ROOT,'board/public/voyage2d/index.html');
  if (existsSync(artifact) && existsSync(join(ROOT,'board/public/voyage2d/captain.webp'))) {
    captainSprite=readFileSync(join(ROOT,'board/public/voyage2d/captain.webp'));
    return voyageBundle=readFileSync(artifact,'utf8');
  }
  const buildRoot=mkdtempSync(join(tmpdir(),'fm-voyage-build-'));
  try {
    cpSync(join(ROOT,'games/voyage-2d'),join(buildRoot,'games/voyage-2d'),{
      recursive:true, filter:source=>!['node_modules','build','__pycache__'].includes(basename(source)),
    });
    const result=spawnSync('bash',[join(buildRoot,'games/voyage-2d/tools/prepare-board.sh'),buildRoot],{encoding:'utf8'});
    if(result.status!==0) throw new Error(`Live bundle build failed: ${result.stderr} ${result.stdout}`);
    captainSprite=readFileSync(join(buildRoot,'board/public/voyage2d/captain.webp'));
    return voyageBundle=readFileSync(join(buildRoot,'board/public/voyage2d/index.html'),'utf8');
  } finally {rmSync(buildRoot,{recursive:true,force:true});}
}

export function makeRoot(stages: Stage[], withDecision = true, actors: "per-task" | "one-worker" = "per-task") {
  const bundle=liveBundle();
  const d = mkdtempSync(join(tmpdir(), "fm-e2e-"));
  mkdirSync(join(d, "state/pending"), { recursive: true });
  mkdirSync(join(d, "design"), { recursive: true });
  cpSync(join(ROOT, "board"), join(d, "board"), { recursive: true });
  mkdirSync(join(d,"board/public/voyage2d"),{recursive:true});
  writeFileSync(join(d,"board/public/voyage2d/index.html"),bundle);
  writeFileSync(join(d,"board/public/voyage2d/captain.webp"),captainSprite);
  cpSync(join(ROOT, "i18n"), join(d, "i18n"), { recursive: true });
  cpSync(join(ROOT, "design/tasks"), join(d, "design/tasks"), { recursive: true });
  mkdirSync(join(d, 'bin'));
  // fm-config.sh is how the board reads the task list (T-090) and, with the
  // parser it loads, the project registry (T-069); without a config.yaml they
  // register nothing
  for (const f of ['fm-emit.sh','fm-diagram.sh','fm-decide.sh','fm-config.sh','fm-herdr.py']) cpSync(join(ROOT,'bin',f), join(d,'bin',f));
  // the lifeline every merge the board starts runs under (T-151), and
  // the extracted config helpers: the board reads the watch's files under
  // state/watch itself (T-137) and runs none of bin/lib's watch or hook code
  mkdirSync(join(d, 'bin/lib'));
  for (const f of ['fm_gates.json', 'fm_binding.py', 'fm_evidence.py', 'fm_spec_preflight.py', 'fm_ste.py', 'fm_lifeline.py', 'fm-lifeline.sh', 'fm_project_paths.py', 'fm_registry.py', 'fm_config_values.py', 'fm_config_tasks.py', 'fm_config_runtime.py']) cpSync(join(ROOT, 'bin/lib', f), join(d, 'bin/lib', f));

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
      title: "Merge it into main", details, gates: {branch: true, rebase: true, scope: true, 'fail-first': true, ci: true, approval: false},
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

// A registry of several projects (T-054). The first hosts itself and is the
// default; the rest are targets, each with its task list at the registry's
// default place, projects/<name>/tasks/, one file per task (T-090), when the
// test gives one.
export function writeProjects(root: string, projects: Array<{ name: string; github: string; tasks?: Array<{ id: string }> }>) {
  const home = mkdtempSync(join(tmpdir(), 'fm-e2e-home-'));
  writeFileSync(join(root, '.fixture-fm-home'), home);
  const lines = [`home: ${home}`, `default_project: ${projects[0].name}`, "projects:"];
  projects.forEach((p, i) => {
    lines.push(`  ${p.name}:`, ...(i === 0 ? ["    repo: ."] : []), `    github: ${p.github}`,
      "    base: main", "    required_check: ci");
    if (i > 0 && p.tasks) {
      const dir = join(home, "projects", p.name, "tasks");
      mkdirSync(dir, { recursive: true });
      for (const t of p.tasks) writeFileSync(join(dir, `${t.id}.json`), JSON.stringify(t) + "\n");
    }
  });
  writeFileSync(join(root, "config.yaml"), lines.join("\n") + "\n");
}

export function projectState(root: string, project: string) {
  const config = readFileSync(join(root, 'config.yaml'), 'utf8');
  const def = /^default_project: (.+)$/m.exec(config)?.[1];
  const dir = project === def ? join(root, 'state')
    : join(readFileSync(join(root, '.fixture-fm-home'), 'utf8'), 'projects', project, 'state');
  mkdirSync(join(dir, 'pending'), {recursive:true});
  mkdirSync(join(dir, 'decisions'), {recursive:true});
  return dir;
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

// `env` is added to the board's environment, for a test that stands a stub in
// for gh (FM_GH) or starts the board from a shell that exports FM_PROJECT
export async function startBoard(root: string, env: Record<string, string> = {}, configuredPort = false) {
  const port = await freePort();
  if (configuredPort) appendFileSync(join(root, "config.yaml"), `\nboard:\n  port: ${port}\n`);
  // the board merges by shelling out to bin/fm-merge.sh in its root, so a
  // recorder there keeps the e2e off gh without teaching the server a test
  // mode it would then be trusted with in production. A merge runs in the
  // background (T-054); while `hold-merge` exists the recorder keeps it
  // running, so a test can see a merge that has not finished.
  const recorder = join(root, "merge-calls");
  mkdirSync(join(root, "bin"), { recursive: true });
  const stub = join(root, "bin/fm-merge.sh");
  writeFileSync(stub, `#!/usr/bin/env bash\nprintf '%s\\n' "$*" >> "${recorder}"\n` +
    `while [ -e "${join(root, "hold-merge")}" ]; do sleep 0.1; done\necho "merged #$2"\n`);
  chmodSync(stub, 0o755);
  // T-122: the board keeps its secret under XDG_CONFIG_HOME; each board gets
  // a directory of its own, outside its root and the operator's home
  const config = mkdtempSync(join(tmpdir(), "fm-e2e-config-"));
  // T-151: no session is passed on, so the board owns what it starts and a
  // board stopped below takes its merges with it, never the operator's session
  const { FM_SESSION_PID: _session, FM_PORT: _port, ...inherited } = process.env;
  // The controller launches through the lifeline (separate process groups)
  // and drains the board's opt-in keeper scope before it exits.
  const proc: ChildProcess = spawn("python3", [join(ROOT, 'bin/lib/fm_lifeline.py'),
    'keep', '--pid', String(process.pid), '--', 'python3',
    join(ROOT, 'tests/lib/e2e_board_process.py'), root, config, join(ROOT, 'bin/lib')], {
    env: { ...inherited, ...env, FM_ROOT: root, ...(configuredPort ? {} : { FM_PORT: String(port) }), XDG_CONFIG_HOME: config },
    stdio: ["pipe", "ignore", "pipe"],
  });
  let processError = '';
  proc.stderr?.on('data', (data) => { processError += data.toString(); });
  const completion = new Promise<void>((resolve, reject) => {
    proc.once('error', reject);
    proc.once('close', (code, signal) => code === 0 ? resolve()
      : reject(new Error(`board controller exited ${code ?? signal}: ${processError}`)));
  });
  // A failed spawn must not become an unhandled rejection during readiness.
  completion.catch(() => {});
  completions.set(proc, completion);
  const url = `http://127.0.0.1:${port}`;
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    try {
      if ((await fetch(`${url}/api/state`)).ok) {
        const secret = readFileSync(join(config, "firstmate", `board-${port}.secret`), "utf8").trim();
        sessions.set(url, secret);
        return { url, proc, root, recorder, config, secret };
      }
    }
    catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 120));
  }
  await stopBoard({ proc, root, config });
  throw new Error("the board did not come up");
}

const completions = new WeakMap<ChildProcess, Promise<void>>();
const removal = { recursive: true, force: true, maxRetries: 5, retryDelay: 100 };

export async function stopBoard(b: { proc: ChildProcess; root: string; url?: string; config?: string }) {
  const completion = completions.get(b.proc);
  if (!completion) throw new Error('board has no owned process controller');
  b.proc.stdin?.end();
  await completion;
  const homeFile = join(b.root, '.fixture-fm-home');
  if (existsSync(homeFile)) rmSync(readFileSync(homeFile, 'utf8'), removal);
  rmSync(b.root, removal);
  if (b.config) rmSync(b.config, removal);
  if (b.url) sessions.delete(b.url);
}

// --- T-122: the captain's credential, for tests that are about something else ---
// Every board a test starts is one the captain signed in to: the first
// page.goto to a board in a test's `page` goes first through a one-time
// sign-in address, as the opener's would, and the board's /login page leaves
// the tab's token in sessionStorage, which later navigations in the tab keep.
// Nothing is injected. The sign-in itself, and a tab without the token, have
// tests of their own that use pages this does not touch.
const sessions = new Map<string, string>();
export const test = base.extend({
  page: async ({ page }, use) => {
    const goto = page.goto.bind(page), signed = new Set<string>();
    page.goto = (async (address: string, options?: Parameters<Page["goto"]>[1]) => {
      const origin = new URL(address).origin, secret = sessions.get(origin);
      if (secret && !signed.has(origin)) {
        await goto(signInAddress({ url: origin, secret }));
        // T-145: the login page takes the board's address before it trades
        // the code, so the address says nothing about whether the trade is
        // done. Once the token is kept, the login page loads the board's
        // own page, so wait for that page (#live is the board's, never the
        // login page's), and read the token there, with no navigation left.
        await page.locator("#live").waitFor({ state: "attached" });
        if (!await page.evaluate(() => sessionStorage.getItem("board.token")))
          throw new Error(`the one-time sign-in to ${origin} left no token`);
        signed.add(origin);
      }
      return goto(address, options);
    }) as Page["goto"];
    await use(page);
  },
});
// The token the board's /login hands a tab, derived as the board derives it:
// for tests that look for it where it must not be.
export const tabToken = (b: { url: string; secret: string }) =>
  createHmac("sha256", b.secret).update(`session:${b.url}`).digest("hex");
// What a script on the operator's machine writes with: the bearer from the
// secret file and the board's own Origin.
export const scriptHeaders = (b: { url: string; secret: string }) =>
  ({ origin: b.url, authorization: `Bearer ${b.secret}` });
// A one-time sign-in address, made as bin/fm-herdr.py makes one.
export function signInAddress(b: { url: string; secret: string }, issued = Date.now()) {
  const nonce = randomUUID().replace(/-/g, "");
  const tag = createHmac("sha256", b.secret).update(`login:${b.url}:${issued}.${nonce}`).digest("hex");
  return `${b.url}/login#${issued}.${nonce}.${tag}`;
}
