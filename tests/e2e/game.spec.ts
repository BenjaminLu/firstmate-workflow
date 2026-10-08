import { showFleet } from './lib/board';
import { rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { expect, type Request } from '@playwright/test';
import { test, makeRoot, startBoard, stopBoard, writeProjects, projectState, details } from './lib/fixture';

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
    await expect(page.locator('#scene')).toHaveCount(0);
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

test('voyage waits for the rendered board and idle before creating its stage', async ({page}) => {
  const b=await startBoard(makeRoot(['working']));
  try {
    await page.addInitScript(()=>{
      if(window!==window.top)return;
      const callbacks=new Map<number,IdleRequestCallback>();let id=0;
      window.requestIdleCallback=callback=>{callbacks.set(++id,callback);return id;};
      window.cancelIdleCallback=id=>{callbacks.delete(id);};
      (window as any).__flushVoyageIdle=()=>{
        const batch=[...callbacks.values()];callbacks.clear();
        for(const callback of batch)callback({didTimeout:false,timeRemaining:()=>50});
      };
    });
    await page.goto(b.url+'/?lang=en');
    await expect(page.locator('.dcard')).toBeVisible();
    // With idle work held, even a completed load and board render cannot mount it.
    await expect(page.locator('#voyage-stage')).toHaveCount(0);
    await page.evaluate(()=>(window as any).__flushVoyageIdle());
    await expect(page.locator('#voyage-stage')).toHaveCount(1);
    await expect.poll(()=>page.frames().find(f=>f.name()==='voyage-stage')?.evaluate(()=> (window as any).__G?.ready)).toBe(true);
  } finally {await stopBoard(b);}
});

test('voyage cancels its animation loop while hidden and resumes only one loop', async ({page}) => {
  const b=await startBoard(makeRoot(['working']));
  try {
    await page.addInitScript(()=>{
      if(window===window.top)return;
      const request=window.requestAnimationFrame.bind(window);
      const cancel=window.cancelAnimationFrame.bind(window);
      const pending=new Set<number>();let ticks=0;
      window.requestAnimationFrame=callback=>{
        const id=request(time=>{pending.delete(id);ticks++;callback(time);});
        pending.add(id);return id;
      };
      window.cancelAnimationFrame=id=>{pending.delete(id);cancel(id);};
      (window as any).__animationProbe={pending,get ticks(){return ticks;}};
    });
    await page.goto(b.url+'/?lang=en');
    await expect.poll(()=>page.frames().find(f=>f.name()==='voyage-stage')?.evaluate(()=> (window as any).__G?.ready)).toBe(true);
    const frame=page.frames().find(f=>f.name()==='voyage-stage')!;
    const paused=await frame.evaluate(()=>{
      Object.defineProperty(document,'hidden',{configurable:true,get:()=>true});
      document.dispatchEvent(new Event('visibilitychange'));
      const probe=(window as any).__animationProbe;
      return {pending:probe.pending.size,ticks:probe.ticks};
    });
    expect(paused.pending).toBe(0);
    // Yield across a browser frame; no voyage callback may run during the pause.
    await page.evaluate(()=>new Promise<void>(resolve=>requestAnimationFrame(()=>resolve())));
    expect(await frame.evaluate(()=>(window as any).__animationProbe.ticks)).toBe(paused.ticks);
    expect(await frame.evaluate(()=>{
      Object.defineProperty(document,'hidden',{configurable:true,get:()=>false});
      document.dispatchEvent(new Event('visibilitychange'));
      document.dispatchEvent(new Event('visibilitychange'));
      return (window as any).__animationProbe.pending.size;
    })).toBe(1);
    await expect.poll(()=>frame.evaluate(()=>(window as any).__animationProbe.ticks)).toBeGreaterThan(paused.ticks);
  } finally {await stopBoard(b);}
});

test('board refresh defers voyage subscribers and retains the stage', async ({page}) => {
  const b=await startBoard(makeRoot(['working']));
  try {
    await page.goto(b.url+'/?lang=en');
    await expect.poll(()=>page.frames().find(f=>f.name()==='voyage-stage')?.evaluate(()=> (window as any).__G?.ready)).toBe(true);
    const result=await page.evaluate(async()=>{
      const w=window as any;
      const state=await (await fetch('/api/state')).json();
      const stage=document.querySelector<HTMLIFrameElement>('#voyage-stage')!;
      const stageWindow=stage.contentWindow;
      const stageDocument=stage.contentDocument;
      const delivered:number[]=[];
      const off=w.VOYAGE.subscribe((s:any)=>{if(s.refreshProbe)delivered.push(s.refreshProbe);});
      w.render({...state,refreshProbe:1});
      w.render({...state,refreshProbe:2});
      w.__refreshDelivery={delivered,off,stage,stageWindow,stageDocument};
      return {synchronous:delivered.slice(),sameStage:stage===document.querySelector('#voyage-stage'),
        sameWindow:stageWindow===document.querySelector<HTMLIFrameElement>('#voyage-stage')!.contentWindow,
        sameDocument:stageDocument===document.querySelector<HTMLIFrameElement>('#voyage-stage')!.contentDocument};
    });
    expect(result.synchronous).toEqual([]);
    expect(result.sameStage).toBe(true);
    expect(result.sameWindow).toBe(true);
    expect(result.sameDocument).toBe(true);
    await expect.poll(()=>page.evaluate(()=>(window as any).__refreshDelivery.delivered)).toEqual([1,2]);
    expect(await page.evaluate(()=>{
      const probe=(window as any).__refreshDelivery;
      const stage=document.querySelector<HTMLIFrameElement>('#voyage-stage')!;
      probe.off();
      return {element:probe.stage===stage,window:probe.stageWindow===stage.contentWindow,
        document:probe.stageDocument===stage.contentDocument};
    })).toEqual({element:true,window:true,document:true});
  } finally {await stopBoard(b);}
});

for (const project of [null, 'beta']) test('Live commands use only authenticated board writes with the card project'+(project ? ' in a two-project board' : ''),async({page})=>{
  const root=makeRoot(['working']);
  if(project) {
    writeProjects(root,[
      {name:'alpha',github:'example-org/alpha-app'},
      {name:project,github:'example-org/beta-app',tasks:[{id:'T-001',title:'Beta task',depends_on:[]}]},
    ]);
    const state=projectState(root,project);
    writeFileSync(join(state,'events.jsonl'),JSON.stringify({
      ts:'2026-09-21T09:01:00Z',actor:'worker-beta',project,task:'T-001',type:'dispatched',
      summary:{en:'Beta task','zh-TW':'Beta task'},
    })+'\n');
    writeFileSync(join(state,'pending/D-beta-T001-1.json'),JSON.stringify({
      id:'D-beta-T001-1',project,task:'T-001',kind:'choice',details,
    }));
  }
  const b=await startBoard(root);
  try {
    await page.goto(b.url+'/?lang=en'+(project ? '&project='+project : ''));
    // Authentication belongs to fixture setup. From this reload through the last
    // command, page events record every request, including every child frame.
    const requests:Request[]=[];
    page.on('request',request=>requests.push(request));
    await page.reload();
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
      const answer=await source.command({type:'answer',decision:card.id,chosen});
      const park=await source.command({type:'park',task:task.key,confirm:true});
      if(!answer.ok || !park.ok) throw new Error(JSON.stringify({answer,park}));
      source.fighting=true;
      await source.command({type:'drop',task:task.key});
      return {cardProject:card.project,taskProject:task.project};
    });
    // Drain requests already scheduled by the completed commands before auditing.
    await page.evaluate(()=>new Promise<void>(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve()))));
    const reads=new Set(['/', '/board.css', '/board.js', '/ship.css', '/ship.js', '/diagram.js', '/watch.js', '/game.js',
      '/api/i18n', '/api/session', '/api/state', '/events', '/voyage2d/captain.webp']);
    // Only the fixture's own diagrams are expected. HEAD belongs to the board;
    // GET belongs to its diagram iframe, never to the voyage frame.
    const diagrams=new Set(['/diagrams/D-1.en.html', ...(project ? ['/diagrams/D-beta-T001-1.en.html'] : [])]);
    const writes=requests.filter(r=>r.method()==='POST');
    expect(writes.map(r=>new URL(r.url()).pathname)).toEqual(['/decisions','/tasks']);
    expect(requests.filter(r=>{
      const url=new URL(r.url());
      const frame=r.frame(), main=page.mainFrame(), method=r.method();
      const boardRead=frame===main && (method==='GET' && reads.has(url.pathname)
        || method==='HEAD' && diagrams.has(url.pathname));
      const diagramRead=method==='GET' && diagrams.has(url.pathname) && frame!==f
        && frame.parentFrame()===main;
      const stageRead=frame===f && method==='GET' && url.pathname==='/voyage2d/index.html';
      const stageWrite=frame===f && method==='POST' && ['/decisions','/tasks'].includes(url.pathname);
      return url.origin!==b.url || !(boardRead || diagramRead || stageRead || stageWrite);
    }).map(r=>r.method()+' '+r.url())).toEqual([]);
    expect(writes.every(r=>r.frame()===f)).toBe(true);
    expect(sent.map(r=>r.path)).toEqual(['/decisions','/tasks']);
    const token=await page.evaluate(()=>sessionStorage.getItem('board.token'));
    expect(token).toBeTruthy();
    for(const request of writes) {
      const headers=await request.allHeaders();
      expect(headers.authorization).toBe('Bearer '+token);
      expect(headers.origin).toBe(b.url);
    }
    for(const r of sent){expect(r.headers.authorization).toBe('Bearer '+token);expect(r.headers.origin).toBe(b.url);}
    for(const [index,ownProject] of [expected.cardProject,expected.taskProject].entries()) {
      expect(ownProject || null).toBe(project);
      if(ownProject) expect(sent[index].body.project).toBe(ownProject);
      else expect('project' in sent[index].body).toBe(false);
    }
  } finally {await stopBoard(b);}
});

