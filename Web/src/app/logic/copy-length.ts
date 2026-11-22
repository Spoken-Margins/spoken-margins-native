// Whether a friend's copy of a podcast episode is a different length from the sender's, and the sentence that says so
// (#4614, #4175). A podcast with dynamic ads is a different file on each request, and a Margin carries only the
// sender's clock time, so a copy that differs in length may put a Margin that far from its words. The rule and the cases
// are shared with the app: `Contracts/fixtures/copy-length-note/cases.json` is read by this file's test and by SessionKit's.
// Plain TypeScript with no DOM, so `npm run test:web` covers it.
import type { Margin } from '../../shared/model.ts';

/** A length difference under this is not worth a word: it leaves room for how a browser and AVFoundation measure one file. */
const MIN_DIFFERENCE_MS = 10_000;
/** Below this many seconds the amount is said in seconds, rounded to 5; from here, in whole minutes. */
const MINUTES_FROM_SECONDS = 120;

export interface CopyLengthDifference {
  /** Whether the listener's copy is shorter or longer than the sender's. */
  direction: 'shorter' | 'longer';
  /** More than 20% of the longer copy apart: a number of minutes would promise an offset that isn't there. */
  farApart: boolean;
  /** "about 35 seconds" or "about 3 minutes". */
  amount: string;
}

function usable(ms: number | null | undefined): ms is number {
  return typeof ms === 'number' && Number.isFinite(ms) && ms > 0;
}

/**
 * How the listener's copy differs in length from the sender's, or `undefined` for no note. Whole milliseconds and
 * integer arithmetic only, so no float lands on the wrong side of a boundary.
 */
export function copyLengthDifference(senderMs: number | null | undefined, listenerMs: number | null | undefined): CopyLengthDifference | undefined {
  if (!usable(senderMs) || !usable(listenerMs)) return undefined;
  const sender = Math.round(senderMs);
  const listener = Math.round(listenerMs);
  const apart = Math.abs(listener - sender);
  if (apart < MIN_DIFFERENCE_MS) return undefined;
  // More than 20% of the longer copy: the app's own "same episode" test (SharedEpisodeFeedMatcher.swift).
  const farApart = 5 * apart > Math.max(sender, listener);
  const seconds = Math.max(10, Math.floor((apart + 2_500) / 5_000) * 5);
  const amount = seconds < MINUTES_FROM_SECONDS
    ? `about ${seconds} seconds`
    : `about ${Math.floor((apart + 30_000) / 60_000)} minutes`;
  return { direction: listener < sender ? 'shorter' : 'longer', farApart, amount };
}

/** The words, as a frozen table like `ARRIVAL_WORDS`. `whose` is the possessive name, ready-made: "Cole’s", "your friend’s". */
export const COPY_LENGTH_WORDS = Object.freeze({
  off: (amount: string, direction: 'shorter' | 'longer', whose: string): string =>
    `Your copy is ${amount} ${direction} than ${whose}, so Margins may be that far off.`,
  farApart: (amount: string, direction: 'shorter' | 'longer', whose: string): string =>
    `Your copy is ${amount} ${direction} than ${whose}, so Margins may not line up.`,
});

/** The sentence for a friend's Margin, from the sender's and the listener's lengths in seconds; `undefined` for no note. */
export function copyLengthNote(
  senderSeconds: number | null | undefined,
  listenerSeconds: number | null | undefined,
  whose: string,
): string | undefined {
  const toMs = (s: number | null | undefined): number | undefined => (usable(s) ? Math.round(s * 1000) : undefined);
  const difference = copyLengthDifference(toMs(senderSeconds), toMs(listenerSeconds));
  if (!difference) return undefined;
  const words = difference.farApart ? COPY_LENGTH_WORDS.farApart : COPY_LENGTH_WORDS.off;
  return words(difference.amount, difference.direction, whose);
}

/** The Margin with the length of the copy it was made on, when that length is usable; otherwise the Margin as it was. */
export function withCopyLength(margin: Margin, seconds: number | null | undefined): Margin {
  return usable(seconds) ? { ...margin, copyLengthSeconds: seconds } : margin;
}
