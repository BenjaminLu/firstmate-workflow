// The board, in a browser. Poses are asserted as classes and text as
// dictionary values, never as screenshots: a snapshot test of a ship that
// moves would fail on the animation and pass on the wrong crew.
import { test, expect, type Page } from "@playwright/test";
import { makeRoot, startBoard, stopBoard, writeRegistry, writeProjects, readTasks, writeTasks, ROOT, details } from "./fixture";
import { appendFileSync, readFileSync, existsSync, writeFileSync, rmSync, utimesSync, mkdirSync, chmodSync, unlinkSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const EN = JSON.parse(readFileSync(join(ROOT, "i18n/ui.en.json"), "utf8"));
const TW = JSON.parse(readFileSync(join(ROOT, "i18n/ui.zh-TW.json"), "utf8"));
// Independently authored oracles: using the production conversion table here
// made an incorrect or incomplete table prove itself correct.
const CN = {merged:'已合并',inflight:'进行中',blocked:'受阻',aboard:'在船上',
  roster:'船员名册',descriptionUnavailable:'尚无工作说明',waitingOnYou:'等你拍板',
  titleMissing:'design/tasks.json 未列出标题',blockedOn:'卡在',gateFailedN:'第 {n} 道闸未过',
  optionsN:'{n} 个选项',rosterBtn:'名册',crossVendor:'跨供应商审核',mergedMore:'另 {n} 个在已完成历史中',
  dragHint:'拖曳人物可旋转单人 · 拖曳甲板转全员 · 双击复位',ahoyDemo:'试放礼炮（不写入事件）',
  orderDemo:'试演下令回应（不写入事件）',alsoWaiting:'其他待决（点开就地展开）',
  engine:'引擎',gateFailed:'闸门未过',viewDesign:'design.md',
  ready:'就绪',backlog:'待办',laneReady:'就绪',laneBacklog:'待办'};
// Every key T-040 added. Each must have an oracle above, and the board's own
// conversion must reproduce it: an oracle only some keys are checked against
// let 閘門未過 ship half-converted.
const T040_KEYS = ['engine','crossVendor','waitingOnYou','blockedOn','titleMissing','mergedMore',
  'gateFailed','gateFailedN','optionsN','rosterBtn','ahoyDemo','orderDemo','dragHint','alsoWaiting','viewDesign'];
// and every key T-057 added, held to the same rule
const T057_KEYS = ['ready','backlog','laneReady','laneBacklog'];
const CN_ACTIVITY = {
  build:'Rowan 实作船长决策', test:'Rowan 测试决策', literal:'验证船长原文命令',
  bea:'Bea 审查船长决策',
};
const CN_DETAILS = [
  {title:'缓存任务索引',explanation:'每次重新整理只读取一次索引。',before:'每张卡片重读任务文件',after:'每次重新整理共用一份索引',outcome:'已记录索引选择',options:{
    A:{description:'每次重新整理建立缓存',pros:'减少读取',cons:'占用内存'},
    B:{description:'保留各自读取',pros:'无需缓存',cons:'重复读取'},
    C:{description:'先测量',pros:'取得证据再变更',cons:'延后改善'}}},
  {title:'限制审查重试',explanation:'三次后停止',before:'无限重试',after:'最多三次',outcome:'已记录重试策略',options:{
    A:{description:'限制重试',pros:'可预测代价',cons:'需要手动恢复'},
    B:{description:'保留各自读取',pros:'无需缓存',cons:'重复读取'},
    C:{description:'先测量',pros:'取得证据再变更',cons:'延后改善'}}},
];
const CREW = ["working", "gate", "review", "working", "gate"] as const;

function emitFixture(root:string, actor:string, task:string, type:string, en='', tw='', data={}) {
  const args=[join(root,'bin/fm-emit.sh'),'--actor',actor,'--task',task,'--type',type,'--data',JSON.stringify(data)];
  if(en)args.push('--en',en,'--tw',tw);
  const result=spawnSync('bash',args,{env:{...process.env,FM_ROOT:root}});
  expect(result.status,result.stderr.toString()).toBe(0);
}

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
    await expect(page.locator('.handoff.static')).toContainText(TW.handoffUnavailable);
    await expect(page.locator('[data-crew="worker-real"]')).toHaveCount(0);
  }finally{stopBoard(b);}
});

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
    await expect(page.locator('[data-crew="worker-ghost"]')).toHaveCount(0);
    await expect(page.locator('#card-D-999')).toHaveCount(0);
    for(const selector of ['.bub .who','.bub .job','.shipbar button','.roster .nm','.roster .st'])
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
    const effect=await page.locator('.scene').getAttribute('data-effect');expect(effect).toBeTruthy();
    await page.evaluate("fetch('/api/state').then(r=>r.json()).then(render)");
    expect(await page.locator('.scene').getAttribute('data-effect')).toBe(effect);
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
    await page.locator('.scene').screenshot({path:testInfo.outputPath('desktop-ship.png')});
    await page.setViewportSize({width:320,height:844});
    await page.evaluate(()=>scrollTo(0,0));await page.screenshot({path:testInfo.outputPath('mobile-decisions.png')});
    await page.locator('.scene').screenshot({path:testInfo.outputPath('mobile-ship.png')});
    await page.addStyleTag({content:'body{font-size:32px} .dcard h3{font-size:44px} .explanation,.tradeoffs,.acts button,.acts label,.acts textarea{font-size:32px}'});
    expect(await page.evaluate(()=>document.documentElement.scrollWidth<=320)).toBe(true);
    await expect(page.locator('#card-D-1 textarea')).toHaveValue('Literal 船長');
    expect(posts).toBe(0);
  } finally {stopBoard(b);}
});

let board: Awaited<ReturnType<typeof startBoard>>;
test.beforeAll(async () => { board = await startBoard(makeRoot([...CREW])); });
test.afterAll(() => stopBoard(board));

// one mechanism at a time. Setting both meant neither was covered: the
// query parameter could have stopped working and the suite would have
// stayed green on the stored value.
const open = async (page: Page, lang: string, how: "query" | "stored" = "query", url = board.url) => {
  if (how === "query") {
    await page.goto(`${url}/?lang=${lang}`);
    await page.evaluate(() => localStorage.removeItem("board.lang"));
    await page.reload();
  } else {
    await page.goto(url);
    await page.evaluate((l) => localStorage.setItem("board.lang", l), lang);
    await page.goto(url);                 // no query parameter this time
  }
  await expect(page.locator(".scene .pivot").first()).toBeVisible();
};

// --- snapshots: all three languages -------------------------------------
for (const lang of ["en", "zh-TW", "zh-CN"]) {
  test(`the board reads in ${lang}`, async ({ page }) => {
    await open(page, lang);

    // the crew are agents: firstmate, one per working agent, the captain
    await expect(page.locator(".scene .pivot")).toHaveCount(CREW.length + 2);
    await expect(page.locator(".roster li")).toHaveCount(CREW.length + 1);
    for (const s of new Set(CREW)) {
      await expect(page.locator(`.scene .fig.s-${s}`).first()).toBeVisible();
    }
    // the captain is NOT on the deck: the crew are agents doing work and
    // he is the person they are waiting on
    await expect(page.locator(".scene .fig.r-cap")).toHaveCount(1);
    await expect(page.locator("#captain .fig.r-cap")).toHaveCount(1);
    // the badge counts the cards, rather than being pinned to the one
    // this fixture happens to have
    const cards = await page.locator(".dcard").count();
    await expect(page.locator("#pcount")).toHaveText(String(cards));
    expect(cards).toBeGreaterThan(0);
    // every crewman says who he is over his own head, and what he is on in
    // the card that head holds (T-116)
    await expect(page.locator(".scene .bub")).toHaveCount(CREW.length + 1);
    await expect(page.locator(".scene .bub:not(.mini) .job").first()).not.toBeEmpty();
    // the full bubbles name the agent; the chips below them name him too,
    // and the work is in each card and the roster (T-116)
    const named = await page.locator(".scene .bub:not(.mini) .who").allInnerTexts();
    const listed = await page.locator(".roster .nm").allInnerTexts();
    for (const n of named) expect(listed).toContain(n);
    // and the roster is named after the agents, not after the tasks
    const agents = listed.filter((n) => /^(worker|reviewer)-\d+$/.test(n));
    expect(agents.length).toBe(CREW.length);
    const jobs = await page.locator(".roster .jb").allInnerTexts();
    expect(jobs.some((j) => /^T-\d+/.test(j))).toBe(true);
    await expect(page.locator(".scene .port").first()).toBeVisible();
    await expect(page.locator(".scene .mast .sail").first()).toBeVisible();

    // t() falls back to the key itself, so the way to catch an unresolved
    // key is to read the label and compare it with the dictionary. A
    // substring scan would not do: "log" is inside plenty of honest text.
    const want = (k: string) => (lang === "en" ? EN : lang === "zh-TW" ? TW : CN)[k];
    const labels = await page.locator(".counts span").allInnerTexts();
    for (const [i, k] of ["merged", "inflight", "waitingOnYou", "blocked", "ready", "backlog"].entries()) {
      const w = want(k);
      // the stylesheet upper-cases these, so compare the words not the case
      expect(labels[i].toLowerCase()).toBe(w.toLowerCase());
    }
    const aboard = await page.locator(".shipbar span").nth(1).innerText();
    expect(aboard).toContain(want("aboard"));
    expect(aboard).toContain(`${CREW.length + 1}/24`);

    // and the language is the one that was asked for
    expect(await page.locator(".roster h3 span").first().innerText()).toBe(want("roster"));
    // and the conversion actually changed something, or "derived" would be
    // satisfied by a table that does nothing
    if (lang === "zh-CN") expect(CN.roster).not.toBe(TW.roster);
    expect(await page.evaluate(() => document.documentElement.lang)).toBe(lang);
  });
}

// --- interaction: zh-TW only --------------------------------------------
// its own board: answering a decision removes the captain from the crew, and
// a later test that counts the crew would then be reading this test's work
test("either mechanism picks the language on its own", async ({ page }) => {
  for (const how of ["query", "stored"] as const) {
    await open(page, "en", how);
    expect(await page.evaluate(() => document.documentElement.lang)).toBe("en");
    expect(await page.locator(".roster h3 span").first().innerText()).toBe(EN.roster);
    await open(page, "zh-TW", how);
    expect(await page.evaluate(() => document.documentElement.lang)).toBe("zh-TW");
    expect(await page.locator(".roster h3 span").first().innerText()).toBe(TW.roster);
  }
});

// Gate 3 is retired (T-114). A gate_failed naming it names no gate the board
// knows, so the badge carries no number; one naming gate 4 keeps its number.
test("a failed-gate badge numbers only a gate that exists: 3 is retired, 4 is kept", async ({ page }) => {
  const root = makeRoot([], false);
  const [three, four] = readTasks(root);
  emitFixture(root, 'worker-1', three.id, 'gate_failed', 'Gate three failed', '第三道閘未過', { gate: 3 });
  emitFixture(root, 'worker-2', four.id, 'gate_failed', 'Gate four failed', '第四道閘未過', { gate: 4 });
  const b = await startBoard(root);
  try {
    const state = await (await fetch(b.url + '/api/state')).json();
    const gateBadge = (id: string) =>
      state.tasks.find((t: any) => t.id === id).badges.filter((x: any) => x.kind === 'gate');
    expect(gateBadge(three.id)).toEqual([{ kind: 'gate', gate: null }]);
    expect(gateBadge(four.id)).toEqual([{ kind: 'gate', gate: 4 }]);
    await page.goto(`${b.url}/?lang=en`);
    await expect(page.locator(`[data-task="${three.id}"] .badge`)).toHaveText(EN.gateFailed);
    await expect(page.locator(`[data-task="${four.id}"] .badge`)).toHaveText(EN.gateFailedN.replace('{n}', '4'));
  } finally { stopBoard(b); }
});

