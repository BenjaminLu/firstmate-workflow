import { showFleet, openCrewSheet } from './lib/board';
import { expect } from '@playwright/test';
import { chmodSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { test, makeRoot, writeProjects, writeTasks, projectState, startBoard, stopBoard, details } from './lib/fixture';

for (const viewport of [{width:1200,height:900}, {width:390,height:844}]) {
  test(`multi-project chips and task IDs stay one line at ${viewport.width}px`, async ({page}) => {
    test.setTimeout(90_000);
    const root = makeRoot([], false);
    const projects = ['firstmate-workflow', 'maker-founder-long-name'];
    const tasks = [221,222,223,224,225,226].map(n => ({id:`T-${n}`, title:`Chip layout ${n}`, depends_on:[]}));
    writeProjects(root, [
      {name:projects[0], github:'example/firstmate-workflow'},
      {name:projects[1], github:'example/maker-founder-long-name', tasks},
    ]);
    writeTasks(root, tasks);
    for (const project of projects) {
      const state = projectState(root, project);
      const events = [
        {actor:'captain', type:'greenlit'},
        {actor:`reviewer-${project}`, task:'T-222', type:'review_opened', pr:222, data:{role:'reviewer'}},
        {actor:'github', task:'T-223', type:'merged', pr:223},
      ].map(event => ({...event, project, ts:'2026-10-05T09:00:00Z', summary:{en:'Layout fixture', 'zh-TW':'版面測試'}}));
      writeFileSync(join(state, 'events.jsonl'), events.map(event => JSON.stringify(event)).join('\n') + '\n');
    }
    const state = projectState(root, projects[1]);
    for (const n of [224,225]) {
      const id = `D-maker-founder-long-name-T${n}-1`;
      writeFileSync(join(state, `pending/${id}.json`), JSON.stringify({id, project:projects[1], task:`T-${n}`, kind:'choice', details}));
    }
    const merging = 'D-maker-founder-long-name-T226-1';
    writeFileSync(join(state, `decisions/${merging}.json`), JSON.stringify({
      id:merging, project:projects[1], task:'T-226', pr:226, kind:'merge', chosen:'A',
      ts:'2026-10-05T09:00:00Z', identity:`decision:${merging}`, merge:'running',
    }));
    // Keep reconciliation of the recorded running merge local and unresolved.
    const gh = join(root, 'bin/gh');
    writeFileSync(gh, '#!/usr/bin/env bash\nexit 1\n');
    chmodSync(gh, 0o755);
    const board = await startBoard(root, {FM_GH:gh});
    try {
      await page.setViewportSize(viewport);
      await page.goto(`${board.url}/?lang=en`);
      await showFleet(page);
      for (const [lane, task] of [['ready','T-221'], ['review','T-222'], ['merged','T-223']]) {
        await expect(page.locator(`[data-lane="${lane}"] [data-task="${task}"] .hd .pchip`)).toHaveCount(2);
      }
      await expect(page.locator('[data-lane="review"] .hd a[data-pr]').first()).toBeVisible();
      await expect(page.locator('[data-lane="ready"] .cmenu').first()).toBeVisible();
      await page.locator('#history > summary').click();
      await expect(page.locator('#history .hd .pchip').first()).toBeVisible();
      const collectChips = async () => await page.locator('.pchip:visible').evaluateAll(els => els.map(el => ({
        text:el.textContent, roster:el.matches('.pj.pchip'),
        height:el.getBoundingClientRect().height, font:parseFloat(getComputedStyle(el).fontSize),
      })));
      const chips = await collectChips();
      // Exercise the inline chip callers too, including the drop confirmation.
      const ready = page.locator(`[data-lane="ready"] [data-project="${projects[1]}"][data-task="T-221"]`);
      await ready.locator('.cmenu').click();
      await ready.locator('[data-act="drop"]').click();
      for (const selector of ['#dropConfirm .pchip', '#roster .pj.pchip', '#deck .meta .pchip', '.dstrip > summary .pchip', '#merging .pchip']) {
        if (selector.startsWith('#roster')) await openCrewSheet(page);
        else {
          if (await page.locator('#crewSheet').isVisible()) await page.locator('#crewSheet [data-sheet-close]').click();
          if (selector.startsWith('#deck') || selector.startsWith('.dstrip')) await page.locator('#tabDecisions').click();
        }
        await expect(page.locator(selector).first()).toBeVisible();
        if (selector.startsWith('#roster')) chips.push(...await collectChips());
      }

      chips.push(...await collectChips());
      expect(chips.length).toBeGreaterThan(0);
      for (const chip of chips) {
        // Phone roster cells deliberately include a block project label.
        if (viewport.width === 390 && chip.roster) continue;
        expect(chip.height, `one-line chip: ${chip.text}`).toBeLessThanOrEqual(chip.font * 1.6 + 4);
      }
      await showFleet(page);
      const ids = await page.locator('.card .id:visible').evaluateAll(els => els.map(el => ({
        text:el.textContent, height:el.getBoundingClientRect().height,
        font:parseFloat(getComputedStyle(el).fontSize), scroll:el.scrollWidth, client:el.clientWidth,
      })));
      expect(ids.length).toBeGreaterThan(0);
      for (const id of ids) {
        expect(id.height, `one-line ID: ${id.text}`).toBeLessThanOrEqual(id.font * 1.6 + 2);
        expect(id.scroll, `uncut ID: ${id.text}`).toBeLessThanOrEqual(id.client + 1);
      }
      const children = await page.locator('.card .hd > :visible:not(.cmenu)').evaluateAll(els => els.map(el => ({
        text:el.textContent, height:el.getBoundingClientRect().height, font:parseFloat(getComputedStyle(el).fontSize),
      })));
      for (const child of children) {
        expect(child.height, `one-line header child: ${child.text}`).toBeLessThanOrEqual(child.font * 1.6 + 4);
      }
      if (viewport.width === 1200) {
        const positions = await page.locator(`.card .hd .pchip[data-chip="${projects[1]}"]:visible`).evaluateAll(els => els.map(el => {
          const chip = el.getBoundingClientRect(), id = el.parentElement!.querySelector('.id')!.getBoundingClientRect();
          return {sameLine:Math.abs((chip.top + chip.bottom) / 2 - (id.top + id.bottom) / 2) <= 1,
            below:chip.top >= id.bottom - 1};
        }));
        expect(positions.length).toBeGreaterThan(0);
        for (const position of positions) expect(position.sameLine || position.below, 'chip beside or wholly below ID').toBe(true);
      }
    } finally { await stopBoard(board); }
  });
}
