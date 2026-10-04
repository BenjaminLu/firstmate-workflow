import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { expect } from '@playwright/test';
import { test, makeRoot, startBoard, stopBoard } from './lib/fixture';

test('voyage is one live stage, persists its size, and Esc Esc unloads it', async ({page}) => {
  const b=await startBoard(makeRoot(['working','review']));
  try {
    const errors:string[]=[]; page.on('pageerror',e=>errors.push(e.message));
    await page.goto(b.url+'/?lang=en');
    const stage=page.locator('#voyage-stage');
    await expect(stage).toHaveCount(1);
    await expect.poll(()=>page.frames().find(f=>f.url().includes('/voyage2d/'))?.evaluate(()=> (window as any).__G?.ready)).toBe(true);
    await page.keyboard.press('f');
    await expect(page.locator('body')).toHaveClass(/voyage-full/);
    await expect(page.locator('#voyage-drawer #counts')).toHaveCount(1);
    await expect(page.locator('#voyage-drawer #deckwrap')).toHaveCount(1);
    await page.reload();
    await expect(page.locator('body')).toHaveClass(/voyage-full/);
    const frame=page.frameLocator('#voyage-stage');
    await frame.locator('#c').click();
    await page.keyboard.press('Escape');
    await expect(page.locator('body')).not.toHaveClass(/voyage-full/);
    await page.keyboard.press('Escape');
    await expect(stage).toHaveCount(0);
    await expect(page.locator('#scene')).toBeHidden();
    await page.reload(); await expect(stage).toHaveCount(0);
    await page.keyboard.press('Escape'); await page.keyboard.press('Escape');
    await expect(stage).toHaveCount(1);
    expect(errors).toEqual([]);
  } finally { await stopBoard(b); }
});

test('Live stage requests only its static bundle and sees the board snapshot',async({page})=>{
  const b=await startBoard(makeRoot(['working']));
  try {
    const requests:string[]=[];
    page.on('request',r=>{if(r.frame().name()==='voyage-stage') requests.push(r.url());});
    await page.goto(b.url+'/?lang=en');
    await expect.poll(()=>page.frames().find(f=>f.url().includes('/voyage2d/'))?.evaluate(()=> (window as any).__G?.ready)).toBe(true);
    const f=page.frames().find(f=>f.url().includes('/voyage2d/'))!;
    const live=await f.evaluate(()=>({mode:(window as any).__voyageLive.mode, tasks:(window as any).__voyageLive.view.tasks.map((t:any)=>t.id)}));
    const state=await page.request.get(b.url+'/api/state').then(r=>r.json());
    expect(live.mode).toBe('live'); expect(live.tasks).toEqual(state.tasks.map((t:any)=>t.key));
    expect(requests.every(u=>u.startsWith(b.url+'/voyage2d/index.html'))).toBe(true);
    expect(await f.evaluate(()=> (window as any).__voyage2d)).toBeUndefined();
    expect(await f.evaluate(()=> (window as any).__G.errors)).toEqual([]);
    await expect(f.locator('#modeBadge')).toBeHidden();
    await expect(f.locator('#menuBtn')).toBeHidden();
  } finally { await stopBoard(b); }
});

test('Live commands use only authenticated board writes with the card project',async({page})=>{
  const b=await startBoard(makeRoot(['working']));
  try {
    await page.goto(b.url+'/?lang=en');
    await expect.poll(()=>page.frames().find(f=>f.name()==='voyage-stage')?.evaluate(()=> (window as any).__G?.ready)).toBe(true);
    const f=page.frames().find(f=>f.name()==='voyage-stage')!;
    const sent:{path:string,headers:Record<string,string>,body:any}[]=[];
    for(const path of ['/decisions','/tasks']) await page.route(b.url+path,async route=>{
      const request=route.request();
      sent.push({path,headers:await request.allHeaders(),body:request.postDataJSON()});
      await route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(path==='/decisions'
        ? {ok:true,decision:{id:request.postDataJSON().id},outcome:'recorded'} : {ok:true})});
    });
    const expected=await f.evaluate(async()=>{
      const source=(window as any).__voyageLive;
      const card=source.snapshot.pending.find((d:any)=>d.answerable!==false);
      const task=source.view.tasks.find((t:any)=>t.actions.includes('park'));
      if(!card || !task) throw new Error('fixture must provide an answerable card and parkable task');
      const chosen=Object.keys(card.details?.en?.options || {A:{}})[0];
      await source.command({type:'answer',decision:card.id,chosen});
      await source.command({type:'park',task:task.key,confirm:true});
      source.fighting=true;
      await source.command({type:'drop',task:task.key});
      return {cardProject:card.project,taskProject:task.project};
    });
    expect(sent.map(r=>r.path)).toEqual(['/decisions','/tasks']);
    const token=await page.evaluate(()=>sessionStorage.getItem('board.token'));
    for(const r of sent){expect(r.headers.authorization).toBe('Bearer '+token);expect(r.headers.origin).toBe(b.url);}
    expect(sent[0].body.project).toBe(expected.cardProject);
    expect(sent[1].body.project).toBe(expected.taskProject);
  } finally {await stopBoard(b);}
});

