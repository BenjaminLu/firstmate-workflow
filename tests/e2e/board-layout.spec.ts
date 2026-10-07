// The board, in a browser. Poses are asserted as classes and text as
// dictionary values, never as screenshots: a snapshot test of a ship that
// moves would fail on the animation and pass on the wrong crew.
import { expect, type Page } from "@playwright/test";
// `test` is the fixture's: every board a test starts is signed in to (T-122)
import { test, makeRoot, startBoard, stopBoard, writeRegistry, writeProjects, readTasks, writeTasks, ROOT, details, scriptHeaders, signInAddress, tabToken } from "./lib/fixture";
import { appendFileSync, readFileSync, existsSync, writeFileSync, rmSync, utimesSync, mkdirSync, chmodSync, unlinkSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { EN, TW, CN, T040_KEYS, T057_KEYS, CN_ACTIVITY, CN_DETAILS, CREW, emitFixture, emit, CN_T058, useBoard } from "./lib/board";
test('the prototype layout: engine badge, six lanes, portrait and strips, roster rows', async ({page}) => {
  test.setTimeout(90_000);
  const root = makeRoot(['working','gate','review']);
  // names nothing could have hard-coded
  writeFileSync(join(root,'config.yaml'),'vendor: vendor-alpha  # top\nreviewer:\n  vendor: vendor-beta\n');
  const spec = {tasks:readTasks(root)};
  const first = spec.tasks[0].id;
  spec.tasks.push({id:'T-QUEUE',title:'Queued behind unmerged work',depends_on:[first]});
  spec.tasks.push({id:'T-READY',title:'Nothing to wait on',depends_on:[]});
  writeTasks(root, spec.tasks);
  emitFixture(root,'captain','T-DECIDED','decision_requested','Dispatch T-DECIDED: a decided title','派工 T-DECIDED：決定的標題');
  emitFixture(root,'worker-absent','T-ABSENT','dispatched','Work on an unlisted task','處理未列出的任務',{role:'worker'});
  emitFixture(root,'worker-2',spec.tasks[1].id,'gate_failed','Fail-first failed','第四道閘未過',{gate:5});
  emitFixture(root,'worker-1',first,'crew_status','Counting gates','計算閘門',{role:'worker',progress:{done:2,total:5}});
  writeFileSync(join(root,'state/pending/D-2.json'),JSON.stringify({id:'D-2',kind:'choice',task:spec.tasks[2].id,details}));
  const b = await startBoard(root);
  // the one-time sign-in's POST /login answers nothing; every other POST counts
  let posts = 0; page.on('request', r => { if (r.method() === 'POST' && new URL(r.url()).pathname !== '/login') posts++; });
  try {
    await page.setViewportSize({width:1280,height:900});
    await page.goto(`${b.url}/?lang=en`);
    await expect(page.locator('#roster .rrow').first()).toBeVisible();
    await expect(page.locator('#scene, #captain')).toHaveCount(0);
    await expect(page.locator('.rosterbar #rosterBtn')).toHaveCount(1);

    // V7: the engine from config.yaml, marked when review runs elsewhere
    await expect(page.locator('#engine')).toHaveText('vendor-alpha ⇄ vendor-beta');
    await expect(page.locator('#engine')).toHaveClass(/\bx\b/);
    writeFileSync(join(root,'config.yaml'),'vendor: vendor-alpha\nreviewer:\n  vendor: vendor-alpha\n');
    await page.evaluate(async () => (window as any).render(await (await fetch('/api/state')).json()));
    await expect(page.locator('#engine')).toHaveText('vendor-alpha');
    await expect(page.locator('#engine')).not.toHaveClass(/\bx\b/);

    // waiting on you counts the decisions, beside the other four
    await expect(page.locator('[data-count="waiting"] b')).toHaveText('2');
    expect(await page.locator('.counts [data-count]').evaluateAll(els => els.map(e => (e as HTMLElement).dataset.count)))
      .toEqual(['merged','inflight','waiting','blocked','ready','backlog']);

    // seven lanes in one row, left to right in lifecycle order
    const lanes = page.locator('#lanes .lane');
    expect(await lanes.evaluateAll(els => els.map(e => (e as HTMLElement).dataset.lane)))
      .toEqual(['backlog','ready','working','gate','review','captain','merged']);
    // ready and backlog each render with their own count, and the header
    // count is the lane's count: one derivation, shown twice
    for (const k of ['ready','backlog']) {
      const n = await page.locator(`[data-lane="${k}"] .card`).count();
      expect(n, `${k} lane has cards`).toBeGreaterThan(0);
      await expect(page.locator(`[data-lane="${k}"] h3 i`)).toHaveText(String(n));
      await expect(page.locator(`[data-count="${k}"] b`)).toHaveText(String(n));
      await expect(page.locator(`[data-lane="${k}"] h3`)).toContainText(EN[k === 'ready' ? 'laneReady' : 'laneBacklog']);
      await expect(page.locator(`[data-count="${k}"] span`)).toHaveText(EN[k]);
    }
    // a ready card could start now and shows no blocker
    await expect(page.locator('[data-lane="ready"] [data-task="T-READY"]')).toHaveCount(1);
    await expect(page.locator('[data-task="T-READY"] .dep')).toHaveCount(0);
    const boxes = await lanes.evaluateAll(els => els.map(e => e.getBoundingClientRect()).map(r => ({x:r.x,y:r.y})));
    for (let i = 1; i < boxes.length; i++) {
      expect(boxes[i].x).toBeGreaterThan(boxes[i-1].x);
      expect(Math.abs(boxes[i].y - boxes[0].y)).toBeLessThan(2);
    }
    // cards say what the log says, and nothing it does not
    const queued = page.locator('[data-task="T-QUEUE"]');
    await expect(queued).toContainText(`${EN.blockedOn} ${first}`);
    await expect(page.locator('[data-lane="backlog"] [data-task="T-QUEUE"]')).toHaveCount(1);
    await expect(page.locator('[data-task="T-DECIDED"] .t')).toHaveText('a decided title');
    await expect(page.locator('[data-task="T-ABSENT"] .t')).toHaveText(EN.titleMissing);
    await expect(page.locator('[data-task="T-ABSENT"]')).toContainText('worker-absent');
    await expect(page.locator(`[data-task="${spec.tasks[1].id}"] .badge`)).toHaveText(EN.gateFailedN.replace('{n}','4').replace('{label}', EN['gate_fail-first']));
    await expect(page.locator(`[data-lane="captain"] [data-task="${first}"] .badge`)).toContainText('D-1');
    await expect(page.locator(`[data-lane="captain"] [data-task="${spec.tasks[2].id}"] .badge`))
      .toHaveText(`D-2 · ${EN.optionsN.replace('{n}','3')}`);

    // the portrait sits beside the first full card; the next is a strip that
    // opens in place and keeps the two-stage confirmation
    const portrait = (await page.locator('#capstage').boundingBox())!, card = (await page.locator('#card-D-1').boundingBox())!;
    expect(portrait.x + portrait.width).toBeLessThanOrEqual(card.x);
    await expect(page.locator('#capstage .lbl')).toContainText(EN.roleCaptain);
    await expect(page.locator('#capstage .capimg')).toHaveAttribute('src', '/voyage2d/captain.webp');
    await expect(page.locator('#capstage .fig')).toHaveCount(0);
    await expect(page.locator('#strip-D-2')).toHaveJSProperty('open', false);
    await expect(page.locator('#card-D-2 .confirm')).toBeHidden();
    await page.locator('#strip-D-2 > summary').click();
    await expect(page.locator('#card-D-2 .confirm')).toBeVisible();
    await expect(page.locator('#card-D-2 .confirm')).toBeDisabled();
    await page.locator('#card-D-2 [data-c="B"]').click();
    await expect(page.locator('#card-D-2 .opt[data-c="B"]')).toHaveCSS('outline-style', 'solid');
    await expect(page.locator('#card-D-2 .opt[data-c="B"]')).toHaveCSS('outline-width', '2px');
    await expect(page.locator('#card-D-2 .confirm')).toBeEnabled();
    await expect(page.locator('#strip-D-2')).toHaveJSProperty('open', true);
    await expect(page.locator('#card-D-1 .links')).toContainText(`${EN.viewPr} #99`);

    // roster rows; a bar only for the one with bounded progress, never a %
    await expect(page.locator('.roster li.rrow')).toHaveCount(4 + 1);
    await expect(page.locator('.roster .pb')).toHaveCount(1);
    await expect(page.locator('.roster [data-roster="worker-1"] .pb')).toHaveAttribute('aria-valuemax','5');
    expect(await page.locator('#shipregion').innerText()).not.toMatch(/\d+\s*%/);
    await page.locator('#rosterBtn').click();
    await expect(page.locator('#roster')).toBeHidden();
    await expect(page.locator('#rosterBtn')).toHaveAttribute('aria-pressed','false');
    expect(await page.evaluate(() => localStorage.getItem('board.roster'))).toBe('hidden');
    await page.reload();
    await expect(page.locator('#roster')).toBeHidden();
    await page.locator('#rosterBtn').click();
    await expect(page.locator('#roster')).toBeVisible();

    // the live log is the full-width panel at the bottom
    const log = (await page.locator('.logwrap').boundingBox())!, lanesBox = (await page.locator('#lanes').boundingBox())!;
    expect(log.y).toBeGreaterThan(lanesBox.y + lanesBox.height);
    expect(log.width).toBeGreaterThan(1200);

    // every width, every locale, and doubled text: nothing overflows the page
    await page.addStyleTag({content:'body{font-size:32px} .card .t,.roster .jb,.log li,.dcard h3,.explanation,.tradeoffs,.acts button,.dstrip>summary{font-size:32px}'});
    for (const locale of ['en','zh-TW','zh-CN']) {
      await page.locator(`[data-l="${locale}"]`).click();
      const want = locale === 'en' ? EN : locale === 'zh-TW' ? TW : CN;
      await expect(page.locator('[data-count="waiting"] span')).toHaveText(want.waitingOnYou);
      await expect(page.locator('[data-task="T-DECIDED"] .t')).toHaveText(
        locale === 'en' ? 'a decided title' : locale === 'zh-TW' ? '決定的標題' : '决定的标题');
      await expect(page.locator('[data-task="T-ABSENT"] .t')).toHaveText(want.titleMissing);
      await expect(queued).toContainText(want.blockedOn);
      await expect(page.locator('#rosterBtn')).toHaveText(want.rosterBtn);
      await expect(page.locator('[data-count="ready"] span')).toHaveText(want.ready);
      await expect(page.locator('[data-count="backlog"] span')).toHaveText(want.backlog);
      await expect(page.locator('[data-lane="ready"] h3')).toContainText(want.laneReady);
      await expect(page.locator('[data-lane="backlog"] h3')).toContainText(want.laneBacklog);
      if (locale === 'zh-CN') {
        // the page's own conversion, against the oracle, for every new key
        for (const k of [...T040_KEYS, ...T057_KEYS]) {
          expect(CN, `no zh-CN oracle for ${k}`).toHaveProperty(k);
          expect(await page.evaluate((s) => (window as any).eval('cn')(s), TW[k]), k).toBe((CN as any)[k]);
        }
        // 閘門 survives only as a pair row; 門 on its own must convert too
        expect(await page.evaluate(() => (window as any).eval('cn')('門'))).toBe('门');
        await expect(page.locator(`[data-task="${spec.tasks[1].id}"] .badge`)).toHaveText(CN.gateFailedN.replace('{n}','4').replace('{label}', 'revert 后测试变红'));
        await expect(page.locator(`[data-lane="captain"] [data-task="${spec.tasks[2].id}"] .badge`))
          .toHaveText(`D-2 · ${CN.optionsN.replace('{n}','3')}`);
      }
      for (const width of [320,390,768,1280]) {
        await page.setViewportSize({width,height:844});
        expect(await page.evaluate(()=>document.documentElement.scrollWidth<=document.documentElement.clientWidth+1)).toBe(true);
      }
      await page.setViewportSize({width:1280,height:900});
    }
    expect(posts).toBe(0);

    // its dependency merging moves the backlog card to ready over the live
    // stream: no reload, no render called by hand
    emitFixture(root,'github',first,'merged','Merged','已合併');
    await expect(page.locator('[data-lane="ready"] [data-task="T-QUEUE"]')).toHaveCount(1, {timeout:15_000});
    await expect(page.locator('[data-lane="backlog"] [data-task="T-QUEUE"]')).toHaveCount(0);
    await expect(page.locator('[data-task="T-QUEUE"] .dep')).toHaveCount(0);
    const readyNow = await page.locator('[data-lane="ready"] .card').count();
    await expect(page.locator('[data-count="ready"] b')).toHaveText(String(readyNow));
  } finally {await stopBoard(b);}
});

// T-058: park, unpark and drop, each by the card's menu and by drag and drop

test('a missing captain image leaves only the portrait label', async ({page}) => {
  const root = makeRoot(['working']);
  const b = await startBoard(root);
  try {
    await page.route('**/voyage2d/captain.webp', route => route.fulfill({status:404, body:''}));
    await page.goto(`${b.url}/?lang=en`);
    await expect(page.locator('#capstage .capimg')).toBeHidden();
    await expect(page.locator('#capstage .lbl')).toContainText(EN.roleCaptain);
    await expect(page.locator('#capstage .fig')).toHaveCount(0);
  } finally { await stopBoard(b); }
});

test('a closed voyage keeps the roster and captain portrait synchronized', async ({page}) => {
  const root = makeRoot(['working'], false);
  const task = readTasks(root)[0].id;
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    await expect(page.locator('#voyage-stage')).toHaveCount(1);
    await page.keyboard.press('Escape'); await page.keyboard.press('Escape');
    await expect(page.locator('#voyage-stage')).toHaveCount(0);
    await expect(page.locator('#capstage')).toBeHidden();
    emitFixture(root, 'worker-hidden', task, 'dispatched', 'Still working with voyage closed', '航程關閉時繼續工作', {role:'worker'});
    writeFileSync(join(root,'state/pending/D-2.json'),JSON.stringify({id:'D-2',kind:'choice',task,details}));
    await expect(page.locator('[data-roster="worker-hidden"] .act')).toHaveText('Still working with voyage closed');
    await expect(page.locator('#card-D-2')).toBeVisible();
    await expect(page.locator('#capstage .capimg')).toHaveCount(1);
    await expect(page.locator('#capstage')).toHaveAttribute('data-pose','idle');
    await page.locator('#card-D-2 [data-c="B"]').click();
    await expect(page.locator('#capstage')).toHaveAttribute('data-pose','ready');
    await expect(page.locator('#capstage .lbl span')).toHaveText(EN.capReady);
    await page.locator('[data-l="zh-TW"]').click();
    await expect(page.locator('#capstage .lbl span')).toHaveText(TW.capReady);
    await expect(page.locator('[data-roster="worker-hidden"] .act')).toHaveText('航程關閉時繼續工作');
    await page.locator('#card-D-2 .confirm').click();
    await expect(page.locator('#capstage')).toHaveAttribute('data-pose','order');
    await expect(page.locator('#capstage .capimg')).toHaveCount(0);
    await expect(page.locator('#capstage')).toHaveAttribute('data-pose','idle');
    await expect(page.locator('#scene, #captain')).toHaveCount(0);
  } finally { await stopBoard(b); }
});
