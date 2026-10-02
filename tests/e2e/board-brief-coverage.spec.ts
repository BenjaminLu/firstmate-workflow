import { expect } from '@playwright/test';
import { test, makeRoot, startBoard, stopBoard, readTasks } from './lib/fixture';
import { emitFixture } from './lib/board';

test('brief gaps, deferrals and waivers display authored bilingual warnings', async ({page}) => {
  const root = makeRoot(['working'], false);
  const task = readTasks(root)[0].id;
  const cases = [
    {gaps:['config.yaml outside scope'], deferred:[], waived:[], en:'Uncovered: config.yaml outside scope', tw:'未涵蓋：config.yaml 不在範圍內'},
    {gaps:[], deferred:['upstream repair'], waived:[], en:'Deferred: upstream repair', tw:'延後：等待上游修復'},
    {gaps:[], deferred:[], waived:['base update'], en:'No brief needed: base update', tw:'免簡報：更新基底'},
  ];
  for (const c of cases) emitFixture(root, 'worker-coverage', task, 'crew_status', c.en, c.tw,
    {evidence_event:'brief_coverage', coverage:c});
  const board = await startBoard(root);
  try {
    for (const lang of ['en', 'zh-TW']) {
      await page.goto(`${board.url}/?lang=${lang}`);
      const warnings = page.locator('#log .evidence-warning');
      await expect(warnings).toHaveCount(3);
      for (const c of cases) await expect(warnings.filter({hasText:lang === 'en' ? c.en : c.tw})).toHaveCount(1);
    }
  } finally { stopBoard(board); }
});
