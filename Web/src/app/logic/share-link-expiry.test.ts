import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { linkFooterText, openSharedPacketWithExpiry, parseShareLink, type ShareLinkRef } from './share-link.ts';

const repo = new URL('../../../../', import.meta.url);
const vector = JSON.parse(readFileSync(new URL('research/B4/contracts/fixtures/share-link-sealing-vector.json', repo), 'utf8'));
const b64 = (value: string): Uint8Array => Uint8Array.from(Buffer.from(value, 'base64'));

function linkFor(url: string): ShareLinkRef {
  const parsed = parseShareLink(url);
  assert.equal(parsed.kind, 'link', url);
  return (parsed as { kind: 'link'; link: ShareLinkRef }).link;
}

test('the footer says the real expiry day when the server sent one (#2168)', () => {
  const now = new Date('2026-11-06T10:00:00Z');
  assert.equal(linkFooterText('2026-12-06', now, 'en-GB'), 'This link works until 6 December.');
  assert.equal(linkFooterText('2026-12-06', now, 'en-US'), 'This link works until December 6.');
  // The UTC day is kept whatever zone the browser is in.
  assert.equal(linkFooterText('2026-12-31', new Date('2026-12-30T23:00:00Z'), 'en-GB'), 'This link works until 31 December.');
});

test('a date in another year carries the year', () => {
  const now = new Date('2026-12-20T10:00:00Z');
  assert.equal(linkFooterText('2027-01-04', now, 'en-GB'), 'This link works until 4 January 2027.');
});

test('with no usable expiry the footer keeps the 30-day words exactly', () => {
  const now = new Date('2026-11-06T10:00:00Z');
  for (const bad of [undefined, '', 'soon', '2026-12-06T10:00:00Z', '2026-13-01', '2026-02-31', '6 December 2026', ' 2026-12-06']) {
    assert.equal(linkFooterText(bad, now, 'en-GB'), 'This link works for 30 days.', String(bad));
  }
});

test('opening a link reports the expiry header the server sent, and nothing when it is absent', async () => {
  const link = linkFor(vector.linkURL);
  const sealed = b64(vector.packet.sealedBase64);
  const withHeader = (async () => new Response(sealed as BodyInit, { status: 200, headers: { 'X-SM-Link-Expires': '2026-12-06' } })) as typeof fetch;
  const got = await openSharedPacketWithExpiry(link, withHeader);
  assert.equal(got.expires, '2026-12-06');
  assert.deepEqual(got.bytes, b64(vector.packet.plaintextBase64));
  const without = (async () => new Response(sealed as BodyInit, { status: 200 })) as typeof fetch;
  assert.equal((await openSharedPacketWithExpiry(link, without)).expires, undefined);
});
