import { test } from 'node:test';
import assert from 'node:assert/strict';
import { close, expired, pause, remainingMs, resume, start, toastMs } from './toast-timer.ts';

test('a plain toast lasts 6 s and one with an action 10 s', () => {
  assert.equal(toastMs(false), 6000);
  assert.equal(toastMs(true), 10000);
});

test('expires at 6 s, not before', () => {
  const t = start(toastMs(false), 1000);
  assert.equal(expired(t, 1000 + 5999).fire, false);
  assert.equal(expired(t, 1000 + 6000).fire, true);
});

test('expires at 10 s with an action, not at 6 s', () => {
  const t = start(toastMs(true), 0);
  assert.equal(expired(t, 6000).fire, false);
  assert.equal(expired(t, 9999).fire, false);
  assert.equal(expired(t, 10000).fire, true);
});

test('a pause at 4 s and a resume 20 s later still has 6 s left', () => {
  let t = start(10000, 0);
  t = pause(t, 4000);
  assert.equal(remainingMs(t, 24000), 6000);
  assert.equal(expired(t, 24000 + 100000).fire, false, 'paused never expires');
  t = resume(t, 24000);
  assert.equal(remainingMs(t, 24000), 6000);
  assert.equal(expired(t, 24000 + 5999).fire, false);
  assert.equal(expired(t, 24000 + 6000).fire, true);
});

test('pausing twice, or resuming a running timer, changes nothing', () => {
  const running = start(10000, 0);
  assert.equal(resume(running, 3000), running);
  const paused = pause(running, 4000);
  assert.equal(pause(paused, 9000), paused);
  assert.equal(remainingMs(paused, 9000), 6000);
});

test('several pauses add up what was spent', () => {
  let t = start(10000, 0);
  t = pause(t, 3000);
  t = resume(t, 10000);
  t = pause(t, 15000);
  assert.equal(remainingMs(t, 99999), 2000);
});

test('fires once, and not after close', () => {
  const t = start(6000, 0);
  const first = expired(t, 6000);
  assert.equal(first.fire, true);
  assert.equal(expired(first.timer, 7000).fire, false);
  assert.equal(expired(close(t), 60000).fire, false);
});

test('a pause or resume after close is a no-op', () => {
  const closed = close(start(6000, 0));
  assert.equal(pause(closed, 1000), closed);
  assert.equal(resume(closed, 1000), closed);
});
