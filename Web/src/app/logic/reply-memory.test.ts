import assert from 'node:assert/strict';
import { test } from 'node:test';

import type { Margin } from '../../shared/model.ts';
import { ended, NOTHING_HEARD, replyForComposer, started, suggestion, WINDOW_SECONDS } from './reply-memory.ts';

// #4107 B1: the app's SharedMarginReplyMemoryTests rows, in milliseconds on the web's wall clock.
const T0 = 1_777_000_000_000;
const sec = (s: number) => T0 + s * 1000;

test('recording while the friend\'s Margin plays or shows answers it, however long it takes', () => {
  const memory = started(NOTHING_HEARD, 'a1', 'ep');
  assert.equal(suggestion(memory, 'ep', sec(600)), 'a1');
});

test('the window\'s edges: seconds after the friend\'s Margin ended, and whether a new Margin answers it', () => {
  assert.equal(WINDOW_SECONDS, 20, 'the owner\'s 2026-10-25 default (#473); change it there, not here');
  const memory = ended(started(NOTHING_HEARD, 'a1', 'ep'), T0);
  const rows: Array<[number, boolean]> = [[0, true], [19, true], [19.9, true], [20, true], [20.01, false], [21, false], [600, false]];
  for (const [after, answers] of rows) {
    assert.equal(suggestion(memory, 'ep', sec(after)) === 'a1', answers, `${after} s after it ended`);
  }
  assert.equal(suggestion(NOTHING_HEARD, 'ep', T0), undefined, 'no friend\'s Margin heard: an ordinary Margin');
});

test('two friend Margins in a row answer the later one', () => {
  let memory = ended(started(NOTHING_HEARD, 'a1', 'ep'), sec(10));
  memory = started(memory, 'b1', 'ep');
  assert.equal(suggestion(memory, 'ep', sec(12)), 'b1', 'b1 is playing, though a1 ended 2 s ago');
  memory = ended(memory, sec(20));
  assert.equal(suggestion(memory, 'ep', sec(25)), 'b1');
  assert.equal(suggestion(memory, 'ep', sec(20 + WINDOW_SECONDS + 1)), undefined);
});

test('another episode is never an answer, and an end with nothing heard changes nothing', () => {
  assert.equal(suggestion(started(NOTHING_HEARD, 'a1', 'ep'), 'other', T0), undefined);
  assert.equal(suggestion(ended(NOTHING_HEARD, T0), 'ep', T0), undefined);
});

test('a second end does not extend the window', () => {
  const once = ended(started(NOTHING_HEARD, 'a1', 'ep'), T0);
  const twice = ended(once, sec(15));
  assert.equal(twice, once);
  assert.equal(suggestion(twice, 'ep', sec(WINDOW_SECONDS + 1)), undefined);
});

test('a clock step backwards still counts as just after, and the memory is never changed in place', () => {
  const memory = ended(started(NOTHING_HEARD, 'a1', 'ep'), sec(5));
  assert.equal(suggestion(memory, 'ep', T0), 'a1');
  assert.deepEqual(NOTHING_HEARD, {}, 'the empty memory stays empty');
  const begun = started(NOTHING_HEARD, 'a1', 'ep');
  ended(begun, T0);
  assert.equal(begun.heard?.endedAtMs, undefined, 'ending returns a new memory');
});

test('the composer\'s parent is found among the episode\'s friend Margins; a Margin no longer there answers nothing', () => {
  const friend = (id: string): Margin => ({ id, episodeId: 'ep', atSeconds: 105, createdAt: '2026-11-01T10:00:00Z', text: id, author: 'Cole' });
  const memory = ended(started(NOTHING_HEARD, 'packet:x:1', 'ep'), T0);
  assert.equal(replyForComposer(memory, 'ep', sec(19), [friend('packet:x:0'), friend('packet:x:1')])?.id, 'packet:x:1');
  assert.equal(replyForComposer(memory, 'ep', sec(21), [friend('packet:x:1')]), undefined, 'outside the window');
  assert.equal(replyForComposer(memory, 'ep', sec(1), [friend('packet:x:0')]), undefined, 'the parent was removed');
  assert.equal(replyForComposer(memory, 'other', sec(1), [friend('packet:x:1')]), undefined, 'another episode');
});
