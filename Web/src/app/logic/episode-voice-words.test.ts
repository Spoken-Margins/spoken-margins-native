import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Margin, PercentMargin } from '../../shared/model.ts';
import type { PacketRead } from '../ports.ts';
import { messageForOpened } from '../play-check.ts';
import { ARRIVAL_WORDS } from './arrival.ts';
import { attemptToast, attemptWithoutAudio, libraryVoiceTag } from './episode-voice-words.ts';
import { MESSAGES } from './messages.ts';
import { episodeVoice, playability } from './playability.ts';

// The #4767 / #4783 promise: for every shape of packet, the Library tag, the arrival card, the player's words and the
// sender's check say one thing. A later edit to any one of them breaks a row here, not a friend's phone.
const margin: Margin = { id: 'm1', episodeId: 'e', atSeconds: 30, createdAt: '2026-11-21T10:00:00Z', text: 'x', author: 'Cole' };
const rough = { margin: { ...margin, id: 'p1', atSeconds: 0 }, percent: 20 } as PercentMargin;
type Read = Pick<PacketRead, 'episode' | 'margins' | 'percentMargins'>;
const read = (episode: object, margins: Margin[] = [margin], percentMargins: PercentMargin[] = []): Read =>
  ({ episode: { title: 'T', ...episode }, margins, percentMargins }) as Read;

const APPLE = 'https://podcasts.apple.com/us/podcast/people-parks-and-policy-with-rffs-margaret-walls/id1445582279?i=1000427709574';
const POST = 'https://thezvi.substack.com/p/leaked-anthropic-draft-ai-regulatory';

interface Shape {
  name: string;
  read: Read;
  voice: ReturnType<typeof episodeVoice>;
  tag: string;
  /** What the arrival card is: a Play button that works (`plays`), one that looks first (`looks up`), the Keep card, or the text-only card. */
  card: 'plays' | 'looks up' | 'keep only' | 'text only';
  /** The sender's check, with no app reads: what it can say from the packet alone. */
  check: ReturnType<typeof messageForOpened>;
  /** What a tap says when the episode still has no audio after any lookup (not asked of an episode with its own audio). */
  noAudioToast: string | undefined;
}

const shapes: Shape[] = [
  {
    name: 'an episode with an audio address',
    read: read({ itemType: 'podcast', audioUrl: 'https://example.com/ep1.mp3', pageUrl: APPLE }),
    voice: 'own',
    tag: 'New',
    card: 'plays',
    check: { type: 'verdict', verdict: 'plays' },
    noAudioToast: undefined,
  },
  {
    name: 'a Substack post (voice looked up on the tap)',
    read: read({ pageUrl: POST }, [], [rough]),
    voice: 'post-lookup',
    tag: 'Post, voice checked when you play',
    card: 'looks up',
    check: { type: 'verdict', verdict: 'unverified', why: 'post-voice' },
    noAudioToast: MESSAGES.noVoice,
  },
  {
    name: 'a Substack podcast post with a timed Margin',
    read: read({ itemType: 'podcast', pageUrl: POST }),
    voice: 'post-lookup',
    tag: 'Post, voice checked when you play',
    card: 'looks up',
    check: { type: 'verdict', verdict: 'unverified', why: 'post-voice' },
    noAudioToast: MESSAGES.noVoice,
  },
  {
    name: 'an Apple Podcasts episode page only (the owner\'s share)',
    read: read({ itemType: 'podcast', pageUrl: APPLE }),
    voice: 'apple-lookup',
    tag: 'Episode, audio found when you play',
    card: 'looks up',
    check: { type: 'verdict', verdict: 'unverified', why: 'post-voice' },
    noAudioToast: MESSAGES.noWebAudio,
  },
  {
    name: 'a Spotify episode page only',
    read: read({ itemType: 'podcast', pageUrl: 'https://open.spotify.com/episode/4rOoJ6Egrf8K2IrywzwOMk' }),
    voice: 'none',
    tag: 'No audio in the browser',
    card: 'keep only',
    check: { type: 'verdict', verdict: 'cannot', reason: 'no-episode-audio' },
    noAudioToast: MESSAGES.noWebAudio,
  },
  {
    name: 'another site\'s episode page only',
    read: read({ itemType: 'podcast', pageUrl: 'https://example.com/podcast/episode-1' }),
    voice: 'none',
    tag: 'No audio in the browser',
    card: 'keep only',
    check: { type: 'verdict', verdict: 'cannot', reason: 'no-episode-audio' },
    noAudioToast: MESSAGES.noWebAudio,
  },
  {
    name: 'a private-feed or imported audio file with timed Margins and no address at all (file, audiobook)',
    read: read({ itemType: 'podcast' }),
    voice: 'none',
    tag: 'No audio in the browser',
    card: 'keep only',
    check: { type: 'verdict', verdict: 'cannot', reason: 'no-episode-audio' },
    noAudioToast: MESSAGES.noWebAudio,
  },
  {
    name: 'an article on another site with no timed Margins',
    read: read({ itemType: 'text', pageUrl: 'https://example.com/essay' }, [], []),
    voice: 'none',
    tag: 'No audio in the browser',
    card: 'text only',
    check: { type: 'verdict', verdict: 'cannot', reason: 'article' },
    noAudioToast: MESSAGES.noWebAudio,
  },
];

