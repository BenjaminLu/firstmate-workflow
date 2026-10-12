// Observe the actual page at screenshot time on either production version.
// This helper does not navigate, serve pages, route requests or select views.
import { chromium } from '@playwright/test';
import { readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const plan = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const observations = [];
const launch = chromium.launch.bind(chromium);
chromium.launch = async (...args) => {
  const browser = await launch(...args);
  const newContext = browser.newContext.bind(browser);
  browser.newContext = async (...args) => {
    const context = await newContext(...args);
    const newPage = context.newPage.bind(context);
    context.newPage = async (...args) => {
      const page = await newPage(...args);
      const screenshot = page.screenshot.bind(page);
      page.screenshot = async (options) => {
        const elements = [];
        for (const selector of ['#decisionsPanel #card-D-1',
          '#fleetPanel .card[data-task="SK-007"]', '#crewSheet[open] #roster .rrow', '#logSheet[open] #log li']) {
          const element = page.locator(selector).first();
          const visible = await element.isVisible();
          elements.push({selector, visible, text: visible ? await element.innerText() : ''});
        }
        const result = await screenshot(options);
        const shot = plan.shots.find(shot => resolve(plan.out, shot.file) === resolve(options.path));
        observations.push({file: resolve(options.path), view: shot?.view, url: page.url(), elements,
          text: await page.locator('body').innerText()});
        writeFileSync(join(plan.out, 'observations.json'), JSON.stringify(observations));
        return result;
      };
      return page;
    };
    return context;
  };
  return browser;
};
await import('../../../bin/lib/fm-design-capture.mjs');
