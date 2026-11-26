import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AppleLookupError, appleEpisodeRef, appleLookupUrl, findAppleEpisodeAudio, playableAudioAddress } from './apple.ts';
import { NeedsRelayConsent } from './read.ts';
import type { FetchLike } from './search.ts';

const PAGE = 'https://podcasts.apple.com/us/podcast/people-parks-and-policy-with-rffs-margaret-walls/id1445582279?i=1000427709574';

// The shape of Apple's public lookup for a show with `entity=podcastEpisode`: the show first, then its episodes.
const lookup = (episodes: object[]) => ({
  resultCount: episodes.length + 1,
  results: [{ wrapperType: 'track', kind: 'podcast', collectionId: 1445582279, feedUrl: 'https://feeds.soundcloud.com/users/soundcloud:users:1/sounds.rss' }, ...episodes],
});
const episode = (extra: object) => ({
  wrapperType: 'podcastEpisode',
  kind: 'podcast-episode',
  trackId: 1000427709574,
  trackName: 'People, Parks, and Policy with RFF’s Margaret Walls',
  collectionName: 'Resources Radio',
  episodeUrl: 'https://feeds.soundcloud.com/stream/559432260-resourcesradio-people-parks-and-policy.mp3',
  episodeGuid: 'tag:soundcloud,2010:tracks/559432260',
  trackTimeMillis: 1_800_000,
  ...extra,
});
const answering = (body: unknown, status = 200) => {
  const asked: string[] = [];
  const fetch: FetchLike = async (input) => {
    asked.push(input);
    return new Response(typeof body === 'string' ? body : JSON.stringify(body), { status });
  };
  return { fetch, asked };
};

// Neighbouring pages: which addresses name an Apple episode, and which are never read as one.
const refs: Array<[string, ReturnType<typeof appleEpisodeRef>]> = [
  [PAGE, { showId: '1445582279', episodeId: '1000427709574' }],
  ['https://podcasts.apple.com/us/podcast/x/id1445582279?i=1000427709574&l=en', { showId: '1445582279', episodeId: '1000427709574' }],
  ['https://PODCASTS.APPLE.COM/us/podcast/x/id1445582279?i=1000427709574', { showId: '1445582279', episodeId: '1000427709574' }],
  ['https://podcasts.apple.com/us/podcast/id1445582279?i=1000427709574', { showId: '1445582279', episodeId: '1000427709574' }],
  ['https://itunes.apple.com/us/podcast/x/id1445582279?i=1000427709574', { showId: '1445582279', episodeId: '1000427709574' }],
  ['https://podcasts.apple.com/us/podcast/x/id0001445582279?i=0001000427709574', { showId: '1445582279', episodeId: '1000427709574' }],
  ['https://podcasts.apple.com/us/podcast/x/id1445582279?i=000', { showId: '1445582279', episodeId: '0' }],
  ['https://podcasts.apple.com/us/podcast/x/id1445582279', undefined],
  ['https://podcasts.apple.com/us/podcast/x/id1445582279?i=', undefined],
  ['https://podcasts.apple.com/us/podcast/x/id1445582279?i=abc', undefined],
  ['https://podcasts.apple.com/us/podcast/x/id1445582279?i=1000427709574&i=1000427709575', undefined],
  ['https://podcasts.apple.com/us/podcast/x?i=1000427709574', undefined],
  ['https://podcasts.apple.com/us/podcast/x/id1/id2?i=1000427709574', undefined],
  ['https://podcasts.apple.com/us/podcast/x/idabc?i=1000427709574', undefined],
  ['https://podcasts.apple.com/us/podcast/x/id12345678901234567890?i=1', undefined],
  ['http://podcasts.apple.com/us/podcast/x/id1445582279?i=1000427709574', undefined],
  ['https://podcasts.apple.com.example.org/us/podcast/x/id1445582279?i=1000427709574', undefined],
  ['https://example.org/podcasts.apple.com/us/podcast/x/id1445582279?i=1000427709574', undefined],
  ['https://music.apple.com/us/album/x/id1445582279?i=1000427709574', undefined],
  ['https://open.spotify.com/episode/4rOoJ6Egrf8K2IrywzwOMk', undefined],
  ['not a url', undefined],
  ['', undefined],
];
for (const [address, expected] of refs) {
  test(`appleEpisodeRef: ${address || '(empty)'}`, () => {
    assert.deepEqual(appleEpisodeRef(address), expected);
  });
}

test('the lookup asks Apple for the show\'s episodes, the same address the iPhone app asks', () => {
  assert.equal(appleLookupUrl('1445582279'), 'https://itunes.apple.com/lookup?id=1445582279&entity=podcastEpisode&limit=200');
});

