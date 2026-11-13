import assert from 'node:assert/strict';
import { test } from 'node:test';

import { packetMarginId } from '../../packet/read.ts';
import type { Margin } from '../../shared/model.ts';
import { choiceFor, replyIdFor, replyRow, toggleReplying, withReplyId } from './reply-choice.ts';

const D = 'c'.repeat(64);
const parent = (extra: Partial<Margin> = {}): Margin =>
  ({ id: packetMarginId(D, 'm1'), episodeId: 'ep', atSeconds: 105, createdAt: '2026-11-01T10:00:00Z', text: 'first words', author: 'Cole', ...extra });

test('a composer begun against a friend\'s Margin is a reply; with none there is no choice and no id', () => {
  const choice = choiceFor(parent());
  assert.equal(choice?.replying, true);
  assert.equal(replyIdFor(choice), parent().id);
  assert.equal(choiceFor(undefined), undefined);
  assert.equal(replyIdFor(undefined), undefined);
  assert.equal(toggleReplying(undefined), undefined);
});

test('the row says whom it answers, with words or by the Margin\'s moment, and "Not a reply" after the ×', () => {
  const rows: Array<[string, Partial<Margin>, string]> = [
    ['words', {}, 'Replying to Cole: “first words”'],
    ['the voice placeholder', { text: 'Voice Margin at 1:45 in “Episode 1”, recorded 3 Nov 2026' }, 'Replying to Cole’s Margin at 1:45'],
    ['no words at all', { text: undefined }, 'Replying to Cole’s Margin at 1:45'],
    ['a blank name', { author: '  ' }, 'Replying to your friend: “first words”'],
    ['a stand-in name, any case', { author: 'SOMEONE', text: undefined }, 'Replying to your friend’s Margin at 1:45'],
    ['quotes inside the words', { text: 'she said “no”' }, 'Replying to Cole: “she said ‘no’”'],
  ];
  for (const [what, extra, caption] of rows) {
    const row = replyRow(choiceFor(parent(extra)) as never);
    assert.ok(row.replying, what);
    assert.equal(row.caption, caption, what);
    assert.equal(row.stop, 'Stop replying', what);
  }
  const stopped = replyRow(toggleReplying(choiceFor(parent())) as never);
  assert.deepEqual(stopped, { replying: false, line: 'Not a reply', resume: 'Reply to Cole' });
  const unnamed = replyRow(toggleReplying(choiceFor(parent({ author: 'Unsigned sender' }))) as never);
  assert.deepEqual(unnamed, { replying: false, line: 'Not a reply', resume: 'Reply to your friend' });
});

test('× takes the id off, "Reply to Cole" puts it back, and a double tap ends where it began', () => {
  const start = choiceFor(parent());
  const stopped = toggleReplying(start);
  assert.equal(replyIdFor(stopped), undefined);
  assert.equal(stopped?.parent.id, parent().id, 'the parent is kept, so the way back works');
  assert.equal(replyIdFor(toggleReplying(stopped)), parent().id);
  // Two taps in the same instant, each applied to the state the last one left.
  assert.deepEqual(toggleReplying(toggleReplying(start)), start);
  assert.equal(replyRow(toggleReplying(toggleReplying(start)) as never).replying, true);
});

test('withReplyId sets or clears the link and leaves the Margin alone otherwise', () => {
  const mine: Margin = { id: 'x', episodeId: 'ep', atSeconds: 5, createdAt: '2026-11-02T10:00:00Z', text: 'mine' };
  const linked = withReplyId(mine, parent().id);
  assert.deepEqual(linked, { ...mine, replyToId: parent().id });
  assert.deepEqual(withReplyId(linked, undefined), mine);
  assert.ok(!('replyToId' in withReplyId(linked, undefined)), 'no empty key left behind');
  assert.deepEqual(withReplyId(mine, undefined), mine);
  assert.equal(mine.replyToId, undefined, 'the original is not changed');
  const other = packetMarginId(D, 'm2');
  assert.equal(withReplyId(linked, other).replyToId, other);
});
