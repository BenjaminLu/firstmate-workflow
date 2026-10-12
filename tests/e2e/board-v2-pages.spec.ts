// T-289: the board's pages, ported from the approved v2 prototype: a sticky
// top bar, the full-width voyage stage, then one sticky row of four tabs
// (Decisions, Fleet, Crew, Log). Crew and Log are pages, not sheets; a task
// opened on the Fleet page is a list | detail pair, never a third layer.
import { expect } from '@playwright/test';
import { test, makeRoot, startBoard, stopBoard, writeTasks } from './lib/fixture';
import { EN, showFleet, showCrew, showLog, openDecisionDetails } from './lib/board';

const TABS = ['Decisions', 'Fleet', 'Crew', 'Log'] as const;
const selected = (page: any, tab: string) => expect(page.locator(`#tab${tab}`)).toHaveAttribute('aria-selected', 'true');

test('the page skeleton: top bar, full-width stage, then one row of four tabs; no counts band or summary strips', async ({page}) => {
  const board = await startBoard(makeRoot(['working','review']));
  try {
    await page.setViewportSize({width:1440, height:900});
    await page.goto(board.url+'/?lang=en');
    await expect(page.locator('#pagetabs [role=tab] .lb')).toHaveText(TABS.map(tab => EN['tab' + tab]));
    await expect(page.locator('#counts, #secbar, .board-sheet, dialog')).toHaveCount(0);
    const top = (await page.locator('.top').boundingBox())!, stage = (await page.locator('#voyage').boundingBox())!;
    const tabs = (await page.locator('#pagetabs').boundingBox())!;
    expect(stage.x).toBe(0); expect(stage.width).toBe(1440);
    expect(stage.y).toBeGreaterThanOrEqual(top.y + top.height - 1);
    expect(tabs.y).toBeGreaterThanOrEqual(stage.y + stage.height);
    await expect(page.locator('.top')).toHaveCSS('position', 'sticky');
    await expect(page.locator('#pagetabs')).toHaveCSS('position', 'sticky');
    // the Decisions tab carries the count; Fleet its open tasks; Crew the crew aboard
    await expect(page.locator('#tabDecisions .badge2')).toHaveText('1');
    await expect(page.locator('#tabDecisions .badge2')).toHaveAttribute('aria-label', EN.tabWaiting.replace('{n}', '1'));
    await expect(page.locator('#tabFleet .sub')).toHaveText(/^\d+ open$/);
    await expect(page.locator('#tabCrew .sub')).toHaveText(/^\d+$/);
    // scrolled, the top bar and the tabs stay; the tabs sit right under the bar
    await showFleet(page);
    await page.evaluate(() => scrollTo(0, 2000));
    await expect.poll(async () => Math.round((await page.locator('#pagetabs').boundingBox())!.y)).toBe(Math.round(top.height));
    // every page is a tab panel, and only the selected one shows
    for (const tab of TABS) {
      await page.locator(`#tab${tab}`).click();
      await selected(page, tab);
      for (const other of TABS) await expect(page.locator(`#${other.toLowerCase()}Panel`))[other === tab ? 'toBeVisible' : 'toBeHidden']();
    }
  } finally { await stopBoard(board); }
});

test('tab keys move between pages and the page is remembered', async ({page}) => {
  const board = await startBoard(makeRoot(['working']));
  try {
    await page.goto(board.url+'/?lang=en');
    await selected(page, 'Decisions');
    await page.locator('#tabDecisions').focus();
    for (const [key, tab] of [['ArrowRight','Fleet'], ['ArrowRight','Crew'], ['End','Log'], ['ArrowRight','Decisions'], ['ArrowLeft','Log'], ['Home','Decisions'], ['ArrowLeft','Log']] as const) {
      await page.keyboard.press(key);
      await selected(page, tab);
      await expect(page.locator(`#tab${tab}`)).toBeFocused();
      await expect(page.locator(`#tab${tab}`)).toHaveAttribute('tabindex', '0');
    }
    expect(await page.evaluate(() => localStorage.getItem('board.tab'))).toBe('log');
    // a waiting card opens the board on Decisions; nothing waiting, on the page last read
    await page.reload(); await selected(page, 'Decisions');
  } finally { await stopBoard(board); }
});

test('stored page and denied storage work without pending decisions', async ({page}) => {
  const board = await startBoard(makeRoot([], false));
  try {
    await page.addInitScript(() => { try { localStorage.setItem('board.tab','crew'); } catch {} });
    await page.goto(board.url+'/?lang=en');
    await selected(page, 'Crew');
    await expect(page.locator('#calm')).toBeHidden();
    await page.addInitScript(() => { Storage.prototype.getItem = () => { throw Error('denied'); }; Storage.prototype.setItem = () => { throw Error('denied'); }; });
    await page.reload();
    await selected(page, 'Decisions');
    await expect(page.locator('#calm')).toHaveText(EN.noCardWaits);
    await showLog(page);
    await selected(page, 'Log');
  } finally { await stopBoard(board); }
});

