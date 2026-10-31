import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Episode, Margin, Show } from '../../shared/model.ts';
import type { PacketRead } from '../ports.ts';
import { episode as fixtureEpisode, voiceMargins } from '../../packet/fixtures.ts';
import { readPacket } from '../../packet/read.ts';
import { writePacket } from '../../packet/write.ts';
import { findEpisode, importSummary, landingOffer, placeImport, sharedShowFor } from './import.ts';

const show: Show = { id: 'feed:https://feeds.test/show.rss', kind: 'podcast', title: 'Show', feedUrl: 'https://feeds.test/show.rss', followedAt: 'T0' };
const mine: Episode = {
  id: 'feed:https://feeds.test/show.rss#g-1',
  showId: show.id,
  title: 'Episode 1',
  guid: 'g-1',
  audioUrl: 'https://media.example.com/1.mp3',
  pageUrl: 'https://example.com/show/episode-1',
};

function margin(id: string, at: number): Margin {
  return { id: `packet:d:${id}`, episodeId: 'packet:d', atSeconds: at, createdAt: '2026-10-30T00:00:00Z', text: id };
}

function read(episode: PacketRead['episode'], extra: Partial<PacketRead> = {}): PacketRead {
  return { contentDigest: 'd'.repeat(64), episode, margins: [margin('b', 40), margin('a', 12.5)], textMarginCount: 0, ...extra };
}

test('the listener’s own copy is found by guid, then audio address, then page', () => {
  const others: Episode[] = [{ ...mine, id: 'x', guid: 'other', audioUrl: 'https://media.example.com/x.mp3', pageUrl: 'https://example.com/x' }];
  const library = [...others, mine];
  assert.equal(findEpisode(read({ title: 'T', guid: ' g-1 ' }), library), mine);
  assert.equal(findEpisode(read({ title: 'T', guid: 'unknown', audioUrl: mine.audioUrl }), library), mine);
  assert.equal(findEpisode(read({ title: 'T', pageUrl: 'https://EXAMPLE.com/show/episode-1/?utm=x' }), library), mine);
  // Guid wins over a conflicting audio address: the app's order.
  assert.equal(findEpisode(read({ title: 'T', guid: 'other', audioUrl: mine.audioUrl }), library), others[0]);
  assert.equal(findEpisode(read({ title: 'T' }), library), undefined);
  assert.equal(findEpisode(read({ title: 'T', guid: '', audioUrl: 'https://media.example.com/none.mp3' }), library), undefined);
});

test('Margins on an episode in the Library go to it, and play from the earliest', () => {
  const placed = placeImport(read({ title: 'T', guid: 'g-1' }), [show], [mine]);
  assert.equal(placed.newEpisode, false);
  assert.equal(placed.show, undefined);
  assert.equal(placed.episode, mine);
  assert.deepEqual(placed.margins.map((m) => m.episodeId), [mine.id, mine.id]);
  assert.equal(placed.landAt, 12.5);
  assert.deepEqual(placed.margins.map((m) => m.id), ['packet:d:b', 'packet:d:a'], 'ids stay, so opening the file twice adds nothing');
});

test('an episode not in the Library is added under the sender, ready to play', () => {
  const packetEpisode = { title: 'Their episode', guid: 'g-9', audioUrl: 'https://media.example.com/9.mp3', durationSeconds: 180, showTitle: 'Their show', publisher: 'Pub' };
  const placed = placeImport(read(packetEpisode, { sender: 'Ada' }), [show], [mine], 'NOW');
  assert.equal(placed.newEpisode, true);
  assert.deepEqual(placed.show, { id: 'shared:Ada', kind: 'podcast', title: 'Shared by Ada', feedUrl: '', followedAt: 'NOW' });
  assert.deepEqual(placed.episode, {
    id: 'shared:Ada#g-9', showId: 'shared:Ada', title: 'Their episode', guid: 'g-9', audioUrl: 'https://media.example.com/9.mp3', durationSeconds: 180,
  });
  assert.ok(placed.margins.every((m) => m.episodeId === 'shared:Ada#g-9'));

  // A second file from Ada reuses her show.
  const again = placeImport(read({ title: 'Another', audioUrl: 'https://media.example.com/10.mp3' }, { sender: 'Ada' }), [show, placed.show!], [mine]);
  assert.equal(again.show, undefined);
  assert.equal(again.episode.showId, 'shared:Ada');
  assert.equal(again.episode.id, 'shared:Ada#https://media.example.com/10.mp3');
});

