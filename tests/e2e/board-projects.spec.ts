// The board, in a browser. Poses are asserted as classes and text as
// dictionary values, never as screenshots: a snapshot test of a ship that
// moves would fail on the animation and pass on the wrong crew.
import { expect, type Page } from "@playwright/test";
// `test` is the fixture's: every board a test starts is signed in to (T-122)
import { test, makeRoot, startBoard, stopBoard, writeRegistry, writeProjects, projectState, readTasks, writeTasks, ROOT, details, scriptHeaders, signInAddress, tabToken } from "./lib/fixture";
import { appendFileSync, readFileSync, existsSync, writeFileSync, rmSync, utimesSync, mkdirSync, chmodSync, unlinkSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { EN, TW, CN, T040_KEYS, T057_KEYS, CN_ACTIVITY, CN_DETAILS, CREW, emitFixture, emit, CN_T058, useBoard } from "./lib/board";
test('two projects on one board: chips everywhere, one answer leaves the other card, a merge runs in the background', async ({page}) => {
  test.setTimeout(90_000);
  const root = makeRoot([], false);
  writeProjects(root, [
    {name:'alpha', github:'example-org/alpha-app'},
    {name:'beta', github:'example-org/beta-app', tasks:[{id:'T-001',title:'beta one',depends_on:[]}]},
  ]);
  writeTasks(root, [{id:'T-001',title:'alpha one',depends_on:[]}]);
  const emitIn = (project:string|null, actor:string, task:string, type:string, pr:number|null, data:object) => {
    const r = spawnSync('bash',[join(root,'bin/fm-emit.sh'),'--actor',actor,'--task',task,'--type',type,
      ...(project ? ['--project',project] : []), ...(pr ? ['--pr',String(pr)] : []),
      '--data',JSON.stringify(data),'--en',`${type} ${task}`,'--tw',`${type} ${task}`],{env:{...process.env,FM_ROOT:root}});
    expect(r.status, r.stderr.toString()).toBe(0);
  };
  emitIn(null,'worker-a','T-001','dispatched',null,{role:'worker',crew_name:'Ada'});
  emitIn('beta','worker-b','T-001','dispatched',null,{role:'worker',crew_name:'Bo'});
  emitIn(null,'worker-a','T-001','pr_opened',7,{});
  emitIn('beta','worker-b','T-001','pr_opened',7,{});
  // beta's card was asked for first, so it leads the one list
  const card = (id:string, project:string) => {
    const file = join(projectState(root, project),`pending/${id}.json`);
    writeFileSync(file, JSON.stringify({id, project, task:'T-001', kind:'merge', pr:7, details, gates:[1,1,1,1,1,1,1]}));
    return file;
  };
  const older = card('D-beta-T001-1','beta'), newer = card('D-alpha-T001-1','alpha');
  utimesSync(older, new Date('2026-09-24T09:00:00Z'), new Date('2026-09-24T09:00:00Z'));
  utimesSync(newer, new Date('2026-09-24T09:05:00Z'), new Date('2026-09-24T09:05:00Z'));
  await page.context().route('https://github.com/**', r => r.fulfill({status:200, contentType:'text/html', body:'<title>pull</title>'}));
  const b = await startBoard(root);
  const hold = join(root,'hold-merge');
  try {
    await page.goto(`${b.url}/?lang=en`);
    // lane cards: two T-001s, each with its project's chip and its own #7, each
    // in the captain's lane for its own project's merge card
    const lane = (p:string) => page.locator(`[data-lane="captain"] [data-task="T-001"][data-project="${p}"]`);
    for (const [p, repo] of [['alpha','alpha-app'],['beta','beta-app']]) {
      await expect(lane(p)).toHaveCount(1);
      await expect(lane(p).locator('.pchip')).toHaveText(p);
      await expect(lane(p).locator('.pchip')).toHaveAttribute('title', EN.projectChip);
      await expect(lane(p).locator('.hd a[data-pr]')).toHaveAttribute('href', `https://github.com/example-org/${repo}/pull/7`);
    }
    await expect(lane('alpha').locator('.t')).toHaveText('alpha one');
    await expect(lane('beta').locator('.t')).not.toContainText('beta one');
    // crew bubbles: each crewman says whose task it is on
    await expect(page.locator('[data-bubble="worker-a"] .pchip')).toHaveText('alpha');
    await expect(page.locator('[data-bubble="worker-b"] .pchip')).toHaveText('beta');
    // decision cards: every project's in one list, oldest first, each with its chip
    await expect(page.locator('#pcount')).toHaveText('2');
    await expect(page.locator('#deck > .dcard')).toHaveAttribute('id', 'card-D-beta-T001-1');
    await expect(page.locator('#card-D-beta-T001-1 > .meta .pchip')).toHaveText('beta');
    await expect(page.locator('#card-D-beta-T001-1 .links a[data-pr]')).toHaveAttribute('href', 'https://github.com/example-org/beta-app/pull/7');
    await expect(page.locator('#strip-D-alpha-T001-1 > summary .pchip')).toHaveText('alpha');
    // the chip's label is the dictionary's; the name is data and stays as written
    await page.locator('#langs [data-l="zh-TW"]').click();
    await expect(lane('beta').locator('.pchip')).toHaveAttribute('title', TW.projectChip);
    await expect(lane('beta').locator('.pchip')).toHaveText('beta');
    await page.locator('#langs [data-l="en"]').click();

    // answer beta's merge while its helper is held: the answer comes back, the
    // board says the merge is running, and alpha's card is still pending
    await page.goto(`${b.url}/?lang=en&project=beta`);
    writeFileSync(hold, '');
    await page.locator('#card-D-beta-T001-1 [data-c="A"]').click();
    await page.locator('#card-D-beta-T001-1 .confirm').click();
    await expect(page.locator('#merging-D-beta-T001-1')).toContainText(EN.mergeRunning, {timeout:15_000});
    await expect(page.locator('#merging-D-beta-T001-1 .pchip')).toHaveText('beta');
    await expect(page.locator('#card-D-beta-T001-1')).toHaveCount(0);
    expect(existsSync(join(root, 'state/pending/D-alpha-T001-1.json'))).toBe(true);
    // The selected project has no pending cards; the badge renders zero as empty.
    await expect(page.locator('#pcount')).toHaveText('');
    await expect.poll(() => existsSync(b.recorder) ? readFileSync(b.recorder,'utf8') : '', {timeout:15_000})
      .toContain('--project beta');
    expect(JSON.parse(readFileSync(join(projectState(root, 'beta'),'decisions/D-beta-T001-1.json'),'utf8')).merge).toBe('running');
    // the helper finishes: the record says merged and the board stops saying running
    rmSync(hold);
    await expect(page.locator('#merging-D-beta-T001-1')).toHaveCount(0, {timeout:15_000});
    await expect.poll(() => JSON.parse(readFileSync(join(projectState(root, 'beta'),'decisions/D-beta-T001-1.json'),'utf8')).merge,
      {timeout:15_000}).toBe('merged');
    expect(existsSync(join(root, 'state/pending/D-alpha-T001-1.json'))).toBe(true);

    // ?project= shows one project: its cards, its crew and its count
    await page.goto(`${b.url}/?lang=en&project=alpha`);
    await expect(page.locator('[data-task="T-001"]')).toHaveCount(1);
    await expect(page.locator('[data-task="T-001"]')).toHaveAttribute('data-project', 'alpha');
    await expect(page.locator('[data-bubble="worker-b"]')).toHaveCount(0);
    await expect(page.locator('[data-bubble="worker-a"]')).toHaveCount(1);
    await expect(page.locator('#pcount')).toHaveText('1');
  } finally { rmSync(hold, {force:true}); stopBoard(b); }
});

// T-054: a project with nothing on the board but its task list - no crew, no
// card, no answer - is still a project on the board: its lane cards carry its
// chip, and so do the default project's beside them
test('a project on the board only through its lane cards still gets its chip', async ({page}) => {
  const root = makeRoot([], false);
  writeProjects(root, [
    {name:'alpha', github:'example-org/alpha-app'},
    {name:'beta', github:'example-org/beta-app', tasks:[{id:'T-001',title:'beta one',depends_on:[]}]},
  ]);
  writeTasks(root, [{id:'T-001',title:'alpha one',depends_on:[]}]);
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    const card = (p:string) => page.locator(`[data-task="T-001"][data-project="${p}"]`);
    await expect(card('beta')).toHaveCount(1);
    await expect(card('beta').locator('.pchip')).toHaveText('beta');
    await expect(card('alpha').locator('.pchip')).toHaveText('alpha');
  } finally { stopBoard(b); }
});