test("the captain merges from the board", async ({ page }) => {
  // its own budget: this one starts a board inside the body, so the global
  // timeout has to cover the start as well as the assertions, and the
  // per-assertion timeouts below are dead letters without it
  test.setTimeout(60_000);
  const b = await startBoard(makeRoot([...CREW]));
  try {
  await page.goto(`${b.url}/?lang=zh-TW`);
  await expect(page.locator(".scene .pivot").first()).toBeVisible();
  const card = page.locator(".dcard").first();
  await expect(card).toBeVisible();
  await expect(card.locator(".gates li")).toHaveCount(6);   // gates 1, 2, 4, 5, 6, 7
  await expect(card.locator(".gates li.n")).toHaveCount(1);   // gate 7 open

  await expect(card.locator("button.confirm")).toBeDisabled();
  await card.locator('[data-c="A"]').click();
  expect(existsSync(join(b.root, "state/decisions/D-1.json"))).toBe(false);
  await expect(page.locator('#captain')).toHaveAttribute('data-pose', 'ready');
  await expect(page.locator('#captain .fig')).toHaveClass(/c-ready/);
  await card.locator("button.confirm").click();

  // the card going away is the visible half; the decision on disk and the
  // call to the one script allowed to merge are the half that matters. The
  // reply text is not asserted: the board re-renders as soon as it lands,
  // so a passing test would be racing the repaint.
  await expect(page.locator(".dcard")).toHaveCount(0, { timeout: 15_000 });
  const decision = join(b.root, "state/decisions/D-1.json");
  // all three side-effects land asynchronously; polling one and reading the
  // others is a race, and the recorder read throws ENOENT rather than
  // failing an assertion when it loses
  await expect.poll(() => existsSync(decision), { timeout: 15_000 }).toBe(true);
  await expect.poll(() => (existsSync(b.recorder) ? readFileSync(b.recorder, "utf8") : ""),
    { timeout: 15_000 }).toContain("--pr 99");
  await expect.poll(() => existsSync(join(b.root, "state/pending/D-1.json")),
    { timeout: 15_000 }).toBe(false);
  expect(JSON.parse(readFileSync(decision, "utf8")).chosen).toBe("A");
  } finally { stopBoard(b); }
});

test("custom selection is local, literal and never merges", async ({ page }) => {
  const b = await startBoard(makeRoot(["working"]));
  try {
    let posts = 0;
    page.on('request', r => { if (r.method() === 'POST') posts++; });
    await page.goto(`${b.url}/?lang=en`);
    const card = page.locator('.dcard');
    expect(await page.locator('#captain .tool').evaluate(el=>({height:getComputedStyle(el).height,background:getComputedStyle(el).backgroundColor,opacity:getComputedStyle(el).opacity})))
      .toEqual({height:'10px',background:'rgb(59, 38, 23)',opacity:'0.45'});
    await card.locator('[data-c="custom"]').click();
    expect(await page.locator('#captain .tool').evaluate(el=>getComputedStyle(el).height)).toBe('38px');
    await expect(card.locator('.confirm')).toBeDisabled();
    await card.locator('textarea').fill('🚢'.repeat(1001));
    await expect(card.locator('.confirm')).toBeDisabled();
    const literal = '  保留 🚢 <script>bad()</script> $(touch nope)  ';
    await card.locator('textarea').fill(literal);
    expect(posts).toBe(0);
    expect(existsSync(join(b.root, 'state/decisions/D-1.json'))).toBe(false);
    await card.locator('.confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText('AYE, CAPTAIN!');
    await expect(page.locator('#captain')).toBeVisible();
    await expect(page.locator('#captain')).toHaveAttribute('data-pose', 'order');
    expect(await page.locator('#captain .tool').evaluate(el=>({height:getComputedStyle(el).height,background:getComputedStyle(el).backgroundColor,opacity:getComputedStyle(el).opacity})))
      .toEqual({height:'52px',background:'rgb(232, 239, 247)',opacity:'1'});
    const stored = JSON.parse(readFileSync(join(b.root, 'state/decisions/D-1.json'), 'utf8'));
    expect(stored.chosen).toBe('custom');
    expect(stored.text).toBe(literal);
    expect(posts).toBe(1);
    expect(existsSync(b.recorder)).toBe(false);
    await expect(page.locator('.scene .fig.cheer')).toHaveCount(3);
    expect(await page.locator('.scene .fig.cheer .armR').evaluateAll(els=>els.every(el=>getComputedStyle(el).animationName === 'crewArms'))).toBe(true);
    await page.evaluate(async () => (window as any).render(await (await fetch('/api/state')).json()));
    await expect(page.locator('.scene .fig.cheer')).toHaveCount(3);
    const delays = await page.locator('.scene .fig.cheer').evaluateAll(els => els.map(el=>parseFloat((el as HTMLElement).style.animationDelay)));
    expect(delays[1] - delays[0]).toBeCloseTo(.055);
    await expect(page.locator('#salvo')).not.toHaveClass(/fire/);
    await page.locator('[data-l="zh-CN"]').click();
    await expect(page.locator('#orderFeedback')).toContainText(literal);
    await expect(page.locator('#orderFeedback script')).toHaveCount(0);
    await expect(page.locator('#captain')).toHaveAttribute('data-pose','idle',{timeout:15_000});
    await expect(page.locator('.scene #captain .r-cap')).toBeVisible();
  } finally { stopBoard(b); }
});

test('all authored fields switch locale, diagrams differ and input stays text', async ({page}) => {
  const root = makeRoot(['working']);
  const second = structuredClone(details);
  Object.assign(second.en,{title:'Limit review retries <img src=x onerror=alert(1)>',explanation:'Stop after three attempts',before:'Unlimited retries',after:'Three attempts',outcome:'Retry policy recorded'});
  Object.assign(second['zh-TW'],{title:'限制審查重試',explanation:'三次後停止',before:'無限重試',after:'最多三次',outcome:'已記錄重試策略'});
  second.en.options.A = {description:'Bound retries',pros:'Predictable cost',cons:'Needs manual recovery'};
  second['zh-TW'].options.A = {description:'限制重試',pros:'可預測代價',cons:'需要手動恢復'};
  writeFileSync(join(root,'state/pending/D-2.json'), JSON.stringify({id:'D-2',task:'T-2',kind:'choice',details:second}));
  expect(spawnSync('bash',[join(root,'bin/fm-diagram.sh'),'--decision','D-2','--repo',root]).status).toBe(0);
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    // the second decision is a strip until it is opened in place, and it
    // stays open through a language switch
    await expect(page.locator('#strip-D-2')).toHaveJSProperty('open', false);
    await page.locator('#strip-D-2 > summary').click();
    await expect(page.locator('#strip-D-2')).toHaveJSProperty('open', true);
    for (const lang of ['en','zh-TW','zh-CN']) {
      await page.locator(`[data-l="${lang}"]`).click();
      await expect(page.locator('#strip-D-2')).toHaveJSProperty('open', true);
      for (const [id, d, cn] of [['D-1', details, CN_DETAILS[0]], ['D-2', second, CN_DETAILS[1]]] as const) {
        const want = lang === 'en' ? d.en : lang === 'zh-TW' ? d['zh-TW'] : cn;
        const card = page.locator(`#card-${id}`);
        for (const field of ['title','explanation'] as const) await expect(card).toContainText(want[field]);
        for (const opt of Object.values(want.options)) for (const value of Object.values(opt)) await expect(card).toContainText(value);
        const frame = card.frameLocator('iframe');
        await expect(frame.locator('body')).toContainText(want.before);
        await expect(frame.locator('body')).toContainText(want.after);
        await expect(frame.locator('h1,button,.gates,.lanes')).toHaveCount(0);
      }
      if (lang === 'zh-CN') await expect(page.locator('#card-D-2 h3')).toHaveText('限制审查重试');
      await expect(page.locator('#card-D-1').locator('iframe:visible, .change-fallback:visible')).toHaveCount(1);
    }
    await expect(page.locator('.dcard img,.dcard script')).toHaveCount(0);
    await page.locator('#card-D-2 [data-c="B"]').click();
    await page.locator('#card-D-2 .confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText(CN_DETAILS[1].outcome);
    await page.locator('[data-l="en"]').click();
    await expect(page.locator('#orderFeedback')).toContainText(second.en.outcome);
    await expect(page.locator('#orderFeedback')).toContainText('AYE, CAPTAIN!');
  } finally {stopBoard(b);}
});

// T-047: a card whose id names its owner is listed, drawn and answered, and
// the card says which project and task the id belongs to
test('a card whose id names its project and task renders, draws and is answered', async ({page}) => {
  const root = makeRoot(['working'], false);
  const id = 'D-example-app-T004-1';
  writeFileSync(join(root,`state/pending/${id}.json`), JSON.stringify({id,task:'T-004',project:'example-app',kind:'choice',details}));
  expect(spawnSync('bash',[join(root,'bin/fm-diagram.sh'),'--decision',id,'--repo',root]).status).toBe(0);
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    const card = page.locator(`#card-${id}`);
    await expect(card).toContainText(details.en.title);
    await expect(card.locator('.meta')).toContainText(id);
    await expect(card.locator('.meta .project')).toHaveText('example-app');
    await expect(card.locator('.meta')).toContainText('T-004');
    const frame = card.frameLocator('iframe');
    await expect(frame.locator('body')).toContainText(details.en.before);
    await card.locator('[data-c="B"]').click();
    await card.locator('.confirm').click();
    await expect.poll(() => existsSync(join(root,`state/decisions/${id}.json`))).toBe(true);
    expect(JSON.parse(readFileSync(join(root,`state/decisions/${id}.json`),'utf8')).chosen).toBe('B');
  } finally {stopBoard(b);}
});

