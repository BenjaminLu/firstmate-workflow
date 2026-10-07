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
test("the captain merges from the board", async ({ page }) => {
  // its own budget: this one starts a board inside the body, so the global
  // timeout has to cover the start as well as the assertions, and the
  // per-assertion timeouts below are dead letters without it
  test.setTimeout(60_000);
  const b = await startBoard(makeRoot([...CREW]));
  try {
  await page.goto(`${b.url}/?lang=zh-TW`);
  await expect(page.locator("#roster .rrow").first()).toBeVisible();
  const card = page.locator(".dcard").first();
  await expect(card).toBeVisible();
  await expect(card.locator(".gates li")).toHaveCount(6);   // six named gates
  await expect(card.locator(".gates li.n")).toHaveCount(1);   // gate 6 open

  await expect(card.locator("button.confirm")).toBeDisabled();
  await card.locator('[data-c="A"]').click();
  expect(existsSync(join(b.root, "state/decisions/D-1.json"))).toBe(false);
  await expect(page.locator('#capstage')).toHaveAttribute('data-pose', 'ready');
  await expect(page.locator('#capstage .lbl span')).toHaveText(TW.capReady);
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
  } finally { await stopBoard(b); }
});

test("custom selection is local, literal and never merges", async ({ page }) => {
  const root = makeRoot(["working"]);
  writeFileSync(join(root,'state/pending/D-2.json'), JSON.stringify({id:'D-2',kind:'choice',details}));
  const b = await startBoard(root);
  try {
    let posts = 0;
    // the fixture's one-time sign-in POSTs /login on the first visit; that
    // exchange answers nothing, so only every other POST counts
    page.on('request', r => { if (r.method() === 'POST' && new URL(r.url()).pathname !== '/login') posts++; });
    await page.goto(`${b.url}/?lang=en`);
    const card = page.locator('#card-D-1');
    await expect(page.locator('#capstage')).toHaveAttribute('data-pose', 'idle');
    await expect(page.locator('#capstage .capimg')).toHaveCSS('filter','none');
    await card.locator('[data-c="custom"]').click();
    await expect(page.locator('#capstage')).toHaveAttribute('data-pose', 'ready');
    await expect(page.locator('#capstage .capimg')).toHaveCSS('filter', /drop-shadow/);
    await expect(page.locator('#capstage .lbl span')).toHaveText(EN.capReady);
    await expect(card.locator('.confirm')).toBeDisabled();
    await card.locator('textarea').fill('🚢'.repeat(1001));
    await expect(card.locator('.confirm')).toBeDisabled();
    const literal = '  保留 🚢 <script>bad()</script> $(touch nope)  ';
    await card.locator('textarea').fill(literal);
    expect(posts).toBe(0);
    expect(existsSync(join(b.root, 'state/decisions/D-1.json'))).toBe(false);
    await card.locator('.confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText('AYE, CAPTAIN!');
    await expect(page.locator('#capstage')).toBeVisible();
    await expect(page.locator('#capstage')).toHaveAttribute('data-pose', 'order');
    await expect(page.locator('#capstage .capimg')).toHaveCSS('filter', /drop-shadow/);
    await expect(page.locator('#capstage .capimg')).toHaveCSS('transform', 'matrix(1, 0, 0, 1, 0, -6)');
    await expect(page.locator('#capstage .lbl span')).toHaveText(EN.capOrder);
    const stored = JSON.parse(readFileSync(join(b.root, 'state/decisions/D-1.json'), 'utf8'));
    expect(stored.chosen).toBe('custom');
    expect(stored.text).toBe(literal);
    expect(posts).toBe(1);
    expect(existsSync(b.recorder)).toBe(false);
    await page.locator('[data-l="zh-CN"]').click();
    await expect(page.locator('#orderFeedback')).toContainText(literal);
    await expect(page.locator('#orderFeedback script')).toHaveCount(0);
    await expect(page.locator('#capstage')).toHaveAttribute('data-pose','idle',{timeout:15_000});
    await expect(page.locator('#capstage .capimg')).toHaveCSS('filter','none');
    await expect(page.locator('#capstage .capimg')).toHaveCSS('transform','none');
    await expect(page.locator('#capstage .lbl span')).toHaveText(CN.capDeciding);
  } finally { await stopBoard(b); }
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
  } finally {await stopBoard(b);}
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
  } finally {await stopBoard(b);}
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
  } finally {await stopBoard(b);}
});


