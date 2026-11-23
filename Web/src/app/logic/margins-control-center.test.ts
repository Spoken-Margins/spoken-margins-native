// Runs every case in Contracts/fixtures/margins-control-center/cases.json (part of #3216) through the web port, as
// SessionKit's MarginsControlCenterCasesTests does, so both follow one set of rules.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import type { Margin } from '../../shared/model.ts';

interface CaseMargin {
  id: string;
  sender: string;
  parentId: string | null;
  timeMs: number | null;
  listenedMs: number;
  words: string | null;
  starred: boolean;
  sourceTextBefore: string | null;
}
interface Case {
  id: string;
  rule: string;
  input: { autoplay: 'unheard' | 'all' | 'none'; playheadMs: number; margins: CaseMargin[] };
  expected: {
    rows: Array<Record<string, unknown>>;
    nextMargin: Record<string, unknown> | null;
    unheardCount: number;
    opensOnMarginsTab: boolean;
    startWithUnheardMs: number | null;
  };
}

const file = JSON.parse(readFileSync(new URL('../../../../Contracts/fixtures/margins-control-center/cases.json', import.meta.url), 'utf8')) as {
  constants: Record<string, unknown>;
  labels: Record<string, unknown>;
  cases: Case[];
};
// The build hands the module these two parts (vite.config.ts); here the test does.
(globalThis as Record<string, unknown>).marginsControlCenterWords = { constants: file.constants, labels: file.labels };
const mcc = await import('./margins-control-center.ts');

test('the cases file has the cases, each with a unique id', () => {
  assert.equal(file.cases.length, 29);
  assert.equal(new Set(file.cases.map((c) => c.id)).size, file.cases.length);
});

test('the words and constants are the cases file’s own', () => {
  assert.deepEqual(mcc.CONSTANTS, file.constants);
  assert.deepEqual(mcc.LABELS, file.labels);
  assert.equal(mcc.LEAD_IN_MS, 20_000);
  assert.deepEqual(mcc.AUTOPLAY_CHOICES.map(mcc.autoplayTitle), ['Unheard Margins', 'All Margins', 'Off']);
});

const ownSender = file.constants.ownSender as string;
const centerOf = (c: Case) =>
  c.input.margins.map((m) => ({
    id: m.id,
    own: m.sender === ownSender,
    sender: m.sender,
    parentId: m.parentId,
    timeMs: m.timeMs,
    heard: m.listenedMs > 0,
    words: m.words,
    starred: m.starred,
    sourceTextBefore: m.sourceTextBefore,
  }));

for (const item of file.cases) {
  test(`case ${item.id} (${item.rule})`, () => {
    const autoplay = item.input.autoplay;
    const rows = mcc.rows(centerOf(item));
    const actual = rows.map((r) => ({
      id: r.id,
      depth: r.depth,
      sender: r.sender,
      hearing: r.hearing,
      words: r.words,
      wordsComing: mcc.wordsComing(r),
      leadIn: r.leadIn,
      timeMs: r.timeMs,
      startHereMs: r.startHereMs,
      starred: r.starred,
      note: r.note,
      arrival: mcc.arrival(r, autoplay),
    }));
    assert.deepEqual(actual, item.expected.rows, 'rows');
    const next = mcc.nextMargin(item.input.playheadMs, rows, autoplay);
    const shown = next && {
      marginTimeMs: next.marginTimeMs,
      leadInStartMs: next.leadInStartMs,
      msUntilMargin: next.msUntilMargin,
      action: next.action,
      destinationMs: next.destinationMs,
      countdown: next.countdown,
      firstToPlayId: next.firstToPlayId,
    };
    assert.deepEqual(shown, item.expected.nextMargin, 'nextMargin');
    assert.equal(mcc.unheardCount(rows), item.expected.unheardCount, 'unheardCount');
    assert.equal(mcc.opensOnMarginsTab(rows), item.expected.opensOnMarginsTab, 'opensOnMarginsTab');
    assert.equal(mcc.startWithUnheardMs(rows), item.expected.startWithUnheardMs, 'startWithUnheardMs');
  });
}

// ---------- The web's own Margins in that shape ----------

const margin = (fields: Partial<Margin> & Pick<Margin, 'id' | 'atSeconds'>): Margin => ({ episodeId: 'e', createdAt: '2026-11-17T10:00:00Z', ...fields });

