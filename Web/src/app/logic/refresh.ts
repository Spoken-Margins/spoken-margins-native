// Refreshing followed shows (#2977 audit, rough edge 1: "Followed shows never refresh"). Plain TypeScript with no
// DOM, so `npm run test:web` covers it (refresh.test.ts); `refresh.tsx` wires it to the app.
//
// What a refresh does, and nothing more:
// 1. Reads each followed show's feed, and only its feed. A Substack post page is read only on a listener's tap
//    (owner, 2026-10-21), so nothing here reads a page: the reader is called with the show's `feedUrl` alone.
// 2. A feed that needs the Spoken Margins server's relay is read through it only if the listener already said yes.
//    Otherwise it is skipped quietly and counted, so the Following tab can say so once. A refresh never asks.
// 3. Merges new episodes into the stored ones without duplicates, keyed on the feed item's GUID, then the
//    enclosure address. A stored episode keeps its id, so its place and its Margins (keyed by episode id) stay.
import type { Episode, Show } from '../../shared/model.ts';
import type { FeedRead } from '../ports.ts';

/** An automatic refresh reads a feed at most once in this long. The Refresh control doesn't wait. */
export const REFRESH_INTERVAL_MS = 30 * 60 * 1000;

/** Feeds read at once. Small, so a long follow list never floods a phone's connection. */
export const REFRESH_CONCURRENCY = 3;

/**
 * The shows an automatic refresh should read now: those not read (or tried) in the last 30 minutes. `attempts` holds
 * this session's tries, so a feed that failed isn't hammered either. `force` (the Refresh control) takes every show.
 */
export function dueShows(
  shows: readonly Show[],
  attempts: ReadonlyMap<string, number>,
  nowMs: number,
  options: { force?: boolean } = {},
): Show[] {
  if (options.force) return [...shows];
  return shows.filter((show) => {
    const refreshed = show.refreshedAt ? Date.parse(show.refreshedAt) : Number.NaN;
    const last = Math.max(Number.isNaN(refreshed) ? Number.NEGATIVE_INFINITY : refreshed, attempts.get(show.id) ?? Number.NEGATIVE_INFINITY);
    return !(nowMs - last < REFRESH_INTERVAL_MS);
  });
}

/** The part of an episode id after the show's id, so a new episode can take the stored show's id. */
function idSuffix(episode: Episode, showId: string): string {
  const prefix = `${showId}#`;
  return episode.id.startsWith(prefix) ? episode.id.slice(prefix.length) : episode.id;
}

/** An episode with its unset fields left out, so spreading it never clears a stored value. */
function definedFields(episode: Episode): Partial<Episode> {
  return Object.fromEntries(Object.entries(episode).filter(([, value]) => value !== undefined)) as Partial<Episode>;
}

function sameEpisode(a: Episode, b: Episode): boolean {
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]) as Set<keyof Episode>;
  for (const key of keys) if (a[key] !== b[key]) return false;
  return true;
}

export interface MergedRefresh {
  /** The stored show with the feed's current title and artwork, its `followedAt` kept and `refreshedAt` set. */
  show: Show;
  /** Episodes to write: the new ones and the stored ones the feed changed. Unchanged ones are left out. */
  write: Episode[];
  /** How many of `write` are new episodes. */
  added: number;
}

/**
 * Merges a fresh read of a feed into the stored show and its episodes.
 *
 * - A feed item matches a stored episode by GUID, then by enclosure address, then by id. A match keeps the stored
 *   id, so playback positions and Margins stay attached. Its fields are updated from the feed, except ones the feed
 *   leaves out: a Substack post's voice, found when the listener tapped it, is not in the feed and is kept.
 * - An item that matches nothing is new, and takes the stored show's id.
 * - A feed listing the same item twice adds it once.
 * - Stored episodes the feed no longer lists stay: they may carry Margins, and a feed only lists its newest items.
 */
export function mergeRefresh(stored: { show: Show; episodes: readonly Episode[] }, read: FeedRead, now: string): MergedRefresh {
  const showId = stored.show.id;
  const byGuid = new Map<string, Episode>();
  const byAudio = new Map<string, Episode>();
  const byId = new Map<string, Episode>();
  const remember = (episode: Episode) => {
    if (episode.guid) byGuid.set(episode.guid, episode);
    if (episode.audioUrl) byAudio.set(episode.audioUrl, episode);
    byId.set(episode.id, episode);
  };
  for (const episode of stored.episodes) if (episode.showId === showId) remember(episode);

  const write = new Map<string, Episode>();
  const merged = new Set<string>();
  let added = 0;
  for (const incoming of read.episodes) {
    const id = `${showId}#${idSuffix(incoming, read.show.id)}`;
    const match =
      (incoming.guid ? byGuid.get(incoming.guid) : undefined) ??
      (incoming.audioUrl ? byAudio.get(incoming.audioUrl) : undefined) ??
      byId.get(id);
    if (match) {
      // A feed lists its newest copy of an item first; a second listing changes nothing.
      if (merged.has(match.id)) continue;
      merged.add(match.id);
      const updated: Episode = { ...match, ...definedFields(incoming), id: match.id, showId };
      if (!sameEpisode(updated, match)) {
        write.set(match.id, updated);
        remember(updated);
      }
      continue;
    }
    const fresh: Episode = { ...definedFields(incoming), id, showId } as Episode;
    write.set(id, fresh);
    merged.add(id);
    remember(fresh);
    added += 1;
  }

  const show: Show = { ...stored.show, title: read.show.title || stored.show.title, refreshedAt: now };
  for (const key of ['author', 'siteUrl', 'artworkUrl'] as const) {
    const value = read.show[key];
    if (value) show[key] = value;
  }
  return { show, write: [...write.values()], added };
}

