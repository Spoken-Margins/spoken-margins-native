import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Episode, Margin, PlaybackPosition, Show } from '../../shared/model.ts';
import { DEFAULT_SETTINGS, readMembership, type LibraryMembership, type Membership, type SettingRow, type Settings } from '../store/schema.ts';
import {
  addedRow,
  followsAShow,
  inLibrary,
  isMigrated,
  libraryCountForShow,
  libraryEpisodes,
  membershipRow,
  prepareLibrary,
  stillMovedOut,
  type PrepareInput,
} from './library-membership.ts';

const NOW = '2026-11-23T15:00:00.000Z';
const LATER = '2026-11-24T09:00:00.000Z';
const FEED = 'feed:https://feeds.test/lemonade.rss';
const SHARED = 'shared:apple:123';

function episode(id: string, showId = FEED, extra: Partial<Episode> = {}): Episode {
  return { id, showId, title: id, audioUrl: `https://media.test/${id}.mp3`, ...extra };
}
function margin(episodeId: string, extra: Partial<Margin> = {}): Margin {
  return { id: `m-${episodeId}`, episodeId, atSeconds: 10, createdAt: NOW, text: 'note', ...extra };
}
function place(episodeId: string, seconds: number): PlaybackPosition {
  return { episodeId, seconds, updatedAt: NOW };
}
function settings(libraryModel: Settings['libraryModel'], libraryMovedOut: readonly string[] = []): PrepareInput['settings'] {
  return { libraryModel, libraryMovedOut };
}
function rowsMap(rows: readonly SettingRow[]): Map<string, unknown> {
  return new Map(rows.map((r) => [r.key, r.value]));
}

// The move's table (Design, "The one-time move"): one row per case, what the store holds and where the episode ends.
const moveTable: { name: string; ep: Episode; margins?: Margin[]; positions?: PlaybackPosition[]; existing?: Membership; expect: 'in' | 'out' | 'kept-in' | 'kept-out' }[] = [
  { name: 'a friend’s shared item, never played', ep: episode('shared-1', SHARED), expect: 'in' },
  { name: 'own Margin on it', ep: episode('own-margin'), margins: [margin('own-margin')], expect: 'in' },
  { name: 'a friend’s Margin on it', ep: episode('friend-margin'), margins: [margin('friend-margin', { author: 'Sam' })], expect: 'in' },
  { name: 'place at 0 s', ep: episode('place-0'), positions: [place('place-0', 0)], expect: 'out' },
  { name: 'place at 40 s', ep: episode('place-40'), positions: [place('place-40', 40)], expect: 'in' },
  { name: 'finished (place near the end)', ep: episode('finished', FEED, { durationSeconds: 600 }), positions: [place('finished', 595)], expect: 'in' },
  { name: 'a place that is not a number', ep: episode('place-nan'), positions: [place('place-nan', Number.NaN)], expect: 'out' },
  { name: 'untouched feed episode', ep: episode('untouched'), expect: 'out' },
  { name: 'an existing "in" row', ep: episode('was-in'), existing: { in: true, at: '2026-11-01T00:00:00Z' }, expect: 'kept-in' },
  { name: 'an existing "out" row, with a Margin', ep: episode('was-out'), margins: [margin('was-out')], existing: { in: false, at: '2026-11-02T00:00:00Z' }, expect: 'kept-out' },
];

for (const row of moveTable) {
  test(`the one-time move: ${row.name} → ${row.expect}`, () => {
    const library: LibraryMembership = row.existing ? { [row.ep.id]: row.existing } : {};
    const result = prepareLibrary(
      { episodes: [row.ep], margins: row.margins ?? [], positions: row.positions ?? [], library, settings: settings('') },
      NOW,
    );
    const written = rowsMap(result.rows);
    const key = `library:${row.ep.id}`;
    switch (row.expect) {
      case 'in':
        assert.deepEqual(written.get(key), { in: true, at: NOW });
        assert.equal(inLibrary(row.ep.id, result.library), true);
        assert.deepEqual(result.movedOut, []);
        break;
      case 'out':
        assert.equal(written.has(key), false, 'no row is written for a moved-out episode');
        assert.equal(inLibrary(row.ep.id, result.library), false);
        assert.deepEqual(result.movedOut, [row.ep.id]);
        break;
      case 'kept-in':
      case 'kept-out':
        assert.equal(written.has(key), false, 'an existing row is never rewritten');
        assert.deepEqual(result.library[row.ep.id], row.existing);
        assert.deepEqual(result.movedOut, []);
        break;
    }
    assert.deepEqual(written.get('libraryMovedOut'), result.movedOut, 'the moved-out list is written with the rows');
    assert.deepEqual(result.finish, { key: 'libraryModel', value: 'added' });
    assert.equal(result.rows.some((r) => r.key === 'libraryModel'), false, 'libraryModel is written last, on its own');
  });
}

