import assert from 'node:assert/strict';
import { test } from 'node:test';

import { episode } from '../../packet/fixtures.ts';
import { packetMarginId, readPacket } from '../../packet/read.ts';
import { writePacket } from '../../packet/write.ts';
import type { Margin } from '../../shared/model.ts';
import { cueFor } from './arrival.ts';
import {
  allPicked, candidateLabel, friendNames, nothingPickedReason, pickAll, pickedMargins, preselected, replyBackOffer, nowCard, savedFileNextStep,
  savedMarginCard, selectAllLabel, tooManyReason, whyNotShared,
} from './reply-back.ts';

const D1 = 'a'.repeat(64);
const D2 = 'b'.repeat(64);
const ep = 'ep';

const friend = (n: number, digest = D1, author = 'Ana', at = '2026-11-01T10:00:00Z'): Margin =>
  ({ id: packetMarginId(digest, `m${n}`), episodeId: ep, atSeconds: n * 10, createdAt: at, text: `friend ${n}`, author });
const own = (id: string, at: string, extra: Partial<Margin> = {}): Margin =>
  ({ id, episodeId: ep, atSeconds: 5, createdAt: at, text: id, ...extra });
const ids = (list: Margin[]): string[] => list.map((m) => m.id);

test('no Margin of the listener since the friend\'s: no offer', () => {
  assert.equal(replyBackOffer([friend(1), friend(2)]), undefined);
  assert.equal(replyBackOffer([]), undefined);
  // Only the listener's own Margins, no friend: nothing to reply to.
  assert.equal(replyBackOffer([own('x', '2026-11-02T10:00:00Z')]), undefined);
  // A Margin made before the friend's first one is not "new".
  assert.equal(replyBackOffer([friend(1), own('old', '2026-10-01T10:00:00Z')]), undefined);
});

test('replies are picked, other new Margins are offered unpicked unless made since the page opened', () => {
  const reply = own('r', '2026-11-02T10:00:00Z', { replyToId: friend(1).id });
  const other = own('o', '2026-11-02T09:00:00Z');
  const offer = replyBackOffer([friend(1), other, reply]);
  assert.ok(offer);
  assert.deepEqual(ids(offer.replies), ['r']);
  assert.deepEqual(ids(offer.others), ['o']);
  assert.deepEqual(ids(offer.candidates), ['o', 'r']);
  assert.deepEqual([...preselected(offer)], ['r']);
  assert.equal(offer.title, 'Send replies to Ana');
});

test('the friend\'s own Margins are never offered', () => {
  const offer = replyBackOffer([friend(1), friend(2), own('r', '2026-11-02T10:00:00Z', { replyToId: friend(2).id })]);
  assert.ok(offer);
  assert.deepEqual(ids(offer.candidates), ['r']);
  assert.deepEqual(ids(pickedMargins(offer, new Set([friend(1).id, 'r']))), ['r']);
});

test('a reply naming a packet that is not on this episode is only an other-new Margin', () => {
  const offer = replyBackOffer([friend(1), own('r', '2026-11-02T10:00:00Z', { replyToId: packetMarginId(D2, 'zz') })]);
  assert.ok(offer);
  assert.deepEqual(ids(offer.replies), []);
  assert.deepEqual(ids(offer.others), ['r']);
  // With no replies, every friend on the item is named.
  assert.equal(offer.title, 'Send replies to Ana');
});

test('the title names whom the replies answer, in reply order', () => {
  const margins = [
    friend(1, D1, 'Ana'), friend(2, D2, 'Ben'),
    own('r1', '2026-11-02T10:00:00Z', { replyToId: friend(2, D2, 'Ben').id }),
    own('r2', '2026-11-02T11:00:00Z', { replyToId: friend(1, D1, 'Ana').id }),
  ];
  assert.equal(replyBackOffer(margins)?.title, 'Send replies to Ben and Ana');
  // No replies: every friend, oldest first.
  assert.equal(replyBackOffer([friend(2, D2, 'Ben', '2026-11-01T11:00:00Z'), friend(1, D1, 'Ana'), own('o', '2026-11-03T10:00:00Z')])?.title, 'Send replies to Ana and Ben');
});

