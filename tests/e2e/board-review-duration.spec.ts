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
test('T-145: a task\'s card shows how long its last review round took and how it ended', async ({page}) => {
  const root = makeRoot([], false);
  emitFixture(root, 'reviewer-lr', 'T-034', 'review_opened', 'Review ready', '開始審查', {role:'reviewer'});
  emitFixture(root, 'reviewer-lr', 'T-034', 'approved', 'Review approved', '審查通過',
    {wall_clock:{started:1790686805, ended:1790687825, seconds:1020}});
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    const line = page.locator('#lanes .card[data-task="T-034"] .lastrev');
    await expect(line).toHaveText(EN.lastReview.replace('{time}', '17:00').replace('{outcome}', EN.lastReviewApproved));
    await expect(line).toHaveAttribute('data-last-review', '1020');
    await page.locator('[data-l="zh-TW"]').click();
    await expect(line).toHaveText(TW.lastReview.replace('{time}', '17:00').replace('{outcome}', TW.lastReviewApproved));
    // a task no review round has finished on shows none
    await expect(page.locator('#lanes .card:not([data-task="T-034"]) .lastrev')).toHaveCount(0);
  } finally { stopBoard(b); }
});

