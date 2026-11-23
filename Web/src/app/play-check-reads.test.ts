import { test } from 'node:test';
import assert from 'node:assert/strict';
import { browserCanPlayType, checkReadHandler, checkTransport, classifyAudioStart, type CheckReadHandler, type CheckReadReply, type CheckReadRequest } from './play-check-reads.ts';

const hostWith = (postMessage: CheckReadHandler['postMessage']) => ({ webkit: { messageHandlers: { smPlayCheckRead: { postMessage } } } });

test('without the app\'s read handler there is no way to read a publisher', () => {
  assert.equal(checkReadHandler({}), undefined);
  assert.equal(checkReadHandler({ webkit: { messageHandlers: { smPlayCheck: { postMessage() {} } } } }), undefined, 'the check\'s own handler is not a read handler');
  assert.equal(checkReadHandler({ webkit: { messageHandlers: { smPlayCheckRead: {} } } }), undefined);
  assert.equal(checkReadHandler(null), undefined);
  assert.ok(checkReadHandler(hostWith(async () => ({ status: 200 }))));
});

test('the transport asks the app for each page, as a native read: a failure is the network\'s and never a relay read', async () => {
  const asked: CheckReadRequest[] = [];
  const transport = checkTransport({
    postMessage: async (request) => {
      asked.push(request);
      return { status: 200, url: 'https://x.example/final', body: 'hello' };
    },
  });
  assert.equal(transport.kind, 'native');
  const response = await transport.fetch('https://x.example/p/a', { credentials: 'omit' });
  assert.deepEqual(asked, [{ kind: 'page', url: 'https://x.example/p/a' }]);
  assert.equal(response.status, 200);
  assert.equal(response.url, 'https://x.example/final');
  assert.equal(await response.text(), 'hello');
  // No address back means the address asked for.
  const plain = checkTransport({ postMessage: async () => ({ status: 200, body: '' }) });
  assert.equal((await plain.fetch('https://x.example/p/b')).url, 'https://x.example/p/b');
});

test('the transport turns anything odd into a network failure, and reads only', async () => {
  const rejecting = checkTransport({ postMessage: async () => Promise.reject(new Error('timed out')) });
  await assert.rejects(rejecting.fetch('https://x.example/p/a'), (e: unknown) => e instanceof TypeError && /timed out/.test((e as Error).message));
  for (const status of [0, 99, 600, 1.5, NaN, undefined, '200']) {
    const odd = checkTransport({ postMessage: async () => ({ status }) as unknown as CheckReadReply });
    await assert.rejects(odd.fetch('https://x.example/p/a'), TypeError, String(status));
  }
  const reads = checkTransport({ postMessage: async () => ({ status: 200 }) });
  await assert.rejects(reads.fetch('https://x.example/p/a', { method: 'POST' }), TypeError);
  const empty = checkTransport({ postMessage: async () => ({ status: 204 }) });
  assert.equal((await empty.fetch('https://x.example/p/a')).status, 204);
});

const plays = (type: string) => (/^audio\/(mpeg|mp4|aac|wav)$/.test(type) ? 'maybe' : '');

test('audio: only what is clear is a warning; anything unclear passes, and a server in trouble is "couldn\'t tell"', () => {
  const verdict = (status: number, contentType?: string) => classifyAudioStart({ status, ...(contentType && { contentType }) }, plays);
  // Plays: a normal MP3, a ranged answer, a type with parameters and capitals, no type at all, a generic binary type.
  assert.equal(verdict(200, 'audio/mpeg'), 'plays');
  assert.equal(verdict(206, 'audio/mp4'), 'plays');
  assert.equal(verdict(200, 'Audio/MPEG; charset=binary'), 'plays');
  assert.equal(verdict(200), 'plays');
  assert.equal(verdict(200, 'application/octet-stream'), 'plays');
  assert.equal(verdict(200, 'binary/octet-stream'), 'plays');
  assert.equal(verdict(200, 'application/vnd.apple.mpegurl'), 'plays', 'not an audio or video type: unclear, so it passes');
  // The server turned the request away, or answered with a page where audio should be.
  for (const status of [404, 410]) assert.equal(verdict(status, 'audio/mpeg'), 'audio-refused', String(status));
  // A host may turn the app away and still serve a friend's browser: couldn't tell.
  for (const status of [400, 401, 403, 451]) assert.equal(verdict(status, 'audio/mpeg'), 'unreachable', String(status));
  for (const type of ['text/html', 'text/html; charset=utf-8', 'application/json', 'application/xml', 'application/atom+xml']) {
    assert.equal(verdict(200, type), 'audio-refused', type);
  }
  // A type this browser says it can't play.
  assert.equal(verdict(200, 'audio/x-ms-wma'), 'audio-format');
  assert.equal(verdict(200, 'video/x-matroska'), 'audio-format');
  // The sender's WebKit says no, but other browsers play these: never a warning.
  for (const type of ['audio/ogg', 'audio/opus', 'audio/webm', 'video/webm', 'audio/flac']) assert.equal(verdict(200, type), 'plays', type);
  // The check couldn't tell.
  for (const status of [500, 502, 503, 429, 301, 302, 304, 199, 100]) assert.equal(verdict(status, 'audio/mpeg'), 'unreachable', String(status));
});

test('the browser\'s own canPlayType answer is only asked, and a page that can\'t ask says nothing against the audio', () => {
  // In node there is no document: the answer is "maybe", never an empty string that would warn.
  assert.notEqual(browserCanPlayType('audio/x-ms-wma'), '');
});

test('an answer over the app\'s size cap is the read path\'s own ReadTooLarge, as a browser\'s read would be', async () => {
  const { ReadTooLarge } = await import('../sources/read.ts');
  const transport = checkTransport({ postMessage: async () => ({ status: 200, url: 'https://x.example/feed', tooLarge: true }) }, 'feed');
  await assert.rejects(transport.fetch('https://x.example/feed'), ReadTooLarge);
});
