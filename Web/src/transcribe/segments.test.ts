import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SILENCE_PEAK, cleanTranscript, joinSegmentTexts, mixToMono, peak, splitAtQuiet } from './segments.ts';

const RATE = 16_000;

/** Seconds of a 220 Hz tone, or of silence when `loud` is false. */
function sound(seconds: number, loud = true): Float32Array {
  const out = new Float32Array(Math.round(seconds * RATE));
  if (loud) for (let i = 0; i < out.length; i += 1) out[i] = 0.5 * Math.sin((2 * Math.PI * 220 * i) / RATE);
  return out;
}

function concat(...parts: Float32Array[]): Float32Array {
  const out = new Float32Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

test('stereo is averaged into one channel', () => {
  const mono = mixToMono([Float32Array.from([1, 0, 0.5]), Float32Array.from([0, 1, 0.5])]);
  assert.deepEqual(Array.from(mono), [0.5, 0.5, 0.5]);
  const single = Float32Array.from([0.1, 0.2]);
  assert.equal(mixToMono([single]), single);
  assert.equal(mixToMono([]).length, 0);
});

test('a recording that fits goes to the model whole', () => {
  const short = sound(12);
  const pieces = splitAtQuiet(short, RATE, 20);
  assert.equal(pieces.length, 1);
  assert.equal(pieces[0]?.length, short.length);
  assert.equal(splitAtQuiet(new Float32Array(0), RATE, 20).length, 1);
});

test('a long recording is cut at its pauses, no piece longer than the limit, nothing lost', () => {
  // Speech-like: 15 s of sound, a half-second pause, 15 s, a pause, 10 s.
  const audio = concat(sound(15), sound(0.5, false), sound(15), sound(0.5, false), sound(10));
  const pieces = splitAtQuiet(audio, RATE, 20);
  assert.equal(pieces.length, 3);
  assert.equal(pieces.reduce((n, p) => n + p.length, 0), audio.length);
  for (const p of pieces) assert.ok(p.length <= 20 * RATE, `piece of ${p.length / RATE} s`);
  // Each cut lands inside a pause, not through the sound.
  const firstCut = (pieces[0]?.length ?? 0) / RATE;
  assert.ok(firstCut >= 15 && firstCut <= 15.5, `first cut at ${firstCut} s`);
  // A recording with no pause at all is still cut within the limit.
  const solid = splitAtQuiet(sound(45), RATE, 20);
  assert.ok(solid.length >= 3);
  for (const p of solid) assert.ok(p.length <= 20 * RATE);
  assert.throws(() => splitAtQuiet(audio, RATE, 0), RangeError);
});

test('silence is recognised so the model is not asked to invent words', () => {
  assert.ok(peak(sound(1, false)) < SILENCE_PEAK);
  assert.ok(peak(sound(1)) >= SILENCE_PEAK);
});

test('sound labels are dropped and only words are kept', () => {
  const rows: Array<[string, string]> = [
    ['  And so, my fellow Americans.  ', 'And so, my fellow Americans.'],
    ['[BLANK_AUDIO]', ''],
    ['[Music]', ''],
    ['(beeping)', ''],
    [' (Applause) Thank you. ', 'Thank you.'],
    ['...', ''],
    ['', ''],
    ['Call me (if you can) later', 'Call me (if you can) later'], // a real aside stays
    ['line one\n\nline two', 'line one line two'],
    ['Café à 3 h', 'Café à 3 h'],
    ['42', '42'],
  ];
  for (const [input, expected] of rows) assert.equal(cleanTranscript(input), expected, JSON.stringify(input));
});

test('pieces join into one line, skipping empty ones', () => {
  assert.equal(joinSegmentTexts([' Ask not ', '[BLANK_AUDIO]', 'what your country can do.']), 'Ask not what your country can do.');
  assert.equal(joinSegmentTexts(['', '(silence)']), '');
});
