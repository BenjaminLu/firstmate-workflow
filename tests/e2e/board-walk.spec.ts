import { expect } from '@playwright/test';
import { test, makeRoot, startBoard, stopBoard, writeTasks, writeProjects, projectState } from './lib/fixture';
import { sceneWalkCard } from './lib/intent-card';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { showFleet } from './lib/board';

async function setup(page: any, mode: 'both'|'scene'|'walk'|'stale' = 'both') {
  const root = makeRoot([], false);
  writeTasks(root,[{id:'T-211',title:'Record walk',depends_on:[]}]);
  writeFileSync(join(root,'state/pending/D-9242.json'),JSON.stringify(sceneWalkCard(mode)));
  const board = await startBoard(root);
  try {
    await page.goto(board.url+'/?lang=en');
    const card=page.locator('#card-D-9242');
    await expect(card.locator('[data-code-tab]')).toBeVisible();
    return {board,card};
  } catch (error) {
    await stopBoard(board);
    throw error;
  }
}

test('scene controls, intent jumps and trusted escaped rows',async({page})=>{
  const {board,card}=await setup(page);
  try {
    await expect(card.locator('[data-code-panel]')).toBeHidden();
    await card.locator('[data-phase="0"]').click();
    await expect(card.locator('.scene-view')).toHaveAttribute('data-phase','before');
    await card.locator('[data-play]').click();
    await expect(card.locator('[data-play]')).toHaveText('Pause');
    await card.locator('[data-play]').click();
    await expect(card.locator('[data-play]')).toHaveText('Play');
    await card.locator('[data-scrub]').evaluate((el: HTMLInputElement)=>{el.value='2';el.dispatchEvent(new Event('input',{bubbles:true}));});
    await expect(card.locator('.scene-view')).toHaveAttribute('data-phase','after');
    await card.locator('.walk-intent-link').first().click();
    await expect(card.locator('.scene-banner')).toBeVisible();
    await expect(card.locator('[data-scene-id="saved"]')).not.toHaveClass(/scene-dim/);
    await card.locator('[data-its-code]').click();
    await expect(card.locator('[data-code-panel]')).toBeVisible();
    await expect(card.locator('.walk-block')).toHaveCount(2);
    await expect(card.locator('.walk-note').first()).toHaveText('The path keeps <b>input</b>.');
    await expect(card.locator('.walk-note b')).toHaveCount(0);
    await expect(card.locator('.walk-row script')).toHaveCount(0);
    await expect(card.locator('.walk-row.noted').first()).toContainText('The input stays.');
    await card.locator('[data-blocks]').focus();
    await page.keyboard.press('ArrowDown');
    await expect(card.locator('[data-block="1"]')).toHaveClass(/active/);
    await page.keyboard.press('ArrowUp');
    await expect(card.locator('[data-block="0"]')).toHaveClass(/active/);
    await page.keyboard.press('Space');
    await card.locator('[data-show-all]').click();
    await expect(card.locator('.scene-dim')).toHaveCount(0);
    await card.locator('[data-badge="c1"]').click();
    await expect(card.locator('[data-intent-tab="1"]')).toHaveAttribute('aria-selected','true');
    await card.locator('[data-intent-tab="2"]').click();
    await expect(card.locator('[data-blocks]')).toContainText('This intent has no key block.');
    await card.locator('[data-other-tab]').click();
    await expect(card.locator('.walk-other')).toContainText('other.py · 3');
    await expect(card.locator('.walk-other')).toContainText('image.bin · 1 · binary');
    await expect(card.locator('.walk-other .walk-note')).toHaveCount(0);
    await expect(card).not.toContainText('total blocks');
  } finally {await stopBoard(board);}
});

test('one-way evidence unlock never depends on opening code',async({page})=>{
  const {board,card}=await setup(page);
  try {
    await card.locator('[data-review-intent="1"]').check();
    await card.locator('[data-review-intent="2"]').check();
    await card.locator('[data-door-answer="1"]').click();
    await expect(card.locator('[data-c="A"]')).toBeDisabled();
    await card.locator('[data-door-answer="0"]').click();
    await expect(card.locator('[data-c="A"]')).toBeEnabled();
    await expect(card.locator('[data-code-panel]')).toBeHidden();
  } finally {await stopBoard(board);}
});

