// When a received Margin fires during episode playback (#3058). Plain TypeScript with no DOM, so `npm run test:web`
// covers it. The player calls `dueMargins` on every time update while the episode plays.
//
// The rules, after the iPhone app:
// - Only a friend's Margin fires by itself (it has an `author`). The listener's own Margins wait for a tap.
// - A Margin fires when playback crosses its moment: the previous time is at or before it and the new time is past
//   it. Starting to play exactly on a Margin (the "Play from the first Margin" landing) therefore plays it.
// - Skipping forward past one does not fire it: a step bigger than normal playback can make is a jump, not a crossing.
// - Seeking back and playing over a Margin again fires it again: the listener rewound to hear it. Time that merely
//   runs on after the Margin has played never does, since the previous time is already past it.
// - The web model keeps no "approximate" flag on a Margin (a percent-placed one is stored at its estimated second),
//   so every Margin fires at its stored moment.
import type { Margin } from '../../shared/model.ts';

/** The most media time one time update may cover and still count as playing (browsers send about four a second). */
export const MAX_PLAYING_STEP_SECONDS = 3;

/** True for a Margin that fires by itself during playback. */
export function firesByItself(margin: Margin): boolean {
  return margin.author !== undefined && margin.author !== '';
}

/**
 * The Margins whose moment playback just crossed, in the order they come, going from `previous` to `now` seconds.
 * Pass `previous` as undefined for the first update after play starts or after any seek: nothing fires then, and the
 * caller starts tracking from `now`.
 */
export function dueMargins(margins: readonly Margin[], previous: number | undefined, now: number): Margin[] {
  if (previous === undefined || !Number.isFinite(previous) || !Number.isFinite(now)) return [];
  const step = now - previous;
  if (step <= 0 || step > MAX_PLAYING_STEP_SECONDS) return [];
  return margins
    .filter((m) => firesByItself(m) && m.atSeconds >= previous && m.atSeconds < now)
    .sort((a, b) => a.atSeconds - b.atSeconds);
}
