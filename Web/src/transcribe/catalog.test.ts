import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  HUGGING_FACE,
  RUNTIME_BYTES,
  RUNTIME_VERSION,
  TRANSCRIPTION_MODEL,
  downloadBytes,
  downloadSizeLabel,
  fileUrl,
  isModelRequest,
  modelBytes,
  modelSizeLabel,
} from './catalog.ts';

test('the model is pinned to a commit on Hugging Face, never a branch or our server', () => {
  assert.match(TRANSCRIPTION_MODEL.revision, /^[0-9a-f]{40}$/);
  for (const file of TRANSCRIPTION_MODEL.files) {
    const url = new URL(fileUrl(file.path));
    assert.equal(url.origin, HUGGING_FACE);
    assert.ok(url.pathname.includes(`/resolve/${TRANSCRIPTION_MODEL.revision}/`), url.pathname);
  }
});

test('the size told to the listener is the pinned files plus the speech engine', () => {
  const sum = TRANSCRIPTION_MODEL.files.reduce((n, f) => n + f.bytes, 0);
  assert.equal(modelBytes(), sum);
  assert.ok(sum > 20_000_000 && sum < 60_000_000, `${sum} bytes: small and English-only`);
  assert.equal(modelSizeLabel(), `${Math.round(sum / 1_000_000)} MB`);
  assert.equal(downloadBytes(), sum + RUNTIME_BYTES);
  assert.equal(downloadSizeLabel(), `${Math.round((sum + RUNTIME_BYTES) / 1_000_000)} MB`);
  // Every graph the dtype names is in the file list, at its quantized name, so the size counts what is fetched.
  for (const graph of Object.keys(TRANSCRIPTION_MODEL.dtype)) {
    assert.ok(TRANSCRIPTION_MODEL.files.some((f) => f.path === `onnx/${graph}_quantized.onnx`), graph);
  }
});

test('only GETs of the pinned files count as the model download', () => {
  assert.equal(isModelRequest(fileUrl('tokenizer.json')), true);
  assert.equal(isModelRequest(`${HUGGING_FACE}/${TRANSCRIPTION_MODEL.repo}/resolve/main/tokenizer.json`), false);
  assert.equal(isModelRequest(`${HUGGING_FACE}/someone/else/resolve/${TRANSCRIPTION_MODEL.revision}/x.onnx`), false);
  assert.equal(isModelRequest(`https://spokenmargins.example/${TRANSCRIPTION_MODEL.repo}/resolve/${TRANSCRIPTION_MODEL.revision}/x`), false);
  assert.equal(isModelRequest(fileUrl('../../evil')), false);
});

test('the speech engine size matches the onnxruntime-web files the build ships', () => {
  // The fast plan runs these tests without Web's packages installed, so the lock file is the check that always runs:
  // a moved onnxruntime-web means the size the listener is told must be measured again.
  const lock = JSON.parse(readFileSync(new URL('../../package-lock.json', import.meta.url), 'utf8'));
  assert.equal(lock.packages['node_modules/onnxruntime-web']?.version, RUNTIME_VERSION,
    'onnxruntime-web moved: run `npm ci` in Web/, then update RUNTIME_BYTES and RUNTIME_VERSION in catalog.ts');
  // Where they are installed (a thread's own checkout, the Playwright run), the shipped files are measured too.
  const dist = (name: string) => fileURLToPath(new URL(`../../node_modules/onnxruntime-web/dist/${name}`, import.meta.url));
  const files = ['ort-wasm-simd-threaded.asyncify.wasm', 'ort-wasm-simd-threaded.asyncify.mjs'];
  if (!files.every((name) => existsSync(dist(name)))) return;
  assert.equal(RUNTIME_BYTES, files.reduce((n, name) => n + statSync(dist(name)).size, 0));
});
