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
test('retained actor activity is localized, run-specific and never guessed from task stage', async ({page})=>{
  const root=makeRoot([],false);
  const spec={tasks:readTasks(root)};
  spec.tasks=spec.tasks.filter((t:any)=>!['T-034','T-035'].includes(t.id));writeTasks(root,spec.tasks);
  emitFixture(root,'worker-rowan','T-034','dispatched','Rowan builds captain decisions','Rowan 實作船長決策',{crew_name:'Rowan',role:'worker'});
  emitFixture(root,'worker-mira','T-035','dispatched','Mira implements safe startup','Mira 實作安全啟動',{crew_name:'Mira',role:'worker'});
  emitFixture(root,'firstmate','T-034','dispatched','Coordinate the decision work','協調決策工作');
  emitFixture(root,'reviewer-sam','T-034','dispatched','Sam reviews decisions','Sam 審查決策',{role:'reviewer',crew_name:'Sam'});
  emitFixture(root,'reviewer-bea','T-036','review_opened','Bea reviews captain decisions','Bea 審查船長決策',{role:'reviewer',crew_name:'Bea'});
  emitFixture(root,'worker-gap','T-001','dispatched');
  emitFixture(root,'worker-unknown','T-035','criteria_returned');
  emitFixture(root,'worker-rowan','T-034','gate_failed');
  for(let i=0;i<45;i++)emitFixture(root,'github','T-900','commit_pushed','Technical update '+i,'技術更新 '+i);
  emitFixture(root,'worker-rowan','T-034','criteria_returned','Technical criteria','技術準則');
  const b=await startBoard(root);
  try {
    const state=await (await fetch(b.url+'/api/state')).json();
    expect(state.recent).toHaveLength(40);
    expect(state.crew.find((c:any)=>c.id==='worker-rowan')).toMatchObject({state:'gate',crew_name:'Rowan',activity:{en:'Rowan builds captain decisions'}});
    expect(state.crew.find((c:any)=>c.id==='reviewer-sam').state).toBe('review');
    expect(state.crew.find((c:any)=>c.id==='reviewer-bea')).toMatchObject({state:'review',activity:{en:'Bea reviews captain decisions'}});
    expect(state.crew.find((c:any)=>c.id==='worker-unknown').state).toBe('unknown');
    expect(state.crew.find((c:any)=>c.id==='firstmate').activity.en).toBe('Coordinate the decision work');
    await page.goto(b.url+'/?lang=en');
    for(const locale of ['en','zh-TW','zh-CN']) {
      await page.locator(`[data-l="${locale}"]`).click();
      const text=locale==='en'?'Rowan builds captain decisions':locale==='zh-TW'?'Rowan 實作船長決策':CN_ACTIVITY.build;
      await expect(page.locator('.roster')).toContainText(text);
      await expect(page.locator('[data-crew="worker-rowan"]')).toHaveAttribute('aria-label',new RegExp(text));
      await expect(page.locator('.roster')).toContainText(locale==='en'?EN.descriptionUnavailable:locale==='zh-TW'?TW.descriptionUnavailable:CN.descriptionUnavailable);
      await expect(page.locator('.pb')).toHaveCount(0);
    }
    emitFixture(root,'worker-rowan','T-034','agent_finished');
    emitFixture(root,'worker-rowan','T-034','commit_pushed');
    await expect(page.locator('[data-crew="worker-rowan"]')).toHaveCount(0);
    emitFixture(root,'worker-rowan-new','T-034','dispatched','Rowan tests decisions','Rowan 測試決策',{crew_name:'Rowan',role:'worker'});
    await expect(page.locator('[data-crew="worker-rowan-new"]')).toHaveAttribute('aria-label',new RegExp(CN_ACTIVITY.test));
    spec.tasks.push({id:'T-034',title:'Scalar title is not a translation',activity:{en:'Verify literal captain orders','zh-TW':'驗證船長原文命令'},depends_on:[]});
    writeTasks(root,spec.tasks);
    emitFixture(root,'worker-rowan-new','T-034','criteria_returned');
    // T-036: replayed event activity beats static task.activity; criteria_returned
    // does not replace the dispatch summary already on the actor.
    await expect(page.locator('[data-crew="worker-rowan-new"]')).toHaveAttribute('aria-label',new RegExp(CN_ACTIVITY.test));
    await expect(page.locator('[data-crew="worker-rowan-new"] .fig')).toHaveClass(/s-working/);
    await expect(page.locator('[data-crew="worker-rowan"]')).toHaveCount(0);
    await expect(page.locator('.roster .nm').filter({hasText:/^Rowan$/})).toHaveCount(1);
    expect((await (await fetch(b.url+'/api/state')).json()).crew.filter((c:any)=>c.role==='firstmate')).toHaveLength(1);
  }finally{stopBoard(b);}
});

