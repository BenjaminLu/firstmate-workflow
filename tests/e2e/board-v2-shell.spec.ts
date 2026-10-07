import { expect, type Page } from '@playwright/test';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { test, makeRoot, startBoard, stopBoard, details } from './lib/fixture';
import { TW } from './lib/board';

const palettes = {
  light: ['#EEF2F0','#FFFFFF','#F6F8F7','#10233B','#5B6B7A','#CBD5D2','#F2B90F','#C2372C','#1D4F91','#2F7D5B'],
  dark: ['#0E1824','#16222F','#1C2A39','#E6EDF1','#93A3B1','#26384A','#F0B429','#E35D4F','#6EA8E8','#4FB286'],
};
const names = ['chart','hull','hull2','harbour','fog','line','signal','flag-red','flag-blue','kelp'];
async function height(page: Page, pixels: number) {
  await expect.poll(() => page.locator('#voyage-stage').evaluate(el => el.getBoundingClientRect().height)).toBe(pixels);
}
async function noScroll(page: Page) {
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1)).toBe(true);
}
for (const theme of ['light','dark'] as const) test(`shell ${theme} palette, system preference, toggle and persistence`, async ({page}) => {
  const b = await startBoard(makeRoot(['working']));
  try {
    await page.emulateMedia({colorScheme:theme});
    await page.goto(b.url+'/?lang=en');
    await expect(page.locator('html')).toHaveAttribute('data-theme',theme);
    expect(await page.evaluate(keys => {
      const style=getComputedStyle(document.documentElement);
      return keys.map(k=>style.getPropertyValue('--'+k).trim().toUpperCase());
    }, names)).toEqual(palettes[theme]);
    expect(await page.evaluate(()=>{
      const s=getComputedStyle(document.documentElement);
      return s.getPropertyValue('--bg').trim()===s.getPropertyValue('--chart').trim();
    })).toBe(true);
    expect(await page.evaluate(()=>{
      const s=getComputedStyle(document.documentElement);
      return ['t13','t15','t17','t21','t26','t33','t41','s1','s2','s3','s4','s5','s6','s7','r-chip','r-panel'].map(k=>s.getPropertyValue('--'+k).trim());
    })).toEqual(['13px','15px','17px','21px','26px','33px','41px','4px','8px','12px','16px','24px','32px','48px','4px','8px']);
    for (const width of [1440,390]) { await page.setViewportSize({width,height:900}); await noScroll(page); }
    await page.locator('#themeToggle').click();
    const other=theme==='light'?'dark':'light';
    await expect(page.locator('html')).toHaveAttribute('data-theme',other);
    expect(await page.evaluate(()=>localStorage.getItem('board.theme'))).toBe(other);
    await page.reload();
    await expect(page.locator('html')).toHaveAttribute('data-theme',other);
  } finally { await stopBoard(b); }
});

for (const query of ['', '?lang=en']) test(`storage methods may throw while rendering and switching language ${query}`, async ({page}) => {
  const b=await startBoard(makeRoot(['working']));
  try {
    // Authenticate before sabotaging Storage methods used by the login fixture.
    await page.goto(b.url+'/?lang=en');
    await page.addInitScript(()=>{
      Storage.prototype.getItem=()=>{throw new Error('storage unavailable');};
      Storage.prototype.setItem=()=>{throw new Error('storage unavailable');};
    });
    await page.emulateMedia({colorScheme:'light'});
    await page.goto(b.url+'/'+query);
    await expect(page.locator('.dcard').first()).toBeVisible();
    await expect(page.locator('#voyage')).toBeVisible();
    await page.locator('[data-l="zh-TW"]').click();
    await expect(page.locator('html')).toHaveAttribute('lang','zh-TW');
    await expect(page.locator('#themeToggle')).toHaveAttribute('aria-label',TW.themeToggle);
    await expect(page.locator('#themeToggle')).toHaveAttribute('title',TW.themeToggle);
    await expect(page.locator('#voyage-size')).toHaveAttribute('aria-label',TW.voyageShrink);
    await expect(page.locator('#voyage-size')).toHaveAttribute('title',TW.voyageShrink);
    await page.locator('#voyage-size').click();
    await expect(page.locator('#voyage-size')).toHaveAttribute('aria-label',TW.voyageGrow);
    await page.locator('#themeToggle').click();
    await expect(page.locator('html')).toHaveAttribute('data-theme','dark');
  } finally { await stopBoard(b); }
});

