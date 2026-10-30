// recordVoiceMargin: a voice Margin as AAC in `.m4a`, the only voice format a packet carries (Builds 32 and 34 check
// each voice asset with AudioFile). Browsers differ, so it picks a path:
//
// 1. MediaRecorder with `audio/mp4;codecs=mp4a.40.2` (Safari; Chrome where its MP4 muxer has AAC).
// 2. WebCodecs: the microphone's PCM through AudioEncoder (`mp4a.40.2`) and this module's own MP4 muxer.
// 3. MediaRecorder with plain `audio/mp4`, last because Chrome and Firefox fill it with Opus; kept only when what
//    comes out is AAC.
//
// Whatever records, the result goes through normalizeM4a, which refuses anything that isn't AAC and rewrites
// fragmented MP4 (Chrome's MediaRecorder output) as one plain progressive `.m4a`. Opus or WebM never reaches a packet.

import { NotAacError, audioSpecificConfigFromDescription, muxM4a, normalizeM4a } from './m4a.ts';
import type { AacTrack } from './m4a.ts';

export type RecordingPath = 'media-recorder-aac' | 'media-recorder-mp4' | 'webcodecs-aac' | 'unsupported';

export const AAC_RECORDER_TYPE = 'audio/mp4;codecs=mp4a.40.2';
export const MP4_RECORDER_TYPE = 'audio/mp4';
export const AAC_ENCODER_CONFIG = Object.freeze({ codec: 'mp4a.40.2', sampleRate: 48000, numberOfChannels: 1, bitrate: 64000 });

/** What the browser offers, so the choice can be tested without one. */
export interface RecordingEnvironment {
  recorderSupports?: (mimeType: string) => boolean;
  encoderSupports?: (config: typeof AAC_ENCODER_CONFIG) => Promise<boolean>;
}

export function browserEnvironment(): RecordingEnvironment {
  const g = globalThis as Record<string, unknown> & typeof globalThis;
  const recorder = g.MediaRecorder as { isTypeSupported?: (type: string) => boolean } | undefined;
  const encoder = g.AudioEncoder as { isConfigSupported?: (config: unknown) => Promise<{ supported?: boolean }> } | undefined;
  return {
    ...(recorder?.isTypeSupported && { recorderSupports: (type: string) => Boolean(recorder.isTypeSupported?.(type)) }),
    ...(encoder?.isConfigSupported && {
      encoderSupports: async (config: typeof AAC_ENCODER_CONFIG) => {
        try {
          return Boolean((await encoder.isConfigSupported?.(config))?.supported);
        } catch {
          return false;
        }
      },
    }),
  };
}

/** The first path that can make AAC, in the order above. `unsupported` means this browser can't record a voice Margin. */
export async function chooseRecordingPath(env: RecordingEnvironment = browserEnvironment()): Promise<RecordingPath> {
  if (env.recorderSupports?.(AAC_RECORDER_TYPE)) return 'media-recorder-aac';
  if (await env.encoderSupports?.(AAC_ENCODER_CONFIG)) return 'webcodecs-aac';
  if (env.recorderSupports?.(MP4_RECORDER_TYPE)) return 'media-recorder-mp4';
  return 'unsupported';
}

export interface RecordedVoice {
  blob: Blob;
  mimeType: 'audio/mp4';
  durationSeconds: number;
  path: RecordingPath;
}

export interface VoiceRecording {
  readonly path: RecordingPath;
  /** Ends the recording and returns AAC `.m4a`. Rejects with NotAacError when the browser recorded something else. */
  stop(): Promise<RecordedVoice>;
  /** Ends the recording and drops it. */
  cancel(): void;
}

export class RecordingUnavailableError extends Error {
  constructor() {
    super("This browser can't record voice Margins in a format the iPhone app plays. Written Margins still work.");
    this.name = 'RecordingUnavailableError';
  }
}

export interface RecordOptions {
  /** A stream the caller already opened; otherwise the microphone is asked for. The caller stops its own stream. */
  stream?: MediaStream;
  environment?: RecordingEnvironment;
  /** Force a path, for the test page. */
  path?: Exclude<RecordingPath, 'unsupported'>;
}

function finish(bytes: Uint8Array, path: RecordingPath): RecordedVoice {
  const normalized = normalizeM4a(bytes);
  return {
    blob: new Blob([normalized.bytes as BlobPart], { type: 'audio/mp4' }),
    mimeType: 'audio/mp4',
    durationSeconds: normalized.durationMs / 1000,
    path,
  };
}

/** Starts recording a voice Margin. Call `stop()` for the `.m4a`. */
export async function recordVoiceMargin(options: RecordOptions = {}): Promise<VoiceRecording> {
  const path = options.path ?? await chooseRecordingPath(options.environment);
  if (path === 'unsupported') throw new RecordingUnavailableError();
  const ownStream = !options.stream;
  const stream = options.stream ?? await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: true } });
  const release = (): void => {
    if (ownStream) for (const track of stream.getTracks()) track.stop();
  };
  try {
    return path === 'webcodecs-aac' ? await recordWithEncoder(stream, release) : recordWithRecorder(stream, path, release);
  } catch (error) {
    release();
    throw error;
  }
}

