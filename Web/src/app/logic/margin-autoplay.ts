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
// - The listener's own Margin made since the last time update, unless a seek came between, is not crossed: Record saves
//   its Margin at the playhead and pauses there, so the first update after Play would otherwise fire it. A friend's
//   Margin that appears mid-play (placed once the audio's length is known, imported) still fires on its moment.
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
export function dueMargins(
  margins: readonly Margin[],
  previous: number | undefined,
  now: number,
  /** Which Margins count. The Margins tab's Autoplay (part of #3216) passes every Margin and decides itself what plays. */
  counts: (margin: Margin) => boolean = firesByItself,
): Margin[] {
  if (previous === undefined || !Number.isFinite(previous) || !Number.isFinite(now)) return [];
  const step = now - previous;
  if (step <= 0 || step > MAX_PLAYING_STEP_SECONDS) return [];
  return margins
    .filter((m) => counts(m) && m.atSeconds >= previous && m.atSeconds < now)
    .sort((a, b) => a.atSeconds - b.atSeconds);
}

/** Where playback last was, from the audio element's events, so each time update can tell which Margins it crossed. */
export class CrossingClock {
  private last: number | undefined;
  // The Margins there at the last time update; undefined after a load or a seek, when every Margin counts (see above).
  private known: Set<string> | undefined;

  /** A new episode is loading: nothing to compare with until it plays. */
  reset(): void {
    this.last = undefined;
    this.known = undefined;
  }

  /** A seek began, landing at `at` (the audio element's currentTime while seeking). */
  seeking(at: number): void {
    this.last = at;
    this.known = undefined;
  }

  /**
   * Playback started or resumed at `at`. A seek or an earlier update already said where it was, and overwriting that
   * would skip a Margin the clock passed before this event arrived.
   */
  playing(at: number): void {
    this.last ??= at;
  }

  /** A time update while playing: the Margins crossed since the last one. */
  update(margins: readonly Margin[], now: number, counts?: (margin: Margin) => boolean): Margin[] {
    const known = this.known;
    const due = dueMargins(known ? margins.filter((m) => known.has(m.id) || firesByItself(m)) : margins, this.last, now, counts);
    this.last = now;
    this.known = new Set(margins.map((m) => m.id));
    return due;
  }
}
