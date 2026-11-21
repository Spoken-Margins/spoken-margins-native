import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AppleLookupError, appleEpisodeRef, appleLookupUrl, findAppleEpisodeAudio, playableAudioAddress } from './apple.ts';
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
