import assert from 'node:assert/strict';
import { test } from 'node:test';
import { feedFixture } from './fixtures.ts';
import { browserFetch, capacitorBridge, nativeFetch, pickReadTransport, toResponse } from './native-http.ts';
import type { CapacitorBridge } from './native-http.ts';
import { NeedsRelayConsent, PostPageReadRefused, ReadHttpError, readFeed, readUrl } from './read.ts';
import { searchPodcasts } from './search.ts';

const FEED_URL = 'https://media.example.com/feed.xml';
const RELAY = 'https://relay.example.org';

type NativeAnswer = { status: number; data?: unknown; url?: string; headers?: Record<string, unknown> };

interface NativeCall {
  plugin: string;
  method: string;
  options: Record<string, unknown>;
}

/** A stand-in for the bridge Capacitor injects: answers by URL, rejects (like Android with no network) otherwise. */
function fakeBridge(routes: Record<string, NativeAnswer>, calls: NativeCall[] = [], native = true): CapacitorBridge {
  return {
    isNativePlatform: () => native,
    nativePromise: async (plugin, method, options) => {
      calls.push({ plugin, method, options });
      const answer = routes[String(options.url)];
      if (!answer) throw { message: 'Unable to resolve host "media.example.com"' };
      return answer;
    },
  };
}

test('the choice: no Capacitor means the browser fetch', () => {
  assert.equal(pickReadTransport({}).kind, 'browser');
  assert.equal(pickReadTransport({}).fetch, browserFetch);
  assert.equal(pickReadTransport(undefined).kind, 'browser');
  assert.equal(pickReadTransport(null).kind, 'browser');
  // Node itself (the tests' own globalThis) is a browser-style host.
  assert.equal(pickReadTransport().kind, 'browser');
});

test('the choice: Capacitor on the web, or a bridge missing a method, means the browser fetch', () => {
  assert.equal(pickReadTransport({ Capacitor: fakeBridge({}, [], false) }).kind, 'browser');
  assert.equal(pickReadTransport({ Capacitor: { isNativePlatform: () => true } }).kind, 'browser');
  assert.equal(pickReadTransport({ Capacitor: { nativePromise: async () => ({}) } }).kind, 'browser');
  const throwing = { isNativePlatform: () => { throw new Error('bridge not ready'); }, nativePromise: async () => ({}) };
  assert.equal(capacitorBridge({ Capacitor: throwing }), undefined);
});

test('the choice: inside the Capacitor app, native HTTP', () => {
  const bridge = fakeBridge({});
  assert.equal(capacitorBridge({ Capacitor: bridge }), bridge);
  assert.equal(pickReadTransport({ Capacitor: bridge }).kind, 'native');
});

test('native fetch asks CapacitorHttp for a text GET with timeouts and the caller\'s headers', async () => {
  const calls: NativeCall[] = [];
  const fetch = nativeFetch(fakeBridge({ [FEED_URL]: { status: 200, data: 'hello' } }, calls));
  const response = await fetch(FEED_URL, { credentials: 'omit', headers: { Accept: 'application/rss+xml' } });
  assert.equal(await response.text(), 'hello');
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.plugin, 'CapacitorHttp');
  assert.equal(calls[0]!.method, 'request');
  assert.deepEqual(calls[0]!.options, {
    url: FEED_URL,
    method: 'GET',
    headers: { accept: 'application/rss+xml' },
    responseType: 'text',
    connectTimeout: 30_000,
    readTimeout: 30_000,
  });
});

test('native fetch reads only', async () => {
  const fetch = nativeFetch(fakeBridge({ [FEED_URL]: { status: 200, data: '' } }));
  await assert.rejects(fetch(FEED_URL, { method: 'POST' }), TypeError);
});

