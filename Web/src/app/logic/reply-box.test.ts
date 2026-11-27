import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { keyFromFragment } from '../../packet/share-link.ts';
import { sealPart } from '../../cli/link-sealing.ts';
import {
  LINK_PART, REPLY_FETCH_CEILING_MS, fetchReplyBox, fetchReplyOutcome, openReplyPart, postAnswer, readReplyBoxRow, readReplyPart, replyBoxRowValue, replyFailureFor,
  sealAnswer, type ReplyBox,
} from './reply-box.ts';

const repo = new URL('../../../../', import.meta.url);
const vector = JSON.parse(readFileSync(new URL('research/B4/contracts/fixtures/reply-box-vector.json', repo), 'utf8'));
const b64 = (value: string): Uint8Array => Uint8Array.from(Buffer.from(value, 'base64'));
const hex = (value: string): Uint8Array => Uint8Array.from(Buffer.from(value, 'hex'));
const linkKey = keyFromFragment(vector.linkKeyFragment) as Uint8Array;
const seal = hex(vector.sealKeyHex);
const ORIGIN = 'https://links.example';
const link = { origin: ORIGIN, id: 'AbCdEf123456', key: linkKey };
const box: ReplyBox = { origin: ORIGIN, linkId: link.id, box: vector.id, post: vector.postProof, seal };

/** A fetch that answers every request with `status` and `body`, and records what was asked. */
function server(status: number, body: BodyInit | null = null, headers: Record<string, string> = {}) {
  const asked: { url: string; init: RequestInit | undefined }[] = [];
  const fetchImpl = (async (url: string | URL | Request, init?: RequestInit) => {
    asked.push({ url: String(url), init });
    return new Response(body, { status, headers });
  }) as typeof fetch;
  return { asked, fetchImpl };
}

test('the reply part number is 4, beside preview 1 and packet 2', () => {
  assert.deepEqual({ ...LINK_PART }, { preview: 1, packet: 2, reply: 4 });
  assert.equal(vector.replyPart.part, LINK_PART.reply);
  assert.equal(vector.answer.part, LINK_PART.packet);
});

/** The vector's reply-part plaintext sealed here as part 4 under the link key, with the vector's nonce. */
const sealedHere = (): Promise<Uint8Array> =>
  sealPart(new TextEncoder().encode(vector.replyPart.plaintext), LINK_PART.reply, linkKey, hex(vector.replyPart.nonceHex));

test('a reply part sealed as part 4 under the link key, header-only additional data, opens to its box', async () => {
  const sealed = await sealedHere();
  assert.equal(Buffer.from(sealed.subarray(0, 8)).toString('hex'), vector.replyPart.aadHex);
  const opened = await openReplyPart(sealed, linkKey);
  assert.ok(opened);
  assert.equal(opened.box, vector.id);
  assert.equal(opened.post, vector.postProof);
  assert.deepEqual(opened.seal, seal);
});

test('the vector’s reply part opens under the link key to its box, post proof and seal key', async () => {
  const opened = await openReplyPart(b64(vector.replyPart.sealedBase64), linkKey);
  assert.ok(opened);
  assert.equal(opened.box, vector.id);
  assert.equal(opened.post, vector.postProof);
  assert.deepEqual(opened.seal, seal);
  // The upload header carries the same sealed bytes.
  assert.deepEqual(b64(vector.uploadHeaders['X-SM-Reply-Part']), b64(vector.replyPart.sealedBase64));
});

test('a reply part that is damaged, under another key, or the wrong part opens to nothing', async () => {
  const sealed = await sealedHere();
  const flipped = sealed.slice();
  flipped[30] ^= 1;
  assert.equal(await openReplyPart(flipped, linkKey), undefined);
  assert.equal(await openReplyPart(sealed.subarray(0, 20), linkKey), undefined);
  assert.equal(await openReplyPart(sealed, new Uint8Array(32)), undefined);
  // The same plaintext sealed as the packet part (2) is not a reply part: the header is the additional data.
  const asPacket = await sealPart(new TextEncoder().encode(vector.replyPart.plaintext), LINK_PART.packet, linkKey);
  assert.equal(await openReplyPart(asPacket, linkKey), undefined);
});

test('the opened JSON must be version 1 in the wire shapes; unknown keys are ignored', () => {
  const read = (value: unknown) => readReplyPart(new TextEncoder().encode(JSON.stringify(value)));
  const good = JSON.parse(vector.replyPart.plaintext);
  assert.ok(read(good));
  assert.ok(read({ ...good, later: 'a field a newer phone adds' }));
  const rows: Array<[string, unknown]> = [
    ['version 2', { ...good, v: 2 }],
    ['no version', { box: good.box, post: good.post, seal: good.seal }],
    ['upper-case box', { ...good, box: good.box.toUpperCase() }],
    ['short box', { ...good, box: good.box.slice(2) }],
    ['short post proof', { ...good, post: good.post.slice(1) }],
    ['seal with padding', { ...good, seal: `${good.seal}=` }],
    ['seal of 31 bytes', { ...good, seal: good.seal.slice(0, 42) }],
    ['seal in standard base64', { ...good, seal: good.seal.replace(/-/g, '+').replace(/_/g, '/') }],
    ['an array', [good]],
    ['null', null],
  ];
  for (const [name, value] of rows) assert.equal(read(value), undefined, name);
  assert.equal(readReplyPart(new Uint8Array([0xff, 0xfe])), undefined, 'not UTF-8');
});

