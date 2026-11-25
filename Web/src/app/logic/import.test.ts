import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Episode, Margin, PercentMargin, Show } from '../../shared/model.ts';
import type { PacketRead } from '../ports.ts';
import { appParent, episode as fixtureEpisode, voiceMargins } from '../../packet/fixtures.ts';
import { readPacket } from '../../packet/read.ts';
import { writePacket } from '../../packet/write.ts';
import { UNNAMED_SENDER, findEpisode, importSummary, isSharedHolderTitle, landingOffer, packetShowFor, placeByPercent, placeImport, previewMargins, sharedShowFor, unnamedAuthorFor } from './import.ts';

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
  return { contentDigest: 'd'.repeat(64), episode, margins: [margin('b', 40), margin('a', 12.5)], textMarginCount: 0, percentMargins: [], pageMargins: [], ...extra };
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
    showTitle: 'Their show',
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
  assert.equal(importSummary(placed, 'Ada'), 'Opened 2 Margins from Ada on “Episode 1”. 1 Margin is on the article’s words. Open the file in Spoken Margins on iPhone to hear them in place.');
  const one = placeImport(read({ title: 'Ep', guid: 'g-1' }, { margins: [margin('a', 1)] }), [show], [mine]);
  assert.equal(importSummary(one, undefined), 'Opened 1 Margin on “Episode 1”.');
  const none = placeImport(read({ title: 'Ep' }, { margins: [], textMarginCount: 3 }), [], []);
  assert.equal(none.landAt, undefined);
  assert.equal(importSummary(none, undefined), 'This file has no Margins the web app can place. 3 Margins are on the article’s words. Open the file in Spoken Margins on iPhone to hear them in place.');
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
  const waiting = { episodeId: 'e1', playing: false, played: false, marginArrived: false, loading: false };
  assert.equal(landingOffer(landing, waiting), 'Play from the first Margin, at 1:23');
  assert.equal(landingOffer(landing, { ...waiting, playing: true }), undefined);
  // Paused again after playing (by the listener, or by a friend's clip the browser blocked): no second Play (#3254).
  assert.equal(landingOffer(landing, { ...waiting, played: true }), undefined);
  // A first Margin at the landing moment pauses the episode before it ever draws as playing: no offer over its clip (#3375).
  assert.equal(landingOffer(landing, { ...waiting, marginArrived: true }), undefined);
  assert.equal(landingOffer(landing, { ...waiting, loading: true }), undefined);
  assert.equal(landingOffer(landing, { ...waiting, episodeId: 'e2' }), undefined);
  assert.equal(landingOffer(undefined, waiting), undefined);
});

test('opened from a link, a Margin with no sender name is still a friend’s: it gets the author "Your friend" (#2168)', () => {
  const unnamed = placeImport(read({ title: 'T', guid: 'g-1' }), [show], [mine], undefined, [], { unnamedAuthor: UNNAMED_SENDER });
  assert.deepEqual(unnamed.margins.map((m) => m.author), ['Your friend', 'Your friend']);
  const named = placeImport(read({ title: 'T', guid: 'g-1' }, { margins: [{ ...margin('a', 1), author: ' Ada ' }] }), [show], [mine], undefined, [], { unnamedAuthor: UNNAMED_SENDER });
  assert.deepEqual(named.margins.map((m) => m.author), [' Ada ']);
  // A restored backup or an opened file keeps its own Margins as the listener's own.
  assert.deepEqual(placeImport(read({ title: 'T', guid: 'g-1' }), [show], [mine]).margins.map((m) => m.author), [undefined, undefined]);
});

test('a sender-less packet opened as a file is a friend’s; one out of a backup zip stays unsigned (#4226)', () => {
  assert.equal(unnamedAuthorFor('file'), 'Your friend');
  assert.equal(unnamedAuthorFor('link'), 'Your friend');
  assert.equal(unnamedAuthorFor('backup'), undefined);
  const authors = (arrival: 'backup' | 'file' | 'link') =>
    placeImport(read({ title: 'T', guid: 'g-1' }), [show], [mine], undefined, [], { unnamedAuthor: unnamedAuthorFor(arrival) }).margins.map((m) => m.author);
  assert.deepEqual(authors('file'), ['Your friend', 'Your friend']);
  assert.deepEqual(authors('backup'), [undefined, undefined]);
  // A Margin that already has an author keeps it, however the file arrived.
  const named = read({ title: 'T', guid: 'g-1' }, { margins: [{ ...margin('a', 1), author: 'Ada' }] });
  assert.deepEqual(placeImport(named, [show], [mine], undefined, [], { unnamedAuthor: unnamedAuthorFor('file') }).margins.map((m) => m.author), ['Ada']);
});

