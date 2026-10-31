import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { PacketError } from './errors.ts';
import { episode, show, voiceMargins, writePlaceholder, writeVoice, writeWritten, writtenMargins } from './fixtures.ts';
import { packetMarginId, readPacket } from './read.ts';
import { conversationId, sharedWords, writePacket } from './write.ts';
import { voicePlaceholder } from '../shared/placeholder.ts';
import { listZip, readZip } from './zip.ts';

const fixtures = new URL('../../../Contracts/fixtures/web-packets/', import.meta.url);
const load = (name: string): Uint8Array => new Uint8Array(readFileSync(new URL(name, fixtures)));
const unlimited = { totalBytes: Infinity, compressionRatio: Infinity, entryBytes: () => Infinity };

test('the committed web fixtures are what the writer writes now', async () => {
  for (const [name, write] of [
    ['web-written.spokenmargins', writeWritten], ['web-voice.spokenmargins', writeVoice], ['web-voice-placeholder.spokenmargins', writePlaceholder],
  ] as const) {
    const committed = await readPacket(load(name));
    const fresh = await write();
    assert.equal(fresh.contentDigest, committed.contentDigest, `${name}: regenerate with node Web/src/packet/fixtures.ts`);
  }
});

test('a written-only packet round-trips through the reader', async () => {
  const written = await writeWritten();
  const read = await readPacket(written.bytes, { fileName: written.fileName, episodeId: episode.id });
  assert.equal(written.fileName, 'Episode-1-example-episode.spokenmargins');
  assert.deepEqual(read.margins.map((m) => [m.atSeconds, m.text, m.author]), [
    [65, 'A written Margin from the web, 1:05 in.', 'Web fixture'],
    [600.4, 'Another at ten minutes.', 'Web fixture'],
  ]);
  assert.equal(read.episode.guid, episode.guid);
  assert.equal(read.episode.audioUrl, episode.audioUrl);
  assert.equal(read.episode.pageUrl, episode.pageUrl);
  assert.equal(read.episode.showTitle, show.title);
  assert.equal(read.episode.durationSeconds, 1800);
  assert.equal(read.item.itemType, 'podcast');
});

test('the archive is laid out as the app writes it', async () => {
  const { bytes } = await writeVoice();
  const entries = listZip(bytes);
  assert.deepEqual(entries.map((e) => e.path), [
    'manifest.json', 'preview.md', 'artifacts/commentary-layer.json', 'assets/audio/margin-0002-original.m4a',
  ]);
  assert.deepEqual(entries.map((e) => e.method), [8, 8, 8, 0]);
  const files = await readZip(bytes, unlimited);
  const manifest = JSON.parse(new TextDecoder().decode(files.get('manifest.json')));
  assert.equal(manifest.itemTransport.kind, 'reference');
  assert.deepEqual(manifest.requiredCapabilities, ['spoken-margins.commentary-layer.v1']);
  assert.match(manifest.createdAt, /^2026-10-30T12:00:00\.000Z$/);
  const layer = JSON.parse(new TextDecoder().decode(files.get('artifacts/commentary-layer.json')));
  assert.deepEqual(layer.interjections[1].anchor, { anchorType: 'media', machineEvidenceAssetIds: [], mediaTimeMs: 125250, roughPercent: 6 });
  assert.equal(layer.interjections[1].createdAt, '2026-10-30T11:02:00Z');
});

test('a voice Margin travels as a plain AAC m4a with its length', async () => {
  const read = await readPacket((await writeVoice()).bytes);
  const voiced = read.margins.find((m) => m.voice);
  assert.ok(voiced?.voice);
  assert.equal(voiced.voice.mimeType, 'audio/mp4');
  assert.ok(Math.abs(voiced.voice.durationSeconds - 2.97) < 0.05, String(voiced.voice.durationSeconds));
  const m4a = new Uint8Array(await voiced.voice.blob.arrayBuffer());
  assert.equal(String.fromCharCode(...m4a.subarray(8, 12)), 'M4A ');
  assert.equal(voiced.text, 'This is a web Margin, recorded for the packet test.');
});

