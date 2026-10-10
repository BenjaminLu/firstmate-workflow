import { openCrewSheet } from './lib/board';
// The board, in a browser. Poses are asserted as classes and text as
// dictionary values, never as screenshots: a snapshot test of a ship that
// moves would fail on the animation and pass on the wrong crew.
import { expect, type Page } from "@playwright/test";
// `test` is the fixture's: every board a test starts is signed in to (T-122)
import { test, makeRoot, startBoard, stopBoard, writeRegistry, writeProjects, readTasks, writeTasks, ROOT, details, scriptHeaders, signInAddress, tabToken } from "./lib/fixture";
import { appendFileSync, readFileSync, existsSync, writeFileSync, rmSync, utimesSync, mkdirSync, chmodSync, unlinkSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { EN, TW, CN, T040_KEYS, T057_KEYS, CN_ACTIVITY, CN_DETAILS, CREW, emitFixture, emit, CN_T058, useBoard } from "./lib/board";
const { board, open } = useBoard();
test('legacy scalar records disclose missing details without invented translations', async ({page}) => {
  const root = makeRoot(['working']);
  writeFileSync(join(root,'state/pending/D-1.json'),JSON.stringify({id:'D-1',kind:'choice',title:'Legacy literal title'}));
  expect(spawnSync('bash',[join(root,'bin/fm-diagram.sh'),'--decision','D-1','--repo',root]).status).toBe(0);
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=zh-TW`);
    await openCrewSheet(page);
    await expect(page.locator('.dcard')).toContainText('Legacy literal title');
    await expect(page.locator('.explanation')).toHaveText(TW.missingDetails);
    await expect(page.locator('.tradeoffs')).toHaveCount(0);
  } finally {await stopBoard(b);}
});

test("nothing here can reach a model", async () => {
  // structural, not a promise: the fixture root has no adapters in it, so
  // there is nothing for the board to shell out to even if it tried. The
  // only scripts it may spawn are the merge recorder, the registry/settings reader
  // and the lifeline keeper the merge runs under, and they are the whole
  // contents of its bin/.
  //
  // fm-config.sh and the fm-herdr.py it imports (T-069) are there so the
  // board can read the project registry's `github`. The only path from them
  // to a model is fm_run_chain, which runs bin/adapters - absent above - and
  // the board calls nothing from fm-config.sh but the registry readers
  // (fm_projects since T-054, to know every project's repository and tasks)
  // and fm_tasks, which only reads task directories (T-090), plus
  // fm_board_port and fm_language, which read config.yaml settings (T-154).
  //
  // fm_lifeline is not an fm-config.sh function: it is server.ts's path to
  // bin/lib/fm_lifeline.py, the lifeline module the merge helper runs under
  // (T-151). It starts and rings only what fm names and reaches no model; the
  // line below pins bin/lib to the lifeline files and the read-only storage resolver.
  // fm-emit.sh sources the task grammar library, which only defines shell functions and reaches no model.
  // The board runs bin/lib/fm_ste.py only to read the STE rule table (T-210/T-211), which reaches no model.
  // The board runs bin/lib/fm_evidence.py summary only to read evidence metadata (T-230), which reaches no model.
  // T-232: the board reads fm_gates.json; fm_evidence imports fm_binding only for gate_list/gate_entry. Neither reaches a model.
  const { readdirSync, readFileSync } = await import("node:fs");
  expect(existsSync(join(board.root, "bin/adapters"))).toBe(false);
  expect(readdirSync(join(board.root, "bin")).sort()).toEqual(["fm-config.sh", "fm-decide.sh", "fm-diagram.sh", "fm-emit.sh", "fm-herdr.py", "fm-merge.sh", "lib"]);
  // lib/ contains the lifeline and config helpers, nothing that calls a model
  expect(readdirSync(join(board.root, "bin/lib")).sort()).toEqual(["fm-lifeline.sh", "fm-task-grammar.sh", "fm_binding.py", "fm_config_runtime.py", "fm_config_tasks.py", "fm_config_values.py", "fm_evidence.py", "fm_gates.json", "fm_git_transfer.py", "fm_lifeline.py", "fm_project_paths.py", "fm_registry.py", "fm_spec_preflight.py", "fm_ste.py"]);
  const called = new Set(readFileSync(join(board.root, "board/server.ts"), "utf8").match(/\bfm_[a-z_]+/g) ?? []);
  expect([...called].sort()).toEqual(["fm_board_port", "fm_evidence", "fm_gates", "fm_language", "fm_lifeline", "fm_project_get", "fm_project_resolve", "fm_projects", "fm_ste", "fm_tasks"]);
});

test("T-127: vendor, model and CLI version are separate fields, read from the run itself", async ({ page }) => {
  test.setTimeout(60_000);
  const root = makeRoot(["working", "review"], false);
  const spec = { tasks: readTasks(root) };
  // a mismatch: the round ran on a different model than config.yaml asked for
  emitFixture(root, "worker-1", spec.tasks[0].id, "dispatched", "on it", "接下", {
    role: "worker", identity: { name: "worker-1", vendor: "claude",
      model_requested: "claude-opus-5-5", model: "claude-sonnet-5",
      cli_version: "2.1.0", model_mismatch: true } });
  // no mismatch, and a different vendor: the engine badge counts both
  emitFixture(root, "reviewer-1", spec.tasks[1].id, "review_opened", "round 1", "第 1 輪", {
    role: "reviewer", identity: { name: "reviewer-1", vendor: "codex",
      model_requested: "o1", model: "o1", cli_version: "0.9.0", model_mismatch: false } });
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    await openCrewSheet(page);
    await expect(page.locator("#roster .rrow").first()).toBeVisible();

    // the header's engine badge shows the vendors actually running now
    await expect(page.locator("#engine")).toContainText("claude");
    await expect(page.locator("#engine")).toContainText("codex");

    // the roster's Vendor and Model columns, sortable like the others
    await expect(page.locator('.roster [data-sort="vendor"]')).toHaveCount(1);
    await expect(page.locator('.roster [data-sort="model"]')).toHaveCount(1);
    const w1 = page.locator('.roster [data-roster="worker-1"]');
    await expect(w1.locator(".rv")).toHaveText("claude");
    await expect(w1.locator(".rm")).toHaveClass(/\bwarn\b/);
    await expect(w1.locator(".rm")).toContainText("claude-opus-5-5");
    await expect(w1.locator(".rm")).toContainText("claude-sonnet-5");
    const r1 = page.locator('.roster [data-roster="reviewer-1"]');
    await expect(r1.locator(".rv")).toHaveText("codex");
    await expect(r1.locator(".rm")).not.toHaveClass(/\bwarn\b/);
    await expect(r1.locator(".rm")).toHaveText("o1");

    // the roster retains the former detail card fields
    const card = page.locator('[data-roster="worker-1"]');
    await expect(card.locator(".rv")).toHaveText("claude");
    await expect(card.locator(".rm")).toHaveClass(/\bwarn\b/);
    await expect(card.locator(".rc")).toHaveText("2.1.0");

  } finally { await stopBoard(b); }
});

test("T-127: an old run without vendor or model still renders", async ({ page }) => {
  test.setTimeout(60_000);
  const root = makeRoot(["working"], false);
  const spec = { tasks: readTasks(root) };
  emitFixture(root, "worker-1", spec.tasks[0].id, "dispatched", "on it", "接下", { role: "worker" });
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    await openCrewSheet(page);
    await expect(page.locator("#roster .rrow").first()).toBeVisible();
    const card = page.locator('[data-roster="worker-1"]');
    await expect(card.locator(".rv")).toHaveText(EN.crewUnknown);
    await expect(card.locator(".rm")).toHaveText(EN.crewUnknown);
    await expect(card.locator(".rm")).not.toHaveClass(/\bwarn\b/);
    await expect(card.locator(".rc")).toHaveText(EN.crewUnknown);
  } finally { await stopBoard(b); }
});
