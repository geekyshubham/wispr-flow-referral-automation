const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({ headless: false });
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto('https://wisprflow.ai/r?SHUBHAM3680', { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(3000);
  
  // Dump interactive elements
  const inputs = await page.locator('input, button, a').all();
  for (const el of inputs.slice(0, 30)) {
    const tag = await el.evaluate(e => e.tagName);
    const type = await el.getAttribute('type');
    const text = (await el.textContent())?.trim().slice(0, 60);
    const placeholder = await el.getAttribute('placeholder');
    const name = await el.getAttribute('name');
    const id = await el.getAttribute('id');
    console.log({ tag, type, text, placeholder, name, id });
  }
  
  await page.screenshot({ path: '/Users/checkred_admin/wispr-flow-tester/signup-page.png', fullPage: true });
  console.log('Screenshot saved');
  await page.waitForTimeout(5000);
  await browser.close();
})();
