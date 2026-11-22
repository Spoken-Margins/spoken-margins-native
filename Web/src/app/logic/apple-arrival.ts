// An Apple Podcasts episode link, settled when the friend opens it (#4783). The packet holds that episode's page and, for
// the owner's first such share, no audio address. Asking Apple's public lookup once, when the friend has opened the link
// themselves, means their Play tap starts sound at once: a browser lets sound start only inside the tap, and a lookup
// awaited after it can lose that. Plain TypeScript with no DOM, so `npm run test:web` covers it.
import type { PacketRead, PostVoice } from '../ports.ts';
import { playability, type VoiceLookup } from './playability.ts';

type Read = Pick<PacketRead, 'episode' | 'margins' | 'percentMargins'>;

export interface SettledArrival<R extends Read> {
  /** The packet, with the episode's audio filled in when Apple's lookup found it. */
  read: R;
  /**
   * What the lookup said: `found`, or `none` when Apple answered but lists no audio for that episode. Unset when nothing was
   * asked, or the lookup couldn't be answered (offline, a refusal): the friend's tap on Play asks again.
   */
  lookup?: VoiceLookup;
}

/** Asks `find` for the audio of an Apple Podcasts episode page with no audio address, and for no other packet. Never throws. */
export async function settleAppleEpisode<R extends Read>(read: R, find: (pageUrl: string) => Promise<PostVoice | null>): Promise<SettledArrival<R>> {
  const first = playability(read);
  if (first.verdict !== 'needs-voice-lookup' || first.source !== 'apple-episode') return { read };
  try {
    const found = await find(first.pageUrl);
    if (!found) return { read, lookup: 'none' };
    const episode = {
      ...read.episode,
      audioUrl: found.audioUrl,
      audioOrigin: found.audioOrigin,
      // The packet's own length is the edition its Margins were made on; Apple's only fills a length the packet lacks.
      ...(read.episode.durationSeconds === undefined && found.durationSeconds !== undefined && { durationSeconds: found.durationSeconds }),
    };
    return { read: { ...read, episode }, lookup: 'found' };
  } catch {
    return { read };
  }
}