for (const shape of shapes) {
  test(`one story for: ${shape.name}`, () => {
    assert.equal(episodeVoice(shape.read.episode), shape.voice, 'voice');
    assert.equal(libraryVoiceTag(shape.voice).text, shape.tag, 'the Library tag');
    const verdict = playability(shape.read);
    const card =
      verdict.verdict === 'plays' ? 'plays'
      : verdict.verdict === 'needs-voice-lookup' ? 'looks up'
      : verdict.reason === 'article' ? 'text only'
      : 'keep only';
    assert.equal(card, shape.card, 'the arrival card');
    assert.deepEqual(messageForOpened(shape.read), shape.check, 'the sender\'s check');
    // An episode with its own audio never reaches "no audio"; the others say what is true of their page.
    if (shape.voice !== 'own') assert.equal(attemptToast(attemptWithoutAudio(shape.voice)), shape.noAudioToast, 'the player\'s words');
    // The card never promises what the tag denies, and the tag never promises what the card refuses.
    if (shape.card === 'keep only') assert.match(libraryVoiceTag(shape.voice).text, /No audio/);
    if (shape.card === 'looks up') assert.match(libraryVoiceTag(shape.voice).text, /when you play/);
  });
}

test('a page that is not a Substack post is never told "no voice" (the #4767 class)', () => {
  for (const shape of shapes.filter((s) => s.voice !== 'post-lookup' && s.voice !== 'own')) {
    assert.notEqual(attemptToast(attemptWithoutAudio(shape.voice)), MESSAGES.noVoice, shape.name);
    assert.doesNotMatch(libraryVoiceTag(shape.voice).text, /^Post/, shape.name);
  }
});

test('the no-audio words point to the app, on the card and in the toast', () => {
  assert.match(ARRIVAL_WORDS.noEpisodeAudio('Cole'), /Spoken Margins app on iPhone/);
  assert.match(MESSAGES.noWebAudio, /Spoken Margins app on iPhone/);
});

test('only the player\'s own outcomes have words, and "played" and "stopped" have none', () => {
  assert.equal(attemptToast('played'), undefined);
  assert.equal(attemptToast('stopped'), undefined);
  assert.equal(attemptToast('paid'), MESSAGES.paidPost);
  assert.equal(attemptToast('no-voice'), MESSAGES.noVoice);
  assert.equal(attemptToast('no-audio'), MESSAGES.noWebAudio);
});
