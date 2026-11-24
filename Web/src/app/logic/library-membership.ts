// What the web Library holds (#4425): an episode is in the Library when its membership row says in. Following and
// refreshing store episodes with no row; Add, Play and a friend's file or link write an "in" row; #4424's Remove
// writes an "out" row. Before a store is migrated (`libraryModel` is ''), the Library is every stored episode, as it
// was before #4425.
//
// Plain TypeScript with no DOM, so `npm run test:web` covers it (library-membership.test.ts). Nothing here writes:
// it returns the setting rows for the caller to write, in the order the Design gives (the rows and
// `libraryMovedOut` together, then `libraryModel` on its own), so a move cut short between the two runs again and
// keeps at least as much.
import type { Episode, Margin, PlaybackPosition, Show } from '../../shared/model.ts';
import { MEMBERSHIP_PREFIX, type LibraryMembership, type Membership, type SettingRow, type Settings } from '../store/schema.ts';

/** Shows that hold a friend's item, not a followed feed, have ids that start with this. */
export const SHARED_SHOW_PREFIX = 'shared:';

/** The setting row that stores one episode's membership. */
export function membershipRow(episodeId: string, membership: Membership): SettingRow {
  return { key: `${MEMBERSHIP_PREFIX}${episodeId}`, value: { in: membership.in, at: membership.at } };
}

/** Whether the Library holds the episode: its row says in. No row, or an "out" row, is not in. */
export function inLibrary(episodeId: string, library: LibraryMembership): boolean {
  return Object.hasOwn(library, episodeId) && library[episodeId]?.in === true;
}

/**
 * The row to write when the listener adds an episode (Add, Play, a friend's file or link). An episode already in keeps
 * its row, so its first `at` survives a second add; one with no row or an "out" row gets a new "in" row.
 */
export function addedRow(existing: Membership | undefined, now: string): Membership {
  return existing?.in === true ? existing : { in: true, at: now };
}

/** The row Remove writes (#4424): "out", stamped with the time of the removal. Nothing else is deleted. */
export function removedRow(now: string): Membership {
  return { in: false, at: now };
}

/**
 * The row Undo writes back: `previous`, the row Remove replaced. If the listener has added the episode again in the
 * meantime (`current` is an "in" row), that newer row stays, so Undo never turns a fresh add back into an older one.
 */
export function restoredRow(current: Membership | undefined, previous: Membership): Membership {
  return current?.in === true ? current : previous;
}

/** Whether the store's Library follows membership rows (the one-time move has finished). */
export function isMigrated(settings: Pick<Settings, 'libraryModel'>): boolean {
  return settings.libraryModel === 'added';
}

/** The episodes the Library shows: every one before the move, then only those whose row says in. */
export function libraryEpisodes(episodes: readonly Episode[], library: LibraryMembership, migrated: boolean): Episode[] {
  return migrated ? episodes.filter((e) => inLibrary(e.id, library)) : [...episodes];
}

/** Whether the listener follows at least one show (a show that is not a friend's shared item). */
export function followsAShow(shows: readonly Show[]): boolean {
  return shows.some((s) => !s.id.startsWith(SHARED_SHOW_PREFIX));
}

/**
 * How many of a show's episodes the Library holds, for the unfollow toast. Counted through `libraryEpisodes`, so before
 * the move every stored episode of the show counts.
 */
export function libraryCountForShow(
  showId: string,
  episodes: readonly Episode[],
  library: LibraryMembership,
  migrated: boolean,
): number {
  return libraryEpisodes(episodes, library, migrated).filter((e) => e.showId === showId).length;
}

/**
 * The moved-out ids the Library notice counts and Put them back returns: still stored, and still with no membership
 * row (an id the listener has since added, played, or added and removed has a row and is not counted). Each id once, in
 * the list's order.
 */
export function stillMovedOut(movedOut: readonly string[], episodes: readonly Episode[], library: LibraryMembership): string[] {
  const stored = new Set(episodes.map((e) => e.id));
  const seen = new Set<string>();
  const result: string[] = [];
  for (const id of movedOut) {
    if (seen.has(id) || !stored.has(id) || Object.hasOwn(library, id)) continue;
    seen.add(id);
    result.push(id);
  }
  return result;
}

export interface PrepareInput {
  episodes: readonly Episode[];
  margins: readonly Margin[];
  positions: readonly PlaybackPosition[];
  library: LibraryMembership;
  settings: Pick<Settings, 'libraryModel' | 'libraryMovedOut'>;
}

export interface Prepared {
  /** Membership after the pass: the stored rows plus the ones in `rows`. */
  library: LibraryMembership;
  /**
   * Setting rows to write first, in one `putMany`: the new "in" rows, and during the move the `libraryMovedOut` list.
   * Empty when nothing needs writing.
   */
  rows: SettingRow[];
  /** Episode ids left out of the Library by the move (the stored list once migrated). */
  movedOut: string[];
  /** The `libraryModel` row to write after `rows` have been written; undefined once migrated. */
  finish: SettingRow | undefined;
}

/**
 * Runs on every load, on the snapshot after the localStorage position mirror has been merged in.
 *
 * Not migrated (the one-time move): each episode with no membership row goes in when its show is a friend's
 * (`shared:`), when any Margin (own or a friend's) sits on it, or when the listener has a place in it past 0 s.
 * Every other episode is left with no row and listed in `movedOut`. Existing rows, "in" or "out", are never changed.
 *
 * Migrated (the keep pass): each episode with no row whose show is a friend's or that has a Margin goes in. This picks
 * up what an older copy of the web app saved while open in another tab. A place alone doesn't add, since a play in this
 * copy writes its own row, and existing rows are never changed, so a removed episode stays removed.
 */
export function prepareLibrary(input: PrepareInput, now: string): Prepared {
  const migrated = isMigrated(input.settings);
  const withMargin = new Set(input.margins.map((m) => m.episodeId));
  const withPlace = new Set(input.positions.filter((p) => Number.isFinite(p.seconds) && p.seconds > 0).map((p) => p.episodeId));

  const library: Record<string, Membership> = Object.assign(Object.create(null) as Record<string, Membership>, input.library);
  const rows: SettingRow[] = [];
  const movedOut: string[] = [];
  const seenOut = new Set<string>();

  for (const episode of input.episodes) {
    const id = episode.id;
    if (Object.hasOwn(library, id)) continue;
    const keep =
      episode.showId.startsWith(SHARED_SHOW_PREFIX) || withMargin.has(id) || (!migrated && withPlace.has(id));
    if (keep) {
      const membership: Membership = { in: true, at: now };
      library[id] = membership;
      rows.push(membershipRow(id, membership));
    } else if (!migrated && !seenOut.has(id)) {
      seenOut.add(id);
      movedOut.push(id);
    }
  }

  if (migrated) {
    return { library, rows, movedOut: [...input.settings.libraryMovedOut], finish: undefined };
  }
  rows.push({ key: 'libraryMovedOut', value: movedOut });
  return { library, rows, movedOut, finish: { key: 'libraryModel', value: 'added' } };
}
