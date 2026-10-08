import { expect } from '@playwright/test';
import { test, makeRoot, startBoard, stopBoard } from './lib/fixture';
import { EN, showFleet, openCrewSheet, openLogSheet } from './lib/board';

test('tabs, sheets and Fleet detail preserve focus and responsive reading', async ({page}) => {
  const board = await startBoard(makeRoot(['working','review']));
  try {
    await page.addInitScript(() => { localStorage.setItem('board.tab','fleet'); localStorage.setItem('board.roster','hidden'); });
    await page.setViewportSize({width:1440,height:900});
    await page.goto(board.url+'/?lang=en');
    await expect(page.locator('#tabDecisions')).toHaveAttribute('aria-selected','true');
    await expect(page.locator('#tabDecisions .badge')).toHaveText('1');
    const stage = (await page.locator('#voyage').boundingBox())!;
    expect((await page.locator('#tabs').boundingBox())!.y).toBeGreaterThanOrEqual(stage.y+stage.height);
    await expect(page.locator('#crewSheet')).toBeHidden();
    await showFleet(page);
    expect((await page.locator('.lanes-wrap').boundingBox())!.width).toBeGreaterThan(1400);
    const card=page.locator('#lanes .card').first();
    await card.click();
    const panel=page.locator('#taskDetail');
    await expect(panel).toBeVisible();
    const list=(await page.locator('#lanes').boundingBox())!, detail=(await panel.boundingBox())!;
    expect(detail.x).toBeGreaterThanOrEqual(list.x+list.width);
    // the pane's close control is named for what it does at each width, also when the width changes while it is open
    const close=panel.locator('[data-close-task]');
    await expect(close).toHaveAccessibleName(EN.detailClose);
    await page.setViewportSize({width:390,height:844});
    await expect(close).toHaveAccessibleName(EN.sheetBack);
    await page.setViewportSize({width:1440,height:900});
    await expect(close).toHaveAccessibleName(EN.detailClose);
    await page.keyboard.press('Escape');
    await expect(panel).toBeHidden(); await expect(card).toBeFocused();
    await card.click(); await openCrewSheet(page);
    // closed, not merely covered: the detail's own hidden state and the list's two-pane class are gone
    await expect(panel).toHaveAttribute('hidden',''); await expect(page.locator('.lanes-wrap')).not.toHaveClass(/has-detail/);
    await expect(page.locator('#crewSheet')).toHaveAttribute('aria-modal','true');
    await expect(page.locator('#roster .rrow').first()).toBeVisible();
    expect((await page.locator('#crewSheet').boundingBox())!.width).toBeCloseTo(1440*.96,0);
    expect(await page.locator('#roster .rrow').evaluateAll(rows=>rows.every(row=>row.scrollHeight<=row.clientHeight && row.scrollWidth<=row.clientWidth))).toBe(true);
    await page.keyboard.press('Escape'); await expect(page.locator('#rosterBtn')).toBeFocused();
    await page.keyboard.press('Escape'); await expect(page.locator('#voyage')).toBeVisible();
    await openLogSheet(page); await expect(page.locator('#logSheet')).toHaveAttribute('role','dialog');
    await page.keyboard.press('Escape'); await expect(page.locator('#logBtn')).toBeFocused();
    await page.setViewportSize({width:390,height:844});
    await card.scrollIntoViewIfNeeded();
    const scroll=await page.evaluate(()=>scrollY);
    await card.click(); await expect(page.locator('#lanes')).toBeHidden();
    await expect(close).toHaveAccessibleName(EN.sheetBack);
    await panel.getByRole('button',{name:EN.sheetBack}).click(); await expect(card).toBeVisible();
    expect(await page.evaluate(()=>scrollY)).toBeCloseTo(scroll,0);
    await openCrewSheet(page);
    expect((await page.locator('#crewSheet').boundingBox())!.width).toBe(390);
    expect(await page.locator('#crewSheet').evaluate(el=>el.scrollWidth<=el.clientWidth)).toBe(true);
    await expect(page.locator('#roster .rrow').first()).toHaveCSS('flex-direction','column');
  } finally { await stopBoard(board); }
});

test('stored tab and denied storage work without pending decisions', async ({page}) => {
  const board=await startBoard(makeRoot([],false));
  try {
    await page.addInitScript(()=>{try { localStorage.setItem('board.tab','fleet'); } catch {}});
    await page.goto(board.url+'/?lang=en');
    await expect(page.locator('#tabFleet')).toHaveAttribute('aria-selected','true');
    await page.addInitScript(()=>{Storage.prototype.getItem=()=>{throw Error('denied');};Storage.prototype.setItem=()=>{throw Error('denied');};});
    await page.reload(); await showFleet(page);
    await expect(page.locator('#tabFleet')).toHaveAttribute('aria-selected','true');
    await page.locator('#tabDecisions').click();
    await expect(page.locator('#tabDecisions')).toHaveAttribute('aria-selected','true');
  } finally { await stopBoard(board); }
});

