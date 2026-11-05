import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { test } from 'node:test';

import { PACKET_MESSAGES, PacketError } from './errors.ts';
import { contentDigest } from './format.ts';
import { voiceMargins, writeVoice, writeWritten } from './fixtures.ts';
import { readPacket } from './read.ts';
import { listZip, readZip, writeZip } from './zip.ts';

const root = new URL('../../../', import.meta.url);
const examples = new URL('Contracts/examples/packets/', root);
const kit = new URL('docs/sharing-test-kit/packets/', root);
const load = (url: URL): Uint8Array => new Uint8Array(readFileSync(url));

const expectations = JSON.parse(readFileSync(new URL('expectations.json', examples), 'utf8')).packets as Record<string, { swift: string }>;

for (const [name, expected] of Object.entries(expectations)) {
  const imports = expected.swift.startsWith('imports');
  test(`${name}: ${imports ? 'imports' : 'refused'}, as the app does`, async () => {
    const reading = readPacket(load(new URL(name, examples)), { fileName: name });
    if (imports) {
      const result = await reading;
      assert.ok(result.margins.length + result.textMargins.length > 0);
    } else {
      await assert.rejects(reading, (error: unknown) => {
        assert.ok(error instanceof PacketError, String(error));
        assert.equal(error.message, PACKET_MESSAGES[error.outcome]);
        return true;
      });
    }
  });
}

test('every example packet is listed in expectations.json', () => {
  const files = readdirSync(examples).filter((f) => f.endsWith('.spokenmargins'));
  assert.deepEqual(files.sort(), Object.keys(expectations).sort());
});

test('the app-made podcast packet reads into timed Margins and its episode', async () => {
  const result = await readPacket(load(new URL('podcast-reference.spokenmargins', examples)));
  assert.equal(result.episode.itemType, 'podcast');
  assert.ok(result.episode.title);
  assert.ok(result.margins.length > 0);
  for (const margin of result.margins) {
    assert.equal(margin.episodeId, `packet:${result.contentDigest}`);
    assert.ok(margin.atSeconds >= 0);
    assert.match(margin.id, /^packet:[0-9a-f]{64}:/);
  }
  assert.equal(result.textMargins.length, 0);
});

test('the app-made article packet reads into text Margins', async () => {
  const result = await readPacket(load(new URL('article-reference.spokenmargins', examples)), { episodeId: 'mine' });
  assert.equal(result.margins.length, 0);
  assert.ok(result.textMargins.length > 0);
  assert.ok(result.textMargins.every((m) => m.text.length > 0));
});

for (const name of readdirSync(kit).filter((f) => f.endsWith('.spokenmargins'))) {
  test(`sharing test kit ${name} imports`, async () => {
    const result = await readPacket(load(new URL(name, kit)));
    if (result.item.itemType === 'podcast') {
      assert.ok(result.margins.length > 0);
      const voiced = result.margins.filter((m) => m.voice);
      for (const margin of voiced) {
        assert.equal(margin.voice?.mimeType, 'audio/mp4');
        assert.ok((margin.voice?.durationSeconds ?? 0) > 0);
      }
    } else {
      assert.ok(result.textMargins.length > 0);
    }
  });
}

test('the Build 34 reply packet reads its reply link', async () => {
  const bytes = load(new URL('Packages/SessionKit/Tests/SessionKitTests/Fixtures/build34-reply-packet.spokenmargins', root));
  const result = await readPacket(bytes);
  const all = [...result.margins, ...result.textMargins];
  assert.ok(all.some((m) => m.replyToId?.startsWith('packet:')));
});

// --- damaged inputs: each refused with one plain message --------------------------------------------------------

async function refusedAs(promise: Promise<unknown>, outcome: string): Promise<void> {
  await assert.rejects(promise, (error: unknown) => {
    assert.ok(error instanceof PacketError, String(error));
    assert.equal(error.outcome, outcome, error.detail);
    assert.equal(error.message, PACKET_MESSAGES[error.outcome as keyof typeof PACKET_MESSAGES]);
    return true;
  });
}

const podcast = (): Uint8Array => load(new URL('podcast-reference.spokenmargins', examples));

test('a truncated zip is damaged', async () => {
  const bytes = podcast();
  await refusedAs(readPacket(bytes.subarray(0, Math.floor(bytes.length / 2))), 'damaged');
});

test('a file with the wrong extension is not a packet', async () => {
  await refusedAs(readPacket(podcast(), { fileName: 'margins.zip' }), 'notAPacket');
  await refusedAs(readPacket(podcast(), { fileName: 'margins.spokenmargins.txt' }), 'notAPacket');
});

test('something that is not a zip is not a packet', async () => {
  await refusedAs(readPacket(new TextEncoder().encode('hello')), 'notAPacket');
});

