// The transcription worker: runs the speech model off the main thread, so the page never stalls while it works.
// WebGPU when the browser has it, WebAssembly otherwise (slower, but it works everywhere the app does).
//
// What leaves the device: nothing but the model download, a GET of each file in catalog.ts from Hugging Face at
// its pinned revision. transformers.js keeps those files in Cache Storage (MODEL_CACHE in catalog.ts), so the second
// use reads them from there. ONNX Runtime's WebAssembly comes from this app's own build (the `?url` imports below),
// never from a CDN, and is cached the same way.
import { AutoModelForSpeechSeq2Seq, AutoProcessor, AutoTokenizer, AutomaticSpeechRecognitionPipeline, env } from '@huggingface/transformers';
import ortMjs from 'onnxruntime-web/ort-wasm-simd-threaded.asyncify.mjs?url';
import ortWasm from 'onnxruntime-web/ort-wasm-simd-threaded.asyncify.wasm?url';
import { HUGGING_FACE, MODEL_CACHE, TRANSCRIPTION_MODEL, modelBytes, type TranscriptionModel } from './catalog.ts';
import type { Device, FromWorker, ToWorker } from './protocol.ts';
import { joinSegmentTexts } from './segments.ts';

interface WorkerScope {
  postMessage(message: FromWorker): void;
  onmessage: ((event: MessageEvent<ToWorker>) => void) | null;
  location: { href: string };
  navigator: { gpu?: { requestAdapter(): Promise<unknown> } };
}
const scope = self as unknown as WorkerScope;

env.allowLocalModels = false;
env.allowRemoteModels = true;
env.remoteHost = `${HUGGING_FACE}/`;
env.useBrowserCache = true;
env.cacheKey = MODEL_CACHE;
const onnx = env.backends.onnx as { wasm?: { wasmPaths?: unknown; numThreads?: number } };
if (onnx.wasm) {
  onnx.wasm.wasmPaths = { mjs: new URL(ortMjs, scope.location.href).href, wasm: new URL(ortWasm, scope.location.href).href };
}

type Transcribe = (audio: Float32Array, options: Record<string, unknown>) => Promise<{ text: string } | { text: string }[]>;

let loaded: { run: Transcribe; device: Device; model: TranscriptionModel } | undefined;
let loading: Promise<void> | undefined;

async function hasWebGpu(): Promise<boolean> {
  try {
    return Boolean(scope.navigator.gpu && (await scope.navigator.gpu.requestAdapter()));
  } catch {
    return false;
  }
}

async function create(model: TranscriptionModel, device: Device): Promise<Transcribe> {
  const progress = new Map<string, number>();
  const total = modelBytes(model);
  const progress_callback = (event: { status?: string; file?: string; loaded?: number }) => {
    if (event.status !== 'progress' || !event.file) return;
    progress.set(event.file, event.loaded ?? 0);
    let sum = 0;
    for (const bytes of progress.values()) sum += bytes;
    scope.postMessage({ type: 'progress', loaded: Math.min(sum, total), total });
  };
  // The revision is written into the address template itself, not only passed as an option: transformers.js 4.3.1
  // asks for some files (the config `pipeline()` lists files from, the tokenizer's existence check) at "main"
  // whatever revision it is given. With the revision in the template, every request and cache key is the pinned
  // one. The parts are also loaded one by one rather than through `pipeline()`, which adds a round of metadata
  // requests.
  env.remotePathTemplate = `{model}/resolve/${encodeURIComponent(model.revision)}/`;
  const pinned = { revision: model.revision, progress_callback };
  const [tokenizer, processor, speech] = await Promise.all([
    AutoTokenizer.from_pretrained(model.repo, pinned),
    AutoProcessor.from_pretrained(model.repo, pinned),
    AutoModelForSpeechSeq2Seq.from_pretrained(model.repo, { ...pinned, device, dtype: { ...model.dtype } as never }),
  ]);
  const asr = new AutomaticSpeechRecognitionPipeline({ task: 'automatic-speech-recognition', model: speech, tokenizer, processor } as never);
  return ((audio, options) => asr(audio, options)) as Transcribe;
}

async function load(model: TranscriptionModel, wanted: Device): Promise<void> {
  const started = performance.now();
  const order: Device[] = wanted === 'webgpu' && (await hasWebGpu()) ? ['webgpu', 'wasm'] : ['wasm'];
  let lastError: unknown;
  for (const device of order) {
    try {
      const run = await create(model, device);
      loaded = { run, device, model };
      scope.postMessage({ type: 'ready', device, loadMs: Math.round(performance.now() - started) });
      return;
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError;
}

async function transcribeSegments(segments: Float32Array[]): Promise<string> {
  if (!loaded) throw new Error('The speech model isn’t loaded.');
  const texts: string[] = [];
  for (const segment of segments) {
    const seconds = segment.length / loaded.model.sampleRate;
    // Moonshine's own cap is 6 tokens per whole second, which gives a 0.9-second "yes" no tokens at all.
    const output = await loaded.run(segment, { max_new_tokens: Math.max(12, Math.ceil(seconds * 7)) });
    texts.push((Array.isArray(output) ? output[0]?.text : output.text) ?? '');
  }
  return joinSegmentTexts(texts);
}

scope.onmessage = (event) => {
  const message = event.data;
  if (message.type === 'load') {
    loading ??= load(message.model ?? TRANSCRIPTION_MODEL, message.device).catch((error: unknown) => {
      loading = undefined;
      scope.postMessage({ type: 'load-failed', message: error instanceof Error ? error.message : String(error) });
    });
    return;
  }
  if (message.type === 'transcribe') {
    const started = performance.now();
    void (async () => {
      try {
        let text: string;
        try {
          text = await transcribeSegments(message.segments);
        } catch (error) {
          // A GPU that loads the model but fails a run (lost device, an unsupported op) gets one try on WebAssembly.
          if (loaded?.device !== 'webgpu') throw error;
          await load(loaded.model, 'wasm');
          text = await transcribeSegments(message.segments);
        }
        scope.postMessage({ type: 'result', id: message.id, text, ms: Math.round(performance.now() - started), device: loaded?.device ?? 'wasm' });
      } catch (error) {
        scope.postMessage({ type: 'failed', id: message.id, message: error instanceof Error ? error.message : String(error) });
      }
    })();
  }
};
