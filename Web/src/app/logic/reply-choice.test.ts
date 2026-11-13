import assert from 'node:assert/strict';
import { test } from 'node:test';

import { packetMarginId } from '../../packet/read.ts';
import type { Margin } from '../../shared/model.ts';
import { choiceFor, hasReplyChoice, parentOf, replyRow, resumeReplying, stopReplying, toggleReplying, withReplyChoice } from './reply-choice.ts';

const D = 'c'.repeat(64);
const parent = (extra: Partial<Margin> = {}): Margin =>
  ({ id: packetMarginId(D, 'm1'), episodeId: 'ep', atSeconds: 105, createdAt: '2026-11-01T10:00:00Z', text: 'first words', author: 'Cole', ...extra });

test('a composer begun against a friend\'s Margin is a reply; with none there is no choice', () => {
  const choice = choiceFor(parent());
  assert.equal(choice?.replying, true);
  assert.equal(choice?.parent.id, parent().id);
  assert.equal(choiceFor(undefined), undefined);
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
  assert.equal(stopped?.replying, false);
  assert.equal(stopped?.parent.id, parent().id, 'the parent is kept, so the way back works');
  assert.equal(toggleReplying(stopped)?.replying, true);
  // Two taps in the same instant, each applied to the state the last one left.
  assert.deepEqual(toggleReplying(toggleReplying(start)), start);
  assert.equal(replyRow(toggleReplying(toggleReplying(start)) as never).replying, true);
});

const mine = (extra: Partial<Margin> = {}): Margin => ({ id: 'x', episodeId: 'ep', atSeconds: 5, createdAt: '2026-11-02T10:00:00Z', text: 'mine', ...extra });

test('withReplyChoice answers, keeps the link while stopped, or carries none, and leaves the Margin alone otherwise', () => {
  const start = choiceFor(parent());
  const answering = withReplyChoice(mine(), start);
  assert.deepEqual(answering, mine({ replyToId: parent().id }));
  // × before or after saving: the id moves to formerReplyToId, so "Reply to Cole" can put it back, and replyToId is gone.
  const stopped = withReplyChoice(answering, toggleReplying(start));
  assert.deepEqual(stopped, mine({ formerReplyToId: parent().id }));
  assert.ok(!('replyToId' in stopped), 'no empty key left behind');
  assert.deepEqual(withReplyChoice(stopped, start), answering, 'and back');
  // No choice: neither field, however it was set.
  assert.deepEqual(withReplyChoice(answering, undefined), mine());
  assert.deepEqual(withReplyChoice(stopped, undefined), mine());
  assert.deepEqual(withReplyChoice(mine(), undefined), mine());
  assert.equal(mine().replyToId, undefined, 'the original is not changed');
  // Another parent replaces the first.
  const other = packetMarginId(D, 'm2');
  assert.equal(withReplyChoice(answering, choiceFor(parent({ id: other })))?.replyToId, other);
});

test('hasReplyChoice says whether a write would change the link', () => {
  const start = choiceFor(parent());
  assert.equal(hasReplyChoice(mine(), undefined), true);
  assert.equal(hasReplyChoice(mine(), start), false);
  assert.equal(hasReplyChoice(withReplyChoice(mine(), start), start), true);
  assert.equal(hasReplyChoice(withReplyChoice(mine(), start), toggleReplying(start)), false);
  assert.equal(hasReplyChoice(withReplyChoice(mine(), toggleReplying(start)), toggleReplying(start)), true);
});

test('"Stop replying" on a saved reply moves the link to formerReplyToId and "Reply to Cole" moves it back', () => {
  const reply = mine({ replyToId: parent().id });
  const stopped = stopReplying(reply);
  assert.deepEqual(stopped, mine({ formerReplyToId: parent().id }));
  assert.ok(!('replyToId' in stopped));
  assert.deepEqual(resumeReplying(stopped), reply);
  // Pressed twice from the same row, or on a Margin that was never a reply: nothing changes and nothing breaks.
  assert.deepEqual(stopReplying(stopped), stopped);
  assert.deepEqual(resumeReplying(reply), reply);
  assert.deepEqual(stopReplying(mine()), mine());
  assert.deepEqual(resumeReplying(mine()), mine());
  // Other fields (a voice, the text, the author) ride along untouched.
  const voice = mine({ replyToId: parent().id, voice: { blob: new Blob(['a']), mimeType: 'audio/mp4', durationSeconds: 2 } });
  assert.equal(resumeReplying(stopReplying(voice)).voice, voice.voice);
});

test('parentOf finds the Margin by replyToId, or by formerReplyToId once stopped, and is undefined when it is gone', () => {
  const friend = parent();
  const others = [parent({ id: packetMarginId(D, 'm2') }), friend];
  assert.equal(parentOf(mine({ replyToId: friend.id }), others), friend);
  assert.equal(parentOf(mine({ formerReplyToId: friend.id }), others), friend);
  assert.equal(parentOf(mine({ replyToId: packetMarginId(D, 'gone') }), others), undefined);
  assert.equal(parentOf(mine(), others), undefined);
});