test('voyage shortcuts preserve board focus and defer to menus and confirmations', async ({page}) => {
  const b=await startBoard(makeRoot(['working']));
  try {
    await page.goto(b.url+'/?lang=en');
    const menu=page.locator('.cmenu:not(:disabled)').first();
    await menu.focus();
    const cancelled=await menu.evaluate(el=>!el.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true})));
    expect(cancelled).toBe(false);
    await expect(menu).toBeFocused();
    await page.keyboard.press('f');
    await expect(page.locator('body')).toHaveClass(/voyage-full/);
    await menu.click();
    await page.keyboard.press('f');
    await expect(page.locator('[role="menu"]')).toBeVisible();
    await expect(page.locator('body')).toHaveClass(/voyage-full/);
    await page.keyboard.press('Escape');
    await expect(menu).toBeFocused();
    await expect(page.locator('body')).toHaveClass(/voyage-full/);
    await menu.click();
    await page.locator('[role="menu"] [data-act="drop"]').click();
    await page.keyboard.press('f');
    await expect(page.locator('#dropConfirm')).toBeVisible();
    await expect(page.locator('body')).toHaveClass(/voyage-full/);
    await page.keyboard.press('Escape');
    await expect(page.locator('#dropConfirm')).toBeHidden();
    await expect(menu).toBeFocused();
    await expect(page.locator('body')).toHaveClass(/voyage-full/);
  } finally { await stopBoard(b); }
});


test('voyage follows the responsive decision order without reloading its stage', async ({page}) => {
  const b=await startBoard(makeRoot(['working']));
  try {
    await page.setViewportSize({width:1000,height:844});
    await page.goto(b.url+'/?lang=en');
    const panel=page.locator('#voyage'), card=page.locator('.dcard').first();
    await expect(card).toBeVisible();
    const stage=await page.locator('#voyage-stage').elementHandle();
    const frame=page.frameLocator('#voyage-stage');
    await expect(frame.locator('#c')).toBeVisible();
    await frame.locator('body').evaluate(()=>{(window as any).__resizeSentinel='same stage';});
    expect((await panel.boundingBox())!.y).toBeLessThan((await card.boundingBox())!.y);
    for(const width of [650,390]) {
      await page.setViewportSize({width,height:844});
      await expect.poll(async()=> (await panel.boundingBox())!.y > (await card.boundingBox())!.y).toBe(true);
      expect((await card.boundingBox())!.y).toBeLessThan(844);
      expect((await panel.boundingBox())!.y).toBeLessThan((await page.locator('.lanes-wrap').boundingBox())!.y);
    }
    await page.keyboard.press('f');
    await expect(page.locator('#voyage-drawer #deckwrap')).toHaveCount(1);
    await page.keyboard.press('Escape');
    await expect(page.locator('#voyage-drawer #deckwrap')).toHaveCount(0);
    await page.setViewportSize({width:651,height:844});
    await expect.poll(async()=> (await panel.boundingBox())!.y < (await card.boundingBox())!.y).toBe(true);
    expect(await stage!.evaluate(el=>el===document.querySelector('#voyage-stage'))).toBe(true);
    expect(await frame.locator('body').evaluate(()=>(window as any).__resizeSentinel)).toBe('same stage');
  } finally {await stopBoard(b);}
});

test('a missing Live build leaves the working board without a game panel', async ({page}) => {
  const root=makeRoot(['working']);
  rmSync(join(root,'board/public/voyage2d/index.html'),{force:true});
  const b=await startBoard(root);
  try {
    const requested:string[]=[];
    page.on('request',r=>requested.push(r.url()));
    await page.goto(b.url+'/?lang=en');
    await expect(page.locator('.dcard').first()).toBeVisible();
    await expect(page.locator('#voyage')).toHaveCount(0);
    await page.keyboard.press('f');
    await page.keyboard.press('Escape');await page.keyboard.press('Escape');
    await expect(page.locator('#voyage-stage')).toHaveCount(0);
    expect(requested.some(u=>u.includes('/voyage2d/') || u.endsWith('/game.js'))).toBe(false);
  } finally {await stopBoard(b);}
});
