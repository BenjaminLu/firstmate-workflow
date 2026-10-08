import { expect } from '@playwright/test';
import { test, makeRoot, startBoard, stopBoard, writeTasks } from './lib/fixture';
import { changePointCard } from './lib/intent-card';
import { writeFileSync, readFileSync, existsSync } from 'node:fs';
import { showFleet } from './lib/board';
import { join } from 'node:path';

for (const kind of ['one-way','two-way'] as const) test(`${kind} evidence walk starts with closed code`, async ({page}) => {
  const root = makeRoot([], false), d = changePointCard(kind);
  writeTasks(root,[{id:'T-211',title:'Record walk',depends_on:[]}]);
  writeFileSync(join(root,'state/pending/D-9242.json'),JSON.stringify(d));
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    const card = page.locator('#card-D-9242');
    await expect(card.locator('.change-point')).toHaveCount(2);
    await expect(card.locator('.change-code[open]')).toHaveCount(0);
    await expect(card.locator('.change-tests a')).toHaveCount(2);
    const merge = card.locator('[data-c="A"]');
    if (kind === 'one-way') {
      await expect(merge).toBeDisabled();
      await card.locator('[data-review-intent="1"]').check();
      await card.locator('[data-review-intent="2"]').check();
      await card.locator('[data-door-answer="1"]').click();
      await expect(card.locator('.door-feedback')).toContainText('Keep the saved records.');
      await expect(merge).toBeDisabled();
      await card.locator('[data-door-answer="0"]').click();
      await expect(merge).toBeEnabled();
      await expect(card.locator('.change-code[open]')).toHaveCount(0);
      await card.locator('[data-review-intent="1"]').uncheck();
      await expect(merge).toBeDisabled();
      await card.locator('[data-review-intent="1"]').check();
      await expect(merge).toBeEnabled();
    } else await expect(merge).toBeEnabled();
    await card.locator('.change-code summary').first().click();
    await expect(card.locator('.change-code[open]')).toHaveCount(1);
    await expect(card.locator('.change-code[open] pre')).toContainText('saved_records()');
    await card.locator('.change-code summary').first().click();
    await expect(card.locator('.change-code[open]')).toHaveCount(0);
    if (kind === 'two-way') {
      await merge.click(); await card.locator('.confirm').click();
      await expect.poll(()=>existsSync(join(root,'state/decisions/D-9242.json'))).toBe(true);
      expect(JSON.parse(readFileSync(join(root,'state/decisions/D-9242.json'),'utf8')).check_ok).toBeUndefined();
    }
  } finally { await stopBoard(b); }
});

