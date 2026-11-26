// Whether a friend's browser can play what a share link holds (#4454). One function answers it, so the arrival page and
// the sender's background check (`play-check.ts`) can never disagree: the page draws its card from this verdict, and
// the check reports it. Plain TypeScript with no DOM, so `npm run test:web` covers it.
//
// It says nothing about the audio's own address failing to load or being in a format the browser can't decode: that is
// only known by reading the audio, which the check does later and never through the player (#4454, PR 1b).
import type { PacketRead } from '../ports.ts';
import type { Episode } from '../../shared/model.ts';
import { appleEpisodeRef } from '../../sources/apple.ts';
import { isSubstackPostUrl } from '../../sources/substack.ts';
import { playableArticleMargins } from './arrival.ts';
import { findEpisode } from './import.ts';

/**
 * Why a link can't be played in a browser, as far as the packet and a post's voice lookup say.
 * - `article`: the Margins sit on an article's own text, which the browser can't play yet.
 * - `no-episode-audio`: an episode with no audio address and no Substack post or Apple Podcasts episode page to look one up on (a page of any other kind counts as none, #4767), or an Apple episode its lookup doesn't list with audio.
 * - `paid-post`: a Substack post whose voice is behind the paywall.
 * - `no-post-voice`: a post page that has no voice to find.
 */
export type CannotPlayReason = 'article' | 'no-episode-audio' | 'paid-post' | 'no-post-voice';

/**
 * Where an episode's voice comes from in a browser (#4767, #4783). One answer for the arrival card, the Library tag, the
 * player, the sender's check and the "play newest" walk, so none of them promises a voice another would refuse.
 * - `own`: the episode has an audio address.
 * - `post-lookup`: no audio address, and the page is a Substack post, whose page is read for a voice when the listener taps it.
 * - `apple-lookup`: no audio address, and the page is an Apple Podcasts episode page, whose audio Apple's public lookup
 *   gives for that very episode when the listener taps it.
 * - `none`: nothing the browser can play. A Spotify page, an Apple show page with no episode, or any other site's page
 *   has nothing to look up; the iPhone app can resolve some of them, a browser can't.
 */
export type EpisodeVoice = 'own' | 'post-lookup' | 'apple-lookup' | 'none';

export function episodeVoice(episode: Pick<Episode, 'audioUrl' | 'pageUrl'>): EpisodeVoice {
  if (episode.audioUrl) return 'own';
  const page = episode.pageUrl;
  if (!page) return 'none';
  if (isSubstackPostUrl(page)) return 'post-lookup';
  return appleEpisodeRef(page) ? 'apple-lookup' : 'none';
}

/** What looking up a post's voice found: a voice, a paywall, or nothing. */
export type VoiceLookup = 'found' | 'paid' | 'none';

export type Playability =
  | { verdict: 'plays' }
  | { verdict: 'cannot'; reason: CannotPlayReason }
  /**
   * The episode has no audio address of its own: a Substack post's page must be read for a voice, or an Apple Podcasts
   * episode's audio asked of Apple's lookup. Only that lookup can settle it.
   */
  | { verdict: 'needs-voice-lookup'; pageUrl: string; source: 'substack-post' | 'apple-episode' };

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
  if (source === 'apple-lookup') {
    // Apple's lookup has no paywall: an episode it doesn't list with audio is an episode with no audio to find.
    return voice === undefined ? { verdict: 'needs-voice-lookup', pageUrl, source: 'apple-episode' } : { verdict: 'cannot', reason: 'no-episode-audio' };
  }
  if (voice === 'paid') return { verdict: 'cannot', reason: 'paid-post' };
  if (voice === 'none') return { verdict: 'cannot', reason: 'no-post-voice' };
  return { verdict: 'needs-voice-lookup', pageUrl, source: 'substack-post' };
}

/**
 * What a packet is about, for the words on the card a browser shows when it can't play the Margins (#5265). It comes from
 * the packet's `item.itemType` and whether it has a web address:
 * - `article`: text with a web address; `text`: text with none (a pasted text, a Spoken Note);
 * - `pdf`, `book` (an EPUB), `episode` (a podcast), `recording` (`other`: an audiobook or another recording).
 * With no `itemType`, or one it doesn't know: `episode` when the packet has timed Margins, else `article` or `text`.
 */
export type ItemKind = 'article' | 'text' | 'pdf' | 'book' | 'episode' | 'recording';

export function itemKind(read: Pick<PacketRead, 'itemType' | 'episode' | 'margins'>): ItemKind {
  const addressed = webAddress(read.episode.pageUrl) !== undefined;
  switch (read.itemType) {
    case 'text':
      return addressed ? 'article' : 'text';
    case 'pdf':
      return 'pdf';
    case 'epub':
      return 'book';
    case 'podcast':
      return 'episode';
    case 'other':
      return 'recording';
    default:
      if (read.margins.length > 0) return 'episode';
      return addressed ? 'article' : 'text';
  }
}

/** An address that is safe to offer as a tap: http or https only. */
export function webAddress(value: string | undefined): string | undefined {
  if (!value) return undefined;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.href : undefined;
  } catch {
    return undefined;
  }
}

/**
 * The packet with the listener's own copy's audio put on its episode, when a link whose episode has no audio names an
 * episode the listener's web Library already holds with audio (#5265): Arrival asks `playability` of this instead, so
 * the friend gets the Play card on their own copy. Undefined when there is no such copy.
 */
export function withOwnedAudio<R extends PacketRead>(read: R, episodes: readonly Episode[]): R | undefined {
  const own = findEpisode(read, episodes);
  if (!own?.audioUrl) return undefined;
  return { ...read, episode: { ...read.episode, audioUrl: own.audioUrl, ...(own.audioOrigin && { audioOrigin: own.audioOrigin }) } };
}

/** Whether the listener's own copy of the episode makes a `no-episode-audio` link play (#5265). */
export function ownedCopyPlays(read: PacketRead, episodes: readonly Episode[]): boolean {
  const owned = withOwnedAudio(read, episodes);
  return owned !== undefined && playability(owned).verdict === 'plays';
}
