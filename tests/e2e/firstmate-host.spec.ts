import { openCrewSheet } from './lib/board';
import { expect } from '@playwright/test';
import { test, makeRoot, startBoard, stopBoard, writeTasks, details } from './lib/fixture';
import { mkdirSync, writeFileSync, unlinkSync, chmodSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

for (const lang of ['en', 'zh-TW']) {
  test(`firstmate host uses the session record (${lang})`, async ({ page }) => {
    const root = makeRoot(['working']);
    mkdirSync(join(root, 'state/session'), { recursive: true });
    const file = join(root, 'state/session/host.json');
    writeFileSync(file, JSON.stringify({ harness: 'codex', model: 'gpt-6-astra',
      cli_version: 'codex-cli 0.116.0', model_source: '/fixture/.codex/config.toml:model' }));
    const b = await startBoard(root, { FM_HARNESS: 'claude' });
    try {
      await page.goto(`${b.url}/?lang=${lang}`);
      await openCrewSheet(page);
      const row = page.locator('.roster [data-roster="firstmate"]');
      await expect(row.locator('.rv')).toHaveText('codex');
      await expect(row.locator('.rv')).not.toHaveClass(/warn/);
      await expect(row.locator('.rm')).toHaveText('gpt-6-astra');
      const card = page.locator('[data-roster="firstmate"]');
      await expect(card.locator('.rc')).toHaveText('codex-cli 0.116.0');
      const state = await (await page.request.get(`${b.url}/api/state`)).json();
      expect(state.crew.find((c: any) => c.id === 'firstmate').model_source)
        .toBe('/fixture/.codex/config.toml:model');
      writeFileSync(file, JSON.stringify({ harness: 'claude', model: null, cli_version: null }));
      await page.reload();
      await expect(row.locator('.rv')).toHaveText('claude');
      await expect(row.locator('.rm')).toHaveText(lang === 'en' ? 'unknown' : '未知');
      await expect(card.locator('.rv')).not.toHaveClass(/warn/);
      writeFileSync(file, JSON.stringify({ harness: 'claude', confirmed: false }));
      await page.reload();
      const warning = lang === 'en' ? 'claude (unconfirmed)' : 'claude（未確認）';
      await expect(row.locator('.rv')).toHaveText(warning);
      await expect(row.locator('.rv')).toHaveClass(/warn/);
      await expect(card.locator('.rv')).toHaveText(warning);
      await expect(card.locator('.rv')).toHaveClass(/warn/);
      const unconfirmed = await (await page.request.get(`${b.url}/api/state`)).json();
      expect(unconfirmed.crew.find((c: any) => c.id === 'firstmate').host_confirmed).toBe(false);
      unlinkSync(file);
      await page.reload();
      await expect(row.locator('.rv')).toHaveCount(0);
      await expect(row.locator('.rm')).toHaveCount(0);
      await expect(card.locator('.rc')).toHaveCount(0);
    } finally { await stopBoard(b); }
  });
}

test('a board dispatch resolves against the recorded host', async ({ page }) => {
  const root = makeRoot([], false);
  writeTasks(root, [{ id: 'T-174', title: 'Host routing', depends_on: [] }]);
  mkdirSync(join(root, 'state/session'), { recursive: true });
  writeFileSync(join(root, 'state/session/host.json'), '{"harness":"claude"}');
  writeFileSync(join(root, 'config.yaml'), 'vendor: opposite-of-host\nfallback:\n  - claude\n  - codex\n  - cursor-agent\n  - gemini\n');
  // Keep the board's real child launch and the production resolver; substitute
  // task execution so this fixture needs no git publication or vendor session.
  writeFileSync(join(root, 'bin/fm-dispatch.sh'), '#!/usr/bin/env bash\n' +
    '. "$FM_ROOT/bin/fm-config.sh"\nfm_storage_init "$FM_ROOT" || exit\n' +
    'fm_vendor_chain worker > "$FM_ROOT/selected-chain"\nprintf "T-174\\n"\n');
  chmodSync(join(root, 'bin/fm-dispatch.sh'), 0o755);
  writeFileSync(join(root, 'state/pending/D-1174.json'), JSON.stringify({
    id: 'D-1174', kind: 'choice', task: 'T-174', ts: '2026-10-03T00:00:00Z',
    title: 'Start host routing?', details: { ...details, effect: { A: 'dispatch' } }
  }));
  const b = await startBoard(root, { FM_HARNESS: 'codex', HERDR_ENV: '0' });
  try {
    await page.goto(`${b.url}/?lang=en`);
    await page.locator('#card-D-1174 .opt[data-c="A"]').click();
    await page.locator('#card-D-1174 .confirm').click();
    await expect.poll(() => existsSync(join(root, 'selected-chain'))
      ? readFileSync(join(root, 'selected-chain'), 'utf8').trim() : '')
      .toBe('codex\nclaude\ncursor-agent\ngemini');
  } finally { await stopBoard(b); }
});