for(const mode of ['scene','walk','stale'] as const) test(`${mode} partial data`,async({page})=>{
  const {board,card}=await setup(page,mode);
  try {
    await expect(card.locator('[data-code-panel]')).toBeHidden();
    if(mode==='walk') {
      await expect(card.locator('.scene-view')).toHaveCount(0);
      await expect(card.locator('.change-fallback')).toBeVisible();
      await card.locator('.walk-intent-link').first().click();
    } else await card.locator('[data-code-tab]').click();
    if(mode==='scene') await expect(card.locator('[data-code-panel]')).toContainText('No code walk for this head');
    if(mode==='stale') {
      await expect(card.locator('[data-code-panel]')).toContainText('Walk out of date');
      await expect(card.locator('[data-code-panel]')).toContainText('bbbbbbb');
      await expect(card.locator('.walk-note')).toHaveCount(0);
      await expect(card.locator('.scene-lit')).toHaveCount(0);
    }
  } finally {await stopBoard(board);}
});

test('reduced motion is static with numbered changes',async({page})=>{
  await page.emulateMedia({reducedMotion:'reduce'});
  const {board,card}=await setup(page);
  try {
    await expect(card.locator('.scene-view')).toHaveAttribute('data-phase','change');
    await expect(card.locator('[data-play]')).toHaveText('Play');
    await expect(card.locator('[data-badge="c1"]')).toBeVisible();
    await card.locator('[data-play]').click();
    await expect(card.locator('[data-play]')).toHaveText('Play');
  } finally {await stopBoard(board);}
});


test('locale redraw uses the translated scene',async({page})=>{
  const {board,card}=await setup(page);
  try {
    await expect(card.locator('.scene-view svg')).toContainText('Saved path');
    await page.locator('#langs button').filter({hasText:'繁'}).click();
    await expect(card.locator('.scene-view svg')).toContainText('已存路徑');
    await expect(card.locator('[data-code-panel]')).toBeHidden();
  } finally {await stopBoard(board);}
});


test('task details animate the spec without a code walk',async({page})=>{
  const root=makeRoot([],false), source=sceneWalkCard();
  const fields=['intent','why','scope_in','scope_out','done','notes','before_nodes','after_nodes','scene'];
  const explain=Object.fromEntries(['en','zh-TW'].map(lang=>[lang,Object.fromEntries(fields.filter(k=>k in source.details[lang]).map(k=>[k,source.details[lang][k]]))]));
  writeTasks(root,[{id:'T-211',title:'Record walk',depends_on:[],scope:[],acceptance:[],explain}]);
  const board=await startBoard(root);
  try {
    await page.goto(board.url+'/?lang=en');await showFleet(page);
    await page.locator('.card[data-task="T-211"]').first().click();
    const panel=page.locator('#taskDetail');
    await expect(panel.locator('.scene-view')).toBeVisible();
    await expect(panel.locator('[data-code-tab]')).toHaveCount(0);
  } finally {await stopBoard(board);}
});


function specExplain(source:any) {
  const fields=['intent','why','scope_in','scope_out','done','notes','before_nodes','after_nodes','scene'];
  return Object.fromEntries(['en','zh-TW'].map(lang=>[lang,Object.fromEntries(fields.filter(k=>k in source.details[lang]).map(k=>[k,source.details[lang][k]]))]));
}

for (const variant of ['older card without a scene','card with a different scene'] as const) test(`task details take the scene from the spec over an ${variant}`,async({page})=>{
  const root=makeRoot([],false);
  writeTasks(root,[{id:'T-211',title:'Record walk',depends_on:[],scope:[],acceptance:[],explain:specExplain(sceneWalkCard())}]);
  const card=sceneWalkCard(variant==='older card without a scene' ? 'walk' : 'both');
  if (variant==='card with a different scene') for (const locale of ['en','zh-TW']) card.details[locale].scene.nodes[2].label=locale==='en' ? 'Card path' : '卡片路徑';
  mkdirSync(join(root,'state/decisions'),{recursive:true});
  writeFileSync(join(root,'state/decisions/D-9242.json'),JSON.stringify({...card,chosen:'A',ts:'2026-10-01T00:00:00Z'}));
  const board=await startBoard(root);
  try {
    await page.goto(board.url+'/?lang=en');await showFleet(page);
    await page.locator('.card[data-task="T-211"]').first().click();
    const panel=page.locator('#taskDetail');
    await expect(panel.locator('.scene-view svg')).toContainText('Saved path');
    await expect(panel.locator('.scene-view svg')).not.toContainText('Card path');
    await expect(panel.locator('[data-code-tab]')).toHaveCount(0);
  } finally {await stopBoard(board);}
});


