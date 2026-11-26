import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Margin, PercentMargin } from '../../shared/model.ts';
import type { PacketRead } from '../ports.ts';
import { playableArticleMargins } from './arrival.ts';
import { episodeVoice, itemKind, ownedCopyPlays, playability, webAddress, withOwnedAudio } from './playability.ts';

const margin = (id: string): Margin => ({ id, episodeId: 'e', atSeconds: 30, createdAt: '2026-11-17T10:00:00Z', text: `words ${id}`, author: 'Cole' });
const percent = (id: string): PercentMargin => ({ margin: { ...margin(id), atSeconds: 0 }, percent: 20 }) as PercentMargin;

type Read = Pick<PacketRead, 'episode' | 'margins' | 'percentMargins'>;
const read = (episode: Partial<PacketRead['episode']>, margins: Margin[] = [margin('m1')], percentMargins: PercentMargin[] = []): Read => ({
  episode: { title: 'T', ...episode } as PacketRead['episode'],
  margins,
  percentMargins,
});

const POST = 'https://thezvi.substack.com/p/leaked-anthropic-draft-ai-regulatory';
const MP3 = 'https://example.com/podcast/ep1.mp3';
const APPLE = 'https://podcasts.apple.com/us/podcast/people-parks-and-policy-with-rffs-margaret-walls/id1445582279?i=1000427709574';

// The fixtures a share link can hold, each with the verdict a friend's browser must give.
const cases: Array<{ name: string; read: Read; verdict: ReturnType<typeof playability> }> = [
  { name: 'a public podcast MP3', read: read({ audioUrl: MP3 }), verdict: { verdict: 'plays' } },
  { name: 'an episode with a page and audio', read: read({ audioUrl: MP3, pageUrl: 'https://example.com/ep1' }), verdict: { verdict: 'plays' } },
  { name: 'a Substack podcast post (the #4433 case)', read: read({ pageUrl: POST }, [], [percent('p1')]), verdict: { verdict: 'needs-voice-lookup', pageUrl: POST, source: 'substack-post' } },
  { name: 'a post whose Margins have a time', read: read({ pageUrl: POST }), verdict: { verdict: 'needs-voice-lookup', pageUrl: POST, source: 'substack-post' } },
  { name: 'a text-only Substack post with no Margins', read: read({ pageUrl: POST }, [], []), verdict: { verdict: 'cannot', reason: 'article' } },
  { name: 'an article on any other site, no Margins', read: read({ pageUrl: 'https://example.com/essay' }, [], []), verdict: { verdict: 'cannot', reason: 'article' } },
  { name: 'an article with only rough-place Margins, not a Substack post', read: read({ pageUrl: 'https://example.com/essay' }, [], [percent('p1')]), verdict: { verdict: 'cannot', reason: 'article' } },
  { name: 'a PDF (no audio, no page)', read: read({}, [], []), verdict: { verdict: 'cannot', reason: 'article' } },
  { name: 'a private-feed episode with Margins but no audio or page', read: read({}), verdict: { verdict: 'cannot', reason: 'no-episode-audio' } },
  // #4767: a podcast shared from an Apple Podcasts or Spotify page carries that page and no audio address. Neither is a
  // Substack post, so no Substack voice is looked up on it. #4783: an Apple Podcasts episode page names its episode, so
  // Apple's public lookup can give its audio, on the friend's tap; a page with nothing to look up is "can't play".
  { name: 'an Apple Podcasts episode page with no audio address (the #4767 / #4783 case)', read: read({ itemType: 'podcast', pageUrl: APPLE }), verdict: { verdict: 'needs-voice-lookup', pageUrl: APPLE, source: 'apple-episode' } },
  { name: 'an Apple Podcasts show page with no episode in it', read: read({ itemType: 'podcast', pageUrl: 'https://podcasts.apple.com/us/podcast/people-parks-and-policy/id1445582279' }), verdict: { verdict: 'cannot', reason: 'no-episode-audio' } },
  { name: 'an Apple Podcasts page naming two episodes', read: read({ itemType: 'podcast', pageUrl: `${APPLE}&i=1000427709575` }), verdict: { verdict: 'cannot', reason: 'no-episode-audio' } },
  { name: 'an Apple page whose episode id is not a number', read: read({ itemType: 'podcast', pageUrl: 'https://podcasts.apple.com/us/podcast/x/id1445582279?i=abc' }), verdict: { verdict: 'cannot', reason: 'no-episode-audio' } },
  { name: 'a lookalike host with an Apple-shaped page', read: read({ itemType: 'podcast', pageUrl: 'https://podcasts.apple.com.example.org/us/podcast/x/id1445582279?i=1000427709574' }), verdict: { verdict: 'cannot', reason: 'no-episode-audio' } },
  { name: 'an Apple page over plain http', read: read({ itemType: 'podcast', pageUrl: APPLE.replace('https:', 'http:') }), verdict: { verdict: 'cannot', reason: 'no-episode-audio' } },
  { name: 'a Spotify episode page with no audio address', read: read({ itemType: 'podcast', pageUrl: 'https://open.spotify.com/episode/4rOoJ6Egrf8K2IrywzwOMk' }), verdict: { verdict: 'cannot', reason: 'no-episode-audio' } },
  { name: 'any other site\'s episode page with no audio address', read: read({ itemType: 'podcast', pageUrl: 'https://example.com/podcast/episode-1' }), verdict: { verdict: 'cannot', reason: 'no-episode-audio' } },
  { name: 'an Apple Podcasts page with a timed Margin and a rough-place one', read: read({ pageUrl: APPLE }, [margin('m1')], [percent('p1')]), verdict: { verdict: 'needs-voice-lookup', pageUrl: APPLE, source: 'apple-episode' } },
  { name: 'a shared open.substack.com post link', read: read({ pageUrl: 'https://open.substack.com/pub/dwarkesh/p/paul-christiano-2' }), verdict: { verdict: 'needs-voice-lookup', pageUrl: 'https://open.substack.com/pub/dwarkesh/p/paul-christiano-2', source: 'substack-post' } },
  { name: 'an Apple Podcasts page that does come with its audio address', read: read({ pageUrl: APPLE, audioUrl: 'https://feeds.soundcloud.com/stream/559432260-resourcesradio-people-parks-and-policy-with-rffs-margaret-walls.mp3' }), verdict: { verdict: 'plays' } },
  { name: 'rough-place Margins on an audio episode', read: read({ audioUrl: MP3 }, [], [percent('p1')]), verdict: { verdict: 'plays' } },
];

