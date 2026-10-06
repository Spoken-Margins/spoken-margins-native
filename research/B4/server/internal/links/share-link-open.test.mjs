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