for (const locale of ['en','zh-TW']) for (const status of [400,409]) test(`${locale} final ${status} retains confirmation and retries`, async ({page}) => {
  const root = makeRoot([], false), d = changePointCard();
  writeFileSync(join(root,'state/pending/D-9242.json'),JSON.stringify(d));
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=${locale}`);
    const card = page.locator('#card-D-9242');
    await card.locator('[data-review-intent="1"]').check();
    await card.locator('[data-review-intent="2"]').check();
    await card.locator('[data-door-answer="0"]').click();
    await expect(card.locator('[data-c="A"]')).toBeEnabled();
    await card.locator('[data-c="A"]').click();
    await page.route('**/decisions',route=>route.fulfill({status,contentType:'application/json',body:JSON.stringify({ok:false,code:'doorUnconfirmed',why:locale==='en'?'Check again.':'請再確認。'})}));
    await card.locator('.confirm').click();
    await expect(card).toBeVisible();
    await expect(card.locator('[data-review-intent="1"]')).toBeChecked();
    await expect(card.locator('[data-review-intent="2"]')).toBeChecked();
    await expect(card.locator('[data-c="A"]')).toHaveAttribute('aria-pressed','true');
    await expect(card.locator('[data-door-answer="0"]')).toHaveAttribute('aria-pressed','true');
    await expect(card.locator('.confirm')).toBeDisabled();
    await page.unroute('**/decisions');
    await card.locator('[data-door-answer="0"]').click();
    await expect(card.locator('.confirm')).toBeEnabled();
    await card.locator('.confirm').click();
    await expect.poll(()=>existsSync(join(root,'state/decisions/D-9242.json'))).toBe(true);
    expect(JSON.parse(readFileSync(join(root,'state/decisions/D-9242.json'),'utf8')).check_ok).toBe(true);
    await expect.poll(()=>existsSync(join(root,'merge-calls'))).toBe(true);
    expect(readFileSync(join(root,'merge-calls'),'utf8').trim().split('\n')).toHaveLength(1);
  } finally { await stopBoard(b); }
});


test('stale correct confirmation cannot unlock changed input', async ({page}) => {
  const root = makeRoot([], false);
  writeFileSync(join(root,'state/pending/D-9242.json'),JSON.stringify(changePointCard()));
  const b = await startBoard(root);
  try {
    let release!: () => void;
    const held = new Promise<void>(resolve => { release = resolve; });
    let captured!: () => void;
    const seen = new Promise<void>(resolve => { captured = resolve; });
    await page.route('**/decisions/check-door',async route => {
      if (route.request().postDataJSON().check_answer === 0) {
        captured(); await held;
        await route.fulfill({status:200,contentType:'application/json',body:JSON.stringify({ok:true,id:'D-9242'})});
      } else await route.continue();
    });
    await page.goto(b.url+'/?lang=en');
    const card = page.locator('#card-D-9242'), merge = card.locator('[data-c="A"]');
    await card.locator('[data-review-intent="1"]').check();
    await card.locator('[data-review-intent="2"]').check();
    const staleResponse = page.waitForResponse(r=>new URL(r.url()).pathname==='/decisions/check-door' && r.request().postDataJSON().check_answer===0);
    await card.locator('[data-door-answer="0"]').click(); await seen;
    await card.locator('[data-door-answer="1"]').click();
    await expect(card.locator('.door-feedback')).toContainText('Keep the saved records.');
    release(); await (await staleResponse).finished();
    await page.evaluate(()=>new Promise<void>(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve()))));
    await expect(merge).toBeDisabled();
    await page.unroute('**/decisions/check-door');
    await card.locator('[data-door-answer="0"]').click();
    await expect(merge).toBeEnabled();
  } finally { await stopBoard(b); }
});

for (const withCard of [true,false]) test(`Fleet detail walk is read-only, refs=${withCard}`, async ({page}) => {
  const root = makeRoot([],false), d = changePointCard();
  const fields = ['intent','why','scope_in','scope_out','done','notes','before_nodes','after_nodes','change_points','door','check'];
  const explain = Object.fromEntries(['en','zh-TW'].map(locale=>[locale,Object.fromEntries(fields.filter(k=>k in d.details[locale]).map(k=>[k,d.details[locale][k]]))]));
  writeTasks(root,[{id:'T-211',title:'Record walk',depends_on:[],explain}]);
  if (withCard) writeFileSync(join(root,'state/pending/D-9242.json'),JSON.stringify(d));
  const b = await startBoard(root);
  try {
    await page.goto(b.url+'/?lang=en'); await showFleet(page);
    await page.locator('#lanes .card[data-task="T-211"]').click();
    const detail = page.locator('#taskDetail');
    await expect(detail).toBeVisible();
    await expect(detail.locator('.change-how')).toHaveCount(2);
    await expect(detail.locator('[data-review-intent]')).toHaveCount(0);
    await expect(detail.locator('[data-door-answer]')).toHaveCount(0);
    await expect(detail.locator('.door-badge')).toContainText('One-way');
    await expect(detail.locator('.change-tests a')).toHaveCount(withCard ? 2 : 0);
    await expect(detail.locator('.change-code')).toHaveCount(withCard ? 2 : 0);
    await expect(detail.locator('.change-code[open]')).toHaveCount(0);
    await detail.locator('[data-close-task]').click();
    await expect(detail).toBeHidden();
  } finally { await stopBoard(b); }
});

test('authenticated voyage command refuses a one-way merge and main card completes it', async ({page}) => {
  const root = makeRoot([],false);
  writeTasks(root,[{id:'T-211',title:'Record walk',depends_on:[]}]);
  writeFileSync(join(root,'state/pending/D-9242.json'),JSON.stringify(changePointCard()));
  const b = await startBoard(root);
  try {
    await page.goto(b.url+'/?lang=en');
    await expect.poll(()=>page.frames().find(f=>f.url().includes('/voyage2d/'))?.evaluate(()=>(window as any).__G?.ready)).toBe(true);
    const frame = page.frames().find(f=>f.url().includes('/voyage2d/'))!;
    const before = readFileSync(join(root,'state/events.jsonl'),'utf8');
    const request = page.waitForRequest(r=>r.method()==='POST' && new URL(r.url()).pathname==='/decisions');
    const response = page.waitForResponse(r=>r.request().method()==='POST' && new URL(r.url()).pathname==='/decisions');
    const result = await frame.evaluate(async()=> (window as any).__voyageLive.command({type:'answer',decision:'D-9242',chosen:'A'}));
    expect(result.code).toBe('doorUnconfirmed');
    expect((await response).status()).toBe(400);
    const sent = await request;
    expect(sent.frame()).toBe(frame);
    expect((await sent.allHeaders()).authorization).toBe('Bearer '+await page.evaluate(()=>sessionStorage.getItem('board.token')));
    expect(existsSync(join(root,'state/decisions/D-9242.json'))).toBe(false);
    expect(existsSync(join(root,'merge-calls'))).toBe(false);
    expect(readFileSync(join(root,'state/events.jsonl'),'utf8')).toBe(before);
    expect((await page.request.get(b.url+'/api/state').then(r=>r.json())).pending.some((d:any)=>d.id==='D-9242')).toBe(true);
    const card = page.locator('#card-D-9242');
    await card.locator('[data-review-intent="1"]').check();
    await card.locator('[data-review-intent="2"]').check();
    await card.locator('[data-door-answer="0"]').click();
    await expect(card.locator('[data-c="A"]')).toBeEnabled();
    await card.locator('[data-c="A"]').click(); await card.locator('.confirm').click();
    await expect.poll(()=>existsSync(join(root,'state/decisions/D-9242.json'))).toBe(true);
    await expect.poll(()=>existsSync(join(root,'merge-calls'))).toBe(true);
    expect(readFileSync(join(root,'merge-calls'),'utf8').trim().split('\n')).toHaveLength(1);
  } finally { await stopBoard(b); }
});
