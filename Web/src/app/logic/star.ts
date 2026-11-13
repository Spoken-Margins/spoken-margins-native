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
