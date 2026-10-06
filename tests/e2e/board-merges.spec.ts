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
test('failed merge persists failure without salute or automatic retry', async ({page}) => {
  const b = await startBoard(makeRoot(['working']));
  writeFileSync(join(b.root,'bin/fm-merge.sh'),'#!/usr/bin/env bash\necho refused\nexit 1\n');
  try {
    await page.goto(`${b.url}/?lang=en`);
    await page.locator('[data-c="A"]').click();
    await page.locator('.confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText(EN.mergeRefused);
    await page.evaluate(async () => (window as any).render(await (await fetch('/api/state')).json()));
    await expect(page.locator('#orderFeedback')).toContainText(EN.mergeRefused);
    // answering again returns the stored record, which says the merge failed,
    // and runs nothing: the helper was called once
    const r = await page.request.post(`${b.url}/decisions`, {data:{id:'D-1',chosen:'A'}, headers:scriptHeaders(b)});
    const again = await r.json();
    expect(again.already).toBe(true);
    expect(again.decision.merge).toBe('failed');
    await page.reload();
    await expect(page.locator('#orderFeedback')).toContainText(EN.mergeRefused);
  } finally {await stopBoard(b);}
});

test('a refused merge names its decision and task, and clears once that task merges', async ({page}) => {
  test.setTimeout(60_000);
  const b = await startBoard(makeRoot(['working']));
  writeFileSync(join(b.root,'bin/fm-merge.sh'),'#!/usr/bin/env bash\necho refused\nexit 1\n');
  const {task} = JSON.parse(readFileSync(join(b.root,'state/pending/D-1.json'),'utf8'));
  const feedback = page.locator('#orderFeedback');
  try {
    await page.goto(`${b.url}/?lang=en`);
    await page.locator('[data-c="A"]').click();
    await page.locator('.confirm').click();
    await expect(feedback).toContainText(EN.mergeRefused);
    await expect(feedback).toContainText('D-1');
    await expect(feedback).toContainText(task);
    // a merge of some other task is not this one
    emitFixture(b.root,'github','T-OTHER','merged','Other merged','其他已合併');
    await page.evaluate(async () => (window as any).render(await (await fetch('/api/state')).json()));
    await expect(feedback).toContainText(EN.mergeRefused);
    // the same task merged afterwards, some other way: the refusal is old news
    const r = spawnSync('bash',[join(b.root,'bin/fm-emit.sh'),'--actor','github','--type','merged','--task',task,'--pr','99',
      '--en','merged by hand','--tw','手動合併'],{env:{...process.env,FM_ROOT:b.root}});
    expect(r.status).toBe(0);
    await expect(feedback).not.toContainText(EN.mergeRefused, {timeout:15_000});
    // and a reload does not bring it back
    await page.reload();
    await expect(page.locator('#roster .rrow').first()).toBeVisible();
    await expect(page.locator('#orderFeedback')).not.toContainText(EN.mergeRefused);
    await expect(page.locator('#deckwrap')).toBeHidden();
  } finally {await stopBoard(b);}
});

test('a second merge in the same project is refused while one runs, and its card stays', async ({page}) => {
  test.setTimeout(60_000);
  const root = makeRoot(['working']);   // D-1, a merge of #99
  const second = join(root,'state/pending/D-2.json');
  writeFileSync(second, JSON.stringify({id:'D-2',kind:'merge',task:'T-XB',pr:98,details,gates:{branch:true,rebase:true,scope:true,'fail-first':true,ci:true,approval:true}}));
  utimesSync(join(root,'state/pending/D-1.json'), new Date('2026-09-24T09:00:00Z'), new Date('2026-09-24T09:00:00Z'));
  utimesSync(second, new Date('2026-09-24T09:05:00Z'), new Date('2026-09-24T09:05:00Z'));
  const hold = join(root,'hold-merge');
  writeFileSync(hold, '');
  const b = await startBoard(root);
  const calls = () => existsSync(b.recorder) ? readFileSync(b.recorder,'utf8') : '';
  try {
    await page.goto(`${b.url}/?lang=en`);
    await page.locator('#card-D-1 [data-c="A"]').click();
    await page.locator('#card-D-1 .confirm').click();
    await expect(page.locator('#merging-D-1')).toContainText(EN.mergeRunning, {timeout:15_000});
    await expect.poll(calls, {timeout:15_000}).toContain('--pr 99');
    await expect(page.locator('#deck > .dcard')).toHaveAttribute('id', 'card-D-2');
    const card = page.locator('#card-D-2');
    await card.locator('[data-c="A"]').click();
    await card.locator('.confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText(EN.mergeBusy);
    await expect(card).toBeVisible();
    await expect(page.locator('#pcount')).toHaveText('1');
    await expect(card.locator('[data-c="A"]')).toBeEnabled();
    await expect(card.locator('.confirm')).toBeEnabled();
    expect(existsSync(join(root,'state/decisions/D-2.json'))).toBe(false);
    expect(calls()).not.toContain('--pr 98');
    // the first merge ends; the same card now goes through
    rmSync(hold);
    await expect(page.locator('#merging-D-1')).toHaveCount(0, {timeout:15_000});
    await card.locator('.confirm').click();
    await expect.poll(calls, {timeout:15_000}).toContain('--pr 98');
  } finally { rmSync(hold, {force:true}); await stopBoard(b); }
});

test('external outcomes override stale success and clear only their settled draft', async ({page}) => {
  const root=makeRoot(['working']);
  writeFileSync(join(root,'state/pending/D-2.json'),JSON.stringify({id:'D-2',task:'T-002',kind:'choice',details}));
  writeFileSync(join(root,'state/pending/D-3.json'),JSON.stringify({id:'D-3',task:'T-003',kind:'choice',details}));
  const b=await startBoard(root);
  writeFileSync(join(b.root,'bin/fm-merge.sh'),'#!/usr/bin/env bash\necho refused\nexit 1\n');
  try {
    await page.goto(`${b.url}/?lang=en`);
    await page.locator('#card-D-1 [data-c="B"]').click();
    await page.locator('#strip-D-2 > summary').click();
    await page.locator('#strip-D-3 > summary').click();
    await page.locator('#card-D-3 [data-c="custom"]').click();
    await page.locator('#card-D-3 textarea').fill('keep this unrelated draft');
    await page.locator('#card-D-2 [data-c="B"]').click();
    await page.locator('#card-D-2 .confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText(EN.recorded);
    const external=await page.request.post(`${b.url}/decisions`,{data:{id:'D-1',chosen:'A'},headers:scriptHeaders(b)});
    expect(external.ok()).toBe(true);
    await expect(page.locator('#orderFeedback')).toContainText(EN.mergeRefused);
    await expect(page.locator('#orderFeedback')).not.toContainText(EN.recorded);
    await expect(page.locator('.dcard')).toHaveCount(1);
    await expect(page.locator('#card-D-3 textarea')).toHaveValue('keep this unrelated draft');
    await expect(page.locator('#capstage')).toHaveAttribute('data-pose','ready',{timeout:15_000});
    await page.request.post(`${b.url}/decisions`,{data:{id:'D-3',chosen:'custom',text:'keep this unrelated draft'},headers:scriptHeaders(b)});
    await expect(page.locator('.dcard')).toHaveCount(0);
    await expect(page.locator('#capstage')).toHaveAttribute('data-pose','idle',{timeout:15_000});
  } finally {await stopBoard(b);}
});

test('network refusal keeps selection and accessible failure; reduced motion still acknowledges', async ({page}) => {
  const root = makeRoot(['working']);
  writeFileSync(join(root,'state/pending/D-2.json'),JSON.stringify({id:'D-2',kind:'choice',details}));
  const b = await startBoard(root);
  try {
    await page.emulateMedia({reducedMotion:'reduce'});
    await page.goto(`${b.url}/?lang=zh-TW`);
    await page.route('**/decisions',route => route.abort());
    await page.locator('#card-D-1 [data-c="C"]').click();
    await expect(page.locator('#capstage')).toHaveAttribute('data-pose','ready');
    await expect(page.locator('#capstage .capimg')).toHaveCSS('filter',/drop-shadow/);
    await expect(page.locator('#capstage .lbl span')).toHaveText(TW.capReady);
    await page.locator('#card-D-1 .confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText(TW.orderFailed);
    expect(existsSync(join(b.root,'state/decisions/D-1.json'))).toBe(false);
    await page.unroute('**/decisions'); await page.locator('#card-D-1 .confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText('AYE, CAPTAIN!');
    await expect(page.locator('#capstage')).toHaveAttribute('data-pose','order');
    await expect(page.locator('#capstage .capimg')).toHaveCSS('filter',/drop-shadow/);
    await expect(page.locator('#capstage .capimg')).toHaveCSS('transform','none');
    await expect(page.locator('#capstage .lbl span')).toHaveText(TW.capOrder);
    await expect(page.locator('#capstage')).toHaveAttribute('data-pose','idle');
    await expect(page.locator('#capstage .capimg')).toHaveCSS('filter','none');
    await expect(page.locator('#capstage .lbl span')).toHaveText(TW.capDeciding);
  } finally {await stopBoard(b);}
});

