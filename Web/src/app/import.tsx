// Opening a `.spokenmargins` file, however it arrives: the file picker on the Margins tab, a file dropped on the
// app, (installed on Android) the share sheet through the service worker, or a share link (#3003), whose packet
// is fetched sealed and opened with the key in its `#` part. Each lands the listener on the first Margin's moment
// in Now Playing (#2979).
import { useCallback, useEffect, useRef } from 'react';
import { useData } from './data.tsx';
import { importSummary, placeImport } from './logic/import.ts';
import { plainError } from './logic/messages.ts';
import { LINK_MESSAGES, ShareLinkError, openSharedPacket, type ParsedLink } from './logic/share-link.ts';
import { usePlayer } from './player.tsx';
import { services } from './services.ts';
import { useUi } from './ui.tsx';

export type OpenMarginFile = (bytes: Uint8Array, fileName: string | undefined) => Promise<void>;
export type OpenShareLink = (parsed: ParsedLink) => Promise<void>;

/** Reads a packet, stores its Margins (and its episode, when new) and opens Now Playing at the first one. */
function useLandPacket(onLanded: () => void): (bytes: Uint8Array, fileName: string | undefined) => Promise<void> {
  const data = useData();
  const player = usePlayer();
  const { toast } = useUi();
  const dataRef = useRef(data);
  dataRef.current = data;

  return useCallback(
    async (bytes, fileName) => {
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
    },
    [player, toast, onLanded],
  );
}

/** Opens one Margin file and calls `onLanded` once Now Playing should show its moment. */
export function useOpenMarginFile(onLanded: () => void): OpenMarginFile {
  const land = useLandPacket(onLanded);
  const { toast } = useUi();
  return useCallback(
    async (bytes, fileName) => {
      try {
        await land(bytes, fileName);
      } catch (error) {
        toast(`Couldn’t open ${fileName ?? 'the file'}. ${plainError(error)}`, 'problem');
      }
    },
    [land, toast],
  );
}

/** Opens a share link's Margins. A damaged link, or one whose packet won't open, says so plainly. */
export function useOpenShareLink(onLanded: () => void): OpenShareLink {
  const land = useLandPacket(onLanded);
  const { toast } = useUi();
  return useCallback(
    async (parsed) => {
      if (parsed.kind === 'none') {
        toast(LINK_MESSAGES.notALink, 'problem');
        return;
      }
      if (parsed.kind === 'damaged') {
        toast(LINK_MESSAGES.damaged, 'problem');
        return;
      }
      let bytes: Uint8Array;
      try {
        bytes = await openSharedPacket(parsed.link);
      } catch (error) {
        toast(error instanceof ShareLinkError ? error.message : LINK_MESSAGES.damaged, 'problem');
        return;
      }
      try {
        await land(bytes, 'shared.spokenmargins');
      } catch (error) {
        // It opened under the key but isn't a packet this app can read.
        toast(`${LINK_MESSAGES.damaged} ${plainError(error)}`, 'problem');
      }
    },
    [land, toast],
  );
}

/** Opens the link the app was loaded with (`…/l/<id>#<key>`), once storage is ready, so the episode can match. */
export function useLaunchLink(link: ParsedLink, open: OpenShareLink): void {
  const data = useData();
  const handled = useRef(false);
  useEffect(() => {
    if (handled.current || !data.ready || link.kind === 'none') return;
    handled.current = true;
    void open(link);
  }, [data.ready, link, open]);
}

/** Files from a drop or a picker, one at a time. */
export async function openFiles(files: Iterable<File>, open: OpenMarginFile): Promise<void> {
  for (const file of files) await open(new Uint8Array(await file.arrayBuffer()), file.name);
}
