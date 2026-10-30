import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatClock } from './clock.ts';

test('formats minutes and seconds, and hours from an hour on', () => {
  assert.equal(formatClock(0), '0:00');
  assert.equal(formatClock(59.9), '0:59');
  assert.equal(formatClock(61), '1:01');
  assert.equal(formatClock(3600), '1:00:00');
  assert.equal(formatClock(3725), '1:02:05');
});

test('shows 0:00 for a time the player has not learned yet', () => {
  for (const value of [Number.NaN, Number.POSITIVE_INFINITY, -4]) {
    assert.equal(formatClock(value), '0:00');
  }
});