for (const width of [1280,650,390]) test('voyage shortcuts preserve board focus and defer to menus and confirmations'+(width===1280?'':` at ${width}px`), async ({page}) => {
  const b=await startBoard(makeRoot(['working']));
  try {
    await page.goto(b.url+'/?lang=en');
    await page.setViewportSize({width,height:844});
    await showFleet(page);
    const menu=page.locator('.cmenu:not(:disabled)').first();
    await menu.focus();
    const cancelled=await menu.evaluate(el=>!el.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true})));
    expect(cancelled).toBe(false);
    await expect(menu).toBeFocused();
    await page.keyboard.press('f');
    await expect(page.locator('body')).toHaveClass(/voyage-full/);
    const stage=page.locator('#voyage-stage'), drawer=page.locator('#voyage-drawer');
    const stageBox=(await stage.boundingBox())!, drawerBox=(await drawer.boundingBox())!;
    expect(stageBox.x+stageBox.width<=drawerBox.x+1 || stageBox.y+stageBox.height<=drawerBox.y+1).toBe(true);
    await page.frameLocator('#voyage-stage').locator('#c').click();
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
    await page.locator('#dropConfirm button').first().click({trial:true});
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
      await expect.poll(async()=> (await panel.boundingBox())!.y < (await card.boundingBox())!.y).toBe(true);
      expect((await card.boundingBox())!.y).toBeLessThan(844);
      await showFleet(page);
      expect((await panel.boundingBox())!.y).toBeLessThan((await page.locator('.lanes-wrap').boundingBox())!.y);
      await page.locator('#tabDecisions').click();
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
    const requested:string[]=[], errors:string[]=[];
    page.on('request',r=>requested.push(r.url()));
    page.on('pageerror',e=>errors.push(e.message));
    await page.goto(b.url+'/?lang=en');
    await expect(page.locator('.dcard').first()).toBeVisible();
    await showFleet(page);
    await page.locator('.cmenu:not(:disabled)').first().click();
    await page.locator('[role="menu"] [data-act="drop"]').click();
    await expect(page.locator('#dropConfirm')).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(page.locator('#voyage')).toHaveCount(0);
    await page.keyboard.press('f');
    await page.keyboard.press('Escape');await page.keyboard.press('Escape');
    await expect(page.locator('#voyage-stage')).toHaveCount(0);
    await expect(page.locator('#capstage .capimg')).toHaveCount(0);
    expect(requested.some(u=>u.includes('/voyage2d/') || u.endsWith('/game.js'))).toBe(false);
    expect(errors).toEqual([]);
  } finally {await stopBoard(b);}
});


