import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Episode, Margin, PlaybackPosition, Show } from '../../shared/model.ts';
import {
  followingRows,
  libraryRows,
  marginGroups,
  newestFirst,
  newestMarginId,
  nextSpeed,
  stableId,
  timelineFraction,
} from './library.ts';

const show = (id: string, title: string): Show => ({ id, kind: 'podcast', title, feedUrl: `https://e.test/${id}`, followedAt: '2026-10-01T00:00:00Z' });
const ep = (id: string, showId: string, publishedAt?: string, durationSeconds?: number): Episode => ({ id, showId, title: `Ep ${id}`, publishedAt, durationSeconds });
const pos = (episodeId: string, seconds: number): PlaybackPosition => ({ episodeId, seconds, updatedAt: '2026-10-30T00:00:00Z' });
const margin = (id: string, episodeId: string, atSeconds: number, createdAt: string): Margin => ({ id, episodeId, atSeconds, createdAt, text: id });

test('newestFirst puts the newest published first and undated last', () => {
  const list = newestFirst([
    ep('a', 's', '2026-09-24T10:00:00Z'),
    ep('undated', 's'),
    ep('c', 's', '2026-09-26T10:00:00Z'),
    ep('bad-date', 's', 'not a date'),
    ep('b', 's', '2026-09-25T10:00:00Z'),
  ]);
  assert.deepEqual(list.map((e) => e.id), ['c', 'b', 'a', 'bad-date', 'undated']);
});

test('libraryRows shows resume positions only for started episodes, and hides unfollowed shows', () => {
  const rows = libraryRows(
    [ep('new', 's1', '2026-10-03', 600), ep('half', 's1', '2026-10-02', 600), ep('done', 's1', '2026-10-01', 600), ep('orphan', 'gone', '2026-10-04')],
    [show('s1', 'One')],
    [pos('half', 300), pos('done', 595)],
  );
  assert.deepEqual(
    rows.map((r) => [r.episode.id, r.state, r.resumeAt, r.progress]),
    [
      ['new', 'new', undefined, undefined],
      ['half', 'started', 300, 0.5],
      ['done', 'finished', undefined, 595 / 600],
    ],
  );
});

test('followingRows sorts shows by their newest episode and counts unstarted ones', () => {
  const rows = followingRows(
    [show('quiet', 'Quiet'), show('busy', 'Busy'), show('empty', 'Empty')],
    [ep('q1', 'quiet', '2026-09-01'), ep('b1', 'busy', '2026-10-01'), ep('b2', 'busy', '2026-10-02'), ep('b3', 'busy', '2026-10-03')],
    [pos('b3', 10)],
  );
  assert.deepEqual(rows.map((r) => [r.show.id, r.newest?.id, r.newCount]), [
    ['busy', 'b3', 2],
    ['quiet', 'q1', 1],
    ['empty', undefined, 0],
  ]);
});

test('marginGroups puts the group with the newest Margin first, Margins in audio order', () => {
  const margins = [
    margin('old-late', 'e1', 900, '2026-10-01T00:00:00Z'),
    margin('newest', 'e2', 50, '2026-10-30T00:00:00Z'),
    margin('old-early', 'e1', 10, '2026-10-02T00:00:00Z'),
    margin('e2-early', 'e2', 5, '2026-09-01T00:00:00Z'),
  ];
  const groups = marginGroups(margins, [ep('e1', 's'), ep('e2', 's')]);
  assert.deepEqual(groups.map((g) => [g.episodeId, g.margins.map((m) => m.id)]), [
    ['e2', ['e2-early', 'newest']],
    ['e1', ['old-early', 'old-late']],
  ]);
  assert.equal(newestMarginId(margins), 'newest');
  assert.equal(newestMarginId([]), undefined);
});

test('nextSpeed cycles and resets unknown speeds to 1x', () => {
  assert.equal(nextSpeed(1), 1.25);
  assert.equal(nextSpeed(2), 0.8);
  assert.equal(nextSpeed(3.3), 1);
});

test('timelineFraction clamps and tolerates unknown durations', () => {
  assert.equal(timelineFraction(30, 60), 0.5);
  assert.equal(timelineFraction(90, 60), 1);
  assert.equal(timelineFraction(-5, 60), 0);
  assert.equal(timelineFraction(30, undefined), 0);
  assert.equal(timelineFraction(30, Number.NaN), 0);
});

test('stableId is stable and differs for different inputs', () => {
  assert.equal(stableId('https://e.test/feed'), stableId('https://e.test/feed'));
  assert.notEqual(stableId('https://e.test/feed'), stableId('https://e.test/feed2'));
  assert.match(stableId(''), /^[0-9a-f]{8}$/);
});
