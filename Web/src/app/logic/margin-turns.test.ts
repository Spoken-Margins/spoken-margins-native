import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MarginTurns } from './margin-turns.ts';

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
