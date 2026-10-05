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
test('continuation history, readable mobile content and persistent controls', async ({page},testInfo) => {
  const root = makeRoot(['working','review','gate']);
  const second=JSON.parse(JSON.stringify(details));
  second.en.title='Separate review results from publication';second.en.before='One shared status obscures review ownership';second.en.after='Independent review record and publication result';
  second['zh-TW'].title='分開審查結果與發布';second['zh-TW'].before='共用狀態隱藏審查責任';second['zh-TW'].after='獨立的審查記錄與發布結果';
  const pendingFile=join(root,'state/pending/D-1.json');
  const first=JSON.parse(readFileSync(pendingFile,'utf8'));
  for(const locale of ['en','zh-TW']) {
    first.details[locale].explanation=first.details[locale].explanation.repeat(8);
    (second as any)[locale].explanation=(second as any)[locale].explanation.repeat(8);
    for(const key of ['A','B','C']) (second as any)[locale].options[key].description=(second as any)[locale].options[key].description.repeat(3);
  }
  writeFileSync(pendingFile,JSON.stringify(first));
  writeFileSync(join(root,'state/pending/D-2.json'),JSON.stringify({id:'D-2',kind:'choice',task:'T-002',details:second}));
  const spec = {tasks:readTasks(root)};
  spec.tasks[4].title='https://example.invalid/'+ 'long-unbroken-title'.repeat(40);
  for (let i=0;i<30;i++) {
    spec.tasks.push({id:`H-${i}`,title:'Completed '+i,depends_on:[]});
    appendFileSync(join(root,'state/events.jsonl'), JSON.stringify({actor:'github',task:`H-${i}`,type:'merged',pr:100+i})+'\n');
  }
  appendFileSync(join(root,'state/events.jsonl'), JSON.stringify({actor:'worker-ghost',task:'T-999',type:'dispatched',summary:{en:'Unknown task work','zh-TW':'未知任務工作'},data:{role:'worker'}})+'\n');
  appendFileSync(join(root,'state/events.jsonl'), JSON.stringify({actor:'github',task:'T-999',type:'merged',pr:999})+'\n');
  writeFileSync(join(root,'state/pending/D-999.json'),JSON.stringify({id:'D-999',task:'T-999',kind:'choice',details}));
  writeTasks(root,spec.tasks);
  const b = await startBoard(root);
  try {
    await page.setViewportSize({width:390,height:844});
    await page.goto(b.url+'/?lang=en');
    await expect(page.locator('#history')).toHaveJSProperty('open',false);
    await expect(page.locator('#history summary')).toContainText('31');
    await expect(page.locator('[data-roster="worker-ghost"]')).toHaveCount(0);
    // a pending card under a merged task is shown, not hidden, and says the task is final (T-118)
    await expect(page.locator('#card-D-999 .final-note')).toContainText(
      EN.finalNote.replace('{task}','T-999').replace('{stage}',EN.laneMerged));
    for(const selector of ['.roster .jb','.rosterbar button','.roster .nm','.roster .st'])
      expect(await page.locator(selector).first().evaluate(el=>parseFloat(getComputedStyle(el).fontSize))).toBeGreaterThanOrEqual(13);
    await expect(page.locator('#history .card').first()).not.toBeVisible();
    expect((await page.locator('.dcard').first().boundingBox())!.y).toBeLessThan(844);
    // merged is a lane now, but a short one: the latest few, newest first,
    // and a pointer at the history for the rest
    const mergedLane=page.locator('[data-lane="merged"]');
    await expect(mergedLane.locator('h3 i')).toHaveText('31');
    await expect(mergedLane.locator('.card')).toHaveCount(5);
    await expect(mergedLane.locator('.card').first()).toContainText('T-999');
    await expect(mergedLane.locator('.more')).toHaveText(EN.mergedMore.replace('{n}','26'));
    await page.evaluate(async()=>{const s=await(await fetch('/api/state')).json();s.tasks=s.tasks.filter((t:any)=>t.stage!=='merged'||t.id==='H-0');(window as any).render(s);});
    await expect(page.locator('#history summary')).toContainText('1');
    await expect(mergedLane.locator('.card')).toHaveCount(1);
    await expect(mergedLane.locator('.more')).toHaveCount(0);
    await page.evaluate("fetch('/api/state').then(r=>r.json()).then(render)");
    await expect(page.locator('#history summary')).toContainText('31');
    let posts=0;page.on('request',r=>{if(r.method()==='POST')posts++;});
    await page.locator('#card-D-1 [data-c="custom"]').click();
    await page.locator('#card-D-1 textarea').fill('Literal 船長');
    await page.locator('#history summary').focus(); await page.keyboard.press('Enter');
    await expect(page.locator('#history .card')).toHaveCount(31);
    for(let i=0;i<30;i++)await expect(page.locator('#history .card').nth(i)).toContainText(`H-${i}`);
    await expect(page.locator('#history .card').nth(29)).toContainText('#129');
    await expect(page.locator('#history .card').last()).toContainText('T-999');
    await expect(page.locator('#history .card').last()).toContainText('#999');
    await page.evaluate("fetch('/api/state').then(r => r.json()).then(render)");
    await expect(page.locator('#history')).toHaveJSProperty('open',true);
    await expect(page.locator('#history summary')).toBeFocused();
    await expect(page.locator('#card-D-1 textarea')).toHaveValue('Literal 船長');
    await page.locator('#history summary').click();
    await page.locator('#card-D-1 textarea').focus();
    emitFixture(root,'github','T-005','merged','Completed task','任務已完成');
    await page.evaluate("fetch('/api/state').then(r=>r.json()).then(render)");
    await expect(page.locator('#history summary')).toContainText('32');
    await expect(page.locator('#history')).toHaveJSProperty('open',false);
    await expect(page.locator('#card-D-1 textarea')).toBeFocused();
    await page.evaluate("fetch('/api/state').then(r=>r.json()).then(render)");
    await page.locator('#history summary').focus();await page.keyboard.press('Enter');
    await expect(page.locator('#history')).toHaveJSProperty('open',true);
    for (const locale of ['en','zh-TW','zh-CN']) {
      await page.locator(`[data-l="${locale}"]`).click();
      for (const width of [320,390,768,1280]) {
        await page.setViewportSize({width,height:844});
        expect(await page.evaluate(()=>document.documentElement.scrollWidth<=document.documentElement.clientWidth+1)).toBe(true);
        expect(await page.evaluate(()=>document.documentElement.clientWidth)).toBe(width);
        for (const selector of ['.explanation','.tradeoffs','.opt','.card .t'])
          expect(await page.locator(selector).first().evaluate(el=>parseFloat(getComputedStyle(el).fontSize))).toBeGreaterThanOrEqual(16);
        expect((await page.locator('.confirm').first().boundingBox())!.height).toBeGreaterThanOrEqual(44);
        // one round trip per width: a locator call per element ran this test
        // past its budget on the runner once the history held 30-odd cards
        const outside=await page.evaluate(({selectors,width})=>selectors.flatMap(selector=>
          [...document.querySelectorAll(selector)].flatMap((el,i)=>{
            const r=el.getBoundingClientRect(),s=getComputedStyle(el);
            if(!r.width||!r.height||s.visibility!=='visible')return [];
            return r.x>=0&&r.x+r.width<=width+1?[]:[`${selector}[${i}] ${r.x}+${r.width}`];
          })),{selectors:['.langs','.opt','textarea','.confirm','.card','#history'],width});
        expect(outside).toEqual([]);
      }
    }
    await page.setViewportSize({width:1280,height:900});await page.evaluate(()=>scrollTo(0,0));
    await page.screenshot({path:testInfo.outputPath('desktop-decisions.png')});
    await page.locator('#roster').screenshot({path:testInfo.outputPath('desktop-roster.png')});
    await page.setViewportSize({width:320,height:844});
    await page.evaluate(()=>scrollTo(0,0));await page.screenshot({path:testInfo.outputPath('mobile-decisions.png')});
    await page.locator('#roster').screenshot({path:testInfo.outputPath('mobile-roster.png')});
    await page.addStyleTag({content:'body{font-size:32px} .dcard h3{font-size:44px} .explanation,.tradeoffs,.acts button,.acts label,.acts textarea{font-size:32px}'});
    expect(await page.evaluate(()=>document.documentElement.scrollWidth<=320)).toBe(true);
    await expect(page.locator('#card-D-1 textarea')).toHaveValue('Literal 船長');
    expect(posts).toBe(0);
  } finally {await stopBoard(b);}
});