for (const c of cases) {
  test(`playability: ${c.name}`, () => {
    assert.deepEqual(playability(c.read), c.verdict);
  });
}

test('a post with no audio address is settled only by the voice lookup, and each outcome has its own verdict', () => {
  const post = read({ pageUrl: POST });
  assert.deepEqual(playability(post, 'found'), { verdict: 'plays' });
  assert.deepEqual(playability(post, 'paid'), { verdict: 'cannot', reason: 'paid-post' });
  assert.deepEqual(playability(post, 'none'), { verdict: 'cannot', reason: 'no-post-voice' });
  assert.deepEqual(playability(post), { verdict: 'needs-voice-lookup', pageUrl: POST, source: 'substack-post' });
});

test('an Apple episode is settled by Apple\'s lookup: found plays, and anything else is an episode with no audio to find', () => {
  const apple = read({ pageUrl: APPLE });
  assert.deepEqual(playability(apple, 'found'), { verdict: 'plays' });
  assert.deepEqual(playability(apple, 'none'), { verdict: 'cannot', reason: 'no-episode-audio' });
  // Apple has no paywall to report: a stray `paid` is still "no audio", never a Substack message.
  assert.deepEqual(playability(apple, 'paid'), { verdict: 'cannot', reason: 'no-episode-audio' });
  assert.deepEqual(playability(apple, undefined), { verdict: 'needs-voice-lookup', pageUrl: APPLE, source: 'apple-episode' });
});

test('a lookup outcome never changes a packet that already has its own audio, or has nothing to play', () => {
  assert.deepEqual(playability(read({ audioUrl: MP3 }), 'none'), { verdict: 'plays' });
  assert.deepEqual(playability(read({ audioUrl: MP3 }), 'paid'), { verdict: 'plays' });
  assert.deepEqual(playability(read({ pageUrl: POST }, [], []), 'found'), { verdict: 'cannot', reason: 'article' });
  assert.deepEqual(playability(read({}), 'found'), { verdict: 'cannot', reason: 'no-episode-audio' });
});

test('the arrival page and the check agree: the text-only card is exactly the `article` verdict', () => {
  for (const c of cases) {
    const textOnly = c.read.margins.length === 0 && playableArticleMargins(c.read).length === 0;
    const verdict = playability(c.read);
    assert.equal(verdict.verdict === 'cannot' && verdict.reason === 'article', textOnly, c.name);
  }
});

// #4767: the Library tag, the player's lookup and the "play newest" walk ask the same question as the arrival card, so
// a page that is not a Substack post is never called a post, looked up, or promised a voice.
test('episodeVoice: own audio, a Substack post or an Apple episode to look up, or none', () => {
  assert.equal(episodeVoice({ audioUrl: MP3 }), 'own');
  assert.equal(episodeVoice({ audioUrl: MP3, pageUrl: APPLE }), 'own');
  assert.equal(episodeVoice({ pageUrl: POST }), 'post-lookup');
  assert.equal(episodeVoice({ pageUrl: APPLE }), 'apple-lookup');
  assert.equal(episodeVoice({ pageUrl: 'https://itunes.apple.com/us/podcast/x/id1445582279?i=1000427709574' }), 'apple-lookup');
  assert.equal(episodeVoice({ pageUrl: 'https://podcasts.apple.com/us/podcast/x/id1445582279' }), 'none');
  assert.equal(episodeVoice({ pageUrl: 'https://open.spotify.com/episode/4rOoJ6Egrf8K2IrywzwOMk' }), 'none');
  assert.equal(episodeVoice({}), 'none');
});