// T-112: fm.sh self-update raises D-SK-<n>. The captain's A on it is recorded
// like any other choice, and an answer the server refuses shows its error on
// the card instead of vanishing.
test('a skill-update card is answered, and a refused answer shows the server error on its card', async ({page}) => {
  const root = makeRoot(['working'], false);
  writeFileSync(join(root,'state/pending/D-SK-001.json'), JSON.stringify({id:'D-SK-001',task:'SK-001',kind:'choice',title:'adopt SK-001'}));
  writeFileSync(join(root,'state/pending/D-SK-01.json'), JSON.stringify({id:'D-SK-01',task:'SK-01',kind:'choice',title:'malformed'}));
  // fm-diagram.sh draws nothing for a skill id, so the drawing is placed by
  // hand: diagram.js's isDecision alone decides whether a card embeds it
  mkdirSync(join(root,'board/public/diagrams'), {recursive:true});
  for (const id of ['D-SK-001','D-SK-01'])
    writeFileSync(join(root,`board/public/diagrams/${id}.en.html`), `<!doctype html><body>drawing of ${id}</body>`);
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    await expect(page.locator('#card-D-SK-001')).toHaveCount(1);
    await expect(page.locator('#card-D-SK-01')).toHaveCount(1);
    // whichever sorts second is a strip, opened in place
    for (const id of ['D-SK-001','D-SK-01']) {
      const strip = page.locator(`#strip-${id}`);
      if (await strip.count()) await strip.locator('summary').click();
    }
    // diagram.js accepts D-SK-<n> like server.ts: the well-formed id embeds and
    // shows its drawing, the malformed one embeds nothing
    const frame = page.locator('#card-D-SK-001 iframe.dg[data-decision="D-SK-001"]');
    await expect(frame).toHaveAttribute('src', 'diagrams/D-SK-001.en.html');
    await expect(page.locator('#card-D-SK-001').frameLocator('iframe.dg').locator('body')).toContainText('drawing of D-SK-001');
    await expect(page.locator('#card-D-SK-01 iframe.dg')).toHaveCount(0);
    // Every mutation a screen reader would announce: an alert put into the
    // deck, or any change inside one. A refusal is announced once, however
    // often the deck is rendered after it.
    await page.evaluate(() => {
      const w = window as any; w.alerts = [];
      const inAlert = (n: Node | null) => (n instanceof Element ? n : n?.parentElement)?.closest('[role=alert]');
      w.alertWatch = new MutationObserver(records => { for (const m of records) {
        for (const n of m.addedNodes) if (n instanceof Element && (n.matches('[role=alert]') || n.querySelector('[role=alert]')))
          w.alerts.push('inserted: ' + n.textContent);
        if (m.type !== 'childList' && inAlert(m.target)) w.alerts.push(m.type + ': ' + (m.target as Node).textContent);
      } });
      w.alertWatch.observe(document.getElementById('deck'), {childList:true, subtree:true, characterData:true, attributes:true});
    });
    const rerender = () => page.evaluate(() => fetch('/api/state').then(r => r.json()).then((window as any).render));
    const bad = page.locator('#card-D-SK-01');
    await bad.locator('[data-c="A"]').click();
    await bad.locator('.confirm').click();
    await expect(bad.locator('.refused')).toContainText('bad decision id');
    expect(existsSync(join(root,'state/decisions/D-SK-01.json'))).toBe(false);
    await rerender(); await rerender();
    await bad.locator('[data-c="B"]').click();
    await expect(bad.locator('[data-c="B"]')).toHaveAttribute('aria-pressed', 'true');
    await expect(bad.locator('.refused')).toContainText('bad decision id');
    const alerts = await page.evaluate(() => { const w = window as any; w.alertWatch.disconnect(); return w.alerts; });
    expect(alerts).toHaveLength(1);
    expect(alerts[0]).toMatch(/^inserted: [\s\S]*bad decision id/);
    // A card that leaves pending takes its refusal with it, as it takes its
    // pick, draft and open strip: it comes back under the same id clean.
    const badPending = join(root,'state/pending/D-SK-01.json'), badBody = readFileSync(badPending,'utf8');
    unlinkSync(badPending); await rerender();
    await expect(bad).toHaveCount(0);
    writeFileSync(badPending, badBody); await rerender();
    await expect(bad).toHaveCount(1);
    await expect(bad.locator('.refused')).toHaveCount(0);
    // A refusal is cleared by the next attempt on that card. The first answer
    // on D-SK-001 is refused by the route below; the second is held until the
    // page has rendered the retry, so a stale refusal would still be on screen.
    let posts = 0, release = () => {};
    const held = new Promise<void>(r => { release = r; });
    await page.route('**/decisions', async route => {
      if (route.request().method() !== 'POST') return route.continue();
      if (++posts === 1) return route.fulfill({status:400, contentType:'application/json', body:JSON.stringify({error:'refused once by the test'})});
      await held; return route.continue();
    });
    const card = page.locator('#card-D-SK-001');
    await card.locator('[data-c="A"]').click();
    await card.locator('.confirm').click();
    await expect(card.locator('.refused')).toContainText('refused once by the test');
    expect(existsSync(join(root,'state/decisions/D-SK-001.json'))).toBe(false);
    await card.locator('[data-c="A"]').click();
    await card.locator('.confirm').click();
    await expect.poll(() => posts).toBe(2);
    await expect(card).toHaveCount(1);
    await expect(card.locator('.refused')).toHaveCount(0);
    release();
    await expect.poll(() => existsSync(join(root,'state/decisions/D-SK-001.json'))).toBe(true);
    expect(JSON.parse(readFileSync(join(root,'state/decisions/D-SK-001.json'),'utf8'))).toMatchObject({chosen:'A',task:'SK-001',kind:'choice'});
    await expect(page.locator('#orderFeedback')).toContainText('AYE, CAPTAIN!');
  } finally {stopBoard(b);}
});

const emit = (root:string, type:string, pr:number) => {
  const r = spawnSync('bash',[join(root,'bin/fm-emit.sh'),'--actor','github','--type',type,'--task',`T-${pr}`,'--pr',String(pr),'--en','fixture outcome','--tw','測試結果'], {env:{...process.env,FM_ROOT:root}});
  expect(r.status).toBe(0);
};
test('merge identities queue absent tasks, survive refresh and never replay history', async ({page}) => {
  test.setTimeout(60_000);
  const root = makeRoot(['working']); emit(root,'merged',880);
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    await expect(page.locator('.dcard')).toBeVisible();
    await expect(page.locator('#salvo')).not.toHaveClass(/fire/);
    emit(root,'merged',881); emit(root,'merged',882);
    await expect(page.locator('.scene')).toHaveAttribute('data-effect','merge:881');
    await expect(page.locator('#salvo')).toHaveClass(/fire/);
    await page.waitForTimeout(700);
    const beforeRefresh = await page.locator('#vessel').evaluate(el => {
      const a=el.getAnimations()[0];
      return Number(a?.effect?.getComputedTiming().progress);
    });
    await page.evaluate(async () => (window as any).render(await (await fetch('/api/state')).json()));
    await expect(page.locator('.scene')).toHaveAttribute('data-effect','merge:881');
    const afterRefresh = await page.locator('#vessel').evaluate(el => {
      const a=el.getAnimations()[0];
      return Number(a?.effect?.getComputedTiming().progress);
    });
    expect(afterRefresh-beforeRefresh).toBeGreaterThanOrEqual(0);
    expect(afterRefresh-beforeRefresh).toBeLessThan(.15);
    expect(await page.locator('#vessel').evaluate(el=>(el as HTMLElement).style.animationDelay)).toBe('0s');
    emit(root,'merged',881);
    await expect(page.locator('.scene')).toHaveAttribute('data-effect','merge:882', {timeout:15_000});
    // not widened: 882 has at most its 3.2 s left, and a replayed 881
    // after it would add 3.2 s more, which is what this window catches
    await expect(page.locator('.scene')).not.toHaveAttribute('data-effect', /.+/, {timeout:4000});
    await page.evaluate(() => { (window as any).connect(); });
    await page.waitForTimeout(650);
    await expect(page.locator('#salvo')).not.toHaveClass(/fire/);
    await page.reload();
    await expect(page.locator('.dcard')).toBeVisible();
    await expect(page.locator('#salvo')).not.toHaveClass(/fire/);
  } finally {stopBoard(b);}
});