test('friendNames follows the app: none, one, two, three and more', () => {
  assert.equal(friendNames([]), 'your friend');
  assert.equal(friendNames(['A']), 'A');
  assert.equal(friendNames(['A', 'B']), 'A and B');
  assert.equal(friendNames(['A', 'B', 'C']), 'A, B and 1 other');
  assert.equal(friendNames(['A', 'B', 'C', 'D']), 'A, B and 2 others');
});

test('a friend with no name is "your friend", not a label', () => {
  const offer = replyBackOffer([friend(1, D1, 'Your friend'), own('o', '2026-11-02T10:00:00Z')]);
  assert.equal(offer?.title, 'Send replies to your friend');
  assert.equal(replyBackOffer([friend(1, D1, '  Ana  '), own('o', '2026-11-02T10:00:00Z')])?.title, 'Send replies to Ana');
});

test('an empty pick writes nothing', () => {
  const offer = replyBackOffer([friend(1), own('r', '2026-11-02T10:00:00Z', { replyToId: friend(1).id })]);
  assert.ok(offer);
  assert.deepEqual(pickedMargins(offer, new Set()), []);
});

test('the written packet holds only the picked Margins, and reads back as a reply', async () => {
  const mine = [
    own('r', '2026-11-02T10:00:00Z', { replyToId: friend(1).id, atSeconds: 70 }),
    own('o', '2026-11-02T09:00:00Z', { atSeconds: 30 }),
    own('p', '2026-11-02T11:00:00Z', { atSeconds: 90 }),
  ];
  const offer = replyBackOffer([friend(1), ...mine]);
  assert.ok(offer);
  const written = await writePacket(episode, pickedMargins(offer, new Set(['r', 'p'])), {});
  assert.equal(written.included.length, 2);
  const read = await readPacket(written.bytes);
  assert.deepEqual(read.margins.map((m) => m.text).sort(), ['p', 'r']);
  // The reply keeps its link to the friend's Margin, so Builds 32 and 34 import it as before.
  assert.equal(read.margins.find((m) => m.text === 'r')?.replyToId, friend(1).id);
  assert.equal(read.margins.find((m) => m.text === 'p')?.replyToId, undefined);
});

const SAVED = (who: string) => `Your Margin is saved. Share sends it to ${who}. You pick which of your Margins go.`;
const mine = own('mine', '2026-11-02T10:00:00Z');

test('saved card: an item of the listener\'s own gets nothing', () => {
  assert.equal(savedMarginCard([mine], undefined), undefined);
  assert.equal(savedMarginCard([], undefined), undefined);
});

test('saved card: a friend\'s item after a save says Share sends it to the friend, in the owner\'s words (2026-11-06)', () => {
  const margins = [friend(1), mine];
  assert.deepEqual(savedMarginCard(margins, cueFor(margins, 999, 'Ana')), { sentence: SAVED('Ana') });
  assert.deepEqual(savedMarginCard(margins, undefined), { sentence: SAVED('Ana') });
});

test('saved card: an unnamed sender reads "your friend", as the other cards do', () => {
  const margins = [friend(1, D1, 'your friend'), mine];
  assert.deepEqual(savedMarginCard(margins, undefined), { sentence: SAVED('your friend') });
  const blank = [friend(1, D1, '   '), mine];
  assert.deepEqual(savedMarginCard(blank, undefined), { sentence: SAVED('your friend') });
});

test('saved card: it replaces the after-last card; an episode that can\'t play keeps its own (the countdown is nowCard\'s)', () => {
  const margins = [friend(1), friend(9), mine];
  const countdown = cueFor(margins, 15, 'Ana');
  assert.equal(countdown?.kind, 'countdown');
  assert.deepEqual(savedMarginCard(margins, countdown), { sentence: SAVED('Ana') });
  const after = cueFor(margins, 999, 'Ana');
  assert.equal(after?.kind, 'after-last');
  assert.deepEqual(savedMarginCard(margins, after), { sentence: SAVED('Ana') });
  const failed = cueFor(margins, 15, 'Ana', { failed: true, heardWithoutEpisode: false });
  assert.equal(savedMarginCard(margins, failed), undefined);
});