test('no sender, no identity: still one show, and an id from the file', () => {
  assert.equal(sharedShowFor(undefined, 'T').title, 'Shared with you');
  assert.equal(sharedShowFor('  ', 'T').id, 'shared:');
  const placed = placeImport(read({ title: 'Untitled' }), [], []);
  assert.equal(placed.episode.id, `shared:#${'d'.repeat(64)}`);
});

test('the summary counts what was placed and names what wasn’t', () => {
  const placed = placeImport(read({ title: 'Ep', guid: 'g-1' }, { textMarginCount: 1 }), [show], [mine]);
  assert.equal(importSummary(placed, 'Ada'), 'Opened 2 Margins from Ada on “Episode 1”. 1 Margin is on an article’s text, which the web app can’t open yet.');
  const one = placeImport(read({ title: 'Ep', guid: 'g-1' }, { margins: [margin('a', 1)] }), [show], [mine]);
  assert.equal(importSummary(one, undefined), 'Opened 1 Margin on “Episode 1”.');
  const none = placeImport(read({ title: 'Ep' }, { margins: [], textMarginCount: 3 }), [], []);
  assert.equal(none.landAt, undefined);
  assert.equal(importSummary(none, undefined), 'This file has no Margins the web app can place. 3 Margins are on an article’s text, which the web app can’t open yet.');
});

test('opening a backup of Margins already here adds none of them again', () => {
  // As a backup of the listener's own Margins comes back: the same words at the same moments, under new ids.
  const here: Margin[] = [
    { id: 'own-a', episodeId: mine.id, atSeconds: 12.5, createdAt: 'T', text: 'a' },
    { id: 'own-b', episodeId: mine.id, atSeconds: 40.2, createdAt: 'T', text: 'b ' },
  ];
  const all = placeImport(read({ title: 'Ep', guid: 'g-1' }), [show], [mine], 'NOW', here);
  assert.deepEqual(all.margins, []);
  assert.equal(all.duplicates, 2);
  assert.equal(all.landAt, 12.5, 'still lands at the earliest Margin');
  assert.equal(importSummary(all, undefined), 'Every Margin in this file is already here, on “Episode 1”.');

  // Neighbours that are not the same Margin: other words, another moment, another episode.
  const near: Margin[] = [
    { id: 'x', episodeId: mine.id, atSeconds: 12.5, createdAt: 'T', text: 'A' },
    { id: 'y', episodeId: mine.id, atSeconds: 41, createdAt: 'T', text: 'b' },
    { id: 'z', episodeId: 'other', atSeconds: 12.5, createdAt: 'T', text: 'a' },
  ];
  const none = placeImport(read({ title: 'Ep', guid: 'g-1' }), [show], [mine], 'NOW', near);
  assert.equal(none.margins.length, 2);
  assert.equal(none.duplicates, 0);

  const some = placeImport(read({ title: 'Ep', guid: 'g-1' }), [show], [mine], 'NOW', here.slice(0, 1));
  assert.equal(importSummary(some, 'Ada'), 'Opened 1 Margin from Ada on “Episode 1”. 1 Margin was already here.');
});

test('a voice Margin without words, backed up and opened again, is not added twice (#3025)', async () => {
  const [, voice] = voiceMargins();
  const own: Margin = { ...voice, text: undefined };
  const packet = await readPacket((await writePacket(fixtureEpisode, [own])).bytes);
  assert.ok(packet.margins[0]?.text?.startsWith('Voice Margin at 2:05'), 'the packet carries placeholder words');
  const again = placeImport(packet, [], [fixtureEpisode], 'NOW', [own]);
  assert.deepEqual(again.margins, []);
  assert.equal(again.duplicates, 1);
  // A voice Margin at the same moment with words of its own is still a new Margin.
  const worded = { ...packet, margins: packet.margins.map((m) => ({ ...m, text: 'Mine, out loud.' })) };
  assert.equal(placeImport(worded, [], [fixtureEpisode], 'NOW', [own]).margins.length, 1);
});

test('after a file opens, Now Playing offers to start at the first Margin until it plays (#3039)', () => {
  const landing = { episodeId: 'e1', at: 83.6 };
  const waiting = { episodeId: 'e1', playing: false, loading: false };
  assert.equal(landingOffer(landing, waiting), 'Play from the first Margin, at 1:23');
  assert.equal(landingOffer(landing, { ...waiting, playing: true }), undefined);
  assert.equal(landingOffer(landing, { ...waiting, loading: true }), undefined);
  assert.equal(landingOffer(landing, { ...waiting, episodeId: 'e2' }), undefined);
  assert.equal(landingOffer(undefined, waiting), undefined);
});
