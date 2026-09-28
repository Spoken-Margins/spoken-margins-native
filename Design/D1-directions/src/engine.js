/* Tiny click-through engine shared by the D1 direction prototypes.
   Screens are <section class="scr" data-id>, sheets are <div class="sheet" data-id>.
   Anything with a data-go / data-tabgo / data-back / data-sheet / data-close /
   data-share / data-toggle / data-emit / data-act / data-tap attribute counts
   as one tap. A task starts from a known screen and ends when its goal event
   is emitted, so the tap counter in the strip is the tap budget, measured. */
(function () {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));

  // Sample content. Every show, person and quote here is illustrative.
  const DATA = {
    margins: {
      m1: { who: 'You', item: 'Why we stopped reading slowly', show: 'The Long Middle', at: '18:12', kind: 'Voice · 0:24',
            text: 'This is Priya’s point about re-reading: attention is a budget you spend twice.' },
      m2: { who: 'You', item: 'Why we stopped reading slowly', show: 'The Long Middle', at: '31:40', kind: 'Written',
            text: 'Find the 1978 study he cites before Tuesday.' },
      m3: { who: 'You', item: 'The case for boredom', show: 'Harbor Review', at: '6:05', kind: 'Voice · 0:41',
            text: 'Boredom as a waiting room for ideas. The kids’ car rides were exactly this.' },
      m4: { who: 'You', item: 'Sleep spindles and memory consolidation', show: 'Ramírez et al. · PDF', at: 'Fig. 3', kind: 'Voice · 0:18',
            text: 'Figure 3 seems to contradict the abstract. Ask Sam.' },
      m0: { who: 'You', item: 'Why we stopped reading slowly', show: 'The Long Middle', at: '18:40', kind: 'Voice · 0:12',
            text: 'Just recorded: “the skim is the enemy, not the screen.”' },
    },
  };

  const COMMON = `
  <section class="scr msgs" data-id="messages" data-chrome="">
    <div class="m-top"><div class="av">P</div><div>Priya</div></div>
    <div class="body"><div class="m-body">
      <div class="bub">ok this bit at 22 min is exactly what we argued about</div>
      <button class="attach" data-act="openPacket" aria-label="Open Priya's Margin in Spoken Margins">
        <div class="a-art">SPOKEN MARGINS · Margin<b>Priya on “Why we stopped reading slowly”</b></div>
        <div class="a-meta">Voice · 0:31 · at 22:05 · priya.spokenmargins</div>
      </button>
      <div class="bub">listen to it where it happens</div>
      <div class="hint">This is Messages, outside the app. Tap the attachment.</div>
    </div></div>
  </section>

  <div class="sheet" data-id="share" hidden>
    <div class="scrim" data-close></div>
    <div class="card ios" role="dialog" aria-label="Share sheet">
      <div class="grab"></div>
      <div class="sh-head">
        <div class="pkt-icon">SM</div>
        <div><div class="sh-title" data-f="title">Your Margin</div><div class="sh-sub" data-f="sub">Spoken Margins packet</div></div>
        <button class="sh-x" data-close aria-label="Close">✕</button>
      </div>
      <div class="scroll">
        <div class="preview">
          <div class="sh-sub">What they’ll get</div>
          <div class="pv-quote" data-f="quote"></div>
          <div class="pv-row">
            <span class="pv-chip" data-f="kind">Voice</span>
            <span class="pv-chip">Transcript</span>
            <span class="pv-chip">Plays at <b data-f="at"></b></span>
            <span class="pv-chip off">Your private feed link</span>
          </div>
          <div style="margin-top:8px"><button class="pv-change" data-tap data-toast="(Sketch) Choose: voice + transcript, transcript only, or with 20 s of source audio">Change what’s included</button></div>
        </div>
        <div class="people">
          <button class="person" data-emit="shared" data-close data-act="sent" data-arg="Priya"><span class="av" style="background:#6b5bd6">P</span>Priya</button>
          <button class="person" data-emit="shared" data-close data-act="sent" data-arg="Tuesday Readers"><span class="av" style="background:#b4452f">TR</span>Tuesday Readers</button>
          <button class="person" data-emit="shared" data-close data-act="sent" data-arg="Sam"><span class="av" style="background:#2f6fb4">S</span>Sam</button>
          <button class="person" data-emit="shared" data-close data-act="sent" data-arg="Mum"><span class="av" style="background:#a17218">M</span>Mum</button>
        </div>
        <div class="apps">
          <button class="appi" data-emit="shared" data-close data-act="sent" data-arg="Messages"><span class="ic" style="background:#34c759">✉</span>Messages</button>
          <button class="appi" data-emit="shared" data-close data-act="sent" data-arg="Mail"><span class="ic" style="background:#1f8cf5">@</span>Mail</button>
          <button class="appi" data-emit="shared" data-close data-act="sent" data-arg="WhatsApp"><span class="ic" style="background:#25a35a">W</span>WhatsApp</button>
          <button class="appi" data-close data-toast="Saved to Files"><span class="ic" style="background:#3b82f6">F</span>Files</button>
        </div>
        <div class="acts">
          <button data-close data-toast="Copied transcript and timestamp">Copy text <span>⧉</span></button>
          <button data-close data-toast="Saved to Files">Save to Files <span>⤓</span></button>
        </div>
      </div>
    </div>
  </div>

  <div class="sheet" data-id="packet" hidden>
    <div class="scrim" data-close></div>
    <div class="card pkt" role="dialog" aria-label="Shared Margin">
      <div class="grab"></div>
      <div class="pk-who"><div class="av">P</div><div><b>Priya shared a Margin</b><span>Voice · 0:31 · recorded Saturday</span></div></div>
      <blockquote>“He’s wrong about audiobooks. Listening is reading, you just can’t skim it, and that’s the point.”</blockquote>
      <p class="pk-src">On <b>Why we stopped reading slowly</b> · The Long Middle · at 22:05</p>
      <p class="pk-note">You don’t have this episode yet. Play adds it to your Library and starts ten seconds before her Margin.</p>
      <div class="pk-actions">
        <button class="primary" data-act="playPacket" data-emit="packet-played">▶︎  Play her Margin in place</button>
        <button class="secondary" data-close data-toast="Saved to Margins · From friends">Save for later</button>
      </div>
    </div>
  </div>

  <div class="sheet" data-id="export" hidden>
    <div class="scrim" data-close></div>
    <div class="card exp" role="dialog" aria-label="Export this week">
      <div class="grab"></div>
      <div class="ex-head"><h3>This week as a note</h3><p>7 Margins from 4 items · Sep 22–28</p></div>
      <pre class="note-md"># Week of Sep 22 – Listening notes

## Why we stopped reading slowly — The Long Middle
- **18:12** (voice) This is Priya’s point about re-reading:
  attention is a budget you spend twice.
- **31:40** Find the 1978 study he cites before Tuesday.
- **40:10** → Sam: “The 1978 study is Kintsch.”

## The case for boredom — Harbor Review
- **6:05** (voice) Boredom as a waiting room for ideas.

## Sleep spindles and memory consolidation — PDF
- **Fig. 3** (voice) Figure 3 seems to contradict the abstract.
  Ask Sam.
…</pre>
      <div class="ex-dest"><span>Saves to</span><b>Obsidian › Spoken Margins</b><button class="chg" data-tap data-toast="(First time only) the Files picker opens to choose a folder: +2 taps, once">Change</button></div>
      <div class="ex-actions">
        <button class="primary" data-emit="exported" data-close data-toast="Saved “Week of Sep 22.md” to Obsidian">Save note</button>
        <button class="secondary" data-close data-share="week">Share as file…</button>
      </div>
    </div>
  </div>

  <div class="toast" role="status" aria-live="polite"><span class="t-msg"></span><button class="t-act" hidden></button></div>`;

  const S = { stack: [], task: null, taps: 0, results: {} };
  let phone, initial, hooks, hud;
  const ACTION = '[data-go],[data-tabgo],[data-back],[data-sheet],[data-close],[data-emit],[data-toast],[data-act],[data-share],[data-toggle],[data-tap]';

  function show(id, push = true) {
    const el = $(`.scr[data-id="${id}"]`, phone);
    if (!el) { console.warn('no screen', id); return; }
    $$('.scr', phone).forEach(s => { s.hidden = s !== el; });
    if (push && S.stack[S.stack.length - 1] !== id) S.stack.push(id);
    phone.dataset.chrome = el.dataset.chrome || '';
    phone.dataset.screen = id;
    if (el.dataset.tab) $$('[data-tabgo]', phone).forEach(t => t.classList.toggle('on', t.dataset.tabgo === el.dataset.tab));
    const b = $('.body', el); if (b && push) b.scrollTop = 0;
    hooks.onShow && hooks.onShow(id, el, api);
  }
  function tabgo(id) { S.stack = []; show(id); }
  function back() { if (S.stack.length > 1) { S.stack.pop(); show(S.stack[S.stack.length - 1], false); } }
  function openSheet(id) {
    const sh = $(`.sheet[data-id="${id}"]`, phone); if (!sh) { console.warn('no sheet', id); return; }
    sh.hidden = false; sh.offsetHeight; sh.classList.add('open');
  }
  function closeSheet(id) {
    const list = id ? [$(`.sheet[data-id="${id}"]`, phone)] : $$('.sheet.open', phone).slice(-1);
    list.forEach(sh => { if (!sh) return; sh.classList.remove('open'); setTimeout(() => { if (!sh.classList.contains('open')) sh.hidden = true; }, 230); });
  }
  function closeAll() { $$('.sheet', phone).forEach(sh => { sh.classList.remove('open'); sh.hidden = true; }); }
  let tt;
  function toast(msg, action) {
    const t = $('.toast', phone), a = $('.t-act', t);
    $('.t-msg', t).textContent = msg;
    Array.from(a.attributes).forEach(at => { if (at.name.startsWith('data-')) a.removeAttribute(at.name); });
    a.hidden = !action;
    if (action) { a.textContent = action.label; Object.entries(action.attrs || {}).forEach(([k, v]) => a.setAttribute(k, v)); }
    t.classList.add('show'); clearTimeout(tt);
    tt = setTimeout(() => t.classList.remove('show'), action ? 5000 : 2600);
  }
  function share(id) {
    const m = DATA.margins[id];
    const sh = $('.sheet[data-id="share"]', phone);
    const f = k => $(`[data-f="${k}"]`, sh);
    if (id === 'week') {
      f('title').textContent = 'Week of Sep 22.md'; f('sub').textContent = 'Markdown note · 7 Margins';
      f('quote').textContent = '# Week of Sep 22 – Listening notes…'; f('kind').textContent = 'Note'; f('at').textContent = '—';
    } else if (m) {
      f('title').textContent = `${m.who === 'You' ? 'Your' : m.who + '’s'} Margin on “${m.item}”`;
      f('sub').textContent = `${m.show} · Spoken Margins packet`;
      f('quote').textContent = `“${m.text}”`; f('kind').textContent = m.kind; f('at').textContent = m.at;
    }
    openSheet('share');
  }
  function emit(name) {
    hooks.onEmit && hooks.onEmit(name, api);
    if (S.task && !S.task.done && S.task.goal === name) {
      S.task.done = true;
      const prev = S.results[S.task.id];
      S.results[S.task.id] = prev == null ? S.taps : Math.min(prev, S.taps);
      renderHud(); renderTasks();
    }
  }
  function countTap() { if (S.task && !S.task.done) { S.taps++; renderHud(); } }

  function renderHud() {
    hud.classList.remove('done', 'over');
    if (!S.task) {
      hud.innerHTML = '<span class="hud-task">Exploring freely</span>';
      return;
    }
    const t = S.task;
    const over = S.taps > t.budget;
    if (t.done) hud.classList.add(over ? 'over' : 'done'); else if (over) hud.classList.add('over');
    hud.innerHTML = `<span class="count">${S.taps} / ${t.budget}</span><span class="hud-task">${t.done ? 'Done: ' : ''}${t.name}</span>`;
  }
  function renderTasks() {
    const list = $('#taskList'); if (!list) return;
    list.innerHTML = hooks.tasks.map(t => {
      const r = S.results[t.id];
      return `<div class="task"><b>${t.name}</b><button data-task="${t.id}">Try</button>
        <span class="meta">Budget ${t.budget} tap${t.budget > 1 ? 's' : ''} · starts ${t.from}${r != null ? ` · <span class="res">you did it in ${r}</span>` : ''}</span></div>`;
    }).join('');
  }
  function startTask(id) {
    const t = hooks.tasks.find(x => x.id === id);
    phone.innerHTML = initial; S.stack = [];
    S.task = Object.assign({}, t, { done: false }); S.taps = 0;
    t.start(api);
    renderHud(); closeGuide();
  }
  function reset() { phone.innerHTML = initial; S.stack = []; S.task = null; S.taps = 0; hooks.home(api); renderHud(); }
  function openGuide() { const g = $('#guide'); g.hidden = false; }
  function closeGuide() { if (window.matchMedia('(max-width: 860px)').matches) $('#guide').hidden = true; }

  const api = { show, tabgo, back, openSheet, closeSheet, closeAll, toast, share, emit, $, $$, get phone() { return phone; }, DATA };

  function init(dir) {
    hooks = dir;
    phone = $('#phone'); hud = $('#hud');
    phone.insertAdjacentHTML('beforeend', COMMON);
    initial = phone.innerHTML;

    hooks.openPacket = hooks.openPacket || function (el, arg, a) { a.show(hooks.packetLanding || 'home'); a.openSheet('packet'); };
    hooks.sent = hooks.sent || function (el, who, a) { setTimeout(() => a.toast(`Sent to ${who}`), 120); };

    phone.addEventListener('click', e => {
      const el = e.target.closest(ACTION);
      if (!el || !phone.contains(el) || el.hasAttribute('data-hold')) return;
      e.preventDefault();
      countTap();
      const d = el.dataset;
      if (d.act && hooks[d.act]) hooks[d.act](el, d.arg, api);
      let togOn = true;
      if ('toggle' in d) {
        el.classList.toggle('on'); togOn = el.classList.contains('on');
        if (d.onText) { if (d.offText == null) d.offText = el.textContent; el.textContent = togOn ? d.onText : d.offText; }
        el.setAttribute('aria-pressed', togOn);
      }
      if ('close' in d) closeSheet(d.close || undefined);
      if ('back' in d) back();
      if (d.tabgo) { closeAll(); tabgo(d.tabgo); }
      if (d.go) { if (!('keep' in d)) closeAll(); show(d.go); }
      if (d.sheet) openSheet(d.sheet);
      if (d.share) share(d.share);
      if (d.toast) toast(d.toast);
      if (d.emit && togOn) d.emit.split(' ').forEach(emit);
    });

    // Press-and-hold controls (direction B records this way).
    let holding = null, t0 = 0;
    phone.addEventListener('pointerdown', e => {
      const el = e.target.closest('[data-hold]'); if (!el) return;
      e.preventDefault(); holding = el; t0 = Date.now();
      phone.classList.add('holding'); hooks.holdStart && hooks.holdStart(el, api);
    });
    const end = () => {
      if (!holding) return; const el = holding; holding = null;
      phone.classList.remove('holding');
      const long = Date.now() - t0 > 450;
      if (long) countTap();
      hooks.holdEnd && hooks.holdEnd(el, long, api);
    };
    window.addEventListener('pointerup', end); window.addEventListener('pointercancel', end);
    phone.addEventListener('contextmenu', e => { if (e.target.closest('[data-hold]')) e.preventDefault(); });

    document.addEventListener('click', e => {
      const b = e.target.closest('[data-task]'); if (b) { startTask(b.dataset.task); return; }
      if (e.target.closest('#guideBtn')) openGuide();
      if (e.target.closest('.close-guide')) $('#guide').hidden = true;
      if (e.target.closest('#resetBtn')) reset();
    });
    if (window.matchMedia('(max-width: 860px)').matches) $('#guide').hidden = true;
    renderTasks(); hooks.home(api); renderHud();
  }

  window.Engine = { init, DATA };
})();
