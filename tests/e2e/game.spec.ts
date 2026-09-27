// T-125: the mode switch, the Live game seam, and the boss key. The Live
// bundle (board/public/voyage2d/live.html) is produced by
// games/voyage-2d/tools/build.py --live and committed; bin/ci.sh refuses a
// stale one. These specs assume it is present, exactly as every other e2e
// spec assumes board/public/index.html is.
import { expect, type Page } from "@playwright/test";
import { test, makeRoot, startBoard, stopBoard } from "./fixture";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const LIVE_BUNDLE = join(process.cwd(), "board/public/voyage2d/live.html");
const haveLiveBundle = existsSync(LIVE_BUNDLE);
const EN = JSON.parse(readFileSync(join(process.cwd(), "i18n/ui.en.json"), "utf8"));

// A tiny one-task fixture is enough for the mode switch and the boss key;
// the field-by-field cross-check between v1 and the games own BoardSource
// model is tests/board.test.sh own, at the HTTP layer, not here.
function fixtureRoot() {
  return makeRoot(["working"], false);
}

test.describe("the mode switch", () => {
  test("Board, Voyage 2.5D and Voyage 3D; 3D is disabled with coming; the choice persists in sessionStorage, not the URL or localStorage", async ({ page }) => {
    const b = await startBoard(fixtureRoot());
    try {
      await page.goto(b.url + "/?lang=en");
      const modes = page.locator("#modes button");
      await expect(modes).toHaveCount(3);
      await expect(modes.nth(0)).toHaveText(EN.modeBoard);
      await expect(modes.nth(1)).toHaveText(EN.modeVoyage2d);
      await expect(modes.nth(2)).toHaveText(EN.modeVoyage3d);
      await expect(modes.nth(2)).toBeDisabled();
      await expect(modes.nth(2)).toHaveAttribute("title", EN.mode3dComing);
      await expect(modes.nth(0)).toHaveAttribute("aria-pressed", "true");
      await expect(page.locator("#v1root")).toBeVisible();
      await expect(page.locator("#gamewrap")).toBeHidden();

      test.skip(!haveLiveBundle, "board/public/voyage2d/live.html has not been built yet");
      await modes.nth(1).click();
      await expect(page.locator("#gamewrap")).toBeVisible();
      await expect(page.locator("#v1root")).toBeHidden();
      const src = await page.locator("#gamewrap iframe").getAttribute("src");
      expect(src, "src").toContain("voyage2d/live.html#");
      expect(await page.evaluate(() => sessionStorage.getItem("board.mode"))).toBe("voyage2d");
      expect(await page.evaluate(() => localStorage.getItem("board.mode"))).toBeNull();
      expect(page.url()).not.toContain("mode=");

      // the choice is this tabs own: a fresh navigation in the SAME tab
      // (sessionStorage) resumes the game; the fixture never changes
      await page.reload();
      await expect(page.locator("#gamewrap")).toBeVisible();
      await expect(modes.nth(1)).toHaveAttribute("aria-pressed", "true");
    } finally { stopBoard(b); }
  });

  test("switching mode never touches /api/state, /events or any write", async ({ page }) => {
    test.skip(!haveLiveBundle, "board/public/voyage2d/live.html has not been built yet");
    const b = await startBoard(fixtureRoot());
    try {
      await page.goto(b.url + "/?lang=en");
      const requests: string[] = [];
      page.on("request", (r) => requests.push(r.url()));
      await page.locator("#modes button[data-m=voyage2d]").click();
      await page.waitForTimeout(300);
      requests.length = 0;
      await page.locator("#modes button[data-m=board]").click();
      await page.waitForTimeout(300);
      for (const url of requests) {
        const path = new URL(url).pathname;
        expect(path === "/decisions" || path === "/tasks", url).toBe(false);
        if (path === "/api/state" || path === "/events") expect(new URL(url).search).toBe("");
      }
    } finally { stopBoard(b); }
  });
});

