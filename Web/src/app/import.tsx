// Opening a `.spokenmargins` file, however it arrives: the file picker on the Margins tab, a file dropped on the
// app, or (installed on Android) the share sheet through the service worker. Each lands the listener on the
// first Margin's moment in Now Playing (#2979).
import { useCallback, useRef } from 'react';
import { useData } from './data.tsx';
import { isBackupArchive, packetsInBackup } from './logic/backup.ts';
import { importSummary, placeImport } from './logic/import.ts';
import { plainError } from './logic/messages.ts';
import { NotSavedError } from './logic/storage.ts';
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
        const placed = placeImport(read, current.shows, current.episodes, undefined, current.margins);
        if (placed.show) await current.follow(placed.show, [placed.episode]);
        else if (placed.newEpisode) await current.updateEpisode(placed.episode);
        for (const margin of placed.margins) await current.addMargin(margin);
        toast(importSummary(placed, read.sender));
        if (placed.landAt === undefined) return;
        await player.open(placed.episode.id, { at: placed.landAt, episode: placed.episode });
        onLanded();
      } catch (error) {
        // A write that failed has already said what wasn't saved.
        if (!(error instanceof NotSavedError)) toast(`Couldn’t open ${label}. ${plainError(error)}`, 'problem');
      }
    },
    [player, toast, onLanded],
  );
}

/**
 * Files from a drop or a picker, one at a time. A backup `.zip` from Settings opens each packet in it (#3012); one
 * with no packets goes to the packet reader as it is, which says plainly that it isn't a Margin file.
 */
export async function openFiles(files: Iterable<File>, open: OpenMarginFile): Promise<void> {
  for (const file of files) {
    const bytes = new Uint8Array(await file.arrayBuffer());
    const packets = isBackupArchive(file.name) ? await packetsInBackup(bytes).catch(() => []) : [];
    if (packets.length === 0) {
      await open(bytes, file.name);
      continue;
    }
    for (const packet of packets) await open(packet.bytes, packet.name);
  }
}
