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
test('T-159: CI waiting is distinct in the roster until review starts', async ({page}) => {
  const root = makeRoot(['review'], false);
  const task = readTasks(root)[0].id;
  const actor = 'reviewer-ci';
  emitFixture(root, actor, task, 'review_opened', '', '', {role:'reviewer'});
  emitFixture(root, actor, task, 'crew_status', '', '', {
    role:'reviewer', phase:'waiting_ci', window_expected:false,
    activity:{en:'Waiting for CI: ci, lint', 'zh-TW':'等待 CI：ci, lint'}
  });
  const b = await startBoard(root);
  try {
    for (const [lang, label] of [['en','Waiting for CI'], ['zh-TW','等待 CI']]) {
      await page.goto(`${b.url}/?lang=${lang}`);
      await expect(page.locator(`[data-roster="${actor}"] .st`)).toHaveText(label);
      await expect(page.locator(`[data-roster="${actor}"] .cwindow`)).toContainText(lang === 'en' ? 'No window' : '尚無視窗');
      await expect(page.locator(`[data-roster="${actor}"] .cwindow a`)).toHaveCount(0);
      await expect(page.locator('.rrow.st-waiting_ci')).toHaveCount(1);
      await expect(page.locator(`[data-roster="${actor}"]`)).toContainText('ci, lint');
      const crew = (await (await page.request.get(`${b.url}/api/state`)).json()).crew.find(c => c.id === actor);
      expect(crew.window_expected).toBe(false);
    }
    emitFixture(root, actor, task, 'crew_status', '', '', {
      role:'reviewer', phase:'review', window_expected:true,
      activity:{en:'Review adapter starting', 'zh-TW':'開始審核'}
    });
    await expect(page.locator(`[data-roster="${actor}"] .st`)).toHaveText(TW.laneReview);
    await expect(page.locator(`[data-roster="${actor}"] .cwindow`)).toHaveCount(0);
    await expect(page.locator('.rrow.st-waiting_ci')).toHaveCount(0);
    await expect(page.locator(`[data-roster="${actor}"]`)).toHaveClass(/st-review/);
    const resumed = (await (await page.request.get(`${b.url}/api/state`)).json()).crew.find(c => c.id === actor);
    expect(resumed.window_expected).toBe(true);
  } finally { await stopBoard(b); }
});
