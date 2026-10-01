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
const { board, open } = useBoard();
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
    // every crewman says who he is over his own head, and what he is on in
    // the card that head holds (T-116)
    await expect(page.locator(".scene .bub")).toHaveCount(CREW.length + 1);
    await expect(page.locator(".scene .bub:not(.mini) .job").first()).not.toBeEmpty();
    // the full bubbles name the agent; the chips below them name him too,
    // and the work is in each card and the roster (T-116)
    const named = await page.locator(".scene .bub:not(.mini) .who").allInnerTexts();
    const listed = await page.locator(".roster .nm").allInnerTexts();
    for (const n of named) expect(listed).toContain(n);
    // and the roster is named after the agents, not after the tasks
    const agents = listed.filter((n) => /^(worker|reviewer)-\d+$/.test(n));
    expect(agents.length).toBe(CREW.length);
    const jobs = await page.locator(".roster .jb").allInnerTexts();
    expect(jobs.some((j) => /^(T|SK)-[0-9]{3,}/.test(j))).toBe(true);
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

// Gate 3 is retired (T-114). A gate_failed naming it names no gate the board
// knows, so the badge carries no number; one naming gate 4 keeps its number.
test("a failed-gate badge numbers only a gate that exists: 3 is retired, 4 is kept", async ({ page }) => {
  const root = makeRoot([], false);
  const [three, four] = readTasks(root);
  emitFixture(root, 'worker-1', three.id, 'gate_failed', 'Gate three failed', '第三道閘未過', { gate: 3 });
  emitFixture(root, 'worker-2', four.id, 'gate_failed', 'Gate four failed', '第四道閘未過', { gate: 4 });
  const b = await startBoard(root);
  try {
    const state = await (await fetch(b.url + '/api/state')).json();
    const gateBadge = (id: string) =>
      state.tasks.find((t: any) => t.id === id).badges.filter((x: any) => x.kind === 'gate');
    expect(gateBadge(three.id)).toEqual([{ kind: 'gate', gate: null }]);
    expect(gateBadge(four.id)).toEqual([{ kind: 'gate', gate: 4 }]);
    await page.goto(`${b.url}/?lang=en`);
    await expect(page.locator(`[data-task="${three.id}"] .badge`)).toHaveText(EN.gateFailed);
    await expect(page.locator(`[data-task="${four.id}"] .badge`)).toHaveText(EN.gateFailedN.replace('{n}', '4'));
  } finally { stopBoard(b); }
});


// T-154: real HTTP listener, credential port and browser preference precedence.
for (const language of ['en', 'zh-TW']) {
  test(`configured port and ${language} default reach cards; viewer toggle persists`, async ({page}) => {
    const root = makeRoot(['working']);
    writeFileSync(join(root, 'config.yaml'), `language: ${language}\n`);
    const other = language === 'en' ? 'zh-TW' : 'en';
    const cardPath = join(root, 'state/pending/D-1.json');
    const card = JSON.parse(readFileSync(cardPath, 'utf8'));
    // Deliberately opposite to the setting, so both cases require reordering.
    card.details = { [other]: details[other], [language]: details[language], effect: { C: 'park' } };
    writeFileSync(cardPath, JSON.stringify(card));
    const b = await startBoard(root, {}, true);
    try {
      await page.goto(b.url);
      await expect(page.locator('html')).toHaveAttribute('lang', language);
      await expect(page.locator('.dcard').first()).toContainText(details[language].title);
      await expect(page.locator('#langs button').first()).toHaveAttribute('data-l', language);
      const state = await (await page.request.get(`${b.url}/api/state`)).json();
      expect(Object.keys(state.pending[0].details).filter(k => ['en', 'zh-TW'].includes(k)))
        .toEqual([language, other]);
      expect(state.pending[0].details[language]).toEqual(details[language]);
      expect(state.pending[0].details[other]).toEqual(details[other]);
      expect(state.pending[0].details.effect).toEqual({ C: 'park' });
      expect(JSON.parse(readFileSync(cardPath, 'utf8'))).toEqual(card);
      await page.locator(`#langs [data-l="${other}"]`).click();
      await page.reload();
      await expect(page.locator('html')).toHaveAttribute('lang', other);
      await expect(page.locator('.dcard').first()).toContainText(details[other].title);
    } finally { stopBoard(b); }
  });
}
test('FM_PORT overrides a configured board port', async ({page}) => {
  const root = makeRoot(['working']);
  writeFileSync(join(root, 'config.yaml'), 'board:\n  port: 1\n');
  const b = await startBoard(root);
  try {
    await page.goto(b.url);
    await expect(page.locator('html')).toHaveAttribute('lang', 'en');
  } finally { stopBoard(b); }
});

test('a fixture without the config reader still honours FM_PORT and defaults to English', async ({page}) => {
  const root = makeRoot(['working']);
  unlinkSync(join(root, 'bin/fm-config.sh'));
  writeFileSync(join(root, 'config.yaml'), 'board:\n  port: 1\nlanguage: zh-TW\n');
  const b = await startBoard(root);
  try {
    await page.goto(b.url);
    await expect(page.locator('html')).toHaveAttribute('lang', 'en');
    await expect(page.locator('.dcard').first()).toContainText(details.en.title);
  } finally { stopBoard(b); }
});
