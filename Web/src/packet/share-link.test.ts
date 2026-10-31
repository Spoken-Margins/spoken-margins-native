import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { PART, SHARE_LINKS_ENABLED, ShareLinksOffError, keyFromFragment, openPart, sealPacket, sealPart, uploadForm, uploadLink } from './share-link.ts';

const vector = JSON.parse(readFileSync(new URL('../../../research/B4/contracts/fixtures/share-link-sealing-vector.json', import.meta.url), 'utf8'));
const bytes = (base64: string): Uint8Array => Uint8Array.from(Buffer.from(base64, 'base64'));
const fromHex = (hex: string): Uint8Array => Uint8Array.from(Buffer.from(hex, 'hex'));

test('share links stay off: turning them on is a reviewed build, never a switch (owner, 2026-10-17 and 2026-10-20)', () => {
  assert.equal(SHARE_LINKS_ENABLED, false);
});

test('uploadLink refuses while off, before sealing or sending anything', async () => {
  let fetched = false;
  const fetchSpy = (async () => {
    fetched = true;
    return new Response('{}');
  }) as typeof fetch;
  await assert.rejects(
    uploadLink(new Uint8Array([1]), { schema: 'spokenmargins.link-preview.v1', source: { title: 't' }, margins: [] }, { server: 'https://example.com', fetch: fetchSpy }),
    ShareLinksOffError,
  );
  assert.equal(fetched, false);
});

test('sealing matches the shared test vector byte for byte', async () => {
  const key = keyFromFragment(vector.keyFragment) as Uint8Array;
  for (const name of ['preview', 'packet'] as const) {
    const entry = vector[name];
    const sealed = await sealPart(bytes(entry.plaintextBase64), entry.part, key, fromHex(entry.nonceHex));
    assert.equal(Buffer.from(sealed).toString('base64'), entry.sealedBase64, name);
  }
  const link = await sealPacket(bytes(vector.packet.plaintextBase64), bytes(vector.preview.plaintextBase64), {
    key, previewNonce: fromHex(vector.preview.nonceHex), packetNonce: fromHex(vector.packet.nonceHex),
  });
  assert.equal(link.keyFragment, vector.keyFragment);
  assert.equal(Buffer.from(link.packet).toString('base64'), vector.packet.sealedBase64);
});

test('the landing page opens what this seals, and a fresh key every time', async () => {
  const packet = new TextEncoder().encode('a packet');
  const a = await sealPacket(packet, { schema: 'spokenmargins.link-preview.v1', source: { title: 'Episode' }, margins: [{ text: 'Hi' }] });
  const b = await sealPacket(packet, new Uint8Array([1]));
  assert.notEqual(a.keyFragment, b.keyFragment);
  const key = keyFromFragment(`#${a.keyFragment}`);
  assert.deepEqual(new Uint8Array(await openPart(a.packet, PART.packet, key)), packet);
  const preview = JSON.parse(new TextDecoder().decode(await openPart(a.preview, PART.preview, key)));
  assert.equal(preview.source.title, 'Episode');
  await assert.rejects(openPart(a.packet, PART.preview, key));
});

test('the upload form has exactly the two parts the server takes', () => {
  const form = uploadForm({ keyFragment: 'k', preview: new Uint8Array([1]), packet: new Uint8Array([2]) });
  assert.deepEqual([...form.keys()], ['preview', 'packet']);
});
