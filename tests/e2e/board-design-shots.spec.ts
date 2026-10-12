// T-298: a UI change's merge card shows each page's prototype and result
// screenshots side by side behind a toggle, and /design-shot serves only the
// screenshots the engine's capture kept under state/design/<task>/<head>/.
import { expect } from '@playwright/test';
import { mkdirSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { test, makeRoot, details, startBoard, stopBoard } from './lib/fixture';
import { intentCard } from './lib/intent-card';

const HEAD = 'a'.repeat(40);
// a 1x1 PNG, so the page can show what the endpoint serves
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=', 'base64');

test('design: merge card compares prototype and result screenshots', async ({page}) => {
  test.setTimeout(60_000);
  const root = makeRoot([], false);
  const shots = join(root, 'state/design/T-001', HEAD);
  mkdirSync(join(shots, 'head'), {recursive: true});
  mkdirSync(join(shots, 'prototype'), {recursive: true});
  writeFileSync(join(shots, 'head/index-w390-light.png'), PNG);
  writeFileSync(join(shots, 'prototype/index-w390-light.png'), PNG);
  writeFileSync(join(shots, 'head/notes.txt'), 'not a screenshot');
  writeFileSync(join(root, 'outside.png'), PNG);
  symlinkSync(join(root, 'outside.png'), join(shots, 'head/escape.png'));
  writeFileSync(join(shots, 'manifest.json'), JSON.stringify({version: 1, task: 'T-001', head: HEAD, kind: 'web', pages: [
    {page: 'board/public/index.html', shots: [{viewport: 'w390', width: 390, height: 844, scheme: 'light',
      head: 'head/index-w390-light.png', prototype: 'prototype/index-w390-light.png'}]}]}));
  writeFileSync(join(root, 'state/pending/D-7.json'), JSON.stringify({id: 'D-7', kind: 'merge', task: 'T-001', pr: 7,
    expected_head: HEAD, title: 'Merge it', details,
    gates: {branch: true, rebase: true, scope: true, 'fail-first': true, ci: true, approval: true}}));
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    const state = await page.evaluate(async () => (await fetch('/api/state')).json());
    const card = state.pending.find((d: any) => d.id === 'D-7');
    const shot = card?.design_shots?.pages?.[0]?.shots?.[0];
    expect(shot?.head, 'the merge card carries the result screenshot').toContain('/design-shot?');
    expect(shot?.head).toContain('file=head%2Findex-w390-light.png');
    expect(shot?.prototype, 'and the prototype screenshot').toContain('file=prototype%2Findex-w390-light.png');

    // the toggle starts closed and loads nothing until it is opened
    const compare = page.locator('#card-D-7 .design-compare');
    await expect(compare.locator('summary')).toHaveText('Compare pages');
    await expect(compare.locator('img')).toHaveCount(0);
    await compare.locator('summary').click();
    await expect(compare.locator('.design-pair img')).toHaveCount(2);
    await expect(compare.locator('.design-side b')).toHaveText(['Prototype', 'Result']);
    await expect.poll(() => compare.locator('img').evaluateAll(els =>
      els.map(el => (el as HTMLImageElement).naturalWidth)), {timeout: 10_000}).toEqual([1, 1]);

    const get = (query: string) => page.evaluate(async q => {
      const r = await fetch('/design-shot?' + q);
      return `${r.status} ${r.headers.get('content-type')}`;
    }, query);
    const q = (file: string, head = HEAD, task = 'T-001') => new URLSearchParams({task, head, file}).toString();
    expect(await get(q('head/index-w390-light.png'))).toBe('200 image/png');
    expect(await get(q('prototype/index-w390-light.png'))).toBe('200 image/png');
    for (const [name, query] of [
      ['a path out of the folder', q('head/../../../../outside.png')],
      ['a bad head', q('head/index-w390-light.png', 'not-a-head')],
      ['a bad task', q('head/index-w390-light.png', HEAD, '../T-001')],
      ['a file that is not a png', q('head/notes.txt')],
      ['a folder other than head or prototype', q('manifest.json')],
      ['a screenshot that is not there', q('head/missing.png')],
      ['a link out of the folder', q('head/escape.png')],
    ]) expect((await get(query)).split(' ')[0], name).toBe('404');
  } finally { await stopBoard(b); }
});

test('design: an intent merge card has the compare toggle too', async ({page}) => {
  const root = makeRoot([], false);
  const shots = join(root, 'state/design/T-001', HEAD);
  mkdirSync(join(shots, 'head'), {recursive: true});
  writeFileSync(join(shots, 'head/index-w390-dark.png'), PNG);
  writeFileSync(join(shots, 'manifest.json'), JSON.stringify({version: 1, task: 'T-001', head: HEAD, kind: 'web', pages: [
    {page: 'board/public/index.html', shots: [{viewport: 'w390', scheme: 'dark', head: 'head/index-w390-dark.png', prototype: null}]}]}));
  writeFileSync(join(root, 'state/pending/D-9.json'), JSON.stringify({...intentCard('D-9'), kind: 'merge', task: 'T-001', pr: 9,
    expected_head: HEAD, gates: {branch: true, rebase: true, scope: true, 'fail-first': true, ci: true, approval: true}}));
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    const compare = page.locator('#card-D-9 .design-compare');
    await compare.locator('summary').click();
    await expect(compare.locator('.design-pair img')).toHaveCount(1);
    await expect(compare.locator('.design-none')).toHaveCount(1);   // no prototype: a dash, not a broken image
    await expect(compare.locator('figcaption')).toHaveText('w390 · dark');
  } finally { await stopBoard(b); }
});

test('design: a merge card with no capture has no compare toggle', async ({page}) => {
  const root = makeRoot([], false);
  writeFileSync(join(root, 'state/pending/D-8.json'), JSON.stringify({id: 'D-8', kind: 'merge', task: 'T-001', pr: 8,
    expected_head: HEAD, title: 'Merge it', details,
    gates: {branch: true, rebase: true, scope: true, 'fail-first': true, ci: true, approval: true}}));
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    await expect(page.locator('#card-D-8')).toBeVisible();
    await expect(page.locator('#card-D-8 .design-compare')).toHaveCount(0);
  } finally { await stopBoard(b); }
});