test('task details show no scene when the spec has none, even if an older card has one',async({page})=>{
  const root=makeRoot([],false),explain=specExplain(sceneWalkCard());
  for (const locale of ['en','zh-TW']) delete explain[locale].scene;
  writeTasks(root,[{id:'T-211',title:'Record walk',depends_on:[],scope:[],acceptance:[],explain}]);
  mkdirSync(join(root,'state/decisions'),{recursive:true});
  writeFileSync(join(root,'state/decisions/D-9242.json'),JSON.stringify({...sceneWalkCard('both'),chosen:'A',ts:'2026-10-01T00:00:00Z'}));
  const board=await startBoard(root);
  try {
    await page.goto(board.url+'/?lang=en');await showFleet(page);
    await page.locator('.card[data-task="T-211"]').first().click();
    const panel=page.locator('#taskDetail');
    await expect(panel).toContainText('Keep the saved records.');
    await expect(panel.locator('.scene-view')).toHaveCount(0);
    await expect(panel.locator('[data-code-tab]')).toHaveCount(0);
  } finally {await stopBoard(board);}
});

test('self-loop and upward edges route outside every node and carry the token',async({page})=>{
  const root=makeRoot([],false),source=sceneWalkCard();
  for (const locale of ['en','zh-TW']) {
    const scene=source.details[locale].scene;
    scene.nodes.push({id:'retry',label:locale==='en' ? 'Retry' : '重試',lane:1,kind:'step',state:'same'});
    scene.edges.push({id:'loop',from:'input',to:'input',state:'same'},
      {id:'back',from:'retry',to:'saved',state:'new',change:'c1'},
      {id:'skip',from:'retry',to:'old',state:'gone',change:'c1'});
    scene.tokens.after=['loop','saved-path'];
  }
  writeTasks(root,[{id:'T-211',title:'Record walk',depends_on:[]}]);
  writeFileSync(join(root,'state/pending/D-9242.json'),JSON.stringify(source));
  const board=await startBoard(root);
  try {
    await page.goto(board.url+'/?lang=en');const card=page.locator('#card-D-9242');
    await expect(card.locator('[data-scene-id="loop"] path').first()).toBeAttached();
    const inside=()=>card.locator('.scene-view svg').evaluate((svg:SVGSVGElement)=>{
      const rects=[...svg.querySelectorAll('.scene-node')].map(g=>{const m=/translate\(([-\d.]+),([-\d.]+)\)/.exec(g.getAttribute('transform')||'')!;return {id:g.getAttribute('data-scene-id'),x:Number(m[1]),y:Number(m[2])};});
      const hit=(x:number,y:number)=>rects.filter(r=>x>r.x+1 && x<r.x+189 && y>r.y+1 && y<r.y+49).map(r=>r.id);
      const edges:Record<string,string[]>={};
      for (const g of svg.querySelectorAll('.scene-edge')) {
        const path=g.querySelector('path') as SVGPathElement, length=path.getTotalLength(), found=new Set<string>();
        for (let i=0;i<=40;i++){const p=path.getPointAtLength(length*i/40);for(const id of hit(p.x,p.y))found.add(id);}
        edges[g.getAttribute('data-scene-id')!]=[...found];
      }
      const token=svg.querySelector('.scene-token') as SVGCircleElement;
      return {edges,token:hit(Number(token.getAttribute('cx')),Number(token.getAttribute('cy'))),shown:token.style.display!=='none'};
    });
    for (const [id,nodes] of Object.entries((await inside()).edges)) expect(nodes,`edge ${id} passes through a node`).toEqual([]);
    await card.locator('[data-scrub]').evaluate((el: HTMLInputElement)=>{el.value='1.2';el.dispatchEvent(new Event('input',{bubbles:true}));});
    const playback=await inside();
    expect(playback.shown).toBe(true);
    expect(playback.token,'the token on the loop is visible outside its node').toEqual([]);
  } finally {await stopBoard(board);}
});


