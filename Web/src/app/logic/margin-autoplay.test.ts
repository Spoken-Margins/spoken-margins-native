import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Margin } from '../../shared/model.ts';
import { CrossingClock, dueMargins, firesByItself, MAX_PLAYING_STEP_SECONDS } from './margin-autoplay.ts';

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

test('no previous time fires nothing', () => {
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

test('a seek that lands on a Margin plays it, even when the first update after the seek is already past it (#3254)', () => {
  const m = [margin('a', 42)];
  const clock = new CrossingClock();
  clock.seeking(42);
  // A slow machine: the clock ran on before the first update, and 'playing' arrives after it.
  assert.deepEqual(ids(clock.update(m, 42.4)), ['a']);
  const late = new CrossingClock();
  late.seeking(42);
  late.playing(42.3);
  assert.deepEqual(ids(late.update(m, 42.5)), ['a']);
});

test('the clock fires nothing for a new episode until it has played, then counts from where it started', () => {
  const m = [margin('a', 0.1)];
  const clock = new CrossingClock();
  clock.seeking(30);
  clock.reset();
  assert.deepEqual(clock.update(m, 0.2), []);
  const fresh = new CrossingClock();
  fresh.playing(0);
  assert.deepEqual(ids(fresh.update(m, 0.25)), ['a']);
});

test('a seek forward past a Margin, then playing on, does not fire it; a seek back before it does', () => {
  const m = [margin('a', 42)];
  const clock = new CrossingClock();
  clock.playing(30);
  clock.seeking(50);
  assert.deepEqual(clock.update(m, 50.25), []);
  clock.seeking(41);
  assert.deepEqual(ids(clock.update(m, 42.1)), ['a']);
});
