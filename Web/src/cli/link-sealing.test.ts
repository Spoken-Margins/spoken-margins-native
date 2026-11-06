import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { PART, keyFromFragment, openPart } from '../packet/share-link.ts';
import { sealPacket, sealPart, uploadForm } from './link-sealing.ts';

const vector = JSON.parse(readFileSync(new URL('../../../research/B4/contracts/fixtures/share-link-sealing-vector.json', import.meta.url), 'utf8'));
const bytes = (base64: string): Uint8Array => Uint8Array.from(Buffer.from(base64, 'base64'));
const fromHex = (hex: string): Uint8Array => Uint8Array.from(Buffer.from(hex, 'hex'));

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