async function rezip(bytes: Uint8Array, change: (entries: Map<string, Uint8Array>) => void): Promise<Uint8Array> {
  const entries = await readZip(bytes, { totalBytes: Infinity, compressionRatio: Infinity, entryBytes: () => Infinity });
  change(entries);
  return writeZip([...entries].map(([path, data]) => ({ path, data, deflate: !path.startsWith('assets/') })));
}

test('an entry that climbs out of the packet is refused', async () => {
  const bytes = await rezip(podcast(), (entries) => entries.set('../outside.json', new TextEncoder().encode('{}')));
  assert.ok(listZip(bytes).some((e) => e.path === '../outside.json'));
  await refusedAs(readPacket(bytes), 'damaged');
  const absolute = await rezip(podcast(), (entries) => entries.set('/etc/passwd', new Uint8Array([1])));
  await refusedAs(readPacket(absolute), 'damaged');
});

test('an oversized voice asset is too large', async () => {
  const big = new Uint8Array(20 * 1024 * 1024 + 1);
  const bytes = await rezip(podcast(), (entries) => entries.set('assets/audio/huge.m4a', big));
  await refusedAs(readPacket(bytes), 'tooLarge');
});

test('a zip bomb is refused before it inflates', async () => {
  const bomb = new Uint8Array(4 * 1024 * 1024);
  const bytes = await writeZip([{ path: 'artifacts/bomb.json', data: bomb, deflate: true }], Infinity);
  await refusedAs(readPacket(bytes), 'damaged');
});

test('an undeclared extra entry is refused', async () => {
  const bytes = await rezip(podcast(), (entries) => entries.set('artifacts/extra.json', new TextEncoder().encode('{}')));
  await refusedAs(readPacket(bytes), 'damaged');
});

/** Re-signs a packet after `change` edits its commentary layer, the way the iPhone app would write a `readAloud` key. */
async function withLayer(bytes: Uint8Array, change: (interjections: Record<string, unknown>[]) => void): Promise<Uint8Array> {
  return rezipSigned(bytes, (entries) => {
    const layer = JSON.parse(new TextDecoder().decode(entries.get('artifacts/commentary-layer.json')));
    change(layer.interjections);
    entries.set('artifacts/commentary-layer.json', new TextEncoder().encode(JSON.stringify(layer)));
  });
}

async function rezipSigned(bytes: Uint8Array, change: (entries: Map<string, Uint8Array>) => void): Promise<Uint8Array> {
  const entries = await readZip(bytes, { totalBytes: Infinity, compressionRatio: Infinity, entryBytes: () => Infinity });
  change(entries);
  const manifest = JSON.parse(new TextDecoder().decode(entries.get('manifest.json')));
  // The descriptor of every artifact states its size and hash; the reader checks both.
  for (const d of manifest.artifacts as { path: string; byteCount: number; sha256: string }[]) {
    const body = entries.get(d.path) as Uint8Array;
    d.byteCount = body.length;
    d.sha256 = createHash('sha256').update(body).digest('hex');
  }
  const files = new Map<string, Uint8Array>(
    [...manifest.artifacts, ...manifest.assets].map((d: { path: string }) => [d.path, entries.get(d.path) as Uint8Array] as const),
  );
  manifest.contentDigest = await contentDigest(manifest, entries.get('preview.md') as Uint8Array, files);
  entries.set('manifest.json', new TextEncoder().encode(JSON.stringify(manifest)));
  return writeZip([...entries].map(([path, data]) => ({ path, data, deflate: !path.startsWith('assets/') })));
}

test('a written Margin the sender asked not to be read aloud carries that into the web model (#3445)', async () => {
  const bytes = await writeWritten().then((w) => w.bytes);
  const edited = await withLayer(bytes, (records) => { records[0].readAloud = false; });
  const result = await readPacket(edited);
  assert.equal(result.margins.length, 2);
  assert.equal(result.margins[0].readAloud, false);
  assert.equal(result.margins[1].readAloud, undefined, 'a Margin without the key is read aloud as before');
  assert.ok(result.margins[0].text, 'the words still come through');
});

test('readAloud true, or a value that is not false, leaves a Margin read aloud (#3445)', async () => {
  const bytes = await writeWritten().then((w) => w.bytes);
  for (const value of [true, 'false', 0, null]) {
    const edited = await withLayer(bytes, (records) => { records[0].readAloud = value; });
    const result = await readPacket(edited);
    assert.equal(result.margins[0].readAloud, undefined, `readAloud ${JSON.stringify(value)}`);
  }
});

test('readAloud false on a voice Margin is ignored: the sender\'s own voice still plays (#3445)', async () => {
  const bytes = await writeVoice().then((w) => w.bytes);
  const edited = await withLayer(bytes, (records) => { for (const r of records) r.readAloud = false; });
  const result = await readPacket(edited);
  const voices = result.margins.filter((m) => m.voice);
  assert.ok(voices.length > 0 && voiceMargins().length > 0);
  assert.ok(voices.every((m) => m.readAloud === undefined));
});