// T-054: park, unpark and drop are addressed by the card's key, its project
// and its id. Two projects each have an untouched T-001; every path the page
// offers - the menu, the confirming step, Escape and cancel, and drag - acts
// on the card it started from and never on the other project's T-001.
test('two projects with the same task id: menu, drop confirmation and drag act only on the card they started from', async ({page}) => {
  test.setTimeout(90_000);
  const root = makeRoot([], false);
  writeProjects(root, [
    {name:'alpha', github:'example-org/alpha-app'},
    {name:'beta', github:'example-org/beta-app', tasks:[{id:'T-001',title:'beta one',depends_on:[]},{id:'T-002',title:'beta two',depends_on:[]}]},
  ]);
  writeTasks(root, [
    {id:'T-001',title:'alpha one',depends_on:[]},{id:'T-002',title:'alpha two',depends_on:[]}]);
  const events = () => ['alpha', 'beta'].flatMap(p => { const file = join(projectState(root, p), 'events.jsonl'); return existsSync(file) ? readFileSync(file,'utf8').trim().split('\n').filter(Boolean).map(l => JSON.parse(l)) : []; });
  const acted = () => events().filter(e => e.actor === 'captain' && ['parked','unparked','closed'].includes(e.type));
  const b = await startBoard(root);
  const dialogs: string[] = [];
  page.on('dialog', d => { dialogs.push(d.type()); d.dismiss().catch(() => {}); });
  const inLane = (k:string, p:string, id:string) => page.locator(`[data-lane="${k}"] [data-task="${id}"][data-project="${p}"]`);
  const parked = (p:string, id:string) => page.locator(`#parked [data-task="${id}"][data-project="${p}"]`);
  const menu = (p:string, id:string) => page.locator(`.cmenu[data-key="${p}/${id}"]`);
  try {
    await page.goto(`${b.url}/?lang=en`);
    for (const p of ['alpha','beta']) for (const id of ['T-001','T-002']) await expect(inLane('ready',p,id)).toHaveCount(1);

    // the menu and its confirming step name beta's card, and Escape and
    // cancel hand focus back to beta's menu button, not alpha's
    await menu('beta','T-001').click();
    await expect(page.locator('.cacts [data-key="beta/T-001"]')).toHaveText([EN.park, EN.drop]);
    await expect(page.locator('.cacts [data-key="alpha/T-001"]')).toHaveCount(0);
    await page.keyboard.press('Escape');
    await expect(menu('beta','T-001')).toBeFocused();
    await menu('beta','T-001').click();
    await page.locator('.cacts [data-key="beta/T-001"][data-act="drop"]').click();
    await expect(page.locator('#dropConfirm')).toContainText(EN.dropConfirm.replace('{id}','T-001'));
    await expect(page.locator('#dropConfirm .pchip')).toHaveText('beta');
    await page.locator('[data-cancel-drop][data-key="beta/T-001"]').click();
    await expect(page.locator('#dropConfirm')).toBeHidden();
    await expect(menu('beta','T-001')).toBeFocused();
    await menu('beta','T-001').click();
    await page.locator('.cacts [data-key="beta/T-001"][data-act="drop"]').click();
    await expect(page.locator('#dropConfirm .pchip')).toHaveText('beta');
    await page.keyboard.press('Escape');
    await expect(page.locator('#dropConfirm')).toBeHidden();
    await expect(menu('beta','T-001')).toBeFocused();
    expect(acted()).toEqual([]);

    // confirming drops beta's T-001 alone
    await menu('beta','T-001').click();
    await page.locator('.cacts [data-key="beta/T-001"][data-act="drop"]').click();
    await page.locator('[data-confirm-drop][data-key="beta/T-001"]').click();
    await expect(page.locator('#lanes [data-task="T-001"][data-project="beta"]')).toHaveCount(0);
    await expect(inLane('ready','alpha','T-001')).toHaveCount(1);
    expect(acted()).toMatchObject([{type:'closed',task:'T-001',project:'beta'}]);

    // park by drag: beta's T-002 goes to parked, alpha's T-002 stays ready
    await inLane('ready','beta','T-002').dragTo(page.locator('#parked > summary'));
    await expect(parked('beta','T-002')).toHaveCount(1);
    await expect(inLane('ready','alpha','T-002')).toHaveCount(1);
    await expect(parked('alpha','T-002')).toHaveCount(0);
    expect(acted()).toMatchObject([{type:'closed',project:'beta'},{type:'parked',task:'T-002',project:'beta'}]);

    // and the default project's card, dragged the same way, writes no project
    await inLane('ready','alpha','T-002').dragTo(page.locator('#parked > summary'));
    await expect(parked('alpha','T-002')).toHaveCount(1);
    await expect(parked('beta','T-002')).toHaveCount(1);
    const last = acted().filter(e => !e.project).at(-1);
    expect(last).toMatchObject({type:'parked',task:'T-002'});
    expect(last).not.toHaveProperty('project');
    expect(dialogs).toEqual([]);
  } finally { stopBoard(b); }
});

