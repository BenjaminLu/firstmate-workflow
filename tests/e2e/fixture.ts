// A board with a crew on it, built from an event log rather than from a mock
// of the server: the page under test is the real one, reading real state
// through the real endpoints. Nothing here calls a model or the network.
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, cpSync, rmSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn, type ChildProcess } from "node:child_process";

// playwright.config.ts sets testDir relative to the repository root, so the
// runner is always started from it; no import.meta here, which would make
// this file ESM-only and the runner transpiles to CommonJS
export const ROOT = resolve(process.cwd());
export type Stage = "working" | "gate" | "review";

const EVENT_FOR: Record<Stage, string> = {
  working: "dispatched", gate: "gate_failed", review: "review_opened",
};

export function makeRoot(stages: Stage[], withDecision = true) {
  const d = mkdtempSync(join(tmpdir(), "fm-e2e-"));
  mkdirSync(join(d, "state/pending"), { recursive: true });
  mkdirSync(join(d, "design"), { recursive: true });
  cpSync(join(ROOT, "board"), join(d, "board"), { recursive: true });
  cpSync(join(ROOT, "i18n"), join(d, "i18n"), { recursive: true });
  cpSync(join(ROOT, "design/tasks.json"), join(d, "design/tasks.json"));

  const tasks = JSON.parse(readFileSync(join(ROOT, "design/tasks.json"), "utf8")).tasks;
  const ev: string[] = [JSON.stringify({
    ts: "2026-09-21T09:00:00Z", actor: "captain", type: "greenlit",
    summary: { en: "green light", "zh-TW": "green light" },
  })];
  stages.forEach((s, i) => {
    const t = tasks[i];
    ev.push(JSON.stringify({
      ts: `2026-09-21T09:${String(i + 1).padStart(2, "0")}:00Z`,
      actor: "worker", task: t.id, type: EVENT_FOR[s],
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

export async function startBoard(root: string) {
  const port = 14500 + Math.floor(Math.random() * 400);
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
  throw new Error("the board did not come up");
}

export function stopBoard(b: { proc: ChildProcess; root: string }) {
  b.proc.kill(9);
  rmSync(b.root, { recursive: true, force: true });
}