// #4092: the saved sentence sits on top of the countdown, so Skip does not go missing after the listener's own Margin.
// The friend's Margins are at 10 s and 90 s (see `friend`); the lead-in is the 20 s before a Margin.
test('#4092 now card: after a save the sentence sits above the countdown and its Skip stays', () => {
  const margins = [friend(1), friend(9), mine];
  const rows = [
    { name: 'first Margin 10 s ahead, in its lead-in', time: 0, leadIn: true, skipTo: 9.7 },
    { name: 'next Margin 60 s ahead, outside the lead-in', time: 30, leadIn: false, skipTo: 70 },
  ];
  for (const row of rows) {
    const cue = cueFor(margins, row.time, 'Ana');
    assert.equal(cue?.kind, 'countdown', row.name);
    const card = nowCard(margins, cue, true);
    assert.equal(card.saved, SAVED('Ana'), row.name);
    assert.equal(card.cue, cue, `${row.name}: the countdown and its Skip are kept`);
    assert.equal(card.cue?.kind === 'countdown' && card.cue.leadIn, row.leadIn, row.name);
    assert.equal(card.cue?.kind === 'countdown' && card.cue.skip.to, row.skipTo, row.name);
    assert.deepEqual(nowCard(margins, cue, false), { cue }, `${row.name}: not saved is today's card`);
  }
});

test('#4092 now card: two Skips from the saved card still reach the Margin in two steps (2026-10-31)', () => {
  const margins = [friend(9), mine]; // the friend's Margin at 90 s
  const first = nowCard(margins, cueFor(margins, 0, 'Ana'), true).cue;
  assert.equal(first?.kind, 'countdown');
  if (first?.kind !== 'countdown') return;
  assert.equal(first.skip.to, 70, 'the first Skip lands 20 s before the Margin');
  const second = nowCard(margins, cueFor(margins, first.skip.to, 'Ana'), true).cue;
  assert.equal(second?.kind === 'countdown' && second.leadIn, true);
  assert.ok(second?.kind === 'countdown' && second.skip.to > 89 && second.skip.to <= 90, 'the second lands on the Margin, never past it');
});

test('#4092 now card: after the last Margin the sentence is alone; an episode that can\'t play keeps its card; no cue is the sentence alone', () => {
  const margins = [friend(1), mine];
  const after = cueFor(margins, 999, 'Ana');
  assert.equal(after?.kind, 'after-last');
  assert.deepEqual(nowCard(margins, after, true), { saved: SAVED('Ana') });
  assert.deepEqual(nowCard(margins, after, false), { cue: after });
  const failed = cueFor(margins, 15, 'Ana', { failed: true, heardWithoutEpisode: false });
  assert.deepEqual(nowCard(margins, failed, true), { cue: failed });
  assert.deepEqual(nowCard(margins, undefined, true), { saved: SAVED('Ana') });
  assert.deepEqual(nowCard([mine], undefined, true), { cue: undefined }, 'an item of the listener\'s own gets nothing');
});

test('#3784: a Margin made since the page opened starts ticked, so Send is not greyed out; an older private note does not', () => {
  const opened = Date.parse('2026-11-03T09:00:00Z');
  const old = own('private', '2026-11-01T10:00:00Z'); // after the friend's Margins, before the page opened
  const mine = own('mine', '2026-11-03T09:30:00Z');
  const offer = replyBackOffer([friend(1, D1, 'Ana', '2026-10-30T10:00:00Z'), old, mine]);
  assert.ok(offer);
  assert.deepEqual(ids(offer.replies), []);
  assert.deepEqual([...preselected(offer, opened)], ['mine']);
  assert.deepEqual(ids(pickedMargins(offer, preselected(offer, opened))), ['mine']);
  assert.equal(nothingPickedReason(offer, 1), undefined);
  // With no page time, nothing but replies is ticked (the app's rule), so a private note is never ticked by accident.
  assert.deepEqual([...preselected(offer)], []);
  // The friend's own Margins are never offered, ticked or not.
  assert.ok(!offer.candidates.some((m) => m.author));
});

