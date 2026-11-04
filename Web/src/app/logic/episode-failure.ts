// Whether the episode in the player has failed to load (#3356). One piece of state, owned by the player, decided here
// so the browser's two ways of saying it (the audio element's `error` event and a rejected `play()`) can arrive in
// any order and still make one problem, announced once. Plain TypeScript with no DOM, so `npm run test:web` covers it.

export type FailureEvent =
  /** The audio element's `error` event: the address answered something it can't play, or the connection broke. */
  | { kind: 'media-error' }
  /** `play()` rejected. `name` is the DOMException's name. */
  | { kind: 'play-rejected'; name: string | undefined }
  /** A different episode (or none) is now the player's source. */
  | { kind: 'source-changed' }
  /** The listener tapped Play on a failed episode, and the player asked the element to load it again. */
  | { kind: 'retry' }
  /** The element is playing: whatever failed before, it works now. */
  | { kind: 'playing' };

export interface FailureStep {
  failed: boolean;
  /** True exactly when this event is the one that turned a working episode into a failed one: show the problem now. */
  announce: boolean;
}

/**
 * A rejected `play()` that means the source is unusable. `NotAllowedError` is the browser refusing to autoplay
 * without a tap: nothing is wrong with the episode. `AbortError` is a load or a seek interrupting the request.
 */
export function playRejectionMeansFailed(name: string | undefined): boolean {
  return name !== 'NotAllowedError' && name !== 'AbortError';
}

/** The state after `event`, and whether to tell the listener. A failure already known is never announced again. */
export function nextFailure(failed: boolean, event: FailureEvent): FailureStep {
  switch (event.kind) {
    case 'media-error':
      return { failed: true, announce: !failed };
    case 'play-rejected':
      return playRejectionMeansFailed(event.name) ? { failed: true, announce: !failed } : { failed, announce: false };
    case 'source-changed':
    case 'retry':
    case 'playing':
      return { failed: false, announce: false };
  }
}

/** The one problem shown for a failed episode, for any item in the player. */
export const EPISODE_FAILED = 'This episode’s audio couldn’t be loaded.';

/** Whether a failure needs its own toast: not when the cue card is on screen saying it in one sentence. */
export function failureNeedsToast(cardsShowing: number): boolean {
  return cardsShowing <= 0;
}

/**
 * What a rejected clip `play()` means for a Margin heard on its own. `NotAllowedError`: the browser wants a tap (a
 * clip started later than the listener's own tap can be refused, as on iPhone Safari), so the run waits on that
 * Margin. Anything else skips it.
 */
export function clipRejection(name: string | undefined): 'wait-for-tap' | 'skip' {
  return name === 'NotAllowedError' ? 'wait-for-tap' : 'skip';
}
