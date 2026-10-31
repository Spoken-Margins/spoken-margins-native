// The browser half of share-link sealing (#805), checked against the vector the Swift tests use.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { parseHTML } from 'linkedom';
import {
  DAMAGED_MESSAGE,
  DamagedLinkError,
  MAX_AFTER_CHARACTERS,
  MAX_BEFORE_CHARACTERS,
  PART,
  checkPreview,
  keyFromFragment,
  openPart,
  openPreview,
  safeSourceURL,
} from './share-link-open.mjs';
import { EXPIRED_MESSAGE, OFFLINE_MESSAGE, SERVER_MESSAGE, showSharedMargins } from './share-link-page.mjs';

const vector = JSON.parse(
  readFileSync(new URL('../../../contracts/fixtures/share-link-sealing-vector.json', import.meta.url), 'utf8'),
);
const fromBase64 = (value) => new Uint8Array(Buffer.from(value, 'base64'));
const key = keyFromFragment(vector.keyFragment);
const sealedPreview = fromBase64(vector.preview.sealedBase64);
const sealedPacket = fromBase64(vector.packet.sealedBase64);
const damaged = (error) => error instanceof DamagedLinkError && error.message === DAMAGED_MESSAGE;

test('the shared vector opens to the same bytes the phone sealed', async () => {
  assert.equal(key.length, 32);
  assert.deepEqual(await openPart(sealedPreview, PART.preview, key), fromBase64(vector.preview.plaintextBase64));
  assert.deepEqual(await openPart(sealedPacket, PART.packet, key), fromBase64(vector.packet.plaintextBase64));
});

test('the landing page reads the key from location.hash and parses the preview', async () => {
  const hash = new URL(vector.linkURL).hash;
  const preview = await openPreview(sealedPreview, hash);
  assert.equal(preview.schema, 'spokenmargins.link-preview.v1');
  assert.equal(preview.source.title, 'Café notes on the Fourier transform');
  assert.equal(preview.margins[0].text, 'This is the part I wanted you to hear 🎧');
});

test('a missing or malformed key fails plainly', async () => {
  for (const hash of ['', '#', `#${vector.keyFragment.slice(0, -3)}`, `#${vector.keyFragment}AAAA`, '#not a key', undefined]) {
    await assert.rejects(openPreview(sealedPreview, hash), damaged, String(hash));
  }
  assert.deepEqual(keyFromFragment(`#${vector.keyFragment}=`), key);
  assert.equal(keyFromFragment(`#+${vector.keyFragment.slice(1)}`), null);
});

test('the wrong key, a tampered byte or a truncated blob fails plainly', async () => {
  const wrongKey = key.slice();
  wrongKey[0] ^= 1;
  await assert.rejects(openPart(sealedPacket, PART.packet, wrongKey), damaged);

  for (const index of [0, 7, 8, 20, Math.floor(sealedPacket.length / 2), sealedPacket.length - 1]) {
    const tampered = sealedPacket.slice();
    tampered[index] ^= 1;
    await assert.rejects(openPart(tampered, PART.packet, key), damaged, `byte ${index}`);
  }
  for (const length of [0, 8, 35, 36, sealedPacket.length - 1]) {
    await assert.rejects(openPart(sealedPacket.slice(0, length), PART.packet, key), damaged, `length ${length}`);
  }
});

test('a packet cannot be passed off as the preview', async () => {
  await assert.rejects(openPart(sealedPacket, PART.preview, key), damaged);
  const relabelled = sealedPacket.slice();
  relabelled[7] = PART.preview;
  await assert.rejects(openPart(relabelled, PART.preview, key), damaged);
});

// A link that decrypts cleanly but holds something that is not a preview: the
// sender's app or someone holding the key sealed it, so the tag is valid and
// only the plaintext is wrong. The page must still show the one plain error,
// not a SyntaxError or a preview with stray replacement characters.
async function seal(plaintext, part, keyBytes) {
  const header = Uint8Array.from([0x53, 0x4d, 0x4c, 0x49, 0x4e, 0x4b, 1, part]);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const aesKey = await crypto.subtle.importKey('raw', keyBytes, { name: 'AES-GCM' }, false, ['encrypt']);
  const body = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce, additionalData: header, tagLength: 128 }, aesKey, plaintext));
  return Uint8Array.from([...header, ...nonce, ...body]);
}