test('web Margins: own and friend’s, heard, a reply found by sharedAs, a lost link, placeholder words', () => {
  const margins = [
    margin({ id: 'own', atSeconds: 190, createdAt: '2026-11-17T10:00:00Z', text: 'Mine.', sharedAs: ['packet:aa:margin-0001'], starred: true }),
    margin({ id: 'sam-reply', atSeconds: 200, createdAt: '2026-11-17T10:01:00Z', author: 'Sam', text: 'Reply.', replyToId: 'packet:aa:margin-0001', leadIn: 'by   Friday their\nreaction times' }),
    margin({ id: 'rae', atSeconds: 100, createdAt: '2026-11-17T10:02:00Z', author: 'Rae', text: 'Heard one.', heard: true }),
    margin({ id: 'lost', atSeconds: 300, createdAt: '2026-11-17T10:03:00Z', author: 'Sam', text: 'Lost.', replyToId: 'packet:zz:margin-0009' }),
    margin({ id: 'words-coming', atSeconds: 465, createdAt: '2026-11-17T10:04:00Z', author: 'Sam', text: 'Voice Margin at 7:45 in “UI Test Episode”, recorded 12 Nov 2026' }),
  ];
  const rows = mcc.marginRows(margins);
  assert.deepEqual(rows.map((r) => [r.id, r.depth, r.sender, r.hearing]), [
    ['rae', 0, 'Rae', 'heard'],
    ['own', 0, 'you', 'yours'],
    ['sam-reply', 1, 'Sam', 'unheard'],
    ['lost', 0, 'Sam', 'unheard'],
    ['words-coming', 0, 'Sam', 'unheard'],
  ]);
  assert.equal(rows[1].starred, true);
  assert.equal(rows[2].parentId, 'own');
  assert.equal(rows[2].leadIn, 'by Friday their reaction times');
  assert.equal(rows[3].note, file.constants.missingParentNote);
  assert.equal(rows[4].words, null);
  // Under Unheard the 3:10 thread starts with Sam's unheard reply, after its lead-in.
  const next = mcc.nextMargin(150_000, rows, 'unheard');
  assert.equal(next?.firstToPlayId, 'sam-reply');
  assert.equal(next?.destinationMs, 170_000);
  assert.equal(mcc.startWithUnheardMs(rows), 170_000);
});

test('the play queue: the chosen Margin, then the rest of its thread Autoplay would play', () => {
  const rows = mcc.rows([
    { id: 'a', own: true, sender: 'you', parentId: null, timeMs: 10_000, heard: false, words: 'a', starred: false, sourceTextBefore: null },
    { id: 'b', own: false, sender: 'Sam', parentId: 'a', timeMs: 11_000, heard: false, words: 'b', starred: false, sourceTextBefore: null },
    { id: 'c', own: true, sender: 'you', parentId: 'b', timeMs: 12_000, heard: false, words: 'c', starred: false, sourceTextBefore: null },
    { id: 'd', own: false, sender: 'Sam', parentId: 'c', timeMs: 13_000, heard: true, words: 'd', starred: false, sourceTextBefore: null },
  ]);
  assert.deepEqual(mcc.playQueue(rows, 'a', 'unheard'), ['a', 'b']);
  assert.deepEqual(mcc.playQueue(rows, 'a', 'all'), ['a', 'b', 'c', 'd']);
  assert.deepEqual(mcc.playQueue(rows, 'c', 'none'), ['c']);
  assert.deepEqual(mcc.playQueue(rows, 'x', 'all'), []);
});

test('a tapped start waits for its Margin, plays on reaching it, and is dropped once playback is well past it', () => {
  assert.equal(mcc.pendingStart(100, 80), 'wait');
  assert.equal(mcc.pendingStart(100, 100), 'play');
  assert.equal(mcc.pendingStart(100, 100.3), 'play');
  assert.equal(mcc.pendingStart(100, 103), 'play');
  assert.equal(mcc.pendingStart(100, 103.1), 'drop');
});

test('a tapped start is left behind by any seek but its own (audit 5 on #4505)', () => {
  // "Jump to this Margin" at 10:00 moves to its lead-in at 9:40; that seek keeps the start, as its browser may round it.
  assert.equal(mcc.startSurvivesSeek(580, 580), true);
  assert.equal(mcc.startSurvivesSeek(580, 580.3), true);
  // The listener then scrubs back to 2:00, or a little way on: the Margin must not play by itself eight minutes later.
  assert.equal(mcc.startSurvivesSeek(580, 120), false);
  assert.equal(mcc.startSurvivesSeek(580, 595), false);
});

test('a row’s start control goes to its lead-in, or straight in from inside the lead-in, never back', () => {
  const rows = mcc.rows([
    { id: 'a', own: false, sender: 'Sam', parentId: null, timeMs: 60_000, heard: false, words: 'a', starred: false, sourceTextBefore: null },
    { id: 'b', own: true, sender: 'you', parentId: 'a', timeMs: 70_000, heard: false, words: 'b', starred: false, sourceTextBefore: null },
  ]);
  assert.deepEqual(mcc.startFor(rows[0], rows, 'unheard', 10_000), { seekToMs: 40_000, atMs: 60_000, queue: ['a'] });
  assert.deepEqual(mcc.startFor(rows[0], rows, 'all', 50_000), { seekToMs: 60_000, atMs: 60_000, queue: ['a', 'b'] });
  // Behind the playhead: back to its lead-in.
  assert.deepEqual(mcc.startFor(rows[0], rows, 'unheard', 300_000), { seekToMs: 40_000, atMs: 60_000, queue: ['a'] });
  // A reply goes to its own lead-in, and plays even though Autoplay wouldn't play your own.
  assert.deepEqual(mcc.startFor(rows[1], rows, 'unheard', 0), { seekToMs: 50_000, atMs: 70_000, queue: ['b'] });
});

test('hearing of a web Margin: yours, heard, unheard', () => {
  const base = { episodeId: 'e', atSeconds: 1, createdAt: '2026-11-17T10:00:00Z' };
  assert.equal(mcc.hearingOf({ ...base, id: 'o' }), 'yours');
  assert.equal(mcc.hearingOf({ ...base, id: 'h', author: 'Sam', heard: true }), 'heard');
  assert.equal(mcc.hearingOf({ ...base, id: 'u', author: 'Sam' }), 'unheard');
});
