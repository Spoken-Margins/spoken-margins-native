// Messages between the page and the transcription worker. Audio goes in as 16 kHz mono samples and only words
// come out; the worker makes no request except the model download (catalog.ts).
import type { TranscriptionModel } from './catalog.ts';

export type Device = 'webgpu' | 'wasm';

export type ToWorker =
  /** Loads the model, downloading it the first time. `model` defaults to the catalog's (a bench may pass another). */
  | { type: 'load'; device: Device; model?: TranscriptionModel }
  | { type: 'transcribe'; id: number; segments: Float32Array[] };

export type FromWorker =
  | { type: 'progress'; loaded: number; total: number }
  | { type: 'ready'; device: Device; loadMs: number }
  | { type: 'load-failed'; message: string }
  /** One segment of a run is done: a long Margin shows it is moving, so only a run that goes quiet is stuck. */
  | { type: 'segment'; id: number; done: number; total: number }
  | { type: 'result'; id: number; text: string; ms: number; device: Device }
  | { type: 'failed'; id: number; message: string };
