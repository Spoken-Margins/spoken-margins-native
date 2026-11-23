// Margins that come up together take turns (part of #3216). Plain TypeScript with no DOM, so `npm run test:web` covers
// it. A thread's start queue, or two Margins crossed in one time update, used to begin all at once: a written Margin
// cancelled the reading before it, and one read over a voice clip talked over it. Here each begins only when the one
// before it is done: its clip played out or was skipped, its words were read, or, shown without a voice, their time
// on screen ran out.

/** Begins one Margin. `done` ends its turn and begins the next; a stale or repeated call does nothing. */
export type BeginTurn<T> = (item: T, done: () => void) => void;

export class MarginTurns<T> {
  private waiting: T[] = [];
  private turn = 0;
  private taking = false;
  private readonly begin: BeginTurn<T>;

  constructor(begin: BeginTurn<T>) {
    this.begin = begin;
  }

  /** Whether a Margin is taking its turn now. */
  get busy(): boolean {
    return this.taking;
  }

  /** Margins due now, in order: the first begins if no Margin is taking its turn, and the rest wait theirs. */
  add(items: readonly T[]): void {
    this.waiting.push(...items);
    if (!this.taking) this.next();
  }

  /** The listener moved on (a seek, a new start, recording): the Margin taking its turn and those waiting are dropped. */
  clear(): void {
    this.waiting = [];
    this.taking = false;
    this.turn++;
  }

  private next(): void {
    const item = this.waiting.shift();
    const turn = ++this.turn;
    this.taking = item !== undefined;
    if (item === undefined) return;
    this.begin(item, () => {
      if (turn === this.turn) this.next();
    });
  }
}

/** Asks again later whether a turn may end: `setTimeout` in the player, run by hand in tests. */
export type Later = (check: () => void) => void;

/**
 * Ends a written Margin's turn, but only while the episode plays: Pause holds the Margins waiting their turn, as it
 * holds a clip. Stops waiting once the turn is over by other means (`current` false: cleared, skipped).
 */
export function endTurnWhenPlaying(turn: { current: () => boolean; paused: () => boolean; done: () => void }, later: Later): void {
  const check = () => {
    if (!turn.current()) return;
    if (turn.paused()) later(check);
    else turn.done();
  };
  check();
}

/**
 * Pause with a Margin being read over the episode: the episode stops first (audit 1 on #4505, `53fc52e`). A browser
 * that can't hold speech stops the reading as it pauses, which ends that Margin's turn at once; the turn must already
 * see the episode paused, so it waits for Play instead of beginning the next Margin during the Pause tap.
 */
export function pauseUnderReading(stop: { episode: () => void; reading: () => void }): void {
  stop.episode();
  stop.reading();
}
