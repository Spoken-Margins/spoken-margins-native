import assert from 'node:assert/strict';
import { test } from 'node:test';

import type { Margin } from '../../shared/model.ts';
import { replyBackOffer } from './reply-back.ts';
import { senderForPacket, senderNameHint, sendFile, sendRefusedNextStep } from './share-send.ts';

const file = new File([new Uint8Array([1, 2, 3])], 'Margins.spokenmargins', { type: 'application/vnd.spokenmargins.package+zip' });
const failing = (name: string, message = '') => async (): Promise<void> => {
  throw Object.assign(new Error(message), { name });
};

test('#4095: a share the browser takes is shared, with the file and the title', async () => {
  let seen: { files: File[]; title: string } | undefined;
  const outcome = await sendFile(async (data) => { seen = data; }, file, 'An episode');
  assert.equal(outcome, 'shared');
  assert.deepEqual(seen?.files, [file]);
  assert.equal(seen?.title, 'An episode');
});

test('#4095: closing the share sheet is a cancel, not a failure', async () => {
  assert.equal(await sendFile(failing('AbortError', 'Share canceled'), file, 'x'), 'cancelled');
});

test('#4095: whatever the browser refuses with, the outcome is refused, so the listener never reads its words', async () => {
  for (const [name, message] of [
    ['NotAllowedError', 'Permission denied'],
    ['NotAllowedError', 'Share must be triggered by "user activation".'],
    ['SecurityError', 'The request is not allowed by the user agent'],
    ['TypeError', 'Failed to execute \'share\' on \'Navigator\': Invalid file name or type'],
    ['DataError', 'Data is not valid'],
    ['Error', ''],
  ]) {
    assert.equal(await sendFile(failing(name, message), file, 'x'), 'refused', `${name}: ${message}`);
  }
  // A thrown string or null is not an AbortError either.
  assert.equal(await sendFile(async () => { throw 'nope'; }, file, 'x'), 'refused');
  assert.equal(await sendFile(async () => { throw null; }, file, 'x'), 'refused');
});

test('#4095: the refusal sentence names the next step, never the error', () => {
  const friend: Margin = { id: 'f', episodeId: 'ep', atSeconds: 1, createdAt: '2026-11-01T10:00:00Z', text: 'hi', author: 'Ana' };
  const mine: Margin = { id: 'm', episodeId: 'ep', atSeconds: 2, createdAt: '2026-11-02T10:00:00Z', text: 'reply' };
  const offer = replyBackOffer([friend, mine]);
  assert.ok(offer);
  assert.equal(
    sendRefusedNextStep(offer),
    'This browser wouldn’t open its share sheet. Tap Save as a file, then send the file to Ana in a message.',
  );
  assert.equal(
    sendRefusedNextStep(undefined),
    'This browser wouldn’t open its share sheet. Tap Save as a file, then send the file in a message.',
  );
  for (const sentence of [sendRefusedNextStep(offer), sendRefusedNextStep(undefined)]) assert.doesNotMatch(sentence, /denied|NotAllowed|permission/i);
});

test('#4107: the typed name goes on the file trimmed, and a blank one signs nothing', () => {
  const rows: [string, string | undefined][] = [
    ['Sam', 'Sam'],
    ['  Sam  ', 'Sam'],
    ['\tSam\n', 'Sam'],
    ['Sam Rivera', 'Sam Rivera'],
    ['  Sam   Rivera ', 'Sam   Rivera'],
    ['Zoë', 'Zoë'],
    ['Zoe\u0301', 'Zoe\u0301'],
    ['山田', '山田'],
    ['', undefined],
    ['   ', undefined],
    ['\n\t ', undefined],
  ];
  for (const [typed, sent] of rows) assert.equal(senderForPacket(typed), sent, JSON.stringify(typed));
});

test('#4107: the name field says who it is for, as the rest of Share names them', () => {
  const kept = 'Kept in this browser.';
  assert.equal(senderNameHint([]), `So your friend knows who these are from. ${kept}`);
  assert.equal(senderNameHint(['Cole']), `So Cole knows who these are from. ${kept}`);
  assert.equal(senderNameHint(['Cole', 'Sam']), `So Cole and Sam know who these are from. ${kept}`);
  assert.equal(senderNameHint(['Cole', 'Sam', 'Ada']), `So Cole, Sam and 1 other know who these are from. ${kept}`);
});
