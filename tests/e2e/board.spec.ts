// The board, in a browser. Poses are asserted as classes and text as
// dictionary values, never as screenshots: a snapshot test of a ship that
// moves would fail on the animation and pass on the wrong crew.
import { test, expect, type Page } from "@playwright/test";
import { makeRoot, startBoard, stopBoard, ROOT } from "./fixture";
import { appendFileSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const EN = JSON.parse(readFileSync(join(ROOT, "i18n/ui.en.json"), "utf8"));
const TW = JSON.parse(readFileSync(join(ROOT, "i18n/ui.zh-TW.json"), "utf8"));
// zh-CN is derived, so the expectation is derived too - the same table the
// board applies, applied here. Asserting only "not the traditional one"
// passes for a converter that emits anything at all.
const TABLE = readFileSync(join(ROOT, "i18n/tw2cn.tsv"), "utf8")
  .split("\n").filter((l) => l && !l.startsWith("#"))
  .map((l) => l.split("\t")) as [string, string][];
const cn = (x: string) => TABLE.reduce((a, [tw, zh]) => a.split(tw).join(zh), x);
const CN: Record<string, string> = Object.fromEntries(
  Object.entries(TW).map(([k, v]) => [k, cn(v as string)]));
const CREW = ["working", "gate", "review", "working", "gate"] as const;

let board: Awaited<ReturnType<typeof startBoard>>;
test.beforeAll(async () => { board = await startBoard(makeRoot([...CREW])); });
test.afterAll(() => stopBoard(board));

// one mechanism at a time. Setting both meant neither was covered: the
// query parameter could have stopped working and the suite would have
// stayed green on the stored value.
const open = async (page: Page, lang: string, how: "query" | "stored" = "query") => {
  if (how === "query") {
    await page.goto(`${board.url}/?lang=${lang}`);
    await page.evaluate(() => localStorage.removeItem("board.lang"));
    await page.reload();
  } else {
    await page.goto(board.url);
    await page.evaluate((l) => localStorage.setItem("board.lang", l), lang);
    await page.goto(board.url);           // no query parameter this time
  }
  await expect(page.locator(".scene .pivot").first()).toBeVisible();
};

// --- snapshots: all three languages -------------------------------------
for (const lang of ["en", "zh-TW", "zh-CN"]) {
  test(`the board reads in ${lang}`, async ({ page }) => {
    await open(page, lang);

    // the crew are agents: firstmate, one per working agent, the captain
    await expect(page.locator(".scene .pivot")).toHaveCount(CREW.length + 1);
    await expect(page.locator(".roster li")).toHaveCount(CREW.length + 1);
    for (const s of new Set(CREW)) {
      await expect(page.locator(`.scene .fig.s-${s}`).first()).toBeVisible();
    }
    // the captain is NOT on the deck: the crew are agents doing work and
    // he is the person they are waiting on
    await expect(page.locator(".scene .fig.r-cap")).toHaveCount(0);
    await expect(page.locator("#captain .fig.r-cap")).toHaveCount(1);
    // the badge counts the cards, rather than being pinned to the one
    // this fixture happens to have
    const cards = await page.locator(".dcard").count();
    await expect(page.locator("#captain .capsays i")).toHaveText(String(cards));
    expect(cards).toBeGreaterThan(0);
    // every crewman says who he is and what he is on, over his own head
    await expect(page.locator(".scene .bub")).toHaveCount(CREW.length + 1);
    await expect(page.locator(".scene .bub:not(.mini) .job").first()).not.toBeEmpty();
    // the full bubbles name the agent; the chips below them name the
    // task, because a chip with only a name says nothing about the work
    const named = await page.locator(".scene .bub:not(.mini) .who").allInnerTexts();
    const listed = await page.locator(".roster .nm").allInnerTexts();
    for (const n of named) expect(listed).toContain(n);
    // and the roster is named after the agents, not after the tasks
    const agents = listed.filter((n) => /^(worker|reviewer)-\d+$/.test(n));
    expect(agents.length).toBe(CREW.length);
    const jobs = await page.locator(".roster .jb").allInnerTexts();
    expect(jobs.some((j) => /^T-\d+/.test(j))).toBe(true);
    await expect(page.locator(".scene .port").first()).toBeVisible();
    await expect(page.locator(".scene .mast .sail").first()).toBeVisible();

    // t() falls back to the key itself, so the way to catch an unresolved
    // key is to read the label and compare it with the dictionary. A
    // substring scan would not do: "log" is inside plenty of honest text.
    const want = (k: string) => (lang === "en" ? EN : lang === "zh-TW" ? TW : CN)[k];
    const labels = await page.locator(".counts span").allInnerTexts();
    for (const [i, k] of ["merged", "inflight", "blocked", "queued"].entries()) {
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

test("the captain merges from the board", async ({ page }) => {
  // its own budget: this one starts a board inside the body, so the global
  // timeout has to cover the start as well as the assertions, and the
  // per-assertion timeouts below are dead letters without it
  test.setTimeout(60_000);
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
  // all three side-effects land asynchronously; polling one and reading the
  // others is a race, and the recorder read throws ENOENT rather than
  // failing an assertion when it loses
  await expect.poll(() => existsSync(decision), { timeout: 10_000 }).toBe(true);
  await expect.poll(() => (existsSync(b.recorder) ? readFileSync(b.recorder, "utf8") : ""),
    { timeout: 10_000 }).toContain("--pr 99");
  await expect.poll(() => existsSync(join(b.root, "state/pending/D-1.json")),
    { timeout: 10_000 }).toBe(false);
  expect(JSON.parse(readFileSync(decision, "utf8")).chosen).toBe("A");
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

test("no cards, no captain", async ({ page }) => {
  test.setTimeout(60_000);
  // Driven by the state the page reads, not by calling into the page:
  // render() runs again on the board's own refresh and would put him
  // straight back, so a hand call passes or flakes depending on the tick.
  const quiet = await startBoard(makeRoot(["working"], false));
  try {
    await page.goto(`${quiet.url}/?lang=en`);
    await expect(page.locator(".scene .pivot").first()).toBeVisible();
    await expect(page.locator(".dcard")).toHaveCount(0);
    await expect(page.locator("#captain .fig.r-cap")).toHaveCount(0);
    // his OWN decision, not his ancestor's: #captain sits inside
    // #deckwrap, which the page hides whenever there are no cards, so
    // toBeHidden() here is true whatever SHIP.captain did with him.
    await expect(page.locator("#captain")).toHaveAttribute("hidden", "");
  } finally { stopBoard(quiet); }
});

test("the captain keeps his own block on a phone", async ({ page }) => {
  test.setTimeout(60_000);
  // At 760px and under the block becomes its own column, and an author
  // `display` at that width beats the user agent's [hidden] rule - so
  // the width that rearranges him is also the width where hiding him
  // can quietly stop working. Both halves, at the width itself.
  await page.setViewportSize({ width: 375, height: 800 });
  const waiting = await startBoard(makeRoot(["working"], true));
  try {
    await page.goto(`${waiting.url}/?lang=en`);
    await expect(page.locator(".dcard").first()).toBeVisible();
    await expect(page.locator("#captain .fig.r-cap")).toHaveCount(1);
    await expect(page.locator("#captain")).toBeVisible();
    // beside the cards, not on the deck, at this width as at any other
    await expect(page.locator(".scene .fig.r-cap")).toHaveCount(0);
    const box = await page.locator("#captain").boundingBox();
    expect(box!.width).toBeGreaterThan(0);
    expect(box!.height).toBeGreaterThan(0);
    // and the guard that keeps `hidden` working at this width. It has to
    // be provoked from here: the page only ever hides him when there are
    // no cards, and then #deckwrap is hidden too and hides him whatever
    // this rule says - which is why removing the rule broke nothing
    // until this line existed. The rule is the contract for
    // `.captain[hidden]`, so the attribute is what sets it.
    //
    // Not a race with the board's own clock, and asserted rather than
    // argued: the page renders when the event log changes and at no
    // other time, so nothing is going to undo this on a tick. The proof
    // is the second half - a real event goes into the log, the render
    // it triggers puts him back, and the page is shown to be the owner
    // of the attribute this half just borrowed.
    await page.evaluate(() => { document.getElementById("captain")!.hidden = true; });
    await expect(page.locator("#captain")).toBeHidden();
    appendFileSync(join(waiting.root, "state/events.jsonl"),
      JSON.stringify({ ts: "2026-09-21T10:00:00Z", actor: "worker-9", task: "T-001",
                       type: "dispatched", summary: { en: "late", "zh-TW": "late" } }) + "\n");
    await expect(page.locator("#captain")).toBeVisible({ timeout: 10_000 });
  } finally { stopBoard(waiting); }
  const quiet = await startBoard(makeRoot(["working"], false));
  try {
    await page.goto(`${quiet.url}/?lang=en`);
    await expect(page.locator(".scene .pivot").first()).toBeVisible();
    await expect(page.locator("#captain")).toHaveAttribute("hidden", "");
  } finally { stopBoard(quiet); }
});

test("a crewman below the top deck still names the task he is on", async ({ page }) => {
  test.setTimeout(60_000);
  // Criterion 3 has no viewport qualifier, and a crowded ship is where
  // the name chips appear - the full bubble would blindfold the crew
  // standing over it, so the chip has to carry the name and the roster
  // the job. Nothing covered the chip.
  const many = await startBoard(makeRoot(Array(9).fill("working"), false));
  try {
    await page.goto(`${many.url}/?lang=en`);
    await expect(page.locator(".scene .pivot").first()).toBeVisible();
    const minis = page.locator(".scene .bub.mini");
    expect(await minis.count()).toBeGreaterThan(0);
    // the task, not merely non-empty: a chip holding the agent's name is
    // also non-empty, which is what it held before and why "not blank"
    // was an assertion that passed on the old code
    for (const text of await minis.locator(".who").allInnerTexts()) {
      expect(text.trim()).toMatch(/^T-\d+$/);
    }
    // and the roster still carries what each of them is on
    const jobs = await page.locator(".roster .jb").allInnerTexts();
    expect(jobs.filter((j) => /^T-\d+/.test(j)).length).toBe(9);
  } finally { stopBoard(many); }
});

test("the ship follows the crew, not the backlog", async ({ page }) => {
  test.setTimeout(60_000);
  // The bug this task replaces: one figure per in-flight task. A fixture
  // with one agent per task cannot tell the two apart, which is why the
  // old one looked fine - so this is twelve tasks in flight and one agent
  // on them, and it has to be a small ship with one crewman aboard
  // besides firstmate.
  const many = await startBoard(makeRoot(Array(12).fill("working"), false, "one-worker"));
  try {
    await page.goto(`${many.url}/?lang=en`);
    await expect(page.locator(".scene .pivot").first()).toBeVisible();
    expect(Number(await page.locator(".scene").getAttribute("data-crew"))).toBe(2);
    await expect(page.locator(".roster li")).toHaveCount(2);
    const small = await page.locator(".scene").getAttribute("data-rate");
    expect(small).toBe("rate1");        // two aboard is the smallest ship
  } finally { stopBoard(many); }
});

test("the ship grows with the crew", async ({ page }) => {
  test.setTimeout(60_000);   // starts a second board in its body
  // zh-TW like every other interaction: the criterion puts the three
  // languages in the snapshot reads and everything else in one locale
  await open(page, "zh-TW");
  const small = await page.locator(".scene").getAttribute("data-rate");
  const crewNow = Number(await page.locator(".scene").getAttribute("data-crew"));
  expect(crewNow).toBe(CREW.length + 1);
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