test('failed merge persists failure without salute or automatic retry', async ({page}) => {
  const b = await startBoard(makeRoot(['working']));
  writeFileSync(join(b.root,'bin/fm-merge.sh'),'#!/usr/bin/env bash\necho refused\nexit 1\n');
  try {
    await page.goto(`${b.url}/?lang=en`);
    await page.locator('[data-c="A"]').click();
    await page.locator('.confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText(EN.mergeRefused);
    await expect(page.locator('#salvo')).not.toHaveClass(/fire/);
    await page.evaluate(async () => (window as any).render(await (await fetch('/api/state')).json()));
    await expect(page.locator('#orderFeedback')).toContainText(EN.mergeRefused);
    // answering again returns the stored record, which says the merge failed,
    // and runs nothing: the helper was called once
    const r = await page.request.post(`${b.url}/decisions`, {data:{id:'D-1',chosen:'A'}});
    const again = await r.json();
    expect(again.already).toBe(true);
    expect(again.decision.merge).toBe('failed');
    await page.reload();
    await expect(page.locator('#orderFeedback')).toContainText(EN.mergeRefused);
    await expect(page.locator('#salvo')).not.toHaveClass(/fire/);
  } finally {stopBoard(b);}
});

test('a refused merge names its decision and task, and clears once that task merges', async ({page}) => {
  test.setTimeout(60_000);
  const b = await startBoard(makeRoot(['working']));
  writeFileSync(join(b.root,'bin/fm-merge.sh'),'#!/usr/bin/env bash\necho refused\nexit 1\n');
  const {task} = JSON.parse(readFileSync(join(b.root,'state/pending/D-1.json'),'utf8'));
  const feedback = page.locator('#orderFeedback');
  try {
    await page.goto(`${b.url}/?lang=en`);
    await page.locator('[data-c="A"]').click();
    await page.locator('.confirm').click();
    await expect(feedback).toContainText(EN.mergeRefused);
    await expect(feedback).toContainText('D-1');
    await expect(feedback).toContainText(task);
    // a merge of some other task is not this one
    emitFixture(b.root,'github','T-OTHER','merged','Other merged','其他已合併');
    await page.evaluate(async () => (window as any).render(await (await fetch('/api/state')).json()));
    await expect(feedback).toContainText(EN.mergeRefused);
    // the same task merged afterwards, some other way: the refusal is old news
    const r = spawnSync('bash',[join(b.root,'bin/fm-emit.sh'),'--actor','github','--type','merged','--task',task,'--pr','99',
      '--en','merged by hand','--tw','手動合併'],{env:{...process.env,FM_ROOT:b.root}});
    expect(r.status).toBe(0);
    await expect(feedback).not.toContainText(EN.mergeRefused, {timeout:15_000});
    // and a reload does not bring it back
    await page.reload();
    await expect(page.locator('.scene .pivot').first()).toBeVisible();
    await expect(page.locator('#orderFeedback')).not.toContainText(EN.mergeRefused);
    await expect(page.locator('#deckwrap')).toBeHidden();
  } finally {stopBoard(b);}
});

test('the prototype layout: engine badge, six lanes, portrait and strips, roster rows and demonstrations', async ({page}) => {
  test.setTimeout(90_000);
  const root = makeRoot(['working','gate','review']);
  // names nothing could have hard-coded
  writeFileSync(join(root,'config.yaml'),'vendor: vendor-alpha  # top\nreviewer:\n  vendor: vendor-beta\n');
  const spec = {tasks:readTasks(root)};
  const first = spec.tasks[0].id;
  spec.tasks.push({id:'T-QUEUE',title:'Queued behind unmerged work',depends_on:[first]});
  spec.tasks.push({id:'T-READY',title:'Nothing to wait on',depends_on:[]});
  writeTasks(root, spec.tasks);
  emitFixture(root,'worker-absent','T-ABSENT','dispatched','Work on an unlisted task','處理未列出的任務',{role:'worker'});
  emitFixture(root,'worker-2',spec.tasks[1].id,'gate_failed','Gate five failed','第五道閘未過',{gate:5});
  emitFixture(root,'worker-1',first,'crew_status','Counting gates','計算閘門',{role:'worker',progress:{done:2,total:5}});
  writeFileSync(join(root,'state/pending/D-2.json'),JSON.stringify({id:'D-2',kind:'choice',task:spec.tasks[2].id,details}));
  const b = await startBoard(root);
  let posts = 0; page.on('request', r => { if (r.method() === 'POST') posts++; });
  try {
    await page.setViewportSize({width:1280,height:900});
    await page.goto(`${b.url}/?lang=en`);
    await expect(page.locator('.scene .pivot').first()).toBeVisible();

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
    await expect(page.locator('[data-task="T-ABSENT"] .t')).toHaveText(EN.titleMissing);
    await expect(page.locator('[data-task="T-ABSENT"]')).toContainText('worker-absent');
    await expect(page.locator(`[data-task="${spec.tasks[1].id}"] .badge`)).toHaveText(EN.gateFailedN.replace('{n}','5'));
    await expect(page.locator(`[data-lane="captain"] [data-task="${first}"] .badge`)).toContainText('D-1');
    await expect(page.locator(`[data-lane="captain"] [data-task="${spec.tasks[2].id}"] .badge`))
      .toHaveText(`D-2 · ${EN.optionsN.replace('{n}','3')}`);

    // the portrait sits beside the first full card; the next is a strip that
    // opens in place and keeps the two-stage confirmation
    const portrait = (await page.locator('#capstage').boundingBox())!, card = (await page.locator('#card-D-1').boundingBox())!;
    expect(portrait.x + portrait.width).toBeLessThanOrEqual(card.x);
    await expect(page.locator('#capstage .lbl')).toContainText(EN.roleCaptain);
    await expect(page.locator('.scene .fig.r-cap')).toHaveCount(1);
    await expect(page.locator('#strip-D-2')).toHaveJSProperty('open', false);
    await expect(page.locator('#card-D-2 .confirm')).toBeHidden();
    await page.locator('#strip-D-2 > summary').click();
    await expect(page.locator('#card-D-2 .confirm')).toBeVisible();
    await expect(page.locator('#card-D-2 .confirm')).toBeDisabled();
    await page.locator('#card-D-2 [data-c="B"]').click();
    await expect(page.locator('#card-D-2 .confirm')).toBeEnabled();
    await expect(page.locator('#strip-D-2')).toHaveJSProperty('open', true);
    await expect(page.locator('#card-D-1 .links')).toContainText(`${EN.viewPr} #99`);

    // roster rows; a bar only for the one with bounded progress, never a %
    await expect(page.locator('.roster li.rrow')).toHaveCount(4 + 1);
    await expect(page.locator('.roster .pb')).toHaveCount(1);
    await expect(page.locator('.roster [data-roster="worker-1"] .pb')).toHaveAttribute('aria-valuemax','5');
    await expect(page.locator('.scene .bub .pb')).toHaveCount(0);
    expect(await page.locator('#shipregion').innerText()).not.toMatch(/\d+\s*%/);
    await page.locator('#rosterBtn').click();
    await expect(page.locator('#roster')).toBeHidden();
    await expect(page.locator('#rosterBtn')).toHaveAttribute('aria-pressed','false');
    await page.locator('#rosterBtn').click();
    await expect(page.locator('#roster')).toBeVisible();

    // the demonstration plays locally and records nothing
    await page.locator('#ahoyDemo').click();
    await expect(page.locator('.scene')).toHaveAttribute('data-effect', /^demo:merge:/);
    await expect(page.locator('#salvo')).toHaveClass(/fire/);
    expect(posts).toBe(0);

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
        await expect(page.locator(`[data-task="${spec.tasks[1].id}"] .badge`)).toHaveText(CN.gateFailedN.replace('{n}','5'));
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
  } finally {stopBoard(b);}
});

// T-058: park, unpark and drop, each by the card's menu and by drag and drop
const CN_T058 = {park:'搁置',unpark:'恢复',drop:'不做',parked:'已搁置',dropped:'已不做',
  cardActions:'{id} 的操作',dropZone:'拖曳卡片到此：不做',dropConfirm:'确定不做 {id}？此任务将离开看板，design/tasks.json 不变。',
  dropYes:'确定不做',cancel:'取消',actionFailed:'看板未能记录此操作，请重新整理后再试。'};
test('the captain parks, unparks and drops a card by menu and by drag, and confirms a drop in the page', async ({page}) => {
  test.setTimeout(90_000);
  const root = makeRoot([], false);
  writeTasks(root, [
    {id:'T-A',title:'Ready to set aside',depends_on:[]},
    {id:'T-B',title:'Waits on T-A',depends_on:['T-A']},
    {id:'T-C',title:'Parked from the keyboard',depends_on:[]},
    {id:'T-D',title:'Dropped by dragging',depends_on:[]},
    {id:'T-W',title:'Already at work',depends_on:[]},
  ]);
  const plan = JSON.stringify(readTasks(root));
  emitFixture(root,'worker-w','T-W','dispatched','On it','接下',{role:'worker'});
  const events = () => readFileSync(join(root,'state/events.jsonl'),'utf8').trim().split('\n').map(l => JSON.parse(l));
  const last = () => events()[events().length - 1];
  const b = await startBoard(root);
  // the confirming step is in the page; a browser dialog fails the test
  const dialogs: string[] = [];
  page.on('dialog', d => { dialogs.push(d.type()); d.dismiss().catch(() => {}); });
  const lane = (k:string, id:string) => page.locator(`[data-lane="${k}"] [data-task="${id}"]`);
  const parkedCard = (id:string) => page.locator(`#parked [data-task="${id}"]`);
  try {
    await page.goto(`${b.url}/?lang=en`);
    await expect(lane('ready','T-A')).toHaveCount(1);
    await expect(lane('backlog','T-B')).toHaveCount(1);
    // a card in flight offers neither action, by either path
    await expect(page.locator('[data-task="T-W"] .cmenu')).toHaveCount(0);
    await expect(page.locator('[data-task="T-W"]')).not.toHaveAttribute('draggable','true');
    const refused = await page.evaluate(async () => (await fetch('/tasks',{method:'POST',
      headers:{'content-type':'application/json'},body:JSON.stringify({task:'T-W',action:'park'})})).status);
    expect(refused).toBe(409);
    expect(events().some(e => e.type === 'parked')).toBe(false);

    // park by click: the card's menu, then park
    await page.locator('[data-menu="T-A"]').click();
    await expect(page.locator('[data-task="T-A"] .cacts button')).toHaveText([EN.park, EN.drop]);
    await page.locator('[data-task="T-A"] [data-act="park"]').click();
    await expect(parkedCard('T-A')).toHaveCount(1);
    await expect(page.locator('#lanes [data-task="T-A"]')).toHaveCount(0);
    await expect(page.locator('#parked > summary')).toContainText(`${EN.parked} 1`);
    expect(last()).toMatchObject({type:'parked',actor:'captain',task:'T-A'});
    // the group is collapsed until opened
    await expect(page.locator('#parked')).toHaveJSProperty('open', false);
    // its dependent names the parked task as its blocker
    await expect(page.locator('[data-task="T-B"] .dep')).toContainText(`T-A (${EN.parked})`);

    // unpark by click: back to ready, as its (absent) dependencies say
    await page.locator('#parked > summary').click();
    await page.locator('#parked [data-menu="T-A"]').click();
    await expect(page.locator('#parked [data-task="T-A"] .cacts button')).toHaveText([EN.unpark, EN.drop]);
    await page.locator('#parked [data-act="unpark"]').click();
    await expect(lane('ready','T-A')).toHaveCount(1);
    await expect(parkedCard('T-A')).toHaveCount(0);
    expect(last()).toMatchObject({type:'unparked',actor:'captain',task:'T-A'});
    await expect(page.locator('[data-task="T-B"] .dep')).not.toContainText(EN.parked);

    // the click menu is the keyboard path: focus, Enter, Enter
    await page.locator('[data-menu="T-C"]').focus();
    await page.keyboard.press('Enter');
    await expect(page.locator('[data-task="T-C"] [data-act="park"]')).toBeFocused();
    await page.keyboard.press('Enter');
    await expect(parkedCard('T-C')).toHaveCount(1);
    expect(last()).toMatchObject({type:'parked',actor:'captain',task:'T-C'});

    // park by drag, onto the parked group
    await lane('ready','T-A').dragTo(page.locator('#parked > summary'));
    await expect(parkedCard('T-A')).toHaveCount(1);
    await expect(page.locator('#lanes [data-task="T-A"]')).toHaveCount(0);
    expect(last()).toMatchObject({type:'parked',actor:'captain',task:'T-A'});
    // and unpark by drag, back onto the lanes
    if (!(await page.locator('#parked').evaluate(el => (el as HTMLDetailsElement).open)))
      await page.locator('#parked > summary').click();
    await parkedCard('T-A').dragTo(page.locator('[data-lane="ready"]'));
    await expect(lane('ready','T-A')).toHaveCount(1);
    expect(last()).toMatchObject({type:'unparked',actor:'captain',task:'T-A'});

    // drop by click asks first, in the page; cancelling writes nothing
    const before = events().length;
    await page.locator('[data-menu="T-A"]').click();
    await page.locator('[data-task="T-A"] [data-act="drop"]').click();
    await expect(page.locator('#dropConfirm')).toBeVisible();
    await expect(page.locator('#dropConfirm')).toContainText(EN.dropConfirm.replace('{id}','T-A'));
    await expect(page.locator('[data-confirm-drop="T-A"]')).toBeFocused();
    await page.locator('[data-cancel-drop="T-A"]').click();
    await expect(page.locator('#dropConfirm')).toBeHidden();
    await expect(lane('ready','T-A')).toHaveCount(1);
    expect(events().length).toBe(before);
    // and confirming drops it: the closed event, and the task leaves the lanes
    await page.locator('[data-menu="T-A"]').click();
    await page.locator('[data-task="T-A"] [data-act="drop"]').click();
    await page.locator('[data-confirm-drop="T-A"]').click();
    await expect(page.locator('#lanes [data-task="T-A"]')).toHaveCount(0);
    await expect(parkedCard('T-A')).toHaveCount(0);
    await expect(page.locator('#dropConfirm')).toBeHidden();
    expect(last()).toMatchObject({type:'closed',actor:'captain',task:'T-A'});
    await expect(page.locator('[data-task="T-B"] .dep')).toContainText(`T-A (${EN.dropped})`);

    // drop by drag, onto the drop target: the same confirming step
    await lane('ready','T-D').dragTo(page.locator('#dropzone'));
    await expect(page.locator('#dropConfirm')).toContainText(EN.dropConfirm.replace('{id}','T-D'));
    await expect(lane('ready','T-D')).toHaveCount(1);
    await page.locator('[data-confirm-drop="T-D"]').click();
    await expect(page.locator('#lanes [data-task="T-D"]')).toHaveCount(0);
    expect(last()).toMatchObject({type:'closed',actor:'captain',task:'T-D'});

    // an in-flight card dragged onto a zone does nothing
    const n = events().length;
    await page.locator('[data-task="T-W"]').dragTo(page.locator('#dropzone'));
    await expect(page.locator('#dropConfirm')).toBeHidden();
    expect(events().length).toBe(n);

    // labels from the dictionaries, in every locale
    await page.locator('[data-l="zh-TW"]').click();
    await page.locator('[data-menu="T-B"]').click();
    await expect(page.locator('[data-task="T-B"] .cacts button')).toHaveText([TW.park, TW.drop]);
    await expect(page.locator('#parked > summary')).toContainText(TW.parked);
    await expect(page.locator('[data-task="T-B"] .dep')).toContainText(`T-A (${TW.dropped})`);
    await page.locator('[data-l="zh-CN"]').click();
    await expect(page.locator('[data-task="T-B"] .cacts button')).toHaveText([CN_T058.park, CN_T058.drop]);
    await expect(page.locator('#dropzone')).toHaveText(CN_T058.dropZone);
    for (const k of Object.keys(CN_T058)) {
      expect(TW, `no zh-TW entry for ${k}`).toHaveProperty(k);
      expect(EN, `no en entry for ${k}`).toHaveProperty(k);
      expect(await page.evaluate((s) => (window as any).eval('cn')(s), TW[k]), k).toBe((CN_T058 as any)[k]);
    }
    expect([EN.park,EN.unpark,EN.drop,EN.parked]).toEqual(['park','unpark','drop','parked']);
    expect([TW.park,TW.unpark,TW.drop,TW.parked]).toEqual(['擱置','恢復','不做','已擱置']);

    // no browser dialog at any point, and the board never edits the plan
    expect(dialogs).toEqual([]);
    expect(JSON.stringify(readTasks(root))).toBe(plan);
  } finally {stopBoard(b);}
});

// T-069: every #n the board shows links to that pull request on the
// repository the project registry names, and a press on one is a click on a
// link - never the start of a drag, never the card's menu
test('every pull request number links to its pull request on the registered repository', async ({page}) => {
  test.setTimeout(90_000);
  const root = makeRoot([], false);
  const REPO = 'example-org/linked-app';
  const pull = (n:number) => `https://github.com/${REPO}/pull/${n}`;
  writeRegistry(root, REPO);
  writeTasks(root, [
    {id:'T-A',title:'Not started, with a pull request opened by hand',depends_on:[]},
    {id:'T-W',title:'Waiting on the captain',depends_on:[]},
    {id:'T-M',title:'Merged, after #4',depends_on:[]},
  ]);
  emitFixture(root,'worker-w','T-W','dispatched','On it','接下',
    {role:'worker',crew_name:'Wren',activity:{en:'answering the review on #3','zh-TW':'回覆 #3 的審查'}});
  // the log as the emitter writes it: --pr is a JSON number
  const emitPr = (actor:string, task:string, type:string, pr:number, en:string, tw:string) => {
    const r = spawnSync('bash',[join(root,'bin/fm-emit.sh'),'--actor',actor,'--task',task,'--type',type,
      '--pr',String(pr),'--en',en,'--tw',tw],{env:{...process.env,FM_ROOT:root}});
    expect(r.status, r.stderr.toString()).toBe(0);
  };
  emitPr('worker-w','T-W','pr_opened',8,'opened #8 for T-W','為 T-W 開了 #8');
  emitPr('github','T-M','merged',9,'merged #9','已合併 #9');
  // a line whose numbers are not its own pr, and one with no pr at all
  emitFixture(root,'github','T-W','commit_pushed','pushed to #8, which replaces #5','推到 #8，取代 #5');
  // a number the log holds for a task nobody has started, written by some
  // other tool as a string: its card is ready, so it is draggable and has a
  // menu, and the string is the same number to the server and the page
  appendFileSync(join(root,'state/events.jsonl'), JSON.stringify({ts:'2026-09-21T10:00:00Z',actor:'github',
    task:'T-A',type:'pr_seen',pr:'7',summary:{en:'found #7','zh-TW':'找到 #7'}}) + '\n');
  const said = {en:{...details.en, explanation:'Lands after #6 is in.'},
    'zh-TW':{...details['zh-TW'], explanation:'在 #6 之後合併。'}};
  writeFileSync(join(root,'state/pending/D-8.json'), JSON.stringify({
    id:'D-8', kind:'merge', task:'T-W', pr:8, title:'Merge it', details:said, gates:[1,1,1,1,1,1,0]}));
  const events = () => readFileSync(join(root,'state/events.jsonl'),'utf8').trim().split('\n');
  // nothing leaves the machine: the opened tab gets a local page
  await page.context().route('https://github.com/**', r => r.fulfill({status:200, contentType:'text/html', body:'<title>pull</title>'}));
  const b = await startBoard(root);
  const isLink = async (l: ReturnType<Page['locator']>, n:number) => {
    await expect(l).toHaveCount(1);
    await expect(l).toHaveAttribute('href', pull(n));
    await expect(l).toHaveAttribute('target', '_blank');
    await expect(l).toHaveAttribute('rel', /(^|\s)noreferrer(\s|$)/);
    await expect(l).toContainText(`#${n}`);
  };
  try {
    await page.goto(`${b.url}/?lang=en`);
    const card = (k:string, id:string) => page.locator(`[data-lane="${k}"] [data-task="${id}"]`);
    await expect(card('ready','T-A')).toHaveCount(1);
    // the top right of each lane card
    await isLink(card('ready','T-A').locator('.hd a'), 7);
    await isLink(card('captain','T-W').locator('.hd a'), 8);
    await isLink(card('merged','T-M').locator('.hd a'), 9);
    // the history rows, the decision card, the roster and the log
    await isLink(page.locator('#history .history-cards a.pr'), 9);
    await isLink(page.locator('#card-D-8 .links a[data-pr]'), 8);
    await expect(page.locator('#card-D-8 .links a[data-pr]')).toContainText(`${EN.viewPr} #8`);
    await isLink(page.locator('#roster [data-roster="worker-w"] .rpr a'), 8);
    await isLink(page.locator('#log a', {hasText:'#7'}), 7);
    await expect(page.locator('#log a', {hasText:'#8'})).toHaveCount(2);
    for (const a of await page.locator('#log a', {hasText:'#8'}).all()) await expect(a).toHaveAttribute('href', pull(8));
    await isLink(page.locator('#log a', {hasText:'#9'}), 9);
    // a #n that is not the line's own pr, and one on a line with no pr
    await isLink(page.locator('#log a', {hasText:'#5'}), 5);
    // a #n in a title, a decision's text and a crewman's activity
    await isLink(card('merged','T-M').locator('.t a'), 4);
    await isLink(page.locator('#card-D-8 .explanation a'), 6);
    await isLink(page.locator('#roster [data-roster="worker-w"] .act a'), 3);
    // T-054: a board of one project renders as it always did - no project
    // chip anywhere, on a card, a bubble or a decision
    await expect(page.locator('.pchip')).toHaveCount(0);
    // and no #n anywhere on the page is left as bare text or points elsewhere.
    // The one exception is a decision's option label: it is a <button>, and
    // a link cannot sit inside one. The fixture's options name no #n.
    const stray = await page.evaluate(() => {
      const out: string[] = [];
      const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      for (let n = walk.nextNode(); n; n = walk.nextNode()) {
        const parent = n.parentElement;
        if (!parent || parent.closest('script,style,textarea')) continue;
        for (const m of (n.textContent || '').matchAll(/#(\d+)/g)) {
          const a = parent.closest('a');
          if (!a || a.getAttribute('href') !== `https://github.com/example-org/linked-app/pull/${m[1]}`)
            out.push(`${m[0]} in ${parent.outerHTML.slice(0, 120)}`);
        }
      }
      return out;
    });
    expect(stray).toEqual([]);

    // reachable by keyboard
    const seven = card('ready','T-A').locator('.hd a');
    // reached by the keyboard itself: it sits between the card's id and its
    // menu button, so a Shift+Tab from the menu lands on it
    await page.locator('[data-menu="T-A"]').focus();
    await page.keyboard.press('Shift+Tab');
    await expect(seven).toBeFocused();
    // a click opens the pull request in a new tab, and nothing else happens
    const [tab] = await Promise.all([page.waitForEvent('popup'), seven.click()]);
    await tab.waitForLoadState();
    expect(tab.url()).toBe(pull(7));
    await tab.close();
    await expect(card('ready','T-A').locator('.cacts')).toHaveCount(0);
    await expect(page.locator('[data-menu="T-A"]')).toHaveAttribute('aria-expanded', 'false');
    await expect(page.locator('.lanes-wrap')).not.toHaveClass(/dragging/);
    // a press that starts on the number and moves away does not drag the card
    const before = events().length;
    await seven.dragTo(page.locator('#dropzone'));
    await expect(page.locator('#dropConfirm')).toBeHidden();
    await seven.dragTo(page.locator('#parked > summary'));
    await expect(card('ready','T-A')).toHaveCount(1);
    await expect(page.locator('#parked [data-task="T-A"]')).toHaveCount(0);
    expect(events().length).toBe(before);
    // the card itself still drags: the number is excluded, not the card
    await card('ready','T-A').locator('.t').dragTo(page.locator('#dropzone'));
    await expect(page.locator('#dropConfirm')).toContainText(EN.dropConfirm.replace('{id}','T-A'));
    await page.locator('[data-cancel-drop="T-A"]').click();
    expect(events().length).toBe(before);
  } finally {stopBoard(b);}
});

test('without a github entry a pull request number is plain text, never a guessed link', async ({page}) => {
  test.setTimeout(60_000);
  const root = makeRoot([], false);
  writeTasks(root, [{id:'T-W',title:'Waiting',depends_on:[]}]);
  emitFixture(root,'worker-w','T-W','dispatched','On it','接下',{role:'worker'});
  appendFileSync(join(root,'state/events.jsonl'), JSON.stringify({ts:'2026-09-21T10:00:00Z',actor:'worker-w',
    task:'T-W',type:'pr_opened',pr:8,summary:{en:'opened #8','zh-TW':'開了 #8'}}) + '\n');
  emitFixture(root,'github','T-W','commit_pushed','pushed, replaces #5','推送，取代 #5');
  writeFileSync(join(root,'state/pending/D-8.json'), JSON.stringify({
    id:'D-8', kind:'merge', task:'T-W', pr:8, title:'Merge it', details, gates:[1,1,1,1,1,1,0]}));
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    await expect(page.locator('[data-task="T-W"] .hd')).toContainText('#8');
    await expect(page.locator('#card-D-8 .links')).toContainText(`${EN.viewPr} #8`);
    await expect(page.locator('#log')).toContainText('opened #8');
    await expect(page.locator('#log')).toContainText('pushed, replaces #5');
    await expect(page.locator('a[data-pr]')).toHaveCount(0);
    await expect(page.locator('a[href*="/pull/"]')).toHaveCount(0);
  } finally {stopBoard(b);}
});

// T-054: two registered projects live at the same time, with the same task id
// and the same pull request number. Every card, bubble and decision says
// whose it is; one project's answer leaves the other's card where it was; a
// merge runs in the background and the board says so while it does.
test('two projects on one board: chips everywhere, one answer leaves the other card, a merge runs in the background', async ({page}) => {
  test.setTimeout(90_000);
  const root = makeRoot([], false);
  writeProjects(root, [
    {name:'alpha', github:'example-org/alpha-app'},
    {name:'beta', github:'example-org/beta-app', tasks:[{id:'T-001',title:'beta one',depends_on:[]}]},
  ]);
  writeTasks(root, [{id:'T-001',title:'alpha one',depends_on:[]}]);
  const emitIn = (project:string|null, actor:string, task:string, type:string, pr:number|null, data:object) => {
    const r = spawnSync('bash',[join(root,'bin/fm-emit.sh'),'--actor',actor,'--task',task,'--type',type,
      ...(project ? ['--project',project] : []), ...(pr ? ['--pr',String(pr)] : []),
      '--data',JSON.stringify(data),'--en',`${type} ${task}`,'--tw',`${type} ${task}`],{env:{...process.env,FM_ROOT:root}});
    expect(r.status, r.stderr.toString()).toBe(0);
  };
  emitIn(null,'worker-a','T-001','dispatched',null,{role:'worker',crew_name:'Ada'});
  emitIn('beta','worker-b','T-001','dispatched',null,{role:'worker',crew_name:'Bo'});
  emitIn(null,'worker-a','T-001','pr_opened',7,{});
  emitIn('beta','worker-b','T-001','pr_opened',7,{});
  // beta's card was asked for first, so it leads the one list
  const card = (id:string, project:string) => {
    const file = join(root,`state/pending/${id}.json`);
    writeFileSync(file, JSON.stringify({id, project, task:'T-001', kind:'merge', pr:7, details, gates:[1,1,1,1,1,1,1]}));
    return file;
  };
  const older = card('D-beta-T001-1','beta'), newer = card('D-alpha-T001-1','alpha');
  utimesSync(older, new Date('2026-09-24T09:00:00Z'), new Date('2026-09-24T09:00:00Z'));
  utimesSync(newer, new Date('2026-09-24T09:05:00Z'), new Date('2026-09-24T09:05:00Z'));
  await page.context().route('https://github.com/**', r => r.fulfill({status:200, contentType:'text/html', body:'<title>pull</title>'}));
  const b = await startBoard(root);
  const hold = join(root,'hold-merge');
  try {
    await page.goto(`${b.url}/?lang=en`);
    // lane cards: two T-001s, each with its project's chip and its own #7, each
    // in the captain's lane for its own project's merge card
    const lane = (p:string) => page.locator(`[data-lane="captain"] [data-task="T-001"][data-project="${p}"]`);
    for (const [p, repo] of [['alpha','alpha-app'],['beta','beta-app']]) {
      await expect(lane(p)).toHaveCount(1);
      await expect(lane(p).locator('.pchip')).toHaveText(p);
      await expect(lane(p).locator('.pchip')).toHaveAttribute('title', EN.projectChip);
      await expect(lane(p).locator('.hd a[data-pr]')).toHaveAttribute('href', `https://github.com/example-org/${repo}/pull/7`);
    }
    await expect(lane('alpha').locator('.t')).toHaveText('alpha one');
    await expect(lane('beta').locator('.t')).toHaveText('beta one');
    // crew bubbles: each crewman says whose task it is on
    await expect(page.locator('[data-bubble="worker-a"] .pchip')).toHaveText('alpha');
    await expect(page.locator('[data-bubble="worker-b"] .pchip')).toHaveText('beta');
    // decision cards: every project's in one list, oldest first, each with its chip
    await expect(page.locator('#pcount')).toHaveText('2');
    await expect(page.locator('#deck > .dcard')).toHaveAttribute('id', 'card-D-beta-T001-1');
    await expect(page.locator('#card-D-beta-T001-1 > .meta .pchip')).toHaveText('beta');
    await expect(page.locator('#card-D-beta-T001-1 .links a[data-pr]')).toHaveAttribute('href', 'https://github.com/example-org/beta-app/pull/7');
    await expect(page.locator('#strip-D-alpha-T001-1 > summary .pchip')).toHaveText('alpha');
    // the chip's label is the dictionary's; the name is data and stays as written
    await page.locator('#langs [data-l="zh-TW"]').click();
    await expect(lane('beta').locator('.pchip')).toHaveAttribute('title', TW.projectChip);
    await expect(lane('beta').locator('.pchip')).toHaveText('beta');
    await page.locator('#langs [data-l="en"]').click();

    // answer beta's merge while its helper is held: the answer comes back, the
    // board says the merge is running, and alpha's card is still pending
    writeFileSync(hold, '');
    await page.locator('#card-D-beta-T001-1 [data-c="A"]').click();
    await page.locator('#card-D-beta-T001-1 .confirm').click();
    await expect(page.locator('#merging-D-beta-T001-1')).toContainText(EN.mergeRunning, {timeout:15_000});
    await expect(page.locator('#merging-D-beta-T001-1 .pchip')).toHaveText('beta');
    await expect(page.locator('#card-D-beta-T001-1')).toHaveCount(0);
    await expect(page.locator('#deck > .dcard')).toHaveAttribute('id', 'card-D-alpha-T001-1');
    await expect(page.locator('#pcount')).toHaveText('1');
    await expect.poll(() => existsSync(b.recorder) ? readFileSync(b.recorder,'utf8') : '', {timeout:15_000})
      .toContain('--project beta');
    expect(JSON.parse(readFileSync(join(root,'state/decisions/D-beta-T001-1.json'),'utf8')).merge).toBe('running');
    // the helper finishes: the record says merged and the board stops saying running
    rmSync(hold);
    await expect(page.locator('#merging-D-beta-T001-1')).toHaveCount(0, {timeout:15_000});
    await expect.poll(() => JSON.parse(readFileSync(join(root,'state/decisions/D-beta-T001-1.json'),'utf8')).merge,
      {timeout:15_000}).toBe('merged');
    await expect(page.locator('#card-D-alpha-T001-1')).toBeVisible();

    // ?project= shows one project: its cards, its crew and its count
    await page.goto(`${b.url}/?lang=en&project=alpha`);
    await expect(page.locator('[data-task="T-001"]')).toHaveCount(1);
    await expect(page.locator('[data-task="T-001"]')).toHaveAttribute('data-project', 'alpha');
    await expect(page.locator('[data-bubble="worker-b"]')).toHaveCount(0);
    await expect(page.locator('[data-bubble="worker-a"]')).toHaveCount(1);
    await expect(page.locator('#pcount')).toHaveText('1');
  } finally { rmSync(hold, {force:true}); stopBoard(b); }
});

// T-054: a project with nothing on the board but its task list - no crew, no
// card, no answer - is still a project on the board: its lane cards carry its
// chip, and so do the default project's beside them
test('a project on the board only through its lane cards still gets its chip', async ({page}) => {
  const root = makeRoot([], false);
  writeProjects(root, [
    {name:'alpha', github:'example-org/alpha-app'},
    {name:'beta', github:'example-org/beta-app', tasks:[{id:'T-001',title:'beta one',depends_on:[]}]},
  ]);
  writeTasks(root, [{id:'T-001',title:'alpha one',depends_on:[]}]);
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    const card = (p:string) => page.locator(`[data-task="T-001"][data-project="${p}"]`);
    await expect(card('beta')).toHaveCount(1);
    await expect(card('beta').locator('.pchip')).toHaveText('beta');
    await expect(card('alpha').locator('.pchip')).toHaveText('alpha');
  } finally { stopBoard(b); }
});

