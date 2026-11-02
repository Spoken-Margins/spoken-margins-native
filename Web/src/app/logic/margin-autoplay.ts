// When a received Margin fires during episode playback (#3058). Plain TypeScript with no DOM, so `npm run test:web`
// covers it. The player feeds a `CrossingClock` its audio element's events, and asks it on every time update while
// the episode plays.
//
// The rules, after the iPhone app:
// - Only a friend's Margin fires by itself (it has an `author`). The listener's own Margins wait for a tap.
// - A Margin fires when playback crosses its moment: the previous time is at or before it and the new time is past
//   it. Starting to play exactly on a Margin (the "Play from the first Margin" landing) therefore plays it: after a
//   seek the previous time is the point it landed on, so the Margin plays even when the first update after the seek
//   is already past it, as on a slow machine (#3254).
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
 * Undefined `previous` means nothing to compare with: nothing fires.
 */
export function dueMargins(margins: readonly Margin[], previous: number | undefined, now: number): Margin[] {
  if (previous === undefined || !Number.isFinite(previous) || !Number.isFinite(now)) return [];
  const step = now - previous;
  if (step <= 0 || step > MAX_PLAYING_STEP_SECONDS) return [];
  return margins
    .filter((m) => firesByItself(m) && m.atSeconds >= previous && m.atSeconds < now)
    .sort((a, b) => a.atSeconds - b.atSeconds);
}

/** Where playback last was, from the audio element's events, so each time update can tell which Margins it crossed. */
export class CrossingClock {
  private last: number | undefined;

  /** A new episode is loading: nothing to compare with until it plays. */
  reset(): void {
    this.last = undefined;
  }

  /** A seek began, landing at `at` (the audio element's currentTime while seeking). */
  seeking(at: number): void {
    this.last = at;
  }

  /**
   * Playback started or resumed at `at`. A seek or an earlier update already said where it was, and overwriting that
   * would skip a Margin the clock passed before this event arrived.
   */
  playing(at: number): void {
    this.last ??= at;
  }

  /** A time update while playing: the Margins crossed since the last one. */
  update(margins: readonly Margin[], now: number): Margin[] {
    const due = dueMargins(margins, this.last, now);
    this.last = now;
    return due;
  }
}
