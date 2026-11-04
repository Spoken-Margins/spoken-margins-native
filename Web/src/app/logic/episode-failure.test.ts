import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Margin } from '../../shared/model.ts';
import { ARRIVAL_WORDS, cueFor } from './arrival.ts';
import { clipRejection, failureNeedsToast, nextFailure, playRejectionMeansFailed, type FailureEvent } from './episode-failure.ts';

/** Runs events through the state and returns how many problems were announced and where it ended. */
function run(events: FailureEvent[], start = false): { announced: number; failed: boolean } {
  let failed = start;
  let announced = 0;
  for (const event of events) {
    const step = nextFailure(failed, event);
    failed = step.failed;
    if (step.announce) announced++;
  }
  return { announced, failed };
}

const error: FailureEvent = { kind: 'media-error' };
const unsupported: FailureEvent = { kind: 'play-rejected', name: 'NotSupportedError' };
const refused: FailureEvent = { kind: 'play-rejected', name: 'NotAllowedError' };

test('the source answers 404, or 200 with an HTML page: the error event fails it, once', () => {
  assert.deepEqual(run([error]), { announced: 1, failed: true });
});

test('the error event then the rejected play(), and the reverse, make one problem', () => {
  assert.deepEqual(run([error, unsupported]), { announced: 1, failed: true });
  assert.deepEqual(run([unsupported, error]), { announced: 1, failed: true });
  assert.deepEqual(run([error, error, unsupported, unsupported]), { announced: 1, failed: true });
});

test('a network failure after playback has started fails it, once', () => {
  assert.deepEqual(run([{ kind: 'playing' }, error, error]), { announced: 1, failed: true });
});

test('autoplay refused (NotAllowedError) is a wait, not a failed load', () => {
  assert.deepEqual(run([refused]), { announced: 0, failed: false });
  assert.deepEqual(run([refused, { kind: 'playing' }]), { announced: 0, failed: false });
});

test('an interrupted request (AbortError) is not a failure; any other rejection is', () => {
  assert.equal(playRejectionMeansFailed('AbortError'), false);
  assert.equal(playRejectionMeansFailed('NotAllowedError'), false);
  assert.equal(playRejectionMeansFailed('NotSupportedError'), true);
  assert.equal(playRejectionMeansFailed(undefined), true);
});

test('a refused autoplay does not hide a real failure that follows', () => {
  assert.deepEqual(run([refused, error]), { announced: 1, failed: true });
});

test('a retry that succeeds clears the failure, and a retry that fails again is announced again', () => {
  assert.deepEqual(run([error, { kind: 'retry' }, { kind: 'playing' }]), { announced: 1, failed: false });
  assert.deepEqual(run([error, { kind: 'retry' }, error]), { announced: 2, failed: true });
});

test('moving to a different episode clears the failure; its own failure is announced', () => {
  assert.deepEqual(run([error, { kind: 'source-changed' }]), { announced: 1, failed: false });
  assert.deepEqual(run([error, { kind: 'source-changed' }, error]), { announced: 2, failed: true });
});

// The card, for an item with and without friend Margins.
const margin = (id: string, atSeconds: number, author = 'Sam', voice = false): Margin => ({
  id,
  episodeId: 'e',
  atSeconds,
  createdAt: '2026-10-31T10:00:00Z',
  ...(author !== '' && { author }),
  ...(voice ? { voice: { blob: new Blob([]), mimeType: 'audio/webm', durationSeconds: 3 } } : { text: 'words' }),
});
const failedState = { failed: true, heardWithoutEpisode: false };

test('a failed episode with friend Margins: one sentence and one button, no countdown, whatever the playhead says', () => {
  for (const time of [0, 10, 500]) {
    const cue = cueFor([margin('a', 30), margin('b', 60, 'Sam', true)], time, 'Sam', failedState);
    assert.deepEqual(cue, {
      kind: 'unplayable',
      who: 'Sam',
      sentence: 'This episode can’t play here, but you can still hear Sam’s Margins.',
      button: 'Hear Sam’s Margins',
    });
  }
});

test('written-only and voice-only lists get the same offer', () => {
  assert.equal(cueFor([margin('a', 30)], 0, 'Sam', failedState)?.kind, 'unplayable');
  assert.equal(cueFor([margin('b', 60, 'Sam', true)], 0, 'Sam', failedState)?.kind, 'unplayable');
});

test('once the Margins have been heard without the episode, the card says what is left and no countdown returns', () => {
  const cue = cueFor([margin('a', 30), margin('b', 60)], 0, 'Sam', { failed: true, heardWithoutEpisode: true });
  assert.deepEqual(cue, { kind: 'unplayable-done', who: 'Sam', sentence: 'That was Sam’s last Margin, and the episode can’t play here.' });
});

test('a failed item with no friend Margins offers nothing (the one toast is all there is)', () => {
  assert.equal(cueFor([], 0, undefined, failedState), undefined);
  assert.equal(cueFor([margin('own', 5, '')], 0, undefined, failedState), undefined);
});

test('an episode that has not failed keeps its countdown, and a retry that works brings it back', () => {
  assert.equal(cueFor([margin('a', 30)], 0, 'Sam', { failed: false, heardWithoutEpisode: false })?.kind, 'countdown');
  assert.equal(cueFor([margin('a', 30)], 0, 'Sam')?.kind, 'countdown');
});

test('a packet with no audio address keeps its own words', () => {
  assert.equal(
    ARRIVAL_WORDS.noEpisodeAudio('Sam'),
    'This episode has no audio the browser can play. Sam’s Margins are saved in your Library.',
  );
});

test('an unnamed sender reads as “your friend” in the sentence and the button', () => {
  const cue = cueFor([margin('a', 30, 'Your friend')], 0, undefined, failedState);
  assert.equal(cue?.kind === 'unplayable' && cue.button, 'Hear your friend’s Margins');
});

test('the failure gets a toast only when no card is on screen to say it', () => {
  assert.equal(failureNeedsToast(0), true);
  assert.equal(failureNeedsToast(1), false);
});

test('a clip the browser refuses without a tap waits for one; other rejections skip it', () => {
  assert.equal(clipRejection('NotAllowedError'), 'wait-for-tap');
  assert.equal(clipRejection('NotSupportedError'), 'skip');
  assert.equal(clipRejection('AbortError'), 'skip');
  assert.equal(clipRejection(undefined), 'skip');
});