// T-054: park, unpark and drop are addressed by the card's key, its project
// and its id. Two projects each have an untouched T-001; every path the page
// offers - the menu, the confirming step, Escape and cancel, and drag - acts
// on the card it started from and never on the other project's T-001.
test('two projects with the same task id: menu, drop confirmation and drag act only on the card they started from', async ({page}) => {
  test.setTimeout(90_000);
  const root = makeRoot([], false);
  writeProjects(root, [
    {name:'alpha', github:'example-org/alpha-app'},
    {name:'beta', github:'example-org/beta-app', tasks:[{id:'T-001',title:'beta one',depends_on:[]},{id:'T-002',title:'beta two',depends_on:[]}]},
  ]);
  writeTasks(root, [
    {id:'T-001',title:'alpha one',depends_on:[]},{id:'T-002',title:'alpha two',depends_on:[]}]);
  const events = () => readFileSync(join(root,'state/events.jsonl'),'utf8').trim().split('\n').filter(Boolean).map(l => JSON.parse(l));
  const acted = () => events().filter(e => e.actor === 'captain' && ['parked','unparked','closed'].includes(e.type));
  const b = await startBoard(root);
  const dialogs: string[] = [];
  page.on('dialog', d => { dialogs.push(d.type()); d.dismiss().catch(() => {}); });
  const inLane = (k:string, p:string, id:string) => page.locator(`[data-lane="${k}"] [data-task="${id}"][data-project="${p}"]`);
  const parked = (p:string, id:string) => page.locator(`#parked [data-task="${id}"][data-project="${p}"]`);
  const menu = (p:string, id:string) => page.locator(`.cmenu[data-key="${p}/${id}"]`);
  try {
    await page.goto(`${b.url}/?lang=en`);
    for (const p of ['alpha','beta']) for (const id of ['T-001','T-002']) await expect(inLane('ready',p,id)).toHaveCount(1);

    // the menu and its confirming step name beta's card, and Escape and
    // cancel hand focus back to beta's menu button, not alpha's
    await menu('beta','T-001').click();
    await expect(page.locator('.cacts [data-key="beta/T-001"]')).toHaveText([EN.park, EN.drop]);
    await expect(page.locator('.cacts [data-key="alpha/T-001"]')).toHaveCount(0);
    await page.keyboard.press('Escape');
    await expect(menu('beta','T-001')).toBeFocused();
    await menu('beta','T-001').click();
    await page.locator('.cacts [data-key="beta/T-001"][data-act="drop"]').click();
    await expect(page.locator('#dropConfirm')).toContainText(EN.dropConfirm.replace('{id}','T-001'));
    await expect(page.locator('#dropConfirm .pchip')).toHaveText('beta');
    await page.locator('[data-cancel-drop][data-key="beta/T-001"]').click();
    await expect(page.locator('#dropConfirm')).toBeHidden();
    await expect(menu('beta','T-001')).toBeFocused();
    await menu('beta','T-001').click();
    await page.locator('.cacts [data-key="beta/T-001"][data-act="drop"]').click();
    await expect(page.locator('#dropConfirm .pchip')).toHaveText('beta');
    await page.keyboard.press('Escape');
    await expect(page.locator('#dropConfirm')).toBeHidden();
    await expect(menu('beta','T-001')).toBeFocused();
    expect(acted()).toEqual([]);

    // confirming drops beta's T-001 alone
    await menu('beta','T-001').click();
    await page.locator('.cacts [data-key="beta/T-001"][data-act="drop"]').click();
    await page.locator('[data-confirm-drop][data-key="beta/T-001"]').click();
    await expect(page.locator('#lanes [data-task="T-001"][data-project="beta"]')).toHaveCount(0);
    await expect(inLane('ready','alpha','T-001')).toHaveCount(1);
    expect(acted()).toMatchObject([{type:'closed',task:'T-001',project:'beta'}]);

    // park by drag: beta's T-002 goes to parked, alpha's T-002 stays ready
    await inLane('ready','beta','T-002').dragTo(page.locator('#parked > summary'));
    await expect(parked('beta','T-002')).toHaveCount(1);
    await expect(inLane('ready','alpha','T-002')).toHaveCount(1);
    await expect(parked('alpha','T-002')).toHaveCount(0);
    expect(acted()).toMatchObject([{type:'closed',project:'beta'},{type:'parked',task:'T-002',project:'beta'}]);

    // and the default project's card, dragged the same way, writes no project
    await inLane('ready','alpha','T-002').dragTo(page.locator('#parked > summary'));
    await expect(parked('alpha','T-002')).toHaveCount(1);
    await expect(parked('beta','T-002')).toHaveCount(1);
    const last = acted()[acted().length - 1];
    expect(last).toMatchObject({type:'parked',task:'T-002'});
    expect(last).not.toHaveProperty('project');
    expect(dialogs).toEqual([]);
  } finally { stopBoard(b); }
});

