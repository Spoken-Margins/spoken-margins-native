import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { MAX_SEALED_PACKET_BYTES, makeShareLink } from './make-share-link.ts';
import { PART, keyFromFragment, openPart } from '../packet/share-link.ts';

const fixture = (name: string): Uint8Array =>
  new Uint8Array(readFileSync(new URL(`../../../Contracts/fixtures/web-packets/${name}`, import.meta.url)));

/** A stand-in link server that keeps what it was sent, answering as research/B4/server does. */
function fakeServer() {
  const sent: { url: string; parts: Map<string, Uint8Array> }[] = [];
  const fetchFake = (async (url: URL | string, init?: RequestInit) => {
    const parts = new Map<string, Uint8Array>();
    for (const [name, value] of (init?.body as FormData).entries()) parts.set(name, new Uint8Array(await (value as Blob).arrayBuffer()));
    sent.push({ url: String(url), parts });
    return new Response(JSON.stringify({ id: 'abc123', path: '/l/abc123', expiresAt: '2026-12-02T00:00:00Z' }), { status: 201 });
  }) as typeof fetch;
  return { sent, fetchFake };
}

test('a link made on the Mac opens to the exact packet, and the key never reaches the server', async () => {
  const packet = fixture('web-voice.spokenmargins');
  const { sent, fetchFake } = fakeServer();
  const made = await makeShareLink(packet, { fileName: 'web-voice.spokenmargins', fetch: fetchFake });

  assert.equal(sent.length, 1);
  assert.equal(sent[0]?.url, 'https://spokenmargins.com/api/v1/links');
  assert.deepEqual([...(sent[0]?.parts.keys() ?? [])], ['preview', 'packet']);
  const [origin, fragment] = made.url.split('#') as [string, string];
  assert.equal(origin, 'https://spokenmargins.com/l/abc123');
  assert.ok(!sent[0]?.url.includes(fragment));

  const key = keyFromFragment(fragment) as Uint8Array;
  const opened = await openPart(sent[0]?.parts.get('packet') as Uint8Array, PART.packet, key);
  assert.deepEqual(opened, packet);
  const preview = JSON.parse(new TextDecoder().decode(await openPart(sent[0]?.parts.get('preview') as Uint8Array, PART.preview, key)));
  assert.equal(preview.schema, 'spokenmargins.link-preview.v1');
  assert.ok(preview.margins.length > 0);
});

test('a packet whose Margins only have placeholder words still makes a link', async () => {
  const { fetchFake } = fakeServer();
  const made = await makeShareLink(fixture('web-voice-placeholder.spokenmargins'), { fileName: 'p.spokenmargins', fetch: fetchFake });
  assert.match(made.preview.margins[0]?.text ?? '', /Voice Margin at/);
});

test('refuses a file that is not a .spokenmargins packet, before uploading', async () => {
  const { sent, fetchFake } = fakeServer();
  await assert.rejects(makeShareLink(fixture('web-written.spokenmargins'), { fileName: 'notes.zip', fetch: fetchFake }));
  assert.equal(sent.length, 0);
});

test('refuses plain http to anything but this machine', async () => {
  const { sent, fetchFake } = fakeServer();
  await assert.rejects(
    makeShareLink(fixture('web-written.spokenmargins'), { fileName: 'w.spokenmargins', server: 'http://spokenmargins.com', fetch: fetchFake }),
    /https only/,
  );
  assert.equal(sent.length, 0);
});

test('the size cap matches the link server', () => {
  const store = readFileSync(new URL('../../../research/B4/server/internal/links/store.go', import.meta.url), 'utf8');
  assert.match(store, /MaxPacketBytes\s*=\s*20 << 20/);
  assert.equal(MAX_SEALED_PACKET_BYTES, 20 << 20);
});

test('an article packet from the iPhone makes a link from its text Margins, without quoting the source', async () => {
  const packet = new Uint8Array(readFileSync(new URL('../../../Contracts/examples/packets/article-reference.spokenmargins', import.meta.url)));
  const { fetchFake } = fakeServer();
  const made = await makeShareLink(packet, { fileName: 'article-reference.spokenmargins', fetch: fetchFake });
  assert.ok(made.preview.margins.length > 0);
  for (const margin of made.preview.margins) assert.deepEqual(Object.keys(margin), ['text']);
});
