// T-308: the board page loads without a page error in every variant it is
// opened in. One uncaught error in a classic script - "Identifier 't' has
// already been declared" was the one a captain saw with ?project=<name> -
// stops that script and leaves the page half drawn, so each variant is
// loaded and any page error fails it. tests/board-page-scope.test.sh keeps
// each script in its own scope; this is the page as a browser runs it.
import { expect, type Page } from "@playwright/test";
// `test` is the fixture's: its `page` is signed in to every board (T-122)
import { test, makeRoot, startBoard, stopBoard, writeProjects } from "./lib/fixture";
import { CREW } from "./lib/board";

const VIEWS = [
  { name: "default", query: "" },
  { name: "?project=<name>", query: "?project=alpha" },
  { name: "en", query: "?lang=en" },
  { name: "zh-TW", query: "?lang=zh-TW" },
  { name: "zh-CN", query: "?lang=zh-CN" },
];

const board = {} as Awaited<ReturnType<typeof startBoard>>;
test.beforeAll(async () => {
  const root = makeRoot([...CREW]);
  writeProjects(root, [
    { name: "alpha", github: "example-org/alpha-app" },
    { name: "beta", github: "example-org/beta-app", tasks: [{ id: "T-001", title: "beta one", depends_on: [] }] },
  ]);
  Object.assign(board, await startBoard(root));
});
test.afterAll(() => stopBoard(board));

// every uncaught error the page reports, from the first script it runs; a
// script that does not parse is one of them
function watchErrors(page: Page) {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  return errors;
}

async function load(page: Page, query: string, signedIn: boolean) {
  await page.goto(`${board.url}/${query}`);
  // the page drew itself: the last of its scripts ran, and the first render
  await expect(page.locator("#tabCrew .lb")).not.toHaveText("");
  await expect(page.locator("#roster .rrow").first()).toBeAttached();
  if (signedIn) await expect(page.locator("#readOnly")).toBeHidden();
  else await expect(page.locator("#readOnly")).toBeVisible();
  // a late error (the event stream, the session check) still counts
  await page.waitForTimeout(500);
}

for (const view of VIEWS) {
  test(`board page: no page error, signed-in tab, ${view.name}`, async ({ page }) => {
    const errors = watchErrors(page);
    await load(page, view.query, true);
    expect(errors).toEqual([]);
  });
  test(`board page: no page error, read-only tab, ${view.name}`, async ({ browser }) => {
    const context = await browser.newContext();
    try {
      const page = await context.newPage();
      const errors = watchErrors(page);
      await load(page, view.query, false);
      expect(errors).toEqual([]);
    } finally { await context.close(); }
  });
}
