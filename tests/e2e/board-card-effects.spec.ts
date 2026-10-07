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
// a line of the fixture log with a pull request, which emitFixture does not carry
function emitPr(root:string, actor:string, task:string, type:string, pr:number, data={}) {
  const args=[join(root,'bin/fm-emit.sh'),'--actor',actor,'--task',task,'--type',type,'--pr',String(pr),
    '--data',JSON.stringify(data),'--en',`${type} #${pr}`,'--tw',`${type} #${pr}`];
  const result=spawnSync('bash',args,{env:{...process.env,FM_ROOT:root}});
  expect(result.status,result.stderr.toString()).toBe(0);
}
const t118Events = (root:string) => readFileSync(join(root,'state/events.jsonl'),'utf8').trim().split('\n').map(l => JSON.parse(l));

test('T-118: an answered card leaves the captain lane, and a park chosen on a card is carried out', async ({page}) => {
  const root = makeRoot([], false);
  writeTasks(root, [{id:'T-030',title:'Answered B, park',depends_on:[]},{id:'T-031',title:'A merge card held',depends_on:[]}]);
  emitFixture(root,'worker-30','T-030','dispatched','On it','接下',{role:'worker'});
  emitFixture(root,'worker-31','T-031','dispatched','On it','接下',{role:'worker'});
  emitPr(root,'worker-31','T-031','pr_opened',31);
  emitFixture(root,'reviewer-31','T-031','approved','Approved','通過',{role:'reviewer'});
  writeFileSync(join(root,'state/pending/D-1020.json'), JSON.stringify({id:'D-1020',kind:'choice',task:'T-030',
    ts:'2026-09-26T09:00:00Z',title:'Park T-030?',details:{...details,effect:{B:'park'}}}));
  writeFileSync(join(root,'state/pending/D-1031.json'), JSON.stringify({id:'D-1031',kind:'merge',task:'T-031',pr:31,
    ts:'2026-09-26T09:00:01Z',title:'Merge #31',details,gates:{branch:true,rebase:true,scope:true,'fail-first':true,ci:true,approval:true}}));
  const b = await startBoard(root);
  const inLane = (k:string, id:string) => page.locator(`[data-lane="${k}"] [data-task="${id}"]`);
  try {
    await page.goto(`${b.url}/?lang=en`);
    await expect(inLane('captain','T-030')).toHaveCount(1);
    await expect(inLane('captain','T-031')).toHaveCount(1);
    // the card says what each option does before the captain picks it
    await expect(page.locator('#card-D-1020 .opt[data-c="B"] .eff')).toHaveText(`→ ${EN.effectPark}`);
    await page.locator('#card-D-1020 .opt[data-c="B"]').click();
    await page.locator('#card-D-1020 .confirm').click();
    // the park is carried out: the parked event, and the card leaves the lane
    await expect(page.locator('#parked [data-task="T-030"]')).toHaveCount(1);
    await expect(inLane('captain','T-030')).toHaveCount(0);
    expect(t118Events(root).filter(e => e.type === 'parked').pop()).toMatchObject({actor:'captain',task:'T-030',data:{decision:'D-1020'}});
    expect(t118Events(root).filter(e => e.type === 'decision_made').pop()).toMatchObject({data:{decision:'D-1020',effect:'park',outcome:'done'}});
    // a merge card answered B holds: the task leaves the captain lane for
    // review, where its approval puts it, and nothing is merged
    await expect(page.locator('#card-D-1031 .opt[data-c="B"] .eff')).toHaveText(`→ ${EN.effectHold}`);
    await page.locator('#card-D-1031 .opt[data-c="B"]').click();
    await page.locator('#card-D-1031 .confirm').click();
    await expect(inLane('review','T-031')).toHaveCount(1);
    await expect(inLane('captain','T-031')).toHaveCount(0);
    expect(existsSync(b.recorder)).toBe(false);
  } finally {await stopBoard(b);}
});

