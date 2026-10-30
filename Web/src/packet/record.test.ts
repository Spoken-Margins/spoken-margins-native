import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { demuxAac, muxM4a, parseAdts } from './m4a.ts';
import { AAC_RECORDER_TYPE, AacFrameCollector, MP4_RECORDER_TYPE, RecordingUnavailableError, chooseRecordingPath, recordVoiceMargin } from './record.ts';

const recorder = (...types: string[]) => (type: string): boolean => types.includes(type);

test('the recording path: AAC MediaRecorder, then WebCodecs AAC, then plain MP4, else none', async () => {
  const rows: [string, Parameters<typeof chooseRecordingPath>[0], string][] = [
    ['Safari: MediaRecorder says AAC in MP4', { recorderSupports: recorder(AAC_RECORDER_TYPE, MP4_RECORDER_TYPE) }, 'media-recorder-aac'],
    ['Chrome with AAC in its MP4 muxer', { recorderSupports: recorder(AAC_RECORDER_TYPE, MP4_RECORDER_TYPE), encoderSupports: async () => true }, 'media-recorder-aac'],
    ['Chrome: MP4 is Opus, AudioEncoder has AAC', { recorderSupports: recorder(MP4_RECORDER_TYPE), encoderSupports: async () => true }, 'webcodecs-aac'],
    ['WebCodecs only', { encoderSupports: async () => true }, 'webcodecs-aac'],
    ['plain MP4 only: tried, output checked', { recorderSupports: recorder(MP4_RECORDER_TYPE), encoderSupports: async () => false }, 'media-recorder-mp4'],
    ['Chromium without proprietary codecs: WebM only', { recorderSupports: recorder('audio/webm'), encoderSupports: async () => false }, 'unsupported'],
    ['nothing at all', {}, 'unsupported'],
  ];
  for (const [name, env, expected] of rows) assert.equal(await chooseRecordingPath(env), expected, name);
});

test('no AAC path refuses plainly before asking for the microphone', async () => {
  await assert.rejects(recordVoiceMargin({ environment: {} }), RecordingUnavailableError);
});

test('WebCodecs chunks gather into a track the muxer writes as AAC m4a', () => {
  const adts = parseAdts(new Uint8Array(readFileSync(new URL('../../../Contracts/fixtures/web-packets/audio/voice.adts.aac', import.meta.url))));
  const collector = new AacFrameCollector(adts.sampleRate, adts.channels);
  adts.frames.forEach((frame, i) => collector.add(
    { byteLength: frame.length, copyTo: (d: Uint8Array) => d.set(frame) },
    i === 0 ? { decoderConfig: { description: adts.audioSpecificConfig.slice().buffer } } : undefined,
  ));
  const track = collector.track();
  assert.deepEqual(track.audioSpecificConfig, adts.audioSpecificConfig);
  assert.equal(track.frames.length, adts.frames.length);
});

test('WebKit\'s ES_Descriptor description gives the same track as Chrome\'s bare config', () => {
  const adts = parseAdts(new Uint8Array(readFileSync(new URL('../../../Contracts/fixtures/web-packets/audio/voice.adts.aac', import.meta.url))));
  // voice.adts.aac is 22050 Hz mono: config 13 88. WebKit wraps it as an ES_Descriptor, here as a typed-array view.
  const asc = adts.audioSpecificConfig;
  const wrapped = new Uint8Array([0xaa, 0x03, 0x80, 0x80, 0x80, 0x22, 0, 0, 0, 0x04, 0x80, 0x80, 0x80, 0x14, 0x40, 0x14, 0, 0x18, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0x05, 0x80, 0x80, 0x80, 0x02, asc[0], asc[1], 0x06, 0x80, 0x80, 0x80, 0x01, 0x02]);
  const collector = new AacFrameCollector(adts.sampleRate, adts.channels);
  adts.frames.forEach((frame, i) => collector.add(
    { byteLength: frame.length, copyTo: (d: Uint8Array) => d.set(frame) },
    i === 0 ? { decoderConfig: { description: wrapped.subarray(1) } } : undefined,
  ));
  const track = collector.track();
  assert.deepEqual(track.audioSpecificConfig, asc);
  const back = demuxAac(muxM4a(track));
  assert.deepEqual(back.audioSpecificConfig, asc);
  assert.equal(back.frames.length, adts.frames.length);
});

test('a collector the encoder never described is not AAC', () => {
  const collector = new AacFrameCollector(48000, 1);
  collector.add({ byteLength: 1, copyTo: (d: Uint8Array) => d.set([0]) });
  assert.throws(() => collector.track(), /AudioSpecificConfig/);
  assert.equal(typeof demuxAac, 'function');
});