test('opening your own earlier "Save as a file" again adds no friend copies (#4226)', () => {
  const here: Margin[] = [
    { id: 'own-a', episodeId: mine.id, atSeconds: 12.5, createdAt: 'T', text: 'a' },
    { id: 'own-b', episodeId: mine.id, atSeconds: 40, createdAt: 'T', text: 'b' },
  ];
  const again = placeImport(read({ title: 'Ep', guid: 'g-1' }), [show], [mine], 'NOW', here, { unnamedAuthor: unnamedAuthorFor('file') });
  assert.deepEqual(again.margins, []);
  assert.equal(again.duplicates, 2);
});

// #4421: a friend's Margins on an article's words are placed on the voice that plays it, by how far through they sit.
test('a second packet’s preview shows a Margin already here as the stored copy: its id, heard and author (audit 2 on #4505)', () => {
  // Sam's packet A brought X at 3:10, and the listener heard it; the listener's own reply Y is stored unsigned.
  const storedX: Margin = { id: 'packet:A:x', episodeId: mine.id, atSeconds: 190, createdAt: '2026-10-30T00:00:00Z', text: 'X', author: 'Sam', heard: true };
  const storedY: Margin = { id: 'mine-y', episodeId: mine.id, atSeconds: 200, createdAt: '2026-10-30T00:01:00Z', text: 'Y', replyToId: storedX.id };
  // Packet B carries X again, the listener's Y back in Sam's packet, and Sam's new reply Z to X, all under B's ids.
  const packetB = read({ title: 'T', guid: 'g-1' }, {
    sender: 'Sam',
    margins: [
      { id: 'packet:B:x', episodeId: 'packet:B', atSeconds: 190, createdAt: '2026-10-30T00:00:00Z', text: 'X', author: 'Sam' },
      { id: 'packet:B:y', episodeId: 'packet:B', atSeconds: 200, createdAt: '2026-10-30T00:01:00Z', text: 'Y', author: 'Sam', replyToId: 'packet:B:x' },
      { id: 'packet:B:z', episodeId: 'packet:B', atSeconds: 230, createdAt: '2026-10-30T00:02:00Z', text: 'Z', author: 'Sam', replyToId: 'packet:B:x' },
    ],
  });
  const shown = previewMargins(packetB, [show], [mine], [storedX, storedY], unnamedAuthorFor('link'));
  // The ids are the ones the player will find in the store, so a start's queue plays them.
  assert.deepEqual(shown.map((m) => m.id), ['packet:A:x', 'mine-y', 'packet:B:z']);
  assert.equal(shown[0].heard, true, 'X was heard from packet A');
  assert.equal(shown[1].author, undefined, 'Y is the listener’s own, not Sam’s');
  // The new reply still hangs under X in the preview.
  assert.equal(shown[2].replyToId, 'packet:A:x');
  assert.equal(shown[2].heard, undefined);
});

test('a new reply to a Margin already stored is stored under the stored copy, not as an orphan (audit 2 on 53fc52e)', () => {
  // Sam's packet A brought X; packet B carries X again under its own id, with Sam's new reply Z to it.
  const storedX: Margin = { id: 'packet:A:x', episodeId: mine.id, atSeconds: 190, createdAt: '2026-10-30T00:00:00Z', text: 'X', author: 'Sam', heard: true };
  const packetB = read({ title: 'T', guid: 'g-1' }, {
    sender: 'Sam',
    margins: [
      { id: 'packet:B:x', episodeId: 'packet:B', atSeconds: 190, createdAt: '2026-10-30T00:00:00Z', text: 'X', author: 'Sam' },
      { id: 'packet:B:z', episodeId: 'packet:B', atSeconds: 230, createdAt: '2026-10-30T00:02:00Z', text: 'Z', author: 'Sam', replyToId: 'packet:B:x' },
    ],
  });
  const placed = placeImport(packetB, [show], [mine], undefined, [storedX], { unnamedAuthor: unnamedAuthorFor('link') });
  // X is a duplicate and isn't stored again; Z is, and it hangs under the X the store holds, as the preview showed it.
  assert.deepEqual(placed.margins.map((m) => [m.id, m.replyToId]), [['packet:B:z', 'packet:A:x']]);
  assert.deepEqual(placed.held.find((m) => m.id === 'packet:B:z')?.replyToId, 'packet:A:x');
});

