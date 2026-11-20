// Whether a friend's browser can play what a share link holds (#4454). One function answers it, so the arrival page and
// the sender's background check (`play-check.ts`) can never disagree: the page draws its card from this verdict, and
// the check reports it. Plain TypeScript with no DOM, so `npm run test:web` covers it.
//
// It says nothing about the audio's own address failing to load or being in a format the browser can't decode: that is
// only known by reading the audio, which the check does later and never through the player (#4454, PR 1b).
import type { PacketRead } from '../ports.ts';
import type { Episode } from '../../shared/model.ts';
import { isSubstackPostUrl } from '../../sources/substack.ts';
import { playableArticleMargins } from './arrival.ts';

/**
 * Why a link can't be played in a browser, as far as the packet and a post's voice lookup say.
 * - `article`: the Margins sit on an article's own text, which the browser can't play yet.
 * - `no-episode-audio`: an episode with no audio address and no Substack post to look one up on (a page of any other kind counts as none, #4767).
 * - `paid-post`: a Substack post whose voice is behind the paywall.
 * - `no-post-voice`: a post page that has no voice to find.
 */
export type CannotPlayReason = 'article' | 'no-episode-audio' | 'paid-post' | 'no-post-voice';

/**
 * Where an episode's voice comes from in a browser (#4767). One answer for the arrival card, the Library tag, the
 * player and the "play newest" walk, so none of them promises a voice another would refuse.
 * - `own`: the episode has an audio address.
 * - `post-lookup`: no audio address, and the page is a Substack post, whose page is read for a voice when the listener taps it.
 * - `none`: nothing the browser can play. An Apple Podcasts or Spotify page, or any other site's page, is not a Substack
 *   post and has no voice to look up; the iPhone app can resolve such a page, a browser can't.
 */
export type EpisodeVoice = 'own' | 'post-lookup' | 'none';

export function episodeVoice(episode: Pick<Episode, 'audioUrl' | 'pageUrl'>): EpisodeVoice {
  if (episode.audioUrl) return 'own';
  return episode.pageUrl && isSubstackPostUrl(episode.pageUrl) ? 'post-lookup' : 'none';
}

/** What looking up a post's voice found: a voice, a paywall, or nothing. */
export type VoiceLookup = 'found' | 'paid' | 'none';

export type Playability =
  | { verdict: 'plays' }
  | { verdict: 'cannot'; reason: CannotPlayReason }
  /** The episode has no audio address of its own; its post's page must be read for a voice. Only the lookup can settle it. */
  | { verdict: 'needs-voice-lookup'; pageUrl: string };

/**
 * What a browser can do with this packet. `voice` is the outcome of the post-voice lookup when one was made
 * (`player.tsx` makes it on the friend's tap); without it, a post with no audio address of its own is
 * `needs-voice-lookup` and never guessed at.
 */
export function playability(read: Pick<PacketRead, 'episode' | 'margins' | 'percentMargins'>, voice?: VoiceLookup): Playability {
  // Only a packet with nothing to play is the text-only card: an article's Margins that carry a rough place play on its voice (#4421).
  if (read.margins.length === 0 && playableArticleMargins(read).length === 0) return { verdict: 'cannot', reason: 'article' };
  const source = episodeVoice(read.episode);
  if (source === 'own') return { verdict: 'plays' };
  if (source === 'none') return { verdict: 'cannot', reason: 'no-episode-audio' };
  const pageUrl = read.episode.pageUrl as string;
  if (voice === 'found') return { verdict: 'plays' };
  if (voice === 'paid') return { verdict: 'cannot', reason: 'paid-post' };
  if (voice === 'none') return { verdict: 'cannot', reason: 'no-post-voice' };
  return { verdict: 'needs-voice-lookup', pageUrl };
}