test('client pages show all history, parked cards and held log lines', async ({page}) => {
  const board=await startBoard(makeRoot([],false));
  try {
    await page.route('**/events', route=>route.fulfill({contentType:'text/event-stream',body:': fixture\n\n'}));
    await page.route('**/api/state', async route=>{
      const response=await route.fetch(), s=await response.json();
      s.tasks=[...Array.from({length:31},(_,i)=>({id:`H-${i}`,title:`History ${i}`,stage:'merged'})),
        ...Array.from({length:13},(_,i)=>({id:`P-${i}`,title:`Parked ${i}`,stage:'parked'}))];
      s.recent=Array.from({length:29},(_,i)=>({actor:'captain',type:'progress',cursor:`fixture-${i}`,summary:{en:`Event ${i}`}}));
      await route.fulfill({response,json:s});
    });
    await page.route('**/api/events?**', route=>route.fulfill({json:{events:Array.from({length:5},(_,i)=>({actor:'captain',type:'progress',cursor:`older-${i}`,summary:{en:`Older ${i}`}})),next:null,pr_urls_by_project:{}}}));
    await page.goto(board.url+'/?lang=en'); await showFleet(page);
    for(const [id,selector,total,size] of [['history','.history-cards .card',31,12],['parked','.parked-cards .card',13,6]] as const) {
      await page.locator(`#${id} summary`).click();
      const seen:string[]=[];
      for(let offset=0;offset<total;offset+=size) {
        const cards=page.locator(`#${id} ${selector}:visible`);
        await expect(cards).toHaveCount(Math.min(size,total-offset));
        seen.push(...await cards.evaluateAll(els=>els.map(el=>(el as HTMLElement).dataset.task!)));
        if(offset+size<total) await page.locator(`#${id} [data-page="next"]`).click();
      }
      expect(seen).toEqual(Array.from({length:total},(_,i)=>`${id === 'history' ? 'H' : 'P'}-${i}`));
      await page.locator(`#${id} [data-page="first"]`).click();
      await expect(page.locator(`#${id} [data-page="prev"]`)).toBeDisabled();
    }
    await openLogSheet(page);
    await expect(page.locator('#log li:visible')).toHaveCount(12);
    await page.locator('#logPager [data-page="next"]').click();
    await expect(page.locator('#log li:visible').first()).toContainText('Event 12');
    await page.locator('#logPager [data-page="next"]').click();
    await expect(page.locator('#log li:visible')).toHaveCount(5);
    await page.locator('#logLoadOlder').click();
    await expect(page.locator('#log li:visible, #logOlder li:visible')).toHaveCount(10);
    await expect(page.locator('#logOlder li:visible').last()).toContainText('Older 4');
    await page.locator('#logPager [data-page="prev"]').click();
    await expect(page.locator('#log li:visible').first()).toContainText('Event 12');
  } finally { await stopBoard(board); }
});

test('sheets and tab changes close Fleet detail without stealing decision Escape', async ({page}) => {
  const board=await startBoard(makeRoot(['working']));
  try {
    await page.goto(board.url+'/?lang=en');
    const button=page.locator('#card-D-1 [data-decision-details]');
    await button.click();
    const decision=page.locator('#sheet-D-1');
    await openCrewSheet(page);
    await page.keyboard.press('Escape');
    await expect(page.locator('#crewSheet')).toBeHidden();
    await expect(page.locator('#rosterBtn')).toBeFocused();
    await expect(decision).toBeVisible();
    await showFleet(page);
    await page.locator('#lanes .card').first().click();
    await expect(page.locator('#taskDetail')).toBeVisible();
    await page.locator('#tabDecisions').click();
    await expect(page.locator('#taskDetail')).toHaveAttribute('hidden',''); await expect(page.locator('.lanes-wrap')).not.toHaveClass(/has-detail/);
    await expect(decision).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(decision).toBeHidden(); await expect(button).toBeFocused();
    await showFleet(page); await page.locator('#lanes .card').first().click();
    await openLogSheet(page); await expect(page.locator('#taskDetail')).toHaveAttribute('hidden',''); await expect(page.locator('.lanes-wrap')).not.toHaveClass(/has-detail/);
    await page.locator('#logSheet [data-sheet-close]').click();
    await expect(page.locator('#logBtn')).toBeFocused();
    await page.locator('#voyage-toggle').click();
    await expect(page.locator('#voyage-drawer .lanes-wrap')).toBeAttached();
    await page.keyboard.press('Escape');
    await expect(page.locator('#fleetPanel .lanes-wrap')).toBeVisible();
    await expect(page.locator('#decisionsPanel #deckwrap')).toBeAttached();
  } finally { await stopBoard(board); }
});
