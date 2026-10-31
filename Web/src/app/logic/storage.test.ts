import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FailureGate, isQuotaError, lastBackupLine, notSavedMessage, persistNote, shouldAskToPersist, STORAGE_REASONS } from './storage.ts';

test('a full disk is recognised however the browser says it', () => {
  const rows: Array<[unknown, boolean]> = [
    [new DOMException('Quota', 'QuotaExceededError'), true], // Chrome, Safari, Firefox today
    [{ name: 'NS_ERROR_DOM_QUOTA_REACHED' }, true], // older Firefox IndexedDB
    [{ name: 'Error', code: 22 }, true], // older Safari localStorage
    [{ name: 'Error', code: 1014 }, true], // older Firefox
    [new Error('wrapped', { cause: new DOMException('Quota', 'QuotaExceededError') }), true],
    [new DOMException('Aborted', 'AbortError'), false],
    [new DOMException('Gone', 'InvalidStateError'), false],
    [new TypeError('Failed to fetch'), false],
    [null, false],
    [undefined, false],
    ['QuotaExceededError', false],
  ];
  for (const [error, quota] of rows) assert.equal(isQuotaError(error), quota, String((error as { name?: string })?.name ?? error));
});

test('a failed write names what wasn’t saved and why, never just “null”', () => {
  const lead = 'Your Margin at 0:12 wasn’t saved.';
  assert.equal(notSavedMessage(lead, new DOMException('Quota', 'QuotaExceededError')), `${lead} ${STORAGE_REASONS.full}`);
  assert.equal(notSavedMessage(lead, null), `${lead} ${STORAGE_REASONS.refused}`);
  assert.equal(notSavedMessage(lead, new DOMException('x', 'UnknownError')), `${lead} ${STORAGE_REASONS.refused}`);
});

test('a Margin failure is shown every time; a background one once until it works again', () => {
  const gate = new FailureGate();
  assert.equal(gate.failed('margin'), true);
  assert.equal(gate.failed('margin'), true);
  assert.equal(gate.failed('position'), true);
  assert.equal(gate.failed('position'), false, 'your place saves every few seconds: one toast, not one a second');
  assert.equal(gate.failed('setting'), true, 'kinds are gated separately');
  gate.worked('position');
  assert.equal(gate.failed('position'), true, 'after a save works, the next failure is news again');
});

test('persistent storage is asked for after the first saved Margin, once, and never on load', () => {
  assert.equal(shouldAskToPersist('unknown', false, 0), false, 'nothing saved yet: on load');
  assert.equal(shouldAskToPersist('not-kept', false, 0), false);
  assert.equal(shouldAskToPersist('not-kept', false, 1), true);
  assert.equal(shouldAskToPersist('unknown', false, 1), true);
  assert.equal(shouldAskToPersist('not-kept', true, 5), false, 'asked once already');
  assert.equal(shouldAskToPersist('kept', false, 5), false, 'already kept');
  assert.equal(shouldAskToPersist('unsupported', false, 5), false);
});

test('Settings says so only when the browser hasn’t agreed to keep Margins', () => {
  assert.equal(persistNote('kept', true), undefined);
  assert.equal(persistNote('unknown', false), undefined);
  assert.equal(persistNote('not-kept', false), undefined, 'not asked yet: nothing refused');
  assert.match(persistNote('not-kept', true) ?? '', /hasn’t agreed to keep your Margins/);
  assert.match(persistNote('unsupported', false) ?? '', /back them up/);
});

test('the last backup line reads a date, or says there hasn’t been one', () => {
  assert.equal(lastBackupLine(undefined), 'Not backed up yet.');
  assert.equal(lastBackupLine(''), 'Not backed up yet.');
  assert.equal(lastBackupLine('not a date'), 'Not backed up yet.');
  assert.match(lastBackupLine('2026-10-30T21:12:00', 'en-GB'), /^Last backed up 30 Oct 2026, 21:12\.$/);
});