test('large stage shrinks and restores the viewer choice',async({page})=>{
  const b=await startBoard(makeRoot(['working']));
  try {
    await page.setViewportSize({width:1440,height:900});
    await page.goto(b.url+'/?lang=en');
    await height(page,324);
    const h=(await page.locator('#voyage-stage').boundingBox())!.height;
    expect(h).toBeGreaterThanOrEqual(270); expect(h).toBeLessThanOrEqual(440);
    await page.locator('#voyage-size').click(); await height(page,88);
    expect(await page.evaluate(()=>localStorage.getItem('board.voyage.size'))).toBe('strip');
    await page.reload(); await height(page,88);
    await page.emulateMedia({reducedMotion:'reduce'});
    await expect(page.locator('#voyage-stage')).toHaveCSS('transition-duration','0s');
  } finally {await stopBoard(b);}
});

for(const initialWidth of [390,1440]) test(`unstored size follows viewport until chosen, starting at ${initialWidth}`,async({page})=>{
  const b=await startBoard(makeRoot(['working']));
  try {
    await page.setViewportSize({width:initialWidth,height:initialWidth===1440?900:844});
    await page.goto(b.url+'/?lang=en');
    if(initialWidth===390) await height(page,72); else await height(page,324);
    for(const width of [650,390]) {
      await page.setViewportSize({width,height:844}); await height(page,72);
      const panel=(await page.locator('#voyage').boundingBox())!, card=(await page.locator('.dcard').first().boundingBox())!;
      expect(panel.y+panel.height).toBeLessThan(card.y);
      expect(panel.height+24).toBeLessThanOrEqual(160);
      expect(card.y).toBeLessThan(844);
    }
    await page.locator('#voyage-size').click(); await height(page,270);
    expect(await page.evaluate(()=>localStorage.getItem('board.voyage.size'))).toBe('full-size');
    await page.setViewportSize({width:1440,height:900}); await height(page,324);
    await page.setViewportSize({width:390,height:844}); await height(page,270);
    await page.reload(); await height(page,270);
  } finally {await stopBoard(b);}
});

test('320px language controls fit with doubled default text',async({page})=>{
  const b=await startBoard(makeRoot(['working']));
  try {
    await page.setViewportSize({width:320,height:844}); await page.goto(b.url+'/?lang=en');
    await page.addStyleTag({content:'body{font-size:32px} .card .t,.roster .jb,.log li,.dcard h3,.explanation,.tradeoffs,.acts button,.dstrip>summary{font-size:32px}'});
    for(const locale of ['en','zh-TW','zh-CN']) {
      await page.locator(`[data-l="${locale}"]`).click(); await noScroll(page);
      for(const button of await page.locator('.langs button:visible').all()) {
        const r=(await button.boundingBox())!; expect(r.x).toBeGreaterThanOrEqual(0); expect(r.x+r.width).toBeLessThanOrEqual(320);
      }
      await expect(page.locator('#themeToggle')).toHaveCSS('width','32px');
      await expect(page.locator('#themeToggle')).toHaveCSS('height','32px');
    }
  } finally {await stopBoard(b);}
});

test('stored strip never constrains full mode and hidden voyage hides size control',async({page})=>{
  const b=await startBoard(makeRoot(['working']));
  try {
    await page.setViewportSize({width:390,height:844}); await page.goto(b.url+'/?lang=en');
    await page.evaluate(()=>localStorage.setItem('board.voyage.size','strip')); await page.reload(); await height(page,72);
    await page.locator('#voyage-toggle').click();
    await expect(page.locator('body')).toHaveClass(/voyage-full/);
    await expect(page.locator('#voyage-size')).toBeHidden();
    await expect.poll(async()=> (await page.locator('#voyage-stage').boundingBox())!.height).toBeGreaterThan(72);
    const p=(await page.locator('#voyage').boundingBox())!, s=(await page.locator('#voyage-stage').boundingBox())!, d=(await page.locator('#voyage-drawer').boundingBox())!;
    expect(p.x).toBe(0);expect(p.y).toBe(0);expect(p.width).toBe(390);expect(p.height).toBe(844);
    expect(s.height).toBeGreaterThan(72);expect(s.y+s.height).toBeLessThanOrEqual(d.y+1);
    await page.locator('#voyage-workflow').click();
    await expect.poll(async()=> (await page.locator('#voyage-stage').boundingBox())!.height).toBeGreaterThan(700);
    await page.keyboard.press('Escape'); await height(page,72);
    await page.evaluate(()=>{(window as any).VOYAGE.key('Escape');(window as any).VOYAGE.key('Escape');});
    await expect(page.locator('#voyage-size')).toBeHidden();
    await expect(page.locator('#voyage-stage')).toHaveCount(0);
  } finally {await stopBoard(b);}
});

