// Where an opened `.spokenmargins` file's Margins go (#2979). The packet names its episode by guid, audio address
// and page; the listener's own copy is found the way the iPhone app finds it (guid, then enclosure, then link).
// With no copy in the Library, the episode is added under a "shared with you" show named for the sender, so the
// Margins land in Following under the person who sent them (owner, 2026-10-17, #1507) and can play at once.
// Plain TypeScript, so `npm run test:web` covers it (import.test.ts).
import { formatClock } from '../../shared/clock.ts';
import type { Episode, Margin, PercentMargin, Show } from '../../shared/model.ts';
import { sharedWords } from '../../packet/write.ts';
import { appleEpisodeRef } from '../../sources/apple.ts';
import { samePage } from '../../sources/substack.ts';
import type { PacketRead } from '../ports.ts';

export interface PlacedImport {
  /** The episode the Margins belong to: the listener's own, or a new one from the packet. */
  episode: Episode;
  /** True when `episode` must be stored: it is new, or the listener's copy gained the audio address the packet carries (#4783). */
  newEpisode: boolean;
  /** A new "shared with you" show to store, when the episode is new and that show doesn't exist yet. */
  show?: Show;
  margins: Margin[];
  /**
   * Every one of the packet's Margins as this browser holds it once `margins` are stored: a Margin already here is that
   * stored copy, with its own id, heard and author, and a new reply to it links to that copy (the arrival preview).
   */
  held: Margin[];
  /** Where to start playing: the earliest Margin's moment. */
  landAt: number | undefined;
  /**
   * Margins on an article's text that carry no rough place, so the web app can't place them. Those that do are in
   * `pending`, to be placed once the audio that plays the article has a length (`placeByPercent`, #4421).
   */
  skipped: number;
  /** The article-text Margins with a rough place, aimed at `episode`, with the packet's unnamed sender named. */
  pending: PercentMargin[];
  /** Margins already here (the same words at the same moment), left out so a backup opened twice adds nothing. */
  duplicates: number;
}

/**
 * The same Margin: same episode, the same moment to the half second, and the same words. With the episode's title,
 * a voice Margin here without words matches its own copy from a packet, which carries placeholder words (#3025).
 */
export function sameMargin(a: Margin, b: Margin, episodeTitle?: string): boolean {
  const words = (m: Margin): string => (episodeTitle === undefined ? (m.text ?? '').trim() : sharedWords(m, episodeTitle));
  return a.episodeId === b.episodeId && Math.abs(a.atSeconds - b.atSeconds) < 0.5 && words(a) === words(b);
}

/** The author stored on a packet's Margins when the sender gave no name. */
export const UNNAMED_SENDER = 'Your friend';

/** How a packet reached the web app. */
export type Arrival = 'backup' | 'file' | 'link';

/**
 * The author for sender-less Margins in a packet that arrived this way (#4226). Only a packet out of the listener's
 * own Settings backup keeps its Margins unsigned. The packet manifest is closed, so a file can't say it is a backup;
 * how it arrived does: a backup is always a `.zip` (buildBackup), and any packet opened on its own, as a file or from a
 * link, is a friend's, so its unnamed Margins read as "Your friend" and play by themselves.
 */
export function unnamedAuthorFor(arrival: Arrival): string | undefined {
  return arrival === 'backup' ? undefined : UNNAMED_SENDER;
}

export const SHARED_SHOW_PREFIX = 'shared:';

/** The show that holds episodes known only from friends' files, one per sender. */
export function sharedShowFor(sender: string | undefined, now: string): Show {
  const name = sender?.trim();
  return {
    id: `${SHARED_SHOW_PREFIX}${name ?? ''}`,
    kind: 'podcast',
    title: name ? `Shared by ${name}` : 'Shared with you',
    feedUrl: '',
    followedAt: now,
  };
}

/** A title the web gave a holder of friends' episodes ("Shared by …", "Shared with you"), not a show's own (#4689). */
export function isSharedHolderTitle(title: string): boolean {
  const folded = title.trim().replace(/\s+/g, ' ').toLowerCase();
  return folded === 'shared with you' || (folded.startsWith('shared by ') && folded.length > 'shared by '.length);
}

/**
 * The show a packet of this episode names (#4689). A "Shared by …" holder is the web's filing place, not the show: its title
 * written as the packet's `showTitle` made the iPhone rule out the sender's own copy despite the same guid, and import a
 * second copy. The packet names the show the friend's packet named instead, or no show when that was not kept.
 */
export function packetShowFor(show: Show | undefined, episode: Episode): Show | undefined {
  if (!show?.id.startsWith(SHARED_SHOW_PREFIX)) return show;
  const title = episode.showTitle?.trim();
  return title ? { ...show, title } : undefined;
}

