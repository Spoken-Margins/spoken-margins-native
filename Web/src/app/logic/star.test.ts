import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Margin } from '../../shared/model.ts';
import { canStar, isStarred, toggleStar, withStar } from './star.ts';

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