test('a correctly sealed preview that is not valid JSON or not valid UTF-8 fails plainly', async () => {
  const text = (value) => new TextEncoder().encode(value);
  const hash = `#${vector.keyFragment}`;

  // Control: the same sealing code with a good preview opens.
  const good = await seal(text('{"schema":"spokenmargins.link-preview.v1"}'), PART.preview, key);
  assert.deepEqual(await openPreview(good, hash), { schema: 'spokenmargins.link-preview.v1' });

  const cases = {
    'not JSON': text('not json'),
    'empty': new Uint8Array(),
    'truncated JSON': text('{"schema":"spokenmargins.link-pre'),
    // Valid JSON once the invalid byte becomes U+FFFD, so only a strict UTF-8 decode refuses it.
    'invalid UTF-8 inside a string': Uint8Array.from([...text('{"schema":"x'), 0xff, ...text('"}')]),
    'only invalid UTF-8': Uint8Array.from([0xff, 0xfe]),
  };
  for (const [name, plaintext] of Object.entries(cases)) {
    const sealed = await seal(plaintext, PART.preview, key);
    await assert.rejects(openPreview(sealed, hash), damaged, name);
  }
});

// The server can't read the sealed preview (#805), so the page checks what the server's ParsePreview
// used to: a title, at least one Margin, and the excerpt ceilings (#2237), in code points.
const vectorPreview = () => JSON.parse(Buffer.from(vector.preview.plaintextBase64, 'base64').toString('utf8'));

test('the vector preview passes the page check, which keeps only the shown fields', () => {
  assert.deepEqual(checkPreview(vectorPreview()), {
    source: { title: 'Café notes on the Fourier transform', show: 'Signals & Noise', url: '' },
    margins: [{ text: 'This is the part I wanted you to hear 🎧', before: 'the transform', after: 'of a square wave' }],
  });
});

test('excerpts are held to their ceilings on each side, in code points', () => {
  for (const [side, max] of [['before', MAX_BEFORE_CHARACTERS], ['after', MAX_AFTER_CHARACTERS]]) {
    for (const [name, text, valid] of [
      ['empty', '', true], ['whitespace', ' \t\n', true], ['punctuation', '—.!?', true], ['case', 'Aa', true],
      ['composed', 'café', true], ['decomposed', 'café', true],
      ['at the cap, ASCII', 'x'.repeat(max), true], ['at the cap, Unicode', '🎧'.repeat(max), true],
      ['over the cap, ASCII', 'x'.repeat(max + 1), false], ['over the cap, Unicode', '🎧'.repeat(max + 1), false],
      ['very long', 'x'.repeat(16000), false],
    ]) {
      const preview = vectorPreview();
      preview.margins[0][side] = text;
      if (valid) assert.equal(checkPreview(preview).margins[0][side], text, `${side}/${name}`);
      else assert.throws(() => checkPreview(preview), damaged, `${side}/${name}`);
    }
  }
  // The caps differ: 121 characters fit before a Margin, not after it.
  const preview = vectorPreview();
  preview.margins[0].before = 'x'.repeat(MAX_AFTER_CHARACTERS + 1);
  preview.margins[0].after = '';
  assert.doesNotThrow(() => checkPreview(preview));
  preview.margins[0].after = 'x'.repeat(MAX_AFTER_CHARACTERS + 1);
  assert.throws(() => checkPreview(preview), damaged);
});

test('a preview without a title or a Margin, or with odd types, fails plainly', () => {
  const variants = {
    null: () => null,
    array: () => [],
    'no source': (p) => { delete p.source; return p; },
    'blank title': (p) => { p.source.title = ' \n'; return p; },
    'numeric title': (p) => { p.source.title = 7; return p; },
    'object show': (p) => { p.source.show = {}; return p; },
    'no margins': (p) => { p.margins = []; return p; },
    'margins not a list': (p) => { p.margins = { text: 'x' }; return p; },
    'margin without text': (p) => { delete p.margins[0].text; return p; },
    'numeric before': (p) => { p.margins[0].before = 3; return p; },
    'null margin': (p) => { p.margins = [null]; return p; },
  };
  for (const [name, change] of Object.entries(variants)) {
    assert.throws(() => checkPreview(change(vectorPreview())), damaged, name);
  }
  const extra = vectorPreview();
  extra.unknown = true;
  extra.margins[0].unknown = '<b>';
  assert.doesNotThrow(() => checkPreview(extra));
});

test('the source link is left out when it could disclose a private URL', () => {
  for (const [url, safe] of [
    ['https://example.org/episode', true], ['http://example.org/a', true], ['HTTPS://example.org/A', true],
    ['https://other.example/episode', true], ['https://examp1e.org/episode', true], ['https://example.org/caf%C3%A9', true],
    ['https://example.org/episode?token=PRIVATE', false], ['https://example.org/episode?', false],
    ['https://PRIVATE:secret@example.org/episode', false], ['https://PRIVATE@example.org/episode', false],
    ['https://example.org/episode#PRIVATE', false], ['javascript:alert(1)', false], ['//example.org/a', false],
    ['', false], [' https://example.org/a', false], ['https://example.org/\nPRIVATE', false], ['https://', false],
    ['https://example.org/%zz', false], ['data:text/html,hi', false], [undefined, false],
  ]) {
    assert.equal(safeSourceURL(url) !== '', safe, String(url));
  }
});