test('#3784: greyed buttons give a reason, and only when nothing is picked', () => {
  const offer = replyBackOffer([friend(1), own('mine', '2026-11-02T10:00:00Z')]);
  assert.match(nothingPickedReason(offer, 0) ?? '', /Tick at least one Margin/);
  assert.match(nothingPickedReason(undefined, 0) ?? '', /nothing to share/);
  assert.equal(nothingPickedReason(offer, 1), undefined);
  assert.equal(nothingPickedReason(undefined, 3), undefined);
});

test('#3784: after saving the file, the listener is told to send it, naming the friend', () => {
  const ana = replyBackOffer([friend(1), own('mine', '2026-11-02T10:00:00Z')]);
  assert.equal(savedFileNextStep(ana), 'Send this file to Ana in a message.');
  const two = replyBackOffer([friend(1, D1, 'Ana'), friend(2, D2, 'Ben'), own('mine', '2026-11-02T10:00:00Z')]);
  assert.equal(savedFileNextStep(two), 'Send this file to Ana and Ben in a message.');
  // A friend with no name is "your friend", never an empty hole in the sentence.
  const unnamed = replyBackOffer([{ ...friend(1), author: ' ' }, own('mine', '2026-11-02T10:00:00Z')]);
  assert.equal(savedFileNextStep(unnamed), 'Send this file to your friend in a message.');
});

test('#3784: a voice Margin row never reads "0:00"', () => {
  const clock = (s: number) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
  const voice = (seconds: number | undefined): Margin => ({
    ...own('v', '2026-11-02T10:00:00Z'),
    text: undefined,
    ...(seconds === undefined ? {} : { voice: { durationSeconds: seconds } as NonNullable<Margin['voice']> }),
  });
  assert.equal(candidateLabel(voice(0), clock), 'Voice Margin');
  assert.equal(candidateLabel(voice(undefined), clock), 'Voice Margin');
  assert.equal(candidateLabel(voice(75), clock), 'Voice Margin, 1:15');
  assert.equal(candidateLabel(own('t', '2026-11-02T10:00:00Z', { text: 'my words' }), clock), 'my words');
});

// #4093: one button ticks every listed Margin, and unticks them when all are ticked. The panel merges `pickAll` over its
// starting picks (`changed` over `preselected`), so these tests do the same.
const ticks = (offer: NonNullable<ReturnType<typeof replyBackOffer>>, changed: Record<string, boolean>): Set<string> => {
  const starting = preselected(offer);
  return new Set(offer.candidates.map((m) => m.id).filter((id) => changed[id] ?? starting.has(id)));
};
const manyOwn = (count: number, replies: number): Margin[] =>
  Array.from({ length: count }, (_, i) => own(`m${i}`, '2026-11-02T10:00:00Z', i < replies ? { replyToId: friend(1).id } : {}));

