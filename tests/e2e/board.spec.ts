// The board, in a browser. Poses are asserted as classes and text as
// dictionary values, never as screenshots: a snapshot test of a ship that
// moves would fail on the animation and pass on the wrong crew.
import { test, expect, type Page } from "@playwright/test";
import { makeRoot, startBoard, stopBoard, ROOT } from "./fixture";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const EN = JSON.parse(readFileSync(join(ROOT, "i18n/ui.en.json"), "utf8"));
const TW = JSON.parse(readFileSync(join(ROOT, "i18n/ui.zh-TW.json"), "utf8"));
const CREW = ["working", "gate", "review", "working", "gate"] as const;

let board: Awaited<ReturnType<typeof startBoard>>;
test.beforeAll(async () => { board = await startBoard(makeRoot([...CREW])); });
test.afterAll(() => stopBoard(board));

const open = async (page: Page, lang: string) => {
  await page.goto(`${board.url}/?lang=${lang}`);
  await page.evaluate((l) => localStorage.setItem("board.lang", l), lang);
  await page.reload();
  await expect(page.locator(".scene .pivot").first()).toBeVisible();
};

// --- snapshots: all three languages -------------------------------------
for (const lang of ["en", "zh-TW", "zh-CN"]) {
  test(`the board reads in ${lang}`, async ({ page }) => {
    await open(page, lang);

    // the crew is the state, not a decoration: firstmate, five tasks, captain
    await expect(page.locator(".scene .pivot")).toHaveCount(CREW.length + 2);
    await expect(page.locator(".roster li")).toHaveCount(CREW.length + 2);
    for (const s of new Set(CREW)) {
      await expect(page.locator(`.scene .fig.s-${s}`).first()).toBeVisible();
    }
    await expect(page.locator(".scene .fig.r-cap")).toHaveCount(1);
    // every crewman says who he is and what he is on, over his own head
    await expect(page.locator(".scene .bub")).toHaveCount(CREW.length + 2);
    await expect(page.locator(".scene .bub:not(.mini) .job").first()).not.toBeEmpty();
    const named = await page.locator(".scene .bub .who").allInnerTexts();
    const listed = await page.locator(".roster .nm").allInnerTexts();
    expect(named.sort()).toEqual(listed.sort());
    await expect(page.locator(".scene .port").first()).toBeVisible();
    await expect(page.locator(".scene .mast .sail").first()).toBeVisible();

    // t() falls back to the key itself, so the way to catch an unresolved
    // key is to read the label and compare it with the dictionary. A
    // substring scan would not do: "log" is inside plenty of honest text.
    const want = (k: string) =>
      lang === "en" ? EN[k] : lang === "zh-TW" ? TW[k] : null;
    const labels = await page.locator(".counts span").allInnerTexts();
    for (const [i, k] of ["merged", "inflight", "blocked", "queued"].entries()) {
      const w = want(k);
      // the stylesheet upper-cases these, so compare the words not the case
      const got = labels[i].toLowerCase();
      if (w) expect(got).toBe(w.toLowerCase());
      else { expect(got).not.toBe(k.toLowerCase()); expect(got).not.toBe(EN[k].toLowerCase()); }
    }
    const aboard = await page.locator(".shipbar span").nth(1).innerText();
    expect(aboard).toContain(lang === "zh-CN" ? "" : (want("aboard") as string));
    expect(aboard).toContain(`${CREW.length + 2}/24`);

    // and the language is the one that was asked for
    const roster = await page.locator(".roster h3 span").first().innerText();
    if (lang === "en") expect(roster).toBe(EN.roster);
    if (lang === "zh-TW") expect(roster).toBe(TW.roster);
    if (lang === "zh-CN") {
      expect(roster).not.toBe(TW.roster);          // it was converted
      expect(roster).not.toBe(EN.roster);          // and not to English
    }
    expect(await page.evaluate(() => document.documentElement.lang)).toBe(lang);
  });
}

