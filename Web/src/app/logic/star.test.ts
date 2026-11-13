import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Margin } from '../../shared/model.ts';
import { canStar, isStarred, keepingStar, toggleStar, withStar } from './star.ts';
import { withWords } from './voice-words.ts';
import { withReplyChoice, choiceFor } from './reply-choice.ts';

const margin: Margin = { id: 'm', episodeId: 'e', atSeconds: 4, createdAt: '2026-11-02T10:00:00Z', text: 'Words.', replyToId: 'packet:x:1' };

test('starring adds the one key, unstarring takes it away, and nothing else changes (#4172)', () => {
  const on = withStar(margin, true);
  assert.equal(on.starred, true);
  assert.deepEqual({ ...on, starred: undefined }, { ...margin, starred: undefined });
  const off = withStar(on, false);
  assert.equal('starred' in off, false, 'off leaves no key, so an unstarred Margin looks as it always did');
  assert.deepEqual(off, margin);
  assert.deepEqual(withStar(margin, false), margin);
});

test('only the listener\'s own Margins can be starred: the friend\'s never travels back (#4172)', () => {
  assert.equal(canStar(margin), true);
  assert.equal(canStar({ ...margin, author: '' }), true);
  assert.equal(canStar({ ...margin, author: 'Ana' }), false);
  assert.equal(isStarred(margin), false);
  assert.equal(isStarred(withStar(margin, true)), true);
});

test('the toggle flips what the button shows', () => {
  assert.equal(toggleStar(false), true);
  assert.equal(toggleStar(true), false);
});

test('a voice composer\'s older copy, rewritten with words or a reply link, does not take the star off (#4172)', () => {
  const voice: Margin = { id: 'v', episodeId: 'e', atSeconds: 9, createdAt: '2026-11-02T10:00:00Z', voice: { blob: new Blob(['x']), mimeType: 'audio/mp4', durationSeconds: 3 } };
  const stored = withStar(voice, true); // starred after the composer made its copy
  const friend: Margin = { id: 'packet:' + 'a'.repeat(64) + ':1', episodeId: 'e', atSeconds: 8, createdAt: '2026-11-01T10:00:00Z', text: 'Hi', author: 'Ana' };
  const withWordsNext = withWords(voice, 'Heard it.', 'placeholder');
  assert.ok(withWordsNext);
  assert.equal(isStarred(withWordsNext), false, 'the stale copy has no star');
  assert.equal(isStarred(keepingStar(withWordsNext, stored)), true);
  assert.equal(keepingStar(withWordsNext, stored).text, 'Heard it.');
  const replied = withReplyChoice(voice, choiceFor(friend));
  assert.equal(keepingStar(replied, stored).replyToId, friend.id);
  assert.equal(isStarred(keepingStar(replied, stored)), true);
  // Nothing stored, or nothing starred: the Margin is exactly as given. A star it carries itself stays.
  assert.equal(keepingStar(voice, undefined), voice);
  assert.equal(keepingStar(voice, voice), voice);
  assert.equal(isStarred(keepingStar(withStar(voice, true), voice)), true);
});