test('Fleet list and detail with the breadcrumb; Escape closes the detail only', async ({page}) => {
  const root = makeRoot(['working','review']);
  const long = 'A title long enough to need more than three lines in a lane card of the Fleet page, '.repeat(3);
  writeTasks(root, [{id:'T-001', title:long, depends_on:[]}, {id:'T-002', title:'Second task', depends_on:[]}]);
  const board = await startBoard(root);
  try {
    await page.setViewportSize({width:1440, height:900});
    await page.goto(board.url+'/?lang=en');
    await showFleet(page);
    // task titles clamp to three lines
    const title = page.locator('.card[data-task="T-001"] .t');
    await expect(title).toHaveCSS('-webkit-line-clamp', '3');
    expect(await title.evaluate(el => el.scrollHeight > el.clientHeight + 1)).toBe(true);
    const card = page.locator('.card[data-task="T-002"]');
    await card.click();
    const panel = page.locator('#taskDetail');
    await expect(panel).toBeVisible();
    const list = (await page.locator('#lanes').boundingBox())!, detail = (await panel.boundingBox())!;
    expect(detail.x).toBeGreaterThanOrEqual(list.x + list.width);
    const crumb = panel.locator('.detail-crumb');
    await expect(crumb).toHaveText(/‹\s*Fleet\s*›\s*T-002/);
    await expect(crumb.locator('[data-close-task]')).toHaveAccessibleName(EN.tabFleet);
    await page.keyboard.press('Escape');
    await expect(panel).toBeHidden(); await expect(card).toBeFocused();
    await page.keyboard.press('Escape');
    await selected(page, 'Fleet');
    // at 390px the detail replaces the list, and the crumb returns to it
    await page.setViewportSize({width:390, height:844});
    await card.scrollIntoViewIfNeeded();
    const scroll = await page.evaluate(() => scrollY);
    await card.click(); await expect(page.locator('#lanes')).toBeHidden();
    await crumb.locator('[data-close-task]').click();
    await expect(card).toBeVisible();
    expect(await page.evaluate(() => scrollY)).toBeCloseTo(scroll, 0);
    // a page change closes the detail: never a third layer
    await card.click(); await expect(panel).toBeVisible();
    await showCrew(page);
    await expect(panel).toHaveAttribute('hidden', ''); await expect(page.locator('.lanes-wrap')).not.toHaveClass(/has-detail/);
    await expect(page.locator('#roster .rrow').first()).toBeVisible();
    await expect(page.locator('#roster .rrow').first()).toHaveCSS('flex-direction', 'column');
    expect(await page.locator('#crewPanel').evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
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
    // the merged lane is hidden; every merged task is in the history
    await expect(page.locator('[data-lane="merged"]')).toHaveCount(0);
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
    await showLog(page);
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

test('a page change closes the Fleet detail and keeps the open decision sheet and its Escape', async ({page}) => {
  const board=await startBoard(makeRoot(['working']));
  try {
    await page.goto(board.url+'/?lang=en');
    await openDecisionDetails(page, 'D-1');
    const button=page.locator('#card-D-1 [data-decision-details]'), decision=page.locator('#sheet-D-1');
    await showCrew(page);
    await expect(decision).toBeHidden();
    await showFleet(page);
    await page.locator('#lanes .card').first().click();
    await expect(page.locator('#taskDetail')).toBeVisible();
    await page.locator('#tabDecisions').click();
    await expect(page.locator('#taskDetail')).toHaveAttribute('hidden',''); await expect(page.locator('.lanes-wrap')).not.toHaveClass(/has-detail/);
    await expect(decision).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(decision).toBeHidden(); await expect(button).toBeFocused();
    await page.locator('#voyage-toggle').click();
    await expect(page.locator('#voyage-drawer .lanes-wrap')).toBeAttached();
    await page.keyboard.press('Escape');
    await expect(page.locator('#fleetPanel .lanes-wrap')).toBeAttached();
    await expect(page.locator('#decisionsPanel #deckwrap')).toBeAttached();
  } finally { await stopBoard(board); }
});

// Short tokens never break inside themselves: a column narrower than "unknown",
// "Awaiting update" or "09:05:00" wraps them mid-word (the T-289 design review).
const lines = (el: Element) => {
  const range = document.createRange(); range.selectNodeContents(el);
  return new Set(Array.from(range.getClientRects()).filter(r => r.width > 0).map(r => Math.round(r.top))).size;
};
test('the Crew round and state and the Log time read on one line at 1440', async ({page}) => {
  const board = await startBoard(makeRoot(['working','review']));
  try {
    await page.setViewportSize({width:1440, height:900});
    await page.goto(board.url+'/?lang=en');
    await showCrew(page);
    const fm = page.locator('#roster [data-roster="firstmate"]');
    await expect(fm.locator('.rd')).toHaveText(EN.crewUnknown);
    await expect(fm.locator('.st')).toHaveText(EN.laneUnknown);
    for (const cell of ['.rl', '.rd', '.st']) expect(await fm.locator(cell).evaluate(lines), cell).toBe(1);
    await showLog(page);
    const times = page.locator('#log li time');
    await expect(times.first()).toHaveText(/^\d\d:\d\d:\d\d$/);
    for (const time of await times.all()) expect(await time.evaluate(lines)).toBe(1);
  } finally { await stopBoard(board); }
});