// A stand-in for a round's own script: a bash that waits on a sleep. On
// SIGTERM it ends its sleep and then dies of the same signal, so the stop
// path is seen as a SIGTERM; and the test's finally ends both, so no sleep
// outlives the test, which bin/ci.sh would turn red (T-151).
// The API suite owns confirmation enforcement, event writes, crew SIGTERM
// and keeping the PR open. Browser cases own the words the captain sees.
for (const hasPr of [false, true]) {
  test(`T-118: park/drop confirmation explains the crew${hasPr ? ' and open PR' : ''}`, async ({page}) => {
    const root = makeRoot([], false);
    writeTasks(root, [{id:'T-051',title:'Work to set aside',depends_on:[]}]);
    emitFixture(root,'worker-51','T-051','dispatched','On it','接下',{role:'worker'});
    if (hasPr) emitPr(root,'worker-51','T-051','pr_opened',51);
    const b = await startBoard(root);
    const box = page.locator('#dropConfirm');
    try {
      await page.goto(`${b.url}/?lang=en`);
      for (const action of ['park', 'drop'] as const) {
        await page.locator('[data-menu="T-051"]').click();
        await expect(page.locator('[data-task="T-051"] .cacts button')).toHaveText([EN.park, EN.drop]);
        await page.locator(`[data-task="T-051"] [data-act="${action}"]`).click();
        await expect(box).toBeVisible();
        await expect(box).toContainText((action === 'park' ? EN.parkConfirm : EN.dropConfirm).replace('{id}','T-051'));
        await expect(box).toContainText(EN.crewStopNote.replace('{crew}','worker-51'));
        if (hasPr) await expect(box).toContainText(EN.prStaysOpen.replace('{pr}','#51'));
        await box.locator(action === 'park' ? '[data-cancel="park"]' : '[data-cancel-drop="T-051"]').click();
        await expect(box).toBeHidden();
      }
    } finally { await stopBoard(b); }
  });
}

test('T-118: a task parked while its card is pending stays in the captain lane, says so, and offers unpark', async ({page}) => {
  const root = makeRoot([], false);
  writeTasks(root, [{id:'T-060',title:'Parked with its card up',depends_on:[]}]);
  emitFixture(root,'worker-60','T-060','dispatched','On it','接下',{role:'worker'});
  writeFileSync(join(root,'state/pending/D-1060.json'), JSON.stringify({id:'D-1060',kind:'choice',task:'T-060',
    ts:'2026-09-26T09:00:00Z',title:'What next for T-060?',details}));
  const b = await startBoard(root);
  const captain = page.locator('[data-lane="captain"] [data-task="T-060"]');
  const box = page.locator('#dropConfirm');
  try {
    await page.goto(`${b.url}/?lang=en`);
    await expect(captain).toHaveCount(1);
    await page.locator('[data-menu="T-060"]').click();
    await expect(page.locator('[data-task="T-060"] .cacts button')).toHaveText([EN.park, EN.drop]);
    await page.locator('[data-task="T-060"] [data-act="park"]').click();
    // the confirm step says what a park does in this lane: the card holds it here
    await expect(box).toContainText(EN.parkConfirmCaptain.replace('{id}','T-060'));
    await expect(box).not.toContainText(EN.parkConfirm.replace('{id}','T-060'));
    await page.locator('#dropConfirm [data-confirm="park"]').click();
    await expect(captain.locator('.badge.b-parked')).toHaveText(EN.parkedPending);
    await expect(page.locator('#parked [data-task="T-060"]')).toHaveCount(0);
    expect(t118Events(root).pop()).toMatchObject({type:'parked',actor:'captain',task:'T-060'});
    // it offers unpark now, not a second park
    await page.locator('[data-menu="T-060"]').click();
    await expect(page.locator('[data-task="T-060"] .cacts button')).toHaveText([EN.unpark, EN.drop]);
    // a refusal the server sends is shown by its own text, not the generic line
    await page.route('**/tasks', route => route.fulfill({status:409, contentType:'application/json',
      body:JSON.stringify({error:'confirm before you unpark T-060', code:'confirmRequired'})}));
    await page.locator('[data-task="T-060"] [data-act="unpark"]').click();
    await expect(page.locator('#taskFeedback')).toHaveText(EN.confirmRequired);
    await page.unroute('**/tasks');
    await page.locator('[data-menu="T-060"]').click();
    await page.locator('[data-task="T-060"] [data-act="unpark"]').click();
    await expect(captain.locator('.badge.b-parked')).toHaveCount(0);
    await expect(page.locator('#taskFeedback')).toHaveText('');
    // parked again and the card withdrawn: the park is what places it
    await page.locator('[data-menu="T-060"]').click();
    await page.locator('[data-task="T-060"] [data-act="park"]').click();
    await page.locator('#dropConfirm [data-confirm="park"]').click();
    await expect(captain.locator('.badge.b-parked')).toHaveCount(1);
    unlinkSync(join(root,'state/pending/D-1060.json'));
    await expect(captain).toHaveCount(0);
    await page.locator('#parked > summary').click();
    await expect(page.locator('#parked [data-task="T-060"]')).toHaveCount(1);
  } finally {await stopBoard(b);}
});

