import { expect } from '@playwright/test';
import { test, makeRoot, startBoard, stopBoard } from './lib/fixture';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

test('idle engine badge shows the resolved vendor and explains its host rule', async ({page}) => {
  const root=makeRoot([],false);
  writeFileSync(join(root,'config.yaml'),'vendor: opposite-of-host\nreviewer:\n  vendor: claude\n');
  mkdirSync(join(root,'state/session'),{recursive:true});
  writeFileSync(join(root,'state/session/host.json'),JSON.stringify({harness:'claude'}));
  const board=await startBoard(root);
  try {
    await page.goto(`${board.url}/?lang=en`);
    await expect(page.locator('#engine')).toHaveText('codex ⇄ claude');
    await expect(page.locator('#engine')).toHaveAttribute('title',/opposite-of-host \(claude → codex\)/);
    // Unknown host keeps the literal rule and exposes the fallback resolution.
    writeFileSync(join(root,'state/session/host.json'),'{}');
    await page.evaluate(async () => (window as any).render(await (await fetch('/api/state')).json()));
    await expect(page.locator('#engine')).toHaveText('mock ⇄ claude');
    await expect(page.locator('#engine')).toHaveAttribute('title',/opposite-of-host \(\? → mock\)/);
  } finally { await stopBoard(board); }
});
