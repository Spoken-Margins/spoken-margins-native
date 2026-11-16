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
  data: () => Pick<DataApi, 'margins' | 'addMargin'>,
): ((episode: Episode) => Promise<void>) | undefined {
  if (placed.pending.length === 0) return undefined;
  return async (episode) => {
    await saved.catch(() => undefined);
    const current = data();
    for (const margin of placeByPercent(placed.pending, episode, current.margins)) await current.addMargin(margin);
  };
}
