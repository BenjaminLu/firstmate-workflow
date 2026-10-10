// T-270: why, how and the glossary on every card shape that has them.
// Expectations in zh-CN are written by hand, independent of the table under
// test; a table with overlapping rows shows the board and bin/lib/fm_plain.py
// convert the same way.
import { expect, type Locator } from '@playwright/test';
import { test, makeRoot, startBoard, stopBoard, details, ROOT } from './lib/fixture';
import { intentCard, changePointCard } from './lib/intent-card';
import { writeFileSync, appendFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';

const PLAIN = {
  en: {
    why: [{kind:'fact', text:'The captain needs the reason.'}],
    how: [{kind:'fact', text:'The board lists each term.'}],
    glossary: [{id:'board', term:'board', text:'The board is the web page where the captain reads and answers cards.'}],
  },
  'zh-TW': {
    why: [{kind:'fact', text:'船長需要船員名冊與船員的原因。'}],
    how: [{kind:'fact', text:'看板列出每個詞彙。'}],
    glossary: [{id:'board', term:'看板', text:'看板是船長閱讀並回答決策卡的網頁。'}],
  },
};
const WANT = {
  en: {labels: ['Why', 'How', 'Glossary'], why: 'The captain needs the reason.', how: 'The board lists each term.',
       term: 'board', text: 'The board is the web page where the captain reads and answers cards.'},
  'zh-TW': {labels: ['原因', '做法', '詞彙表'], why: '船長需要船員名冊與船員的原因。', how: '看板列出每個詞彙。',
            term: '看板', text: '看板是船長閱讀並回答決策卡的網頁。'},
  'zh-CN': {labels: ['原因', '做法', '词汇表'], why: '船长需要船员名册与船员的原因。', how: '看板列出每个词汇。',
            term: '看板', text: '看板是船长阅读并回答决策卡的网页。'},
};

function plainCard(id = 'D-270') {
  const content: any = structuredClone(details);
  for (const lang of ['en', 'zh-TW'] as const) Object.assign(content[lang], structuredClone(PLAIN[lang]));
  return {id, kind:'choice', task:'T-270', details:content};
}

// The plain block sits directly in the card, the sheet or the intent column.
async function expectPlain(scope: Locator, lang: keyof typeof WANT) {
  const want = WANT[lang];
  await expect(scope.locator(':scope > .plain-why-how h4, :scope > .card-glossary h4')).toHaveText(want.labels);
  await expect(scope.locator(':scope > .plain-why-how .plain-why li')).toHaveText([want.why]);
  await expect(scope.locator(':scope > .plain-why-how .plain-how li')).toHaveText([want.how]);
  await expect(scope.locator(':scope > .card-glossary dt')).toHaveText([want.term]);
  await expect(scope.locator(':scope > .card-glossary dd')).toHaveText([want.text]);
}

test('a non-intent card shows why, how and glossary in three languages', async ({page}) => {
  const root = makeRoot([], false);
  // Overlapping rows: the longer term must come first in file order.
  appendFileSync(join(root, 'i18n/tw2cn.tsv'), '\n船員名冊\t船员名册\n船員\t船员\n');
  writeFileSync(join(root, 'state/pending/D-270.json'), JSON.stringify(plainCard()));
  const b = await startBoard(root);
  try {
    for (const lang of ['en', 'zh-TW', 'zh-CN'] as const) {
      await page.goto(`${b.url}/?lang=${lang}`);
      const card = page.locator('#card-D-270');
      // the main card: one plain block, outside the decision sheet
      await expectPlain(card, lang);
      // the decision sheet repeats it for the captain who opens the details
      await card.locator('[data-decision-details]').click();
      await expectPlain(card.locator('.decision-sheet'), lang);
    }
    // bin/lib/fm_plain.py converts with the same table to the same text
    const python = spawnSync('python3', ['-c', [
      'import sys', `sys.path.insert(0, ${JSON.stringify(join(ROOT, 'bin/lib'))})`, 'import fm_plain',
      `print(fm_plain.to_cn(sys.argv[1], fm_plain.tw2cn_rows(${JSON.stringify(root)})), end="")`].join('\n'),
      PLAIN['zh-TW'].why[0].text], {encoding: 'utf8'});
    expect(python.status, python.stderr).toBe(0);
    expect(python.stdout).toBe(WANT['zh-CN'].why);
  } finally { await stopBoard(b); }
});

test('the enriched walk card shows why, how and glossary', async ({page}) => {
  const root = makeRoot([], false), d: any = changePointCard('two-way');
  for (const lang of ['en', 'zh-TW'] as const) Object.assign(d.details[lang], structuredClone(PLAIN[lang]));
  writeFileSync(join(root, 'state/pending/D-9242.json'), JSON.stringify(d));
  const b = await startBoard(root);
  try {
    for (const lang of ['en', 'zh-TW', 'zh-CN'] as const) {
      await page.goto(`${b.url}/?lang=${lang}`);
      const card = page.locator('#card-D-9242');
      await expect(card.locator('.change-walk')).toHaveCount(1);
      await expectPlain(card.locator('.intent-alignment').first(), lang);
    }
  } finally { await stopBoard(b); }
});

test('an older card without how or glossary renders as before', async ({page}) => {
  const root = makeRoot([], false);
  writeFileSync(join(root, 'state/pending/D-211.json'), JSON.stringify(intentCard()));
  writeFileSync(join(root, 'state/pending/D-212.json'), JSON.stringify({id:'D-212', kind:'choice', details}));
  const b = await startBoard(root);
  try {
    for (const lang of ['en', 'zh-TW', 'zh-CN'] as const) {
      await page.goto(`${b.url}/?lang=${lang}`);
      await expect(page.locator('#card-D-211, #card-D-212')).toHaveCount(2);
      await expect(page.locator('.plain-why-how, .card-glossary')).toHaveCount(0);
      // the older intent card keeps its why where it always was
      await expect(page.locator('#card-D-211 .why-disclosure .intent-why')).toHaveCount(1);
    }
  } finally { await stopBoard(b); }
});
