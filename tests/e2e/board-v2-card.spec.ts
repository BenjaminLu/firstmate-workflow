// T-289: the open decision card, ported from the approved v2 prototype. The
// card reads header, intent rows, How it works, then the walk and the intent
// check; its explanation waits behind "Why you see this"; the decision bar is
// the prototype's fixed bar with signal-flag option tiles.
import { openCard, openDecisionDetails, EN } from './lib/board';
import { expect } from '@playwright/test';
import { test, makeRoot, startBoard, stopBoard, writeTasks } from './lib/fixture';
import { intentCard, changePointCard, sceneWalkCard } from './lib/intent-card';
import { writeFileSync, renameSync } from 'node:fs';
import { join } from 'node:path';

test('an open card reads as the prototype: header, intent rows, How it works, then the walk and check', async ({page}) => {
  const root = makeRoot([], false), d = intentCard();
  d.details.en.done = [{text:'Intent 1: Listed evidence.'},{text:'Unpaired evidence.'}];
  writeFileSync(join(root, 'state/pending/D-211.json'), JSON.stringify(d));
  const b = await startBoard(root);
  try {
    await page.setViewportSize({width:1440, height:900});
    await page.goto(`${b.url}/?lang=en`);
    const card = page.locator('#card-D-211');
    await expect(card.locator(':scope > *')).toHaveClass([/caphead/, /kpsec/, /hero/, /align/, /dbar/]);
    // the header: kind first, the condensed headline, the pills and the toggle
    await expect(card.locator('.capmeta > :first-child')).toHaveClass('kbadge k-decision');
    await expect(card.locator('h2')).toHaveText(d.details.en.title);
    await expect(card.locator('h2')).toHaveCSS('font-family', /Avenir Next Condensed/);
    await expect(card.locator('h2')).toHaveCSS('font-size', '33px');
    const why = card.locator('.caphead .why');
    await expect(why).toHaveAttribute('aria-expanded', 'false');
    await expect(why.locator('.nb')).toHaveText(EN.noteCount.replace('{n}', '2'));
    // the explanation, why, notes and outcome are not on the card by default
    for (const text of [d.details.en.explanation, d.details.en.why[0].text, d.details.en.notes[1].text])
      await expect(card.getByText(text, {exact:true})).toBeHidden();
    await why.click();
    await expect(why).toHaveAttribute('aria-expanded', 'true');
    for (const text of [d.details.en.explanation, d.details.en.why[0].text, d.details.en.notes[1].text])
      await expect(card.getByText(text, {exact:true})).toBeVisible();
    await expect(card.locator('.drawer li.warn')).toHaveText(d.details.en.notes[1].text);
    // the intent rows, each with its status, and their evidence in the check
    await expect(card.locator('.kpsec h3')).toHaveText(EN.kpHeading);
    await expect(card.locator('.kp .kt')).toHaveText([d.details.en.intent[0].text]);
    await expect(card.locator('.kp .ks')).toHaveText([EN.kpEvidence]);
    await expect(card.locator('.hero h3')).toHaveText(EN.howHeading);
    await expect(card.locator('.align > .tabs [role=tab]')).toHaveText([EN.walkIntentCheck]);
    await expect(card.locator('.step .alignment-row')).toHaveText(['Intent 1: Listed evidence.']);
    await expect(card.locator('.plain-alignment li')).toHaveText(['Unpaired evidence.']);
    await expect(card.locator('.meta2 .chip')).toHaveText(['Board cards', 'Other pages']);
    // the decision bar is fixed to the bottom of the viewport
    const bar = card.locator('.dbar');
    await expect(bar).toHaveCSS('position', 'fixed');
    expect(Math.round((await bar.boundingBox())!.y + (await bar.boundingBox())!.height)).toBe(900);
    await expect(bar.locator('.mini .mflag b')).toHaveText(['A', 'B', 'C', '✎']);
    await expect(bar.locator('.mflag.f-A b')).toHaveCSS('background-color', 'rgb(242, 185, 15)');
    await expect(bar.locator('.confirm')).toHaveText(EN.pickOption);
    await bar.locator('[data-c="B"]').click();
    await expect(bar.locator('.confirm')).toHaveText(EN.sendChoice.replace('{k}', 'B'));
    // the card leaves room for the bar under its last line
    await page.evaluate(() => scrollTo(0, document.documentElement.scrollHeight));
    const last = (await card.locator('.align').boundingBox())!, row = (await bar.locator('.drow').boundingBox())!;
    expect(last.y + last.height).toBeLessThanOrEqual(row.y + 1);
  } finally { await stopBoard(b); }
});

