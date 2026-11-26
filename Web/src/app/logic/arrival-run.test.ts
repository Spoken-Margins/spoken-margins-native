import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Margin } from '../../shared/model.ts';
import { runMargins, type MarginHooks, type MarginRunEffects, type MarginRunProgress } from './arrival-run.ts';

const margin = (id: string): Margin => ({ id, episodeId: 'e', atSeconds: 0, createdAt: '2026-11-25T10:00:00Z', text: id, author: 'Cole' });

/** Effects the test drives by hand: each sound waits until the test ends it. */
function fake() {
  const log: string[] = [];
  const pending: Array<{ kind: 'line' | 'margin'; id: string; end: () => void; hooks?: MarginHooks; stopped: boolean }> = [];
  const effects: MarginRunEffects = {
    speak(text, ended) {
      log.push(`say ${text}`);
      const entry = { kind: 'line' as const, id: text, end: ended, stopped: false };
      pending.push(entry);
      return { stop: () => { entry.stopped = true; log.push(`stop ${text}`); } };
    },
    playMargin(m, hooks) {
      log.push(`play ${m.id}`);
      const entry = { kind: 'margin' as const, id: m.id, end: () => hooks.ended(), hooks, stopped: false };
      pending.push(entry);
      return { stop: () => { entry.stopped = true; log.push(`stop ${m.id}`); } };
    },
  };
  const last = () => pending[pending.length - 1];
  return { log, pending, effects, last };
}

test('each step: the context line, then the Margin, in order, then done', () => {
  const f = fake();
  const progress: MarginRunProgress[] = [];
  runMargins([{ context: 'before a', margin: margin('a') }, { margin: margin('b') }], f.effects, (p) => progress.push(p));
  f.last().end(); // the line
  f.last().hooks?.started();
  f.last().end(); // a
  f.last().end(); // b
  assert.deepEqual(f.log, ['say before a', 'play a', 'play b']);
  assert.deepEqual(progress.map((p) => `${p.index} ${p.phase}`), ['0 context', '0 margin', '0 ended', '1 margin', '1 ended', '1 done']);
});

test('Stop silences what is sounding and nothing it started reports again', () => {
  const f = fake();
  const progress: string[] = [];
  const run = runMargins([{ context: 'ctx', margin: margin('a') }, { margin: margin('b') }], f.effects, (p) => progress.push(p.phase));
  run.stop();
  assert.deepEqual(f.log, ['say ctx', 'stop ctx']);
  f.pending[0].end(); // a voice that reports its end after the stop
  assert.deepEqual(progress, ['context']);
  assert.deepEqual(f.log, ['say ctx', 'stop ctx'], 'the Margin never starts');
});

test('a refused clip waits on that Margin; a run started from it goes on from there, not from the first', () => {
  const f = fake();
  const progress: string[] = [];
  runMargins([{ margin: margin('a') }, { margin: margin('b') }, { margin: margin('c') }], f.effects, (p) => progress.push(`${p.index} ${p.phase}`));
  f.last().end();
  f.last().hooks?.blocked();
  assert.deepEqual(progress, ['0 margin', '0 ended', '1 margin', '1 blocked']);
  assert.equal(f.log.includes('play c'), false);
  const again: string[] = [];
  runMargins([{ margin: margin('a') }, { margin: margin('b') }, { margin: margin('c') }], f.effects, (p) => again.push(`${p.index} ${p.phase}`), { startAt: 1 });
  f.last().end();
  f.last().end();
  assert.deepEqual(again, ['1 margin', '1 ended', '2 margin', '2 ended', '2 done']);
});

test('a clip that fails is marked and the run goes on to the next', () => {
  const f = fake();
  const progress: string[] = [];
  runMargins([{ margin: margin('a') }, { margin: margin('b') }], f.effects, (p) => progress.push(`${p.index} ${p.phase}`));
  f.last().hooks?.failed();
  f.last().end();
  assert.deepEqual(progress, ['0 margin', '0 failed', '1 margin', '1 ended', '1 done']);
});

test('“Hear this one” plays that step alone, with its context, then stops', () => {
  const f = fake();
  const progress: string[] = [];
  runMargins([{ margin: margin('a') }, { context: 'ctx b', margin: margin('b') }, { margin: margin('c') }], f.effects, (p) => progress.push(`${p.index} ${p.phase}`), { startAt: 1, only: true });
  f.last().end();
  f.last().end();
  assert.deepEqual(f.log, ['say ctx b', 'play b']);
  assert.deepEqual(progress, ['1 context', '1 margin', '1 ended', '1 done']);
});

test('a second run stops the first: one run sounds (burst)', () => {
  const f = fake();
  const first: string[] = [];
  const one = runMargins([{ margin: margin('a') }, { margin: margin('b') }], f.effects, (p) => first.push(p.phase));
  one.stop();
  runMargins([{ margin: margin('a') }, { margin: margin('b') }], f.effects, () => undefined);
  f.pending[0].end(); // the first run's clip ending late
  assert.deepEqual(first, ['margin']);
  assert.deepEqual(f.log, ['play a', 'stop a', 'play a']);
});

test('a line or a Margin that ends at once moves straight on; no voice at all skips the line', () => {
  const log: string[] = [];
  const progress: string[] = [];
  const effects: MarginRunEffects = {
    speak: (text, ended) => {
      log.push(`say ${text}`);
      if (text === 'none') return undefined;
      ended();
      return { stop: () => log.push('late stop') };
    },
    playMargin: (m, hooks) => {
      log.push(`play ${m.id}`);
      hooks.ended();
      return { stop: () => log.push('late stop') };
    },
  };
  const run = runMargins([{ context: 'quick', margin: margin('a') }, { context: 'none', margin: margin('b') }], effects, (p) => progress.push(`${p.index} ${p.phase}`));
  run.stop();
  assert.deepEqual(log, ['say quick', 'play a', 'say none', 'play b']);
  assert.deepEqual(progress, ['0 context', '0 margin', '0 ended', '1 context', '1 margin', '1 ended', '1 done']);
});

test('heard is reported only once a Margin starts sounding', () => {
  const f = fake();
  const started: number[] = [];
  runMargins([{ context: 'ctx', margin: margin('a') }], f.effects, () => undefined, { onStarted: (i) => started.push(i) });
  f.last().end();
  assert.deepEqual(started, [], 'the context line is not the Margin');
  f.last().hooks?.started();
  assert.deepEqual(started, [0]);
});
