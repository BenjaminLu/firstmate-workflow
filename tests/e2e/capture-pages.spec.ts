// T-299: run real captures in the CI job that installs Chromium.
// Dependencies: bin/lib/fm_design.py bin/lib/fm-design-capture.mjs
// bin/lib/fm_capture_server.py tests/e2e/capture-server.sh
// tests/e2e/lib/capture-server.ts tests/e2e/lib/fixture.ts tests/e2e/lib/capture-pages.py
// tests/e2e/lib/capture-observer.mjs tests/e2e/lib/failfirst-reporter.ts
import { test, expect, type TestInfo } from '@playwright/test';
import { spawnSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { resolve, join } from 'node:path';

function capture(mode: string, info: TestInfo) {
  const out = info.outputPath('capture');
  const result = spawnSync('python3', [resolve('tests/e2e/lib/capture-pages.py'), mode, out], {
    encoding: 'utf8', env: {...process.env, PYTHONDONTWRITEBYTECODE: '1'},
  });
  expect(result.status, `${result.error || ''}\n${result.stdout}\n${result.stderr}`).toBe(0);
  const pages = JSON.parse(readFileSync(join(out, 'observations.json'), 'utf8'));
  expect(pages.length, 'the capture must take a screenshot').toBeGreaterThan(0);
  for (const shot of pages) {
    expect(readFileSync(shot.file).subarray(0, 8))
      .toEqual(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  }
  // The base writes screenshots but no blocked-request record. Absence is
  // zero recorded blocks, so the blocking assertion below is the red result.
  const requests = join(out, 'requests.json');
  const record = existsSync(requests) ? JSON.parse(readFileSync(requests, 'utf8')) : {blocked: []};
  return {pages, record};
}

test('capture: served page has content', async ({}, info) => {
  const {pages} = capture('served', info);
  expect(pages.map((shot: {text: string}) => shot.text).join('\n')).toContain('SK-007');
  expect(pages.map((shot: {view: string}) => shot.view)).toEqual(['Decisions', 'Fleet', 'Crew', 'Log']);
});

for (const [view, selector, content] of [
  ['Decisions', '#decisionsPanel #card-D-1', 'SK-007'],
  ['Fleet', '#fleetPanel .card[data-task="SK-007"]', 'SK-007'],
  ['Crew', '#crewSheet[open] #roster .rrow', 'FIRSTMATE'],
  ['Log', '#logSheet[open] #log li', 'worker-5'],
]) {
  test(`capture: ${view} view has visible content`, async ({}, info) => {
    const {pages} = capture('served', info);
    const visible = pages.filter((shot: {view: string}) => shot.view === view)
      .flatMap((shot: {elements: any[]}) => shot.elements)
      .filter((element: any) => element.selector === selector && element.visible);
    expect(visible.map((element: any) => element.text).join('\n'),
      `${view} fixture panel must be visible in a captured page`).toContain(content);
  });
}

test('capture: remote request blocked', async ({}, info) => {
  const {record, pages} = capture('remote', info);
  const blocked = record.blocked.map((request: {url: string}) => request.url);
  expect(blocked).toContain('https://example.invalid/api');
  expect(blocked).toContain('https://example.invalid/image.png');
  expect(blocked).toContain('wss://example.invalid/socket');
  expect(pages[0].text).toContain('offline fixture');
});

test('capture: file pages unchanged', async ({}, info) => {
  const {record, pages} = capture('file', info);
  expect(record.blocked).toEqual([]);
  expect(pages).toHaveLength(1);
  expect(pages[0].url).toMatch(/^file:/);
  expect(pages[0].text).toContain('file fixture');
});