test('the queue, the sheet and their focus survive state pushes and locale changes', async ({page}) => {
  const root = makeRoot([], false), d = intentCard();
  writeFileSync(join(root, 'state/pending/D-211.json'), JSON.stringify(d));
  writeFileSync(join(root, 'state/pending/D-212.json'), JSON.stringify(intentCard('D-212')));
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    await expect(page.locator('.queue .qitem')).toHaveCount(2);
    await expect(page.locator('#card-D-212')).toBeHidden();
    await expect(page.locator('#card-D-211 .pos')).toHaveText('1 / 2');
    await openCard(page, 'D-212');
    await expect(page.locator('#queue-D-212')).toHaveAttribute('aria-current', 'true');
    await expect(page.locator('#card-D-211')).toBeHidden();
    await openCard(page, 'D-211');
    const card = page.locator('#card-D-211');
    await openDecisionDetails(page, 'D-211');
    const sheet = card.getByRole('dialog');
    await expect(sheet.locator('h4')).toHaveText(['Options','Questions to confirm']);
    await expect(sheet).toContainText(d.details.en.options.A.pros);
    await expect(sheet).toContainText(d.details.en.options.A.cons);
    await expect(card.locator('[data-decision-details]')).toHaveText(EN.decisionHide);
    await sheet.locator('[data-question="0"][data-ok="no"]').click();
    const input = sheet.locator('textarea[data-question="0"]');
    await input.fill('Keep my correction');
    d.details.en.title = 'Pushed card';
    writeFileSync(join(root,'state/pending/.push'),JSON.stringify(d));
    renameSync(join(root,'state/pending/.push'),join(root,'state/pending/D-211.json'));
    await expect(card.locator('h2')).toHaveText('Pushed card');
    await expect(input).toBeFocused();
    await page.evaluate(() => (document.querySelector('[data-l="zh-TW"]') as HTMLElement).click());
    await expect(input).toBeFocused();
    await expect(input).toHaveValue('Keep my correction');
    await expect(sheet).toBeVisible();
    await expect(card).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(sheet).toBeHidden();
    await expect(card.locator('[data-decision-details]')).toBeFocused();
    await expect(page.locator('#voyage-stage')).toBeVisible();
  } finally { await stopBoard(b); }
});

test('a locked one-way merge opens the sheet, and its ticks and check unlock A', async ({page}) => {
  const root = makeRoot([], false);
  writeFileSync(join(root,'state/pending/D-9242.json'),JSON.stringify(changePointCard('one-way')));
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    const card = page.locator('#card-D-9242'), merge = card.locator('.mflag[data-c="A"]');
    await expect(card.locator('.capmeta .doorchip.one-way')).toHaveText(EN.doorOneWay);
    await expect(card.locator('.drow .doorchip')).toHaveText(EN.doorChipOne);
    await expect(merge).toHaveAttribute('aria-disabled', 'true');
    await expect(card.locator('.lockmsg')).toHaveText(EN.lockIntents.replace('{n}', '2') + EN.lockJoin + EN.lockQuestion);
    // a locked tile is aria-disabled, yet still answers a press by opening the sheet
    await merge.dispatchEvent('click');
    const sheet = card.locator('.dsheet');
    await expect(sheet).toBeVisible();
    await expect(sheet.locator('.door.one b')).toHaveText(EN.doorOneWay);
    await expect(sheet.locator('.understand .prog')).toContainText(EN.intentsChecked.replace('{have}', '0').replace('{need}', '2'));
    await card.locator('[data-review-intent="1"]').check();
    await card.locator('[data-review-intent="2"]').check();
    await expect(card.locator('.kp .ks').first()).toHaveText(EN.kpChecked + ' · ' + EN.kpChange);
    await expect(card.locator('.align [data-check-tab] i')).toHaveText('2/2');
    await sheet.locator('[data-door-answer="0"]').click();
    await expect(merge).toBeEnabled();
    await expect(card.locator('.lockmsg')).toHaveCount(0);
    await merge.click();
    await expect(card.locator('.confirm')).toHaveText(EN.sendChoice.replace('{k}', 'A'));
    await expect(sheet.locator('.flagbtn[data-pick="A"]')).toHaveAttribute('aria-pressed', 'true');
  } finally { await stopBoard(b); }
});