test('a highlighted intent keeps its banner across a state update and a locale switch',async({page})=>{
  const {board,card}=await setup(page);
  try {
    await card.locator('.walk-intent-link').first().click();
    await expect(card.locator('.scene-banner [data-show-all]')).toBeVisible();
    await expect(card.locator('.scene-banner [data-its-code]')).toHaveText('Walk its code');
    await page.evaluate(() => fetch('/api/state').then(r => r.json()).then((window as any).render));
    await expect(card.locator('.scene-banner [data-show-all]')).toBeVisible();
    await expect(card.locator('.scene-banner [data-its-code]')).toBeVisible();
    await page.locator('#langs button').filter({hasText:'繁'}).click();
    await expect(card.locator('.scene-banner [data-show-all]')).toHaveText('顯示全部');
    await expect(card.locator('.scene-banner [data-its-code]')).toHaveText('導覽此意圖的程式碼');
    await card.locator('.scene-banner [data-its-code]').click();
    await expect(card.locator('[data-intent-tab="1"]')).toHaveAttribute('aria-selected','true');
    await card.locator('.scene-banner [data-show-all]').click();
    await expect(card.locator('.scene-banner')).toBeHidden();
    await expect(card.locator('.scene-dim')).toHaveCount(0);
  } finally {await stopBoard(board);}
});


test('an intent with key blocks but no mapped change keeps its banner across a state update and a locale switch',async({page})=>{
  const root=makeRoot([],false),source=sceneWalkCard();
  for (const locale of ['en','zh-TW']) source.details[locale].scene.changes[0].intents=[2];
  writeTasks(root,[{id:'T-211',title:'Record walk',depends_on:[]}]);
  writeFileSync(join(root,'state/pending/D-9242.json'),JSON.stringify(source));
  const board=await startBoard(root);
  try {
    await page.goto(board.url+'/?lang=en');const card=page.locator('#card-D-9242');
    await card.locator('.intent-row').first().locator('.walk-intent-link').click();
    await expect(card.locator('.scene-banner [data-its-code]')).toBeVisible();
    await page.evaluate(() => fetch('/api/state').then(r => r.json()).then((window as any).render));
    await expect(card.locator('.scene-banner [data-its-code]')).toBeVisible();
    await page.locator('#langs button').filter({hasText:'繁'}).click();
    await expect(card.locator('.scene-banner [data-its-code]')).toHaveText('導覽此意圖的程式碼');
    await card.locator('.scene-banner [data-its-code]').click();
    await expect(card.locator('[data-intent-tab="1"]')).toHaveAttribute('aria-selected','true');
  } finally {await stopBoard(board);}
});

test('unmapped change highlights without a code jump',async({page})=>{
  const root=makeRoot([],false),source=sceneWalkCard();
  for(const locale of ['en','zh-TW']) source.details[locale].scene.changes.push({id:'c2',text:locale==='en'?'The output stays.':'輸出保留。',intents:[2]});
  writeTasks(root,[{id:'T-211',title:'Record walk',depends_on:[]}]);
  writeFileSync(join(root,'state/pending/D-9242.json'),JSON.stringify(source));
  const board=await startBoard(root);
  try {
    await page.goto(board.url+'/?lang=en');const card=page.locator('#card-D-9242');
    await card.locator('[data-badge="c2"]').click();
    await expect(card.locator('.scene-banner button').filter({hasText:'Walk its code'})).toBeDisabled();
    await expect(card.locator('[data-code-panel]')).toBeHidden();
    await expect(card.locator('.scene-dim').first()).toBeVisible();
  } finally {await stopBoard(board);}
});

test('external card renders from its private pending record',async({page})=>{
  const root=makeRoot([],false);
  writeProjects(root,[{name:'fixture',github:'example/self'},{name:'beta',github:'example/private',tasks:[{id:'T-211',title:'Private walk',depends_on:[],scope:[],acceptance:[]} as any]}]);
  const source=sceneWalkCard();source.id='D-beta-T211-1';source.project='beta';
  writeFileSync(join(projectState(root,'beta'),'pending/D-beta-T211-1.json'),JSON.stringify(source));
  const board=await startBoard(root);
  try {
    await page.goto(board.url+'/?lang=en');const card=page.locator('#card-D-beta-T211-1');
    await expect(card.locator('.scene-view')).toBeVisible();
    await card.locator('[data-code-tab]').click();
    await expect(card.locator('.walk-note').first()).toHaveText('The path keeps <b>input</b>.');
  } finally {await stopBoard(board);}
});