const pct = (id: string, percent: number, extra: Partial<Margin> = {}): PercentMargin => ({
  percent,
  margin: { id: `packet:d:${id}`, episodeId: 'packet:d', atSeconds: 0, createdAt: '2026-11-16T00:00:00Z', text: id, ...extra },
});
const voice: Pick<Episode, 'id' | 'title' | 'durationSeconds'> = { id: 'post-1', title: 'A post', durationSeconds: 1200 };

test('a Margin on an article’s words goes where its percent of the voice reaches', () => {
  const margins = placeByPercent([pct('b', 50), pct('a', 25), pct('c', 0)], voice);
  assert.deepEqual(margins.map((m) => [m.text, m.atSeconds, m.episodeId]), [['c', 0, 'post-1'], ['a', 300, 'post-1'], ['b', 600, 'post-1']]);
});

test('a Margin at the very end, or a percent out of range, is kept inside the voice', () => {
  const margins = placeByPercent([pct('end', 100), pct('over', 140), pct('under', -5)], voice);
  assert.deepEqual(margins.map((m) => [m.text, m.atSeconds]), [['under', 0], ['end', 1199], ['over', 1199]]);
  const short = placeByPercent([pct('end', 100)], { ...voice, durationSeconds: 0.5 });
  assert.equal(short[0]?.atSeconds, 0);
});

test('with no usable length for the audio nothing is placed', () => {
  for (const durationSeconds of [undefined, 0, -3, Number.NaN, Number.POSITIVE_INFINITY]) {
    assert.deepEqual(placeByPercent([pct('a', 10), pct('b', 20)], { ...voice, durationSeconds }), [], String(durationSeconds));
  }
});

test('a Margin already here, at the same place with the same words, is not added again', () => {
  const first = placeByPercent([pct('a', 25), pct('b', 50)], voice);
  const again = placeByPercent([pct('a', 25), pct('b', 50), pct('c', 75)], voice, first);
  assert.deepEqual(again.map((m) => m.text), ['c']);
});

test('a voice clip and the sender’s other fields survive being placed', () => {
  const clip = { blob: new Blob([new Uint8Array([1])]), mimeType: 'audio/mp4', durationSeconds: 7 };
  const margins = placeByPercent([pct('v', 10, { voice: clip, author: 'Cole', replyToId: 'packet:x:1' })], voice);
  assert.equal(margins[0]?.voice, clip);
  assert.equal(margins[0]?.author, 'Cole');
  assert.equal(margins[0]?.replyToId, 'packet:x:1');
});

test('an opened packet keeps its article Margins to place later, aimed at its episode, signed by a friend with no name', () => {
  const packet = read({ title: 'A post', pageUrl: 'https://writer.substack.com/p/a-post' }, { margins: [], textMarginCount: 3, percentMargins: [pct('a', 10), pct('b', 20)] });
  const placed = placeImport(packet, [], [], undefined, [], { unnamedAuthor: UNNAMED_SENDER });
  assert.equal(placed.margins.length, 0);
  assert.equal(placed.skipped, 1, 'the one with no rough place has nowhere to go');
  assert.deepEqual(placed.pending.map((p) => [p.margin.text, p.percent, p.margin.episodeId, p.margin.author]), [
    ['a', 10, placed.episode.id, UNNAMED_SENDER],
    ['b', 20, placed.episode.id, UNNAMED_SENDER],
  ]);
  const own = placeImport(packet, [], [], undefined, [], {});
  assert.equal(own.pending[0]?.margin.author, undefined, 'a restored backup keeps its Margins unsigned');
});

test('a Margin file opens no voice, so its article Margins are still counted as unopened', () => {
  const packet = read({ title: 'A post', pageUrl: 'https://writer.substack.com/p/a-post' }, { margins: [], textMarginCount: 3, percentMargins: [pct('a', 10), pct('b', 20)] });
  const placed = placeImport(packet, [], []);
  assert.match(importSummary(placed, 'Cole'), /3 Margins are on the article’s words\. Open the file in Spoken Margins on iPhone to hear them in place\./);
  // The noun follows what the Margins sit on (#5265).
  assert.match(importSummary(placed, 'Cole', 'PDF'), /3 Margins are on the PDF’s words\./);
  assert.doesNotMatch(importSummary(placed, 'Cole', 'book'), /can’t/);
});