test('sealAnswer with the vector’s nonce gives the vector’s answer, byte for byte', async () => {
  const sealed = await sealAnswer(b64(vector.answer.plaintextBase64), box, hex(vector.answer.nonceHex));
  assert.equal(Buffer.from(sealed).toString('base64'), vector.answer.sealedBase64);
  // The additional data is the header then the 16 box id bytes, as the vector says.
  assert.equal(Buffer.from([...sealed.subarray(0, 8), ...hex(vector.id)]).toString('hex'), vector.answer.aadHex);
});

test('sealAnswer draws a fresh nonce each time and refuses a bad box or key', async () => {
  const packet = b64(vector.answer.plaintextBase64);
  const one = await sealAnswer(packet, box);
  const two = await sealAnswer(packet, box);
  assert.notDeepEqual(one.subarray(8, 20), two.subarray(8, 20));
  await assert.rejects(sealAnswer(packet, { ...box, box: 'not-hex' }));
  await assert.rejects(sealAnswer(packet, { ...box, seal: new Uint8Array(16) }));
});

test('fetchReplyBox asks the link’s own server, with no credentials, and opens the part', async () => {
  const { asked, fetchImpl } = server(200, (await sealedHere()) as BodyInit);
  const got = await fetchReplyBox(link, fetchImpl);
  assert.ok(got);
  assert.deepEqual({ ...got, seal: [...got.seal] }, { ...box, seal: [...seal] });
  assert.equal(asked.length, 1);
  assert.equal(asked[0].url, `${ORIGIN}/l/AbCdEf123456/reply`);
  assert.equal(asked[0].init?.credentials, 'omit');
  assert.equal(asked[0].init?.referrerPolicy, 'no-referrer');
  assert.ok(!asked[0].url.includes(vector.linkKeyFragment), 'the key never leaves the browser');
});

test('fetchReplyBox is "no reply part" for 404, an expired link, a switched-off server, offline and damage', async () => {
  for (const status of [404, 410, 503, 500]) {
    assert.equal(await fetchReplyBox(link, server(status, JSON.stringify({ error: 'x' })).fetchImpl), undefined, String(status));
  }
  const offline = (async () => {
    throw new TypeError('Failed to fetch');
  }) as typeof fetch;
  assert.equal(await fetchReplyBox(link, offline), undefined);
  assert.equal(await fetchReplyBox(link, server(200, new Uint8Array(40) as BodyInit).fetchImpl), undefined);
});

test('a reply fetch that hasn’t answered by the ceiling counts as none, and is aborted', async () => {
  assert.equal(REPLY_FETCH_CEILING_MS, 5_000);
  let aborted = false;
  const hanging = ((_url: string, init?: RequestInit) =>
    new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener('abort', () => {
        aborted = true;
        reject(new DOMException('aborted', 'AbortError'));
      });
    })) as unknown as typeof fetch;
  assert.equal(await fetchReplyBox(link, hanging, 20), undefined);
  assert.equal(aborted, true);
});

test('postAnswer posts the sealed answer raw to the box with the post proof, and any 2xx is sent', async () => {
  const { asked, fetchImpl } = server(201, JSON.stringify({ seq: 1 }), { 'content-type': 'application/json' });
  const packet = b64(vector.answer.plaintextBase64);
  assert.deepEqual(await postAnswer(box, packet, fetchImpl), { kind: 'sent' });
  assert.equal(asked.length, 1);
  assert.equal(asked[0].url, `${ORIGIN}/api/v1/clubs/${vector.id}/posts`);
  assert.equal(asked[0].init?.method, 'POST');
  assert.equal(asked[0].init?.credentials, 'omit');
  const headers = asked[0].init?.headers as Record<string, string>;
  assert.equal(headers.Authorization, `Bearer ${vector.postProof}`);
  assert.equal(headers['Content-Type'], 'application/octet-stream');
  // The body opens under the seal key with the box id as additional data, to the packet's bytes.
  const body = asked[0].init?.body as Uint8Array;
  const key = await crypto.subtle.importKey('raw', seal, 'AES-GCM', false, ['decrypt']);
  const opened = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: body.subarray(8, 20), additionalData: new Uint8Array([...body.subarray(0, 8), ...hex(vector.id)]) },
    key,
    body.subarray(20),
  );
  assert.deepEqual(new Uint8Array(opened), packet);
  // A 200 or a 204 with no body is sent too: the body's fields are never relied on.
  assert.deepEqual(await postAnswer(box, packet, server(200).fetchImpl), { kind: 'sent' });
  assert.deepEqual(await postAnswer(box, packet, server(204).fetchImpl), { kind: 'sent' });
});