/** The listener's own copy of the packet's episode: by guid, then audio address, then page. */
export function findEpisode(read: PacketRead, episodes: readonly Episode[]): Episode | undefined {
  const { guid, audioUrl, pageUrl } = read.episode;
  const trimmedGuid = guid?.trim();
  if (trimmedGuid) {
    const byGuid = episodes.find((e) => e.guid?.trim() === trimmedGuid);
    if (byGuid) return byGuid;
  }
  if (audioUrl) {
    const byAudio = episodes.find((e) => e.audioUrl === audioUrl);
    if (byAudio) return byAudio;
  }
  if (pageUrl) return episodes.find((e) => e.pageUrl !== undefined && sameEpisodePage(e.pageUrl, pageUrl));
  return undefined;
}

/** Whether the listener's copy is the packet's episode by the guid or by an Apple episode's show and episode ids. */
function sameEpisodeIdentity(own: Episode, packet: PacketRead['episode']): boolean {
  const guid = packet.guid?.trim();
  if (guid && own.guid?.trim() === guid) return true;
  return own.pageUrl !== undefined && packet.pageUrl !== undefined && appleEpisodeRef(own.pageUrl) !== undefined && sameEpisodePage(own.pageUrl, packet.pageUrl);
}

/**
 * Two pages of one episode. An Apple episode page names its episode only in `?i=`, which `samePage` ignores, so two episodes
 * of one show would match. When either page is an Apple episode page, both must be, with the same show and episode ids.
 */
function sameEpisodePage(a: string, b: string): boolean {
  const left = appleEpisodeRef(a);
  const right = appleEpisodeRef(b);
  if (left || right) return left !== undefined && right !== undefined && left.showId === right.showId && left.episodeId === right.episodeId;
  return samePage(a, b);
}

export function placeImport(
  read: PacketRead,
  shows: readonly Show[],
  episodes: readonly Episode[],
  now = new Date().toISOString(),
  existing: readonly Margin[] = [],
  options: { unnamedAuthor?: string; backup?: boolean } = {},
): PlacedImport {
  const own = findEpisode(read, episodes);
  let episode: Episode;
  let show: Show | undefined;
  // The listener's copy was kept before its audio was known (a page-only Apple episode, saved when Apple wasn't answering or
  // before the lookup existed). The packet now carries the audio, so the copy takes it instead of asking again on the tap (#4783).
  // Only when the match is by identity (the guid, or an Apple episode's own ids). A page matched by address alone is not
  // proof of the same episode where the address names its item in a query (a YouTube `watch?v=`, a `/?p=7`), and audio
  // saved on the wrong item stays there.
  const filled = own !== undefined && !own.audioUrl && read.episode.audioUrl !== undefined && sameEpisodeIdentity(own, read.episode);
  if (own) {
    episode = filled
      ? {
          ...own,
          audioUrl: read.episode.audioUrl as string,
          ...(read.episode.audioOrigin && { audioOrigin: read.episode.audioOrigin }),
          ...(own.durationSeconds === undefined && read.episode.durationSeconds !== undefined && { durationSeconds: read.episode.durationSeconds }),
        }
      : own;
  } else {
    const shared = sharedShowFor(read.sender, now);
    // A holder the listener unfollowed counts as missing (#4426): the fresh one is followed through `follow()`, which
    // picks up the stored record, so the sender's row comes back on Following.
    if (!shows.some((s) => s.id === shared.id && !Object.hasOwn(s, 'unfollowedAt'))) show = shared;
    const { showTitle, publisher: _publisher, ...fields } = read.episode;
    const realShow = showTitle?.trim();
    episode = {
      ...fields,
      ...(realShow && !isSharedHolderTitle(realShow) && { showTitle: realShow }),
      id: `${shared.id}#${read.episode.guid ?? read.episode.audioUrl ?? read.episode.pageUrl ?? read.contentDigest}`,
      showId: shared.id,
    };
  }
  // Opened as a file or from a share link, a Margin is a friend's even when the sender gave no name: it plays by
  // itself and gets a countdown, and the page calls the sender "your friend" (#2168, #4226). The caller passes
  // `unnamedAuthorFor(arrival)`, so a restored backup keeps its own Margins unsigned.
  const { unnamedAuthor } = options;
  // A backup packet's length is one value for up to 50 Margins that may have been made on different copies (or on none that
  // was measured), so it says nothing about any one of them. A restored Margin keeps no copy length rather than gain one
  // it never had; the packet writer then falls back to the episode's own length, as it did before #4175.
  const ownCopy = (m: Margin): Margin => {
    if (!options.backup || m.copyLengthSeconds === undefined) return m;
    const { copyLengthSeconds: _copy, ...rest } = m;
    return rest;
  };
  const placed = read.margins.map((m) => ({ ...ownCopy(m), episodeId: episode.id, ...(unnamedAuthor && !m.author?.trim() && { author: unnamedAuthor }) }));
  const stored = new Map(placed.map((m) => [m.id, existing.find((e) => sameMargin(e, m, episode.title))]));
  const held = placed.map((m) => {
    const copy = stored.get(m.id);
    if (copy) return copy;
    const parent = m.replyToId === undefined ? undefined : stored.get(m.replyToId);
    return parent ? { ...m, replyToId: parent.id } : m;
  });
  // What is stored is what the preview showed: a new reply to a Margin already here hangs under the stored copy, whose id
  // the packet's own id for it would never find (audit 2 on #4505).
  const margins = held.filter((_, i) => !stored.get(placed[i].id));
  const landAt = placed.length ? Math.min(...placed.map((m) => m.atSeconds)) : undefined;
  const pending = read.percentMargins.map(({ margin, percent }) => ({
    percent,
    margin: { ...margin, episodeId: episode.id, ...(unnamedAuthor && !margin.author?.trim() && { author: unnamedAuthor }) },
  }));
  return {
    episode,
    newEpisode: !own || filled,
    ...(show && { show }),
    margins,
    held,
    landAt,
    skipped: Math.max(0, read.textMarginCount - pending.length),
    pending,
    duplicates: placed.length - margins.length,
  };
}

