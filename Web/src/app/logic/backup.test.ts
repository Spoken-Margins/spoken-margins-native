import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PacketError } from '../../packet/errors.ts';
import { episode, show, writtenMargins } from '../../packet/fixtures.ts';
import { readPacket } from '../../packet/read.ts';
import { writePacket } from '../../packet/write.ts';
import { listZip, writeZip } from '../../packet/zip.ts';
import type { Episode, Margin } from '../../shared/model.ts';
import { voicePlaceholder } from '../../shared/placeholder.ts';
import { backupSummary, buildBackup, isBackupArchive, MARGINS_PER_PACKET, packetsInBackup, uniqueName, type WritePacket } from './backup.ts';

const fixtures = new URL('../../../../Contracts/fixtures/web-packets/', import.meta.url);

/** The real writer, pinned the way the committed fixtures were written, so digests compare. */
const write: WritePacket = async (ep, margins, sh) => {
  const written = await writePacket(ep, margins, {
    ...(sh && { show: sh }),
    sender: 'Web fixture',
    packageId: 'package-web-fixture-written',
    createdAt: new Date('2026-10-30T12:00:00.000Z'),
  });
  return { bytes: written.bytes, fileName: written.fileName, mimeType: written.mimeType, included: written.included, ...(written.notice && { notice: written.notice }) };
};

const second: Episode = { ...episode, id: 'episode-two', title: 'Episode 2', guid: 'example-episode-guid-2', audioUrl: 'https://example.com/podcast/episode-2.mp3' };
const recorded = readFileSync(new URL('audio/voice-fragmented.mp4', fixtures));
/** A voice Margin with no words: real AAC, as every web recording is. */
const voiceOnly = (id: string, episodeId: string, at: number): Margin => ({
  id, episodeId, atSeconds: at, createdAt: '2026-10-30T11:00:00Z',
  voice: { blob: new Blob([recorded], { type: 'audio/mp4' }), mimeType: 'audio/mp4', durationSeconds: 2.9 },
});
const describe = (error: unknown) => (error instanceof Error ? error.message : String(error));

test('one episode backs up as the very packet the iPhone app’s import test reads', async () => {
  const result = await buildBackup({ episodes: [episode], shows: [show], margins: writtenMargins() }, write);
  assert.equal(result.file?.name, 'Episode-1-example-episode.spokenmargins');
  assert.equal(result.file?.mimeType, 'application/vnd.spokenmargins.package+zip');
  // web-written.spokenmargins is what SessionKit's WebPacketImportTests opens through the app's reader, the
  // check that Builds 32 and 34 import web packets. Same content digest: the same packet.
  const committed = await readPacket(new Uint8Array(readFileSync(new URL('web-written.spokenmargins', fixtures))));
  const backedUp = await readPacket(result.file!.bytes);
  assert.equal(backedUp.contentDigest, committed.contentDigest);
  assert.deepEqual(backupSummary(result, describe), { text: 'Backed up 2 Margins from 1 episode as Episode-1-example-episode.spokenmargins.', problem: false });
});

test('several episodes, a voice Margin with no words and a long episode go in one zip, nothing dropped', async () => {
  const many: Margin[] = Array.from({ length: MARGINS_PER_PACKET + 3 }, (_, i) => ({
    id: `n${i}`, episodeId: second.id, atSeconds: i * 10, createdAt: '2026-10-30T11:00:00Z', text: `Margin ${i}`,
  }));
  const margins = [...writtenMargins(), voiceOnly('v-a', episode.id, 75), ...many];
  const result = await buildBackup({ episodes: [episode, second], shows: [show], margins }, write, new Date(2026, 9, 30, 21, 5));
  assert.equal(result.file?.name, 'Spoken-Margins-backup-2026-10-30.zip');
  assert.equal(result.file?.mimeType, 'application/zip');
  assert.deepEqual(listZip(result.file!.bytes).map((e) => e.path), [
    'Episode-1-example-episode.spokenmargins',
    'Episode-2.spokenmargins',
    'Episode-2-2.spokenmargins',
  ]);
  assert.equal(result.inPackets, 3 + MARGINS_PER_PACKET + 3);
  assert.equal(result.episodes, 2);

  // Every packet in it opens, and between them they hold every Margin once, the voice one with placeholder words.
  const packets = await packetsInBackup(result.file!.bytes);
  assert.deepEqual(packets.map((p) => p.name), ['Episode-1-example-episode.spokenmargins', 'Episode-2.spokenmargins', 'Episode-2-2.spokenmargins']);
  const texts: string[] = [];
  for (const packet of packets) texts.push(...(await readPacket(packet.bytes)).margins.map((m) => m.text ?? ''));
  assert.equal(texts.length, result.inPackets);
  assert.equal(new Set(texts).size, texts.length);
  assert.ok(texts.includes(voicePlaceholder({ atSeconds: 75, title: episode.title, recordedAt: new Date('2026-10-30T11:00:00Z') })));

  assert.deepEqual(backupSummary(result, describe), {
    text: 'Backed up 56 Margins from 2 episodes as Spoken-Margins-backup-2026-10-30.zip.',
    problem: false,
  });
});