// #4783: a page-only Apple episode kept before its audio was known takes the audio the packet now carries.
const APPLE_PAGE = 'https://podcasts.apple.com/us/podcast/x/id1445582279?i=1000427709574';
const pageOnlyCopy: Episode = { id: 'shared:Cole#page', showId: 'shared:Cole', title: 'Episode', pageUrl: APPLE_PAGE };

test('a copy kept without audio takes the audio the packet carries, and is stored again', () => {
  const placed = placeImport(read({ title: 'Episode', pageUrl: APPLE_PAGE, audioUrl: 'https://media.example.com/a.mp3', audioOrigin: 'podcast-enclosure', durationSeconds: 1800 }), [], [pageOnlyCopy]);
  assert.equal(placed.episode.id, pageOnlyCopy.id, 'still the listener\'s own copy');
  assert.equal(placed.episode.audioUrl, 'https://media.example.com/a.mp3');
  assert.equal(placed.episode.audioOrigin, 'podcast-enclosure');
  assert.equal(placed.episode.durationSeconds, 1800);
  assert.equal(placed.newEpisode, true, 'the changed copy must be stored');
});

test('a copy that already has audio, or a packet with none, is left exactly as it was', () => {
  const withAudio = placeImport(read({ title: 'E', guid: 'g-1', audioUrl: 'https://media.example.com/other.mp3' }), [show], [mine]);
  assert.equal(withAudio.episode, mine);
  assert.equal(withAudio.newEpisode, false);
  const noAudio = placeImport(read({ title: 'Episode', pageUrl: APPLE_PAGE }), [], [pageOnlyCopy]);
  assert.equal(noAudio.episode, pageOnlyCopy);
  assert.equal(noAudio.newEpisode, false);
});

test('the copy keeps its own length when it has one', () => {
  const placed = placeImport(read({ title: 'Episode', pageUrl: APPLE_PAGE, audioUrl: 'https://media.example.com/a.mp3', durationSeconds: 1800 }), [], [{ ...pageOnlyCopy, durationSeconds: 1500 }]);
  assert.equal(placed.episode.durationSeconds, 1500);
});

test('two episodes of one Apple show are never the same page, however alike their addresses (audit on f88c1c7)', () => {
  const other = 'https://podcasts.apple.com/us/podcast/x/id1445582279?i=1000427709999';
  const table: Array<[string, string, boolean]> = [
    [APPLE_PAGE, other, false],
    [APPLE_PAGE, APPLE_PAGE, true],
    [APPLE_PAGE, 'https://podcasts.apple.com/us/podcast/x/id1445582279?i=1000427709574&utm_source=a', true],
    [APPLE_PAGE, 'https://itunes.apple.com/us/podcast/x/id1445582279?i=1000427709574', true],
    [APPLE_PAGE, 'https://podcasts.apple.com/us/podcast/x/id1445582279', false],
    ['https://podcasts.apple.com/us/podcast/id1445582279?i=1', 'https://podcasts.apple.com/us/podcast/id1445582279?i=2', false],
    ['https://podcasts.apple.com/us/podcast/id1445582279?i=1', 'https://podcasts.apple.com/gb/podcast/id1445582279?i=1', true],
  ];
  for (const [kept, opened, same] of table) {
    const copy: Episode = { ...pageOnlyCopy, pageUrl: kept };
    assert.equal(findEpisode(read({ title: 'Episode', pageUrl: opened }), [copy]) !== undefined, same, `${kept} vs ${opened}`);
  }
});

test('opening episode B never stores B’s audio on the kept episode A', () => {
  const other = 'https://podcasts.apple.com/us/podcast/x/id1445582279?i=1000427709999';
  const placed = placeImport(read({ title: 'Episode', pageUrl: other, audioUrl: 'https://media.example.com/b.mp3' }), [], [pageOnlyCopy]);
  assert.notEqual(placed.episode.id, pageOnlyCopy.id);
  assert.equal(placed.newEpisode, true);
  assert.equal(pageOnlyCopy.audioUrl, undefined);
});