for (const viewport of [{width:1280,height:720}, {width:390,height:844}]) test(`with the sheet open, a card control scrolled into view is not under the fixed bar or the sticky header at ${viewport.width}px`, async ({page}) => {
  const root = makeRoot([], false);
  writeFileSync(join(root,'state/pending/D-9242.json'),JSON.stringify(changePointCard('one-way')));
  const b = await startBoard(root);
  try {
    await page.setViewportSize(viewport);
    await page.goto(`${b.url}/?lang=en`);
    await openDecisionDetails(page, 'D-9242');
    const card = page.locator('#card-D-9242'), bar = card.locator('.dbar');
    // the card keeps room for the whole bar, sheet included
    await expect.poll(async () => await card.evaluate((el, bar) => parseFloat(getComputedStyle(el).paddingBottom) - bar!.getBoundingClientRect().height,
      await bar.elementHandle())).toBeGreaterThanOrEqual(0);
    // a pointer can reach the card's last checkbox: scrolled to it, nothing covers it
    await card.locator('[data-review-intent="2"]').check({trial:true, timeout:10_000});
    // and scrolled to the top of the window, it lands below the sticky header
    const hit = await card.locator('[data-review-intent="2"]').evaluate(el => {
      el.scrollIntoView({block:'start'});
      const r = el.getBoundingClientRect(), at = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
      return at === el || Boolean(el.closest('label')?.contains(at));
    });
    expect(hit, 'scrolled to the top, the checkbox is uncovered').toBe(true);
  } finally { await stopBoard(b); }
});

for (const door of ['one-way', 'two-way'] as const) test(`a ${door} card with a walk opens on ${door === 'one-way' ? 'its evidence' : 'Walk the diff'}`, async ({page}) => {
  const root = makeRoot([], false), d = sceneWalkCard('both');
  for (const locale of ['en', 'zh-TW']) d.details[locale].door.kind = door;
  writeTasks(root,[{id:'T-211',title:'Record walk',depends_on:[]}]);
  writeFileSync(join(root,'state/pending/D-9242.json'),JSON.stringify(d));
  const b = await startBoard(root);
  try {
    await page.setViewportSize({width:1440, height:900});
    await page.goto(`${b.url}/?lang=en`);
    const card = page.locator('#card-D-9242');
    await expect(card.locator('.align > .tabs [role=tab]')).toHaveText([EN.walkDiff, /^Intent check/]);
    const walk = card.locator('[data-code-tab]'), check = card.locator('[data-check-tab]');
    await expect(walk).toHaveAttribute('aria-selected', String(door === 'two-way'));
    await expect(check).toHaveAttribute('aria-selected', String(door === 'one-way'));
    await walk.click();
    // the walk: intent tabs, then key blocks | code | explanation
    // one tab per intent (the card has two), then "Other changes"
    await expect(card.locator('.wtabs [role=tab] b')).toHaveText([`${EN.intentHeading} 1`, `${EN.intentHeading} 2`, EN.walkOther]);
    for (const area of ['.dtoc', '.dcode', '.dexplain']) await expect(card.locator(`.dwalk ${area}`)).toBeVisible();
    const [toc, code, explain] = await Promise.all(['.dtoc', '.dcode', '.dexplain'].map(async area => (await card.locator(`.dwalk ${area}`).boundingBox())!));
    expect(toc.x + toc.width).toBeLessThanOrEqual(code.x + 1);
    expect(code.x + code.width).toBeLessThanOrEqual(explain.x + 1);
    // How it works: the prototype's phase control and its numbered changes
    await expect(card.locator('.hero .seg2 button')).toHaveText([EN.walkBefore, EN.walkChange, EN.walkAfter]);
    await expect(card.locator('.hero .hchanges .cn2')).toHaveText(['1']);
    await check.click();
    await expect(card.locator('[data-check-panel]')).toBeVisible();
    await expect(card.locator('[data-code-panel]')).toBeHidden();
  } finally { await stopBoard(b); }
});