test('the episode whose Apple id is the page\'s is found with its audio, length and guid', async () => {
  const { fetch, asked } = answering(lookup([episode({ trackId: 1000427709000, episodeUrl: 'https://example.com/other.mp3' }), episode({})]));
  const found = await findAppleEpisodeAudio(PAGE, { fetch });
  assert.deepEqual(found, {
    audioUrl: 'https://feeds.soundcloud.com/stream/559432260-resourcesradio-people-parks-and-policy.mp3',
    audioOrigin: 'podcast-enclosure',
    durationSeconds: 1800,
    guid: 'tag:soundcloud,2010:tracks/559432260',
  });
  assert.deepEqual(asked, ['https://itunes.apple.com/lookup?id=1445582279&entity=podcastEpisode&limit=200']);
});

test('an episode Apple does not list is never matched by its title or its neighbours', async () => {
  // Same title, different episode id (a re-upload): never guessed.
  const same = answering(lookup([episode({ trackId: 1000427709999 })]));
  assert.equal(await findAppleEpisodeAudio(PAGE, { fetch: same.fetch }), null);
  assert.equal(await findAppleEpisodeAudio(PAGE, { fetch: answering(lookup([])).fetch }), null);
  assert.equal(await findAppleEpisodeAudio(PAGE, { fetch: answering({ resultCount: 0 }).fetch }), null);
  // The show row has no episode id of its own to match.
  assert.equal(await findAppleEpisodeAudio(PAGE, { fetch: answering(lookup([{ wrapperType: 'track', kind: 'podcast', trackId: 1000427709574 }])).fetch }), null);
});

test('an episode listed with no usable audio is "no audio", not a guess', async () => {
  for (const episodeUrl of [undefined, '', '   ', 'ftp://example.com/a.mp3', 'not a url', 42]) {
    const { fetch } = answering(lookup([episode({ episodeUrl })]));
    assert.equal(await findAppleEpisodeAudio(PAGE, { fetch }), null, String(episodeUrl));
  }
});

test('a page that is not an Apple episode is never sent to Apple', async () => {
  const { fetch, asked } = answering(lookup([episode({})]));
  assert.equal(await findAppleEpisodeAudio('https://podcasts.apple.com/us/podcast/x/id1445582279', { fetch }), null);
  assert.equal(await findAppleEpisodeAudio('https://example.com/ep', { fetch }), null);
  assert.deepEqual(asked, []);
});

test('audio addresses a page on https can load: an http address is read as https, anything else is no audio', () => {
  assert.equal(playableAudioAddress('http://traffic.example.com/ep.mp3?x=1'), 'https://traffic.example.com/ep.mp3?x=1');
  assert.equal(playableAudioAddress('https://traffic.example.com/ep.mp3'), 'https://traffic.example.com/ep.mp3');
  assert.equal(playableAudioAddress(' https://traffic.example.com/ep.mp3 '), 'https://traffic.example.com/ep.mp3');
  for (const bad of ['', '   ', 'ftp://example.com/a', 'javascript:alert(1)', 'data:audio/mp3;base64,AAAA', 'file:///a.mp3', 'x', undefined, null, 5]) {
    assert.equal(playableAudioAddress(bad), undefined, String(bad));
  }
});

test('a lookup that could not be asked or answered says so, and is not "no audio"', async () => {
  const offline: FetchLike = async () => {
    throw new TypeError('Failed to fetch');
  };
  await assert.rejects(findAppleEpisodeAudio(PAGE, { fetch: offline }), AppleLookupError);
  await assert.rejects(findAppleEpisodeAudio(PAGE, { fetch: answering('{}', 503).fetch }), AppleLookupError);
  await assert.rejects(findAppleEpisodeAudio(PAGE, { fetch: answering('<html>', 200).fetch }), AppleLookupError);
});

test('the lookup carries a deadline, so a card waiting on Apple never waits forever', async () => {
  let signal: AbortSignal | null | undefined;
  const fetch: FetchLike = async (_input, init) => {
    signal = init?.signal;
    return new Response(JSON.stringify(lookup([episode({})])));
  };
  await findAppleEpisodeAudio(PAGE, { fetch });
  assert.ok(signal, 'a signal was passed');
  assert.equal(signal.aborted, false);
});

test('a lookup that ignores the abort signal and never answers still ends at its limit (the Android app\'s native read does)', async () => {
  const neverAnswers: FetchLike = () => new Promise<Response>(() => {});
  const started = Date.now();
  await assert.rejects(findAppleEpisodeAudio(PAGE, { fetch: neverAnswers, timeoutMs: 40 }), AppleLookupError);
  assert.ok(Date.now() - started < 2_000, 'it rejected, it did not hang');
});