// --- interaction: zh-TW only --------------------------------------------
// its own board: answering a decision removes the captain from the crew, and
// a later test that counts the crew would then be reading this test's work
test("the captain merges from the board", async ({ page }) => {
  const b = await startBoard(makeRoot([...CREW]));
  try {
  await page.goto(`${b.url}/?lang=zh-TW`);
  await expect(page.locator(".scene .pivot").first()).toBeVisible();
  const card = page.locator(".dcard").first();
  await expect(card).toBeVisible();
  await expect(card.locator(".gates li")).toHaveCount(7);
  await expect(card.locator(".gates li.n")).toHaveCount(1);   // gate seven open

  await card.locator("button.go").click();

  // the card going away is the visible half; the decision on disk and the
  // call to the one script allowed to merge are the half that matters. The
  // reply text is not asserted: the board re-renders as soon as it lands,
  // so a passing test would be racing the repaint.
  await expect(page.locator(".dcard")).toHaveCount(0, { timeout: 10_000 });
  const decision = join(b.root, "state/decisions/D-1.json");
  await expect.poll(() => existsSync(decision), { timeout: 5_000 }).toBe(true);
  expect(JSON.parse(readFileSync(decision, "utf8")).chosen).toBe("A");
  expect(readFileSync(b.recorder, "utf8")).toContain("--pr 99");
  expect(existsSync(join(b.root, "state/pending/D-1.json"))).toBe(false);
  } finally { stopBoard(b); }
});

test("a crewman turns under the pointer, and the ahoy fires", async ({ page }) => {
  await open(page, "zh-TW");
  const crew = page.locator(".scene .pivot").first();
  await crew.scrollIntoViewIfNeeded();
  const before = await crew.evaluate((el) => el.style.getPropertyValue("--ry"));
  const box = (await crew.boundingBox())!;
  // low on the figure: a bubble sits above the head and would take the press
  const y = box.y + box.height * 0.82;
  await page.mouse.move(box.x + box.width / 2, y);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width / 2 + 90, y, { steps: 6 });
  await page.mouse.up();
  const after = await crew.evaluate((el) => el.style.getPropertyValue("--ry"));
  expect(after).not.toBe(before);
  expect(parseFloat(after)).toBeGreaterThan(parseFloat(before || "-26"));

  await page.locator("#ahoyBtn").click();
  await expect(page.locator("#vessel")).toHaveClass(/heel/);
  await expect(page.locator("#salvo")).toHaveClass(/fire/);
  await expect(page.locator(".scene .fig.cheer").first()).toBeVisible();
});

test("nothing here can reach a model", async () => {
  // structural, not a promise: the fixture root has no adapters in it, so
  // there is nothing for the board to shell out to even if it tried. The
  // only script it may spawn is the merge recorder, and that is the whole
  // contents of its bin/.
  const { readdirSync } = await import("node:fs");
  expect(existsSync(join(board.root, "bin/adapters"))).toBe(false);
  expect(readdirSync(join(board.root, "bin"))).toEqual(["fm-merge.sh"]);
});

test("the ship grows with the crew", async ({ page }) => {
  await open(page, "en");
  const small = await page.locator(".scene").getAttribute("data-rate");
  const crewNow = Number(await page.locator(".scene").getAttribute("data-crew"));
  expect(crewNow).toBe(CREW.length + 2);
  const big = await startBoard(makeRoot(Array(20).fill("working"), false));
  try {
    await page.goto(`${big.url}/?lang=en`);
    await expect(page.locator(".scene .pivot").first()).toBeVisible();
    expect(await page.locator(".scene").getAttribute("data-rate")).not.toBe(small);
    expect(Number(await page.locator(".scene").getAttribute("data-crew"))).toBe(21);
    // the whole sail still clears the tallest head
    const clear = await page.evaluate(() => {
      const top = [...document.querySelectorAll<HTMLElement>(".scene .pivot")]
        .reduce((m, p) => Math.min(m, p.getBoundingClientRect().top), Infinity);
      const sail = [...document.querySelectorAll<HTMLElement>(".scene .sail")]
        .reduce((m, s) => Math.max(m, s.getBoundingClientRect().bottom), -Infinity);
      return sail < top;
    });
    expect(clear).toBe(true);
  } finally { stopBoard(big); }
});
