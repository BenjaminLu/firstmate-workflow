// T-299: run real captures in the CI job that installs Chromium.
// Dependencies: bin/lib/fm_design.py bin/lib/fm-design-capture.mjs
// bin/lib/fm_capture_server.py tests/e2e/capture-server.sh
// tests/e2e/lib/capture-server.ts tests/e2e/lib/fixture.ts tests/e2e/lib/capture-pages.py
import { test, expect, type TestInfo } from '@playwright/test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { resolve, join } from 'node:path';

function capture(mode: string, info: TestInfo) {
  const out = info.outputPath('capture');
  const result = spawnSync('python3', [resolve('tests/e2e/lib/capture-pages.py'), mode, out], {
    encoding: 'utf8', env: {...process.env, PYTHONDONTWRITEBYTECODE: '1'},
  });
  expect(result.status, `${result.error || ''}\n${result.stdout}\n${result.stderr}`).toBe(0);
  const record = JSON.parse(readFileSync(join(out, 'requests.json'), 'utf8'));
  for (const shot of record.pages) {
    expect(readFileSync(join(out, shot.file)).subarray(0, 8))
      .toEqual(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  }
  return {
    record,
    server: JSON.parse(readFileSync(join(out, 'server.json'), 'utf8')),
  };
}

test('capture: served page has content', async ({}, info) => {
  const {record, server} = capture('served', info);
  expect(server).not.toBeNull();
  expect(record.pages.map((shot: {view: string}) => shot.view))
    .toEqual(['Decisions', 'Fleet', 'Crew', 'Log']);
  for (const [view, selector, content] of [
    ['Decisions', '#decisionsPanel #card-D-1', 'SK-007'],
    ['Fleet', '#fleetPanel .card[data-task="SK-007"]', 'SK-007'],
    ['Crew', '#crewSheet[open] #roster .rrow', 'FIRSTMATE'],
    ['Log', '#logSheet[open] #log li', 'worker-5'],
  ]) {
    const shot = record.pages.find((shot: {view: string}) => shot.view === view);
    expect(shot.ready).toBe(selector);
    expect(shot.readyVisible, `${view} fixture panel must be visible`).toBe(true);
    expect(shot.readyText).toContain(content);
  }
});

test('capture: remote request blocked', async ({}, info) => {
  const {record} = capture('remote', info);
  const blocked = record.blocked.map((request: {url: string}) => request.url);
  expect(blocked).toContain('https://example.invalid/api');
  expect(blocked).toContain('https://example.invalid/image.png');
  expect(blocked).toContain('wss://example.invalid/socket');
  expect(record.pages[0].text).toContain('offline fixture');
});

test('capture: file pages unchanged', async ({}, info) => {
  const {record, server} = capture('file', info);
  expect(server).toBeNull();
  expect(record.blocked).toEqual([]);
  expect(record.pages[0].text).toContain('file fixture');
});