test('T-118: an effect that failed is listed with its reason on the page until it is overtaken', async ({page}) => {
  const root = makeRoot([], false);
  writeTasks(root, [{id:'T-070',title:'A dispatch the dispatcher holds',depends_on:[]}]);
  // fm-dispatch.sh as the real one answers when it holds a task: the reason
  // on stderr, the tally on stdout, exit 0, and no task id printed
  writeFileSync(join(root,'bin/fm-dispatch.sh'), '#!/usr/bin/env bash\n' +
    'echo "fm-dispatch: T-070 waits for a slot: 3 in flight, limit 3" >&2\n' +
    'echo "fm-dispatch: 3 in flight, limit 3 - nothing to start"\n');
  chmodSync(join(root,'bin/fm-dispatch.sh'), 0o755);
  writeFileSync(join(root,'state/pending/D-1070.json'), JSON.stringify({id:'D-1070',kind:'choice',task:'T-070',
    ts:'2026-09-26T09:00:00Z',title:'Start T-070?',details:{...details,effect:{A:'dispatch'}}}));
  const b = await startBoard(root);
  const listed = page.locator('#effects #effect-D-1070');
  try {
    await page.goto(`${b.url}/?lang=en`);
    await expect(listed).toHaveCount(0);
    await page.locator('#card-D-1070 .opt[data-c="A"]').click();
    await page.locator('#card-D-1070 .confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText(EN.effectRefused);
    // listed by its effect's name and the dispatcher's own reason
    await expect(listed).toContainText(EN.effectFailed.replace('{effect}', EN.effectDispatch));
    await expect(listed).toContainText('T-070 waits for a slot: 3 in flight, limit 3');
    await expect(listed).toHaveAttribute('data-effect', 'dispatch');
    expect(t118Events(root).filter(e => e.type === 'decision_made').pop()).toMatchObject({data:{decision:'D-1070',effect:'dispatch',outcome:'failed'}});
    // dispatched some other way after the answer: the failure is overtaken
    emitFixture(root,'worker-70','T-070','dispatched','On it','接下',{role:'worker'});
    await expect(listed).toHaveCount(0);
  } finally {await stopBoard(b);}
});

test('T-118: a closed task is reopened from the history menu, behind a confirm step with a reason', async ({page}) => {
  const root = makeRoot([], false);
  writeTasks(root, [{id:'T-080',title:'Dropped by mistake',depends_on:[]}]);
  emitFixture(root,'worker-80','T-080','dispatched','On it','接下',{role:'worker'});
  emitFixture(root,'worker-80','T-080','agent_finished');
  emitFixture(root,'captain','T-080','closed','the captain dropped T-080','船長決定不做 T-080');
  const b = await startBoard(root);
  const inHistory = page.locator('#history [data-history="T-080"]');
  const box = page.locator('#dropConfirm');
  const reopen = async () => {
    await page.locator('#history [data-menu="T-080"]').click();
    await expect(page.locator('#history [data-history="T-080"] .cacts button')).toHaveText([EN.reopen]);
    await page.locator('#history [data-act="reopen"]').click();
    await expect(box).toContainText(EN.reopenConfirm.replace('{id}','T-080').replace('{stage}',EN.laneClosed));
    await page.locator('#dropConfirm [data-reopen-reason]').fill('dropped by mistake');
    await page.locator('#dropConfirm [data-confirm="reopen"]').click();
  };
  try {
    await page.goto(`${b.url}/?lang=en`);
    // closed tasks sit in no lane: the history is the only place to reopen one
    await expect(page.locator('#lanes [data-task="T-080"]')).toHaveCount(0);
    await page.locator('#history > summary').click();
    await expect(inHistory).toHaveCount(1);
    // a refusal for want of a reason is shown by its own text
    await page.route('**/tasks', route => route.fulfill({status:400, contentType:'application/json',
      body:JSON.stringify({error:'reopening needs a reason', code:'reopenNeedsReason'})}));
    await reopen();
    await expect(page.locator('#taskFeedback')).toHaveText(EN.reopenNeedsReason);
    await expect(inHistory).toHaveCount(1);
    await page.unroute('**/tasks');
    await reopen();
    // reopened with no later events: untouched work again, in ready
    await expect(page.locator('[data-lane="ready"] [data-task="T-080"]')).toHaveCount(1);
    await expect(inHistory).toHaveCount(0);
    expect(t118Events(root).pop()).toMatchObject({type:'reopened',actor:'captain',task:'T-080',
      data:{reason:'dropped by mistake',from:'closed'}});
  } finally {await stopBoard(b);}
});

test('T-118: reopening moves a merged card out of merged, and a card under a final task is shown', async ({page}) => {
  const root = makeRoot([], false);
  writeTasks(root, [{id:'T-117',title:'T-105 again',depends_on:[]}]);
  // T-117's sequence: its own #97 open, then a merge card for #96 raised
  // under it, answered, and merged
  emitFixture(root,'worker-117','T-117','dispatched','On it','接下',{role:'worker'});
  emitPr(root,'worker-117','T-117','pr_opened',97);
  emitFixture(root,'worker-117','T-117','agent_finished');
  emitPr(root,'firstmate','T-117','decision_requested',96);
  emitPr(root,'captain','T-117','merged',96);
  writeFileSync(join(root,'state/pending/D-1118.json'), JSON.stringify({id:'D-1118',kind:'choice',task:'T-117',
    title:'A card under a merged task',details}));
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    await expect(page.locator('[data-lane="merged"] [data-task="T-117"]')).toHaveCount(1);
    // the card under the merged task is shown, and says the task is final
    await expect(page.locator('#card-D-1118 .final-note')).toContainText(
      EN.finalNote.replace('{task}','T-117').replace('{stage}',EN.laneMerged));
    await page.locator('#card-D-1118 .opt[data-c="C"]').click();
    await page.locator('#card-D-1118 .confirm').click();
    await expect(page.locator('#card-D-1118')).toHaveCount(0);
    // the merged card offers reopening, behind a confirm step that needs a reason
    await page.locator('[data-lane="merged"] [data-menu="T-117"]').click();
    await expect(page.locator('[data-task="T-117"] .cacts button')).toHaveText([EN.reopen]);
    await page.locator('[data-task="T-117"] [data-act="reopen"]').click();
    const box = page.locator('#dropConfirm');
    await expect(box).toContainText(EN.reopenConfirm.replace('{id}','T-117').replace('{stage}',EN.laneMerged));
    const go = page.locator('#dropConfirm [data-confirm="reopen"]');
    await expect(go).toBeDisabled();
    await page.locator('#dropConfirm [data-reopen-reason]').fill('the merge card for #96 was raised under T-117');
    await expect(go).toBeEnabled();
    await go.click();
    // out of merged: with no later events it is untouched work again, and
    // shows its own pull request, not the one the wrong card merged
    await expect(page.locator('[data-lane="merged"] [data-task="T-117"]')).toHaveCount(0);
    const card = page.locator('[data-lane="ready"] [data-task="T-117"]');
    await expect(card).toHaveCount(1);
    await expect(card.locator('.pr')).toHaveText('#97');
    expect(t118Events(root).pop()).toMatchObject({type:'reopened',actor:'captain',task:'T-117',
      data:{reason:'the merge card for #96 was raised under T-117'}});
    await expect(page.locator('#log li').first()).toContainText('the captain reopened T-117');
    // a later merge card for #97 is shown and answerable
    writeFileSync(join(root,'state/pending/D-1119.json'), JSON.stringify({id:'D-1119',kind:'merge',task:'T-117',pr:97,
      title:'Merge #97',details,gates:{branch:true,rebase:true,scope:true,'fail-first':true,ci:true,approval:true}}));
    await expect(page.locator('#card-D-1119')).toHaveCount(1);
    await expect(page.locator('#card-D-1119 .final-note')).toHaveCount(0);
    await page.locator('#card-D-1119 .opt[data-c="A"]').click();
    await page.locator('#card-D-1119 .confirm').click();
    await expect.poll(() => existsSync(b.recorder) ? readFileSync(b.recorder,'utf8') : '').toContain('--pr 97 --task T-117');
  } finally {await stopBoard(b);}
});