test('real directed handoffs travel, react once and retain pointer ownership through refresh', async ({page})=>{
  const root=makeRoot([],false);
  emitFixture(root,'worker-real','T-034','dispatched','Build decision cards','實作決策卡片',{role:'worker'});
  emitFixture(root,'reviewer-real','T-034','dispatched','Review decision cards','審查決策卡片',{role:'reviewer'});
  const b=await startBoard(root);
  try {
    await page.goto(b.url+'/?lang=en');
    await expect(page.locator('[data-crew="worker-real"]')).toBeVisible();
    await expect(page.locator('.handoff')).toHaveCount(0);
    // paused, not just installed: an installed clock still runs in real
    // time, and on a loaded machine the real seconds between the steps
    // below ran the 2.3 s cue out before it was read. Paused, the cue's
    // time is only what runFor gives it.
    await page.clock.install();await page.clock.pauseAt(Date.now()+60_000);
    emitFixture(root,'reviewer-real','T-034','review_opened','Review ready','開始審查');
    await page.evaluate("fetch('/api/state').then(r=>r.json()).then(render)");
    await page.clock.runFor(32);
    const cue=page.locator('.handoff[data-kind="work"]');
    await expect(cue).toHaveAttribute('data-from','worker-real');await expect(cue).toHaveAttribute('data-to','reviewer-real');
    const start=await cue.boundingBox();const identity=await cue.getAttribute('data-identity');
    await page.clock.runFor(650);const middle=await cue.boundingBox();
    expect(Math.hypot(middle!.x-start!.x,middle!.y-start!.y)).toBeGreaterThan(10);
    await page.evaluate("fetch('/api/state').then(r=>r.json()).then(render)");
    await page.locator('[data-l="zh-TW"]').click();await page.locator('#history summary').click();
    await page.setViewportSize({width:390,height:844});
    await page.clock.runFor(800);
    await expect(cue).toHaveAttribute('data-identity',identity!);
    await expect(page.locator('[data-crew="reviewer-real"]')).toHaveClass(/react/);
    await expect(page.locator('[data-bubble="reviewer-real"]')).toHaveClass(/ping/);
    const end=await cue.boundingBox(),receiver=await page.locator('[data-crew="reviewer-real"]').boundingBox();
    expect(Math.abs(end!.x+end!.width/2-receiver!.x-receiver!.width/2)).toBeLessThan(4);
    await page.clock.runFor(1000);await expect(cue).toHaveCount(0);
    await page.evaluate("fetch('/api/state').then(r=>r.json()).then(render)");await page.clock.runFor(50);await expect(cue).toHaveCount(0);
    emitFixture(root,'reviewer-real','T-034','review_failed','No review produced','未產生審查');
    expect((await (await fetch(b.url+'/api/state')).json()).handoffs.filter((h:any)=>h.kind==='reject')).toHaveLength(0);
    await page.evaluate("fetch('/api/state').then(r=>r.json()).then(render)");await page.clock.runFor(32);
    await expect(page.locator('.handoff[data-kind="reject"]')).toHaveCount(0);
    emitFixture(root,'reviewer-real','T-034','review_failed','Changes requested','要求修改',{review_outcome:'rejected'});
    expect((await (await fetch(b.url+'/api/state')).json()).handoffs.filter((h:any)=>h.kind==='reject')).toHaveLength(1);
    await page.evaluate("fetch('/api/state').then(r=>r.json()).then(render)");await page.clock.runFor(32);
    await expect(page.locator('.handoff[data-kind="reject"]')).toHaveAttribute('data-to','worker-real');
    const worker=page.locator('[data-crew="worker-real"]'), reviewer=page.locator('[data-crew="reviewer-real"]');
    await worker.scrollIntoViewIfNeeded();const box=await worker.boundingBox();
    const other=await reviewer.evaluate(el=>getComputedStyle(el).transform);
    await page.mouse.move(box!.x+box!.width/2,box!.y+box!.height/2);await page.mouse.down();
    await page.evaluate("fetch('/api/state').then(r=>r.json()).then(render)");
    await page.mouse.move(box!.x+box!.width/2+45,box!.y+box!.height/2);await page.mouse.up();
    expect(await worker.evaluate(el=>(el as HTMLElement).style.getPropertyValue('--ry'))).not.toBe('');
    expect(await reviewer.evaluate(el=>getComputedStyle(el).transform)).toBe(other);
    await page.clock.runFor(2500);
    const scene=await page.locator('.scene').boundingBox();
    await page.mouse.move(scene!.x+12,scene!.y+scene!.height-20);await page.mouse.down();
    await page.mouse.move(scene!.x+52,scene!.y+scene!.height-20);await page.mouse.up();
    expect(await reviewer.evaluate(el=>(el as HTMLElement).style.getPropertyValue('--ry'))).not.toBe('');
    await page.mouse.dblclick(scene!.x+12,scene!.y+scene!.height-20);
    expect(await reviewer.evaluate(el=>(el as HTMLElement).style.getPropertyValue('--ry'))).toBe('');
    expect(await worker.evaluate(el=>(el as HTMLElement).style.getPropertyValue('--ry'))).toBe('');
    await page.emulateMedia({reducedMotion:'reduce'});
    emitFixture(root,'reviewer-real','T-034','approved','Review approved','審查通過');
    await page.evaluate("fetch('/api/state').then(r=>r.json()).then(render)");await page.clock.runFor(32);
    await expect(page.locator('.handoff.static')).toContainText('reviewer-real');
    await expect(page.locator('.handoff.static')).toContainText(TW.roleFirstmate);
    await expect(page.locator('.pivot.react')).toHaveCount(0);
    await page.clock.runFor(2400);
    emitFixture(root,'worker-real','T-034','agent_finished');
    emitFixture(root,'reviewer-real','T-034','review_failed','Reject again','再次拒絕',{review_outcome:'rejected'});
    await page.evaluate("fetch('/api/state').then(r=>r.json()).then(render)");await page.clock.runFor(32);
    // T-145: a worker that has left the deck is the normal end of a round,
    // not a participant the board cannot confirm: the cue names its role
    // and says nothing more
    await expect(page.locator('.handoff.static[data-kind="reject"]')).toContainText(TW.roleWorker);
    await expect(page.locator('.handoffs')).not.toContainText(TW.handoffUnavailable);
    await expect(page.locator('[data-crew="worker-real"]')).toHaveCount(0);
  }finally{stopBoard(b);}
});

