// The page's side of on-device transcription. It decodes a voice Margin in the browser, hands 16 kHz mono samples
// to the worker (worker.ts), and gets words back. The recording is never sent anywhere: the only requests this
// feature makes are the model download in catalog.ts, once, after the listener turns it on.
import { MODEL_CACHE, TRANSCRIPTION_MODEL, fileUrl, type TranscriptionModel } from './catalog.ts';
import type { Device, FromWorker, ToWorker } from './protocol.ts';
import { SILENCE_PEAK, mixToMono, peak, splitAtQuiet } from './segments.ts';

export interface Transcript {
  text: string;
  /** How long the model took, without decoding or loading. */
  ms: number;
  device: Device;
}

export interface Transcriber {
  /** Whether this browser can run the model at all (a worker, WebAssembly and audio decoding). */
  supported(): boolean;
  /** Whether every model file is already kept in this browser. */
  isDownloaded(): Promise<boolean>;
  /** Loads the model, downloading it the first time. Progress is in bytes of the known total. */
  prepare(onProgress?: (loaded: number, total: number) => void): Promise<Device>;
  /** Words for a recording, or '' when none were heard. */
  transcribe(voice: Blob, onSegment?: (done: number, total: number) => void): Promise<Transcript>;
  /** Forgets the downloaded model. */
  remove(): Promise<void>;
  /**
   * Stops a load or run that has gone quiet, keeping the downloaded model, so the next `prepare` starts afresh.
   * A load still waiting is rejected; a run's promise never settles, as its caller has moved on.
   */
  abandon(): void;
}

function browserSupports(): boolean {
  return typeof Worker !== 'undefined' && typeof WebAssembly !== 'undefined' && typeof OfflineAudioContext !== 'undefined';
}

/** A recording as the model takes it: 16 kHz, one channel. The browser's own decoder does the resampling. */
export async function decodeForModel(voice: Blob, sampleRate: number): Promise<Float32Array> {
  const context = new OfflineAudioContext(1, 1, sampleRate);
  const buffer = await context.decodeAudioData(await voice.arrayBuffer());
  const channels: Float32Array[] = [];
  for (let c = 0; c < buffer.numberOfChannels; c += 1) channels.push(buffer.getChannelData(c));
  return mixToMono(channels);
}

export interface TranscriberOptions {
  model?: TranscriptionModel;
  /**
   * The backend. Left out, WebAssembly: on an M-series Mac in Chrome it ran 30 s of speech in about 1.3 s, while the
   * same 8-bit model on WebGPU took about 7.5 s (its int8 operators fall back to the CPU), and the WebGPU-friendly
   * files (a 32-bit encoder and a 4-bit decoder) took about 1.5 s but weigh 75 MB instead of 32 MB. 'webgpu' tries
   * the GPU first and falls back to WebAssembly.
   */
  device?: Device;
}

export function createTranscriber(options: TranscriberOptions = {}): Transcriber {
  const model = options.model ?? TRANSCRIPTION_MODEL;
  let worker: Worker | undefined;
  let ready: Promise<Device> | undefined;
  let nextId = 1;
  const waiting = new Map<number, { resolve: (t: Transcript) => void; reject: (e: Error) => void; onSegment?: (done: number, total: number) => void }>();
  /** Bumped when a stuck worker is stopped or the model is removed, so a call begun before it gives up. */
  let generation = 0;
  let abortStart: ((error: Error) => void) | undefined;
  let progressListener: ((loaded: number, total: number) => void) | undefined;

  const send = (message: ToWorker, transfer: Transferable[] = []) => worker?.postMessage(message, transfer);

  const start = (): Promise<Device> =>
    new Promise<Device>((resolve, reject) => {
      abortStart = reject;
      worker = new Worker(new URL('./worker.ts', import.meta.url), { type: 'module', name: 'transcription' });
      worker.onmessage = (event: MessageEvent<FromWorker>) => {
        const message = event.data;
        if (message.type === 'progress') progressListener?.(message.loaded, message.total);
        else if (message.type === 'ready') resolve(message.device);
        else if (message.type === 'load-failed') reject(new Error(message.message));
        else if (message.type === 'segment') waiting.get(message.id)?.onSegment?.(message.done, message.total);
        else if (message.type === 'result' || message.type === 'failed') {
          const job = waiting.get(message.id);
          waiting.delete(message.id);
          if (message.type === 'result') job?.resolve({ text: message.text, ms: message.ms, device: message.device });
          else job?.reject(new Error(message.message));
        }
      };
      worker.onerror = (event) => {
        event.preventDefault();
        reject(new Error(event.message || 'The speech model stopped.'));
        for (const job of waiting.values()) job.reject(new Error(event.message || 'The speech model stopped.'));
        waiting.clear();
      };
      const device: Device = options.device ?? 'wasm';
      send({ type: 'load', device, ...(model === TRANSCRIPTION_MODEL ? {} : { model }) });
    });

  const prepare = (onProgress?: (loaded: number, total: number) => void): Promise<Device> => {
    if (onProgress) progressListener = onProgress;
    if (!ready) {
      const attempt: Promise<Device> = start().catch((error: unknown) => {
        // A failed load (no network for the first download, say) can be tried again from scratch. Only the load
        // still current clears the state: a stopped one must not take down the worker that replaced it.
        if (ready === attempt) {
          worker?.terminate();
          worker = undefined;
          ready = undefined;
        }
        throw error;
      });
      ready = attempt;
    }
    return ready;
  };

  return {
    supported: browserSupports,
    async isDownloaded() {
      if (typeof caches === 'undefined') return false;
      try {
        // has() first: open() would create an empty cache, so checking after "Remove" would leave one behind.
        if (!(await caches.has(MODEL_CACHE))) return false;
        const cache = await caches.open(MODEL_CACHE);
        const found = await Promise.all(model.files.map((file) => cache.match(fileUrl(file.path, model))));
        return found.every(Boolean);
      } catch {
        return false;
      }
    },
    prepare,
    async transcribe(voice, onSegment) {
      const mine = generation;
      const stopped = () => new Error('The speech model was stopped.');
      const samples = await decodeForModel(voice, model.sampleRate);
      if (generation !== mine) throw stopped();
      if (peak(samples) < SILENCE_PEAK) return { text: '', ms: 0, device: await prepare() };
      await prepare();
      if (generation !== mine) throw stopped();
      const segments = splitAtQuiet(samples, model.sampleRate, model.maxSegmentSeconds).map((s) => s.slice());
      const id = nextId;
      nextId += 1;
      return new Promise<Transcript>((resolve, reject) => {
        waiting.set(id, { resolve, reject, ...(onSegment && { onSegment }) });
        send({ type: 'transcribe', id, segments }, segments.map((s) => s.buffer));
      });
    },
    abandon() {
      generation += 1;
      worker?.terminate();
      worker = undefined;
      ready = undefined;
      waiting.clear();
      progressListener = undefined;
      // Anything else awaiting this load (Settings' download, say) is told, not left spinning.
      abortStart?.(new Error('The speech model was stopped.'));
      abortStart = undefined;
    },
    async remove() {
      generation += 1;
      worker?.terminate();
      worker = undefined;
      ready = undefined;
      if (typeof caches !== 'undefined') await caches.delete(MODEL_CACHE);
    },
  };
}
