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
    await expect(page.locator('.dcard')).toContainText('Legacy literal title');
    await expect(page.locator('.explanation')).toHaveText(TW.missingDetails);
    await expect(page.locator('.tradeoffs')).toHaveCount(0);
  } finally {await stopBoard(b);}
});

// its own board: it emits a merge, and with the file's tests running in
// parallel the shared board is being read by the language tests meanwhile
test("a crewman turns under the pointer, and the ahoy fires", async ({ page }) => {
  // the start of its board counts against the test's own budget
  test.setTimeout(60_000);
  const own = await startBoard(makeRoot([...CREW]));
  try {
    await open(page, "zh-TW", "query", own.url);
    const crew = page.locator(".scene .pivot").first();
    await crew.scrollIntoViewIfNeeded();
    const before = await crew.evaluate((el) => el.style.getPropertyValue("--ry"));
    const box = (await crew.boundingBox())!;
    // low on the figure: a bubble sits above the head and would take the press
    const y = box.y + box.height * 0.82;
    await page.mouse.move(box.x + box.width / 2, y);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width / 2 + 90, y, { steps: 6 });
    await page.mouse.up();
    const after = await crew.evaluate((el) => el.style.getPropertyValue("--ry"));
    expect(after).not.toBe(before);
    expect(parseFloat(after)).toBeGreaterThan(parseFloat(before || "-26"));

    emit(own.root, 'merged', 777);
    await expect(page.locator("#vessel")).toHaveClass(/heel/);
    await expect(page.locator("#salvo")).toHaveClass(/fire/);
    await expect(page.locator(".scene .fig.cheer").first()).toBeVisible();
  } finally { await stopBoard(own); }
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
  const { readdirSync, readFileSync } = await import("node:fs");
  expect(existsSync(join(board.root, "bin/adapters"))).toBe(false);
  expect(readdirSync(join(board.root, "bin")).sort()).toEqual(["fm-config.sh", "fm-decide.sh", "fm-diagram.sh", "fm-emit.sh", "fm-herdr.py", "fm-merge.sh", "lib"]);
  // lib/ contains the lifeline and config helpers, nothing that calls a model
  expect(readdirSync(join(board.root, "bin/lib")).sort()).toEqual(["fm-lifeline.sh", "fm_config_runtime.py", "fm_config_tasks.py", "fm_config_values.py", "fm_lifeline.py", "fm_project_paths.py", "fm_registry.py"]);
  const called = new Set(readFileSync(join(board.root, "board/server.ts"), "utf8").match(/\bfm_[a-z_]+/g) ?? []);
  expect([...called].sort()).toEqual(["fm_board_port", "fm_language", "fm_lifeline", "fm_project_get", "fm_project_resolve", "fm_projects", "fm_tasks"]);
});

test("no cards retains one idle captain aboard", async ({ page }) => {
  test.setTimeout(60_000);
  // Driven by the state the page reads, not by calling into the page:
  // render() runs again on the board's own refresh and would put him
  // straight back, so a hand call passes or flakes depending on the tick.
  const quiet = await startBoard(makeRoot(["working"], false));
  try {
    await page.goto(`${quiet.url}/?lang=en`);
    await expect(page.locator(".scene .pivot").first()).toBeVisible();
    await expect(page.locator(".dcard")).toHaveCount(0);
    await expect(page.locator("#captain .fig.r-cap")).toHaveCount(1);
    // Visibility must come from the ship, independently of the empty
    // decision region. A DOM node hidden by an ancestor does not pass.
    await expect(page.locator(".scene #captain")).toBeVisible();
    await expect(page.locator("#captain")).toHaveAttribute("data-pose", "idle");
  } finally { await stopBoard(quiet); }
});

