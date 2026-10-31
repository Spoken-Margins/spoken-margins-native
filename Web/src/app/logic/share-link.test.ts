import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import type { Episode, Margin, Show } from '../../shared/model.ts';
import { readPacket } from '../../packet/read.ts';
import { SHARE_LINKS_ENABLED, ShareLinkUploadError, ShareLinksOffError, sealPacket } from '../../packet/share-link.ts';
import { EXPIRED_MESSAGE, SERVER_MESSAGE } from '../../../../research/B4/server/internal/links/share-link-page.mjs';
import { LINK_MESSAGES, ShareLinkError, linkPreview, linkUploadMessage, openSharedPacket, parseShareLink, type ShareLinkRef } from './share-link.ts';

const repo = new URL('../../../../', import.meta.url);
const vector = JSON.parse(readFileSync(new URL('research/B4/contracts/fixtures/share-link-sealing-vector.json', repo), 'utf8'));
const b64 = (value: string): Uint8Array => Uint8Array.from(Buffer.from(value, 'base64'));
const KEY = vector.keyFragment as string;

/** A fetch that answers one path with `body` and `status`, and records what was asked. */
function server(body: Uint8Array | null, status = 200) {
  const asked: { url: string; init: RequestInit | undefined }[] = [];
  const fetchImpl = (async (url: string | URL | Request, init?: RequestInit) => {
    asked.push({ url: String(url), init });
    return new Response(body as BodyInit | null, { status });
  }) as typeof fetch;
  return { asked, fetchImpl };
}

function linkFor(url: string): ShareLinkRef {
  const parsed = parseShareLink(url);
  assert.equal(parsed.kind, 'link', url);
  return (parsed as { kind: 'link'; link: ShareLinkRef }).link;
}

test('the test vector’s link opens: the sealed packet decrypts to its plaintext, byte for byte', async () => {
  const link = linkFor(vector.linkURL);
  assert.equal(link.origin, 'https://spokenmargins.proximitytoprogress.com');
  assert.equal(link.id, 'AbCdEf123456');
  const { asked, fetchImpl } = server(b64(vector.packet.sealedBase64));
  const opened = await openSharedPacket(link, fetchImpl);
  assert.deepEqual(opened, b64(vector.packet.plaintextBase64));
  assert.equal(asked.length, 1);
  assert.equal(asked[0].url, 'https://spokenmargins.proximitytoprogress.com/l/AbCdEf123456/packet');
  assert.ok(!asked[0].url.includes(KEY), 'the key never leaves the browser');
  assert.equal(asked[0].init?.credentials, 'omit');
  assert.equal(asked[0].init?.referrerPolicy, 'no-referrer');
});