test('the one-time move on an empty store finds nothing and still finishes', () => {
  const result = prepareLibrary({ episodes: [], margins: [], positions: [], library: {}, settings: settings('') }, NOW);
  assert.deepEqual(result.movedOut, []);
  assert.deepEqual(result.rows, [{ key: 'libraryMovedOut', value: [] }]);
  assert.deepEqual(result.finish, { key: 'libraryModel', value: 'added' });
});

test('the returning seed (A Margin, B place, C untouched, D shared) keeps A, B and D and moves C', () => {
  const episodes = [episode('A'), episode('B'), episode('C'), episode('D', SHARED)];
  const result = prepareLibrary(
    { episodes, margins: [margin('A'), margin('D', { author: 'Sam' })], positions: [place('B', 40)], library: {}, settings: settings('') },
    NOW,
  );
  assert.deepEqual(libraryEpisodes(episodes, result.library, true).map((e) => e.id), ['A', 'B', 'D']);
  assert.deepEqual(result.movedOut, ['C']);
  assert.deepEqual(stillMovedOut(result.movedOut, episodes, result.library), ['C']);
});

function applyRows(library: LibraryMembership, rows: readonly SettingRow[], base: SettingRow[] = []): { library: LibraryMembership; settingRows: SettingRow[] } {
  const settingRows = [...base.filter((b) => !rows.some((r) => r.key === b.key)), ...rows];
  return { library: { ...library, ...readMembership(rows) }, settingRows };
}

test('relaunch: a move cut short after its rows but before libraryModel runs again and keeps a superset', () => {
  const episodes = [episode('A'), episode('B'), episode('C'), episode('D', SHARED)];
  const margins = [margin('A')];
  const positions = [place('B', 40)];
  const first = prepareLibrary({ episodes, margins, positions, library: {}, settings: settings('') }, NOW);
  // The tab closed after the first putMany: rows and libraryMovedOut stored, libraryModel still ''.
  const stored = applyRows({}, first.rows);
  const second = prepareLibrary({ episodes, margins, positions, library: stored.library, settings: settings('', first.movedOut) }, LATER);
  for (const id of Object.keys(first.library)) {
    assert.equal(inLibrary(id, second.library), true, `${id} stays in after the rerun`);
    assert.equal(second.library[id]?.at, NOW, `${id} keeps its first time`);
  }
  assert.deepEqual(second.movedOut, first.movedOut);
  assert.equal(second.rows.filter((r) => r.key.startsWith('library:')).length, 0, 'no row is written twice');
  assert.deepEqual(second.finish, { key: 'libraryModel', value: 'added' });
});

test('relaunch: a migrated store is left as it is; running the pass over its own output writes nothing', () => {
  const episodes = [episode('A'), episode('C')];
  const first = prepareLibrary({ episodes, margins: [margin('A')], positions: [], library: {}, settings: settings('') }, NOW);
  const stored = applyRows({}, first.rows);
  const again = prepareLibrary(
    { episodes, margins: [margin('A')], positions: [place('C', 30)], library: stored.library, settings: settings('added', first.movedOut) },
    LATER,
  );
  assert.deepEqual(again.rows, [], 'nothing to write');
  assert.equal(again.finish, undefined);
  assert.deepEqual(again.movedOut, ['C'], 'the stored list is returned as it is');
  assert.equal(inLibrary('C', again.library), false, 'a place alone does not add once migrated: a play in this copy writes its own row');
});

test('the keep pass adds shared items and episodes with a Margin that have no row, and leaves "out" rows alone', () => {
  const episodes = [episode('shared-new', SHARED), episode('margin-new'), episode('removed'), episode('plain'), episode('removed-shared', SHARED)];
  const library: LibraryMembership = {
    removed: { in: false, at: '2026-11-20T00:00:00Z' },
    'removed-shared': { in: false, at: '2026-11-20T00:00:00Z' },
  };
  const result = prepareLibrary(
    { episodes, margins: [margin('margin-new', { author: 'Sam' }), margin('removed')], positions: [place('plain', 50)], library, settings: settings('added') },
    NOW,
  );
  const written = rowsMap(result.rows);
  assert.deepEqual([...written.keys()].sort(), ['library:margin-new', 'library:shared-new']);
  assert.equal(inLibrary('removed', result.library), false);
  assert.equal(inLibrary('removed-shared', result.library), false);
  assert.equal(inLibrary('plain', result.library), false);
  assert.equal(result.finish, undefined);
});