function recordWithRecorder(stream: MediaStream, path: 'media-recorder-aac' | 'media-recorder-mp4', release: () => void): VoiceRecording {
  const recorder = new MediaRecorder(stream, { mimeType: path === 'media-recorder-aac' ? AAC_RECORDER_TYPE : MP4_RECORDER_TYPE });
  const chunks: Blob[] = [];
  recorder.addEventListener('dataavailable', (event) => {
    if (event.data.size) chunks.push(event.data);
  });
  const stopped = new Promise<void>((resolve, reject) => {
    recorder.addEventListener('stop', () => resolve());
    recorder.addEventListener('error', (event) => reject((event as unknown as { error?: Error }).error ?? new Error('recording failed')));
  });
  recorder.start(1000);
  return {
    path,
    async stop() {
      if (recorder.state !== 'inactive') recorder.stop();
      await stopped;
      release();
      const bytes = new Uint8Array(await new Blob(chunks).arrayBuffer());
      return finish(bytes, path);
    },
    cancel() {
      if (recorder.state !== 'inactive') recorder.stop();
      release();
    },
  };
}

/** Encoded AAC frames from WebCodecs, gathered into a track the muxer writes. */
export class AacFrameCollector {
  readonly frames: Uint8Array[] = [];
  audioSpecificConfig?: Uint8Array;
  sampleRate: number;
  channels: number;

  constructor(sampleRate: number, channels: number) {
    this.sampleRate = sampleRate;
    this.channels = channels;
  }

  add(chunk: { byteLength: number; copyTo(destination: Uint8Array): void }, metadata?: { decoderConfig?: { description?: AllowSharedBufferSource } }): void {
    const description = metadata?.decoderConfig?.description;
    if (description && !this.audioSpecificConfig) {
      const bytes = description instanceof ArrayBuffer
        ? new Uint8Array(description.slice(0))
        : new Uint8Array((description as ArrayBufferView).buffer as ArrayBuffer, (description as ArrayBufferView).byteOffset, (description as ArrayBufferView).byteLength).slice();
      // Chrome describes the stream with a bare AudioSpecificConfig, WebKit with an ES_Descriptor around one.
      this.audioSpecificConfig = audioSpecificConfigFromDescription(bytes);
    }
    const frame = new Uint8Array(chunk.byteLength);
    chunk.copyTo(frame);
    this.frames.push(frame);
  }

  track(): AacTrack {
    if (!this.audioSpecificConfig) throw new NotAacError('the encoder gave no AudioSpecificConfig');
    return {
      audioSpecificConfig: this.audioSpecificConfig,
      sampleRate: this.sampleRate,
      channels: this.channels,
      timescale: this.sampleRate,
      frames: this.frames,
      durations: this.frames.map(() => 1024),
    };
  }
}

async function recordWithEncoder(stream: MediaStream, release: () => void): Promise<VoiceRecording> {
  const context = new AudioContext({ sampleRate: AAC_ENCODER_CONFIG.sampleRate });
  const sampleRate = context.sampleRate;
  const collector = new AacFrameCollector(sampleRate, 1);
  let failure: Error | undefined;
  const encoder = new AudioEncoder({
    output: (chunk, metadata) => collector.add(chunk, metadata),
    error: (error) => {
      failure = error;
    },
  });
  encoder.configure({ ...AAC_ENCODER_CONFIG, sampleRate, aac: { format: 'aac' } } as AudioEncoderConfig);
  const source = context.createMediaStreamSource(stream);
  // ScriptProcessorNode is deprecated but needs no worklet file, and every browser with AudioEncoder has it.
  const processor = context.createScriptProcessor(4096, 1, 1);
  let timestamp = 0;
  processor.onaudioprocess = (event) => {
    const samples = new Float32Array(event.inputBuffer.getChannelData(0));
    encoder.encode(new AudioData({ format: 'f32-planar', sampleRate, numberOfFrames: samples.length, numberOfChannels: 1, timestamp, data: samples }));
    timestamp += Math.round((samples.length * 1_000_000) / sampleRate);
  };
  source.connect(processor);
  processor.connect(context.destination);
  const teardown = async (): Promise<void> => {
    processor.disconnect();
    source.disconnect();
    release();
    await context.close();
  };
  return {
    path: 'webcodecs-aac',
    async stop() {
      await teardown();
      await encoder.flush();
      encoder.close();
      if (failure) throw failure;
      const track = collector.track();
      return finish(muxM4a(track), 'webcodecs-aac');
    },
    cancel() {
      void teardown();
      encoder.close();
    },
  };
}