// The page module against a DOM, with the shell the server renders (links.Render).
const LINK_ID = 'ab'.repeat(16);
function shell() {
  const { document } = parseHTML(
    `<!doctype html><html><body><section id="margins" data-link="${LINK_ID}"><p id="status" role="status"></p></section></body></html>`,
  );
  return document;
}
const answer = (status, bytes = new Uint8Array()) => ({
  status,
  arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
});
const linkHash = `#${vector.keyFragment}`;
const sealJSON = (value) => seal(new TextEncoder().encode(JSON.stringify(value)), PART.preview, key);

test('the page opens the vector preview from the server and shows it as text', async () => {
  const document = shell();
  const asked = [];
  const shown = await showSharedMargins(document, linkHash, async (path) => {
    asked.push(path);
    return answer(200, sealedPreview);
  });
  assert.equal(shown, '');
  assert.deepEqual(asked, [`/l/${LINK_ID}/preview`]);
  const article = document.querySelector('article');
  assert.match(article.textContent, /This is the part I wanted you to hear 🎧/);
  assert.match(article.textContent, /Café notes on the Fourier transform/);
  assert.match(article.textContent, /Signals & Noise/);
  assert.match(article.textContent, /Quotation from the source · before this Margin/);
  assert.equal(document.querySelector('a'), null, 'the vector has no source URL');
  assert.equal(document.getElementById('status').textContent, '');
});

test('HTML in a sealed preview is shown as text, and only a safe source URL is linked', async () => {
  const preview = {
    source: { title: 'A source <title>', show: 'A show & name', url: 'https://example.org/episode?token=PRIVATE' },
    margins: [{ text: 'My <script>alert(1)</script>', before: 'Before <img src=x>', after: 'After & <b>text</b>' }],
  };
  const document = shell();
  const sealed = await sealJSON(preview);
  await showSharedMargins(document, linkHash, async () => answer(200, sealed));
  const section = document.getElementById('margins');
  assert.equal(section.querySelector('script, img, b'), null);
  assert.match(section.textContent, /My <script>alert\(1\)<\/script>/);
  assert.match(section.textContent, /A source <title>/);
  assert.equal(section.querySelector('a'), null);
  assert.doesNotMatch(section.innerHTML, /PRIVATE/);

  preview.source.url = 'https://example.org/episode';
  const second = shell();
  const safe = await sealJSON(preview);
  await showSharedMargins(second, linkHash, async () => answer(200, safe));
  const link = second.querySelector('a');
  assert.equal(link.getAttribute('href'), 'https://example.org/episode');
  assert.equal(link.getAttribute('rel'), 'noreferrer noopener');
});

test('the page says plainly when the link is missing its key, expired, damaged or unreachable', async () => {
  const never = async () => assert.fail('fetched without a usable key');
  for (const missing of ['', '#', '#not a key', `#${vector.keyFragment.slice(0, -3)}`]) {
    assert.equal(await showSharedMargins(shell(), missing, never), DAMAGED_MESSAGE, missing);
  }
  const overCap = vectorPreview();
  overCap.margins[0].after = 'x'.repeat(MAX_AFTER_CHARACTERS + 1);
  const overCapSealed = await sealJSON(overCap);
  const tampered = sealedPreview.slice();
  tampered[30] ^= 1;
  for (const [name, respond, message] of [
    ['expired', async () => answer(410), EXPIRED_MESSAGE],
    ['unknown', async () => answer(404), EXPIRED_MESSAGE],
    ['rate limited', async () => answer(429), SERVER_MESSAGE],
    ['switched off', async () => answer(503), SERVER_MESSAGE],
    ['offline', async () => { throw new TypeError('Failed to fetch'); }, OFFLINE_MESSAGE],
    ['tampered', async () => answer(200, tampered), DAMAGED_MESSAGE],
    ['the packet served as the preview', async () => answer(200, sealedPacket), DAMAGED_MESSAGE],
    ['an excerpt over its ceiling', async () => answer(200, overCapSealed), DAMAGED_MESSAGE],
  ]) {
    const document = shell();
    assert.equal(await showSharedMargins(document, linkHash, respond), message, name);
    assert.equal(document.getElementById('status').textContent, message, name);
    assert.equal(document.querySelector('article'), null, name);
  }
});
