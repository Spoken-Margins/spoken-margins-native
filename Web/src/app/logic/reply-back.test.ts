import assert from 'node:assert/strict';
import { test } from 'node:test';

import { episode } from '../../packet/fixtures.ts';
import { packetMarginId, readPacket } from '../../packet/read.ts';
import { writePacket } from '../../packet/write.ts';
import type { Margin } from '../../shared/model.ts';
import { friendNames, pickedMargins, preselected, replyBackOffer } from './reply-back.ts';

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

test('replies are picked, other new Margins are offered unpicked', () => {
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
