import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Margin } from '../../shared/model.ts';
import { fromRow, toRow } from './voice-rows.ts';

const bytes = new Uint8Array([0, 0, 0, 24, 102, 116, 121, 112, 77, 52, 65, 32, 9, 8, 7]);
const voice: Margin = {
  id: 'v1',
  episodeId: 'e1',
  atSeconds: 12,
  createdAt: '2026-10-31T01:02:00Z',
  voice: { blob: new Blob([bytes], { type: 'audio/mp4' }), mimeType: 'audio/mp4', durationSeconds: 2.5 },
};
const written: Margin = { id: 'w1', episodeId: 'e1', atSeconds: 3, createdAt: '2026-10-31T01:03:00Z', text: 'Tides.' };

/** Whether a value holds a Blob anywhere inside it, the thing Safari's private browsing won't store. */
function holdsBlob(value: unknown): boolean {
  if (value instanceof Blob) return true;
  if (value && typeof value === 'object' && !(value instanceof ArrayBuffer)) return Object.values(value).some(holdsBlob);
  return false;
}

test('a stored voice Margin holds bytes and no Blob, so a browser that refuses Blobs can keep it (#3043)', async () => {
  const row = await toRow(voice);
  assert.equal(holdsBlob(row), false);
  assert.ok(row.voice?.data instanceof ArrayBuffer);
  assert.deepEqual(new Uint8Array(row.voice.data), bytes);
});

test('reading the row back gives the same audio, type, length and fields', async () => {
  const back = fromRow(await toRow(voice));
  assert.ok(back.voice?.blob instanceof Blob);
  assert.equal(back.voice.blob.type, 'audio/mp4');
  assert.deepEqual(new Uint8Array(await back.voice.blob.arrayBuffer()), bytes);
  assert.equal(back.voice.mimeType, 'audio/mp4');
  assert.equal(back.voice.durationSeconds, 2.5);
  assert.deepEqual({ ...back, voice: undefined }, { ...voice, voice: undefined });
});

test('a written Margin passes through untouched', async () => {
  assert.equal(await toRow(written), written);
  assert.equal(fromRow(written), written);
});

test('a voice row saved before #3043, holding a Blob, still reads as it did', () => {
  assert.equal(fromRow(voice), voice);
  assert.equal(fromRow(voice).voice?.blob, voice.voice?.blob);
});

test('a voice row with neither bytes nor a Blob is kept as it is, not dropped', () => {
  const odd = { ...written, voice: { mimeType: 'audio/mp4', durationSeconds: 1 } };
  assert.equal(fromRow(odd), odd as unknown as Margin);
});