/**
 * The packet's Margins as the arrival preview shows them (part of #3216): as this browser will hold them once placed.
 * A packet's Margin ids come from its digest, so a Margin the listener already has from an earlier packet has another
 * id here; the preview shows the stored copy (heard, the listener's own), and its starts queue the id the player finds.
 */
export function previewMargins(
  read: PacketRead,
  shows: readonly Show[],
  episodes: readonly Episode[],
  existing: readonly Margin[],
  unnamedAuthor: string | undefined,
): Margin[] {
  return placeImport(read, shows, episodes, undefined, existing, { unnamedAuthor }).held;
}

/** How near the end a Margin placed by percent may sit: a Margin on the very last moment would never be reached. */
const END_ROOM_SECONDS = 1;

/**
 * Places a friend's article-text Margins on the audio that plays the article. The app's own Timeline puts a shared
 * Margin it can't match at the sender's rough percent of its copy; this does the same on the audio's length, since the
 * browser has no map from the article's words to the voice (#4421). `episode` is the one the audio belongs to, with its
 * own `durationSeconds`: the length of the audio itself, never the sender's narration. A Margin already here (the same
 * words at the same moment) is left out. With no usable length nothing can be placed.
 */
export function placeByPercent(
  pending: readonly PercentMargin[],
  episode: Pick<Episode, 'id' | 'title' | 'durationSeconds'>,
  existing: readonly Margin[] = [],
): Margin[] {
  const length = episode.durationSeconds;
  if (length === undefined || !Number.isFinite(length) || length <= 0) return [];
  const last = Math.max(0, length - END_ROOM_SECONDS);
  const placed = pending.map(({ margin, percent }) => ({
    ...margin,
    episodeId: episode.id,
    atSeconds: Math.min(last, Math.max(0, (Math.min(100, Math.max(0, percent)) / 100) * length)),
  }));
  return placed.filter((m) => !existing.some((e) => sameMargin(e, m, episode.title))).sort((a, b) => a.atSeconds - b.atSeconds);
}

/** What the listener is told once the Margins are in. */
export function importSummary(placed: PlacedImport, sender: string | undefined): string {
  const count = placed.margins.length;
  const who = sender?.trim() ? ` from ${sender.trim()}` : '';
  const what = count === 1 ? '1 Margin' : `${count} Margins`;
  // A Margin file opens no voice, so the Margins in it with a rough place stay unplaced here as well; only a share link
  // looks the post's voice up when the friend taps Play (#4421).
  const unopened = placed.skipped + placed.pending.length;
  const skipped = unopened
    ? ` ${unopened === 1 ? '1 Margin is' : `${unopened} Margins are`} on an article’s text, which the web app can’t open yet.`
    : '';
  const already = placed.duplicates
    ? ` ${placed.duplicates === 1 ? '1 Margin was' : `${placed.duplicates} Margins were`} already here.`
    : '';
  if (count === 0 && placed.duplicates) return `Every Margin in this file is already here, on “${placed.episode.title}”.${skipped}`;
  if (count === 0) return `This file has no Margins the web app can place.${skipped}`;
  return `Opened ${what}${who} on “${placed.episode.title}”.${already}${skipped}`;
}

/** Where an opened file left the listener: its episode, at the first Margin's moment (#3039). */
export interface Landing {
  episodeId: string;
  at: number;
}

/**
 * The words on Now Playing's offer to start, for when a browser won't start the audio by itself after a file opens
 * (the file was read, but nobody tapped Play). Undefined while it plays, for good once it has played since the file
 * opened (a later pause, or a friend's clip the browser blocked, is not a refused start; #3254), while the audio
 * loads, and when Now Playing shows another episode. A Margin that has come up means the episode ran, even if it never
 * drew as playing: a first Margin at the landing moment pauses the episode within milliseconds, and a tap on an offer
 * left up would drop its clip (#3375).
 */
export function landingOffer(
  landing: Landing | undefined,
  now: { episodeId: string | undefined; playing: boolean; played: boolean; marginArrived: boolean; loading: boolean },
): string | undefined {
  if (!landing || now.playing || now.played || now.marginArrived || now.loading || now.episodeId !== landing.episodeId) return undefined;
  return `Play from the first Margin, at ${formatClock(landing.at)}`;
}
