import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { PacketRead, PostVoice } from '../ports.ts';
import { settleAppleEpisode } from './apple-arrival.ts';
import { playability } from './playability.ts';

const APPLE = 'https://podcasts.apple.com/us/podcast/people-parks-and-policy-with-rffs-margaret-walls/id1445582279?i=1000427709574';
const margin = { id: 'm', episodeId: 'e', atSeconds: 30, createdAt: '2026-11-21T10:00:00Z', text: 'x', author: 'Cole' };
const read = (episode: object, margins: object[] = [margin]) =>
  ({ episode: { title: 'T', ...episode }, margins, percentMargins: [] }) as unknown as Pick<PacketRead, 'episode' | 'margins' | 'percentMargins'>;
const voice: PostVoice = { audioUrl: 'https://feeds.example.com/ep.mp3', audioOrigin: 'podcast-enclosure', durationSeconds: 1800 };

test('an Apple episode page with no audio gets the audio Apple\'s lookup found, and then plays', async () => {
  const asked: string[] = [];
  const settled = await settleAppleEpisode(read({ itemType: 'podcast', pageUrl: APPLE }), async (url) => (asked.push(url), voice));
  assert.deepEqual(asked, [APPLE]);
  assert.equal(settled.lookup, 'found');
  assert.equal(settled.read.episode.audioUrl, voice.audioUrl);
  assert.equal(settled.read.episode.audioOrigin, 'podcast-enclosure');
  assert.equal(settled.read.episode.pageUrl, APPLE, 'the page stays the episode\'s identity');
  assert.deepEqual(playability(settled.read, settled.lookup), { verdict: 'plays' });
});

test('the packet\'s own length is kept; Apple\'s only fills a length the packet lacks', async () => {
  const kept = await settleAppleEpisode(read({ pageUrl: APPLE, durationSeconds: 1500 }), async () => voice);
  assert.equal(kept.read.episode.durationSeconds, 1500);
  const filled = await settleAppleEpisode(read({ pageUrl: APPLE }), async () => voice);
  assert.equal(filled.read.episode.durationSeconds, 1800);
});

test('an episode Apple lists no audio for is settled as "none", and the card says it cannot play', async () => {
  const settled = await settleAppleEpisode(read({ pageUrl: APPLE }), async () => null);
  assert.equal(settled.lookup, 'none');
  assert.equal(settled.read.episode.audioUrl, undefined);
  assert.deepEqual(playability(settled.read, settled.lookup), { verdict: 'cannot', reason: 'no-episode-audio' });
});

test('a lookup that could not be answered settles nothing: the friend\'s tap on Play asks again', async () => {
  const input = read({ pageUrl: APPLE });
  const settled = await settleAppleEpisode(input, async () => {
    throw new Error('offline');
  });
  assert.equal(settled.lookup, undefined);
  assert.equal(settled.read, input);
  assert.equal(playability(settled.read, settled.lookup).verdict, 'needs-voice-lookup');
});

test('no other packet is looked up: own audio, a Substack post, Spotify, an article, a file', async () => {
  const never = async (): Promise<PostVoice | null> => {
    throw new Error('should not be asked');
  };
  for (const input of [
    read({ audioUrl: 'https://example.com/a.mp3', pageUrl: APPLE }),
    read({ pageUrl: 'https://thezvi.substack.com/p/leaked-anthropic-draft' }),
    read({ pageUrl: 'https://open.spotify.com/episode/4rOoJ6Egrf8K2IrywzwOMk' }),
    read({ pageUrl: APPLE }, []),
    read({}),
  ]) {
    const settled = await settleAppleEpisode(input, never);
    assert.equal(settled.read, input);
    assert.equal(settled.lookup, undefined);
  }
});

test('rough-place Margins on an Apple episode page are not the text-only card: Apple\'s audio can carry them', async () => {
  const rough = { margin: { ...margin, atSeconds: 0 }, percent: 20 };
  const input = { ...read({ pageUrl: APPLE }, []), percentMargins: [rough] } as unknown as Pick<PacketRead, 'episode' | 'margins' | 'percentMargins'>;
  assert.deepEqual(playability(input).verdict, 'needs-voice-lookup');
  const settled = await settleAppleEpisode(input, async () => voice);
  assert.deepEqual(playability(settled.read, settled.lookup), { verdict: 'plays' });
});
