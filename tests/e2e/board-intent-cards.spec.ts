import { expect } from '@playwright/test';
import { test, makeRoot, startBoard, stopBoard, details, writeTasks, writeProjects, projectState } from './lib/fixture';
import { intentCard } from './lib/intent-card';
import { writeFileSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';

for (const missingRules of [false, true]) test(`intent sections and stored chips; rules ${missingRules ? 'absent' : 'present'}`, async ({page}) => {
  const root = makeRoot([], false), d = intentCard();
  writeTasks(root,[{id:'T-211',title:'Intent cards',depends_on:[]}]);
  writeFileSync(join(root,'state/pending/D-211.json'), JSON.stringify(d));
  writeFileSync(join(root,'state/pending/D-212.json'), JSON.stringify({id:'D-212',kind:'choice',details}));
  if (missingRules) rmSync(join(root,'bin/lib/fm_ste.py'));
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    const card = page.locator('#card-D-211');
    await expect(card.locator('.intent-alignment')).toBeVisible();
    for (const text of ['Intent', 'How it works', 'Alignment', 'Board cards', 'Other pages', 'The card shows the result.', 'Check the scope.', 'Do not dispatch yet.']) await expect(card).toContainText(text);
    await expect(card.locator('.ste-pill')).toHaveText('STE · 6/7');
    await expect(card.locator('.ste-chip').first()).toContainText('17/20');
    await expect(card.locator('.ste-sentence').filter({hasText:'The card stays small.'}).locator('.ste-chip')).toContainText('4/20');
    await expect(card.locator('[data-rule="R3"]')).toHaveAttribute('title',missingRules ? 'R3' : 'R3 — Use one instruction per step.');
    const state = await (await page.request.get(`${b.url}/api/state`)).json();
    if (missingRules) expect(state.ste_rules).toEqual([]);
    else expect(state.ste_rules).toContainEqual({id:'R3',en:'Use one instruction per step.','zh-TW':'每個步驟只寫一個指令。'});
    await expect(card.locator('script')).toHaveCount(0);
    await expect(page.locator('#card-D-212 .intent-alignment')).toHaveCount(0);
    await card.locator('[data-c="A"]').click();
    await expect(card.locator('.confirm')).toBeDisabled();
    await card.locator('[data-question="0"][data-ok="yes"]').click();
    await expect(card.locator('.confirm')).toBeDisabled();
    await card.locator('[data-question="1"][data-ok="no"]').click();
    const correction = card.locator('textarea[data-question="1"]');
    await expect(correction).toBeVisible();
    await correction.fill('🚢'.repeat(1001));
    await expect(card.locator('.confirm')).toBeDisabled();
    await correction.fill('  Change the scope 🚢  ');
    await expect(card.locator('.confirm')).toBeEnabled();
    await page.locator('[data-l="zh-CN"]').click();
    await expect(card).toContainText('检查任务修改。');
    await expect(card.locator('.ste-pill')).toHaveText('STE · 2/3');
    await expect(card.locator('[data-rule="Z2"]')).toHaveAttribute('title',missingRules ? 'Z2' : 'Z2 — 每个步驟只写一个动作。');
    await expect(correction).toHaveValue('  Change the scope 🚢  ');
    await page.locator('[data-l="en"]').click();
    expect(await page.evaluate(() => (window as any).VOYAGE?.hidden)).not.toBe(true);
    const response = page.waitForResponse(r=>r.url().endsWith('/decisions') && r.request().method()==='POST');
    await card.locator('.confirm').click();
    const r = await response;
    expect(r.request().postDataJSON().answers).toEqual([{index:0,ok:true},{index:1,ok:false,text:'  Change the scope 🚢  '}]);
    await expect(page.locator('#orderFeedback')).toHaveText('Change requested — firstmate revises the spec');
    await expect(card).toHaveCount(0);
    const stored = JSON.parse(readFileSync(join(root,'state/decisions/D-211.json'),'utf8'));
    expect(stored).toMatchObject({chosen:'change',picked:'A',effect:null,merge:null});
    await page.evaluate(async () => (window as any).render(await (await fetch('/api/state')).json()));
    await expect(page.locator('#orderFeedback')).not.toContainText('AYE, CAPTAIN');
    await expect(page.locator('#capstage')).not.toHaveAttribute('data-pose', 'order');
  } finally {await stopBoard(b);}
});

