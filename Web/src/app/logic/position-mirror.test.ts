import assert from 'node:assert/strict';
import { test } from 'node:test';

import type { PlaybackPosition } from '../../shared/model.ts';
import { MIRROR_KEY, mergeMirror, mirrorPosition, pruneMirror, readMirror, type MirrorStorage } from './position-mirror.ts';

const at = (episodeId: string, seconds: number, time: string): PlaybackPosition => ({ episodeId, seconds, updatedAt: `2026-11-12T10:00:${time}Z` });
const memory = (initial?: string): MirrorStorage & { value: string | null } => {
  const box = { value: initial ?? null } as MirrorStorage & { value: string | null };
  box.getItem = (key) => (key === MIRROR_KEY ? box.value : null);
  box.setItem = (key, value) => { if (key === MIRROR_KEY) box.value = value; };
  return box;
};
const ids = (...list: string[]) => new Set(list);

test('#4096: a place written to the mirror reads back, one row per episode', () => {
  const s = memory();
  mirrorPosition(s, at('a', 10, '01'));
  mirrorPosition(s, at('b', 20, '02'));
  mirrorPosition(s, at('a', 40, '03'));
  assert.deepEqual([...readMirror(s).values()].sort((x, y) => x.episodeId.localeCompare(y.episodeId)), [at('a', 40, '03'), at('b', 20, '02')]);
});

test('#4096: an older place never replaces a newer one for the same episode', () => {
  const s = memory();
  mirrorPosition(s, at('a', 40, '09'));
  mirrorPosition(s, at('a', 5, '01'));
  assert.equal(readMirror(s).get('a')?.seconds, 40);
});

test('#4096: refresh during playback: the mirrored place newer than the stored one wins, and goes back to storage', () => {
  // The scrub to 100 s committed to IndexedDB; the play on to 104 s only reached the mirror before the page went.
  const stored = [at('a', 100, '00')];
  const mirrored = new Map([['a', at('a', 104, '04')]]);
  const { positions, written } = mergeMirror(stored, mirrored, ids('a'));
  assert.deepEqual(positions, [at('a', 104, '04')]);
  assert.deepEqual(written, [at('a', 104, '04')]);
});

test('#4096: scrub while paused, refresh at once: the scrub is in the mirror though IndexedDB never got it', () => {
  const { positions, written } = mergeMirror([at('a', 12, '00')], new Map([['a', at('a', 70, '30')]]), ids('a'));
  assert.equal(positions[0].seconds, 70);
  assert.equal(written.length, 1);
});

test('#4096: a mirrored place that is older or equal changes nothing; an episode with no stored place takes the mirrored one', () => {
  const stored = [at('a', 100, '10')];
  const same = mergeMirror(stored, new Map([['a', at('a', 90, '05')], ['b', at('b', 7, '01')]]), ids('a', 'b'));
  assert.deepEqual(same.positions.sort((x, y) => x.episodeId.localeCompare(y.episodeId)), [at('a', 100, '10'), at('b', 7, '01')]);
  assert.deepEqual(same.written, [at('b', 7, '01')]);
  assert.deepEqual(mergeMirror(stored, new Map([['a', at('a', 100, '10')]]), ids('a')).written, []);
});

test('#4096: a place for an episode that is no longer in the library is left out', () => {
  const { positions, written } = mergeMirror([], new Map([['gone', at('gone', 5, '01')]]), ids('a'));
  assert.deepEqual(positions, []);
  assert.deepEqual(written, []);
});

test('#4096: pruning drops places storage already has (or has newer) and places of episodes that are gone', () => {
  const s = memory();
  mirrorPosition(s, at('a', 10, '01'));
  mirrorPosition(s, at('b', 50, '09'));
  mirrorPosition(s, at('gone', 3, '02'));
  pruneMirror(s, [at('a', 10, '01'), at('b', 20, '02')]);
  assert.deepEqual([...readMirror(s).values()], [at('b', 50, '09')]);
});

test('#4096: no storage, blocked storage, damaged or foreign values read as nothing, and never throw', () => {
  assert.equal(readMirror(undefined).size, 0);
  mirrorPosition(undefined, at('a', 1, '01'));
  for (const bad of ['', 'not json', '{"a":1}', 'null', '[1,"x",{"episodeId":"a"}]', JSON.stringify([{ episodeId: 'a', seconds: -1, updatedAt: 'x' }, { episodeId: 'a', seconds: Number.NaN, updatedAt: 'x' }])]) {
    assert.equal(readMirror(memory(bad)).size, 0, bad);
  }
  const throwing: MirrorStorage = { getItem() { throw new Error('blocked'); }, setItem() { throw new Error('full'); } };
  assert.equal(readMirror(throwing).size, 0);
  mirrorPosition(throwing, at('a', 1, '01'));
  pruneMirror(throwing, []);
  // One damaged row does not cost the good ones.
  const mixed = memory(JSON.stringify([{ episodeId: 'a', seconds: 4, updatedAt: '2026-11-12T10:00:01Z' }, { episodeId: 'b' }]));
  assert.deepEqual([...readMirror(mixed).keys()], ['a']);
});

test('#4096: a place with an unreadable time counts as the oldest', () => {
  const stored = [at('a', 100, '10')];
  assert.deepEqual(mergeMirror(stored, new Map([['a', { episodeId: 'a', seconds: 9, updatedAt: 'later' }]]), ids('a')).written, []);
  assert.equal(mergeMirror([], new Map([['a', { episodeId: 'a', seconds: 9, updatedAt: 'later' }]]), ids('a')).written.length, 1);
});