// T-054: with only the default project in the log the board renders as it
// always did - a card whose id names its owner, a crew bubble, a history
// card, a running merge and the drop confirmation all without a project
// chip - and a merge whose outcome GitHub cannot tell says so by name
test('a board of one project shows no project chip anywhere, and says a merge outcome is unknown', async ({page}) => {
  test.setTimeout(90_000);
  const root = makeRoot([], false);
  writeRegistry(root, 'example-org/solo-app');   // one project, `fixture`, the default
  writeTasks(root, [
    {id:'T-1',title:'at work',depends_on:[]},
    {id:'T-2',title:'not started',depends_on:[]},
    {id:'T-3',title:'already in',depends_on:[]},
  ]);
  emitFixture(root,'worker-a','T-1','dispatched','On it','接下',{role:'worker',crew_name:'Ada'});
  emitFixture(root,'github','T-3','merged','merged','已合併');
  // the default project named explicitly, in the id and on the record
  const owned = 'D-fixture-T1-1';
  writeFileSync(join(root,`state/pending/${owned}.json`), JSON.stringify({id:owned,project:'fixture',task:'T-1',kind:'choice',details}));
  // a merge answered earlier: its helper is gone, the log says nothing, and
  // gh fails the way gh fails
  mkdirSync(join(root,'state/decisions'), {recursive:true});
  writeFileSync(join(root,'state/decisions/D-fixture-T4-1.json'), JSON.stringify({id:'D-fixture-T4-1',chosen:'A',
    project:'fixture',task:'T-4',pr:44,kind:'merge',ts:'2026-01-01T00:00:00.000Z',identity:'decision:D-fixture-T4-1',merge:'running'}));
  const gh = join(root,'bin/gh');
  writeFileSync(gh, '#!/usr/bin/env bash\necho "HTTP 502: Bad Gateway (https://api.github.com/graphql)" >&2\nexit 1\n');
  chmodSync(gh, 0o755);
  const b = await startBoard(root, {FM_GH: gh});
  try {
    await page.goto(`${b.url}/?lang=en`);
    await expect(page.locator('[data-task="T-1"]')).toHaveCount(1);
    await expect(page.locator('[data-bubble="worker-a"]')).toHaveCount(1);
    await expect(page.locator('#history .history-cards .card', {hasText:'T-3'})).toHaveCount(1);
    // the owned id shows its project as it did before this task: plain text
    await expect(page.locator(`#card-${owned} > .meta`)).toHaveText(`${owned} · fixture · T-1`);
    await expect(page.locator(`#card-${owned} > .meta .project`)).toHaveAttribute('class', 'project');
    // the merge whose outcome GitHub could not tell: named, and marked unknown
    const row = page.locator('#merging-D-fixture-T4-1');
    await expect(row).toHaveClass(/unknown/, {timeout:15_000});
    await expect(row).toContainText(EN.mergeUnknown);
    expect(JSON.parse(readFileSync(join(root,'state/decisions/D-fixture-T4-1.json'),'utf8')).merge).toBe('running');
    await page.locator('#langs [data-l="zh-TW"]').click();
    await expect(row).toContainText(TW.mergeUnknown);
    await page.locator('#langs [data-l="en"]').click();
    // the drop confirmation, open
    await page.locator('[data-menu="T-2"]').click();
    await page.locator('.cacts [data-act="drop"]').click();
    await expect(page.locator('#dropConfirm')).toContainText(EN.dropConfirm.replace('{id}','T-2'));
    // and not one chip on any of it
    await expect(page.locator('.pchip')).toHaveCount(0);
    await page.locator('[data-cancel-drop="T-2"]').click();
  } finally {stopBoard(b);}
});

