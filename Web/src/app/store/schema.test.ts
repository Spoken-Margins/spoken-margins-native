import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Episode, Margin, PlaybackPosition, Show } from '../../shared/model.ts';
import { DB_VERSION, DEFAULT_SETTINGS, readSettings, SCHEMA_KEY, SCHEMA_VERSION, storedVersion, upgrade, type StoredRows } from './schema.ts';

// The rows the web store held before #3012 (shape 1), as db.ts wrote them: no version row, three settings.
function shapeOne(): StoredRows {
  const show: Show = { id: 'feed:https://feeds.test/a.rss', kind: 'podcast', title: 'A', feedUrl: 'https://feeds.test/a.rss', followedAt: '2026-10-30T01:00:00Z' };
  const episode: Episode = { id: `${show.id}#g1`, showId: show.id, title: 'One', guid: 'g1', audioUrl: 'https://media.test/1.mp3' };
  const voice = { blob: new Blob([new Uint8Array([1, 2, 3])], { type: 'audio/mp4' }), mimeType: 'audio/mp4', durationSeconds: 2.5 };
  const margins: Margin[] = [
    { id: 'm1', episodeId: episode.id, atSeconds: 12, createdAt: '2026-10-30T01:01:00Z', text: 'Written' },
    { id: 'm2', episodeId: episode.id, atSeconds: 40.5, createdAt: '2026-10-30T01:02:00Z', voice },
  ];
  const positions: PlaybackPosition[] = [{ episodeId: episode.id, seconds: 41, updatedAt: '2026-10-30T01:03:00Z' }];
  return {
    shows: [show],
    episodes: [episode],
    margins,
    positions,
    settings: [
      { key: 'relayAllowed', value: true },
      { key: 'relayAsked', value: true },
      { key: 'playbackRate', value: 1.5 },
    ],
  };
}

test('IndexedDB’s own version stays 1, so an older copy open in another tab can still open the database', () => {
  // Raising it makes every copy built before the raise fail to open with a VersionError: a store change needs a
  // new object store and a plan for the older copies, not a casual bump.
  assert.equal(DB_VERSION, 1);
});

test('shape 1 (no version row) reads into the current shape with every record untouched', () => {
  const rows = shapeOne();
  const { snapshot, from, writes } = upgrade(rows);
  assert.equal(from, 1);
  assert.deepEqual(writes, [{ key: SCHEMA_KEY, value: SCHEMA_VERSION }]);
  assert.equal(snapshot.margins, rows.margins, 'records pass through as they are');
  assert.equal(snapshot.margins[1]?.voice?.blob, rows.margins[1]?.voice?.blob, 'voice audio is the same Blob');
  assert.deepEqual(snapshot.shows, rows.shows);
  assert.deepEqual(snapshot.episodes, rows.episodes);
  assert.deepEqual(snapshot.positions, rows.positions);
  assert.deepEqual(snapshot.settings, { ...DEFAULT_SETTINGS, relayAllowed: true, relayAsked: true, playbackRate: 1.5 });
  assert.equal(snapshot.settings.persistAsked, false);
  assert.equal(snapshot.settings.lastBackupAt, '');
});

test('the current shape reads without writing anything', () => {
  const rows = shapeOne();
  rows.settings.push({ key: SCHEMA_KEY, value: SCHEMA_VERSION }, { key: 'lastBackupAt', value: '2026-10-30T02:00:00Z' }, { key: 'persistAsked', value: true });
  const { snapshot, from, writes } = upgrade(rows);
  assert.equal(from, SCHEMA_VERSION);
  assert.deepEqual(writes, []);
  assert.equal(snapshot.settings.lastBackupAt, '2026-10-30T02:00:00Z');
  assert.equal(snapshot.settings.persistAsked, true);
});

test('a store from a newer copy is read as it is, and its version row is never lowered', () => {
  const rows = shapeOne();
  const future = { ...rows.margins[0], colour: 'blue' } as Margin;
  rows.margins = [future];
  rows.settings.push({ key: SCHEMA_KEY, value: SCHEMA_VERSION + 3 }, { key: 'someFutureSetting', value: 'x' });
  const { snapshot, from, writes } = upgrade(rows);
  assert.equal(from, SCHEMA_VERSION + 3);
  assert.deepEqual(writes, []);
  assert.equal((snapshot.margins[0] as Margin & { colour?: string }).colour, 'blue', 'a field this copy doesn’t know survives');
  assert.equal('someFutureSetting' in snapshot.settings, false);
});

test('a setting row of the wrong type keeps its default rather than breaking the app', () => {
  const settings = readSettings([
    { key: 'playbackRate', value: '2' },
    { key: 'relayAllowed', value: 'yes' },
    { key: 'lastBackupAt', value: 1234 },
    { key: 'playbackRate', value: Number.NaN },
    { key: 'toString', value: 'x' },
  ]);
  assert.deepEqual(settings, DEFAULT_SETTINGS);
  assert.equal(storedVersion([{ key: SCHEMA_KEY, value: '2' }]), 1);
  assert.equal(storedVersion([{ key: SCHEMA_KEY, value: 0 }]), 1);
  assert.equal(storedVersion([]), 1);
});

test('the transcription answer reads back, and an unknown value means not asked yet', () => {
  assert.equal(readSettings([]).transcription, '');
  assert.equal(readSettings([{ key: 'transcription', value: 'on' }]).transcription, 'on');
  assert.equal(readSettings([{ key: 'transcription', value: 'off' }]).transcription, 'off');
  // A value no copy writes (or a newer copy's) is not taken as a yes, so nothing downloads on it.
  assert.equal(readSettings([{ key: 'transcription', value: 'always' }]).transcription, '');
  assert.equal(readSettings([{ key: 'transcription', value: true }]).transcription, '');
});
