import { expect } from '@playwright/test';
import { test, makeRoot, startBoard, stopBoard } from './lib/fixture';
import { intentCard } from './lib/intent-card';
import { writeFileSync, renameSync } from 'node:fs';
import { join } from 'node:path';

test('captain rows, disclosures and sheet focus survive state and locale changes', async ({page}) => {
  const root = makeRoot([], false), d = intentCard();
  d.details.en.done = [{text:'Intent 1: Listed evidence.'},{text:'Unpaired evidence.'},{text:'Intent 9: Outside range.'}];
  writeFileSync(join(root, 'state/pending/D-211.json'), JSON.stringify(d));
  writeFileSync(join(root, 'state/pending/D-212.json'), JSON.stringify(intentCard('D-212')));
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    const card = page.locator('#card-D-211');
    await expect(card.locator('.intent-alignment h4')).toHaveText(['Intent','How it works','Scope','Notes']);
    await expect(card.locator('.intent-row .alignment-row')).toHaveText('✓ Intent 1: Listed evidence.');
    await expect(card.locator('.plain-alignment .alignment-row')).toHaveText(['Unpaired evidence.','Intent 9: Outside range.']);
    await expect(card.locator('.ste-chip,.ste-sentence')).toHaveCount(0);
    await expect(card.locator('.decision-bar')).toHaveCSS('position','sticky');
    await expect(card.locator('.decision-bar')).toHaveCSS('bottom','0px');
    await page.locator('#strip-D-212 > summary').click();
    await expect(page.locator('#card-D-212 .decision-bar')).toHaveCSS('position','static');
    await expect(card.locator('.explanation')).toBeHidden();
    await card.getByText('Why you see this', {exact:true}).click();
    await expect(card.locator('.explanation')).toBeVisible();
    await card.locator('[data-decision-details]').click();
    const sheet = card.getByRole('dialog');
    await expect(sheet).toBeVisible();
    await expect(sheet.locator('h4')).toHaveText(['Options','Questions to confirm']);
    await expect(sheet).toContainText(d.details.en.options.A.pros);
    await expect(sheet).toContainText(d.details.en.options.A.cons);
    await sheet.locator('[data-question="0"][data-ok="no"]').click();
    const input = sheet.locator('textarea[data-question="0"]');
    await input.fill('Keep my correction');
    d.details.en.title = 'Pushed card';
    writeFileSync(join(root,'state/pending/.push'),JSON.stringify(d));
    renameSync(join(root,'state/pending/.push'),join(root,'state/pending/D-211.json'));
    await expect(card.locator('h3')).toHaveText('Pushed card');
    await expect(input).toBeFocused();
    await page.evaluate(() => (document.querySelector('[data-l="zh-TW"]') as HTMLElement).click());
    await expect(input).toBeFocused();
    await expect(input).toHaveValue('Keep my correction');
    await expect(sheet).toBeVisible();
    await expect(card.locator('.explanation')).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(sheet).toBeHidden();
    await expect(card.locator('[data-decision-details]')).toBeFocused();
    await expect(page.locator('#voyage-stage')).toBeVisible();
  } finally { await stopBoard(b); }
});

for (const lang of ['en','zh-TW','zh-CN']) test(`pairing respects visible intent rows and done cap in ${lang}`, async ({page}) => {
  const root = makeRoot([], false), d = intentCard();
  for (const locale of ['en','zh-TW']) {
    d.details[locale].intent = Array.from({length:7},(_,i) => ({text:`Row ${i+1}`}));
    d.details[locale].done = [{text:locale === 'en' ? 'Intent 1: Paired' : '意圖 1：Paired'}, {text:'Intent 7: Hidden parent'}];
  }
  writeFileSync(join(root,'state/pending/D-211.json'),JSON.stringify(d));
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=${lang}`);
    const card = page.locator('#card-D-211');
    await expect(card.locator('.intent-row .alignment-row')).toContainText('Paired');
    await expect(card.locator('.plain-alignment')).toContainText('Hidden parent');
    await page.evaluate(() => {
      const w = window as any;
      return fetch('/api/state').then(r=>r.json()).then(s=>{
        for(const c of Object.values(s.pending[0].details) as any[]) if(c.intent) {
          c.intent=c.intent.slice(0,1); c.done=Array.from({length:7},(_,i)=>({text:`Intent 1: Evidence ${i}`}));
        }
        w.render(s);
      });
    });
    await expect(card.locator('.alignment-row')).toHaveCount(6);
    await expect(card.locator('[data-reveal]').filter({hasText:'(1)'})).toHaveCount(1);
  } finally { await stopBoard(b); }
});

for (const theme of ['light','dark']) test(`phone decision bar leaves disclosures reachable in ${theme}`, async ({page}) => {
  const root = makeRoot([],false), d = intentCard();
  d.details.en.done = Array.from({length:7},(_,i)=>({text:`Intent 1: Evidence ${i}`}));
  writeFileSync(join(root,'state/pending/D-211.json'),JSON.stringify(d));
  const b = await startBoard(root);
  try {
    await page.setViewportSize({width:390,height:844});
    await page.goto(`${b.url}/?lang=en`);
    await page.evaluate(theme => document.documentElement.dataset.theme=theme,theme);
    const card = page.locator('#card-D-211'), bar = card.locator('.decision-bar');
    await expect.poll(() => card.evaluate(el => parseFloat(getComputedStyle(el).paddingBottom) >= el.querySelector('.decision-bar')!.getBoundingClientRect().height)).toBe(true);
    await card.getByRole('button',{name:'Show more (1)',exact:true}).click();
    await expect(card.locator('.alignment-row')).toHaveCount(7);
    await bar.locator('[data-decision-details]').click();
    await expect(card.getByRole('dialog')).toBeVisible();
    for (const region of [bar,card.locator('.decision-sheet')]) {
      const style = await region.evaluate(el => {
        const s=getComputedStyle(el);
        const lum=(c:string)=>c.match(/[\d.]+/g)!.slice(0,3).map(Number).map(v=>v/255).map(v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4).reduce((sum,v,i)=>sum+v*[.2126,.7152,.0722][i],0);
        const a=lum(s.color),b=lum(s.backgroundColor);
        return {image:s.backgroundImage,contrast:(Math.max(a,b)+.05)/(Math.min(a,b)+.05)};
      });
      expect(style.image).toBe('none');
      expect(style.contrast).toBeGreaterThanOrEqual(4.5);
    }
    await card.locator('[data-decision-close]').click();
    await expect(card.locator('[data-decision-details]')).toBeFocused();
    expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
  } finally { await stopBoard(b); }
});