for(const width of [1440,390]) test(`light text contrast sweep at ${width}`,async({page})=>{
  const root=makeRoot(['working','review']);
  writeFileSync(join(root,'config.yaml'),'vendor: vendor-alpha\nreviewer:\n  vendor: vendor-beta\n');
  writeFileSync(join(root,'state/pending/D-2.json'),JSON.stringify({id:'D-2',kind:'choice',purpose:'dispatch',task:'T-002',details}));
  const b=await startBoard(root);
  try {
    await page.setViewportSize({width,height:width===1440?900:844}); await page.emulateMedia({colorScheme:'light'});
    await page.route('**/api/session',route=>route.fulfill({json:{writable:false}}));
    await page.route('**/api/state',async route=>{
      const response=await route.fetch(), state=await response.json();
      state.crew=state.crew.filter((c:any)=>c.state!=='queued');
      Object.assign(state.crew[0],{host_recorded:true,host_confirmed:false,vendor:'vendor-alpha',model_mismatch:true,model_requested:'requested',model:'actual'});
      await route.fulfill({response,json:state});
    });
    await page.goto(b.url+'/?lang=en');
    await expect(page.locator('[data-count="waiting"] b')).toHaveText('2');
    await expect(page.locator('#engine')).toBeVisible();
    await expect(page.locator('#readOnly')).toBeVisible();
    await page.locator('.dstrip > summary').click();
    await page.locator('.rgroupbtn').click();
    await expect(page.locator('.roster h4.rgroup').first()).toBeVisible();
    if(width===390) for(const cell of ['.rv','.jb']) {
      const field=page.locator('.roster li.rrow').first().locator(cell);
      expect(await field.evaluate(el=>el.getBoundingClientRect().width)).toBeGreaterThan(100);
    }
    await expect(page.locator('.roster .warn').first()).toBeVisible();
    await expect(page.locator('#log .k-greenlit')).toBeVisible();
    expect(await page.evaluate(()=>{
      const s=getComputedStyle(document.documentElement);
      return ['brass','warn','wait','ok','bad','accent','fg','fg2','fg3'].map(k=>s.getPropertyValue('--'+k).trim().toUpperCase());
    })).toEqual(['#7A5600','#8A4B00','#6B2FA0','#1E6B47','#B3261E','#1D4F91','#10233B','#5B6B7A','#5B6B7A']);
    const result=await page.evaluate(()=>{
      const rgba=(s:string):number[]=>{
        if(s.startsWith('#')) return [...s.slice(1).match(/../g)!.map(v=>parseInt(v,16)),1];
        const v=s.match(/[\d.]+/g)!.map(Number); return [v[0],v[1],v[2],v[3]??1];
      };
      const over=(a:number[],b:number[])=>[...a.slice(0,3).map((v,i)=>v*a[3]+b[i]*(1-a[3])),1];
      const lum=(c:number[])=>c.slice(0,3).map(v=>v/255).map(v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4).reduce((s,v,i)=>s+v*[.2126,.7152,.0722][i],0);
      const failures:string[]=[];let checked=0;
      const roots=document.querySelectorAll('.top,#readOnly,.counts,#deckwrap,#shipregion,.logwrap');
      for(const root of roots) for(const el of [root,...root.querySelectorAll('*')]) {
        if(!(el instanceof HTMLElement) || !el.checkVisibility() || ![...el.childNodes].some(n=>n.nodeType===Node.TEXT_NODE && n.textContent?.trim())) continue;
        // Frames are separate documents; the voyage bar is outside these roots.
        if(el.closest('iframe,#voyage-bar,.kbadge,[aria-pressed="true"]')) continue;
        const chain:Element[]=[];for(let n:Element|null=el;n;n=n.parentElement)chain.push(n);
        let bg=rgba(getComputedStyle(document.body).backgroundColor);
        const unknown=chain.some(n=>getComputedStyle(n).backgroundImage!=='none');
        if(unknown) {
          if(el.matches('.capstage .lbl,.capstage .lbl b,.capstage .lbl span')) bg=rgba('#140f22');
          else if(el.matches('.acts .go')) bg=rgba('#b8862c');
          else {failures.push(el.tagName+'.'+el.className+': unknown background image');continue;}
        } else for(const n of chain.reverse()) bg=over(rgba(getComputedStyle(n).backgroundColor),bg);
        const fg=over(rgba(getComputedStyle(el).color),bg), a=lum(fg), b=lum(bg), ratio=(Math.max(a,b)+.05)/(Math.min(a,b)+.05);
        checked++;if(ratio<4.5) failures.push(`${el.tagName}.${el.className} ${el.textContent?.trim().slice(0,60)}: ${ratio.toFixed(2)}`);
      }
      return {checked,failures};
    });
    expect(result.checked).toBeGreaterThan(60);
    expect(result.failures).toEqual([]);
  } finally {await stopBoard(b);}
});
