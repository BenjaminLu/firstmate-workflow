// A board with a crew on it, built from an event log rather than from a mock
// of the server: the page under test is the real one, reading real state
// through the real endpoints. Nothing here calls a model or the network.
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, cpSync, rmSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn, type ChildProcess } from "node:child_process";

// No import.meta here: it is ESM-only and the runner transpiles to
// CommonJS. cwd is the repository root because bin/ci.sh is the only thing
// that starts this runner and it runs from there - testDir resolves
// against the config file, not cwd, so that is not what makes this true.
export const ROOT = resolve(process.cwd());
export type Stage = "working" | "gate" | "review";
// an agent per entry: the board's crew are agents, so a fixture that wants
// five crewmen needs five actors, not five tasks

const EVENT_FOR: Record<Stage, string> = {
  working: "dispatched", gate: "gate_failed", review: "review_opened",
};

export function makeRoot(stages: Stage[], withDecision = true, actors: "per-task" | "one-worker" = "per-task") {
  const d = mkdtempSync(join(tmpdir(), "fm-e2e-"));
  mkdirSync(join(d, "state/pending"), { recursive: true });
  mkdirSync(join(d, "design"), { recursive: true });
  cpSync(join(ROOT, "board"), join(d, "board"), { recursive: true });
  cpSync(join(ROOT, "i18n"), join(d, "i18n"), { recursive: true });
  cpSync(join(ROOT, "design/tasks.json"), join(d, "design/tasks.json"));

  const tasks = JSON.parse(readFileSync(join(ROOT, "design/tasks.json"), "utf8")).tasks;
  if (tasks.length < stages.length) {
    throw new Error(
      `the fixture wants ${stages.length} tasks and design/tasks.json has ${tasks.length}`);
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
      title: "Merge it into main", gates: [1, 1, 1, 1, 1, 1, 0],
    }));
  }
  return d;
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