test("captain and left helm stay on the real deck at every width and rate", async ({page}) => {
  test.setTimeout(60000);
  const b=await startBoard(makeRoot([],false));
  try {
    await page.goto(b.url+'/?lang=en');
    await page.addStyleTag({content:'.scene *{animation:none!important;transition:none!important}'});
    for(const n of [0,2,5,9,14,19,24]) {
      for(const width of [320,390,768,1280]) {
        await page.setViewportSize({width,height:844});
        await page.evaluate(async n=>{
          const s=await (await fetch('/api/state')).json();
          s.crew=Array.from({length:n},(_,i)=>({id:i?'worker-'+i:'firstmate',role:i?'worker':'firstmate',state:'working',task:'T-001'}));
          (window as any).render(s);
        },n);
        await expect(page.locator('.scene #captain')).toBeVisible();
        await expect(page.locator('.r-cap')).toHaveCount(1);
        const boxes=await page.evaluate(()=>{
          const scene=document.querySelector('.scene') as HTMLElement;
          const rect=(s:string)=>{const r=document.querySelector(s)!.getBoundingClientRect();return {x:r.x,y:r.y,w:r.width,h:r.height,right:r.right,bottom:r.bottom};};
          const css=getComputedStyle(scene),cap=document.querySelector('#captain') as HTMLElement;
          return {scene:rect('.scene'),cap:rect('#captain .pivot'),foot:rect('#captain .shoeL .fr'),helm:rect('.helm'),hull:rect('.hullwrap'),bow:rect('.prow'),stern:rect('.stern'),deck:scene.getBoundingClientRect().bottom-1-parseFloat(css.getPropertyValue('--deckY0'))-parseFloat(cap.style.getPropertyValue('--capRow'))*parseFloat(css.getPropertyValue('--rowStep'))};
        });
        expect(boxes.cap.w).toBeGreaterThan(0);expect(boxes.cap.h).toBeGreaterThan(0);
        expect(boxes.cap.x).toBeGreaterThanOrEqual(boxes.scene.x);
        expect(boxes.cap.right).toBeLessThanOrEqual(boxes.scene.right);
        expect(Math.abs(boxes.cap.bottom-boxes.deck)).toBeLessThan(12); // 3D foot projection
        expect(Math.abs(boxes.foot.bottom-boxes.deck)).toBeLessThan(12);
        expect(boxes.cap.x+boxes.cap.w/2).toBeGreaterThan(boxes.hull.x);
        expect(boxes.cap.x+boxes.cap.w/2).toBeLessThan(boxes.hull.right);
        expect(boxes.helm.x+boxes.helm.w/2).toBeLessThan(boxes.hull.x+boxes.hull.w/2);
        expect(boxes.bow.x).toBeLessThan(boxes.hull.x+boxes.hull.w/2);
        expect(boxes.stern.x).toBeGreaterThan(boxes.hull.x+boxes.hull.w/2);
        expect(boxes.helm.x+boxes.helm.w/2).toBeGreaterThan(boxes.hull.x);
      }
    }
  } finally {await stopBoard(b);}
});

