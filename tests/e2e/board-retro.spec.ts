// The periodic retrospective on the board (T-273): the "Run retrospective"
// button, a retrospective card whose items each take their own choice, and
// the two refusals the captain can meet, in English, Traditional Chinese and
// the page's converted Simplified Chinese. Text is asserted as dictionary
// values; the Simplified oracle below is authored independently of the
// conversion table, so an incomplete table cannot prove itself.
import { expect } from "@playwright/test";
// `test` is the fixture's: every board a test starts is signed in to (T-122)
import { test, makeRoot, startBoard, stopBoard, ROOT } from "./lib/fixture";
import { EN, TW } from "./lib/board";
import { copyFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const CN_RETRO = {
  retroRun: '执行回顾', retroBusy: '已有回顾在等待或执行中。',
  itemAnswersInvalid: '请依卡片顺序为每个项目选 A、C 或 D。',
  retroApprove: '核准：firstmate 在该项目的专案写任务提案', retroPark: '搁置：带到下次回顾', retroDrop: '舍弃',
};
const LOCALES = [['en', EN], ['zh-TW', TW], ['zh-CN', CN_RETRO]] as const;
const HELPER = join(ROOT, 'bin/lib/fm_retro.py');

// the retro helper lives only in this file's own fixture
function retroRoot() {
  const root = makeRoot(['working'], false);
  if (existsSync(HELPER)) copyFileSync(HELPER, join(root, 'bin/lib/fm_retro.py'));
  return root;
}

function retroCard(root: string, id: string, intent = false) {
  const item = (lang: string, label: string, n: number) => {
    const en = lang === 'en';
    return { id: `${label}/R${n}`, project: label, effect: 'removes', removes: ['tests/old.test.sh'],
      title: en ? `Delete old suite ${n}.` : `刪除舊測試 ${n}。`,
      why: en ? 'Another suite covers the same checks.' : '另一組測試已涵蓋同樣的檢查。',
      how: en ? 'Remove the file.' : '移除檔案。', evidence: ['tests/a.sh:1'], scope: ['tests/old.test.sh'] };
  };
  const loc = (lang: string) => {
    const text = lang === 'en' ? 'The check passes.' : '檢查通過。';
    return { title: lang === 'en' ? 'Retrospective: choose what happens to each item.' : '回顧：逐項決定處理方式。',
      explanation: text, before: text, after: text, outcome: text,
      options: { A: { description: lang === 'en' ? 'Record my choice for each item.' : '逐項記錄我的選擇。', pros: text, cons: text },
                 C: { description: lang === 'en' ? 'Park the whole retrospective.' : '擱置整個回顧。', pros: text, cons: text } },
      items: [item(lang, 'self', 1), item(lang, 'P-0a1b2c3d', 2)] };
  };
  // an intent layout of the same card: the board's second card renderer
  const withIntent = (lang: string) => ({ ...loc(lang),
    intent: [{ text: lang === 'en' ? 'The captain picks per item.' : '船長逐項選擇。', kind: 'fact' }],
    done: [{ text: lang === 'en' ? 'Intent 1: each item has a choice.' : '意圖 1：每個項目都有選擇。', kind: 'fact' }] });
  const details = intent ? { en: withIntent('en'), 'zh-TW': withIntent('zh-TW') } : { en: loc('en'), 'zh-TW': loc('zh-TW') };
  writeFileSync(join(root, `state/pending/${id}.json`), JSON.stringify({
    id, kind: 'choice', purpose: 'retro', details, title: details.en.title, expected_head: '', binding: null }));
}

test("the header's Run retrospective button, and its busy refusal, in three languages", async ({ page }) => {
  test.skip(!existsSync(HELPER), 'SKIP (not evidence): bin/lib/fm_retro.py is absent on this tree');
  test.setTimeout(60_000);
  const b = await startBoard(retroRoot());
  try {
    await page.goto(`${b.url}/?lang=en`);
    const button = page.locator('#retroRun');
    for (const [locale, dict] of LOCALES) {
      await page.locator(`[data-l="${locale}"]`).click();
      await expect(button).toHaveText(dict.retroRun);
    }
    await page.locator('[data-l="en"]').click();
    await button.click();
    await expect(page.locator('#retroSaid')).toHaveText(EN.retroRequested);
    const requests = join(b.root, 'state/retro/requests');
    await expect.poll(() => existsSync(requests)).toBe(true);
    await button.click();
    for (const [locale, dict] of LOCALES) {
      await page.locator(`[data-l="${locale}"]`).click();
      await expect(page.locator('#retroSaid')).toHaveText(dict.retroBusy);
    }
    const wakes = readFileSync(join(b.root, 'state/session/wake.jsonl'), 'utf8').trim().split('\n').map(l => JSON.parse(l));
    expect(wakes.filter(w => w.reason === 'retro_requested')).toHaveLength(1);
  } finally { await stopBoard(b); }
});

test("a retrospective card: A and C only, a choice per item, and the item refusal in three languages", async ({ page }) => {
  test.setTimeout(60_000);
  const root = retroRoot();
  retroCard(root, 'D-1000');
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);
    const card = page.locator('#card-D-1000');
    await expect(card).toBeVisible();
    await expect(card.locator('.decision-bar [data-c]')).toHaveCount(2);
    await expect(card.locator('.decision-bar [data-c="B"]')).toHaveCount(0);
    await expect(card.locator('.decision-bar [data-c="custom"]')).toHaveCount(0);
    const main = card.locator('.retro-items[data-place="card"] .retro-item');
    await expect(main).toHaveCount(2);
    await expect(main.first().locator('[data-item-choice]')).toHaveCount(3);
    await card.locator('.decision-bar [data-c="A"]').click();
    await expect(card.locator('button.confirm')).toBeDisabled();
    for (const [locale, dict] of LOCALES) {
      await page.locator(`[data-l="${locale}"]`).click();
      await expect(page.locator('#card-D-1000 .validation')).toHaveText(dict.itemAnswersInvalid);
      await expect(main.first().locator('[data-item-choice="A"]')).toContainText(dict.retroApprove);
      await expect(main.first().locator('[data-item-choice="C"]')).toContainText(dict.retroPark);
      await expect(main.first().locator('[data-item-choice="D"]')).toContainText(dict.retroDrop);
    }
    await page.locator('[data-l="en"]').click();
    await main.nth(0).locator('[data-item-choice="A"]').click();
    await main.nth(1).locator('[data-item-choice="D"]').click();
    await expect(card.locator('button.confirm')).toBeEnabled();
    await card.locator('button.confirm').click();
    const decision = join(b.root, 'state/decisions/D-1000.json');
    await expect.poll(() => existsSync(decision), { timeout: 15_000 }).toBe(true);
    expect(JSON.parse(readFileSync(decision, 'utf8')).item_answers).toEqual([
      { index: 0, id: 'self/R1', choice: 'A' }, { index: 1, id: 'P-0a1b2c3d/R2', choice: 'D' }]);
  } finally { await stopBoard(b); }
});

