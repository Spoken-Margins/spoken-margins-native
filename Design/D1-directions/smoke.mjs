// Walks each task's intended path in a prototype and prints the measured taps.
// Usage: NODE_PATH=$(npm root -g) node smoke.mjs a-rooms.html '<json paths>' [shotdir]
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const [,, file, pathsJson, shots] = process.argv;
const paths = JSON.parse(pathsJson);
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, hasTouch: true });
const errs = []; p.on('pageerror', e => errs.push(e.message)); p.on('console', m => { if (m.type() === 'error' || m.type()==='warning') errs.push(m.text()); });
await p.goto('file://' + process.cwd() + '/' + file);
for (const [task, steps] of Object.entries(paths)) {
  await p.evaluate(t => { document.getElementById('guide').hidden = false; document.querySelector(`[data-task="${t}"]`).click(); }, task);
  await p.waitForTimeout(300);
  for (const s of steps) {
    if (s.startsWith('hold:')) {
      const el = p.locator(s.slice(5)).first(); const bx = await el.boundingBox();
      await p.mouse.move(bx.x + bx.width/2, bx.y + bx.height/2); await p.mouse.down(); await p.waitForTimeout(700); await p.mouse.up();
    } else {
      await p.locator(s).filter({ visible: true }).first().click({ timeout: 3000 });
    }
    await p.waitForTimeout(320);
  }
  const hud = await p.locator('#hud').innerText();
  console.log(task.padEnd(8), '|', hud.replace(/\n/g, ' '));
  if (shots) await p.screenshot({ path: `${shots}/${file.replace('.html','')}-${task}.png` });
}
console.log(errs.length ? 'ERRORS: ' + errs.join(' | ') : 'no console errors');
await b.close();
