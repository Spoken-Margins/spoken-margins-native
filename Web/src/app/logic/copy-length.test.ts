import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import type { Margin } from '../../shared/model.ts';
import { COPY_LENGTH_WORDS, copyLengthDifference, copyLengthNote, withCopyLength } from './copy-length.ts';

interface Row {
  note: string;
  senderMs: number | null;
  listenerMs: number | 'Infinity' | 'NaN' | null;
  expect: 'none' | 'shorter' | 'longer';
  farApart: boolean | null;
  amount: string | null;
}
const cases = JSON.parse(readFileSync(new URL('../../../../Contracts/fixtures/copy-length-note/cases.json', import.meta.url), 'utf8')) as Row[];
const number = (v: Row['listenerMs']): number | null => (v === 'Infinity' ? Infinity : v === 'NaN' ? NaN : v);

test('the shared table of cases has the rows the Design names, and the none rows carry no detail', () => {
  assert.ok(cases.length >= 17);
  for (const row of cases) {
    if (row.expect === 'none') assert.deepEqual([row.farApart, row.amount], [null, null], row.note);
    else assert.ok(typeof row.farApart === 'boolean' && typeof row.amount === 'string', row.note);
  }
});

for (const row of cases) {
  test(`copy length rule: ${row.note}`, () => {
    const got = copyLengthDifference(row.senderMs, number(row.listenerMs));
    if (row.expect === 'none') return assert.equal(got, undefined);
    assert.deepEqual(got, { direction: row.expect, farApart: row.farApart, amount: row.amount });
  });
}

test('the sentences, for a named sender and for "your friend"', () => {
  for (const whose of ['Cole’s', 'your friend’s']) {
    assert.equal(copyLengthNote(1946.018, 1913, whose), `Your copy is about 35 seconds shorter than ${whose}, so Margins may be that far off.`);
    assert.equal(copyLengthNote(1800, 1810, whose), `Your copy is about 10 seconds longer than ${whose}, so Margins may be that far off.`);
    assert.equal(copyLengthNote(1800, 600, whose), `Your copy is about 20 minutes shorter than ${whose}, so Margins may not line up.`);
    assert.equal(copyLengthNote(1800, 2400, whose), `Your copy is about 10 minutes longer than ${whose}, so Margins may not line up.`);
  }
});

test('the sentences name no early or late, and use the curly apostrophe', () => {
  const notes = [copyLengthNote(1946.018, 1913, 'Cole’s'), copyLengthNote(1800, 600, 'Cole’s')] as string[];
  for (const note of notes) {
    assert.doesNotMatch(note, /\b(early|late|earlier|later)\b/);
    assert.doesNotMatch(note, /'/);
  }
});

test('the words table is frozen', () => {
  assert.ok(Object.isFrozen(COPY_LENGTH_WORDS));
});

test('no note when either length is missing, zero, negative or not a number', () => {
  for (const bad of [undefined, null, 0, -5, NaN, Infinity]) {
    assert.equal(copyLengthNote(bad, 1800, 'Cole’s'), undefined, `sender ${bad}`);
    assert.equal(copyLengthNote(1800, bad, 'Cole’s'), undefined, `listener ${bad}`);
  }
});

test('the web\'s fractional seconds become whole milliseconds before the rule runs, so 10.000 s apart is a note and 9.999 s is not', () => {
  assert.ok(copyLengthNote(1800, 1810, 'Cole’s'));
  assert.equal(copyLengthNote(1800, 1809.999, 'Cole’s'), undefined);
  // a float that is 10 s apart in seconds but 9.9999999 in a naive subtraction
  assert.ok(copyLengthNote(1946.018, 1956.018, 'Cole’s'));
});

const margin: Margin = { id: 'm1', episodeId: 'e1', atSeconds: 12, createdAt: '2026-11-22T00:00:00Z', text: 'x' };

test('withCopyLength sets a usable length and leaves the Margin alone otherwise', () => {
  assert.equal(withCopyLength(margin, 1946.018).copyLengthSeconds, 1946.018);
  for (const bad of [undefined, null, 0, -1, NaN, Infinity]) assert.equal(withCopyLength(margin, bad), margin);
  assert.equal('copyLengthSeconds' in margin, false);
});