// The card's details sheet and its intent layout render the same items with
// the same choices: a choice made in one shows in the other, and the answer
// carries it.
for (const layout of ['card', 'intent'] as const) {
  test(`a retrospective card's details sheet shares the ${layout} layout's item choices and answer`, async ({ page }) => {
    test.setTimeout(60_000);
    const root = retroRoot();
    retroCard(root, 'D-1000', layout === 'intent');
    const b = await startBoard(root);
    try {
      await page.goto(`${b.url}/?lang=en`);
      const card = page.locator('#card-D-1000');
      const main = card.locator(`.retro-items[data-place="${layout}"] .retro-item`);
      await expect(main).toHaveCount(2);
      await expect(card.locator('.decision-bar [data-c]')).toHaveCount(2);
      await expect(card.locator('.decision-bar [data-c="custom"]')).toHaveCount(0);
      await main.nth(0).locator('[data-item-choice="C"]').click();
      await card.locator('[data-decision-details]').click();
      const sheet = page.locator('#sheet-D-1000');
      await expect(sheet).toBeVisible();
      const listed = sheet.locator('.retro-items[data-place="sheet"] .retro-item');
      await expect(listed).toHaveCount(2);
      await expect(listed.nth(0)).toContainText('Delete old suite 1.');
      await expect(listed.nth(0).locator('[data-item-choice="C"]')).toHaveAttribute('aria-pressed', 'true');
      await listed.nth(1).locator('[data-item-choice="A"]').click();
      await expect(page.locator('#sheet-D-1000 .retro-items[data-place="sheet"] .retro-item').nth(1)
        .locator('[data-item-choice="A"]')).toHaveAttribute('aria-pressed', 'true');
      await page.locator('#sheet-D-1000 [data-decision-close]').click();
      await expect(card.locator(`.retro-items[data-place="${layout}"] .retro-item`).nth(1)
        .locator('[data-item-choice="A"]')).toHaveAttribute('aria-pressed', 'true');
      await card.locator('.decision-bar [data-c="A"]').click();
      await expect(card.locator('button.confirm')).toBeEnabled();
      await card.locator('button.confirm').click();
      const decision = join(b.root, 'state/decisions/D-1000.json');
      await expect.poll(() => existsSync(decision), { timeout: 15_000 }).toBe(true);
      expect(JSON.parse(readFileSync(decision, 'utf8')).item_answers).toEqual([
        { index: 0, id: 'self/R1', choice: 'C' }, { index: 1, id: 'P-0a1b2c3d/R2', choice: 'A' }]);
    } finally { await stopBoard(b); }
  });
}