// T-054: one merge at a time within a project. A second answered while the
// first runs is refused on the page: the card stays in the deck, its options
// work again, nothing is written and the helper is not called
test('a second merge in the same project is refused while one runs, and its card stays', async ({page}) => {
  test.setTimeout(60_000);
  const root = makeRoot(['working']);   // D-1, a merge of #99
  const second = join(root,'state/pending/D-2.json');
  writeFileSync(second, JSON.stringify({id:'D-2',kind:'merge',task:'T-XB',pr:98,details,gates:[1,1,1,1,1,1,1]}));
  utimesSync(join(root,'state/pending/D-1.json'), new Date('2026-09-24T09:00:00Z'), new Date('2026-09-24T09:00:00Z'));
  utimesSync(second, new Date('2026-09-24T09:05:00Z'), new Date('2026-09-24T09:05:00Z'));
  const hold = join(root,'hold-merge');
  writeFileSync(hold, '');
  const b = await startBoard(root);
  const calls = () => existsSync(b.recorder) ? readFileSync(b.recorder,'utf8') : '';
  try {
    await page.goto(`${b.url}/?lang=en`);
    await page.locator('#card-D-1 [data-c="A"]').click();
    await page.locator('#card-D-1 .confirm').click();
    await expect(page.locator('#merging-D-1')).toContainText(EN.mergeRunning, {timeout:15_000});
    await expect.poll(calls, {timeout:15_000}).toContain('--pr 99');
    await expect(page.locator('#deck > .dcard')).toHaveAttribute('id', 'card-D-2');
    const card = page.locator('#card-D-2');
    await card.locator('[data-c="A"]').click();
    await card.locator('.confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText(EN.mergeBusy);
    await expect(card).toBeVisible();
    await expect(page.locator('#pcount')).toHaveText('1');
    await expect(card.locator('[data-c="A"]')).toBeEnabled();
    await expect(card.locator('.confirm')).toBeEnabled();
    expect(existsSync(join(root,'state/decisions/D-2.json'))).toBe(false);
    expect(calls()).not.toContain('--pr 98');
    // the first merge ends; the same card now goes through
    rmSync(hold);
    await expect(page.locator('#merging-D-1')).toHaveCount(0, {timeout:15_000});
    await card.locator('.confirm').click();
    await expect.poll(calls, {timeout:15_000}).toContain('--pr 98');
  } finally { rmSync(hold, {force:true}); stopBoard(b); }
});

test('external outcomes override stale success and clear only their settled draft', async ({page}) => {
  const root=makeRoot(['working']);
  writeFileSync(join(root,'state/pending/D-2.json'),JSON.stringify({id:'D-2',task:'T-002',kind:'choice',details}));
  writeFileSync(join(root,'state/pending/D-3.json'),JSON.stringify({id:'D-3',task:'T-003',kind:'choice',details}));
  const b=await startBoard(root);
  writeFileSync(join(b.root,'bin/fm-merge.sh'),'#!/usr/bin/env bash\necho refused\nexit 1\n');
  try {
    await page.goto(`${b.url}/?lang=en`);
    await page.locator('#card-D-1 [data-c="B"]').click();
    await page.locator('#strip-D-2 > summary').click();
    await page.locator('#strip-D-3 > summary').click();
    await page.locator('#card-D-3 [data-c="custom"]').click();
    await page.locator('#card-D-3 textarea').fill('keep this unrelated draft');
    await page.locator('#card-D-2 [data-c="B"]').click();
    await page.locator('#card-D-2 .confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText(EN.recorded);
    const external=await page.request.post(`${b.url}/decisions`,{data:{id:'D-1',chosen:'A'}});
    expect(external.ok()).toBe(true);
    await expect(page.locator('#orderFeedback')).toContainText(EN.mergeRefused);
    await expect(page.locator('#orderFeedback')).not.toContainText(EN.recorded);
    await expect(page.locator('.dcard')).toHaveCount(1);
    await expect(page.locator('#card-D-3 textarea')).toHaveValue('keep this unrelated draft');
    await expect(page.locator('#captain')).toHaveAttribute('data-pose','ready',{timeout:15_000});
    await page.request.post(`${b.url}/decisions`,{data:{id:'D-3',chosen:'custom',text:'keep this unrelated draft'}});
    await expect(page.locator('.dcard')).toHaveCount(0);
    await expect(page.locator('#captain')).toHaveAttribute('data-pose','idle',{timeout:15_000});
  } finally {stopBoard(b);}
});

test('network refusal keeps selection and accessible failure; reduced motion still acknowledges', async ({page}) => {
  const b = await startBoard(makeRoot(['working']));
  try {
    await page.emulateMedia({reducedMotion:'reduce'});
    await page.goto(`${b.url}/?lang=zh-TW`);
    await page.route('**/decisions',route => route.abort());
    await page.locator('[data-c="C"]').click();
    expect(await page.locator('#captain .tool').evaluate(el=>getComputedStyle(el).height)).toBe('38px');
    await page.locator('.confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText(TW.orderFailed);
    await expect(page.locator('.scene .fig.cheer')).toHaveCount(0);
    expect(existsSync(join(b.root,'state/decisions/D-1.json'))).toBe(false);
    await page.unroute('**/decisions'); await page.locator('.confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText('AYE, CAPTAIN!');
    expect(await page.locator('#captain .tool').evaluate(el=>getComputedStyle(el).height)).toBe('52px');
    await expect(page.locator('#ahoy')).toBeVisible();
    await expect(page.locator('.scene .fig.cheer')).toHaveCount(0);
  } finally {stopBoard(b);}
});

async function fakeAudio(page:Page, local = true, refused = false) {
  await page.addInitScript(({local,refused}) => {
    const w = window as any;
    w.sounds = {tones:[],booms:0,spoken:[],cancel:0,pause:0,stopped:0,master:1};
    const param = {setValueAtTime(){},exponentialRampToValueAtTime(){}};
    const node = () => ({connect(){return this;}, start(){},stop(){w.sounds.stopped++;},frequency:param,gain:param});
    w.AudioContext = class {
      currentTime = 0; sampleRate = 8000; state = 'suspended'; destination = {};
      resume(){return refused ? Promise.reject(new Error('autoplay refused')) : Promise.resolve();}
      createGain(){const n = node(); n.gain = {...param,setValueAtTime(v:number){w.sounds.master = v;}};return n;}
      createOscillator(){const n = node(); n.frequency = {...param,setValueAtTime(v:number){w.sounds.tones.push(v);}};return n;}
      createBuffer(){return {getChannelData:()=>new Float32Array(4000)};}
      createBufferSource(){w.sounds.booms++; return node();}
      createBiquadFilter(){return node();}
    };
    w.SpeechSynthesisUtterance = class {text:string;constructor(text:string){this.text=text;}};
    const synth = {speaking:false,pending:false,
      getVoices:()=>[{name:'remote',lang:'en-US',localService:false}, ...(local ? [{name:'local',lang:'en-US',localService:true}] : [])],
      speak(u:any){w.sounds.spoken.push({text:u.text,local:u.voice.localService}); synth.speaking=true;w.utterance=u;},
      cancel(){w.sounds.cancel++;synth.speaking=false;w.utterance?.onend?.();},
      pause(){w.sounds.pause++;},resume(){},
    };
    Object.defineProperty(w,'speechSynthesis',{value:synth});
    w.finishVoice = () => {synth.speaking=false;w.utterance?.onend?.();};
  }, {local,refused});
}
test('Ahoy speech cues stay off while merge cannon, dedupe and mute remain', async ({page}) => {
  test.setTimeout(60_000);
  await fakeAudio(page);
  const b = await startBoard(makeRoot(['working']));
  const external:string[]=[];
  page.on('request',r => {if (!r.url().startsWith(b.url)) external.push(r.url());});
  try {
    await page.goto(`${b.url}/?lang=zh-TW`);
    await page.locator('[data-c="B"]').click();
    expect(await page.evaluate(()=>(window as any).sounds.tones)).toEqual([]);
    expect(await page.evaluate(()=>(window as any).sounds.spoken)).toEqual([]);
    await page.locator('.confirm').click();
    const sound = await page.evaluate(()=>(window as any).sounds);
    expect(sound.tones).toEqual([]);expect(sound.spoken).toEqual([]);expect(sound.booms).toBe(0);
    emit(b.root,'merged',885);
    await expect(page.locator('.scene')).toHaveAttribute('data-effect','merge:885',{timeout:15_000});
    expect((await page.evaluate(()=>(window as any).sounds)).booms).toBeGreaterThan(0);
    expect((await page.evaluate(()=>(window as any).sounds)).tones).toEqual([]);
    expect((await page.evaluate(()=>(window as any).sounds)).spoken).toEqual([]);
    const before = await page.evaluate(()=>(window as any).sounds.booms);
    emit(b.root,'merged',885);
    await page.locator('#muteBtn').click();
    expect(await page.evaluate(()=>localStorage.getItem('board.muted'))).toBe('1');
    expect((await page.evaluate(()=>(window as any).sounds)).cancel).toBe(0);
    emit(b.root,'merged',886);
    await expect(page.locator('.scene')).toHaveAttribute('data-effect','merge:886',{timeout:15_000});
    expect((await page.evaluate(()=>(window as any).sounds)).booms).toBe(before);
    expect((await page.evaluate(()=>(window as any).sounds)).spoken).toEqual([]);
    expect(external).toEqual([]);
    await page.reload(); await expect(page.locator('#muteBtn')).toHaveAttribute('aria-pressed','true');
  } finally {stopBoard(b);}
});

test('audio unavailability never adds fallback noise or hides visible acknowledgement', async ({page}) => {
  await fakeAudio(page,false,true);
  const b = await startBoard(makeRoot(['working']));
  try {
    await page.emulateMedia({reducedMotion:'reduce'});
    await page.goto(`${b.url}/?lang=en`);
    await page.locator('[data-c="C"]').click(); await page.locator('.confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText('AYE, CAPTAIN!');
    await expect(page.locator('#orderFeedback')).not.toContainText('Local speech unavailable');
    expect((await page.evaluate(()=>(window as any).sounds)).spoken).toEqual([]);
    expect((await page.evaluate(()=>(window as any).sounds)).tones).toEqual([]);
  } finally {stopBoard(b);}
});

test('Ahoy override never touches an unrelated browser speech queue', async ({page}) => {
  await fakeAudio(page);
  const b = await startBoard(makeRoot(['working']));
  try {
    await page.goto(`${b.url}/?lang=en`);
    await page.evaluate(()=>{(window.speechSynthesis as any).speaking=true;});
    await page.locator('[data-c="C"]').click(); await page.locator('.confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText('AYE, CAPTAIN!');
    expect((await page.evaluate(()=>(window as any).sounds)).spoken).toEqual([]);
    await page.evaluate(()=>{(window.speechSynthesis as any).pending=true;});
    await page.locator('#muteBtn').click();
    const sounds = await page.evaluate(()=>(window as any).sounds);
    expect(sounds.spoken).toEqual([]);expect(sounds.cancel).toBe(0);expect(sounds.pause).toBe(0);
  } finally {stopBoard(b);}
});

test('legacy scalar records disclose missing details without invented translations', async ({page}) => {
  const root = makeRoot(['working']);
  writeFileSync(join(root,'state/pending/D-1.json'),JSON.stringify({id:'D-1',kind:'choice',title:'Legacy literal title'}));
  expect(spawnSync('bash',[join(root,'bin/fm-diagram.sh'),'--decision','D-1','--repo',root]).status).toBe(0);
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=zh-TW`);
    await expect(page.locator('.dcard')).toContainText('Legacy literal title');
    await expect(page.locator('.explanation')).toHaveText(TW.missingDetails);
    await expect(page.locator('.tradeoffs')).toHaveCount(0);
  } finally {stopBoard(b);}
});

// its own board: it emits a merge, and with the file's tests running in
// parallel the shared board is being read by the language tests meanwhile
test("a crewman turns under the pointer, and the ahoy fires", async ({ page }) => {
  // the start of its board counts against the test's own budget
  test.setTimeout(60_000);
  const own = await startBoard(makeRoot([...CREW]));
  try {
    await open(page, "zh-TW", "query", own.url);
    const crew = page.locator(".scene .pivot").first();
    await crew.scrollIntoViewIfNeeded();
    const before = await crew.evaluate((el) => el.style.getPropertyValue("--ry"));
    const box = (await crew.boundingBox())!;
    // low on the figure: a bubble sits above the head and would take the press
    const y = box.y + box.height * 0.82;
    await page.mouse.move(box.x + box.width / 2, y);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width / 2 + 90, y, { steps: 6 });
    await page.mouse.up();
    const after = await crew.evaluate((el) => el.style.getPropertyValue("--ry"));
    expect(after).not.toBe(before);
    expect(parseFloat(after)).toBeGreaterThan(parseFloat(before || "-26"));

    emit(own.root, 'merged', 777);
    await expect(page.locator("#vessel")).toHaveClass(/heel/);
    await expect(page.locator("#salvo")).toHaveClass(/fire/);
    await expect(page.locator(".scene .fig.cheer").first()).toBeVisible();
  } finally { stopBoard(own); }
});

test("nothing here can reach a model", async () => {
  // structural, not a promise: the fixture root has no adapters in it, so
  // there is nothing for the board to shell out to even if it tried. The
  // only scripts it may spawn are the merge recorder and the registry
  // reader, and they are the whole contents of its bin/.
  //
  // fm-config.sh and the fm-herdr.py it imports (T-069) are there so the
  // board can read the project registry's `github`. The only path from them
  // to a model is fm_run_chain, which runs bin/adapters - absent above - and
  // the board calls nothing from fm-config.sh but the registry readers
  // (fm_projects since T-054, to know every project's repository and tasks)
  // and fm_tasks, which only reads task directories (T-090).
  const { readdirSync, readFileSync } = await import("node:fs");
  expect(existsSync(join(board.root, "bin/adapters"))).toBe(false);
  expect(readdirSync(join(board.root, "bin")).sort()).toEqual(["fm-config.sh", "fm-decide.sh", "fm-diagram.sh", "fm-emit.sh", "fm-herdr.py", "fm-merge.sh", "watch-decisions.ts"]);
  const called = new Set(readFileSync(join(board.root, "board/server.ts"), "utf8").match(/\bfm_[a-z_]+/g) ?? []);
  expect([...called].sort()).toEqual(["fm_project_get", "fm_project_resolve", "fm_projects", "fm_tasks"]);
});

test("no cards retains one idle captain aboard", async ({ page }) => {
  test.setTimeout(60_000);
  // Driven by the state the page reads, not by calling into the page:
  // render() runs again on the board's own refresh and would put him
  // straight back, so a hand call passes or flakes depending on the tick.
  const quiet = await startBoard(makeRoot(["working"], false));
  try {
    await page.goto(`${quiet.url}/?lang=en`);
    await expect(page.locator(".scene .pivot").first()).toBeVisible();
    await expect(page.locator(".dcard")).toHaveCount(0);
    await expect(page.locator("#captain .fig.r-cap")).toHaveCount(1);
    // Visibility must come from the ship, independently of the empty
    // decision region. A DOM node hidden by an ancestor does not pass.
    await expect(page.locator(".scene #captain")).toBeVisible();
    await expect(page.locator("#captain")).toHaveAttribute("data-pose", "idle");
  } finally { stopBoard(quiet); }
});

test("captain and left helm stay on the real deck at every width and rate", async ({page}) => {
  test.setTimeout(60000);
  const b=await startBoard(makeRoot([],false));
  try {
    await page.goto(b.url+'/?lang=en');
    await page.addStyleTag({content:'.scene *{animation:none!important;transition:none!important}'});
    for(const n of [0,2,5,9,14,19,24]) {
      for(const width of [320,390,768,1280]) {
        await page.setViewportSize({width,height:844});
        await page.evaluate(async n=>{
          const s=await (await fetch('/api/state')).json();
          s.crew=Array.from({length:n},(_,i)=>({id:i?'worker-'+i:'firstmate',role:i?'worker':'firstmate',state:'working',task:'T-001'}));
          (window as any).render(s);
        },n);
        await expect(page.locator('.scene #captain')).toBeVisible();
        await expect(page.locator('.r-cap')).toHaveCount(1);
        const boxes=await page.evaluate(()=>{
          const scene=document.querySelector('.scene') as HTMLElement;
          const rect=(s:string)=>{const r=document.querySelector(s)!.getBoundingClientRect();return {x:r.x,y:r.y,w:r.width,h:r.height,right:r.right,bottom:r.bottom};};
          const css=getComputedStyle(scene),cap=document.querySelector('#captain') as HTMLElement;
          return {scene:rect('.scene'),cap:rect('#captain .pivot'),foot:rect('#captain .shoeL .fr'),helm:rect('.helm'),hull:rect('.hullwrap'),bow:rect('.prow'),stern:rect('.stern'),deck:scene.getBoundingClientRect().bottom-1-parseFloat(css.getPropertyValue('--deckY0'))-parseFloat(cap.style.getPropertyValue('--capRow'))*parseFloat(css.getPropertyValue('--rowStep'))};
        });
        expect(boxes.cap.w).toBeGreaterThan(0);expect(boxes.cap.h).toBeGreaterThan(0);
        expect(boxes.cap.x).toBeGreaterThanOrEqual(boxes.scene.x);
        expect(boxes.cap.right).toBeLessThanOrEqual(boxes.scene.right);
        expect(Math.abs(boxes.cap.bottom-boxes.deck)).toBeLessThan(12); // 3D foot projection
        expect(Math.abs(boxes.foot.bottom-boxes.deck)).toBeLessThan(12);
        expect(boxes.cap.x+boxes.cap.w/2).toBeGreaterThan(boxes.hull.x);
        expect(boxes.cap.x+boxes.cap.w/2).toBeLessThan(boxes.hull.right);
        expect(boxes.helm.x+boxes.helm.w/2).toBeLessThan(boxes.hull.x+boxes.hull.w/2);
        expect(boxes.bow.x).toBeLessThan(boxes.hull.x+boxes.hull.w/2);
        expect(boxes.stern.x).toBeGreaterThan(boxes.hull.x+boxes.hull.w/2);
        expect(boxes.helm.x+boxes.helm.w/2).toBeGreaterThan(boxes.hull.x);
      }
    }
  } finally {stopBoard(b);}
});

test("a crewman below the top deck still names the task he is on", async ({ page }) => {
  test.setTimeout(60_000);
  // Criterion 3 has no viewport qualifier, and a crowded ship is where
  // the name chips appear. T-116 made every tag quiet: it carries the
  // name only, and the task he is on is in his detail card and the roster.
  const many = await startBoard(makeRoot(Array(9).fill("working"), false));
  try {
    await page.goto(`${many.url}/?lang=en`);
    await expect(page.locator(".scene .pivot").first()).toBeVisible();
    const minis = page.locator(".scene .bub.mini");
    const count = await minis.count();
    expect(count).toBeGreaterThan(0);
    // the name exactly: no task, round or activity rides on the tag
    for (const text of await minis.locator(".who").allInnerTexts()) {
      expect(text.trim()).toMatch(/^(worker|reviewer)-\d+$/);
    }
    // the task, not merely non-empty: each chip's own card names it
    const tasks = await minis.locator(".crewcard .ctask").allTextContents();
    expect(tasks.length).toBe(count);
    for (const t of tasks) expect(t.trim()).toMatch(/^T-\d+ /);
    // and the roster still carries what each of them is on
    const jobs = await page.locator(".roster .jb").allInnerTexts();
    expect(jobs.filter((j) => /^T-\d+/.test(j)).length).toBe(9);
  } finally { stopBoard(many); }
});

test("the ship follows the crew, not the backlog", async ({ page }) => {
  test.setTimeout(60_000);
  // The bug this task replaces: one figure per in-flight task. A fixture
  // with one agent per task cannot tell the two apart, which is why the
  // old one looked fine - so this is twelve tasks in flight and one agent
  // on them, and it has to be a small ship with one crewman aboard
  // besides firstmate.
  const many = await startBoard(makeRoot(Array(12).fill("working"), false, "one-worker"));
  try {
    await page.goto(`${many.url}/?lang=en`);
    await expect(page.locator(".scene .pivot").first()).toBeVisible();
    expect(Number(await page.locator(".scene").getAttribute("data-crew"))).toBe(2);
    await expect(page.locator(".roster li")).toHaveCount(2);
    const small = await page.locator(".scene").getAttribute("data-rate");
    expect(small).toBe("rate1");        // two aboard is the smallest ship
  } finally { stopBoard(many); }
});

test("the ship grows with the crew", async ({ page }) => {
  test.setTimeout(60_000);   // starts a second board in its body
  // zh-TW like every other interaction: the criterion puts the three
  // languages in the snapshot reads and everything else in one locale
  await open(page, "zh-TW");
  const small = await page.locator(".scene").getAttribute("data-rate");
  const crewNow = Number(await page.locator(".scene").getAttribute("data-crew"));
  expect(crewNow).toBe(CREW.length + 1);
  const big = await startBoard(makeRoot(Array(20).fill("working"), false));
  try {
    await page.goto(`${big.url}/?lang=en`);
    await expect(page.locator(".scene .pivot").first()).toBeVisible();
    expect(await page.locator(".scene").getAttribute("data-rate")).not.toBe(small);
    expect(Number(await page.locator(".scene").getAttribute("data-crew"))).toBe(21);
    // the whole sail still clears the tallest head
    const clear = await page.evaluate(() => {
      const top = [...document.querySelectorAll<HTMLElement>(".scene .pivot")]
        .reduce((m, p) => Math.min(m, p.getBoundingClientRect().top), Infinity);
      const sail = [...document.querySelectorAll<HTMLElement>(".scene .sail")]
        .reduce((m, s) => Math.max(m, s.getBoundingClientRect().bottom), -Infinity);
      return sail < top;
    });
    expect(clear).toBe(true);
  } finally { stopBoard(big); }
});
