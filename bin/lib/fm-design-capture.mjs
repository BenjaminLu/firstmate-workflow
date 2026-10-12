// T-298: render every planned page at its viewport and colour scheme.
//
//   bun bin/lib/fm-design-capture.mjs <plan.json>
//
// bin/lib/fm_design.py writes the plan and checks every screenshot this
// writes; it runs in the launcher, outside the round's sandbox, so the
// designer round itself never starts a browser. Any page that fails to load
// exits non-zero, and no designer round starts.
import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { chromium } from "@playwright/test";

const plan = JSON.parse(readFileSync(process.argv[2], "utf8"));
// Pin localhost resolution and disable peer-to-peer UDP. Context routing
// covers HTTP(S), redirects, frames and workers; sockets need their own route.
const browser = await chromium.launch({args: [
  '--host-resolver-rules=MAP localhost 127.0.0.1, EXCLUDE 127.*, EXCLUDE [::1], MAP * ~NOTFOUND',
  '--proxy-server=http://127.0.0.1:9',
  '--proxy-bypass-list=localhost;127.0.0.0/8;[::1]',
  '--disable-quic',
  '--force-webrtc-ip-handling-policy=disable_non_proxied_udp',
]});
const record = {blocked: [], pages: []};
function local(url) {
  const u = new URL(url);
  if (u.protocol === 'file:') return !u.hostname || u.hostname === 'localhost';
  if (['data:', 'blob:', 'about:'].includes(u.protocol)) return true;
  return ['http:', 'https:', 'ws:', 'wss:'].includes(u.protocol) &&
    (['localhost', '[::1]'].includes(u.hostname) || /^127\.\d+\.\d+\.\d+$/.test(u.hostname));
}
let failed = 0;
try {
  for (const shot of plan.shots) {
    const context = await browser.newContext({
      viewport: { width: shot.width, height: shot.height },
      colorScheme: shot.scheme,
      reducedMotion: "reduce",
      serviceWorkers: "block",
    });
    try {
      const blocked = url => record.blocked.push({page: shot.page, file: shot.file, url});
      await context.route('**/*', route => {
        const url = route.request().url();
        if (local(url)) return route.continue();
        blocked(url);
        return route.abort('blockedbyclient');
      });
      await context.routeWebSocket('**/*', socket => {
        if (local(socket.url())) socket.connectToServer();
        else { blocked(socket.url()); socket.close(); }
      });
      const page = await context.newPage();
      const response = await page.goto(shot.url, { waitUntil: "load", timeout: 30000 });
      if (response && !response.ok() && !shot.url.startsWith("file:")) throw new Error(`HTTP ${response.status()}`);
      if (shot.ready) await page.locator(shot.ready).first().waitFor({state: 'attached', timeout: 30000});
      const out = join(plan.out, shot.file);
      mkdirSync(dirname(out), { recursive: true });
      await page.screenshot({ path: out, fullPage: true, animations: "disabled" });
      record.pages.push({file: shot.file, url: shot.url,
        text: (await page.locator('body').innerText()).slice(0, 16000),
        readyText: shot.ready ? await page.locator(shot.ready).first().textContent() : null});
    } catch (error) {
      failed++;
      console.error(`capture failed: ${shot.file}: ${error.message}`);
    } finally {
      await context.close();
    }
  }
} finally {
  await browser.close();
  mkdirSync(plan.out, {recursive: true});
  writeFileSync(join(plan.out, 'requests.json'), JSON.stringify(record, null, 2));
}
process.exit(failed ? 1 : 0);
