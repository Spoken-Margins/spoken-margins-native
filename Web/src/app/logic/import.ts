// Where an opened `.spokenmargins` file's Margins go (#2979). The packet names its episode by guid, audio address
// and page; the listener's own copy is found the way the iPhone app finds it (guid, then enclosure, then link).
// With no copy in the Library, the episode is added under a "shared with you" show named for the sender, so the
// Margins land in Following under the person who sent them (owner, 2026-10-17, #1507) and can play at once.
// Plain TypeScript, so `npm run test:web` covers it (import.test.ts).
import { formatClock } from '../../shared/clock.ts';
import type { Episode, Margin, Show } from '../../shared/model.ts';
import { sharedWords } from '../../packet/write.ts';
import { samePage } from '../../sources/substack.ts';
import type { PacketRead } from '../ports.ts';

export interface PlacedImport {
  /** The episode the Margins belong to: the listener's own, or a new one from the packet. */
  episode: Episode;
  /** True when `episode` is new and must be stored. */
  newEpisode: boolean;
  /** A new "shared with you" show to store, when the episode is new and that show doesn't exist yet. */
  show?: Show;
  margins: Margin[];
  /** Where to start playing: the earliest Margin's moment. */
  landAt: number | undefined;
  /** Margins on an article's text, which the web app can't place yet. */
  skipped: number;
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
  if (pageUrl) return episodes.find((e) => e.pageUrl !== undefined && samePage(e.pageUrl, pageUrl));
  return undefined;
}

export function placeImport(
  read: PacketRead,
  shows: readonly Show[],
  episodes: readonly Episode[],
  now = new Date().toISOString(),
  existing: readonly Margin[] = [],
): PlacedImport {
  const own = findEpisode(read, episodes);
  let episode: Episode;
  let show: Show | undefined;
  if (own) {
    episode = own;
  } else {
    const shared = sharedShowFor(read.sender, now);
    if (!shows.some((s) => s.id === shared.id)) show = shared;
    const { showTitle: _showTitle, publisher: _publisher, ...fields } = read.episode;
    episode = {
      ...fields,
      id: `${shared.id}#${read.episode.guid ?? read.episode.audioUrl ?? read.episode.pageUrl ?? read.contentDigest}`,
      showId: shared.id,
    };
  }
  const placed = read.margins.map((m) => ({ ...m, episodeId: episode.id }));
  const margins = placed.filter((m) => !existing.some((e) => sameMargin(e, m, episode.title)));
  const landAt = placed.length ? Math.min(...placed.map((m) => m.atSeconds)) : undefined;
  return { episode, newEpisode: !own, ...(show && { show }), margins, landAt, skipped: read.textMarginCount, duplicates: placed.length - margins.length };
}

/** What the listener is told once the Margins are in. */
export function importSummary(placed: PlacedImport, sender: string | undefined): string {
  const count = placed.margins.length;
  const who = sender?.trim() ? ` from ${sender.trim()}` : '';
  const what = count === 1 ? '1 Margin' : `${count} Margins`;
  const skipped = placed.skipped
    ? ` ${placed.skipped === 1 ? '1 Margin is' : `${placed.skipped} Margins are`} on an article’s text, which the web app can’t open yet.`
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
 * (the file was read, but nobody tapped Play). Undefined once it plays, while the audio loads, and when Now Playing
 * shows another episode.
 */
export function landingOffer(
  landing: Landing | undefined,
  now: { episodeId: string | undefined; playing: boolean; loading: boolean },
): string | undefined {
  if (!landing || now.playing || now.loading || now.episodeId !== landing.episodeId) return undefined;
  return `Play from the first Margin, at ${formatClock(landing.at)}`;
}