// #5265: the card for a link a browser can't play takes its nouns from what the Margins sit on.
const typed = (itemType: string | undefined, episode: Partial<PacketRead['episode']>, margins: Margin[] = [], percentMargins: PercentMargin[] = []) => ({
  ...read(episode, margins, percentMargins),
  ...(itemType !== undefined && { itemType }),
});

test('the cannot-play cases of #5265: a PDF, a book, a pasted text, a recording, a podcast with only places', () => {
  const rows: Array<[string, ReturnType<typeof typed>, ReturnType<typeof playability>]> = [
    ['a PDF with no address', typed('pdf', {}, [], [percent('p')]), { verdict: 'cannot', reason: 'article' }],
    ['a PDF with an address', typed('pdf', { pageUrl: 'https://example.com/paper.pdf' }, [], [percent('p')]), { verdict: 'cannot', reason: 'article' }],
    ['an EPUB', typed('epub', {}, [], []), { verdict: 'cannot', reason: 'article' }],
    ['a pasted text', typed('text', {}, [], []), { verdict: 'cannot', reason: 'article' }],
    ['a recording with timed Margins and no audio', typed('other', {}, [margin('m')]), { verdict: 'cannot', reason: 'no-episode-audio' }],
    ['a podcast with only percent places and no length', typed('podcast', {}, [], [percent('p')]), { verdict: 'cannot', reason: 'article' }],
  ];
  for (const [name, r, verdict] of rows) assert.deepEqual(playability(r), verdict, name);
});

test('itemKind: every itemType, a missing one, and the fallbacks (#5265)', () => {
  const rows: Array<[string | undefined, Partial<PacketRead['episode']>, Margin[], string]> = [
    ['text', { pageUrl: 'https://example.com/essay' }, [], 'article'],
    ['text', {}, [], 'text'],
    ['text', { pageUrl: 'javascript:alert(1)' }, [], 'text'],
    ['pdf', {}, [], 'pdf'],
    ['pdf', { pageUrl: 'https://example.com/p.pdf' }, [], 'pdf'],
    ['epub', {}, [], 'book'],
    ['podcast', {}, [], 'episode'],
    ['other', {}, [margin('m')], 'recording'],
    [undefined, {}, [margin('m')], 'episode'],
    [undefined, { pageUrl: 'https://example.com/essay' }, [], 'article'],
    [undefined, {}, [], 'text'],
    ['newkind', {}, [], 'text'],
    ['newkind', {}, [margin('m')], 'episode'],
    ['', { pageUrl: 'https://example.com/x' }, [], 'article'],
  ];
  for (const [itemType, episode, margins, kind] of rows) assert.equal(itemKind(typed(itemType, episode, margins)), kind, `${itemType} ${JSON.stringify(episode)}`);
});

test('webAddress offers only http and https', () => {
  assert.equal(webAddress('https://example.com/a'), 'https://example.com/a');
  assert.equal(webAddress('http://example.com/a'), 'http://example.com/a');
  assert.equal(webAddress('javascript:alert(1)'), undefined);
  assert.equal(webAddress('file:///etc/passwd'), undefined);
  assert.equal(webAddress('not a url'), undefined);
  assert.equal(webAddress(undefined), undefined);
});

test('an owned copy with audio makes a no-audio link play; one without audio leaves it on the card (#5265)', () => {
  const packet = { contentDigest: 'd', textMarginCount: 0, pageMargins: [], ...read({ itemType: 'podcast', guid: 'g-1' }) } as PacketRead;
  assert.deepEqual(playability(packet), { verdict: 'cannot', reason: 'no-episode-audio' });
  const withAudio = [{ id: 'mine', showId: 's', title: 'Mine', guid: 'g-1', audioUrl: MP3 }];
  const withoutAudio = [{ id: 'mine', showId: 's', title: 'Mine', guid: 'g-1' }];
  assert.equal(ownedCopyPlays(packet, withAudio), true);
  assert.equal(withOwnedAudio(packet, withAudio)?.episode.audioUrl, MP3);
  assert.equal(ownedCopyPlays(packet, withoutAudio), false);
  assert.equal(ownedCopyPlays(packet, []), false);
  assert.equal(ownedCopyPlays(packet, [{ ...withAudio[0], guid: 'other' }]), false);
});

test('the listen-here card shows exactly when the verdict is cannot (article or no audio) and no owned copy plays', () => {
  for (const c of cases) {
    const v = playability(c.read);
    const card = v.verdict === 'cannot' && (v.reason === 'article' || v.reason === 'no-episode-audio');
    const packet = { contentDigest: 'd', textMarginCount: 0, pageMargins: [], ...c.read } as PacketRead;
    assert.equal(card && !ownedCopyPlays(packet, []), card, c.name);
  }
});
