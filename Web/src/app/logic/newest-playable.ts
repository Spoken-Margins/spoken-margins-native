// The play button on a show's card (#3610): start the newest item that can actually play. Whether a Substack post has
// a voice anyone can hear is known only by reading its page, and that page is read only on a listener's tap, so the
// walk happens during the tap. Plain TypeScript with no DOM, so `npm run test:web` covers it.
import type { Episode } from '../../shared/model.ts';
import { MESSAGES } from './messages.ts';

/** How many post pages one tap may read. A show of nothing but paid posts must not cost twenty page reads. */
export const MAX_POST_LOOKUPS = 3;

/** How one attempt went. `stopped`: the player has already told the listener why, so the walk ends there. */
export type PlayAttempt = 'played' | 'paid' | 'no-voice' | 'stopped';

export interface NewestPlayableResult {
  outcome: 'played' | 'nothing-playable' | 'stopped';
  /** Why the newest item was passed over, when it was. */
  firstSkip?: 'paid' | 'no-voice';
}

/**
 * The items one tap will try, newest first: posts that need a page read, up to the limit, and it ends at the first
 * item whose audio is already known, since that one will play.
 */
export function playCandidates(newestFirst: readonly Episode[], maxLookups = MAX_POST_LOOKUPS): Episode[] {
  const candidates: Episode[] = [];
  let lookups = 0;
  for (const episode of newestFirst) {
    if (episode.audioUrl) {
      candidates.push(episode);
      break;
    }
    if (!episode.pageUrl || lookups >= maxLookups) continue;
    lookups += 1;
    candidates.push(episode);
  }
  return candidates;
}

/** Tries each candidate in turn until one plays or the player has stopped the walk. */
export async function playNewestAvailable(
  candidates: readonly Episode[],
  attempt: (episode: Episode) => Promise<PlayAttempt>,
): Promise<NewestPlayableResult> {
  let firstSkip: NewestPlayableResult['firstSkip'];
  for (const episode of candidates) {
    const result = await attempt(episode);
    if (result === 'played' || result === 'stopped') return firstSkip ? { outcome: result, firstSkip } : { outcome: result };
    firstSkip ??= result;
  }
  return firstSkip ? { outcome: 'nothing-playable', firstSkip } : { outcome: 'nothing-playable' };
}

/** The one line for the listener after the walk, if there is one to say. */
export function newestPlayableMessage(result: NewestPlayableResult): { text: string; tone?: 'problem' } | undefined {
  if (result.outcome === 'stopped') return undefined;
  if (result.outcome === 'played') return result.firstSkip ? { text: MESSAGES.newestSkipped } : undefined;
  return { text: result.firstSkip === 'paid' ? MESSAGES.paidPost : MESSAGES.noVoice, tone: 'problem' };
}
