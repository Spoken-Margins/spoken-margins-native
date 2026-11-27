// Opening a `.spokenmargins` file, however it arrives: the file picker on the Library and Margins tabs (#3039), a
// file dropped on the app, a file the installed app is opened with (desktop Chrome and Edge), (installed on Android)
// the share sheet through the service worker, or a share link (#3003), whose packet is fetched sealed and opened
// with the key in its `#` part. Each lands the listener on the first Margin's moment in Now Playing (#2979). A page
// opened at a link starts on the arrival page instead (screens/Arrival.tsx, #2168).
import { useCallback, useRef, type ReactNode } from 'react';
import { useData } from './data.tsx';
import { packetsToOpen } from './logic/backup.ts';
import { importSummary, placeImport, unnamedAuthorFor, type Arrival, type Landing, type PlacedImport } from './logic/import.ts';
import { kindNoun, opensListenCard } from './logic/arrival-card.ts';
import type { PacketRead } from './ports.ts';
import { packetPickerAccept, packetRoute } from './logic/native-packets.ts';
import { plainError } from './logic/messages.ts';
import { NotSavedError } from './logic/storage.ts';
import { LINK_MESSAGES, ShareLinkError, openSharedPacket, type ParsedLink } from './logic/share-link.ts';
import { fetchReplyOutcome } from './logic/reply-box.ts';
import { fetchIntroMark, linkShareFetch } from './logic/intro-link.ts';
import { senderNameOrNone } from './logic/reply-words.ts';
import { usePlayer } from './player.tsx';
import { trackReplyBox } from './reply-boxes.ts';
import { services } from './services.ts';
import { useUi } from './ui.tsx';

/**
 * `fromBackup`: the packet came out of a Settings backup `.zip`, so its Margins are the listener's own. `alone`: it is the
 * only packet being opened, so a text-kind file may open the listen-here card instead of being stored (#5265).
 */
export type OpenMarginFile = (bytes: Uint8Array, fileName: string | undefined, fromBackup?: boolean, alone?: boolean) => Promise<void>;

/** Shows the listen-here card for a file's Margins on something the web app can't play (#5265). */
export type ListenToFile = (read: PacketRead) => void;
export type OpenShareLink = (parsed: ParsedLink) => Promise<void>;

/** Reads a packet, stores its Margins (and its episode, when new) and opens Now Playing at the first one. */
function useLandPacket(
  onLanded: (landing: Landing) => void,
  onListen?: ListenToFile,
): (
  bytes: Uint8Array,
  fileName: string | undefined,
  arrival: Arrival,
  alone?: boolean,
  onPlaced?: (episodeId: string, read: PacketRead, placed: PlacedImport) => void,
) => Promise<void> {
  const data = useData();
  const player = usePlayer();
  const { toast } = useUi();
  const dataRef = useRef(data);
  dataRef.current = data;

  return useCallback(
    async (bytes, fileName, arrival, alone = false, onPlaced) => {
      const read = await services.packets.readPacket(bytes, fileName);
      // A single file of Margins on a text's words opens the card that plays them here, before anything is written (#5265).
      if (onListen && opensListenCard(read, arrival, alone)) {
        onListen(read);
        return;
      }
      const current = dataRef.current;
      const placed = placeImport(read, current.shows, current.episodes, undefined, current.margins, { unnamedAuthor: unnamedAuthorFor(arrival), backup: arrival === 'backup' });
      onPlaced?.(placed.episode.id, read, placed);
      if (placed.show) await current.follow(placed.show, [placed.episode]);
      else if (placed.newEpisode) await current.updateEpisode(placed.episode);
      for (const margin of placed.margins) await current.addMargin(margin);
      // A friend's item is the listener's to keep, even a copy that was moved out or removed. Quiet: never drops the landing.
      await current.addToLibrary(placed.episode.id, { quiet: true });
      toast(importSummary(placed, read.sender, kindNoun(read)));
      if (placed.landAt === undefined) return;
      await player.open(placed.episode.id, { at: placed.landAt, episode: placed.episode });
      onLanded({ episodeId: placed.episode.id, at: placed.landAt });
    },
    [player, toast, onLanded, onListen],
  );
}

/** Opens one Margin file and calls `onLanded` once Now Playing should show its moment. */
export function useOpenMarginFile(onLanded: (landing: Landing) => void, onListen?: ListenToFile): OpenMarginFile {
  const land = useLandPacket(onLanded, onListen);
  const { toast } = useUi();
  return useCallback(
    async (bytes, fileName, fromBackup = false, alone = false) => {
      try {
        await land(bytes, fileName, fromBackup ? 'backup' : 'file', alone);
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
  const data = useData();
  const dataRef = useRef(data);
  dataRef.current = data;
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
      // The link's reply part (#4675), fetched beside the packet and never waited on.
      const replyFetch = fetchReplyOutcome(parsed.link);
      // Its sealed preview (#4784): an introduction link's Margins are marked once stored, and it takes no answers.
      const introFetch = fetchIntroMark(parsed.link);
      let stored!: () => void;
      const landed = new Promise<void>((resolve) => {
        stored = resolve;
      });
      let bytes: Uint8Array;
      try {
        bytes = await openSharedPacket(parsed.link);
      } catch (error) {
        toast(error instanceof ShareLinkError ? error.message : LINK_MESSAGES.damaged, 'problem');
        return;
      }
      try {
        await land(bytes, 'shared.spokenmargins', 'link', false, (episodeId, read, placed) => {
          const markIntro = async () => {
            await landed;
            await dataRef.current.markFromIntro(placed.margins.map((m) => m.id));
          };
          trackReplyBox(episodeId, linkShareFetch(replyFetch, introFetch, markIntro), senderNameOrNone(read.sender), read.contentDigest);
        });
      } catch (error) {
        // A write that failed has already said what wasn't saved. Otherwise it opened under the key but isn't a
        // packet this app can read.
        if (!(error instanceof NotSavedError)) toast(`${LINK_MESSAGES.damaged} ${plainError(error)}`, 'problem');
      } finally {
        stored();
      }
    },
    [land, toast],
  );
}

/**
 * Opens one file's bytes, from any way in. A backup `.zip` from Settings opens each packet in it (#3012); anything
 * else goes to the packet reader as it is, which says plainly when it isn't a Margin file.
 */
export async function openFileBytes(bytes: Uint8Array, fileName: string | undefined, open: OpenMarginFile, onlyFile = false): Promise<void> {
  const packets = await packetsToOpen(bytes, fileName);
  for (const packet of packets) await open(packet.bytes, packet.name, packet.fromBackup, onlyFile && packets.length === 1);
}

/** Files from a drop or a picker, one at a time. */
export async function openFiles(files: Iterable<File>, open: OpenMarginFile): Promise<void> {
  const all = [...files];
  for (const file of all) await openFileBytes(new Uint8Array(await file.arrayBuffer()), file.name, open, all.length === 1);
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