test("a crewman below the top deck still names the task he is on", async ({ page }) => {
  test.setTimeout(60_000);
  // Criterion 3 has no viewport qualifier, and a crowded ship is where
  // the name chips appear. T-116 made every tag quiet: it carries the
  // name only, and the task he is on is in his detail card and the roster.
  const many = await startBoard(makeRoot(Array(9).fill("working"), false));
  try {
    await page.goto(`${many.url}/?lang=en`);
    await expect(page.locator(".scene .pivot").first()).toBeVisible();
    const minis = page.locator(".scene .bub.mini");
    const count = await minis.count();
    expect(count).toBeGreaterThan(0);
    // the name exactly: no task, round or activity rides on the tag
    for (const text of await minis.locator(".who").allInnerTexts()) {
      expect(text.trim()).toMatch(/^(worker|reviewer)-\d+$/);
    }
    // the task, not merely non-empty: each chip's own card names it
    const tasks = await minis.locator(".crewcard .ctask").allTextContents();
    expect(tasks.length).toBe(count);
    // any task id the board accepts (board/server.ts TASK_ID): the crew is
    // on whatever design/tasks holds, a skill update (SK-*) included
    for (const t of tasks) expect(t.trim()).toMatch(/^(T|SK)-[0-9]{3,} /);
    // and the roster still carries what each of them is on
    const jobs = await page.locator(".roster .jb").allInnerTexts();
    expect(jobs.filter((j) => /^(T|SK)-[0-9]{3,}/.test(j)).length).toBe(9);
  } finally { await stopBoard(many); }
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
    await expect(page.locator(".scene .pivot").first()).toBeVisible();

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

    // the detail card gains Vendor, Model and CLI rows
    const card = page.locator('[data-bubble="worker-1"] .crewcard');
    await expect(card.locator(".cvendor")).toHaveText("claude");
    await expect(card.locator(".cmodel")).toHaveClass(/\bwarn\b/);
    await expect(card.locator(".ccli")).toHaveText("2.1.0");

    // the name tag stays quiet: no model string anywhere on it
    const tag = page.locator('[data-bubble="worker-1"] .who');
    await expect(tag).not.toContainText("claude-sonnet-5");
    await expect(tag).not.toContainText("claude-opus-5-5");
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
    await expect(page.locator(".scene .pivot").first()).toBeVisible();
    const card = page.locator('[data-bubble="worker-1"] .crewcard');
    await expect(card.locator(".cvendor")).toHaveText(EN.crewUnknown);
    await expect(card.locator(".cmodel")).toHaveText(EN.crewUnknown);
    await expect(card.locator(".cmodel")).not.toHaveClass(/\bwarn\b/);
    await expect(card.locator(".ccli")).toHaveText(EN.crewUnknown);
  } finally { await stopBoard(b); }
});

test("the ship follows the crew, not the backlog", async ({ page }) => {
  test.setTimeout(60_000);
  // The bug this task replaces: one figure per in-flight task. A fixture
  // with one agent per task cannot tell the two apart, which is why the
  // old one looked fine - so this is twelve tasks in flight and one agent
  // on them, and it has to be a small ship with one crewman aboard
  // besides firstmate.
  const many = await startBoard(makeRoot(Array(12).fill("working"), false, "one-worker"));
  try {
    await page.goto(`${many.url}/?lang=en`);
    await expect(page.locator(".scene .pivot").first()).toBeVisible();
    expect(Number(await page.locator(".scene").getAttribute("data-crew"))).toBe(2);
    await expect(page.locator(".roster li")).toHaveCount(2);
    const small = await page.locator(".scene").getAttribute("data-rate");
    expect(small).toBe("rate1");        // two aboard is the smallest ship
  } finally { await stopBoard(many); }
});

test("the ship grows with the crew", async ({ page }) => {
  test.setTimeout(60_000);   // starts a second board in its body
  // zh-TW like every other interaction: the criterion puts the three
  // languages in the snapshot reads and everything else in one locale
  await open(page, "zh-TW");
  const small = await page.locator(".scene").getAttribute("data-rate");
  const crewNow = Number(await page.locator(".scene").getAttribute("data-crew"));
  expect(crewNow).toBe(CREW.length + 1);
  const big = await startBoard(makeRoot(Array(20).fill("working"), false));
  try {
    await page.goto(`${big.url}/?lang=en`);
    await expect(page.locator(".scene .pivot").first()).toBeVisible();
    expect(await page.locator(".scene").getAttribute("data-rate")).not.toBe(small);
    expect(Number(await page.locator(".scene").getAttribute("data-crew"))).toBe(21);
    // the whole sail still clears the tallest head
    const clear = await page.evaluate(() => {
      const top = [...document.querySelectorAll<HTMLElement>(".scene .pivot")]
        .reduce((m, p) => Math.min(m, p.getBoundingClientRect().top), Infinity);
      const sail = [...document.querySelectorAll<HTMLElement>(".scene .sail")]
        .reduce((m, s) => Math.max(m, s.getBoundingClientRect().bottom), -Infinity);
      return sail < top;
    });
    expect(clear).toBe(true);
  } finally { await stopBoard(big); }
});

// --- T-122: only the captain's browser writes ---------------------------------
// These use pages the fixture does not sign in: the tab gets in through the
// one-time address, or not at all.
