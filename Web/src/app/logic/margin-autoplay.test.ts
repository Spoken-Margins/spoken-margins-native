import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Margin } from '../../shared/model.ts';
import { CrossingClock, dueMargins, firesByItself, MAX_PLAYING_STEP_SECONDS } from './margin-autoplay.ts';
import { cueFor } from './arrival.ts';

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

// #4472: the countdown's Skip, then playback, as the player feeds the clock: the seek's landing, then a time update
// every quarter second. Every row's Margin fires once, at its moment. The crossing logic was not why a Margin waited
// after "Skip to just before" (the browser refused the clip, player.tsx), and these rows keep it that way.
test('after either Skip, playback reaching the next friend Margin fires it once, for every kind and spacing (#4472)', () => {
  const voice = { blob: new Blob([]), mimeType: 'audio/mp4', durationSeconds: 3 };
  const spoken = (id: string, at: number, extra: Partial<Margin> = {}): Margin => ({ ...margin(id, at), voice, ...extra });
  const written = (id: string, at: number, extra: Partial<Margin> = {}): Margin => ({ ...margin(id, at), text: `Words ${id}.`, ...extra });
  const rows: Array<{ name: string; margins: Margin[]; from: number; skip: RegExp }> = [
    { name: 'spoken, far ahead', margins: [spoken('t', 300)], from: 100, skip: /^Skip to just before/ },
    { name: 'written, read aloud', margins: [written('t', 300)], from: 100, skip: /^Skip to just before/ },
    { name: 'spoken with placeholder words', margins: [spoken('t', 300, { text: 'Voice Margin at 5:00 in Episode, 31 Oct 2026' })], from: 100, skip: /^Skip to just before/ },
    { name: 'landing exactly 20 s before', margins: [spoken('t', 300)], from: 278.9, skip: /^Skip to just before/ },
    { name: 'inside the lead-in', margins: [spoken('t', 300)], from: 285, skip: /^Skip to Sam now/ },
    { name: 'the first of several', margins: [spoken('t', 60), spoken('b', 200), spoken('c', 400)], from: 0, skip: /^Skip to just before/ },
    { name: 'the last of several', margins: [spoken('a', 60), spoken('b', 200), spoken('t', 400)], from: 250, skip: /^Skip to just before/ },
    { name: 'one second after another', margins: [spoken('a', 299), spoken('t', 300)], from: 100, skip: /^Skip to just before/ },
    { name: 'past a silent written one', margins: [written('s', 290, { readAloud: false }), spoken('t', 300)], from: 100, skip: /^Skip to just before/ },
    { name: 'at a fraction of a second', margins: [spoken('t', 300.987)], from: 100, skip: /^Skip to just before/ },
  ];
  for (const row of rows) {
    const cue = cueFor(row.margins, row.from, 'Sam');
    assert.equal(cue?.kind, 'countdown', row.name);
    if (cue?.kind !== 'countdown') continue;
    assert.match(cue.skip.label, row.skip, row.name);
    const clock = new CrossingClock();
    clock.playing(row.from);
    clock.seeking(cue.skip.to);
    const target = row.margins.find((m) => m.id === 't')!;
    const fired: string[] = [];
    for (let now = cue.skip.to; now < target.atSeconds + 2; now += 0.25) fired.push(...ids(clock.update(row.margins, now)));
    assert.equal(fired.filter((id) => id === 't').length, 1, row.name);
  }
});

test('a Margin made at the playhead while paused does not fire when playback resumes (audit 3 on #4505)', () => {
  const clock = new CrossingClock();
  const everything = () => true;
  const before = [margin('old', 300)];
  clock.playing(10);
  assert.deepEqual(ids(clock.update(before, 10.25, everything)), []);
  // Record pauses at 10.25 and saves the listener's own Margin there; then playback resumes.
  const after = [...before, margin('recorded', 10.25, null)];
  clock.playing(10.25);
  assert.deepEqual(ids(clock.update(after, 10.5, everything)), []);
  // Rewinding over it later is the listener asking to hear it again: it fires.
  clock.seeking(10);
  assert.deepEqual(ids(clock.update(after, 10.3, everything)), ['recorded']);
});
