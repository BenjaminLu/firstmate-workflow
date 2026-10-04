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
test('merge identities queue absent tasks, survive refresh and never replay history', async ({page}) => {
  test.setTimeout(60_000);
  const root = makeRoot(['working']); emit(root,'merged',880);
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    await expect(page.locator('.dcard')).toBeVisible();
    await expect(page.locator('#salvo')).not.toHaveClass(/fire/);
    emit(root,'merged',881); emit(root,'merged',882);
    await expect(page.locator('.scene')).toHaveAttribute('data-effect','merge:881');
    await expect(page.locator('#salvo')).toHaveClass(/fire/);
    await page.waitForTimeout(700);
    const refresh = await page.evaluate(async () => {
      const state = await (await fetch('/api/state')).json();
      // Measure synchronously around render so browser transport time cannot
      // masquerade as an animation reset or seek.
      const el = document.querySelector('#vessel')!;
      const a0 = el.getAnimations()[0] as CSSAnimation | undefined;
      const hasAnimation = !!a0;
      const running = a0?.playState === 'running';
      const name = a0?.animationName;
      const startBefore = a0?.startTime;
      const delayBefore = a0?.effect?.getTiming().delay;
      (window as any).render(state);
      const a1 = el.getAnimations()[0];
      return {
        hasAnimation, running, name,
        sameVessel: el === document.querySelector('#vessel'),
        sameAnimation: a1 === a0,
        startBefore, startAfter: a1?.startTime,
        delayBefore, delayAfter: a1?.effect?.getTiming().delay,
      };
    });
    await expect(page.locator('.scene')).toHaveAttribute('data-effect','merge:881');
    expect(refresh.hasAnimation).toBe(true);
    expect(refresh.running).toBe(true);
    expect(refresh.name).toBe('heel');
    expect(refresh.sameVessel).toBe(true);
    expect(refresh.sameAnimation).toBe(true);
    expect(refresh.startAfter).toBe(refresh.startBefore);
    expect(refresh.delayAfter).toBe(refresh.delayBefore);
    expect(await page.locator('#vessel').evaluate(el=>(el as HTMLElement).style.animationDelay)).toBe('0s');
    emit(root,'merged',881);
    await expect(page.locator('.scene')).toHaveAttribute('data-effect','merge:882', {timeout:15_000});
    // not widened: 882 has at most its 3.2 s left, and a replayed 881
    // after it would add 3.2 s more, which is what this window catches
    await expect(page.locator('.scene')).not.toHaveAttribute('data-effect', /.+/, {timeout:4000});
    await page.evaluate(() => { (window as any).connect(); });
    await page.waitForTimeout(650);
    await expect(page.locator('#salvo')).not.toHaveClass(/fire/);
    await page.reload();
    await expect(page.locator('.dcard')).toBeVisible();
    await expect(page.locator('#salvo')).not.toHaveClass(/fire/);
  } finally {await stopBoard(b);}
});

test('failed merge persists failure without salute or automatic retry', async ({page}) => {
  const b = await startBoard(makeRoot(['working']));
  writeFileSync(join(b.root,'bin/fm-merge.sh'),'#!/usr/bin/env bash\necho refused\nexit 1\n');
  try {
    await page.goto(`${b.url}/?lang=en`);
    await page.locator('[data-c="A"]').click();
    await page.locator('.confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText(EN.mergeRefused);
    await expect(page.locator('#salvo')).not.toHaveClass(/fire/);
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
    await expect(page.locator('#salvo')).not.toHaveClass(/fire/);
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
    await expect(page.locator('.scene .pivot').first()).toBeVisible();
    await expect(page.locator('#orderFeedback')).not.toContainText(EN.mergeRefused);
    await expect(page.locator('#deckwrap')).toBeHidden();
  } finally {await stopBoard(b);}
});

test('a second merge in the same project is refused while one runs, and its card stays', async ({page}) => {
  test.setTimeout(60_000);
  const root = makeRoot(['working']);   // D-1, a merge of #99
  const second = join(root,'state/pending/D-2.json');
  writeFileSync(second, JSON.stringify({id:'D-2',kind:'merge',task:'T-XB',pr:98,details,gates:[1,1,1,1,1,1,1]}));
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
    await expect(page.locator('#captain')).toHaveAttribute('data-pose','ready',{timeout:15_000});
    await page.request.post(`${b.url}/decisions`,{data:{id:'D-3',chosen:'custom',text:'keep this unrelated draft'},headers:scriptHeaders(b)});
    await expect(page.locator('.dcard')).toHaveCount(0);
    await expect(page.locator('#captain')).toHaveAttribute('data-pose','idle',{timeout:15_000});
  } finally {await stopBoard(b);}
});

test('network refusal keeps selection and accessible failure; reduced motion still acknowledges', async ({page}) => {
  const b = await startBoard(makeRoot(['working']));
  try {
    await page.emulateMedia({reducedMotion:'reduce'});
    await page.goto(`${b.url}/?lang=zh-TW`);
    await page.route('**/decisions',route => route.abort());
    await page.locator('[data-c="C"]').click();
    expect(await page.locator('#captain .tool').evaluate(el=>getComputedStyle(el).height)).toBe('38px');
    await page.locator('.confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText(TW.orderFailed);
    await expect(page.locator('.scene .fig.cheer')).toHaveCount(0);
    expect(existsSync(join(b.root,'state/decisions/D-1.json'))).toBe(false);
    await page.unroute('**/decisions'); await page.locator('.confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText('AYE, CAPTAIN!');
    expect(await page.locator('#captain .tool').evaluate(el=>getComputedStyle(el).height)).toBe('52px');
    await expect(page.locator('#ahoy')).toBeVisible();
    await expect(page.locator('.scene .fig.cheer')).toHaveCount(0);
  } finally {await stopBoard(b);}
});

