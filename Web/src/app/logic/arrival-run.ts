// The run behind "Hear Cole’s Margins" on the card for a link the browser can't play (#5265): for each Margin in order,
// the source's words in the browser's voice, then the Margin (its tone, then its clip or its words read aloud). The
// sounds themselves are the caller's (`MarginRunEffects`), so this order, Stop, a refused clip and a failed one are
// tested here without a browser. It never touches the player's own "arrived" Margin, so Now Playing shows no friend card
// and the reply memory isn't fed for Margins that aren't on its episode.
import type { Margin } from '../../shared/model.ts';

export interface MarginRunStep {
  /** What the voice says first, when anything. */
  context?: string;
  margin: Margin;
}

/** What is happening to step `index`: its context line, the Margin itself, or the end of it. */
export type MarginRunProgress =
  | { index: number; phase: 'context' | 'margin' }
  /** The clip couldn't load or decode: the row says so for the rest of the visit, and the run goes on. */
  | { index: number; phase: 'failed' }
  /** The browser refused to start the clip without a new tap: the run waits on this Margin. */
  | { index: number; phase: 'blocked' }
  /** This step's Margin ended. */
  | { index: number; phase: 'ended' }
  /** The run played its last step. */
  | { index: number; phase: 'done' };

/** Something sounding that can be stopped. */
export interface Stoppable {
  stop(): void;
}

/** How a Margin's sound went. `started` fires once it is sounding: the clip playing, or the voice reading it. */
export interface MarginHooks {
  started(): void;
  ended(): void;
  failed(): void;
  blocked(): void;
}

export interface MarginRunEffects {
  /** Says one line with no tone; `ended` fires once, however it ends. Undefined when nothing could be said. */
  speak(text: string, ended: () => void): Stoppable | undefined;
  /** Plays a Margin: its tone, then its clip or its words read aloud, or its words shown for a while. */
  playMargin(margin: Margin, hooks: MarginHooks): Stoppable;
}

/**
 * Plays `steps` from `startAt`, calling `onProgress` as each one moves. `only` plays that one step and stops. Returns the
 * run's handle; `stop()` silences it at once, and nothing it started reports again.
 */
export function runMargins(
  steps: readonly MarginRunStep[],
  effects: MarginRunEffects,
  onProgress: (progress: MarginRunProgress) => void,
  options: { startAt?: number; only?: boolean; onStarted?: (index: number) => void } = {},
): Stoppable {
  let live = true;
  let current: Stoppable | undefined;
  const startAt = options.startAt ?? 0;
  const last = options.only ? Math.min(startAt, steps.length - 1) : steps.length - 1;

  const report = (progress: MarginRunProgress) => {
    if (live) onProgress(progress);
  };

  const step = (index: number): void => {
    if (!live) return;
    if (index > last) {
      live = false;
      current = undefined;
      onProgress({ index: last, phase: 'done' });
      return;
    }
    const { context, margin } = steps[index];
    const playIt = () => {
      if (!live) return;
      current = undefined;
      report({ index, phase: 'margin' });
      let settled = false;
      const settle = (then: () => void) => {
        if (settled || !live) return;
        settled = true;
        current = undefined;
        then();
      };
      const handle = effects.playMargin(margin, {
        started: () => {
          if (live && !settled) options.onStarted?.(index);
        },
        ended: () =>
          settle(() => {
            report({ index, phase: 'ended' });
            step(index + 1);
          }),
        failed: () =>
          settle(() => {
            report({ index, phase: 'failed' });
            step(index + 1);
          }),
        blocked: () =>
          settle(() => {
            // The run waits here: the caller starts a new run from this step on the next tap.
            report({ index, phase: 'blocked' });
            live = false;
          }),
      });
      // A Margin that settled at once has moved the run on; its handle is spent.
      if (!settled && live) current = handle;
    };
    if (context === undefined) {
      playIt();
      return;
    }
    report({ index, phase: 'context' });
    let said = false;
    const next = () => {
      if (said) return;
      said = true;
      playIt();
    };
    const line = effects.speak(context, next);
    // A line that ended at once has already moved on to the Margin, whose sound is `current` now.
    if (line && !said) current = line;
    else next();
  };

  step(startAt);
  return {
    stop() {
      if (!live) return;
      live = false;
      const sounding = current;
      current = undefined;
      sounding?.stop();
    },
  };
}
