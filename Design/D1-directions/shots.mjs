// Screenshots named screens of a prototype into one contact sheet per file.
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const [,, file, ids, out] = process.argv;
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 390, height: 800 }, deviceScaleFactor: 1 });
await p.goto('file://' + process.cwd() + '/' + file);
const list = ids.split(',');
const imgs = [];
for (const id of list) {
  await p.evaluate(id => {
    document.querySelectorAll('.sheet').forEach(s => { s.hidden = true; s.classList.remove('open'); });
    const [scr, sheet] = id.split('+');
    const el = document.querySelector(`.scr[data-id="${scr}"]`);
    document.querySelectorAll('.scr').forEach(s => s.hidden = s !== el);
    const ph = document.getElementById('phone'); ph.dataset.chrome = el.dataset.chrome || '';
    if (sheet) { const sh = document.querySelector(`.sheet[data-id="${sheet}"]`); sh.hidden = false; sh.classList.add('open'); }
  }, id);
  await p.waitForTimeout(350);
  imgs.push((await p.locator('#phone').screenshot()).toString('base64'));
}
const html = `<body style="margin:0;display:flex;flex-wrap:wrap;gap:6px;background:#888">${imgs.map(i => `<img style="width:390px" src="data:image/png;base64,${i}">`).join('')}</body>`;
const q = await b.newPage({ viewport: { width: 396 * Math.min(list.length, 4), height: 800 } });
await q.setContent(html); await q.screenshot({ path: out, fullPage: true });
await b.close();
