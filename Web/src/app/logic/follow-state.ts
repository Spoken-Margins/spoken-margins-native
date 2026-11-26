// Unfollowing a show and dismissing an episode on the web (#4426, Design of 2026-11-22). Neither deletes anything:
// - Unfollow marks the show record `unfollowedAt`. The show leaves Following, refresh stops reading it, and its
//   episodes, places, Margins and Library membership all stay.
// - Dismiss writes a `dismissed:<episode id>` settings row. The episode leaves its show's list and the "N new" count.
// - Undo puts back the one thing that changed, and following the show again picks up the stored record.
//
// Plain TypeScript with no DOM, so `npm run test:web` covers it (follow-state.test.ts). Nothing here writes.
import type { Episode, Show } from '../../shared/model.ts';
import type { FeedRead } from '../ports.ts';
import type { DismissedRow, Dismissals } from '../store/schema.ts';
import { mergeRefresh } from './refresh.ts';
import { sameFeed } from './suggestions.ts';

/** Shows that hold a friend's item, not a followed feed, have ids that start with this. */
const SHARED_SHOW_PREFIX = 'shared:';

/** Whether the listener follows the show: the record carries no `unfollowedAt`. */
export function isFollowed(show: Show): boolean {
  return !Object.hasOwn(show, 'unfollowedAt');
}

/** The shows the listener follows, in their stored order. */
export function followedShows(shows: readonly Show[]): Show[] {
  return shows.filter(isFollowed);
}

/** Whether refresh may read and write the show: only a followed one. */
export function refreshable(show: Show): boolean {
  return isFollowed(show);
}

/** The record Unfollow writes: the same record, marked. */
export function unfollowedRecord(show: Show, now: string): Show {
  return { ...show, unfollowedAt: now };
}

/** The record Undo and a re-follow write: the same record with the mark deleted, never set to `undefined`. */
export function followedAgainRecord(show: Show): Show {
  const { unfollowedAt: _unfollowedAt, ...rest } = show;
  return rest;
}

/**
 * The stored record a follow should pick up: by id, then, for a feed show, by the same feed address. A friend's
 * "Shared by" holder matches by id only (every one has `feedUrl: ''`), so a file from a new sender is never filed under
 * another sender's show.
 */
export function findStoredShow(shows: readonly Show[], read: Show): Show | undefined {
  const byId = shows.find((s) => s.id === read.id);
  if (byId) return byId;
  if (read.id.startsWith(SHARED_SHOW_PREFIX)) return undefined;
  return shows.find((s) => !s.id.startsWith(SHARED_SHOW_PREFIX) && sameFeed(s.feedUrl, read.feedUrl));
}

/**
 * What following a show again writes: the read merged into the stored record and its episodes through `mergeRefresh`,
 * so a stored episode keeps its id (and with it its place, Margins, membership and dismissal rows) and a Substack voice
 * found on an earlier tap is kept. `episodes` holds only new or changed episodes. `followedAt` becomes `now` only when
 * the stored record had been unfollowed.
 */
export function refollowWrites(stored: Show, storedEpisodes: readonly Episode[], read: FeedRead, now: string): { show: Show; episodes: Episode[] } {
  const merged = mergeRefresh({ show: stored, episodes: storedEpisodes }, read, now);
  const show = followedAgainRecord(merged.show);
  if (!isFollowed(stored)) show.followedAt = now;
  show.refreshedAt = now;
  return { show, episodes: merged.write };
}

/** Whether an episode is dismissed now. */
export function isDismissed(id: string, dismissed: Dismissals): boolean {
  return Object.hasOwn(dismissed, id) && dismissed[id]?.dismissed === true;
}

/** The row Dismiss writes. */
export function dismissedRow(now: string): DismissedRow {
  return { dismissed: true, at: now };
}

/** The row Undo writes back: the one Dismiss replaced, or "not dismissed" as of now when there was none. */
export function restoredDismissal(previous: DismissedRow | undefined, now: string): DismissedRow {
  return previous ?? { dismissed: false, at: now };
}

/** The row Bring back writes. */
export function broughtBackRow(now: string): DismissedRow {
  return { dismissed: false, at: now };
}

/**
 * Whether an episode shows in its show's list: it is not dismissed, or it is in the Library. An episode the listener
 * adds or plays always shows, with "In Library".
 */
export function onShowList(episode: Episode, dismissed: Dismissals, inLibrary: (id: string) => boolean): boolean {
  return !isDismissed(episode.id, dismissed) || inLibrary(episode.id);
}

export interface UnfollowToastInput {
  title: string;
  /** A friend's "Shared by" holder. */
  shared: boolean;
  /** The Library follows membership rows (#4425). */
  migrated: boolean;
  /** Migrated: how many of the show's episodes the Library holds. */
  inLibrary: number;
  /** Not migrated: how many of the show's episodes the Library showed, which leave it. */
  leaving: number;
  /** Any of the show's episodes carries a Margin. */
  hasMargins: boolean;
}

/** The Unfollow toast (Design, Screens › Show screen): the first line that applies. */
export function unfollowToast(input: UnfollowToastInput): string {
  const { title } = input;
  const tail = 'Its Margins stay in the Margins tab.';
  if (!input.migrated) {
    if (input.leaving <= 0) return `Unfollowed ${title}. ${tail}`;
    return `Unfollowed ${title}. ${input.leaving === 1 ? '1 episode leaves' : `${input.leaving} episodes leave`} your Library. ${tail}`;
  }
  if (input.inLibrary >= 1) {
    return input.shared ? `Unfollowed ${title}. Its items stay in your Library.` : `Unfollowed ${title}. What you added to your Library stays there.`;
  }
  if (input.hasMargins) return `Unfollowed ${title}. ${tail}`;
  return `Unfollowed ${title}.`;
}