test('a native answer becomes a Response with its status, headers and final address', async () => {
  const response = toResponse(
    { status: 404, data: 'gone', url: 'https://cdn.example.com/feed.xml', headers: { 'Content-Length': '4', 'X-Odd': 7 } },
    FEED_URL,
  );
  assert.equal(response.status, 404);
  assert.equal(response.ok, false);
  assert.equal(response.url, 'https://cdn.example.com/feed.xml');
  assert.equal(response.headers.get('content-length'), '4');
  assert.equal(response.headers.get('x-odd'), null, 'a non-string header is dropped');
  assert.equal(await response.text(), 'gone');
});

test('a native answer with JSON data, no data, no url or a bodiless status still reads', async () => {
  assert.equal(await toResponse({ status: 200, data: { results: [] } }, FEED_URL).text(), '{"results":[]}');
  assert.equal(await toResponse({ status: 200 }, FEED_URL).text(), '');
  assert.equal(toResponse({ status: 200, data: '' }, FEED_URL).url, FEED_URL);
  assert.equal(toResponse({ status: 204, data: 'ignored' }, FEED_URL).status, 204);
});

test('a native answer with no usable status is a network failure', () => {
  for (const raw of [undefined, null, {}, { status: '200' }, { status: 0 }, { status: 199 }, { status: 600 }, { status: 200.5 }]) {
    assert.throws(() => toResponse(raw, FEED_URL), TypeError, JSON.stringify(raw));
  }
});

test('inside the app a feed reads natively, with no relay and no consent', async () => {
  const calls: NativeCall[] = [];
  const bridge = fakeBridge({ [FEED_URL]: { status: 200, data: feedFixture('enclosure-only-episodes.rss'), url: FEED_URL } }, calls);
  const transport = pickReadTransport({ Capacitor: bridge });
  const feed = await readFeed(FEED_URL, { transport, relayBase: RELAY });
  assert.ok(feed.episodes.length > 0);
  assert.deepEqual(calls.map((call) => call.options.url), [FEED_URL]);
});

test('inside the app a failed read says the network failed: never the relay, never a consent question', async () => {
  const calls: NativeCall[] = [];
  const transport = pickReadTransport({ Capacitor: fakeBridge({}, calls) });
  await assert.rejects(readUrl(FEED_URL, { transport, relayBase: RELAY, consent: true }), (error: unknown) => {
    assert.ok(!(error instanceof NeedsRelayConsent));
    assert.ok(error instanceof TypeError);
    // The UI's offline message matches this (`plainError` in src/app/logic/messages.ts).
    assert.match(error.message, /network/i);
    return true;
  });
  assert.deepEqual(calls.map((call) => call.options.url), [FEED_URL], 'the relay was never asked');
});

test('inside the app an HTTP error is still the site\'s answer', async () => {
  const transport = pickReadTransport({ Capacitor: fakeBridge({ [FEED_URL]: { status: 410, data: 'gone' } }) });
  await assert.rejects(readUrl(FEED_URL, { transport }), (error: unknown) => error instanceof ReadHttpError && error.via === 'direct');
});

test('inside the app the post-page tap rule holds, before and after a redirect', async () => {
  const post = 'https://captured.example/p/voiceover';
  const calls: NativeCall[] = [];
  const transport = pickReadTransport({
    Capacitor: fakeBridge({ [FEED_URL]: { status: 200, data: '<rss/>', url: post } }, calls),
  });
  await assert.rejects(readUrl(post, { transport, reason: 'feed-refresh' }), PostPageReadRefused);
  assert.equal(calls.length, 0, 'nothing was fetched for an untapped post');
  await assert.rejects(readUrl(FEED_URL, { transport, reason: 'feed-refresh' }), PostPageReadRefused);
});

test('an injected fetch is a browser read, so tests and the browser keep the relay path', async () => {
  await assert.rejects(readUrl(FEED_URL, { fetch: async () => { throw new TypeError('Failed to fetch'); } }), NeedsRelayConsent);
});

test('podcast search still honours an injected fetch', async () => {
  const shows = await searchPodcasts('anything', { fetch: async () => new Response('{"results":[]}') });
  assert.deepEqual(shows, []);
});
