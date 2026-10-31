import assert from 'node:assert/strict';
import { test } from 'node:test';
import { FeedParseError } from './feed.ts';
import { feedFixture, stubFetch } from './fixtures.ts';
import {
  NeedsRelayConsent,
  PaidPostNoVoice,
  PostPageReadRefused,
  ReadHttpError,
  ReadTooLarge,
  RelayNotConfigured,
  RelayUnreachable,
  readFeed,
  readSubstackVoice,
  RELAY_FINAL_URL_HEADER,
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
  assert.equal(result.finalUrl, undefined, 'a relay that names no final address leaves it unset');
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

// The relay (#2985) answers 503 `{"error":"disabled"}` when switched off and 503 `{"error":"busy"}` when full: seen
// from a local build of it on 2026-10-30. The code is what tells a listener which.
test('a relay error keeps the relay\'s own reason', async () => {
  const relayed = relayUrl(RELAY, FEED_URL);
  const rows: Array<[string, number, string | undefined]> = [
    ['{"error":"disabled"}', 503, 'disabled'],
    ['{"error":"busy"}', 503, 'busy'],
    ['{"error":"rate_limited"}', 429, 'rate_limited'],
    ['<html>Bad gateway</html>', 502, undefined],
    ['{"error":42}', 503, undefined],
    ['{"error":"<script>"}', 503, undefined],
    ['', 503, undefined],
  ];
  for (const [body, status, code] of rows) {
    const fetch = stubFetch({ [relayed]: { body, status } });
    await assert.rejects(readUrl(FEED_URL, { fetch, relayBase: RELAY, consent: true }), (error: unknown) => {
      assert.ok(error instanceof ReadHttpError, body);
      assert.equal(error.status, status);
      assert.equal(error.code, code, body);
      return true;
    });
  }
});

// A relay that is down, or that doesn't list this web app's origin, fails in a browser the way a blocked site does:
// `fetch` throws. That used to surface as the raw TypeError, which the app words as "No connection".
test('a relay that cannot be reached says so, not a raw fetch error', async () => {
  const calls: string[] = [];
  await assert.rejects(readUrl(FEED_URL, { fetch: stubFetch({}, calls), relayBase: RELAY, consent: true }), RelayUnreachable);
  assert.deepEqual(calls, [FEED_URL, relayUrl(RELAY, FEED_URL)]);
});

// What a listener pastes for "a Substack address" is the publication's home page. On 2026-10-30 that said "isn't a
// podcast or Substack feed" in Chrome. The home page is synthetic here, in the shape real ones have.
const HOME = 'https://www.example-letter.com';
const HOME_FEED = 'https://www.example-letter.com/feed';
const HOME_PAGE = `<!DOCTYPE html><html><head><title>A Letter</title><link rel="alternate" type="application/rss+xml" href="/feed" title="A Letter"/></head><body><p>Posts</p></body></html>`;

test('readFeed follows a home page to the feed it names, and the show follows that feed', async () => {
  const calls: string[] = [];
  const fetch = stubFetch(
    { [HOME]: { body: HOME_PAGE, url: `${HOME}/` }, [HOME_FEED]: { body: feedFixture('substack-zvi-generated-voice.rss') } },
    calls,
  );
  const feed = await readFeed(HOME, { fetch });
  assert.equal(feed.show.feedUrl, HOME_FEED, 'a refresh reads the feed, not the page');
  assert.equal(feed.show.id, `feed:${HOME_FEED}`);
  assert.equal(feed.show.kind, 'substack');
  assert.ok(feed.episodes.length > 0);
  assert.deepEqual(calls, [HOME, HOME_FEED]);
});

test('readFeed through the relay: the home page and its feed both go the same way, after consent', async () => {
  const calls: string[] = [];
  const fetch = stubFetch(
    {
      [relayUrl(RELAY, HOME)]: { body: HOME_PAGE, headers: { [RELAY_FINAL_URL_HEADER]: `${HOME}/` } },
      [relayUrl(RELAY, HOME_FEED)]: { body: feedFixture('substack-zvi-generated-voice.rss') },
    },
    calls,
  );
  await assert.rejects(readFeed(HOME, { fetch, relayBase: RELAY }), NeedsRelayConsent);
  const feed = await readFeed(HOME, { fetch, relayBase: RELAY, consent: true });
  assert.equal(feed.show.feedUrl, HOME_FEED);
  assert.deepEqual(calls.slice(1), [HOME, relayUrl(RELAY, HOME), HOME_FEED, relayUrl(RELAY, HOME_FEED)]);
});

test('readFeed: a page with no feed link, or one whose feed link is another page, is not a feed', async () => {
  const bare = stubFetch({ [HOME]: { body: '<html><head><title>x</title></head><body></body></html>' } });
  await assert.rejects(readFeed(HOME, { fetch: bare }), FeedParseError);
  const calls: string[] = [];
  const loop = stubFetch({ [HOME]: { body: HOME_PAGE }, [HOME_FEED]: { body: HOME_PAGE } }, calls);
  await assert.rejects(readFeed(HOME, { fetch: loop }), FeedParseError);
  assert.deepEqual(calls, [HOME, HOME_FEED], 'one hop only');
  const self = stubFetch({ [HOME_FEED]: { body: HOME_PAGE } });
  await assert.rejects(readFeed(HOME_FEED, { fetch: self }), FeedParseError, 'a page naming itself is read once');
});

test('readFeed never follows a feed link to a Substack post page without a tap', async () => {
  const page = '<html><head><link rel="alternate" type="application/rss+xml" href="/p/a-post"></head></html>';
  const calls: string[] = [];
  await assert.rejects(readFeed(HOME, { fetch: stubFetch({ [HOME]: { body: page } }, calls) }), PostPageReadRefused);
  assert.deepEqual(calls, [HOME]);
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

// On 2026-10-30 a real paid post tapped in Chrome said "neither the writer nor Substack offers one", though its page
// listed Substack's voice as `paywalled`. Most paid posts on the publications checked that day were like it.
test('readSubstackVoice for a paid post says it is for paid subscribers, not that it has no voice', async () => {
  const url = 'https://captured.example/p/paid-post';
  const fetch = stubFetch({ [url]: { body: feedFixture('substack-paid-post-page.html'), url } });
  await assert.rejects(readSubstackVoice(url, { fetch }), (error: unknown) => {
    assert.ok(error instanceof PaidPostNoVoice);
    assert.equal(error.url, url);
    return true;
  });
});

test('readSubstackVoice: a free post whose automatic voice failed has no voice, and is not called paid', async () => {
  const url = 'https://captured.example/p/failed';
  const post = { type: 'newsletter', audience: 'everyone', id: 7, canonical_url: url, audio_items: [{ post_id: 7, type: 'tts', status: 'failed', audio_url: null }] };
  const html = `<script>window._preloads = JSON.parse(${JSON.stringify(JSON.stringify({ post }))});</script>`;
  assert.equal(await readSubstackVoice(url, { fetch: stubFetch({ [url]: { body: html, url } }) }), null);
});

test('readSubstackVoice: a redirect to another post\'s paid page neither plays nor blames the paywall', async () => {
  const url = 'https://captured.example/p/asked-for';
  const fetch = stubFetch({ [url]: { body: feedFixture('substack-paid-post-page.html'), url: 'https://captured.example/p/elsewhere' } });
  assert.equal(await readSubstackVoice(url, { fetch, consent: false }).catch((e: unknown) => e), null);
});

test('readSubstackVoice still asks consent before the relay', async () => {
  await assert.rejects(readSubstackVoice(POST_URL, { fetch: stubFetch({}), relayBase: RELAY }), NeedsRelayConsent);
});

// The relay names the address after redirects in X-Final-URL (#2979), so a relayed read keeps the checks a direct
// read gets from Response.url.
const RELATIVE_FEED = `<?xml version="1.0"?><rss version="2.0"><channel><title>Moved</title><link>/show</link>
<item><title>One</title><guid>g1</guid><link>/p/one</link><enclosure url="audio/one.mp3" type="audio/mpeg"/></item>
</channel></rss>`;

test('through the relay, the final address comes from X-Final-URL and relative links resolve against it', async () => {
  const asked = 'https://old.example/feed';
  const final = 'https://new.example/podcast/feed.xml';
  const fetch = stubFetch({ [relayUrl(RELAY, asked)]: { body: RELATIVE_FEED, headers: { [RELAY_FINAL_URL_HEADER]: final } } });
  const read = await readUrl(asked, { fetch, relayBase: RELAY, consent: true });
  assert.equal(read.finalUrl, final);
  const feed = await readFeed(asked, { fetch, relayBase: RELAY, consent: true });
  assert.equal(feed.show.feedUrl, asked, 'the show keeps the address the listener followed');
  assert.equal(feed.show.siteUrl, 'https://new.example/show');
  assert.equal(feed.episodes[0]?.audioUrl, 'https://new.example/podcast/audio/one.mp3');
  assert.equal(feed.episodes[0]?.pageUrl, 'https://new.example/p/one');
});

test('a direct read that was redirected resolves relative links against where it landed', async () => {
  const asked = 'https://old.example/feed';
  const fetch = stubFetch({ [asked]: { body: RELATIVE_FEED, url: 'https://new.example/podcast/feed.xml' } });
  const feed = await readFeed(asked, { fetch });
  assert.equal(feed.episodes[0]?.audioUrl, 'https://new.example/podcast/audio/one.mp3');
});

test('a relayed read whose redirect landed on a post page is refused without a tap', async () => {
  const asked = 'https://short.example/x';
  const fetch = stubFetch({
    [relayUrl(RELAY, asked)]: { body: 'html', headers: { [RELAY_FINAL_URL_HEADER]: 'https://thezvi.substack.com/p/some-post' } },
  });
  await assert.rejects(readUrl(asked, { fetch, relayBase: RELAY, consent: true, reason: 'feed-refresh' }), PostPageReadRefused);
});

test('through the relay, readSubstackVoice gives a voice only to the post the page is about', async () => {
  const html = feedFixture('substack-voiceover-page.html');
  const relayed = relayUrl(RELAY, POST_URL);
  const same = stubFetch({ [relayed]: { body: html, headers: { [RELAY_FINAL_URL_HEADER]: POST_URL } } });
  assert.equal((await readSubstackVoice(POST_URL, { fetch: same, relayBase: RELAY, consent: true }))?.origin, 'substack-voiceover');
  const other = stubFetch({ [relayed]: { body: html, headers: { [RELAY_FINAL_URL_HEADER]: 'https://captured.example/p/something-else' } } });
  assert.equal(await readSubstackVoice(POST_URL, { fetch: other, relayBase: RELAY, consent: true }), null);
});

test('an unusable X-Final-URL is ignored, not trusted', async () => {
  for (const junk of ['javascript:alert(1)', 'not a url', '', 'file:///etc/passwd']) {
    const fetch = stubFetch({ [relayUrl(RELAY, FEED_URL)]: { body: 'x', headers: { [RELAY_FINAL_URL_HEADER]: junk } } });
    const read = await readUrl(FEED_URL, { fetch, relayBase: RELAY, consent: true });
    assert.equal(read.finalUrl, undefined, junk);
  }
});
