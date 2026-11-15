import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Margin } from '../../shared/model.ts';
import { findParent, LOST_PARENT_LINE, threadedRows } from './margin-threads.ts';

const own = (id: string, atSeconds: number, extra: Partial<Margin> = {}): Margin => ({ id, episodeId: 'e', atSeconds, createdAt: `2026-11-1${atSeconds % 10}T10:00:00Z`, text: id, ...extra });
const friend = (id: string, atSeconds: number, extra: Partial<Margin> = {}): Margin => own(id, atSeconds, { author: 'Cole', ...extra });
const order = (margins: Margin[]) => threadedRows(margins).map((r) => `${r.indented ? '  ' : ''}${r.margin.id}`);
const lines = (margins: Margin[]) => Object.fromEntries(threadedRows(margins).map((r) => [r.margin.id, r.line]));

test('Cole’s reply to a Margin she shared sits right under it, found by sharedAs', () => {
  const margins = [own('mine-a', 10, { sharedAs: ['packet:d1:margin-0001'] }), own('mine-b', 30, { sharedAs: ['packet:d1:margin-0002'] }), friend('cole-1', 10, { replyToId: 'packet:d1:margin-0002' })];
  assert.deepEqual(order(margins), ['mine-a', 'mine-b', '  cole-1']);
  assert.equal(lines(margins)['cole-1'], 'Reply to your Margin at 0:30');
  assert.equal(lines(margins)['mine-a'], undefined);
});

test('a reply that matches nothing keeps its own time and says this browser can’t find the Margin', () => {
  const margins = [own('mine-a', 5, { sharedAs: ['packet:d1:margin-0001'] }), friend('cole-1', 10, { replyToId: 'packet:d1:margin-0007' }), own('mine-b', 20)];
  assert.deepEqual(order(margins), ['mine-a', 'cole-1', 'mine-b']);
  assert.equal(lines(margins)['cole-1'], LOST_PARENT_LINE);
});

test('a Margin shared before the web kept the link (no sharedAs) is not matched', () => {
  const margins = [own('mine-a', 5), friend('cole-1', 5, { replyToId: 'packet:d1:margin-0001' })];
  assert.deepEqual(order(margins), ['mine-a', 'cole-1']);
  assert.equal(lines(margins)['cole-1'], LOST_PARENT_LINE);
});

test('her reply to a friend’s Margin sits under it, and her own Margin line is left to rowLine', () => {
  const margins = [friend('packet:d2:margin-0001', 40), own('mine-r', 40, { replyToId: 'packet:d2:margin-0001' }), own('mine-late', 90)];
  assert.deepEqual(order(margins), ['packet:d2:margin-0001', '  mine-r', 'mine-late']);
  assert.equal(lines(margins)['mine-r'], undefined);
});

test('a friend’s Margin answering another friend’s says whose, and a reply to a reply stays in the thread', () => {
  const margins = [friend('packet:d2:margin-0001', 40, { author: 'Sam' }), friend('cole-1', 40, { replyToId: 'packet:d2:margin-0001' }), own('mine-r', 40, { replyToId: 'cole-1' })];
  assert.deepEqual(order(margins), ['packet:d2:margin-0001', '  cole-1', '  mine-r']);
  assert.equal(lines(margins)['cole-1'], 'Reply to Sam’s Margin at 0:40');
});

test('later replies to the same Margin follow in their own time order; Margins with no link are unchanged', () => {
  const margins = [own('mine-a', 10, { sharedAs: ['packet:d1:margin-0001'] }), friend('cole-2', 25, { replyToId: 'packet:d1:margin-0001' }), friend('cole-1', 12, { replyToId: 'packet:d1:margin-0001' }), own('plain', 15)];
  assert.deepEqual(order(margins), ['mine-a', '  cole-1', '  cole-2', 'plain']);
});

test('same-time replies to one Margin are ordered by when they were made, whatever form the date is written in', () => {
  const margins = [
    own('mine-a', 10, { sharedAs: ['packet:d1:margin-0001'] }),
    friend('later', 30, { replyToId: 'packet:d1:margin-0001', createdAt: '2026-11-10T09:30:00Z' }),
    friend('earlier', 30, { replyToId: 'packet:d1:margin-0001', createdAt: '2026-11-10T10:00:00+02:00' }),
  ];
  assert.deepEqual(order(margins), ['mine-a', '  earlier', '  later']);
});

test('a parent on another episode is found for the line but the reply stays at its own time in its own group', () => {
  const elsewhere = own('mine-a', 10, { episodeId: 'other', sharedAs: ['packet:d1:margin-0001'] });
  const reply = friend('cole-1', 30, { replyToId: 'packet:d1:margin-0001' });
  const rows = threadedRows([reply], [elsewhere, reply]);
  assert.deepEqual(rows.map((r) => [r.margin.id, r.indented, r.line]), [['cole-1', false, 'Reply to your Margin at 0:10']]);
});

test('a stopped reply is not a reply: only replyToId threads', () => {
  const margins = [friend('packet:d2:margin-0001', 40), own('mine-r', 50, { formerReplyToId: 'packet:d2:margin-0001' })];
  assert.deepEqual(order(margins), ['packet:d2:margin-0001', 'mine-r']);
});

test('neighbours: a Margin never answers itself, links that loop list each Margin once at its own time, an empty list is empty', () => {
  assert.equal(findParent(own('x', 1, { replyToId: 'x' }), [own('x', 1, { replyToId: 'x' })])?.kind, 'lost');
  const loop = [friend('a', 10, { replyToId: 'b' }), friend('b', 20, { replyToId: 'a' }), own('c', 5)];
  assert.deepEqual(order(loop), ['c', 'a', '  b']);
  const withD = [...loop, friend('d', 40, { replyToId: 'a' })];
  assert.deepEqual(order(withD), ['c', 'a', '  b', '  d']);
  assert.deepEqual(threadedRows([]), []);
});

test('an id match beats a sharedAs match, and a reply link in another case or with spaces is not guessed at', () => {
  const margins = [own('mine-a', 10, { sharedAs: ['packet:d1:margin-0001'] }), friend('packet:d1:margin-0001', 20), friend('cole-1', 20, { replyToId: 'packet:d1:margin-0001' }), friend('cole-2', 30, { replyToId: ' PACKET:d1:margin-0001' })];
  assert.equal(findParent(margins[2], margins)?.kind, 'friends');
  assert.equal(findParent(margins[3], margins)?.kind, 'lost');
});