test('a voice Margin with no words travels with placeholder words in its transcript (#3025)', async () => {
  const [text, voice] = voiceMargins();
  for (const words of ['  ', undefined]) {
    const written = await writePacket(episode, [text, { ...voice, text: words }]);
    assert.deepEqual(written.included, [text.id, voice.id]);
    assert.deepEqual(written.leftOut, []);
    assert.equal(written.notice, undefined);
    const read = await readPacket(written.bytes);
    const voiced = read.margins.find((m) => m.voice);
    assert.ok(voiced?.voice, 'the voice audio travels');
    const expected = voicePlaceholder({ atSeconds: voice.atSeconds, title: episode.title, recordedAt: new Date(voice.createdAt) });
    assert.equal(voiced.text, expected);
    assert.match(expected, /^Voice Margin at 2:05 in “Episode 1 \(example episode\)”, recorded \d{1,2} Oct 2026$/);
  }
  // A packet of only that Margin is written too, rather than refused.
  const alone = await writePacket(episode, [{ ...voice, text: undefined }]);
  assert.deepEqual(alone.included, [voice.id]);
  // No new key: the record and its representation have the same keys as a voice Margin with its own words.
  const firstRecord = async (bytes: Uint8Array) => {
    const files = await readZip(bytes, unlimited);
    return JSON.parse(new TextDecoder().decode(files.get('artifacts/commentary-layer.json'))).interjections[0];
  };
  const keys = (record: Record<string, unknown>): string[] => Object.keys(record).sort();
  const own = await firstRecord((await writePacket(episode, [voice])).bytes);
  const placed = await firstRecord(alone.bytes);
  assert.deepEqual(keys(placed), keys(own));
  assert.deepEqual(keys(placed.representations[0]), keys(own.representations[0]));
  assert.equal(placed.representations[0].kind, 'original_audio_and_text');
});

test('a voice Margin keeps its own words over the placeholder', () => {
  const [, voice] = voiceMargins();
  assert.equal(sharedWords(voice, episode.title), 'This is a web Margin, recorded for the packet test.');
  assert.equal(sharedWords({ ...voice, text: '  Mine.  ' }, episode.title), 'Mine.');
  assert.equal(sharedWords({ ...writtenMargins()[0], text: ' ' }, episode.title), '', 'a written Margin gets no placeholder');
});

test('a written Margin with no words is still left out with the app notice', async () => {
  const [text] = voiceMargins();
  const empty = { ...writtenMargins()[0], id: 'empty', text: '  ' };
  const written = await writePacket(episode, [text, empty]);
  assert.deepEqual(written.included, [text.id]);
  assert.deepEqual(written.leftOut, ['empty']);
  assert.equal(written.notice, "1 Margin has no transcript and wasn't included.");
  await assert.rejects(writePacket(episode, [{ ...empty, text: undefined }]), (error: unknown) =>
    error instanceof PacketError && error.outcome === 'cannotShare');
});

test('Opus voice is never written', async () => {
  const opus = readFileSync(new URL('audio/voice-opus.mp4', fixtures));
  const margin = { ...writtenMargins()[0], voice: { blob: new Blob([opus]), mimeType: 'audio/mp4', durationSeconds: 1 } };
  await assert.rejects(writePacket(episode, [margin]), (error: unknown) => error instanceof PacketError && error.outcome === 'cannotShare');
});

test('without a public link the item travels as recipient-supplied', async () => {
  const privateEpisode = { ...episode, pageUrl: undefined, audioUrl: 'https://www.patreon.com/file?h=1&i=2' };
  const read = await readPacket((await writePacket(privateEpisode, writtenMargins())).bytes);
  assert.equal(read.item.canonicalURL, undefined);
  assert.equal(read.item.enclosureURL, undefined);
  assert.equal(read.episode.guid, episode.guid);
});

test('a reply to an imported Margin carries its link, which reads back', async () => {
  const parent = await readPacket(load('web-written.spokenmargins'));
  const parentId = parent.margins[0].id;
  const reply = { ...writtenMargins()[1], id: 'r1', replyToId: parentId };
  const read = await readPacket((await writePacket(episode, [writtenMargins()[0], reply])).bytes);
  assert.equal(read.margins[1].replyToId, parentId);
  assert.equal(read.margins[0].replyToId, undefined);
  assert.equal(parentId, packetMarginId(parent.contentDigest, 'margin-0001'));
});

test('a reply to a reply stays in the conversation of its parent (Build 34 reply packet)', async () => {
  const bytes = new Uint8Array(readFileSync(new URL('../../../Packages/SessionKit/Tests/SessionKitTests/Fixtures/build34-reply-packet.spokenmargins', import.meta.url)));
  const parent = await readPacket(bytes);
  const [parentId, thread] = Object.entries(parent.conversationIds)[0];
  const reply = { ...writtenMargins()[0], replyToId: parentId };
  const written = await writePacket(episode, [reply], { conversationIds: parent.conversationIds });
  const files = await readZip(written.bytes, unlimited);
  const conversation = JSON.parse(new TextDecoder().decode(files.get('artifacts/margin-conversation.json')));
  assert.equal(conversation.replies[0].conversationId, thread);
});

test('a reply to a Margin that starts a conversation gets the id the app derives', async () => {
  // MarginConversation.swift conversationId(rootedAt:), worked by hand with shasum for "<64 zeros>\nmargin-0001".
  const digest = '0'.repeat(64);
  assert.equal(await conversationId(digest, 'margin-0001'), 'conversation-d6f8e22049d6b209862922cb12c73972');
});

test('more than 50 Margins is refused', async () => {
  const many = Array.from({ length: 51 }, (_, i) => ({ ...writtenMargins()[0], id: `m${i}`, atSeconds: i }));
  await assert.rejects(writePacket(episode, many), (error: unknown) => error instanceof PacketError && error.outcome === 'cannotShare');
});
