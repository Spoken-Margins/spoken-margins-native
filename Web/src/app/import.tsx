// Opening a `.spokenmargins` file, however it arrives: the file picker on the Library and Margins tabs (#3039), a
// file dropped on the app, a file the installed app is opened with (desktop Chrome and Edge), (installed on Android)
// the share sheet through the service worker, or a share link (#3003), whose packet is fetched sealed and opened
// with the key in its `#` part. Each lands the listener on the first Margin's moment in Now Playing (#2979).
import { useCallback, useEffect, useRef, type ReactNode } from 'react';
import { useData } from './data.tsx';
import { packetsToOpen } from './logic/backup.ts';
import { importSummary, placeImport, type Landing } from './logic/import.ts';
import { packetPickerAccept, packetRoute } from './logic/native-packets.ts';
import { plainError } from './logic/messages.ts';
import { NotSavedError } from './logic/storage.ts';
import { LINK_MESSAGES, ShareLinkError, openSharedPacket, type ParsedLink } from './logic/share-link.ts';
import { usePlayer } from './player.tsx';
import { services } from './services.ts';
import { useUi } from './ui.tsx';

export type OpenMarginFile = (bytes: Uint8Array, fileName: string | undefined) => Promise<void>;
export type OpenShareLink = (parsed: ParsedLink) => Promise<void>;

/** Reads a packet, stores its Margins (and its episode, when new) and opens Now Playing at the first one. */
function useLandPacket(onLanded: (landing: Landing) => void): (bytes: Uint8Array, fileName: string | undefined) => Promise<void> {
  const data = useData();
  const player = usePlayer();
  const { toast } = useUi();
  const dataRef = useRef(data);
  dataRef.current = data;

  return useCallback(
    async (bytes, fileName) => {
      const read = await services.packets.readPacket(bytes, fileName);
      const current = dataRef.current;
      const placed = placeImport(read, current.shows, current.episodes, undefined, current.margins);
      if (placed.show) await current.follow(placed.show, [placed.episode]);
      else if (placed.newEpisode) await current.updateEpisode(placed.episode);
      for (const margin of placed.margins) await current.addMargin(margin);
      toast(importSummary(placed, read.sender));
      if (placed.landAt === undefined) return;
      await player.open(placed.episode.id, { at: placed.landAt, episode: placed.episode });
      onLanded({ episodeId: placed.episode.id, at: placed.landAt });
    },
    [player, toast, onLanded],
  );
}

/** Opens one Margin file and calls `onLanded` once Now Playing should show its moment. */
export function useOpenMarginFile(onLanded: (landing: Landing) => void): OpenMarginFile {
  const land = useLandPacket(onLanded);
  const { toast } = useUi();
  return useCallback(
    async (bytes, fileName) => {
      try {
        await land(bytes, fileName);
      } catch (error) {
        // A write that failed has already said what wasn't saved.
        if (!(error instanceof NotSavedError)) toast(`Couldn’t open ${fileName ?? 'the file'}. ${plainError(error)}`, 'problem');
      }
    },
    [land, toast],
  );
}

/** Opens a share link's Margins. A damaged link, or one whose packet won't open, says so plainly. */
export function useOpenShareLink(onLanded: (landing: Landing) => void): OpenShareLink {
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
        // A write that failed has already said what wasn't saved. Otherwise it opened under the key but isn't a
        // packet this app can read.
        if (!(error instanceof NotSavedError)) toast(`${LINK_MESSAGES.damaged} ${plainError(error)}`, 'problem');
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

/**
 * Opens one file's bytes, from any way in. A backup `.zip` from Settings opens each packet in it (#3012); anything
 * else goes to the packet reader as it is, which says plainly when it isn't a Margin file.
 */
export async function openFileBytes(bytes: Uint8Array, fileName: string | undefined, open: OpenMarginFile): Promise<void> {
  for (const packet of await packetsToOpen(bytes, fileName)) await open(packet.bytes, packet.name);
}

/** Files from a drop or a picker, one at a time. */
export async function openFiles(files: Iterable<File>, open: OpenMarginFile): Promise<void> {
  for (const file of files) await openFileBytes(new Uint8Array(await file.arrayBuffer()), file.name, open);
}

/**
 * The Margin file picker: `input` goes once on a screen, and `choose` opens it from any button there. The input keeps
 * `data-testid="margin-file"` for the end-to-end tests.
 */
export function useMarginFilePicker(open: OpenMarginFile): { choose: () => void; input: ReactNode } {
  const picker = useRef<HTMLInputElement>(null);
  const choose = useCallback(() => picker.current?.click(), []);
  const input = (
    <input
      ref={picker}
      type="file"
      accept={packetPickerAccept(packetRoute())}
      hidden
      data-testid="margin-file"
      onChange={(event) => {
        const files = Array.from(event.target.files ?? []);
        event.target.value = '';
        void openFiles(files, open);
      }}
    />
  );
  return { choose, input };
}