test('intent card without a report renders without chips and read-only controls stay locked', async ({page, browser}) => {
  const root=makeRoot([],false), d:any=intentCard(); delete d.ste;
  writeFileSync(join(root,'state/pending/D-211.json'),JSON.stringify(d));
  const b=await startBoard(root);
  const context=await browser.newContext(), guest=await context.newPage();
  try {
    await guest.goto(`${b.url}/?lang=en`);
    await expect(guest.locator('.intent-alignment')).toBeVisible();
    await expect(guest.locator('.ste-chip,.ste-pill')).toHaveCount(0);
    for (const control of await guest.locator('[data-question]').all()) await expect(control).toBeDisabled();
  } finally {await context.close(); await stopBoard(b);}
});

test('external change outcomes keep chosen on the main page', async ({page}) => {
  const root=makeRoot([],false);
  writeProjects(root,[{name:'engine',github:'fixtures/engine'},{name:'external',github:'fixtures/external',tasks:[{id:'T-211'}]}]);
  const dir=projectState(root,'external');
  writeFileSync(join(dir,'decisions/D-external-T211-1.json'),JSON.stringify({id:'D-external-T211-1',project:'external',task:'T-211',chosen:'change',picked:'A',identity:'decision:D-external-T211-1',merge:null,effect:null,effect_outcome:'recorded'}));
  writeFileSync(join(dir,'events.jsonl'),JSON.stringify({type:'decision_made',project:'external',task:'T-211',data:{decision:'D-external-T211-1',chosen:'change'},summary:{en:'change','zh-TW':'修改'}})+'\n');
  const b=await startBoard(root);
  try {
    const state=await (await page.request.get(`${b.url}/api/state`)).json();
    const outcomes=state.outcomes.filter((e:any)=>e.project==='external' && e.type==='decision_made');
    expect(outcomes.length).toBeGreaterThanOrEqual(2);
    for (const e of outcomes) expect(e.chosen).toBe('change');
    await page.goto(`${b.url}/?lang=en`);
  } finally {await stopBoard(b);}
});

test('all Yes still needs a valid custom pick; submitted question controls lock', async ({page}) => {
  const root=makeRoot([],false), d=intentCard();
  writeFileSync(join(root,'state/pending/D-211.json'),JSON.stringify(d));
  const b=await startBoard(root);
  let release=()=>{};
  const held=new Promise<void>(resolve=>{ release=resolve; });
  try {
    await page.goto(`${b.url}/?lang=en`);
    const card=page.locator('#card-D-211');
    await card.locator('[data-question="0"][data-ok="yes"]').click();
    await card.locator('[data-question="1"][data-ok="yes"]').click();
    await expect(card.locator('.confirm')).toBeDisabled();
    await card.locator('[data-c="custom"]').click();
    await expect(card.locator('.confirm')).toBeDisabled();
    await card.locator('textarea:not([data-question])').fill('My choice');
    await expect(card.locator('.confirm')).toBeEnabled();
    await page.route('**/decisions',async route=>{await held; await route.continue();});
    await card.locator('.confirm').click();
    for (const control of await card.locator('[data-question]').all()) await expect(control).toBeDisabled();
    await expect(page.locator('#capstage')).toHaveAttribute('data-pose','order');
    release();
    await expect(card).toHaveCount(0);
    const decision=JSON.parse(readFileSync(join(root,'state/decisions/D-211.json'),'utf8'));
    expect(decision).toMatchObject({chosen:'custom',text:'My choice',answers:[{index:0,ok:true},{index:1,ok:true}]});
    await expect(page.locator('#orderFeedback')).toContainText('AYE, CAPTAIN!');
  } finally {release(); await stopBoard(b);}
});
