import assert from 'node:assert/strict';
import { test } from 'node:test';
import { feedFixture, stubFetch } from './fixtures.ts';
import {
  NeedsRelayConsent,
  PostPageReadRefused,
  ReadHttpError,
  ReadTooLarge,
  RelayNotConfigured,
  readFeed,
  readSubstackVoice,
  readUrl,
  relayUrl,
} from './read.ts';

const FEED_URL = 'https://media.example.com/feed.xml';
const POST_URL = 'https://captured.example/p/voiceover';
const RELAY = 'https://relay.example.org';

test('a direct read that works never touches the relay', async () => {
  const calls: string[] = [];
  const fetch = stubFetch({ [FEED_URL]: { body: feedFixture('enclosure-only-episodes.rss') } }, calls);
  const result = await readUrl(FEED_URL, { fetch, relayBase: RELAY });
  assert.equal(result.via, 'direct');
  assert.deepEqual(calls, [FEED_URL]);
});

test('a blocked direct read throws NeedsRelayConsent, and asks nothing of the relay yet', async () => {
  const calls: string[] = [];
  const fetch = stubFetch({}, calls);
  await assert.rejects(readUrl(FEED_URL, { fetch, relayBase: RELAY }), (error: unknown) => {
    assert.ok(error instanceof NeedsRelayConsent);
    assert.equal(error.url, FEED_URL);
    return true;
  });
  assert.deepEqual(calls, [FEED_URL], 'the server never saw the address');
});

test('with consent, a blocked direct read goes through the relay', async () => {
  const calls: string[] = [];
  const relayed = relayUrl(RELAY, FEED_URL);
  const fetch = stubFetch({ [relayed]: { body: feedFixture('enclosure-only-episodes.rss') } }, calls);
  const result = await readUrl(FEED_URL, { fetch, relayBase: `${RELAY}/`, consent: true });
  assert.equal(result.via, 'relay');
  assert.equal(result.finalUrl, undefined);
  assert.deepEqual(calls, [FEED_URL, relayed]);
  assert.equal(relayed, 'https://relay.example.org/api/v1/relay?url=https%3A%2F%2Fmedia.example.com%2Ffeed.xml');
});

test('the relay address encodes a target that has its own query string', () => {
  const url = new URL(relayUrl(RELAY, 'https://a.example/feed?x=1&y=2#f'));
  assert.equal(url.searchParams.get('url'), 'https://a.example/feed?x=1&y=2#f');
  assert.equal(url.searchParams.get('y'), null);
});

test('consent without a relay address says so', async () => {
  await assert.rejects(readUrl(FEED_URL, { fetch: stubFetch({}), consent: true }), RelayNotConfigured);
});

test('an HTTP error from the site is its answer: no relay offered', async () => {
  const calls: string[] = [];
  const fetch = stubFetch({ [FEED_URL]: { body: 'gone', status: 404 } }, calls);
  await assert.rejects(readUrl(FEED_URL, { fetch, relayBase: RELAY, consent: true }), (error: unknown) => {
    assert.ok(error instanceof ReadHttpError);
    assert.equal(error.status, 404);
    assert.equal(error.via, 'direct');
    return true;
  });
  assert.deepEqual(calls, [FEED_URL]);
});

test('an error from the relay is reported as the relay\'s', async () => {
  const fetch = stubFetch({ [relayUrl(RELAY, FEED_URL)]: { body: 'bad gateway', status: 502 } });
  await assert.rejects(readUrl(FEED_URL, { fetch, relayBase: RELAY, consent: true }), (error: unknown) => {
    assert.ok(error instanceof ReadHttpError);
    assert.equal(error.via, 'relay');
    return true;
  });
});

test('a body over the cap is refused', async () => {
  const fetch = stubFetch({ [FEED_URL]: { body: 'x'.repeat(2000) } });
  await assert.rejects(readUrl(FEED_URL, { fetch, maxBytes: 1000 }), ReadTooLarge);
  assert.equal((await readUrl(FEED_URL, { fetch, maxBytes: 2000 })).body.length, 2000);
});

test('a Substack post page is refused without a listener tap, and nothing is fetched', async () => {
  for (const reason of [undefined, 'feed-refresh', 'search'] as const) {
    const calls: string[] = [];
    const fetch = stubFetch({ [POST_URL]: { body: feedFixture('substack-voiceover-page.html') } }, calls);
    await assert.rejects(readUrl(POST_URL, { fetch, reason }), PostPageReadRefused, String(reason));
    assert.deepEqual(calls, [], `${String(reason)}: no request left the browser`);
  }
});

test('a post page is read for a listener tap', async () => {
  const fetch = stubFetch({ [POST_URL]: { body: feedFixture('substack-voiceover-page.html') } });
  const result = await readUrl(POST_URL, { fetch, reason: 'listener-tap' });
  assert.equal(result.via, 'direct');
});

test('a redirect that lands on a post page is refused without a tap', async () => {
  const fetch = stubFetch({ 'https://short.example/x': { body: 'html', url: 'https://thezvi.substack.com/p/some-post' } });
  await assert.rejects(readUrl('https://short.example/x', { fetch, reason: 'feed-refresh' }), PostPageReadRefused);
});

test('a Substack feed is not a post page: it reads without a tap', async () => {
  const url = 'https://thezvi.substack.com/feed';
  const fetch = stubFetch({ [url]: { body: feedFixture('substack-zvi-generated-voice.rss') } });
  const feed = await readFeed(url, { fetch, reason: 'feed-refresh' });
  assert.equal(feed.show.kind, 'substack');
  assert.equal(feed.episodes.length, 1);
});

test('readFeed parses what it read, through the relay when the listener agreed', async () => {
  const fetch = stubFetch({ [relayUrl(RELAY, FEED_URL)]: { body: feedFixture('enclosure-only-episodes.rss') } });
  await assert.rejects(readFeed(FEED_URL, { fetch, relayBase: RELAY }), NeedsRelayConsent);
  const feed = await readFeed(FEED_URL, { fetch, relayBase: RELAY, consent: true, followedAt: 'T0' });
  assert.equal(feed.episodes.length, 3);
  assert.equal(feed.show.followedAt, 'T0');
});

test('readSubstackVoice finds the voice for a tapped post, and only for that post', async () => {
  const html = feedFixture('substack-voiceover-page.html');
  const same = stubFetch({ [POST_URL]: { body: html, url: POST_URL } });
  assert.equal((await readSubstackVoice(POST_URL, { fetch: same }))?.origin, 'substack-voiceover');
  const other = stubFetch({ [POST_URL]: { body: html, url: 'https://captured.example/p/something-else' } });
  assert.equal(await readSubstackVoice(POST_URL, { fetch: other }), null);
});

test('readSubstackVoice for a paid post is null, not an error', async () => {
  const url = 'https://captured.example/p/paid-post';
  const fetch = stubFetch({ [url]: { body: feedFixture('substack-paid-post-page.html'), url } });
  assert.equal(await readSubstackVoice(url, { fetch }), null);
});

test('readSubstackVoice still asks consent before the relay', async () => {
  await assert.rejects(readSubstackVoice(POST_URL, { fetch: stubFetch({}), relayBase: RELAY }), NeedsRelayConsent);
});
