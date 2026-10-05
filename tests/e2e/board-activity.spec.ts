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
      await expect(page.locator('[data-roster="worker-rowan"]')).toContainText(text);
      await expect(page.locator('.roster')).toContainText(locale==='en'?EN.descriptionUnavailable:locale==='zh-TW'?TW.descriptionUnavailable:CN.descriptionUnavailable);
      await expect(page.locator('.pb')).toHaveCount(0);
    }
    emitFixture(root,'worker-rowan','T-034','agent_finished');
    emitFixture(root,'worker-rowan','T-034','commit_pushed');
    await expect(page.locator('[data-roster="worker-rowan"]')).toHaveCount(0);
    emitFixture(root,'worker-rowan-new','T-034','dispatched','Rowan tests decisions','Rowan 測試決策',{crew_name:'Rowan',role:'worker'});
    await expect(page.locator('[data-roster="worker-rowan-new"]')).toContainText(CN_ACTIVITY.test);
    spec.tasks.push({id:'T-034',title:'Scalar title is not a translation',activity:{en:'Verify literal captain orders','zh-TW':'驗證船長原文命令'},depends_on:[]});
    writeTasks(root,spec.tasks);
    emitFixture(root,'worker-rowan-new','T-034','criteria_returned');
    // T-036: replayed event activity beats static task.activity; criteria_returned
    // does not replace the dispatch summary already on the actor.
    await expect(page.locator('[data-roster="worker-rowan-new"]')).toContainText(CN_ACTIVITY.test);
    await expect(page.locator('[data-roster="worker-rowan-new"]')).toHaveClass(/st-working/);
    await expect(page.locator('[data-roster="worker-rowan"]')).toHaveCount(0);
    await expect(page.locator('.roster .nm').filter({hasText:/^Rowan$/})).toHaveCount(1);
    expect((await (await fetch(b.url+'/api/state')).json()).crew.filter((c:any)=>c.role==='firstmate')).toHaveLength(1);
  }finally{await stopBoard(b);}
});

