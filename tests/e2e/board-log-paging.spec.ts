import { expect } from '@playwright/test';
import { test, makeRoot, startBoard, stopBoard, writeRegistry } from './lib/fixture';
import { appendFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const line = (n: number) => JSON.stringify({type:'progress', actor:'captain',
  ts:'2026-01-01T00:00:00Z', summary:{en:`older line ${n}${n === 0 ? ' #98765' : ''}`, 'zh-TW':`事件 ${n}`}}) + '\n';

test('older log pages link PRs, end, recover, and track the live anchor', async ({page}) => {
  const root = makeRoot([], false);
  writeRegistry(root, 'example/log');
  const log = join(root, 'state/events.jsonl');
  writeFileSync(log, Array.from({length:85}, (_, n) => line(n)).join(''));
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    const button = page.getByRole('button', {name:'Load older', exact:true});
    await expect(page.locator('#log li')).toHaveCount(40);
    await button.click();
    await expect(page.locator('#logOlder li')).toHaveCount(40);
    await expect(page.locator('#logOlder')).toContainText('older line 5');
    // An unchanged live snapshot preserves the separate older list.
    await page.evaluate(async () => {
      const s = await fetch('/api/state').then(r => r.json());
      (window as any).render(s);
    });
    await expect(page.locator('#logOlder li')).toHaveCount(40);
    await button.click();
    await expect(page.locator('#logOlder li')).toHaveCount(45);
    await expect(page.locator('#logOlder a')).toHaveAttribute('href', 'https://github.com/example/log/pull/98765');
    await expect(button).toBeHidden();
    appendFileSync(log, Array.from({length:41}, (_, n) => line(n + 85)).join(''));
    await expect(page.locator('#log')).toContainText('older line 125');
    await expect(page.locator('#logOlder li')).toHaveCount(0);
    await expect(button).toBeVisible();
    await button.click();
    await expect(page.locator('#logOlder li')).toHaveCount(40);
    // Failure preserves already displayed pages and permits retry.
    await page.route('**/api/events?**', route => route.fulfill({status:503, body:'unavailable'}));
    await button.click();
    await expect(page.locator('#logLoadStatus')).toHaveText('Could not load older events. Try again.');
    await expect(page.locator('#logOlder li')).toHaveCount(40);
    await page.unroute('**/api/events?**');
    for (const [status, code] of [[409, 'staleCursor'], [400, 'badCursor']] as const) {
      await page.route('**/api/events?**', route => route.fulfill({status, contentType:'application/json', body:JSON.stringify({code})}));
      await button.click();
      await expect(page.locator('#logOlder li')).toHaveCount(0);
      await expect(button).toBeVisible();
      await page.unroute('**/api/events?**');
      await button.click();
      await expect(page.locator('#logOlder li')).toHaveCount(40);
    }
  } finally { await stopBoard(b); }
});
