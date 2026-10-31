import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { test } from 'node:test';

import { NotAacError, audioSpecificConfig, audioSpecificConfigFromDescription, demuxAac, durationMs, muxM4a, normalizeM4a, parseAdts } from './m4a.ts';

// voice.adts.aac: `say` then `afconvert -f adts -d aac` (1 channel, 22050 Hz, about 2.79 s by afinfo).
// voice-apple.m4a: the same speech through `afconvert -f m4af`, what the iPhone app's recorder writes.
// voice-fragmented.mp4: voice-apple.m4a's frames copied into a fragmented MP4 (ffmpeg, empty_moov, six
// moofs), the shape Chrome's MediaRecorder writes. voice-opus.mp4: Opus in MP4, which a packet must never carry.
const audio = new URL('../../../Contracts/fixtures/web-packets/audio/', import.meta.url);
const load = (name: string): Uint8Array => new Uint8Array(readFileSync(new URL(name, audio)));

test('ADTS frames mux into an m4a that reads back frame for frame', () => {
  const adts = parseAdts(load('voice.adts.aac'));
  assert.equal(adts.sampleRate, 22050);
  assert.equal(adts.channels, 1);
  const m4a = muxM4a(adts);
  assert.equal(String.fromCharCode(...m4a.subarray(4, 8)), 'ftyp');
  assert.equal(String.fromCharCode(...m4a.subarray(8, 12)), 'M4A ');
  const back = demuxAac(m4a);
  assert.deepEqual(back.audioSpecificConfig, adts.audioSpecificConfig);
  assert.equal(back.frames.length, adts.frames.length);
  assert.deepEqual(back.frames.at(-1), adts.frames.at(-1));
  assert.equal(durationMs(back), durationMs(adts));
  // afinfo estimates 2.786 s of speech; the frames also hold the encoder's priming and padding (under 4 frames).
  assert.ok(durationMs(back) >= 2786 && durationMs(back) - 2786 < (4 * 1024) / 22.05, String(durationMs(back)));
  if (process.env.SM_WRITE_M4A) writeFileSync(process.env.SM_WRITE_M4A, m4a);
});

test('an Apple-written m4a demuxes and re-muxes with the same frames', () => {
  const apple = demuxAac(load('voice-apple.m4a'));
  assert.equal(apple.channels, 1);
  const again = demuxAac(muxM4a(apple));
  assert.equal(again.frames.length, apple.frames.length);
  assert.deepEqual(again.frames[3], apple.frames[3]);
  assert.equal(durationMs(again), durationMs(apple));
});

test('a fragmented MP4 (Chrome MediaRecorder shape) normalizes to a plain m4a', () => {
  const fragmented = demuxAac(load('voice-fragmented.mp4'));
  const apple = demuxAac(load('voice-apple.m4a'));
  assert.equal(fragmented.frames.length, apple.frames.length);
  assert.deepEqual(fragmented.frames[10], apple.frames[10]);
  assert.deepEqual(fragmented.frames.at(-1), apple.frames.at(-1));
  const { bytes, durationMs: ms } = normalizeM4a(load('voice-fragmented.mp4'));
  assert.ok(findBox(load('voice-fragmented.mp4'), 'moof'));
  assert.ok(!findBox(bytes, 'moof'));
  assert.ok(Math.abs(ms - durationMs(apple)) <= 25, `${ms} vs ${durationMs(apple)}`);
});

test('Opus in MP4 is refused: packets carry AAC only', () => {
  assert.throws(() => normalizeM4a(load('voice-opus.mp4')), NotAacError);
});

test('non-MP4 bytes are refused', () => {
  assert.throws(() => demuxAac(new TextEncoder().encode('not audio at all')), NotAacError);
  assert.throws(() => demuxAac(load('voice.adts.aac')), NotAacError);
});

test('AudioSpecificConfig for AAC-LC 48 kHz stereo is 0x1190', () => {
  assert.deepEqual([...audioSpecificConfig(48000, 2)], [0x11, 0x90]);
  assert.deepEqual([...audioSpecificConfig(44100, 1)], [0x12, 0x08]);
  assert.throws(() => audioSpecificConfig(12345, 1), RangeError);
});

// WebCodecs AudioEncoder `decoderConfig.description` for AAC-LC, 48 kHz mono, captured on the Mac on 2026-10-30.
const hex = (text: string): Uint8Array => new Uint8Array(text.split(' ').map((b) => parseInt(b, 16)));
const CHROME_DESCRIPTION = hex('11 88'); // Chrome 156: the bare AudioSpecificConfig.
const WEBKIT_DESCRIPTION = hex( // Playwright WebKit 27.2 (revision 2370): an MPEG-4 ES_Descriptor, 39 bytes.
  '03 80 80 80 22 00 00 00 04 80 80 80 14 40 14 00 18 00 00 00 00 00 00 00 00 00 05 80 80 80 02 11 88 06 80 80 80 01 02');

test('an encoder description gives the AudioSpecificConfig in Chrome\'s bare form and WebKit\'s ES_Descriptor form', () => {
  assert.equal(WEBKIT_DESCRIPTION.length, 39);
  const rows: [string, Uint8Array][] = [
    ['Chrome: bare AudioSpecificConfig', CHROME_DESCRIPTION],
    ['WebKit: ES_Descriptor (tag 0x03) with four-byte lengths', WEBKIT_DESCRIPTION],
    ['ES_Descriptor with one-byte lengths', hex('03 19 00 00 00 04 11 40 14 00 18 00 00 00 00 00 00 00 00 00 05 02 11 88 06 01 02')],
    ['a whole esds box', concatBytes(hex('00 00 00 33'), new TextEncoder().encode('esds'), hex('00 00 00 00'), WEBKIT_DESCRIPTION)],
    ['DecoderConfigDescriptor alone (tag 0x04)', WEBKIT_DESCRIPTION.subarray(8, 33)],
    ['DecoderSpecificInfo alone (tag 0x05)', WEBKIT_DESCRIPTION.subarray(26, 33)],
  ];
  for (const [name, description] of rows) assert.deepEqual([...audioSpecificConfigFromDescription(description)], [0x11, 0x88], name);
  // The 48 kHz mono config the muxer would write for itself matches what both browsers describe.
  assert.deepEqual([...audioSpecificConfig(48000, 1)], [0x11, 0x88]);
});

test('an encoder description that isn\'t AAC, or is cut short, is refused', () => {
  const rows: [string, Uint8Array][] = [
    ['empty', new Uint8Array()],
    ['one byte', hex('11')],
    ['audio object type 0 (what reading WebKit\'s descriptor as a config gave)', hex('00 88')],
    ['ES_Descriptor cut inside its config', WEBKIT_DESCRIPTION.subarray(0, 31)],
    ['ES_Descriptor around MP3 (object type 0x6b)', hex('03 19 00 00 00 04 11 6b 14 00 18 00 00 00 00 00 00 00 00 00 05 02 11 88 06 01 02')],
    ['ES_Descriptor around Opus-looking config (AOT 31)', hex('03 19 00 00 00 04 11 40 14 00 18 00 00 00 00 00 00 00 00 00 05 02 f8 88 06 01 02')],
  ];
  for (const [name, description] of rows) assert.throws(() => audioSpecificConfigFromDescription(description), NotAacError, name);
});

function concatBytes(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

function findBox(bytes: Uint8Array, type: string): boolean {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  for (let at = 0; at + 8 <= bytes.length; ) {
    const size = view.getUint32(at);
    if (String.fromCharCode(...bytes.subarray(at + 4, at + 8)) === type) return true;
    if (size < 8) return false;
    at += size;
  }
  return false;
}