test('an episode whose page id is zero-padded is still matched by its number', async () => {
  const { fetch } = answering({ results: [{ wrapperType: 'podcastEpisode', trackId: 1000427709574, episodeUrl: 'https://media.example.com/a.mp3' }] });
  const found = await findAppleEpisodeAudio('https://podcasts.apple.com/us/podcast/x/id1445582279?i=0001000427709574', { fetch });
  assert.equal(found?.audioUrl, 'https://media.example.com/a.mp3');
});

// An episode older than the newest 200 Apple lists is found in the show's own feed (#4783).
const FEED_URL = 'https://feeds.soundcloud.com/users/soundcloud:users:1/sounds.rss';
const TITLE = "People, Parks, and Policy, with RFF's Margaret Walls";
const rssItem = (title: string, audio: string, extra = '') => `<item><title>${title}</title><guid>${extra || audio}</guid><itunes:duration>00:21:35</itunes:duration><enclosure type="audio/mpeg" url="${audio}" length="1"/></item>`;
const rss = (...items: string[]) => `<?xml version="1.0"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Resources Radio</title>${items.join('')}</channel></rss>`;
const GAP_AUDIO = 'https://feeds.soundcloud.com/stream/559432260-resourcesradio-people-parks-and-policy-with-rffs-margaret-walls.mp3';
/** Apple's answer with a show row and one episode that is not ours, then each read answered by address. */
function lookupThenFeed(feedBody: string | Error, show: object = { wrapperType: 'track', kind: 'podcast', collectionId: 1445582279, feedUrl: FEED_URL }) {
  const asked: string[] = [];
  const fetch: FetchLike = async (input) => {
    asked.push(input);
    if (input.startsWith('https://itunes.apple.com/lookup')) {
      return new Response(JSON.stringify({ results: [show, episode({ trackId: 1000427709000, episodeUrl: 'https://example.com/other.mp3' })] }));
    }
    if (feedBody instanceof Error) throw feedBody;
    return new Response(feedBody, { headers: { 'content-type': 'application/rss+xml' } });
  };
  return { fetch, asked };
}

test('an episode Apple does not list is found in the show\'s feed by its title, with the feed\'s audio, length and guid', async () => {
  const { fetch, asked } = lookupThenFeed(rss(rssItem('Newest', 'https://example.com/new.mp3'), rssItem(TITLE, GAP_AUDIO, 'tag:soundcloud,2010:tracks/559432260')));
  const found = await findAppleEpisodeAudio(PAGE, { fetch, feed: { title: TITLE, fetch } });
  assert.deepEqual(found, { audioUrl: GAP_AUDIO, audioOrigin: 'podcast-enclosure', durationSeconds: 1295, guid: 'tag:soundcloud,2010:tracks/559432260' });
  assert.deepEqual(asked, ['https://itunes.apple.com/lookup?id=1445582279&entity=podcastEpisode&limit=200', FEED_URL]);
});

test('without a title to look for, the show\'s feed is never read', async () => {
  const { fetch, asked } = lookupThenFeed(rss(rssItem(TITLE, GAP_AUDIO)));
  assert.equal(await findAppleEpisodeAudio(PAGE, { fetch }), null);
  assert.equal(asked.length, 1, 'only Apple was asked');
});

test('an episode Apple lists with audio never reads the feed', async () => {
  const asked: string[] = [];
  const fetch: FetchLike = async (input) => {
    asked.push(input);
    return new Response(JSON.stringify(lookup([episode({})])));
  };
  const found = await findAppleEpisodeAudio(PAGE, { fetch, feed: { title: TITLE, fetch } });
  assert.equal(found?.audioUrl, 'https://feeds.soundcloud.com/stream/559432260-resourcesradio-people-parks-and-policy.mp3');
  assert.equal(asked.length, 1);
});

test('two feed items with the title, or none, give no audio (never a guess)', async () => {
  const twins = lookupThenFeed(rss(rssItem(TITLE, GAP_AUDIO), rssItem('People Parks and Policy with RFFs Margaret Walls', 'https://example.com/twin.mp3')));
  assert.equal(await findAppleEpisodeAudio(PAGE, { fetch: twins.fetch, feed: { title: TITLE, fetch: twins.fetch } }), null);
  const none = lookupThenFeed(rss(rssItem('Something else', 'https://example.com/else.mp3')));
  assert.equal(await findAppleEpisodeAudio(PAGE, { fetch: none.fetch, feed: { title: TITLE, fetch: none.fetch } }), null);
});

