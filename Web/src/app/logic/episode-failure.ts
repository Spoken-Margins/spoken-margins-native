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
}

/**
 * A rejected `play()` that means the source is unusable. `NotAllowedError` is the browser refusing to autoplay
 * without a tap: nothing is wrong with the episode. `AbortError` is a load or a seek interrupting the request.
 */
export function playRejectionMeansFailed(name: string | undefined): boolean {
  return name !== 'NotAllowedError' && name !== 'AbortError';
}

/** The state after `event`. A failure already known stays one failure, whichever event says it again. */
export function nextFailure(failed: boolean, event: FailureEvent): FailureStep {
  switch (event.kind) {
    case 'media-error':
      return { failed: true };
    case 'play-rejected':
      return { failed: failed || playRejectionMeansFailed(event.name) };
    case 'source-changed':
    case 'retry':
    case 'playing':
      return { failed: false };
  }
}

/** The one problem shown for a failed episode, for any item in the player. */
export const EPISODE_FAILED = 'This episode’s audio couldn’t be loaded.';

/**
 * Whether the standing problem notice is on screen. A pure function of what is true now, never of what happened when:
 * the failure may land before the cue card has mounted (the arrival page stores the Margins first), and the listener
 * may close Now Playing to the mini player or open it later. The card says the sentence by rendering it; the notice
 * says it only while no card is on screen, and only until the listener closes it. So a failure is never silent and
 * never two sentences.
 */
export function failureNoticeShown(state: { failed: boolean; cardsShowing: number; closed: boolean }): boolean {
  return state.failed && state.cardsShowing <= 0 && !state.closed;
}

/**
 * What a rejected clip `play()` means for a Margin heard on its own. `NotAllowedError`: the browser wants a tap (a
 * clip started later than the listener's own tap can be refused, as on iPhone Safari), so the run waits on that
 * Margin. Anything else skips it.
 */
export function clipRejection(name: string | undefined): 'wait-for-tap' | 'skip' {
  return name === 'NotAllowedError' ? 'wait-for-tap' : 'skip';
}