for (const action of ['decision','task']) test(`board ${action} writes remain available during a voyage fight`,async({page})=>{
  const b=await startBoard(makeRoot(['working']));
  try {
    await page.goto(b.url+'/?lang=en');
    await expect(page.locator('#voyage-stage')).toHaveCount(1);
    const path=action==='decision'?'/decisions':'/tasks';
    const sent:Request[]=[];
    await page.route(b.url+path,async route=>{
      sent.push(route.request());
      await route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(action==='decision'
        ? {ok:true,decision:{id:route.request().postDataJSON().id},outcome:'recorded'} : {ok:true})});
    });
    let selector;
    if(action==='decision') {
      await page.locator('.dcard .opt[data-c="B"]').first().click();
      selector='.dcard .confirm';
    } else {
      await showFleet(page);
      await page.locator('.cmenu:not(:disabled)').first().click();
      await page.locator('[role="menu"] [data-act="drop"]').click();
      selector='#dropConfirm [data-confirm="drop"]';
    }
    await expect(page.locator(selector).first()).toBeEnabled();
    // Set the flag and click in one browser turn: the stage's next frame cannot reset it.
    await page.evaluate(selector=>{
      (window as any).VOYAGE.fight(true);
      (document.querySelector(selector) as HTMLButtonElement).click();
    },selector);
    await expect.poll(()=>sent.length).toBe(1);
    expect(sent[0].method()).toBe('POST');
    expect(sent[0].postDataJSON()).toMatchObject(action==='decision'?{chosen:'B'}:{action:'drop',confirm:true});
  } finally {await stopBoard(b);}
});