test('a damaged packet, the preview in its place, or the wrong key is "incomplete or damaged"', async () => {
  const sealed = b64(vector.packet.sealedBase64);
  const flipped = sealed.slice();
  flipped[40] ^= 1;
  const cases: Array<[string, Uint8Array, string]> = [
    ['flipped byte', flipped, vector.linkURL],
    ['truncated', sealed.subarray(0, 30), vector.linkURL],
    ['the preview part', b64(vector.preview.sealedBase64), vector.linkURL],
    ['another key', sealed, vector.linkURL.replace(/#.*/, `#${'A'.repeat(43)}`)],
  ];
  for (const [name, bytes, url] of cases) {
    await assert.rejects(openSharedPacket(linkFor(url), server(bytes).fetchImpl), (error: unknown) => {
      assert.ok(error instanceof ShareLinkError, name);
      assert.equal((error as Error).message, 'This link is incomplete or damaged.', name);
      return true;
    });
  }
});

test('server answers become the share page’s plain messages', async () => {
  assert.equal(LINK_MESSAGES.expired, EXPIRED_MESSAGE);
  assert.equal(LINK_MESSAGES.server, SERVER_MESSAGE);
  const link = linkFor(vector.linkURL);
  for (const [status, message] of [[404, LINK_MESSAGES.expired], [410, LINK_MESSAGES.expired], [500, LINK_MESSAGES.server], [403, LINK_MESSAGES.server]] as const) {
    await assert.rejects(openSharedPacket(link, server(null, status).fetchImpl), { message });
  }
  const offline = (async () => {
    throw new TypeError('Failed to fetch');
  }) as typeof fetch;
  await assert.rejects(openSharedPacket(link, offline), { message: LINK_MESSAGES.offline });
});

test('which text is a share link, which is a damaged one, and which is neither', () => {
  const id = '0123456789abcdef0123456789abcdef';
  const kinds: Array<[string, string, string?]> = [
    [vector.linkURL, 'link'],
    [`  ${vector.linkURL}\n`, 'link'],
    [`https://example.com/l/${id}/#${KEY}`, 'link'],
    [`https://example.com/l/${id}#${KEY}=`, 'link'],
    [`http://127.0.0.1:4174/l/${id}#${KEY}`, 'link'],
    [`http://localhost/l/${id}#${KEY}`, 'link'],
    [`/l/${id}#${KEY}`, 'link', 'https://example.com/'],
    [`https://example.com/l/${id}`, 'damaged'],
    [`https://example.com/l/${id}#`, 'damaged'],
    [`https://example.com/l/${id}#${KEY.slice(0, 20)}`, 'damaged'],
    [`https://example.com/l/${id}#${KEY}!`, 'damaged'],
    [`https://example.com/l/${id}#${KEY}AA`, 'damaged'],
    [`http://example.com/l/${id}#${KEY}`, 'none'],
    [`https://example.com/l/${id}?k=1#${KEY}`, 'none'],
    [`https://user:pw@example.com/l/${id}#${KEY}`, 'none'],
    [`https://example.com/l/${id}/packet#${KEY}`, 'none'],
    [`https://example.com/l/${'a'.repeat(65)}#${KEY}`, 'none'],
    [`https://example.com/x/${id}#${KEY}`, 'none'],
    [`ftp://example.com/l/${id}#${KEY}`, 'none'],
    ['https://example.com/podcast/episode-1', 'none'],
    ['not a link', 'none'],
    ['', 'none'],
    ['   ', 'none'],
  ];
  for (const [text, kind, base] of kinds) assert.equal(parseShareLink(text, base).kind, kind, text);
});

test('a link made here opens back to the same packet, and the importer reads its Margins', async () => {
  const packet = new Uint8Array(readFileSync(new URL('Contracts/fixtures/web-packets/web-voice.spokenmargins', repo)));
  const sealed = await sealPacket(packet, { schema: 'spokenmargins.link-preview.v1', source: { title: 'Episode 1' }, margins: [{ text: 'Hi' }] });
  const link = linkFor(`https://example.com/l/0123456789abcdef0123456789abcdef#${sealed.keyFragment}`);
  const opened = await openSharedPacket(link, server(sealed.packet).fetchImpl);
  const read = await readPacket(opened);
  assert.equal(read.episode.guid, 'example-episode-guid-1');
  assert.deepEqual(read.margins.map((m) => m.atSeconds), [30, 125.25]);
});

const show: Show = { id: 's', kind: 'podcast', title: 'Example Show', feedUrl: 'https://feeds.test/s.rss', followedAt: 'T0' };
const episode: Episode = { id: 'e', showId: 's', title: 'Episode 1', pageUrl: 'https://example.com/podcast/episode-1' };
const margin = (id: string, text: string | undefined): Margin => ({ id, episodeId: 'e', atSeconds: 1, createdAt: 'T0', ...(text !== undefined && { text }) });

test('the preview carries the words of the Margins in the packet, and nothing else', () => {
  const margins = [margin('a', 'First'), margin('b', '  Second  '), margin('c', undefined), margin('d', 'Not in the packet'), margin('e', '   ')];
  const preview = linkPreview(episode, show, margins, ['a', 'b', 'c', 'e']);
  assert.deepEqual(preview, {
    schema: 'spokenmargins.link-preview.v1',
    source: { title: 'Episode 1', show: 'Example Show', url: 'https://example.com/podcast/episode-1' },
    margins: [{ text: 'First' }, { text: 'Second' }],
  });
  const secret = linkPreview({ ...episode, pageUrl: 'https://example.com/ep?token=abc' }, undefined, margins, ['a']);
  assert.deepEqual(secret.source, { title: 'Episode 1' });
  assert.throws(() => linkPreview(episode, show, margins, ['c']), { message: LINK_MESSAGES.nothingToLink });
});

test('upload failures read plainly', () => {
  assert.equal(linkUploadMessage(new ShareLinkUploadError(413)), LINK_MESSAGES.tooLarge);
  assert.equal(linkUploadMessage(new ShareLinkUploadError(429)), LINK_MESSAGES.tooMany);
  assert.equal(linkUploadMessage(new ShareLinkUploadError(400)), LINK_MESSAGES.refused);
  assert.equal(linkUploadMessage(new ShareLinkUploadError(503)), LINK_MESSAGES.server);
  assert.equal(linkUploadMessage(new TypeError('Failed to fetch')), LINK_MESSAGES.offline);
  assert.equal(linkUploadMessage(new ShareLinksOffError()), new ShareLinksOffError().message);
  assert.equal(linkUploadMessage(new Error('x')), LINK_MESSAGES.server);
});

test('outside a build that turns them on, share links stay off', () => {
  assert.equal(SHARE_LINKS_ENABLED, false);
});