export type RefreshOutcome =
  | { showId: string; status: 'read'; read: FeedRead }
  | { showId: string; status: 'needs-relay' }
  | { showId: string; status: 'failed'; error: unknown };

export interface RefreshRun {
  shows: readonly Show[];
  /** Reads one feed. `relayAllowed` is the listener's standing answer; the reader never asks. */
  readFeed: (feedUrl: string, options: { relayAllowed: boolean }) => Promise<FeedRead>;
  relayAllowed: boolean;
  /** Tells a needs-relay refusal (`NeedsRelayConsent`) from any other failure. */
  needsRelay: (error: unknown) => boolean;
  concurrency?: number;
  /** Called as each feed finishes, so its new episodes show without waiting for the slowest feed. */
  onOutcome?: (outcome: RefreshOutcome) => void | Promise<void>;
}

/** Reads every show's feed, a few at a time. Never throws: each feed's failure is its own outcome. */
export async function runRefresh(run: RefreshRun): Promise<RefreshOutcome[]> {
  const queue = [...run.shows];
  const outcomes: RefreshOutcome[] = [];
  const worker = async () => {
    for (let show = queue.shift(); show; show = queue.shift()) {
      let outcome: RefreshOutcome;
      try {
        outcome = { showId: show.id, status: 'read', read: await run.readFeed(show.feedUrl, { relayAllowed: run.relayAllowed }) };
      } catch (error) {
        outcome = run.needsRelay(error) ? { showId: show.id, status: 'needs-relay' } : { showId: show.id, status: 'failed', error };
      }
      outcomes.push(outcome);
      try {
        await run.onOutcome?.(outcome);
      } catch {
        // A write that failed has already said so (data.tsx); the other feeds carry on.
      }
    }
  };
  const width = Math.max(1, Math.min(run.concurrency ?? REFRESH_CONCURRENCY, queue.length));
  await Promise.all(Array.from({ length: width }, worker));
  return outcomes;
}

/** The one line for skipped feeds, such as "3 shows need the Spoken Margins server to refresh." */
export function needsRelayLine(count: number): string {
  if (count <= 0) return '';
  return count === 1 ? '1 show needs the Spoken Margins server to refresh.' : `${count} shows need the Spoken Margins server to refresh.`;
}

/** What a refresh the listener asked for found, for the toast. */
export function refreshResultLine(added: number, failed: number): string {
  const found = added === 0 ? 'No new episodes.' : added === 1 ? '1 new episode.' : `${added} new episodes.`;
  if (failed <= 0) return found;
  return `${found} ${failed === 1 ? '1 show' : `${failed} shows`} couldn’t be checked.`;
}

/** The newest successful refresh across the shows, as an ISO date, or undefined before the first. */
export function lastRefreshedAt(shows: readonly Show[]): string | undefined {
  let best: string | undefined;
  let bestMs = Number.NEGATIVE_INFINITY;
  for (const show of shows) {
    const ms = show.refreshedAt ? Date.parse(show.refreshedAt) : Number.NaN;
    if (!Number.isNaN(ms) && ms > bestMs) {
      best = show.refreshedAt;
      bestMs = ms;
    }
  }
  return best;
}

/** "Checked just now", "Checked 12 minutes ago", "Checked at 9:40 PM", or "Checked Oct 28" for older. */
export function checkedLabel(iso: string | undefined, nowMs: number, locale?: string): string {
  if (!iso) return 'Not checked yet';
  const ms = Date.parse(iso);
  if (Number.isNaN(ms)) return 'Not checked yet';
  const ago = Math.max(0, nowMs - ms);
  if (ago < 60_000) return 'Checked just now';
  if (ago < 60 * 60_000) {
    const m = Math.floor(ago / 60_000);
    return `Checked ${m} minute${m === 1 ? '' : 's'} ago`;
  }
  const date = new Date(ms);
  if (new Date(nowMs).toDateString() === date.toDateString()) {
    return `Checked at ${date.toLocaleTimeString(locale, { hour: 'numeric', minute: '2-digit' })}`;
  }
  return `Checked ${date.toLocaleDateString(locale, { month: 'short', day: 'numeric' })}`;
}
