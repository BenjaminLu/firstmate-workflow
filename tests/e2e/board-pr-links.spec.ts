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
test('every pull request number links to its pull request on the registered repository', async ({page}) => {
  test.setTimeout(90_000);
  const root = makeRoot([], false);
  const REPO = 'example-org/linked-app';
  const pull = (n:number) => `https://github.com/${REPO}/pull/${n}`;
  writeRegistry(root, REPO);
  writeTasks(root, [
    {id:'T-A',title:'Not started, with a pull request opened by hand',depends_on:[]},
    {id:'T-W',title:'Waiting on the captain',depends_on:[]},
    {id:'T-M',title:'Merged, after #4',depends_on:[]},
  ]);
  emitFixture(root,'worker-w','T-W','dispatched','On it','接下',
    {role:'worker',crew_name:'Wren',activity:{en:'answering the review on #3','zh-TW':'回覆 #3 的審查'}});
  // the log as the emitter writes it: --pr is a JSON number
  const emitPr = (actor:string, task:string, type:string, pr:number, en:string, tw:string) => {
    const r = spawnSync('bash',[join(root,'bin/fm-emit.sh'),'--actor',actor,'--task',task,'--type',type,
      '--pr',String(pr),'--en',en,'--tw',tw],{env:{...process.env,FM_ROOT:root}});
    expect(r.status, r.stderr.toString()).toBe(0);
  };
  emitPr('worker-w','T-W','pr_opened',8,'opened #8 for T-W','為 T-W 開了 #8');
  emitPr('github','T-M','merged',9,'merged #9','已合併 #9');
  // a line whose numbers are not its own pr, and one with no pr at all
  emitFixture(root,'github','T-W','commit_pushed','pushed to #8, which replaces #5','推到 #8，取代 #5');
  // a number the log holds for a task nobody has started, written by some
  // other tool as a string: its card is ready, so it is draggable and has a
  // menu, and the string is the same number to the server and the page
  appendFileSync(join(root,'state/events.jsonl'), JSON.stringify({ts:'2026-09-21T10:00:00Z',actor:'github',
    task:'T-A',type:'pr_seen',pr:'7',summary:{en:'found #7','zh-TW':'找到 #7'}}) + '\n');
  const said = {en:{...details.en, explanation:'Lands after #6 is in.'},
    'zh-TW':{...details['zh-TW'], explanation:'在 #6 之後合併。'}};
  writeFileSync(join(root,'state/pending/D-8.json'), JSON.stringify({
    id:'D-8', kind:'merge', task:'T-W', pr:8, title:'Merge it', details:said, gates:[1,1,1,1,1,1,0]}));
  const events = () => readFileSync(join(root,'state/events.jsonl'),'utf8').trim().split('\n');
  // nothing leaves the machine: the opened tab gets a local page
  await page.context().route('https://github.com/**', r => r.fulfill({status:200, contentType:'text/html', body:'<title>pull</title>'}));
  const b = await startBoard(root);
  const isLink = async (l: ReturnType<Page['locator']>, n:number) => {
    await expect(l).toHaveCount(1);
    await expect(l).toHaveAttribute('href', pull(n));
    await expect(l).toHaveAttribute('target', '_blank');
    await expect(l).toHaveAttribute('rel', /(^|\s)noreferrer(\s|$)/);
    await expect(l).toContainText(`#${n}`);
  };
  try {
    await page.goto(`${b.url}/?lang=en`);
    const card = (k:string, id:string) => page.locator(`[data-lane="${k}"] [data-task="${id}"]`);
    await expect(card('ready','T-A')).toHaveCount(1);
    // the top right of each lane card
    await isLink(card('ready','T-A').locator('.hd a'), 7);
    await isLink(card('captain','T-W').locator('.hd a'), 8);
    await isLink(card('merged','T-M').locator('.hd a'), 9);
    // the history rows, the decision card, the roster and the log
    await isLink(page.locator('#history .history-cards a.pr'), 9);
    await isLink(page.locator('#card-D-8 .links a[data-pr]'), 8);
    await expect(page.locator('#card-D-8 .links a[data-pr]')).toContainText(`${EN.viewPr} #8`);
    await isLink(page.locator('#roster [data-roster="worker-w"] .rpr a'), 8);
    await isLink(page.locator('#log a', {hasText:'#7'}), 7);
    await expect(page.locator('#log a', {hasText:'#8'})).toHaveCount(2);
    for (const a of await page.locator('#log a', {hasText:'#8'}).all()) await expect(a).toHaveAttribute('href', pull(8));
    await isLink(page.locator('#log a', {hasText:'#9'}), 9);
    // a #n that is not the line's own pr, and one on a line with no pr
    await isLink(page.locator('#log a', {hasText:'#5'}), 5);
    // a #n in a title, a decision's text and a crewman's activity
    await isLink(card('merged','T-M').locator('.t a'), 4);
    await isLink(page.locator('#card-D-8 .explanation a'), 6);
    await isLink(page.locator('#roster [data-roster="worker-w"] .act a'), 3);
    // T-054: a board of one project renders as it always did - no project
    // chip anywhere, on a card, a bubble or a decision
    await expect(page.locator('.pchip')).toHaveCount(0);
    // and no #n anywhere on the page is left as bare text or points elsewhere.
    // The one exception is a decision's option label: it is a <button>, and
    // a link cannot sit inside one. The fixture's options name no #n.
    const stray = await page.evaluate(() => {
      const out: string[] = [];
      const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      for (let n = walk.nextNode(); n; n = walk.nextNode()) {
        const parent = n.parentElement;
        if (!parent || parent.closest('script,style,textarea')) continue;
        for (const m of (n.textContent || '').matchAll(/#(\d+)/g)) {
          const a = parent.closest('a');
          if (!a || a.getAttribute('href') !== `https://github.com/example-org/linked-app/pull/${m[1]}`)
            out.push(`${m[0]} in ${parent.outerHTML.slice(0, 120)}`);
        }
      }
      return out;
    });
    expect(stray).toEqual([]);

    // reachable by keyboard
    const seven = card('ready','T-A').locator('.hd a');
    // reached by the keyboard itself: it sits between the card's id and its
    // menu button, so a Shift+Tab from the menu lands on it
    await page.locator('[data-menu="T-A"]').focus();
    await page.keyboard.press('Shift+Tab');
    await expect(seven).toBeFocused();
    // a click opens the pull request in a new tab, and nothing else happens
    const [tab] = await Promise.all([page.waitForEvent('popup'), seven.click()]);
    await tab.waitForLoadState();
    expect(tab.url()).toBe(pull(7));
    await tab.close();
    await expect(card('ready','T-A').locator('.cacts')).toHaveCount(0);
    await expect(page.locator('[data-menu="T-A"]')).toHaveAttribute('aria-expanded', 'false');
    await expect(page.locator('.lanes-wrap')).not.toHaveClass(/dragging/);
    // a press that starts on the number and moves away does not drag the card
    const before = events().length;
    await seven.dragTo(page.locator('#dropzone'));
    await expect(page.locator('#dropConfirm')).toBeHidden();
    await seven.dragTo(page.locator('#parked > summary'));
    await expect(card('ready','T-A')).toHaveCount(1);
    await expect(page.locator('#parked [data-task="T-A"]')).toHaveCount(0);
    expect(events().length).toBe(before);
    // the card itself still drags: the number is excluded, not the card
    await card('ready','T-A').locator('.t').dragTo(page.locator('#dropzone'));
    await expect(page.locator('#dropConfirm')).toContainText(EN.dropConfirm.replace('{id}','T-A'));
    await page.locator('[data-cancel-drop="T-A"]').click();
    expect(events().length).toBe(before);
  } finally {await stopBoard(b);}
});

test('without a github entry a pull request number is plain text, never a guessed link', async ({page}) => {
  test.setTimeout(60_000);
  const root = makeRoot([], false);
  writeTasks(root, [{id:'T-W',title:'Waiting',depends_on:[]}]);
  emitFixture(root,'worker-w','T-W','dispatched','On it','接下',{role:'worker'});
  appendFileSync(join(root,'state/events.jsonl'), JSON.stringify({ts:'2026-09-21T10:00:00Z',actor:'worker-w',
    task:'T-W',type:'pr_opened',pr:8,summary:{en:'opened #8','zh-TW':'開了 #8'}}) + '\n');
  emitFixture(root,'github','T-W','commit_pushed','pushed, replaces #5','推送，取代 #5');
  writeFileSync(join(root,'state/pending/D-8.json'), JSON.stringify({
    id:'D-8', kind:'merge', task:'T-W', pr:8, title:'Merge it', details, gates:[1,1,1,1,1,1,0]}));
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    await expect(page.locator('[data-task="T-W"] .hd')).toContainText('#8');
    await expect(page.locator('#card-D-8 .links')).toContainText(`${EN.viewPr} #8`);
    await expect(page.locator('#log')).toContainText('opened #8');
    await expect(page.locator('#log')).toContainText('pushed, replaces #5');
    await expect(page.locator('a[data-pr]')).toHaveCount(0);
    await expect(page.locator('a[href*="/pull/"]')).toHaveCount(0);
  } finally {await stopBoard(b);}
});

// T-054: two registered projects live at the same time, with the same task id
// and the same pull request number. Every card, bubble and decision says
// whose it is; one project's answer leaves the other's card where it was; a
// merge runs in the background and the board says so while it does.
