import { showFleet } from './lib/board';
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
test('the captain parks, unparks and drops a card by menu and by drag, and confirms a drop in the page', async ({page}) => {
  test.setTimeout(90_000);
  const root = makeRoot([], false);
  writeTasks(root, [
    {id:'T-A',title:'Ready to set aside',depends_on:[]},
    {id:'T-B',title:'Waits on T-A',depends_on:['T-A']},
    {id:'T-C',title:'Parked from the keyboard',depends_on:[]},
    {id:'T-D',title:'Dropped by dragging',depends_on:[]},
    {id:'T-W',title:'Already at work',depends_on:[]},
  ]);
  const plan = JSON.stringify(readTasks(root));
  emitFixture(root,'worker-w','T-W','dispatched','On it','接下',{role:'worker'});
  const events = () => readFileSync(join(root,'state/events.jsonl'),'utf8').trim().split('\n').map(l => JSON.parse(l));
  const last = () => events()[events().length - 1];
  const b = await startBoard(root);
  // the confirming step is in the page; a browser dialog fails the test
  const dialogs: string[] = [];
  page.on('dialog', d => { dialogs.push(d.type()); d.dismiss().catch(() => {}); });
  const lane = (k:string, id:string) => page.locator(`[data-lane="${k}"] [data-task="${id}"]`);
  const parkedCard = (id:string) => page.locator(`#parked [data-task="${id}"]`);
  try {
    await page.goto(`${b.url}/?lang=en`);
    await showFleet(page);
    await expect(lane('ready','T-A')).toHaveCount(1);
    await expect(lane('backlog','T-B')).toHaveCount(1);
    // T-118: a card in flight offers both actions, by either path, but the
    // server sets it aside only once the captain has confirmed it
    await page.locator('[data-menu="T-W"]').click();
    await expect(page.locator('[data-task="T-W"] .cacts button')).toHaveText([EN.park, EN.drop]);
    await page.locator('[data-menu="T-W"]').click();
    await expect(page.locator('[data-task="T-W"]')).toHaveAttribute('draggable','true');
    // with the tab's own token (T-122), so the 409 is the board's rule, not a 403
    const refused = await page.evaluate(async () => (await fetch('/tasks',{method:'POST',
      headers:{'content-type':'application/json',authorization:'Bearer '+sessionStorage.getItem('board.token')},body:JSON.stringify({task:'T-W',action:'park'})})).status);
    expect(refused).toBe(409);
    expect(events().some(e => e.type === 'parked')).toBe(false);

    // park by click: the card's menu, then park
    await page.locator('[data-menu="T-A"]').click();
    await expect(page.locator('[data-task="T-A"] .cacts button')).toHaveText([EN.park, EN.drop]);
    await page.locator('[data-task="T-A"] [data-act="park"]').click();
    await expect(parkedCard('T-A')).toHaveCount(1);
    await expect(page.locator('#lanes [data-task="T-A"]')).toHaveCount(0);
    await expect(page.locator('#parked > summary')).toContainText(`${EN.parked} 1`);
    expect(last()).toMatchObject({type:'parked',actor:'captain',task:'T-A'});
    // the group is collapsed until opened
    await expect(page.locator('#parked')).toHaveJSProperty('open', false);
    // its dependent names the parked task as its blocker
    await expect(page.locator('[data-task="T-B"] .dep')).toContainText(`T-A (${EN.parked})`);

    // unpark by click: back to ready, as its (absent) dependencies say
    await page.locator('#parked > summary').click();
    await page.locator('#parked [data-menu="T-A"]').click();
    await expect(page.locator('#parked [data-task="T-A"] .cacts button')).toHaveText([EN.unpark, EN.drop]);
    await page.locator('#parked [data-act="unpark"]').click();
    await expect(lane('ready','T-A')).toHaveCount(1);
    await expect(parkedCard('T-A')).toHaveCount(0);
    expect(last()).toMatchObject({type:'unparked',actor:'captain',task:'T-A'});
    await expect(page.locator('[data-task="T-B"] .dep')).not.toContainText(EN.parked);

    // the click menu is the keyboard path: focus, Enter, Enter
    await page.locator('[data-menu="T-C"]').focus();
    await page.keyboard.press('Enter');
    await expect(page.locator('[data-task="T-C"] [data-act="park"]')).toBeFocused();
    await page.keyboard.press('Enter');
    await expect(parkedCard('T-C')).toHaveCount(1);
    expect(last()).toMatchObject({type:'parked',actor:'captain',task:'T-C'});

    // park by drag, onto the parked group
    await lane('ready','T-A').dragTo(page.locator('#parked > summary'));
    await expect(parkedCard('T-A')).toHaveCount(1);
    await expect(page.locator('#lanes [data-task="T-A"]')).toHaveCount(0);
    expect(last()).toMatchObject({type:'parked',actor:'captain',task:'T-A'});
    // and unpark by drag, back onto the lanes
    if (!(await page.locator('#parked').evaluate(el => (el as HTMLDetailsElement).open)))
      await page.locator('#parked > summary').click();
    await parkedCard('T-A').dragTo(page.locator('[data-lane="ready"]'));
    await expect(lane('ready','T-A')).toHaveCount(1);
    expect(last()).toMatchObject({type:'unparked',actor:'captain',task:'T-A'});

    // drop by click asks first, in the page; cancelling writes nothing
    const before = events().length;
    await page.locator('[data-menu="T-A"]').click();
    await page.locator('[data-task="T-A"] [data-act="drop"]').click();
    await expect(page.locator('#dropConfirm')).toBeVisible();
    await expect(page.locator('#dropConfirm')).toContainText(EN.dropConfirm.replace('{id}','T-A'));
    await expect(page.locator('[data-confirm-drop="T-A"]')).toBeFocused();
    await page.locator('[data-cancel-drop="T-A"]').click();
    await expect(page.locator('#dropConfirm')).toBeHidden();
    await expect(lane('ready','T-A')).toHaveCount(1);
    expect(events().length).toBe(before);
    // and confirming drops it: the closed event, and the task leaves the lanes
    await page.locator('[data-menu="T-A"]').click();
    await page.locator('[data-task="T-A"] [data-act="drop"]').click();
    await page.locator('[data-confirm-drop="T-A"]').click();
    await expect(page.locator('#lanes [data-task="T-A"]')).toHaveCount(0);
    await expect(parkedCard('T-A')).toHaveCount(0);
    await expect(page.locator('#dropConfirm')).toBeHidden();
    expect(last()).toMatchObject({type:'closed',actor:'captain',task:'T-A'});
    await expect(page.locator('[data-task="T-B"] .dep')).toContainText(`T-A (${EN.dropped})`);

    // drop by drag, onto the drop target: the same confirming step
    await lane('ready','T-D').dragTo(page.locator('#dropzone'));
    await expect(page.locator('#dropConfirm')).toContainText(EN.dropConfirm.replace('{id}','T-D'));
    await expect(lane('ready','T-D')).toHaveCount(1);
    await page.locator('[data-confirm-drop="T-D"]').click();
    await expect(page.locator('#lanes [data-task="T-D"]')).toHaveCount(0);
    expect(last()).toMatchObject({type:'closed',actor:'captain',task:'T-D'});

    // an in-flight card dragged onto the drop target asks first, and says its
    // crew will be stopped; cancelling writes nothing
    const n = events().length;
    await page.locator('[data-task="T-W"]').dragTo(page.locator('#dropzone'));
    await expect(page.locator('#dropConfirm')).toBeVisible();
    await expect(page.locator('#dropConfirm')).toContainText(EN.crewStopNote.split('{crew}')[0]);
    await page.locator('[data-cancel-drop="T-W"]').click();
    await expect(page.locator('#dropConfirm')).toBeHidden();
    expect(events().length).toBe(n);

    // labels from the dictionaries, in every locale
    await page.locator('[data-l="zh-TW"]').click();
    await page.locator('[data-menu="T-B"]').click();
    await expect(page.locator('[data-task="T-B"] .cacts button')).toHaveText([TW.park, TW.drop]);
    await expect(page.locator('#parked > summary')).toContainText(TW.parked);
    await expect(page.locator('[data-task="T-B"] .dep')).toContainText(`T-A (${TW.dropped})`);
    await page.locator('[data-l="zh-CN"]').click();
    await expect(page.locator('[data-task="T-B"] .cacts button')).toHaveText([CN_T058.park, CN_T058.drop]);
    await expect(page.locator('#dropzone')).toHaveText(CN_T058.dropZone);
    for (const k of Object.keys(CN_T058)) {
      expect(TW, `no zh-TW entry for ${k}`).toHaveProperty(k);
      expect(EN, `no en entry for ${k}`).toHaveProperty(k);
      expect(await page.evaluate((s) => (window as any).eval('cn')(s), TW[k]), k).toBe((CN_T058 as any)[k]);
    }
    expect([EN.park,EN.unpark,EN.drop,EN.parked]).toEqual(['park','unpark','drop','parked']);
    expect([TW.park,TW.unpark,TW.drop,TW.parked]).toEqual(['擱置','恢復','不做','已擱置']);

    // no browser dialog at any point, and the board never edits the plan
    expect(dialogs).toEqual([]);
    expect(JSON.stringify(readTasks(root))).toBe(plan);
  } finally {await stopBoard(b);}
});

// T-069: every #n the board shows links to that pull request on the
// repository the project registry names, and a press on one is a click on a
// link - never the start of a drag, never the card's menu