// Every request the Live game makes while mounted must be one of: a static
// asset under /voyage2d/, GET /api/state, GET /events (SSE), GET /api/i18n,
// POST /decisions or POST /tasks - and every POST carries the tabs bearer
// token, never the boards secret. Nothing else ever leaves the page
// (docs/interface.md section 0 and 2; T-125 acceptance point 3).
test.describe("the Live game writes only through the boards own routes", () => {
  test.skip(!haveLiveBundle, "board/public/voyage2d/live.html has not been built yet");

  test("every request from the mounted game is a whitelisted board route, and every write carries the tabs token", async ({ page }) => {
    const b = await startBoard(fixtureRoot());
    try {
      await page.goto(b.url + "/?lang=en");
      const token = await page.evaluate(() => sessionStorage.getItem("board.token"));
      expect(token).toBeTruthy();
      await page.locator("#modes button[data-m=voyage2d]").click();
      const seen: Array<{ url: string; method: string; auth: string | null }> = [];
      page.on("request", (r) => {
        const url = new URL(r.url());
        if (url.origin !== new URL(b.url).origin) { seen.push({ url: r.url(), method: r.method(), auth: null }); return; }
        seen.push({ url: r.url(), method: r.method(), auth: r.headers()["authorization"] ?? null });
      });
      await page.waitForTimeout(500);
      for (const r of seen) {
        expect(r.url.startsWith(b.url), "same origin only").toBe(true);
        const path = new URL(r.url).pathname;
        const allowed = path === "/api/state" || path === "/api/i18n" || path === "/events" || path.startsWith("/voyage2d/");
        const isWrite = path === "/decisions" || path === "/tasks";
        expect(allowed || isWrite, r.url).toBe(true);
        if (isWrite) { expect(r.method).toBe("POST"); expect(r.auth).toBe(`Bearer ${token}`); }
      }
    } finally { stopBoard(b); }
  });

  test("a refused write shows the boards own translated refusal, never an invented message", async ({ page }) => {
    const b = await startBoard(fixtureRoot());
    try {
      await page.goto(b.url + "/?lang=en");
      // a stale/foreign token, exactly as a read-only tab would carry
      await page.evaluate(() => sessionStorage.setItem("board.token", "not-a-real-token"));
      await page.locator("#modes button[data-m=voyage2d]").click();
      const frame = page.frameLocator("#gamewrap iframe");
      await frame.locator("body").waitFor({ state: "attached", timeout: 15000 });
      // the exact surface depends on the games own menu; the contract is
      // that IT shows the boards writeCredential text somewhere, not a
      // message of its own invention
      await expect(frame.getByText(EN.writeCredential, { exact: false })).toBeVisible({ timeout: 15000 });
    } finally { stopBoard(b); }
  });
});

test.describe("the boss key", () => {
  test.skip(!haveLiveBundle, "board/public/voyage2d/live.html has not been built yet");

  test("Esc Esc from the Live game returns to v1 at once, and the iframe - canvas, audio and every timer with it - is gone", async ({ page }) => {
    const b = await startBoard(fixtureRoot());
    try {
      await page.goto(b.url + "/?lang=en");
      await page.locator("#modes button[data-m=voyage2d]").click();
      const frame = page.frameLocator("#gamewrap iframe");
      await frame.locator("canvas#c").waitFor({ state: "attached", timeout: 15000 });
      await frame.locator("canvas#c").click();
      await page.keyboard.press("Escape");
      await page.keyboard.press("Escape");
      // before the next frame: no animation-frame wait here on purpose
      await expect(page.locator("#gamewrap")).toBeHidden({ timeout: 300 });
      await expect(page.locator("#v1root")).toBeVisible();
      await expect(page.locator("#gamewrap iframe")).toHaveCount(0);
      expect(await page.evaluate(() => sessionStorage.getItem("board.mode"))).toBe("board");
    } finally { stopBoard(b); }
  });

  test("a single Esc keeps its in-game meaning; only the second, within about 400 ms, is the boss key", async ({ page }) => {
    const b = await startBoard(fixtureRoot());
    try {
      await page.goto(b.url + "/?lang=en");
      await page.locator("#modes button[data-m=voyage2d]").click();
      const frame = page.frameLocator("#gamewrap iframe");
      await frame.locator("canvas#c").waitFor({ state: "attached", timeout: 15000 });
      await frame.locator("canvas#c").click();
      await page.keyboard.press("Escape");
      await page.waitForTimeout(700); // well past the 400 ms window
      await page.keyboard.press("Escape");
      await page.waitForTimeout(300);
      await expect(page.locator("#gamewrap")).toBeVisible();
      await expect(page.locator("#v1root")).toBeHidden();
    } finally { stopBoard(b); }
  });

  test("the visible Board button returns to v1 just as the boss key does", async ({ page }) => {
    const b = await startBoard(fixtureRoot());
    try {
      await page.goto(b.url + "/?lang=en");
      await page.locator("#modes button[data-m=voyage2d]").click();
      await expect(page.locator("#gamewrap")).toBeVisible();
      await page.locator("#modes button[data-m=board]").click();
      await expect(page.locator("#gamewrap")).toBeHidden();
      await expect(page.locator("#v1root")).toBeVisible();
      await expect(page.locator("#gamewrap iframe")).toHaveCount(0);
    } finally { stopBoard(b); }
  });
});