test('each server answer lands on Screen B’s row', async () => {
  const rows: Array<[number, string | undefined, string]> = [
    [410, 'expired_or_removed', 'ended'],
    [409, 'club_full', 'ended'],
    [404, 'not_found', 'ended'],
    [503, 'full', 'ended'],
    [503, 'disabled', 'ended'],
    [413, 'too_large', 'too-big'],
    [429, 'rate_limited', 'retry'],
    [503, 'busy', 'retry'],
    [503, undefined, 'retry'],
    [500, undefined, 'retry'],
    [400, 'bad_request', 'retry'],
  ];
  const packet = new Uint8Array([1, 2, 3]);
  for (const [status, code, row] of rows) {
    assert.equal(replyFailureFor(status, code), row, `${status} ${code}`);
    const body = code === undefined ? 'not json' : JSON.stringify({ error: code });
    assert.deepEqual(await postAnswer(box, packet, server(status, body).fetchImpl), { kind: 'failed', failure: row }, `${status} ${code} through postAnswer`);
  }
  const offline = (async () => {
    throw new TypeError('Failed to fetch');
  }) as typeof fetch;
  assert.deepEqual(await postAnswer(box, packet, offline), { kind: 'failed', failure: 'retry' }, 'a network error');
  const hanging = (() => new Promise<Response>(() => {})) as unknown as typeof fetch;
  assert.deepEqual(await postAnswer(box, packet, hanging, 20), { kind: 'failed', failure: 'retry' }, 'no answer at all');
});

test('#5419: a kept reply box reads back as written, with no link key in it', () => {
  const digest = 'a'.repeat(64);
  const value = replyBoxRowValue({ box, sender: 'Sam', packetDigest: digest });
  // Plain JSON values only, so any browser's store keeps it; the link key is never among them.
  assert.deepEqual(JSON.parse(JSON.stringify(value)), value);
  assert.ok(!JSON.stringify(value).includes(vector.linkKeyFragment));
  assert.deepEqual(Object.keys(value).sort(), ['box', 'linkId', 'origin', 'packetDigest', 'post', 'seal', 'sender', 'v']);
  const read = readReplyBoxRow(value);
  assert.ok(read);
  assert.deepEqual({ ...read.box, seal: [...read.box.seal] }, { ...box, seal: [...seal] });
  assert.equal(read.sender, 'Sam');
  assert.equal(read.packetDigest, digest);
  // No sender name: none is written, and none reads back.
  const unnamed = replyBoxRowValue({ box, sender: undefined, packetDigest: digest });
  assert.equal(Object.hasOwn(unnamed, 'sender'), false);
  assert.equal(readReplyBoxRow(unnamed)?.sender, undefined);
});

test('#5419: a kept reply box row that isn\'t one reads as none', () => {
  const good = replyBoxRowValue({ box, sender: 'Sam', packetDigest: 'a'.repeat(64) });
  const rows: unknown[] = [
    undefined, null, 'box', [], {},
    { ...good, v: 2 },
    { ...good, origin: 'ftp://links.example' },
    { ...good, origin: 'https://links.example/path' },
    { ...good, origin: 'not a url' },
    { ...good, linkId: '' },
    { ...good, box: 'A'.repeat(32) },
    { ...good, post: 'f'.repeat(63) },
    { ...good, seal: 'short' },
    { ...good, seal: 5 },
    { ...good, packetDigest: '' },
    { ...good, sender: 7 },
  ];
  for (const row of rows) assert.equal(readReplyBoxRow(row), undefined, JSON.stringify(row));
  assert.ok(readReplyBoxRow(good));
});

test('#5419: fetchReplyOutcome says "gone" only when the link\'s server answers 404 or 410', async () => {
  for (const status of [404, 410]) {
    assert.deepEqual(await fetchReplyOutcome(link, server(status, JSON.stringify({ error: 'x' })).fetchImpl), { kind: 'gone' }, String(status));
  }
  // Anything that may pass is "unreachable", so a kept box still serves.
  for (const status of [500, 502, 503, 429, 401]) {
    assert.deepEqual(await fetchReplyOutcome(link, server(status, JSON.stringify({ error: 'x' })).fetchImpl), { kind: 'unreachable' }, String(status));
  }
  const offline = (async () => {
    throw new TypeError('Failed to fetch');
  }) as typeof fetch;
  assert.deepEqual(await fetchReplyOutcome(link, offline), { kind: 'unreachable' });
  assert.deepEqual(await fetchReplyOutcome(link, server(200, new Uint8Array(40) as BodyInit).fetchImpl), { kind: 'unreachable' });
  const hanging = ((_url: string | URL | Request, init?: RequestInit) =>
    new Promise<Response>((_resolve, reject) => init?.signal?.addEventListener('abort', () => reject(new Error('aborted'))))) as typeof fetch;
  assert.deepEqual(await fetchReplyOutcome(link, hanging, 20), { kind: 'unreachable' });
  const opened = await fetchReplyOutcome(link, server(200, (await sealedHere()) as BodyInit).fetchImpl);
  assert.equal(opened.kind, 'box');
  assert.equal(opened.kind === 'box' && opened.box.box, vector.id);
});
