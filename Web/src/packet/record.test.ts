import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { demuxAac, muxM4a, parseAdts } from './m4a.ts';
import { AAC_RECORDER_TYPE, AacFrameCollector, MP4_RECORDER_TYPE, RecordingUnavailableError, chooseRecordingPath, recordVoiceMargin, waitForAudioFlow } from './record.ts';

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

// --- microphone warm-up --------------------------------------------------------------------------------------------

class FakeNode {
  connected: unknown[] = [];
  disconnected = 0;
  connect(destination: unknown): unknown {
    this.connected.push(destination);
    return destination;
  }
  disconnect(): void {
    this.disconnected += 1;
  }
}
class FakeProcessor extends FakeNode {
  onaudioprocess: ((event: { inputBuffer: { getChannelData(channel: number): Float32Array } }) => void) | null = null;
  feed(samples: number[]): void {
    this.onaudioprocess?.({ inputBuffer: { getChannelData: () => new Float32Array(samples) } });
  }
}
class FakeContext {
  destination = { name: 'speakers' };
  source = new FakeNode();
  probe = new FakeProcessor();
  closed = false;
  createMediaStreamSource(): FakeNode {
    return this.source;
  }
  createScriptProcessor(): FakeProcessor {
    return this.probe;
  }
  async resume(): Promise<void> {}
  async close(): Promise<void> {
    this.closed = true;
  }
}
const fakeStream = { getTracks: () => [] } as unknown as MediaStream;

test('warm-up waits through digital silence and resolves at the first real sample', async () => {
  const context = new FakeContext();
  let settled = false;
  const flow = waitForAudioFlow(fakeStream, context, 5000).then((f) => {
    settled = true;
    return f;
  });
  await Promise.resolve();
  context.probe.feed([0, 0, 0, 0]);
  context.probe.feed(new Array(512).fill(0));
  await new Promise((r) => setTimeout(r, 5));
  assert.equal(settled, false, 'silence is not audio flowing');
  context.probe.feed([0, 0, 0.0003, -0.0002]);
  const result = await flow;
  assert.equal(result.flowing, true);
  assert.ok(result.waitedMs >= 0 && result.waitedMs < 5000);
  // The probe comes off the graph; a context the caller passed in stays open for the caller.
  assert.equal(context.probe.onaudioprocess, null);
  assert.equal(context.probe.disconnected, 1);
  assert.equal(context.source.disconnected, 1);
  assert.equal(context.closed, false);
  assert.deepEqual(context.source.connected, [context.probe]);
  assert.deepEqual(context.probe.connected, [context.destination]);
});

test('a microphone that never warms up still records after the limit, and says so', async () => {
  const context = new FakeContext();
  const flow = waitForAudioFlow(fakeStream, context, 30);
  context.probe.feed([0, 0, 0]);
  const result = await flow;
  assert.equal(result.flowing, false);
  assert.ok(result.waitedMs >= 25, String(result.waitedMs));
  assert.equal(context.probe.disconnected, 1);
});

test('MediaRecorder starts only after the microphone is flowing, and recordVoiceMargin resolves only then', async () => {
  const events: string[] = [];
  class FakeRecorder {
    state = 'inactive';
    listeners: Record<string, ((event: unknown) => void)[]> = {};
    constructor(_stream: MediaStream, options: { mimeType: string }) {
      events.push(`recorder made (${options.mimeType})`);
    }
    addEventListener(type: string, listener: (event: unknown) => void): void {
      (this.listeners[type] ??= []).push(listener);
    }
    start(): void {
      this.state = 'recording';
      events.push('recorder started');
    }
    stop(): void {
      this.state = 'inactive';
      for (const l of this.listeners.stop ?? []) l({});
    }
  }
  const globals = globalThis as Record<string, unknown>;
  const saved = globals.MediaRecorder;
  globals.MediaRecorder = FakeRecorder;
  try {
    let open: (flow: { flowing: boolean; waitedMs: number }) => void = () => undefined;
    const pending = recordVoiceMargin({
      stream: fakeStream,
      path: 'media-recorder-aac',
      waitForAudio: () => {
        events.push('waiting for audio');
        return new Promise((resolve) => {
          open = resolve;
        });
      },
    }).then((recording) => {
      events.push('resolved');
      return recording;
    });
    await new Promise((r) => setTimeout(r, 5));
    assert.deepEqual(events, ['waiting for audio'], 'no recorder, and no "Recording" state, before audio flows');
    open({ flowing: true, waitedMs: 700 });
    const recording = await pending;
    assert.deepEqual(events, ['waiting for audio', `recorder made (${AAC_RECORDER_TYPE})`, 'recorder started', 'resolved']);
    assert.deepEqual(recording.warmUp, { flowing: true, waitedMs: 700 });
    recording.cancel();
  } finally {
    globals.MediaRecorder = saved;
  }
});