test('decision kind badges lead every card and strip in both locales with readable colours', async ({page}) => {
  const root = makeRoot(['working'], false);
  const cards = [
    {id:'D-2271', kind:'merge'},
    {id:'D-2272', kind:'choice', purpose:'dispatch'},
    {id:'D-2273', kind:'choice', title:'Repin T-227'},
    {id:'D-2274', kind:'choice', title:'A plain choice'},
  ];
  for (const card of cards) writeFileSync(join(root, `state/pending/${card.id}.json`), JSON.stringify(card));
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    const kinds = ['merge', 'dispatch', 'repin', 'decision'];
    for (const [lang, labels] of [['en', ['Merge','Dispatch','Repin','Decision']], ['zh-TW', ['合併','派工','重新固定','決定']]] as const) {
      await page.locator(`[data-l="${lang}"]`).click();
      for (let i = 0; i < cards.length; i++) {
        const meta = page.locator(`#card-${cards[i].id} > .meta`);
        await expect(meta.locator('.kbadge')).toHaveCount(1);
        await expect(meta.locator(':scope > :first-child')).toHaveClass(`kbadge k-${kinds[i]}`);
        await expect(meta.locator('.kbadge')).toHaveText(labels[i]);
        if (i) {
          const summary = page.locator(`#strip-${cards[i].id} > summary`);
          await expect(summary.locator('.kbadge')).toHaveCount(1);
          await expect(summary.locator(':scope > :first-child')).toHaveClass(`kbadge k-${kinds[i]}`);
          await expect(summary.locator('.kbadge')).toHaveText(labels[i]);
        }
      }
      const colours = await page.locator('#deck .kbadge').evaluateAll(badges => badges.map(badge => {
        const style = getComputedStyle(badge);
        const luminance = (colour: string) => {
          const rgb = colour.match(/[\d.]+/g)!.slice(0,3).map(Number).map(v => {
            v /= 255; return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
          });
          return rgb[0]*0.2126 + rgb[1]*0.7152 + rgb[2]*0.0722;
        };
        const a = luminance(style.color), b = luminance(style.backgroundColor);
        return {background:style.backgroundColor, contrast:(Math.max(a,b)+0.05)/(Math.min(a,b)+0.05)};
      }));
      expect(colours[0].background).not.toBe(colours[1].background);
      for (const colour of colours) expect(colour.contrast).toBeGreaterThanOrEqual(4.5);
    }
    // Cover the remaining tokens and classification precedence without rewriting stored cards.
    const cases = [
      [{kind:'merge-untracked',purpose:'dispatch'}, 'merge'],
      [{kind:'choice',purpose:'scope',title:'Dispatch T-227'}, 'scope'],
      [{kind:'choice',purpose:'skill'}, 'skill'],
      [{kind:'choice',purpose:'decision',id:'D-SK-227'}, 'decision'],
      [{kind:'choice',id:'D-SK-227'}, 'skill'],
      ...[['Dispatch T-227','dispatch'],['Repin T-227','repin'],['Scope widening','scope'],['Skill update worker','skill'],
        ['派工 T-227','dispatch'],['重新固定 T-227','repin'],['範圍 T-227','scope'],['技能 worker','skill']].map(([title,kind]) => [{title},kind]),
      [{purpose:'unknown',title:'Other'}, 'decision'],
    ];
    for (const [card, expected] of cases) {
      expect(await page.evaluate(d => (window as any).cardKind(d), card)).toBe(expected);
    }
    // All six badge fills must stay legible, including scope and skill.
    for (const kind of ['scope','skill']) {
      await page.evaluate(kind => {
        const badge = document.querySelector('#deck .kbadge')!;
        badge.className = `kbadge k-${kind}`;
      }, kind);
      const ratio = await page.locator('#deck .kbadge').first().evaluate(el => {
        const s = getComputedStyle(el);
        const lum = (c: string) => c.match(/[\d.]+/g)!.slice(0,3).map(Number).map(v => v/255).map(v => v <= .04045 ? v/12.92 : ((v+.055)/1.055)**2.4).reduce((sum,v,i) => sum+v*[.2126,.7152,.0722][i],0);
        const a=lum(s.color), b=lum(s.backgroundColor);
        return (Math.max(a,b)+.05)/(Math.min(a,b)+.05);
      });
      expect(ratio).toBeGreaterThanOrEqual(4.5);
    }
  } finally { await stopBoard(b); }
});

for (const legacy of [false, true]) test(`named checklist reads ${legacy ? 'legacy' : 'new'} card`, async ({page}) => {
  const root = makeRoot([...CREW]);
  const file = join(root, 'state/pending/D-1.json');
  const card = JSON.parse(readFileSync(file, 'utf8'));
  card.gates = legacy ? [true,true,null,true,true,true,true] : {branch:true,rebase:true,scope:true,'fail-first':true,ci:true,approval:true}; // legacy-gates (T-232)
  writeFileSync(file, JSON.stringify(card));
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    const lines = page.locator('#card-D-1 .gates li');
    await expect(lines).toHaveCount(6);
    for (const [i,name] of ['branch','rebase','scope','fail-first','ci','approval'].entries()) {
      await expect(lines.nth(i)).toContainText(`${i+1}. ${EN['gate_'+name]}`);
      await expect(lines.nth(i)).toHaveClass('y');
    }
  } finally { await stopBoard(b); }
});


test('not-runnable fail-first warns in both languages and leaves merge available', async ({ page }) => {
  const root = makeRoot(['working']);
  const path = join(root, 'state/pending/D-1.json');
  const cardData = JSON.parse(readFileSync(path, 'utf8'));
  const reason = 'Missing test credentials $& <script>unsafe()</script>';
  cardData.gates = {branch:true, rebase:true, scope:true, 'fail-first':'not_runnable', ci:true, approval:true};
  cardData.not_runnable = {'fail-first':reason};
  writeFileSync(path, JSON.stringify(cardData));
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    for (const [lang, dict] of [['en', EN], ['zh-TW', TW]] as const) {
      await page.locator(`[data-l="${lang}"]`).click();
      const card = page.locator('#card-D-1');
      await expect(card.locator('.gates li.w')).toHaveCount(1);
      await expect(card.locator('.gates li.w')).toContainText(dict.gateNotRunnable.replace('{reason}', () => reason));
      await expect(card).toContainText(dict.ciOnlyEvidence);
      await expect(card.locator('script')).toHaveCount(0);
      await expect(card.locator('[data-c="A"]')).toBeEnabled();
      await card.locator('[data-c="A"]').click();
      await expect(card.locator('button.confirm')).toBeEnabled();
    }
  } finally { await stopBoard(b); }
});
