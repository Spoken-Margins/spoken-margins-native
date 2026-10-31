// Opening a `.spokenmargins` file, however it arrives: the file picker on the Margins tab, a file dropped on the
// app, or (installed on Android) the share sheet through the service worker. Each lands the listener on the
// first Margin's moment in Now Playing (#2979).
import { useCallback, useRef } from 'react';
import { useData } from './data.tsx';
import { importSummary, placeImport } from './logic/import.ts';
import { plainError } from './logic/messages.ts';
import { usePlayer } from './player.tsx';
import { services } from './services.ts';
import { useUi } from './ui.tsx';

export type OpenMarginFile = (bytes: Uint8Array, fileName: string | undefined) => Promise<void>;

/** Opens one Margin file and calls `onLanded` once Now Playing should show its moment. */
export function useOpenMarginFile(onLanded: () => void): OpenMarginFile {
  const data = useData();
  const player = usePlayer();
  const { toast } = useUi();
  const dataRef = useRef(data);
  dataRef.current = data;

  return useCallback(
    async (bytes, fileName) => {
      const label = fileName ?? 'the file';
      try {
        const read = await services.packets.readPacket(bytes, fileName);
        const current = dataRef.current;
        const placed = placeImport(read, current.shows, current.episodes);
        if (placed.show) await current.follow(placed.show, [placed.episode]);
        else if (placed.newEpisode) await current.updateEpisode(placed.episode);
        for (const margin of placed.margins) await current.addMargin(margin);
        toast(importSummary(placed, read.sender));
        if (placed.landAt === undefined) return;
        await player.open(placed.episode.id, { at: placed.landAt, episode: placed.episode });
        onLanded();
      } catch (error) {
        toast(`Couldn’t open ${label}. ${plainError(error)}`, 'problem');
      }
    },
    [player, toast, onLanded],
  );
}

/** Files from a drop or a picker, one at a time. */
export async function openFiles(files: Iterable<File>, open: OpenMarginFile): Promise<void> {
  for (const file of files) await open(new Uint8Array(await file.arrayBuffer()), file.name);
}
