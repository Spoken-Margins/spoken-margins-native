import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Margin, PercentMargin } from '../../shared/model.ts';
import type { PacketRead } from '../ports.ts';
import { ARRIVAL_WORDS, playableArticleMargins } from './arrival.ts';
import { playability } from './playability.ts';

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

// The fixtures a share link can hold, each with the verdict a friend's browser must give.
const cases: Array<{ name: string; read: Read; verdict: ReturnType<typeof playability> }> = [
  { name: 'a public podcast MP3', read: read({ audioUrl: MP3 }), verdict: { verdict: 'plays' } },
  { name: 'an episode with a page and audio', read: read({ audioUrl: MP3, pageUrl: 'https://example.com/ep1' }), verdict: { verdict: 'plays' } },
  { name: 'a Substack podcast post (the #4433 case)', read: read({ pageUrl: POST }, [], [percent('p1')]), verdict: { verdict: 'needs-voice-lookup', pageUrl: POST } },
  { name: 'a post whose Margins have a time', read: read({ pageUrl: POST }), verdict: { verdict: 'needs-voice-lookup', pageUrl: POST } },
  { name: 'a text-only Substack post with no Margins', read: read({ pageUrl: POST }, [], []), verdict: { verdict: 'cannot', reason: 'article' } },
  { name: 'an article on any other site, no Margins', read: read({ pageUrl: 'https://example.com/essay' }, [], []), verdict: { verdict: 'cannot', reason: 'article' } },
  { name: 'an article with only rough-place Margins, not a Substack post', read: read({ pageUrl: 'https://example.com/essay' }, [], [percent('p1')]), verdict: { verdict: 'cannot', reason: 'article' } },
  { name: 'a PDF (no audio, no page)', read: read({}, [], []), verdict: { verdict: 'cannot', reason: 'article' } },
  { name: 'a private-feed episode with Margins but no audio or page', read: read({}), verdict: { verdict: 'cannot', reason: 'no-episode-audio' } },
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
  assert.deepEqual(playability(post), { verdict: 'needs-voice-lookup', pageUrl: POST });
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
  assert.ok(ARRIVAL_WORDS.article('Cole').includes('can’t play yet'));
});