test('#4093 select all: all, then untick one, then the label reads right, then all again', () => {
  const offer = replyBackOffer([friend(1), ...manyOwn(4, 2)]); // two replies ticked, two older notes unticked
  assert.ok(offer);
  assert.equal(offer.candidates.length, 4);
  let changed: Record<string, boolean> = {};
  assert.equal(allPicked(offer.candidates, ticks(offer, changed)), false);
  assert.equal(selectAllLabel(allPicked(offer.candidates, ticks(offer, changed))), 'Select all', 'older notes are unticked by default');
  // Select all ticks the older notes too, as the listener's own act.
  changed = { ...changed, ...pickAll(offer.candidates, !allPicked(offer.candidates, ticks(offer, changed))) };
  assert.deepEqual(ids(pickedMargins(offer, ticks(offer, changed))), ids(offer.candidates));
  assert.equal(selectAllLabel(allPicked(offer.candidates, ticks(offer, changed))), 'Select none');
  // Untick one: the next tap is "Select all" again.
  changed = { ...changed, m3: false };
  assert.equal(selectAllLabel(allPicked(offer.candidates, ticks(offer, changed))), 'Select all');
  assert.equal(pickedMargins(offer, ticks(offer, changed)).length, 3);
  // Select all again ticks the one back; Select none then clears the list.
  changed = { ...changed, ...pickAll(offer.candidates, !allPicked(offer.candidates, ticks(offer, changed))) };
  assert.equal(allPicked(offer.candidates, ticks(offer, changed)), true);
  changed = { ...changed, ...pickAll(offer.candidates, !allPicked(offer.candidates, ticks(offer, changed))) };
  assert.equal(pickedMargins(offer, ticks(offer, changed)).length, 0);
  assert.equal(whyNotShared(offer, 0), nothingPickedReason(offer, 0));
});

test('#4093 select all: first-run reads "Select none"; a double tap ends where it began (burst)', () => {
  const offer = replyBackOffer([friend(1), ...manyOwn(3, 3)]); // three replies, all ticked by default
  assert.ok(offer);
  const start = ticks(offer, {});
  assert.equal(selectAllLabel(allPicked(offer.candidates, start)), 'Select none');
  const tap = (changed: Record<string, boolean>) => ({ ...changed, ...pickAll(offer.candidates, !allPicked(offer.candidates, ticks(offer, changed))) });
  const twice = tap(tap({}));
  assert.deepEqual([...ticks(offer, twice)].sort(), [...start].sort());
});

test('#4093 select all: never ticks the friend\'s Margins, and an empty list is never "all picked"', () => {
  const offer = replyBackOffer([friend(1), friend(2), ...manyOwn(2, 1)]);
  assert.ok(offer);
  const all = pickAll(offer.candidates, true);
  assert.deepEqual(Object.keys(all).sort(), ids(offer.candidates).sort());
  assert.ok(!(friend(1).id in all) && !(friend(2).id in all));
  assert.deepEqual(ids(pickedMargins(offer, new Set(Object.keys(all)))), ids(offer.candidates));
  assert.equal(allPicked([], new Set()), false);
  assert.deepEqual(pickAll([], true), {});
});

test('#4093 more than 50 ticked: the writer\'s sentence is said before the tap; with no list nothing greys', () => {
  const offer = replyBackOffer([friend(1), ...manyOwn(51, 51)]);
  assert.ok(offer);
  assert.equal(offer.candidates.length, 51);
  const sentence = 'Spoken Margins shares up to 50 Margins at a time. Pick fewer, then share again.';
  assert.equal(tooManyReason(51), sentence);
  assert.equal(tooManyReason(50), undefined);
  assert.equal(tooManyReason(0), undefined);
  assert.equal(whyNotShared(offer, 51), sentence, 'select all on 51 candidates');
  assert.equal(whyNotShared(offer, 50), undefined);
  assert.equal(whyNotShared(offer, 0), 'Tick at least one Margin above to send it.', 'nothing ticked keeps its sentence');
  // No offer (nothing to untick): the writer's error toast stays the only notice.
  assert.equal(whyNotShared(undefined, 51), undefined);
  assert.equal(whyNotShared(undefined, 0), 'There is nothing to share yet.');
});

test('#4093 the writer refuses 51 Margins with the very sentence the panel shows', async () => {
  const margins = Array.from({ length: 51 }, (_, i) => ({ id: `w${i}`, episodeId: ep, atSeconds: i, createdAt: '2026-11-02T10:00:00Z', text: `w${i}` }));
  await assert.rejects(writePacket(episode, margins), (error: Error) => {
    assert.equal(error.message, tooManyReason(51));
    return true;
  });
});
