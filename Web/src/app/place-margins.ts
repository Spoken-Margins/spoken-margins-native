// Puts a friend's article-text Margins onto the audio that plays the article (#4421). The player calls it, with the
// episode and the loaded audio's own length, once the audio reports it. Used by the share-link page; a Margin file opens
// no voice (importSummary says so).
import type { DataApi } from './data.tsx';
import { placeByPercent } from './logic/import.ts';
import type { PlacedImport } from './logic/import.ts';
import type { Episode } from '../shared/model.ts';

/**
 * The player's `placeMargins` for a placed packet, or undefined when it has no article-text Margins to place. `saved`
 * is the write that stores the packet's episode; the Margins go in after it, so none is stored before its episode.
 */
export function placeMarginsOnAudio(
  placed: Pick<PlacedImport, 'pending'>,
  saved: Promise<void>,
): ((episode: Episode, data: Pick<DataApi, 'margins' | 'addMargin'>) => Promise<void>) | undefined {
  if (placed.pending.length === 0) return undefined;
  // `data` comes from the player, which outlives the arrival page, so the Margins already here are today's.
  return async (episode, data) => {
    // A packet whose episode wasn't stored has said so already; no Margin goes in for an episode that isn't there.
    if (!(await saved.then(() => true, () => false))) return;
    for (const margin of placeByPercent(placed.pending, episode, data.margins)) await data.addMargin(margin);
  };
}
