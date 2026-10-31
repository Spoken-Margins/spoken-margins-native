import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Margin } from '../../shared/model.ts';
import { dueMargins, firesByItself, MAX_PLAYING_STEP_SECONDS } from './margin-autoplay.ts';

const margin = (id: string, atSeconds: number, author: string | null = 'Sam'): Margin => ({
  id,
  episodeId: 'e',
  atSeconds,
  createdAt: '2026-10-31T10:00:00Z',
  ...(author !== null && { author }),
});
const ids = (list: Margin[]) => list.map((m) => m.id);

test('a Margin fires when playback crosses its moment, once', () => {
  const m = [margin('a', 42)];
  assert.deepEqual(ids(dueMargins(m, 41.6, 41.9)), []);
  assert.deepEqual(ids(dueMargins(m, 41.9, 42.2)), ['a']);
  assert.deepEqual(ids(dueMargins(m, 42.2, 42.5)), []);
});

test('starting to play exactly on a Margin plays it', () => {
  assert.deepEqual(ids(dueMargins([margin('a', 42)], 42, 42.25)), ['a']);
});

test('skipping forward past a Margin does not fire it', () => {
  const m = [margin('a', 42)];
  assert.deepEqual(ids(dueMargins(m, 30, 45)), []);
  assert.deepEqual(ids(dueMargins(m, 41, 41 + MAX_PLAYING_STEP_SECONDS + 0.1)), []);
});

test('no previous time (first update after play or a seek) fires nothing', () => {
  assert.deepEqual(dueMargins([margin('a', 42)], undefined, 42.1), []);
});

test('a backward step fires nothing, and playing over the Margin again fires it again', () => {
  const m = [margin('a', 42)];
  assert.deepEqual(dueMargins(m, 60, 40), []);
  assert.deepEqual(ids(dueMargins(m, 41.9, 42.1)), ['a']);
});

test('a step that crosses two Margins gives them in order', () => {
  const m = [margin('b', 42.8), margin('a', 42.1), margin('far', 90)];
  assert.deepEqual(ids(dueMargins(m, 42, 43)), ['a', 'b']);
});

test('the listener’s own Margins never fire by themselves', () => {
  const m = [margin('mine', 42, null), margin('blank', 42, '')];
  assert.equal(firesByItself(m[0]), false);
  assert.deepEqual(dueMargins(m, 41.9, 42.2), []);
});
