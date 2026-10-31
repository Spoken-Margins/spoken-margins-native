// The speech-to-text model the web app can download, pinned like the iPhone app's voice catalog (owner,
// 2026-10-17): fetched straight from Hugging Face at a fixed revision, never from our server, and only after the
// listener turns transcription on. Plain TypeScript, so `npm run test:web` checks it (catalog.test.ts).
//
// Why Moonshine Tiny (English) and not Whisper: it is MIT like Whisper, smaller (about 32 MB against 45 MB for
// whisper-tiny.en at the same 8-bit quantization), and its encoder works on the audio's real length instead of a
// fixed 30-second window, so a 10-second Margin costs a third of the work. Measured on the Mac in
// Web/README.md ("On-device transcription").

export interface ModelFile {
  /** Path inside the model repository. */
  path: string;
  /** Size in bytes at the pinned revision, so the download size is known before anything is fetched. */
  bytes: number;
}

export interface TranscriptionModel {
  /** The id transformers.js loads, which is the Hugging Face repository. */
  repo: string;
  /** A commit of that repository. Every file is fetched at this revision. */
  revision: string;
  /** What the listener reads. */
  name: string;
  licence: string;
  /** transformers.js's dtype per ONNX graph; the same files serve WebGPU and WebAssembly. */
  dtype: Readonly<Record<string, string>>;
  files: readonly ModelFile[];
  /** Audio sample rate the model takes. */
  sampleRate: number;
  /** The longest piece of audio given to the model at once. Longer recordings are split at quiet moments. */
  maxSegmentSeconds: number;
}

export const HUGGING_FACE = 'https://huggingface.co';

/** The Cache Storage the model is kept in, after its one download (worker.ts gives it to transformers.js). */
export const MODEL_CACHE = 'sm-transcription-model';

export const MOONSHINE_TINY: TranscriptionModel = Object.freeze({
  repo: 'onnx-community/moonshine-tiny-ONNX',
  revision: 'a6da1241cd305dcd64eab1edbd615f2bb9aabb95',
  name: 'Moonshine Tiny (English)',
  licence: 'MIT',
  dtype: Object.freeze({ encoder_model: 'q8', decoder_model_merged: 'q8' }),
  files: Object.freeze([
    { path: 'config.json', bytes: 921 },
    { path: 'generation_config.json', bytes: 147 },
    { path: 'preprocessor_config.json', bytes: 128 },
    { path: 'tokenizer.json', bytes: 3_761_754 },
    { path: 'tokenizer_config.json', bytes: 135_735 },
    { path: 'onnx/encoder_model_quantized.onnx', bytes: 7_937_661 },
    { path: 'onnx/decoder_model_merged_quantized.onnx', bytes: 20_243_286 },
  ]),
  sampleRate: 16_000,
  maxSegmentSeconds: 20,
});

export const TRANSCRIPTION_MODEL: TranscriptionModel = MOONSHINE_TINY;

/** Bytes the listener downloads once. */
/** The model's own files, all from Hugging Face. */
export function modelBytes(model: TranscriptionModel = TRANSCRIPTION_MODEL): number {
  return model.files.reduce((sum, file) => sum + file.bytes, 0);
}

/**
 * The speech engine (onnxruntime-web's WebAssembly build and its loader), which comes from the app's own site rather
 * than Hugging Face and is kept with the model once transcription is on. It is not part of the app shell, so a
 * listener who never turns transcription on never downloads it. Measured from `RUNTIME_VERSION`; catalog.test.ts
 * checks Web/package-lock.json still pins that version, and the file sizes when Web's packages are installed.
 */
export const RUNTIME_BYTES = 26_861_777 + 53_057;

/** The onnxruntime-web version `RUNTIME_BYTES` was measured from. Re-measure when the lock file moves. */
export const RUNTIME_VERSION = '1.31.0-dev.20260914-8d85527a0';

/** Everything turning transcription on adds to this browser: the model plus the speech engine. */
export function downloadBytes(model: TranscriptionModel = TRANSCRIPTION_MODEL): number {
  return modelBytes(model) + RUNTIME_BYTES;
}

/** "59 MB": what the listener is told before the download, rounded to whole megabytes (10^6, as phones show). */
export function downloadSizeLabel(model: TranscriptionModel = TRANSCRIPTION_MODEL): string {
  return megabytes(downloadBytes(model));
}

/** "32 MB": the part that comes from Hugging Face. */
export function modelSizeLabel(model: TranscriptionModel = TRANSCRIPTION_MODEL): string {
  return megabytes(modelBytes(model));
}

const megabytes = (bytes: number) => `${Math.max(1, Math.round(bytes / 1_000_000))} MB`;

/** The address of one model file at the pinned revision: the only place the model is ever fetched from. */
export function fileUrl(path: string, model: TranscriptionModel = TRANSCRIPTION_MODEL): string {
  return `${HUGGING_FACE}/${model.repo}/resolve/${model.revision}/${path}`;
}

/**
 * Whether a request is one the transcriber may make: a GET of a file in the pinned model at its pinned revision.
 * Anything else (another host, another revision, a body) is not the model download.
 */
export function isModelRequest(url: string, model: TranscriptionModel = TRANSCRIPTION_MODEL): boolean {
  const prefix = `${HUGGING_FACE}/${model.repo}/resolve/${model.revision}/`;
  return url.startsWith(prefix) && !url.slice(prefix.length).includes('..');
}