for (const theme of ['light','dark']) test(`the phone decision bar shows flag letters and keeps the card reachable in ${theme}`, async ({page}) => {
  const root = makeRoot([],false), d = intentCard();
  writeFileSync(join(root,'state/pending/D-211.json'),JSON.stringify(d));
  const b = await startBoard(root);
  try {
    await page.setViewportSize({width:390,height:844});
    await page.emulateMedia({colorScheme:theme});
    await page.goto(`${b.url}/?lang=en`);
    const card = page.locator('#card-D-211'), bar = card.locator('.dbar');
    await expect(bar.locator('.mflag span').first()).toBeHidden();
    await expect(bar.locator('.mflag b').first()).toBeVisible();
    // the tiles keep their names when their text is hidden at phone width
    await expect(bar.locator('[data-c="custom"]')).toHaveAccessibleName(EN.customChoice);
    await expect(bar.locator('[data-c="A"]')).toHaveAccessibleName(/^A · \S/);
    for (const control of ['.mflag[data-c="A"]', '[data-decision-details]', '.confirm'])
      expect((await bar.locator(control).boundingBox())!.height).toBeGreaterThanOrEqual(44);
    await expect.poll(() => card.evaluate(el => parseFloat(getComputedStyle(el).paddingBottom) >= el.querySelector('.drow')!.getBoundingClientRect().height)).toBe(true);
    await bar.locator('[data-decision-details]').click();
    await expect(card.getByRole('dialog')).toBeVisible();
    for (const region of [bar.locator('.drow'), card.locator('.dsheet')]) {
      const style = await region.evaluate(el => {
        const s = getComputedStyle(el), bg = getComputedStyle(el.closest('.dbar')!).backgroundColor;
        const lum = (c:string) => c.match(/[\d.]+/g)!.slice(0,3).map(Number).map(v=>v/255).map(v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4).reduce((sum,v,i)=>sum+v*[.2126,.7152,.0722][i],0);
        const a = lum(getComputedStyle(el.closest('.dbar')!).color), b = lum(s.backgroundColor === 'rgba(0, 0, 0, 0)' ? bg : s.backgroundColor);
        return {image:s.backgroundImage, contrast:(Math.max(a,b)+.05)/(Math.min(a,b)+.05)};
      });
      expect(style.image).toBe('none');
      expect(style.contrast).toBeGreaterThanOrEqual(4.5);
    }
    await card.locator('[data-decision-close]').click();
    await expect(card.locator('[data-decision-details]')).toBeFocused();
    expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
  } finally { await stopBoard(b); }
});

test('the prototype type scale and font stacks', async ({page}) => {
  const b = await startBoard(makeRoot(['working']));
  try {
    await page.setViewportSize({width:1440, height:900});
    await page.goto(`${b.url}/?lang=en`);
    const style = (selector: string) => page.locator(selector).first().evaluate(el => {
      const s = getComputedStyle(el); return {family:s.fontFamily, size:s.fontSize};
    });
    expect(await style('body')).toEqual({family:expect.stringMatching(/^"Avenir Next", "PingFang TC"/), size:'15px'});
    expect(await style('#tabDecisions')).toEqual({family:expect.stringMatching(/^"Avenir Next Condensed"/), size:'17px'});
    expect(await style('#card-D-1 h2')).toEqual({family:expect.stringMatching(/^"Avenir Next Condensed"/), size:'33px'});
    expect(await style('#card-D-1 .hero h3')).toEqual({family:expect.stringMatching(/^"Avenir Next Condensed"/), size:'21px'});
    expect(await style('#card-D-1 .pill code')).toEqual({family:expect.stringMatching(/^"SF Mono"/), size:'13px'});
    expect(await style('#card-D-1 .mflag b')).toEqual({family:expect.stringMatching(/^"Avenir Next Condensed"/), size:'21px'});
  } finally { await stopBoard(b); }
});
