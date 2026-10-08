// The browser half of share-link sealing (#805), checked against the vector the Swift tests use.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { DAMAGED_MESSAGE, DamagedLinkError, PART, keyFromFragment, openPart, openPreview } from './share-link-open.mjs';

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