test('the move does not change the input membership', () => {
  const library: LibraryMembership = Object.freeze({ A: Object.freeze({ in: true, at: '2026-11-01T00:00:00Z' }) });
  const result = prepareLibrary({ episodes: [episode('A'), episode('B', SHARED)], margins: [], positions: [], library, settings: settings('') }, NOW);
  assert.deepEqual(Object.keys(library), ['A']);
  assert.equal(inLibrary('B', result.library), true);
});

test('long-source: 20,000 episodes over 40 shows move with a correct count', () => {
  const episodes: Episode[] = [];
  const margins: Margin[] = [];
  const positions: PlaybackPosition[] = [];
  for (let s = 0; s < 40; s += 1) {
    for (let e = 0; e < 500; e += 1) {
      const id = `feed:s${s}#e${e}`;
      episodes.push(episode(id, `feed:s${s}`));
      if (e % 50 === 0) margins.push(margin(id));
      else if (e % 50 === 1) positions.push(place(id, 12));
    }
  }
  const result = prepareLibrary({ episodes, margins, positions, library: {}, settings: settings('') }, NOW);
  // 40 shows × 20 kept per show (10 with a Margin, 10 with a place).
  assert.equal(Object.keys(result.library).length, 800);
  assert.equal(result.movedOut.length, 20_000 - 800);
  assert.equal(new Set(result.movedOut).size, result.movedOut.length, 'each id once');
  assert.equal(stillMovedOut(result.movedOut, episodes, result.library).length, 20_000 - 800);
});

test('libraryEpisodes: every episode before migration, only "in" rows after', () => {
  const episodes = [episode('in'), episode('out'), episode('none')];
  const library: LibraryMembership = { in: { in: true, at: NOW }, out: { in: false, at: NOW } };
  assert.deepEqual(libraryEpisodes(episodes, library, false).map((e) => e.id), ['in', 'out', 'none']);
  assert.deepEqual(libraryEpisodes(episodes, library, true).map((e) => e.id), ['in']);
  assert.notEqual(libraryEpisodes(episodes, library, false), episodes, 'a copy, so a caller sorting it leaves the snapshot alone');
});

test('addedRow keeps an existing "in" row and its first time; replaces no row or an "out" row', () => {
  const first = addedRow(undefined, NOW);
  assert.deepEqual(first, { in: true, at: NOW });
  assert.equal(addedRow(first, LATER), first, 'a double add writes the same row');
  assert.deepEqual(addedRow({ in: false, at: NOW }, LATER), { in: true, at: LATER });
});

test('inLibrary reads no inherited value: an episode id like "constructor" or "__proto__" with no row is not in', () => {
  const library = readMembership([]);
  assert.equal(inLibrary('constructor', library), false);
  assert.equal(inLibrary('__proto__', library), false);
  assert.equal(inLibrary('toString', {}), false);
});

test('isMigrated reads only libraryModel "added"', () => {
  assert.equal(isMigrated(DEFAULT_SETTINGS), false);
  assert.equal(isMigrated({ libraryModel: 'added' }), true);
});

test('followsAShow: a shared show alone is not following', () => {
  const show = (id: string): Show => ({ id, kind: 'podcast', title: id, feedUrl: 'https://feeds.test/x.rss', followedAt: NOW });
  assert.equal(followsAShow([]), false);
  assert.equal(followsAShow([show(SHARED)]), false);
  assert.equal(followsAShow([show(SHARED), show(FEED)]), true);
});

test('libraryCountForShow counts every stored episode before migration, only "in" ones after', () => {
  const episodes = [episode('a'), episode('b'), episode('c'), episode('other', 'feed:other')];
  const library: LibraryMembership = { a: { in: true, at: NOW }, b: { in: false, at: NOW } };
  assert.equal(libraryCountForShow(FEED, episodes, library, false), 3);
  assert.equal(libraryCountForShow(FEED, episodes, library, true), 1);
  assert.equal(libraryCountForShow('feed:none', episodes, library, true), 0);
});

test('stillMovedOut drops ids no longer stored, ids that since got a row (in or out), and repeats', () => {
  const episodes = [episode('a'), episode('b'), episode('c')];
  const library: LibraryMembership = { b: { in: true, at: NOW }, c: { in: false, at: NOW } };
  assert.deepEqual(stillMovedOut(['a', 'a', 'b', 'c', 'gone'], episodes, library), ['a']);
});

test('membershipRow writes the key and a plain value that readMembership reads back', () => {
  const row = membershipRow('feed:x#1', { in: true, at: NOW });
  assert.deepEqual(row, { key: 'library:feed:x#1', value: { in: true, at: NOW } });
  assert.deepEqual({ ...readMembership([row]) }, { 'feed:x#1': { in: true, at: NOW } });
});