test('a kept copy is filled only when it is the packet’s episode by identity, never by an address that names its item in a query', () => {
  const kept = (pageUrl: string, extra: Partial<Episode> = {}): Episode => ({ id: 'shared:Cole#x', showId: 'shared:Cole', title: 'Video', pageUrl, ...extra });
  const audio = 'https://media.example.com/b.mp3';
  // An address that names its item in the query: matched by page, but the audio is not copied across.
  const sibling = placeImport(read({ title: 'Video', pageUrl: 'https://example.com/watch?v=B', audioUrl: audio }), [], [kept('https://example.com/watch?v=A')]);
  assert.equal(sibling.episode.audioUrl, undefined);
  assert.equal(sibling.newEpisode, false);
  // The guid is identity: the same episode, so its audio is filled in.
  const byGuid = placeImport(read({ title: 'Video', guid: 'g-9', pageUrl: 'https://example.com/other', audioUrl: audio }), [], [kept('https://example.com/watch?v=A', { guid: 'g-9' })]);
  assert.equal(byGuid.episode.audioUrl, audio);
  assert.equal(byGuid.newEpisode, true);
  // The same Apple episode, whatever the padding of its id or the storefront: filled.
  const apple = placeImport(read({ title: 'Episode', pageUrl: 'https://podcasts.apple.com/gb/podcast/x/id1445582279?i=01000427709574', audioUrl: audio }), [], [pageOnlyCopy]);
  assert.equal(apple.episode.audioUrl, audio);
  assert.equal(apple.newEpisode, true);
});

// #4689: a reply written from an episode the web filed under "Shared by <sender>" named that holder as the show, and the
// iPhone, seeing another show beside the same guid, imported a second copy of the episode.
test('a reply to a friend’s packet names the show the friend’s packet named, never the "Shared by" holder', async () => {
  const parent = await appParent();
  assert.equal(parent.episode.showTitle, 'Example Show');
  const placed = placeImport(parent, [], [], 'T0', [], { unnamedAuthor: unnamedAuthorFor('link') });
  assert.ok(placed.show?.id.startsWith('shared:'));
  assert.equal(placed.show?.title, 'Shared by Ana');
  assert.equal(placed.episode.showTitle, 'Example Show');
  const reply: Margin = { id: 'r1', episodeId: placed.episode.id, atSeconds: 755, createdAt: '2026-10-30T12:00:00Z', text: 'A reply.', replyToId: placed.margins[0]?.id };
  const written = await writePacket(placed.episode, [reply], { show: packetShowFor(placed.show, placed.episode), sender: 'Ben' });
  const back = await readPacket(written.bytes);
  assert.equal(back.episode.showTitle, 'Example Show');
  assert.equal(back.episode.guid, parent.episode.guid);
});

test('an episode kept before its show title was, or from a packet that named only a holder, sends no show', async () => {
  const holder = sharedShowFor('Ana', 'T0');
  const kept: Episode = { id: 'shared:Ana#g', showId: holder.id, title: 'E', guid: 'g' };
  assert.equal(packetShowFor(holder, kept), undefined);
  assert.equal(packetShowFor(holder, { ...kept, showTitle: '   ' }), undefined);
  const written = await writePacket(kept, [{ id: 'm', episodeId: kept.id, atSeconds: 5, createdAt: '2026-10-30T12:00:00Z', text: 'Hi' }], { show: packetShowFor(holder, kept) });
  assert.equal((await readPacket(written.bytes)).episode.showTitle, undefined);
  // An older web build's reply named its holder; that title is not kept as the show.
  const fromOldReply = placeImport(read({ itemType: 'podcast', title: 'E', guid: 'g2', showTitle: 'Shared by Ana' } as PacketRead['episode']), [], [], 'T0');
  assert.equal(fromOldReply.episode.showTitle, undefined);
});

test('a followed show is the packet’s show as it is', () => {
  assert.equal(packetShowFor(show, mine), show);
  assert.equal(packetShowFor(undefined, mine), undefined);
});

test('holder titles are told from show titles', () => {
  for (const title of ['Shared by Ana', 'shared by ana', '  Shared  by   Ana ', 'Shared with you', 'SHARED WITH YOU', 'Shared by Zoë Ångström']) {
    assert.equal(isSharedHolderTitle(title), true, title);
  }
  for (const title of ['Shared by', 'Shared by ', 'Example Show', 'The Shared by Show', 'Shared Brains', '', 'Shared withyou']) {
    assert.equal(isSharedHolderTitle(title), false, title);
  }
});
