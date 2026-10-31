import { test } from 'node:test';
import assert from 'node:assert/strict';
import { initialPhase, loadingLine, mayRun, nextPhase, prefill, settingAfter, type Phase, type PhaseEvent, type TranscriptionSetting } from './state.ts';

test('nothing runs or downloads until the listener says yes', () => {
  const rows: Array<[TranscriptionSetting, boolean, Phase['kind']]> = [
    ['', true, 'offer'],
    ['off', true, 'off'],
    ['on', true, 'loading'],
    ['', false, 'off'],
    ['on', false, 'off'], // a browser that can't run it falls back to the plain box, even when turned on
  ];
  for (const [setting, supported, kind] of rows) {
    const phase = initialPhase(setting, supported);
    assert.equal(phase.kind, kind, `${setting || 'unset'} supported=${supported}`);
    assert.equal(mayRun(phase), kind === 'loading', `${setting || 'unset'} supported=${supported} may run`);
  }
  // Declining the offer never reaches a phase that runs the model, whatever arrives after it.
  let phase = nextPhase(initialPhase('', true), { type: 'decline' });
  for (const event of [{ type: 'progress', loaded: 5, total: 10 }, { type: 'loaded' }, { type: 'result', text: 'hello' }] as PhaseEvent[]) {
    phase = nextPhase(phase, event);
    assert.equal(mayRun(phase), false);
    assert.equal(phase.kind, 'off');
  }
});

test('accepting the offer loads, transcribes and finishes', () => {
  let phase = nextPhase(initialPhase('', true), { type: 'accept' });
  assert.deepEqual(phase, { kind: 'loading', loaded: 0, total: 0 });
  phase = nextPhase(phase, { type: 'progress', loaded: 8_000_000, total: 32_000_000 });
  assert.deepEqual(phase, { kind: 'loading', loaded: 8_000_000, total: 32_000_000 });
  phase = nextPhase(phase, { type: 'loaded' });
  assert.deepEqual(phase, { kind: 'transcribing' });
  phase = nextPhase(phase, { type: 'result', text: 'Ask what you can do.' });
  assert.deepEqual(phase, { kind: 'done', text: 'Ask what you can do.' });
  // A late progress or error after the result changes nothing.
  assert.deepEqual(nextPhase(phase, { type: 'error', message: 'late' }), phase);
  assert.deepEqual(nextPhase(phase, { type: 'progress', loaded: 1, total: 2 }), phase);
});

test('a failure can be tried again, and the answer is stored as the setting', () => {
  const failed = nextPhase({ kind: 'transcribing' }, { type: 'error', message: 'GPU lost' });
  assert.deepEqual(failed, { kind: 'failed', message: 'GPU lost' });
  assert.equal(nextPhase(failed, { type: 'accept' }).kind, 'loading');
  assert.equal(settingAfter({ type: 'accept' }, ''), 'on');
  assert.equal(settingAfter({ type: 'decline' }, ''), 'off');
  assert.equal(settingAfter({ type: 'result', text: 'x' }, 'on'), 'on');
});

test('the transcript fills the box only when the listener has not typed', () => {
  assert.deepEqual(prefill('', false, '  Ask not.  '), { words: 'Ask not.' });
  // Typed, then cleared: an empty box takes the transcript.
  assert.deepEqual(prefill('  ', true, 'Ask not.'), { words: 'Ask not.' });
  // Typed words stay, and the transcript is offered beside them.
  assert.deepEqual(prefill('my own words', true, 'Ask not.'), { words: 'my own words', suggestion: 'Ask not.' });
  // Typed the same thing: nothing to offer.
  assert.deepEqual(prefill('Ask not.', true, 'Ask not.'), { words: 'Ask not.' });
  // No words heard: the box is untouched, typed or not.
  assert.deepEqual(prefill('', false, ''), { words: '' });
  assert.deepEqual(prefill('mine', true, '   '), { words: 'mine' });
});

test('the loading line names the size before it is known, then the progress', () => {
  assert.equal(loadingLine({ kind: 'loading', loaded: 0, total: 0 }, '28 MB'), 'Getting the speech model ready (28 MB the first time)…');
  assert.equal(loadingLine({ kind: 'loading', loaded: 12_400_000, total: 32_100_000 }, '32 MB'), 'Downloading the speech model, 12 of 32 MB…');
  assert.equal(loadingLine({ kind: 'loading', loaded: 32_100_000, total: 32_100_000 }, '32 MB'), 'Getting the speech model ready…');
  assert.equal(loadingLine({ kind: 'transcribing' }, '32 MB'), '');
});
