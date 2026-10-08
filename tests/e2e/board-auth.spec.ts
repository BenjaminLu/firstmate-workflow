import { showFleet } from './lib/board';
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
test('the one-time address signs one tab in once, keeps no code and sets no cookie, and the card is answered end to end', async ({browser}) => {
  const b = await startBoard(makeRoot(['working']));
  const context = await browser.newContext();
  const page = await context.newPage();
  const other = await (await browser.newContext()).newPage();
  try {
    const address = signInAddress(b);
    const code = address.split('#')[1];
    await page.goto(address);
    await page.locator("#live").waitFor({ state: "attached" });   // the board page, loaded after the trade (T-145)
    expect(page.url()).toBe(`${b.url}/`);
    // the code stays neither in the address nor in the entry the tab kept
    expect(page.url()).not.toContain(code);
    await page.goBack().catch(() => null);
    expect(page.url()).not.toContain(code);
    // the tab holds the token, in its own storage; the browser holds no cookie
    await page.goto(`${b.url}/?lang=en`);
    expect(await page.evaluate(() => sessionStorage.getItem('board.token'))).toBe(tabToken(b));
    expect(await context.cookies()).toHaveLength(0);
    expect(await page.evaluate(() => document.cookie)).toBe('');
    await expect(page.locator('#readOnly')).toBeHidden();
    await page.locator('#card-D-1 [data-c="A"]').click();
    await page.locator('#card-D-1 .confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText('AYE, CAPTAIN!');
    await expect.poll(() => existsSync(b.recorder) ? readFileSync(b.recorder, 'utf8') : '').toContain('--pr 99');
    expect(await context.cookies()).toHaveLength(0);
    // the token is this tab's: another tab in the same browser is read-only
    const second = await context.newPage();
    await second.goto(`${b.url}/?lang=en`);
    await expect(second.locator('#readOnly')).toBeVisible();
    await expect(second.locator('#readOnlyWhy')).toHaveText(EN.readOnly);
    // the same address a second time signs nothing in
    await other.goto(address);
    await other.locator("#live").waitFor({ state: "attached" });
    expect(await other.evaluate(() => sessionStorage.getItem('board.token'))).toBeNull();
    await expect(other.locator('#readOnly')).toBeVisible();
  } finally { await context.close(); await other.context().close(); await stopBoard(b); }
});

test('a tab without the credential says it is read-only, in both languages, and writes nothing', async ({browser}) => {
  const root = makeRoot(['working']);
  const b = await startBoard(root);
  const context = await browser.newContext();
  const page = await context.newPage();
  try {
    await page.goto(`${b.url}/?lang=en`);
    await expect(page.locator('#readOnly')).toBeVisible();
    await expect(page.locator('#readOnlyWhy')).toHaveText(EN.readOnly);
    // every control that writes is visibly disabled, and says why (T-145):
    // the answer buttons, the confirm and each card's menu, which is there,
    // greyed, rather than gone; and no card can be dragged to park or drop
    for (const control of ['#card-D-1 [data-c="A"]', '#card-D-1 [data-c="custom"]', '#card-D-1 .confirm']) {
      await expect(page.locator(control)).toBeDisabled();
      await expect(page.locator(control)).toHaveAttribute('title', EN.readOnlyTip);
    }
    await showFleet(page);
    await expect(page.locator('.lanes .card')).not.toHaveCount(0);
    await expect(page.locator('.lanes .cmenu')).not.toHaveCount(0);
    for (const menu of await page.locator('.cmenu').all()) {
      await expect(menu).toBeDisabled();
      await expect(menu).toHaveAttribute('title', EN.readOnlyTip);
    }
    await expect(page.locator('.cacts')).toHaveCount(0);
    await expect(page.locator('.card[draggable="true"]')).toHaveCount(0);
    // the banner offers the sign-in again, and names no localhost address here
    await expect(page.locator('#relogin')).toBeVisible();
    await expect(page.locator('#relogin')).toHaveText(EN.reloginButton);
    await expect(page.locator('#readOnlyHere')).toBeHidden();
    // and a write sent anyway is refused by the board, whatever the page does
    const status = await page.evaluate(async () => (await fetch('/decisions', {method:'POST',
      headers:{'content-type':'application/json'}, body:JSON.stringify({id:'D-1',chosen:'A'})})).status);
    expect(status).toBe(403);
    // and so is one carrying what a cookie session would have held: the board
    // reads no cookie
    await context.addCookies([{ name: `firstmate_board_${new URL(b.url).port}`, value: tabToken(b), url: b.url }]);
    const withCookie = await page.evaluate(async () => (await fetch('/decisions', {method:'POST', credentials:'include',
      headers:{'content-type':'application/json'}, body:JSON.stringify({id:'D-1',chosen:'A'})})).status);
    expect(withCookie).toBe(403);
    expect(existsSync(join(root, 'state/decisions/D-1.json'))).toBe(false);
    expect(existsSync(b.recorder)).toBe(false);
    await page.goto(`${b.url}/?lang=zh-TW`);
    await expect(page.locator('#readOnlyWhy')).toHaveText(TW.readOnly);
    await expect(page.locator('#card-D-1 .confirm')).toHaveAttribute('title', TW.readOnlyTip);
    await expect(page.locator('#relogin')).toHaveText(TW.reloginButton);
  } finally { await context.close(); await stopBoard(b); }
});

test('T-145: the sign-in page takes the board\'s own address before it trades the code, so a reload never sends it again', async ({browser}) => {
  const root = makeRoot(['working']);
  const b = await startBoard(root);
  const context = await browser.newContext();
  const page = await context.newPage();
  try {
    // the trade is held until the address has been read
    let release = () => {};
    const held = new Promise<void>(r => { release = r; });
    const posts: string[] = [];
    await page.route('**/login', async route => {
      if (route.request().method() === 'POST') { posts.push(route.request().postData() || ''); await held; }
      await route.continue();
    });
    const address = signInAddress(b);
    const code = address.split('#')[1];
    await page.goto(address, { waitUntil: 'commit' });
    await expect.poll(() => posts.length).toBe(1);
    expect(posts[0]).toContain(code);
    // while the code is on its way the tab's address is already the board's
    await expect.poll(() => page.url()).toBe(`${b.url}/`);
    release();
    // the board's own page, which the login page loads once the token is kept
    await page.locator('#live').waitFor({ state: 'attached' });
    expect(await page.evaluate(() => sessionStorage.getItem('board.token'))).toBe(tabToken(b));
    // a reload lands on the board and sends no code
    await page.reload();
    await expect(page.locator('#readOnly')).toBeHidden();
    expect(posts).toHaveLength(1);
  } finally { await context.close(); await stopBoard(b); }
});

test('T-145: a tab opened as localhost says so, and links to the board at 127.0.0.1', async ({browser}) => {
  const root = makeRoot(['working']);
  const b = await startBoard(root);
  const context = await browser.newContext();
  const page = await context.newPage();
  const port = new URL(b.url).port;
  try {
    await page.goto(`http://localhost:${port}/?lang=en`);
    await expect(page.locator('#readOnly')).toBeVisible();
    await expect(page.locator('#readOnlyWhy')).toHaveText(EN.readOnlyLocalhost);
    await expect(page.locator('#readOnlyHere')).toBeVisible();
    await expect(page.locator('#readOnlyHere')).toHaveAttribute('href', `http://127.0.0.1:${port}/?lang=en`);
    await expect(page.locator('#card-D-1 [data-c="A"]')).toBeDisabled();
    await expect(page.locator('#card-D-1 [data-c="A"]')).toHaveAttribute('title', EN.readOnlyTipLocalhost);
    await page.goto(`http://localhost:${port}/?lang=zh-TW`);
    await expect(page.locator('#readOnlyWhy')).toHaveText(TW.readOnlyLocalhost);
    await expect(page.locator('#readOnlyHere')).toHaveText(TW.readOnlyOpenHere);
  } finally { await context.close(); await stopBoard(b); }
});

test('T-145: the banner\'s button asks the board for a sign-in, sends no credential, and says what the board did', async ({browser}) => {
  const root = makeRoot(['working']);
  // the opener, recorded instead of run: the board runs bin/fm-herdr.py in its
  // root, as it runs bin/fm-merge.sh, so nothing opens a real browser here
  const calls = join(root, 'opener-calls');
  writeFileSync(join(root, 'bin/fm-herdr.py'), 'import json, sys\n' +
    `open(${JSON.stringify(calls)}, "a").write(json.dumps(sys.argv[1:]) + "\\n")\n` +
    'print(json.dumps({"opener_invoked": True, "tab": "reused", "browser": "Safari"}))\n');
  const b = await startBoard(root);
  const context = await browser.newContext();
  const page = await context.newPage();
  const sent: Array<Record<string, string>> = [];
  page.on('request', r => { if (new URL(r.url()).pathname === '/relogin') sent.push(r.headers()); });
  try {
    await page.goto(`${b.url}/?lang=en`);
    await expect(page.locator('#relogin')).toBeVisible();
    await page.locator('#relogin').click();
    await expect(page.locator('#reloginSaid')).toHaveText(EN.reloginReused);
    expect(readFileSync(calls, 'utf8').trim().split('\n').map(l => JSON.parse(l)))
      .toEqual([['board-login', new URL(b.url).port]]);
    expect(sent).toHaveLength(1);
    expect(sent[0].authorization).toBeUndefined();
    expect(sent[0]['content-type']).toContain('application/json');
    // the button waits out the board's 10 seconds, and the board refuses a burst anyway
    await expect(page.locator('#relogin')).toBeDisabled();
    const again = await page.evaluate(async () => { const r = await fetch('/relogin', { method: 'POST',
      headers: { 'content-type': 'application/json' }, body: '{}' }); return [r.status, (await r.json()).code]; });
    expect(again).toEqual([429, 'reloginTooSoon']);
    expect(readFileSync(calls, 'utf8').trim().split('\n')).toHaveLength(1);
  } finally { await context.close(); await stopBoard(b); }
});

test('a server on another loopback port receives nothing from the captain\'s signed-in tab, and its page cannot answer a card', async ({page}) => {
  const root = makeRoot(['working']);
  const b = await startBoard(root);
  try {
    await page.goto(`${b.url}/?lang=en`);   // signed in, through the one-time address
    await expect(page.locator('#readOnly')).toBeHidden();
    // Another loopback port is the same site, and a browser would send it a
    // cookie set for 127.0.0.1. So the other server records every header it
    // is sent, and none may carry the credential.
    const { createServer } = await import('node:http');
    const received: string[] = [];
    const elsewhere = createServer((req, res) => {
      received.push(JSON.stringify(req.headers));
      res.setHeader('content-type', 'text/html'); res.end('<title>elsewhere</title>');
    });
    await new Promise<void>(r => elsewhere.listen(0, '127.0.0.1', () => r()));
    const port = (elsewhere.address() as { port: number }).port;
    try {
      // the same tab goes there, as following a link would
      await page.goto(`http://127.0.0.1:${port}/`);
      await page.goto(`http://127.0.0.1:${port}/again`);
      expect(received.length).toBeGreaterThanOrEqual(2);   // the control
      for (const headers of received) {
        expect(headers).not.toContain(tabToken(b));
        expect(headers).not.toContain(b.secret);
        expect(headers).not.toContain('firstmate_board_');
      }
      expect(await page.context().cookies()).toHaveLength(0);
      // its page cannot read the board's storage, and what it sends is refused
      expect(await page.evaluate(() => sessionStorage.getItem('board.token'))).toBeNull();
      const status = await page.evaluate(async (url) => {
        const r = await fetch(url + '/decisions', { method: 'POST', mode: 'no-cors', credentials: 'include',
          headers: { 'content-type': 'text/plain' }, body: JSON.stringify({ id: 'D-1', chosen: 'A' }) }).catch(() => null);
        return r ? r.type : 'failed';
      }, b.url);
      expect(['opaque', 'failed']).toContain(status);
      await page.waitForTimeout(500);
      expect(existsSync(join(root, 'state/decisions/D-1.json'))).toBe(false);
      expect(existsSync(b.recorder)).toBe(false);
      // the control: back on the board, the same tab still writes
      await page.goto(`${b.url}/?lang=en`);
      await expect(page.locator('#readOnly')).toBeHidden();
      await page.locator('#card-D-1 [data-c="A"]').click();
      await page.locator('#card-D-1 .confirm').click();
      await expect.poll(() => existsSync(b.recorder) ? readFileSync(b.recorder, 'utf8') : '').toContain('--pr 99');
    } finally { elsewhere.close(); }
  } finally { await stopBoard(b); }
});

// --- T-118: every card sits where its task really is -------------------------
