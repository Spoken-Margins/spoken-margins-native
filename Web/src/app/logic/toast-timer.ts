// The timer of one info toast (#4424). A plain note stays 6 s. A note with a button (Undo) stays 10 s, and its timer
// stops while keyboard focus or the pointer is inside it, then goes on with the time it had left (WCAG 2.2.1).
//
// Plain TypeScript with no clock and no DOM: every call is given `now` (milliseconds), so `npm run test:web` covers
// it (toast-timer.test.ts). `ui.tsx` owns the real `setTimeout` and feeds it from `remainingMs`.

export const TOAST_MS = 6000;
export const TOAST_WITH_ACTION_MS = 10000;

export interface ToastTimer {
  /** Time left as of `since` while running, or the frozen time left while paused. */
  readonly left: number;
  /** When it last started or resumed; null while paused. */
  readonly since: number | null;
  readonly closed: boolean;
}

/** How long a toast stays: 10 s with an action, 6 s without. */
export function toastMs(hasAction: boolean): number {
  return hasAction ? TOAST_WITH_ACTION_MS : TOAST_MS;
}

export function start(ms: number, now: number): ToastTimer {
  return { left: ms, since: now, closed: false };
}

/** Milliseconds still to run at `now` (never negative). */
export function remainingMs(timer: ToastTimer, now: number): number {
  const spent = timer.since === null ? 0 : Math.max(0, now - timer.since);
  return Math.max(0, timer.left - spent);
}

/** Stops the clock, keeping what is left. Pausing a paused or closed timer changes nothing. */
export function pause(timer: ToastTimer, now: number): ToastTimer {
  if (timer.closed || timer.since === null) return timer;
  return { ...timer, left: remainingMs(timer, now), since: null };
}

/** Starts the clock again with what was left. Resuming a running or closed timer changes nothing. */
export function resume(timer: ToastTimer, now: number): ToastTimer {
  if (timer.closed || timer.since !== null) return timer;
  return { ...timer, since: now };
}

/** The listener closed the toast (or its action ran): nothing may fire after this. */
export function close(timer: ToastTimer): ToastTimer {
  return timer.closed ? timer : { ...timer, closed: true };
}

/**
 * Whether the toast should go now. `fire` is true once: when the time has run out while running and not closed. The
 * returned timer is closed after it fires, so a second call, or a call after the toast was closed, is a no-op.
 */
export function expired(timer: ToastTimer, now: number): { timer: ToastTimer; fire: boolean } {
  if (timer.closed || timer.since === null || remainingMs(timer, now) > 0) return { timer, fire: false };
  return { timer: close(timer), fire: true };
}