// T-054: with only the default project in the log the board renders as it
// always did - a card whose id names its owner, a crew bubble, a history
// card, a running merge and the drop confirmation all without a project
// chip - and a merge whose outcome GitHub cannot tell says so by name
test('a board of one project shows no project chip anywhere, and says a merge outcome is unknown', async ({page}) => {
  test.setTimeout(90_000);
  const root = makeRoot([], false);
  writeRegistry(root, 'example-org/solo-app');   // one project, `fixture`, the default
  writeTasks(root, [
    {id:'T-1',title:'at work',depends_on:[]},
    {id:'T-2',title:'not started',depends_on:[]},
    {id:'T-3',title:'already in',depends_on:[]},
  ]);
  emitFixture(root,'worker-a','T-1','dispatched','On it','接下',{role:'worker',crew_name:'Ada'});
  emitFixture(root,'github','T-3','merged','merged','已合併');
  // the default project named explicitly, in the id and on the record
  const owned = 'D-fixture-T1-1';
  writeFileSync(join(root,`state/pending/${owned}.json`), JSON.stringify({id:owned,project:'fixture',task:'T-1',kind:'choice',details}));
  // a merge answered earlier: its helper is gone, the log says nothing, and
  // gh fails the way gh fails
  mkdirSync(join(root,'state/decisions'), {recursive:true});
  writeFileSync(join(root,'state/decisions/D-fixture-T4-1.json'), JSON.stringify({id:'D-fixture-T4-1',chosen:'A',
    project:'fixture',task:'T-4',pr:44,kind:'merge',ts:'2026-01-01T00:00:00.000Z',identity:'decision:D-fixture-T4-1',merge:'running'}));
  const gh = join(root,'bin/gh');
  writeFileSync(gh, '#!/usr/bin/env bash\necho "HTTP 502: Bad Gateway (https://api.github.com/graphql)" >&2\nexit 1\n');
  chmodSync(gh, 0o755);
  const b = await startBoard(root, {FM_GH: gh});
  try {
    await page.goto(`${b.url}/?lang=en`);
    await expect(page.locator('[data-task="T-1"]')).toHaveCount(1);
    await expect(page.locator('[data-bubble="worker-a"]')).toHaveCount(1);
    await expect(page.locator('#history .history-cards .card', {hasText:'T-3'})).toHaveCount(1);
    // the owned id shows its project as it did before this task: plain text
    await expect(page.locator(`#card-${owned} > .meta`)).toHaveText(`${owned} · fixture · T-1`);
    await expect(page.locator(`#card-${owned} > .meta .project`)).toHaveAttribute('class', 'project');
    // the merge whose outcome GitHub could not tell: named, and marked unknown
    const row = page.locator('#merging-D-fixture-T4-1');
    await expect(row).toHaveClass(/unknown/, {timeout:15_000});
    await expect(row).toContainText(EN.mergeUnknown);
    expect(JSON.parse(readFileSync(join(root,'state/decisions/D-fixture-T4-1.json'),'utf8')).merge).toBe('running');
    await page.locator('#langs [data-l="zh-TW"]').click();
    await expect(row).toContainText(TW.mergeUnknown);
    await page.locator('#langs [data-l="en"]').click();
    // the drop confirmation, open
    await page.locator('[data-menu="T-2"]').click();
    await page.locator('.cacts [data-act="drop"]').click();
    await expect(page.locator('#dropConfirm')).toContainText(EN.dropConfirm.replace('{id}','T-2'));
    // and not one chip on any of it
    await expect(page.locator('.pchip')).toHaveCount(0);
    await page.locator('[data-cancel-drop="T-2"]').click();
  } finally {stopBoard(b);}
});

// T-054: one merge at a time within a project. A second answered while the
// first runs is refused on the page: the card stays in the deck, its options
// work again, nothing is written and the helper is not called