test('a packet that can’t be written, or a Margin with no episode, is named as not backed up', async () => {
  const failing: WritePacket = async (ep, ms, sh) => {
    if (ep.id === second.id) throw new PacketError('cannotShare', 'title', 'This episode’s title is too long to share.');
    return write(ep, ms, sh);
  };
  const orphan: Margin = { id: 'o', episodeId: 'gone', atSeconds: 1, createdAt: 'T', text: 'Orphan' };
  const margins = [...writtenMargins(), { id: 's', episodeId: second.id, atSeconds: 5, createdAt: 'T', text: 'On two' }, orphan];
  const result = await buildBackup({ episodes: [episode, second], shows: [show], margins }, failing);
  assert.equal(result.inPackets, 2);
  assert.equal(result.unplaced, 1);
  assert.deepEqual(result.failed.map((f) => [f.title, f.margins]), [['Episode 2', 1]]);
  const summary = backupSummary(result, describe);
  assert.equal(summary.problem, true);
  assert.match(summary.text, /1 Margin on “Episode 2” couldn’t be backed up\. This episode’s title is too long to share\./);
  assert.match(summary.text, /1 Margin isn’t linked to an episode in this browser, so it wasn’t backed up\./);
});

test('a Margin the writer leaves out of its packet is counted as not backed up', async () => {
  // The writer trims by Swift's rules; a margin of only a zero-width space passes JavaScript's trim but not Swift's.
  const dropping: WritePacket = async (ep, ms, sh) => {
    const written = await write(ep, ms.slice(0, 1), sh);
    return { ...written, notice: '1 Margin has no transcript and wasn’t included.' };
  };
  const result = await buildBackup({ episodes: [episode], shows: [show], margins: writtenMargins() }, dropping);
  assert.deepEqual(result.failed.map((f) => [f.title, f.margins]), [[episode.title, 1]]);
  assert.equal(backupSummary(result, describe).problem, true);
});

test('nothing to back up says so; voice Margins without words back up as a packet the apps open', async () => {
  const none = await buildBackup({ episodes: [episode], shows: [show], margins: [] }, write);
  assert.equal(none.file, undefined);
  assert.deepEqual(backupSummary(none, describe), { text: 'Nothing was backed up.', problem: true });
  const voices = await buildBackup({ episodes: [episode], shows: [], margins: [voiceOnly('a', episode.id, 3), voiceOnly('b', episode.id, 3)] }, write);
  assert.equal(voices.file?.name, 'Episode-1-example-episode.spokenmargins');
  assert.equal(voices.inPackets, 2);
  assert.deepEqual(voices.failed, []);
  const read = await readPacket(voices.file!.bytes);
  assert.equal(read.margins.length, 2);
  assert.ok(read.margins.every((m) => m.voice && m.text?.startsWith('Voice Margin at 0:03 in “Episode 1 (example episode)”, recorded ')));
  assert.deepEqual(backupSummary(voices, describe), { text: 'Backed up 2 Margins from 1 episode as Episode-1-example-episode.spokenmargins.', problem: false });
});

test('an older backup’s loose voice audio is skipped when reading it', async () => {
  const packet = (await write(episode, writtenMargins(), show)).bytes;
  const zip = await writeZip([
    { path: 'Episode-1-example-episode.spokenmargins', data: packet, deflate: false },
    { path: 'Voice Margins without words/Episode-1-example-episode at 1-15.m4a', data: new Uint8Array(recorded), deflate: false },
  ]);
  assert.deepEqual((await packetsInBackup(zip)).map((p) => p.name), ['Episode-1-example-episode.spokenmargins']);
});

test('names stay unique without regard to case, and only .zip files are read as backups', () => {
  const taken = new Set<string>();
  assert.equal(uniqueName('A.spokenmargins', taken), 'A.spokenmargins');
  assert.equal(uniqueName('a.SPOKENMARGINS', taken), 'a-2.SPOKENMARGINS');
  assert.equal(uniqueName('A.spokenmargins', taken), 'A-3.spokenmargins');
  assert.equal(uniqueName('noext', taken), 'noext');
  assert.equal(uniqueName('noext', taken), 'noext-2');
  assert.equal(isBackupArchive('Spoken-Margins-backup-2026-10-30.ZIP'), true);
  assert.equal(isBackupArchive('Episode.spokenmargins'), false);
  assert.equal(isBackupArchive(undefined), false);
});
