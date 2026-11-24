import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MarginTurns, endTurnWhenPlaying, pauseUnderReading } from './margin-turns.ts';

/** Turns over strings, recording which began and keeping each one's `done`. */
const turns = () => {
  const begun: string[] = [];
  const done = new Map<string, () => void>();
  const queue = new MarginTurns<string>((item, finish) => {
    begun.push(item);
    done.set(item, finish);
  });
  return { queue, begun, done };
};

test('a thread queued together plays one Margin at a time: the reply waits for the root to finish (audit 1 on #4505)', () => {
  const { queue, begun, done } = turns();
  queue.add(['root', 'reply']);
  assert.deepEqual(begun, ['root']);
  assert.equal(queue.busy, true);
  done.get('root')?.();
  assert.deepEqual(begun, ['root', 'reply']);
  done.get('reply')?.();
  assert.equal(queue.busy, false);
});

test('a Margin crossed while another is taking its turn waits for it', () => {
  const { queue, begun, done } = turns();
  queue.add(['voice']);
  queue.add(['written']);
  assert.deepEqual(begun, ['voice']);
  done.get('voice')?.();
  assert.deepEqual(begun, ['voice', 'written']);
});

test('a repeated or stale done begins nothing more', () => {
  const { queue, begun, done } = turns();
  queue.add(['a', 'b', 'c']);
  done.get('a')?.();
  done.get('a')?.();
  assert.deepEqual(begun, ['a', 'b']);
  queue.clear();
  done.get('b')?.();
  assert.deepEqual(begun, ['a', 'b']);
  assert.equal(queue.busy, false);
});

test('after a clear, the next Margin due begins at once', () => {
  const { queue, begun } = turns();
  queue.add(['a', 'b']);
  queue.clear();
  queue.add(['c']);
  assert.deepEqual(begun, ['a', 'c']);
});

test('a turn that ends inside its own begin hands on to the next', () => {
  const begun: string[] = [];
  const queue = new MarginTurns<string>((item, finish) => {
    begun.push(item);
    finish();
  });
  queue.add(['a', 'b']);
  assert.deepEqual(begun, ['a', 'b']);
  assert.equal(queue.busy, false);
});

test('Pause on a browser that can\'t hold speech holds the reply: the reading ends, but the next Margin waits for Play (audit 1 on 53fc52e)', () => {
  // The player's pieces: an episode, a reading that is stopped (not held) by pause and ends its turn as it stops, and
  // turns that end only while the episode plays.
  const episode = { paused: false };
  const pending: (() => void)[] = [];
  const begun: string[] = [];
  let reading: { pause: () => void } | undefined;
  let turnDone: (() => void) | undefined;
  const queue = new MarginTurns<string>((item, done) => {
    begun.push(item);
    turnDone = done;
    reading = {
      pause: () => {
        reading = undefined;
        endTurnWhenPlaying({ current: () => turnDone === done, paused: () => episode.paused, done }, (check) => pending.push(check));
      },
    };
  });
  queue.add(['root', 'reply']);
  assert.deepEqual(begun, ['root']);

  pauseUnderReading({ episode: () => (episode.paused = true), reading: () => reading?.pause() });
  assert.deepEqual(begun, ['root'], 'nothing begins during the Pause tap');
  pending.splice(0).forEach((check) => check());
  assert.deepEqual(begun, ['root'], 'still paused: the reply keeps waiting');

  episode.paused = false;
  pending.splice(0).forEach((check) => check());
  assert.deepEqual(begun, ['root', 'reply'], 'Play hands the turn on');
});

test('a turn waiting for Play ends no more once it is over by other means', () => {
  let ended = 0;
  let current = true;
  const pending: (() => void)[] = [];
  endTurnWhenPlaying({ current: () => current, paused: () => true, done: () => ended++ }, (check) => pending.push(check));
  current = false;
  pending.splice(0).forEach((check) => check());
  assert.equal(ended, 0);
  assert.equal(pending.length, 0);
});