test('T-145: a verdict from a reviewer who has just left the deck is shown quietly, and an actor the board cannot place is said once', async ({page})=>{
  const root=makeRoot([],false);
  emitFixture(root,'worker-q','T-034','dispatched','Build decision cards','實作決策卡片',{role:'worker'});
  emitFixture(root,'reviewer-q','T-034','dispatched','Review decision cards','審查決策卡片',{role:'reviewer'});
  const b=await startBoard(root);
  try {
    await page.goto(b.url+'/?lang=en');
    await expect(page.locator('[data-crew="reviewer-q"]')).toBeVisible();
    await page.clock.install();await page.clock.pauseAt(Date.now()+60_000);
    const redraw=async(expectedCount=1)=>{
      await page.evaluate("fetch('/api/state').then(r=>r.json()).then(render)");
      await expect(page.locator('.handoff')).toHaveCount(expectedCount);
      // SSE may render between the fetch and this callback. Drive animation
      // frames until every current cue has actually rendered its label.
      await expect.poll(async()=>{
        await page.clock.runFor(16);
        return page.locator('.handoff').evaluateAll(cues=>cues.every(cue=>!!cue.textContent));
      }, { intervals: [50] }).toBe(true);
    };
    const finishCues=async()=>{
      await expect.poll(async()=>{
        await page.clock.runFor(100);
        return page.locator('.handoff').count();
      }, { timeout: 15_000, intervals: [50] }).toBe(0);
    };
    // the verdict and the leaving land together, as they do at a round's end
    emitFixture(root,'reviewer-q','T-034','approved','Review approved','審查通過');
    emitFixture(root,'reviewer-q','T-034','agent_finished');
    await redraw();
    await expect(page.locator('[data-crew="reviewer-q"]')).toHaveCount(0);
    const approve=page.locator('.handoff[data-kind="approve"]');
    await expect(approve).toHaveAttribute('data-from','reviewer-q');
    // it travels, from the station of a crewman no longer aboard, and is not
    // turned into a line of text with a notice on it
    await expect(approve).not.toHaveClass(/static/);
    await expect(approve).toHaveText('✓');
    await expect(page.locator('.handoffs')).not.toContainText(EN.handoffUnavailable);
    await finishCues();
    await expect(approve).toHaveCount(0);
    // the reviewer rejects and leaves, and the worker has left before it
    emitFixture(root,'worker-q','T-034','agent_finished');
    emitFixture(root,'reviewer-q','T-034','dispatched','Review again','再審',{role:'reviewer'});
    emitFixture(root,'reviewer-q','T-034','review_failed','Changes requested','要求修改',{review_outcome:'rejected'});
    emitFixture(root,'reviewer-q','T-034','agent_finished');
    await redraw();
    const reject=page.locator('.handoff[data-kind="reject"]');
    await expect(reject).toHaveCount(1);
    await expect(reject).not.toHaveClass(/static/);
    await expect(page.locator('.handoffs')).not.toContainText(EN.handoffUnavailable);
    await finishCues();
    // a crewman with a name that says no role is placed by what it was
    // dispatched as, which the server knows, and leaves as quietly
    emitFixture(root,'secondmate','T-034','dispatched','Odd job','怪差事');
    emitFixture(root,'secondmate','T-034','agent_finished');
    await redraw();
    const second=page.locator('.handoff[data-kind="order"][data-to="secondmate"]');
    await expect(second).toHaveCount(1);
    await expect(second).not.toHaveAttribute('data-unknown',/./);
    await expect(page.locator('.handoffs')).not.toContainText(EN.handoffUnavailable);
    await finishCues();
    // an actor the board cannot place - never dispatched, never said what it
    // is, and not aboard - is the one case said, and said once, not once per
    // event
    emitFixture(root,'mystery','T-034','approved','Approved','通過');
    // Render the verdict before the finish event: SSE can observe this
    // intermediate state in production. An unknown actor must not board.
    await redraw();
    const odd=page.locator('.handoff[data-kind="approve"][data-from="mystery"]');
    await expect(page.locator('[data-crew="mystery"]')).toHaveCount(0);
    await expect(odd).toHaveAttribute('data-unknown','mystery');
    emitFixture(root,'mystery','T-034','approved','Approved again','再次通過');
    emitFixture(root,'mystery','T-034','agent_finished');
    await redraw(2);
    await expect(odd).toHaveCount(2);
    await expect(odd.first()).toHaveAttribute('data-unknown','mystery');
    await expect(odd.nth(1)).not.toHaveAttribute('data-unknown',/./);
    await expect(page.locator('.handoff[data-unknown]')).toHaveCount(1);
    await expect(page.locator('.handoff[data-unknown]')).toContainText(EN.handoffUnavailable);
  }finally{stopBoard(b);}
});

