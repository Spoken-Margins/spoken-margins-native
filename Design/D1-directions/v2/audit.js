(async () => {
  const phone = document.getElementById('phone');
  const pr = phone.getBoundingClientRect();
  const ACTION = '[data-go],[data-tabgo],[data-back],[data-sheet],[data-close],[data-emit],[data-toast],[data-act],[data-share],[data-toggle],[data-tap],[data-hold],[data-task]';
  const issues = [];
  const vis = el => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 && !el.closest('[hidden]'); };
  const check = (label) => {
    // horizontal overflow of any visible element beyond the phone
    phone.querySelectorAll('*').forEach(el => {
      if (!vis(el)) return; if (el.closest('.scroll, .chips, .people, .apps, .tapwrap')) return;
      const r = el.getBoundingClientRect();
      if (r.right > pr.right + 1 || r.left < pr.left - 1) issues.push(`${label}: overflow x ${el.tagName.toLowerCase()}.${[...el.classList].join('.')} (${Math.round(r.left - pr.left)}..${Math.round(r.right - pr.left)})`);
    });
    phone.querySelectorAll(ACTION).forEach(el => {
      if (!vis(el)) return; if (el.classList.contains('scrim')) return;
      const r = el.getBoundingClientRect();
      if (r.width < 44 || r.height < 44) issues.push(`${label}: small target ${Math.round(r.width)}x${Math.round(r.height)} ${el.tagName.toLowerCase()}.${[...el.classList].join('.')} "${(el.getAttribute('aria-label') || el.textContent).trim().slice(0, 30)}"`);
    });
    // any visible body that scrolls horizontally
    phone.querySelectorAll('.body').forEach(b => { if (vis(b) && b.scrollWidth > b.clientWidth + 1) issues.push(`${label}: body scrolls horizontally by ${b.scrollWidth - b.clientWidth}px`); });
    // sheet cards taller than the phone
    phone.querySelectorAll('.sheet.open > .card').forEach(c => { const r = c.getBoundingClientRect(); if (r.top < pr.top) issues.push(`${label}: sheet card clipped at top`); });
  };
  const screens = [...phone.querySelectorAll('.scr')].map(s => s.dataset.id);
  const sheets = [...phone.querySelectorAll('.sheet')].map(s => s.dataset.id);
  const api = { show: id => { phone.querySelectorAll('.scr').forEach(s => s.hidden = s.dataset.id !== id); const el = phone.querySelector(`.scr[data-id="${id}"]`); phone.dataset.chrome = el.dataset.chrome || ''; el.dispatchEvent(new Event('x')); } };
  for (const id of screens) {
    // use the engine's own show() so lists populate
    const btn = document.createElement('button'); btn.setAttribute('data-go', id); btn.style.position = 'absolute'; phone.appendChild(btn); btn.click(); btn.remove();
    await new Promise(r => setTimeout(r, 60));
    // also reveal hidden optional pieces
    phone.querySelectorAll('#pktBanner,#pktMargin').forEach(e => e.hidden = false);
    check('screen ' + id);
    // scroll to bottom and re-check for elements only visible when scrolled
    const b = phone.querySelector(`.scr[data-id="${id}"] .body`); if (b) { b.scrollTop = b.scrollHeight; check('screen ' + id + ' (scrolled)'); b.scrollTop = 0; }
  }
  for (const id of sheets) {
    const sh = phone.querySelector(`.sheet[data-id="${id}"]`); sh.hidden = false; sh.classList.add('open');
    if (id === 'share') { const btn = document.createElement('button'); btn.setAttribute('data-share', 'm1'); phone.appendChild(btn); btn.click(); btn.remove(); }
    await new Promise(r => setTimeout(r, 300));
    check('sheet ' + id);
    sh.classList.remove('open'); sh.hidden = true;
  }
  return { size: `${innerWidth}x${innerHeight}`, screens, sheets, issues: [...new Set(issues)] };
})()
