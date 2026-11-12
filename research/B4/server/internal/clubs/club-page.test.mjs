// The club invitation page's script (#1799 slice 4). The shell is the one clubs/page.go writes: the ids the script
// reads are checked against the Go output by TestClubPageShellHasWhatTheScriptReads in internal/api.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
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

test('the script makes no request and keeps nothing', () => {
  const source = readFileSync(new URL('./club-page.mjs', import.meta.url), 'utf8').replace(/^\s*\/\/.*$/gm, '');
  for (const banned of ['fetch(', 'XMLHttpRequest', 'sendBeacon', 'WebSocket', 'localStorage', 'sessionStorage', 'document.cookie', 'location.replace', 'location.assign', 'innerHTML']) {
    assert.ok(!source.includes(banned), banned);
  }
});
