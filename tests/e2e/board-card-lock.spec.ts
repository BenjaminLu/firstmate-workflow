import { expect } from '@playwright/test';
import { test, makeRoot, startBoard, stopBoard } from './lib/fixture';
import { intentCard } from './lib/intent-card';
import { writeFileSync, rmSync, renameSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

for (const status of [200, 409]) test(`answer controls lock immediately and settle after ${status}`, async ({page}) => {
  const root = makeRoot([], false), d = intentCard();
  writeFileSync(join(root, 'state/pending/D-211.json'), JSON.stringify(d));
  const b = await startBoard(root);
  let posts = 0, release = () => {};
  const held = new Promise<void>(resolve => {release = resolve;});
  try {
    await page.goto(`${b.url}/?lang=en`);
    const state = await (await page.request.get(`${b.url}/api/state`)).json();
    // Keep the old pending snapshot after POST, including the immediate refresh.
    await page.route('**/api/state*', route => route.fulfill({json:state}));
    await page.route('**/decisions', async route => {
      posts++;
      await new Promise(resolve => setTimeout(resolve, 1000));
      await held;
      await route.fulfill({status, json:status === 200 ? {ok:true} : {error:'decision already recorded differently'}});
    });
    const card = page.locator('#card-D-211');
    await card.locator('[data-c="custom"]').click();
    await card.locator('textarea:not([data-question])').fill('Keep this draft');
    await card.locator('[data-question="0"][data-ok="yes"]').click();
    await card.locator('[data-question="1"][data-ok="no"]').click();
    await card.locator('textarea[data-question="1"]').fill('Keep this correction');
    await expect(card.locator('.confirm')).toBeEnabled();
    const response = page.waitForResponse(r => r.url().endsWith('/decisions'));
    // Two synchronous activations of the original node model a stale click/Enter.
    await card.locator('.confirm').evaluate((button: HTMLButtonElement) => {button.click(); button.click();});
    await expect(card.locator('.confirm')).toHaveText('Sending…');
    const controls = card.locator('.opt, textarea, [data-ok], .confirm');
    for (const control of await controls.all()) await expect(control).toBeDisabled();
    release();
    await response;
    await expect(card.locator('.confirm')).not.toHaveText('Sending…');
    expect(posts).toBe(1);
    if (status === 200) {
      for (const control of await controls.all()) await expect(control).toBeDisabled();
      await page.evaluate(() => (window as any).answer('D-211'));
      expect(posts).toBe(1);
      rmSync(join(root, 'state/pending/D-211.json'));
      state.pending = [];
      await page.evaluate(async () => (window as any).render(await (await fetch('/api/state')).json()));
      await expect(card).toHaveCount(0);
    } else {
      for (const control of await controls.all()) await expect(control).toBeEnabled();
      await expect(card.locator('.refused')).toContainText('decision already recorded differently');
      await expect(card.locator('textarea:not([data-question])')).toHaveValue('Keep this draft');
      await expect(card.locator('textarea[data-question="1"]')).toHaveValue('Keep this correction');
    }
  } finally {release(); await stopBoard(b);}
});

for (const diagram of [false, true]) test(`intent sections keep order, phone width and disclosures; diagram ${diagram}`,  async ({page}) => {
  const root = makeRoot([], false), d = intentCard();
  d.details.en.done = Array.from({length:7}, (_, i) => ({text:`Alignment item ${i + 1}.`}));
  writeFileSync(join(root, 'state/pending/D-211.json'), JSON.stringify(d));
  if (diagram) expect(spawnSync('bash', [join(root, 'bin/fm-diagram.sh'), '--decision', d.id, '--repo', root]).status).toBe(0);
  const b = await startBoard(root);
  try {
    await page.setViewportSize({width:390, height:844});
    await page.goto(`${b.url}/?lang=en`);
    const card = page.locator('#card-D-211');
    await expect(card.locator('h4')).toHaveText(['Intent','How it works','Alignment','Scope','Notes','Options','Questions to confirm']);
    await expect(card.locator('.meta > .kbadge:first-child')).toHaveCount(1);
    for (const selector of ['.explanation', '.tradeoffs', '.opt'])
      await expect(card.locator(selector).first()).toHaveCSS('font-size', '16px');
    const alignment = card.locator('section').filter({has:page.getByRole('heading', {name:'Alignment', exact:true})});
    await expect(alignment.locator('li')).toHaveCount(6);
    await card.locator('[data-c="A"]').click();
    await card.locator('[data-question="0"][data-ok="no"]').click();
    await card.locator('textarea[data-question="0"]').fill('Preserved answer');
    await alignment.getByRole('button', {name:'Show more (1)', exact:true}).click();
    await expect(alignment.locator('li')).toHaveCount(7);
    await expect(card.locator('[data-c="A"]')).toHaveAttribute('aria-pressed','true');
    // Observe the next server state push, rather than a local click re-render.
    d.details.en.title = 'Refreshed intent card';
    writeFileSync(join(root, 'state/pending/.D-211.tmp'), JSON.stringify(d));
    renameSync(join(root, 'state/pending/.D-211.tmp'), join(root, 'state/pending/D-211.json'));
    await expect(card.locator('h3')).toHaveText('Refreshed intent card');
    await expect(alignment.locator('li')).toHaveCount(7);
    await expect(card.locator('[data-c="A"]')).toHaveAttribute('aria-pressed','true');
    await expect(card.locator('textarea[data-question="0"]')).toHaveValue('Preserved answer');
    const how = card.locator('section').filter({has:page.getByRole('heading', {name:'How it works', exact:true})});
    await expect(how.locator('iframe:visible, .change-fallback:visible')).toHaveCount(1);
    await expect(how.locator(diagram ? 'iframe' : '.change-fallback')).toBeVisible();
    expect(await card.locator('section').evaluateAll(sections => sections.every(el => {
      const box = el.getBoundingClientRect();
      return box.left >= 0 && box.right <= innerWidth && el.scrollWidth <= el.clientWidth + 1;
    }))).toBe(true);
  } finally {await stopBoard(b);}
});