test('a show row with no usable feed address reads no feed', async () => {
  for (const feedUrl of [undefined, '', 'not a url', 'ftp://example.com/feed', 'file:///etc/passwd', 'javascript:alert(1)']) {
    const { fetch, asked } = lookupThenFeed(rss(rssItem(TITLE, GAP_AUDIO)), { wrapperType: 'track', kind: 'podcast', ...(feedUrl !== undefined && { feedUrl }) });
    assert.equal(await findAppleEpisodeAudio(PAGE, { fetch, feed: { title: TITLE, fetch } }), null, String(feedUrl));
    assert.equal(asked.length, 1, `${feedUrl}: only Apple was asked`);
  }
});

test('a feed the browser can\'t read asks for the relay\'s consent, and reads through it once given', async () => {
  const blocked = new TypeError('Failed to fetch');
  const direct = lookupThenFeed(blocked);
  await assert.rejects(findAppleEpisodeAudio(PAGE, { fetch: direct.fetch, feed: { title: TITLE, fetch: direct.fetch, relayBase: 'https://relay.example' } }), NeedsRelayConsent);

  const asked: string[] = [];
  const fetch: FetchLike = async (input) => {
    asked.push(input);
    if (input.startsWith('https://itunes.apple.com/lookup')) return new Response(JSON.stringify({ results: [{ wrapperType: 'track', kind: 'podcast', feedUrl: FEED_URL }] }));
    if (input === FEED_URL) throw blocked;
    return new Response(rss(rssItem(TITLE, GAP_AUDIO)), { headers: { 'x-final-url': FEED_URL } });
  };
  const found = await findAppleEpisodeAudio(PAGE, { fetch, feed: { title: TITLE, fetch, consent: true, relayBase: 'https://relay.example' } });
  assert.equal(found?.audioUrl, GAP_AUDIO);
  assert.deepEqual(asked.slice(1), [FEED_URL, `https://relay.example/api/v1/relay?url=${encodeURIComponent(FEED_URL)}`]);
});

test('a feed that errors says so once, and one that is not a feed or is too large is simply no audio', async () => {
  const down = lookupThenFeed(rss());
  const refusing: FetchLike = async (input) => (input.startsWith('https://itunes') ? down.fetch(input) : new Response('busy', { status: 503 }));
  await assert.rejects(findAppleEpisodeAudio(PAGE, { fetch: refusing, feed: { title: TITLE, fetch: refusing } }), AppleLookupError);
  const html = lookupThenFeed('<html><body>Not a feed</body></html>');
  assert.equal(await findAppleEpisodeAudio(PAGE, { fetch: html.fetch, feed: { title: TITLE, fetch: html.fetch } }), null);
  const lookupOnly = lookupThenFeed(rss());
  const huge: FetchLike = async (input) => (input.startsWith('https://itunes') ? lookupOnly.fetch(input) : new Response('x', { headers: { 'content-length': String(8 * 1024 * 1024) } }));
  assert.equal(await findAppleEpisodeAudio(PAGE, { fetch: huge, feed: { title: TITLE, fetch: huge } }), null);
});

test('a twin of the title with no audio still makes it not unique, as the feed reader leaves such an item out unless asked', async () => {
  const twinNoAudio = '<item><title>People Parks and Policy with RFF’s Margaret Walls</title><guid>twin</guid></item>';
  const { fetch } = lookupThenFeed(rss(rssItem(TITLE, GAP_AUDIO), twinNoAudio));
  assert.equal(await findAppleEpisodeAudio(PAGE, { fetch, feed: { title: TITLE, fetch } }), null);
});

test('titles one character apart in a number are different episodes, even when the real one is missing from the feed', async () => {
  const { fetch } = lookupThenFeed(rss(rssItem('Episode 15', 'https://example.com/15.mp3')));
  assert.equal(await findAppleEpisodeAudio(PAGE, { fetch, feed: { title: 'Episode 1.5', fetch } }), null);
});

test('a feed longer than the items read is never matched, as a twin may lie beyond them', async () => {
  const many = Array.from({ length: 5_001 }, (_, i) => rssItem(i === 4_000 ? TITLE : `Item ${i}`, `https://example.com/${i}.mp3`)).join('');
  const { fetch } = lookupThenFeed(rss(many));
  assert.equal(await findAppleEpisodeAudio(PAGE, { fetch, feed: { title: TITLE, fetch } }), null);
});

test('a feed that never answers ends at its limit with a plain error, never a hang', async () => {
  const lookupOnly = lookupThenFeed(rss());
  const silent: FetchLike = (input) => (input.startsWith('https://itunes') ? lookupOnly.fetch(input) : new Promise<Response>(() => {}));
  const started = Date.now();
  await assert.rejects(findAppleEpisodeAudio(PAGE, { fetch: silent, feed: { title: TITLE, fetch: silent, timeoutMs: 40 } }), AppleLookupError);
  assert.ok(Date.now() - started < 2_000, 'it rejected, it did not hang');
});
