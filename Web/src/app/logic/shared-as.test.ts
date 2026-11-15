import assert from 'node:assert/strict';
import { test } from 'node:test';

import { episode, writtenMargins } from '../../packet/fixtures.ts';
import { packetMarginId, readPacket } from '../../packet/read.ts';
import { writePacket } from '../../packet/write.ts';
import { keepingSharedAs, withSharedAs } from './shared-as.ts';

test('each Margin written is stored with the id its packet gives it back, which is what a friend\'s reply names', async () => {
  const [first, second] = writtenMargins();
  const written = await writePacket(episode, [first, second]);
  const stamped = withSharedAs(written, [first, second]);
  assert.equal(stamped.length, 2);
  assert.deepEqual(stamped[0].sharedAs, [packetMarginId(written.contentDigest, 'margin-0001')]);
  assert.deepEqual(stamped[1].sharedAs, [packetMarginId(written.contentDigest, 'margin-0002')]);
  // The ids the same packet has when a friend imports it: a reply to her second Margin carries exactly this.
  const imported = await readPacket(written.bytes);
  assert.deepEqual(imported.margins.map((m) => m.id), stamped.map((m) => m.sharedAs?.[0]));
});

test('the position in the file decides the name, not the position in the list handed over', async () => {
  const [first, second] = writtenMargins();
  const written = await writePacket(episode, [second, first]);
  assert.equal(written.included.length, 2);
  const stamped = withSharedAs(written, [first, second]);
  const link = (id: string) => stamped.find((m) => m.id === id)?.sharedAs?.[0];
  assert.equal(link(written.included[0]), packetMarginId(written.contentDigest, 'margin-0001'));
  assert.equal(link(written.included[1]), packetMarginId(written.contentDigest, 'margin-0002'));
});

test('a Margin left out of the file, or not held any more, gets nothing', async () => {
  const [first, second] = writtenMargins();
  const written = await writePacket(episode, [first]);
  assert.deepEqual(withSharedAs(written, [first, second]).map((m) => m.id), [first.id]);
  assert.deepEqual(withSharedAs(written, [second]), []);
});

test('sharing again adds the new link and keeps the old; the same file twice adds nothing', async () => {
  const [first] = writtenMargins();
  const once = await writePacket(episode, [first]);
  const [afterOnce] = withSharedAs(once, [first]);
  assert.deepEqual(withSharedAs(once, [afterOnce]), [], 'the same packet again');
  const twice = await writePacket(episode, [afterOnce, { ...writtenMargins()[1], id: 'later' }]);
  const [afterTwice] = withSharedAs(twice, [afterOnce, { ...writtenMargins()[1], id: 'later' }]);
  assert.equal(afterTwice.sharedAs?.length, 2);
  assert.equal(afterTwice.sharedAs?.[0], afterOnce.sharedAs?.[0]);
});

test('a Margin the listener never shared has no sharedAs, and writing a packet never puts it in the file', async () => {
  const [first] = writtenMargins();
  const stamped = withSharedAs(await writePacket(episode, [first]), [first])[0];
  const read = await readPacket((await writePacket(episode, [stamped])).bytes);
  assert.equal(JSON.stringify(read).includes('sharedAs'), false);
  assert.equal(first.sharedAs, undefined);
});

test('a Margin written again from an older copy keeps the packets it was shared in since', async () => {
  const [first] = writtenMargins();
  const stored = withSharedAs(await writePacket(episode, [first]), [first])[0];
  // The voice composer's own copy, from before the share, written again when its words arrive.
  const older = { ...first, text: 'Words that arrived later.' };
  const kept = keepingSharedAs(older, stored);
  assert.deepEqual(kept.sharedAs, stored.sharedAs);
  assert.equal(kept.text, 'Words that arrived later.');
  // A copy that already carries the links, or a stored one with none, is returned as it is.
  assert.equal(keepingSharedAs(stored, stored), stored);
  assert.equal(keepingSharedAs(older, first), older);
  assert.equal(keepingSharedAs(older, undefined), older);
  // Links only the copy has are kept too, none twice.
  const other = { ...older, sharedAs: ['packet:x:margin-0009', ...(stored.sharedAs ?? [])] };
  assert.deepEqual([...(keepingSharedAs(other, stored).sharedAs ?? [])].sort(), [...(stored.sharedAs ?? []), 'packet:x:margin-0009'].sort());
});

test('stamping reads the Margins as stored now: an edit made while the file was written is kept', async () => {
  const [first] = writtenMargins();
  const written = await writePacket(episode, [first]);
  const editedMeanwhile = { ...first, text: 'Edited while the file was being written.' };
  const [stamped] = withSharedAs(written, [editedMeanwhile]);
  assert.equal(stamped.text, 'Edited while the file was being written.');
  assert.equal(stamped.sharedAs?.length, 1);
  // One deleted meanwhile is no longer held, so it comes back as nothing rather than as a Margin.
  assert.deepEqual(withSharedAs(written, []), []);
});
