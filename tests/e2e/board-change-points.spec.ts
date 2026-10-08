import { expect } from '@playwright/test';
import { test, makeRoot, startBoard, stopBoard, writeTasks } from './lib/fixture';
import { changePointCard } from './lib/intent-card';
import { writeFileSync } from 'node:fs';
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
    await expect(card.locator('[data-door-answer="0"]')).toHaveAttribute('aria-pressed','true');
    await expect(card.locator('.confirm')).toBeDisabled();
    await card.locator('[data-door-answer="0"]').click();
    await expect(card.locator('.confirm')).toBeEnabled();
  } finally { await stopBoard(b); }
});
