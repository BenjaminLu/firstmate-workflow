// T-274: the voyage stage reserves its final height before its iframe loads,
// so loading the ship never moves the tabs, and a click on a tab while the
// board is still loading is never lost. The stage mounts in an idle callback;
// Playwright's clock, paused before the board's page loads, holds that
// callback until the test lets the clock run. No hook in product code.
import { expect, type Page } from '@playwright/test';
import { test, makeRoot, startBoard, stopBoard } from './lib/fixture';

type Board = Awaited<ReturnType<typeof startBoard>>;
const START = new Date('2026-10-09T00:00:00Z');

// Sign in with the real clock, then pause the fake one and load the board.
async function pausedBoard(page: Page, b: Board, viewport: {width:number,height:number},
  storage: {local?: Record<string,string>, session?: Record<string,string>} = {}) {
  await page.setViewportSize(viewport);
  await page.goto(b.url+'/?lang=en');
  await page.evaluate(({local, session}) => {
    for (const [k, v] of Object.entries(local ?? {})) localStorage.setItem(k, v);
    for (const [k, v] of Object.entries(session ?? {})) sessionStorage.setItem(k, v);
  }, storage);
  await page.clock.install({time: START});
  await page.clock.pauseAt(new Date(START.getTime()+10_000));
  await page.goto(b.url+'/?lang=en');
  await expect(page.locator('.dcard').first()).toBeAttached();
  await expect.poll(() => page.evaluate(() => document.readyState)).toBe('complete');
  await expect(page.locator('#voyage-stage')).toHaveCount(0);
}
// Let the paused clock run until the idle callback has mounted the stage.
async function runUntilMounted(page: Page) {
  await expect.poll(async () => {
    await page.clock.runFor(500);
    return page.locator('#voyage-stage').count();
  }).toBe(1);
}
const box = async (page: Page, selector: string) => (await page.locator(selector).boundingBox())!;

const cases = [
  {name:'desktop panel', viewport:{width:1280,height:720}, size:'full-size', stage:270},
  {name:'narrow panel', viewport:{width:390,height:844}, size:'full-size', stage:270},
  {name:'desktop strip', viewport:{width:1280,height:720}, size:'strip', stage:88},
  {name:'narrow strip', viewport:{width:390,height:844}, size:'strip', stage:72},
];
for (const c of cases) test(`loading the ${c.name} stage never moves the tabs`, async ({page}) => {
  const b = await startBoard(makeRoot(['working']));
  try {
    await pausedBoard(page, b, c.viewport, {local:{'board.voyage.size':c.size}});
    const tabsBefore = await box(page, '#tabs'), mountBefore = await box(page, '#voyage-mount');
    await runUntilMounted(page);
    const tabsAfter = await box(page, '#tabs'), mountAfter = await box(page, '#voyage-mount');
    const iframe = await box(page, '#voyage-stage');
    expect(iframe.height).toBe(c.stage);
    expect(tabsAfter.y, 'the tab bar moved when the stage loaded').toBe(tabsBefore.y);
    expect(mountBefore.height, 'the stage box was not reserved before it loaded').toBe(iframe.height);
    expect(mountAfter.height).toBe(iframe.height);
  } finally { await stopBoard(b); }
});

for (const viewport of [{width:1280,height:720},{width:390,height:844}])
  test(`a Fleet click held while the stage loads is not lost at ${viewport.width}px`, async ({page}) => {
    const b = await startBoard(makeRoot(['working']));
    try {
      await pausedBoard(page, b, viewport);
      await expect(page.locator('#tabFleet')).not.toHaveText('');
      await expect(page.locator('#tabFleet')).toHaveAttribute('aria-selected', 'false');
      const tab = await box(page, '#tabFleet');
      await page.mouse.move(tab.x+tab.width/2, tab.y+tab.height/2);
      await page.mouse.down();
      await runUntilMounted(page);
      await page.mouse.up();
      await expect(page.locator('#tabFleet'), 'the Fleet tab click was lost').toHaveAttribute('aria-selected', 'true');
      await expect(page.locator('#fleetPanel')).toBeVisible();
    } finally { await stopBoard(b); }
  });

test('a hidden voyage reserves no space', async ({page}) => {
  const b = await startBoard(makeRoot(['working']));
  try {
    await pausedBoard(page, b, {width:1280,height:720}, {local:{'board.voyage.hidden':'1'}});
    await page.clock.runFor(2_000);
    await expect(page.locator('#voyage-stage')).toHaveCount(0);
    await expect(page.locator('#voyage-mount')).toBeHidden();
    expect(await page.locator('#voyage-mount').evaluate(el => el.getClientRects().length)).toBe(0);
  } finally { await stopBoard(b); }
});

for (const viewport of [{width:1280,height:720},{width:390,height:500}])
  test(`full screen keeps its geometry at ${viewport.width}x${viewport.height}`, async ({page}) => {
    const b = await startBoard(makeRoot(['working']));
    try {
      await pausedBoard(page, b, viewport, {session:{'board.voyage.mode':'full'}});
      await expect(page.locator('body')).toHaveClass(/voyage-full/);
      await runUntilMounted(page);
      const mount = await box(page, '#voyage-mount'), iframe = await box(page, '#voyage-stage');
      for (const k of ['x','y','width','height'] as const) expect(Math.abs(iframe[k]-mount[k]), `iframe ${k}`).toBeLessThanOrEqual(1);
      expect(mount.height).toBeGreaterThan(88);
      for (const selector of ['#voyage', '#voyage-mount', '#voyage-stage', '#voyage-drawer']) {
        const r = await box(page, selector);
        expect(r.x, selector).toBeGreaterThanOrEqual(0);
        expect(r.y, selector).toBeGreaterThanOrEqual(0);
        expect(r.x+r.width, selector).toBeLessThanOrEqual(viewport.width);
        expect(r.y+r.height, selector).toBeLessThanOrEqual(viewport.height);
      }
    } finally { await stopBoard(b); }
  });
