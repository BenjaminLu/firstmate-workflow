// The board, in a browser. Poses are asserted as classes and text as
// dictionary values, never as screenshots: a snapshot test of a ship that
// moves would fail on the animation and pass on the wrong crew.
import { test, expect, type Page } from "@playwright/test";
import { makeRoot, startBoard, stopBoard, ROOT, details } from "./fixture";
import { appendFileSync, readFileSync, existsSync, writeFileSync } from "node:fs";
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
  const file=join(root,'design/tasks.json');const spec=JSON.parse(readFileSync(file,'utf8'));
  spec.tasks=spec.tasks.filter((t:any)=>!['T-034','T-035'].includes(t.id));writeFileSync(file,JSON.stringify(spec));
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
    writeFileSync(file,JSON.stringify(spec));
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
  const file = join(root,'design/tasks.json');
  const spec = JSON.parse(readFileSync(file,'utf8'));
  spec.tasks[4].title='https://example.invalid/'+ 'long-unbroken-title'.repeat(40);
  for (let i=0;i<30;i++) {
    spec.tasks.push({id:`H-${i}`,title:'Completed '+i,depends_on:[]});
    appendFileSync(join(root,'state/events.jsonl'), JSON.stringify({actor:'github',task:`H-${i}`,type:'merged',pr:100+i})+'\n');
  }
  appendFileSync(join(root,'state/events.jsonl'), JSON.stringify({actor:'worker-ghost',task:'T-999',type:'dispatched',summary:{en:'Unknown task work','zh-TW':'未知任務工作'},data:{role:'worker'}})+'\n');
  appendFileSync(join(root,'state/events.jsonl'), JSON.stringify({actor:'github',task:'T-999',type:'merged',pr:999})+'\n');
  writeFileSync(join(root,'state/pending/D-999.json'),JSON.stringify({id:'D-999',task:'T-999',kind:'choice',details}));
  writeFileSync(file,JSON.stringify(spec));
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
        for(const selector of ['.langs','.opt','textarea','.confirm','.card','#history']) {
          for(const el of await page.locator(selector).all()) {
            if(!await el.isVisible())continue;
            const box=await el.boundingBox();expect(box!.x).toBeGreaterThanOrEqual(0);expect(box!.x+box!.width).toBeLessThanOrEqual(width+1);
          }
        }
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
    // every crewman says who he is and what he is on, over his own head
    await expect(page.locator(".scene .bub")).toHaveCount(CREW.length + 1);
    await expect(page.locator(".scene .bub:not(.mini) .job").first()).not.toBeEmpty();
    // the full bubbles name the agent; the chips below them name the
    // task, because a chip with only a name says nothing about the work
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
  await expect(card.locator(".gates li")).toHaveCount(7);
  await expect(card.locator(".gates li.n")).toHaveCount(1);   // gate seven open

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
    const r = await page.request.post(`${b.url}/decisions`, {data:{id:'D-1',chosen:'A'}});
    expect((await r.json()).merged.ok).toBe(false);
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
  const file = join(root,'design/tasks.json'), spec = JSON.parse(readFileSync(file,'utf8'));
  const first = spec.tasks[0].id;
  spec.tasks.push({id:'T-QUEUE',title:'Queued behind unmerged work',depends_on:[first]});
  spec.tasks.push({id:'T-READY',title:'Nothing to wait on',depends_on:[]});
  writeFileSync(file, JSON.stringify(spec));
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
  const file = join(root,'design/tasks.json');
  writeFileSync(file, JSON.stringify({tasks:[
    {id:'T-A',title:'Ready to set aside',depends_on:[]},
    {id:'T-B',title:'Waits on T-A',depends_on:['T-A']},
    {id:'T-C',title:'Parked from the keyboard',depends_on:[]},
    {id:'T-D',title:'Dropped by dragging',depends_on:[]},
    {id:'T-W',title:'Already at work',depends_on:[]},
  ]}));
  const plan = readFileSync(file,'utf8');
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
    expect(readFileSync(file,'utf8')).toBe(plan);
  } finally {stopBoard(b);}
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
  // only script it may spawn is the merge recorder, and that is the whole
  // contents of its bin/.
  const { readdirSync } = await import("node:fs");
  expect(existsSync(join(board.root, "bin/adapters"))).toBe(false);
  expect(readdirSync(join(board.root, "bin")).sort()).toEqual(["fm-decide.sh", "fm-diagram.sh", "fm-emit.sh", "fm-merge.sh", "watch-decisions.ts"]);
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
  // the name chips appear - the full bubble would blindfold the crew
  // standing over it, so the chip has to carry the name and the roster
  // the job. Nothing covered the chip.
  const many = await startBoard(makeRoot(Array(9).fill("working"), false));
  try {
    await page.goto(`${many.url}/?lang=en`);
    await expect(page.locator(".scene .pivot").first()).toBeVisible();
    const minis = page.locator(".scene .bub.mini");
    expect(await minis.count()).toBeGreaterThan(0);
    // the task, not merely non-empty: a chip holding the agent's name is
    // also non-empty, which is what it held before and why "not blank"
    // was an assertion that passed on the old code
    for (const text of await minis.locator(".who").allInnerTexts()) {
      expect(text.trim()).toMatch(/^(worker|reviewer)-\d+ T-\d+$/);
    }
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
