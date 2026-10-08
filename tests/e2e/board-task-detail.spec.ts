import { showFleet } from './lib/board';
import { expect } from '@playwright/test';
import { test, makeRoot, startBoard, stopBoard, writeTasks, writeRegistry, ROOT } from './lib/fixture';
import { appendFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

function fixture() {
  const root = makeRoot([], false);
  const explain = Object.fromEntries(['en','zh-TW'].map(lang => [lang, {
    intent:[{kind:'fact',text:lang==='en'?'The panel shows the plan.':'面板顯示計畫。'}],
    done:[{kind:'fact',text:lang==='en'?'Intent 1: The panel shows the plan.':'意圖 1：面板顯示計畫。'}],
    scope_in:['board/public/index.html'],scope_out:['Merge policy'],
    notes:[{kind:'note',text:lang==='en'?'The task has no run.':'任務尚未執行。'}],
    before_nodes:[{state:'gone',label:'No plan'}],after_nodes:[{state:'new',label:'Read the plan'}]
  }]));
  writeTasks(root,[{id:'T-001',title:'Plan: Read the task.',milestone:'M2',depends_on:[],scope:['tests/plan.test.sh'],acceptance:['The task explains the plan. '.repeat(30)],explain},
    {id:'T-002',title:'Next: Read another task.',depends_on:[],scope:[],acceptance:[]}]);
  return root;
}

test('task panel shares intent sections, keyboard/focus, replacement and persistent disclosures', async ({page}) => {
  const root=fixture(), board=await startBoard(root);
  try {
    await page.goto(board.url+'/?lang=en');
    await showFleet(page);
    const first=page.locator('.card[data-task="T-001"]'), second=page.locator('.card[data-task="T-002"]');
    const panel=page.locator('#taskDetail');
    await first.click();
    await expect(panel).toBeVisible();
    await expect(panel.locator('.intent-header')).toContainText('Plan');
    await expect(panel.locator('.intent-alignment > section > h4')).toHaveText(['Intent','How it works','Alignment','Scope','Notes']);
    await expect(panel.locator(':scope > section > h4')).toHaveText(['Spec','Tests','Progress']);
    expect(await panel.evaluate(el=>el.parentElement===document.getElementById('lanes')?.parentElement)).toBe(true);
    await expect(panel).toContainText('not dispatched yet');
    await panel.locator('[data-acceptance]').click();
    await expect(panel.locator('.acceptance-text').first()).toHaveClass(/expanded/);
    let requests=0;
    page.on('request',r=>{if(new URL(r.url()).pathname==='/api/task') requests++;});
    // An unrelated state update does not refetch or rebuild the open detail.
    appendFileSync(join(root,'state/events.jsonl'), JSON.stringify({type:'greenlit',actor:'captain',ts:new Date().toISOString(),summary:{en:'go','zh-TW':'go'}})+'\n');
    await expect.poll(()=>page.locator('#log').textContent()).toContain('go');
    expect(requests).toBe(0);
    await expect(panel.locator('.acceptance-text').first()).toHaveClass(/expanded/);
    // Changing one of the watched fields causes one fresh task read.
    appendFileSync(join(root,'state/events.jsonl'), JSON.stringify({type:'pr_opened',actor:'worker-imani',task:'T-001',pr:3,ts:new Date().toISOString()})+'\n');
    await expect.poll(()=>requests).toBe(1);
    await expect(panel.locator('.acceptance-text').first()).toHaveClass(/expanded/);
    await second.click();
    await expect(panel.locator('.intent-header')).toContainText('Next');
    await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
    await expect(panel.locator('[data-close-task]')).toBeInViewport();
    await panel.locator('[data-close-task]').click();
    await expect(panel).toBeHidden();
    await expect(second).toBeFocused();
    for(const key of ['Enter','Space']) {
      await first.focus(); await first.press(key);
      await expect(panel).toBeVisible();
      await page.keyboard.press('Escape');
      await expect(panel).toBeHidden();
      await expect(first).toBeFocused();
    }
  } finally { await stopBoard(board); }
});

test('card controls and dragging do not open the panel; 390px has no horizontal overflow', async ({page}) => {
  const root=fixture();
  writeRegistry(root, 'example/tasks');
  writeFileSync(join(root,'state/events.jsonl'),JSON.stringify({type:'pr_opened',actor:'worker-imani',task:'T-001',pr:3,ts:new Date().toISOString()})+'\n');
  const board=await startBoard(root);
  try {
    await page.goto(board.url+'/?lang=en');
    await showFleet(page);
    const first=page.locator('.card[data-task="T-001"]'), panel=page.locator('#taskDetail');
    await first.locator('[data-menu]').click();
    await expect(panel).toBeHidden();
    await page.keyboard.press('Escape');
    const pr=first.locator('[data-pr]');
    await pr.evaluate(el=>el.addEventListener('click',event=>event.preventDefault()));
    await pr.click();
    await expect(panel).toBeHidden();
    await first.dispatchEvent('dragstart',{dataTransfer:await page.evaluateHandle(()=>new DataTransfer())});
    await first.dispatchEvent('dragend');
    await first.dispatchEvent('click');
    await expect(panel).toBeHidden();
    await page.setViewportSize({width:390,height:844});
    await first.click();
    await expect(panel).toBeVisible();
    expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
    expect(await panel.evaluate(el=>el.scrollWidth<=el.clientWidth)).toBe(true);
    await expect(panel.locator('[data-close-task]')).toBeInViewport();
    expect(await panel.evaluate(el=>el.getBoundingClientRect().top>=document.querySelector('.top')!.getBoundingClientRect().bottom)).toBe(true);
  } finally { await stopBoard(board); }
});

test('the main page keeps same-id project cards distinct and reads the newest authored source', async ({page}) => {
  const { writeProjects, projectState } = await import('./lib/fixture');
  const root=fixture();
  writeProjects(root,[{name:'alpha',github:'example/alpha'},{name:'beta',github:'example/beta',tasks:[{id:'T-001',title:'Beta: A separate plan.',depends_on:[],scope:[],acceptance:[]} as any]}]);
  const store=projectState(root,'beta');
  const { details } = await import('./lib/fixture');
  const authored=structuredClone(details) as any;
  for(const lang of ['en','zh-TW']) {
    authored[lang].intent=[{kind:'fact',text:'The newest card supplies this plan.'}];
    authored[lang].done=[{kind:'fact',text:'Intent 1: The newest plan is visible.'}];
  }
  writeFileSync(join(store,'decisions/D-beta-T001-2.json'),JSON.stringify({id:'D-beta-T001-2',project:'beta',task:'T-001',kind:'choice',purpose:'dispatch',chosen:'A',details:authored,ste:{ok:true},ts:'2026-10-01T00:00:00Z'}));
  const older=structuredClone(authored);
  older.en.intent=[{kind:'fact',text:'An older explanation.'}];
  writeFileSync(join(store,'decisions/D-beta-T001-1.json'),JSON.stringify({id:'D-beta-T001-1',project:'beta',task:'T-001',kind:'choice',purpose:'dispatch',chosen:'A',details:older,ste:{ok:false},ts:'2026-09-01T00:00:00Z'}));
  const board=await startBoard(root);
  try {
    await page.goto(board.url+'/?lang=en');
    await showFleet(page);
    const panel=page.locator('#taskDetail');
    await page.locator('.card[data-project="alpha"][data-task="T-001"]').first().click();
    await expect(panel.locator('.intent-header')).toContainText('Plan');
    await expect(panel).toContainText('The panel shows the plan.');
    await page.locator('.card[data-project="beta"][data-task="T-001"]').first().click();
    await expect(panel.locator('.intent-header')).toContainText('Beta');
    await expect(panel).toContainText('The newest card supplies this plan.');
    await expect(panel.locator('.ste-pill')).toContainText('pass');
    await expect(panel).not.toContainText('The panel shows the plan.');
  } finally { await stopBoard(board); }
});

for (const locale of ['en', 'zh-TW']) {
  test(`external review locations and minute refresh stay private (${locale})`, async ({page}) => {
    const { writeProjects, projectState } = await import('./lib/fixture');
    const { spawnSync } = await import('node:child_process');
    const root = fixture();
    writeProjects(root, [{name:'fixture',github:'example/self'},
      {name:'beta',github:'example/beta',tasks:[{id:'T-001',title:'Beta: Review this patch.',depends_on:[],scope:[],acceptance:[]} as any]}]);
    const store = projectState(root, 'beta');
    const appendEvidence = (path: string) => {
      // Shared Python fixture: tests/lib/task_detail_fixture.py
      const result = spawnSync('python3', [join(ROOT,'tests/lib/task_detail_fixture.py'),
        root, store, 'beta', '--external-review-only', path], {encoding:'utf8'});
      expect(result.status, result.stderr).toBe(0);
    };
    appendEvidence('src/x.py');
    const board = await startBoard(root);
    try {
      await page.clock.install({time:new Date('2026-10-08T01:00:00Z')});
      await page.goto(board.url+'/?lang='+locale);
      const panel=page.locator('#taskDetail');
      await page.locator('.card[data-project="beta"][data-task="T-001"]').click();
      const section=panel.locator('[data-detail-section="detailExternalReview"]');
      await expect(section.locator('h4')).toHaveText(locale==='en' ? 'External review' : '外部審查');
      for (const state of ['CHANGES_REQUESTED','APPROVED','COMMENTED','UNKNOWN'])
        await expect(section.locator('.badge', {hasText:state})).toBeVisible();
      for (const label of locale==='en'
        ? ['Covers this patch','Older patch','Current head','Unresolved','Resolved','No cited line']
        : ['涵蓋此修補','較舊修補','目前版本','未解決','已解決','未引用行號'])
        await expect(section).toContainText(label);
      await expect(section).toContainText('src/x.py:9');
      await expect(panel).not.toContainText('SECRET-EXTERNAL-BODY');
      let requests=0;
      page.on('request',r=>{if(new URL(r.url()).pathname==='/api/task') requests++;});
      const event = (label: string) => appendFileSync(join(root,'state/events.jsonl'), JSON.stringify({
        type:'greenlit',actor:'captain',ts:new Date().toISOString(),summary:{en:label,'zh-TW':label}})+'\n');
      appendEvidence('src/changed.py');
      event('before-minute');
      await expect.poll(()=>page.locator('#log').textContent()).toContain('before-minute');
      expect(requests).toBe(0);
      await page.clock.fastForward(60_000);
      event('after-minute');
      await expect(section).toContainText('src/changed.py:9');
      expect(requests).toBe(1);
      event('same-minute');
      await expect.poll(()=>page.locator('#log').textContent()).toContain('same-minute');
      expect(requests).toBe(1);
      await page.locator('.card[data-project="fixture"][data-task="T-001"]').click();
      await expect(panel.locator(':scope > section > h4')).toHaveText(locale==='en'
        ? ['Spec','Tests','Progress'] : ['規格','測試','進度']);
      requests=0;
      await page.clock.fastForward(60_000);
      event('self-minute');
      await expect.poll(()=>page.locator('#log').textContent()).toContain('self-minute');
      expect(requests).toBe(0);
    } finally { await stopBoard(board); }
  });
}
