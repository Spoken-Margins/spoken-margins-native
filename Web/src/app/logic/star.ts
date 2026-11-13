// Starring the listener's own Margins to share (#4172), as the iPhone app's `isStarredForSharing` does. A star lives with the
// Margin in this browser's store and nowhere else: `starred` is not a packet field, so no packet or backup ever carries it
// (docs/decisions.md: stars "stay out of packets and exports"), and a restored Margin comes back unstarred. Plain TypeScript
// with no DOM, so `npm run test:web` covers it.
import type { Margin } from '../../shared/model.ts';

/**
 * The star button flips: a tap on a starred Margin unstars it and the other way round. A pure function of what the button
 * shows, so a double tap ends where it began.
 */
export function toggleStar(current: boolean): boolean {
  return !current;
}

/** Whether the Margin is starred. */
export const isStarred = (margin: Margin): boolean => margin.starred === true;

/** Only the listener's own Margins can be starred: a friend's never travels back (reply-back.ts), so it has no star. */
export const canStar = (margin: Margin): boolean => margin.author === undefined || margin.author === '';

/** The Margin with its star set or cleared, nothing else changed. Off leaves no key at all, so an unstarred Margin looks as it always did. */
export function withStar(margin: Margin, on: boolean): Margin {
  const { starred: _was, ...rest } = margin;
  return on ? { ...rest, starred: true } : rest;
}

/**
 * A rewritten Margin keeps the star the stored one has. The voice composer keeps its own copy of the Margin it saved and
 * writes it again when the words arrive or the reply link changes, and the listener may have starred the row since; that
 * older copy must not take the star off. A Margin that says nothing about a star takes the stored one; starring or
 * unstarring is `withStar` through the store's own write, never this.
 */
export function keepingStar(margin: Margin, stored: Margin | undefined): Margin {
  return stored !== undefined && isStarred(stored) && !isStarred(margin) ? withStar(margin, true) : margin;
}
