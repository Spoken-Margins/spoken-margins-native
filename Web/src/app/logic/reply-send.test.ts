import assert from 'node:assert/strict';
import { test } from 'node:test';

import type { Margin } from '../../shared/model.ts';
import {
  REPLY_SEND_WORDS, everythingSent, failureLine, fileInsteadLabel, forgetTicks, isSent, keepingSentThrough, replyCaption, savedCardWithBox,
  sendToLabel, sendsThroughLink, sentLine, splitForLink, withSentThrough, withoutSent,
} from './reply-send.ts';

const margin = (id: string, extra: Partial<Margin> = {}): Margin =>
  ({ id, episodeId: 'ep', atSeconds: 5, createdAt: '2026-11-26T10:00:00Z', text: id, ...extra });

test('Screen B words with a sender’s name and without one', () => {
  assert.equal(replyCaption('Cole'), 'They go back through this link. Only Cole can hear them.');
  assert.equal(replyCaption(undefined), 'They go back through this link. Only the person who sent it can hear them.');
  assert.equal(sendToLabel('Cole'), 'Send to Cole');
  assert.equal(sendToLabel(undefined), 'Send to your friend');
  assert.equal(sentLine('Cole'), 'Sent to Cole. They’ll get it the next time they open Spoken Margins.');
  assert.equal(sentLine(undefined), 'Sent. Your friend gets it the next time they open Spoken Margins.');
  assert.equal(savedCardWithBox('Cole'), 'Your Margin is saved. Send to Cole sends it back. You pick which of your Margins go.');
  assert.equal(REPLY_SEND_WORDS.sending, 'Sending…');
  assert.equal(REPLY_SEND_WORDS.allSent, 'Everything here has been sent.');
});

test('the file button under its "instead" name, for each of today’s three', () => {
  assert.equal(fileInsteadLabel('send'), 'Send as a file instead');
  assert.equal(fileInsteadLabel('save'), 'Save as a file instead');
  assert.equal(fileInsteadLabel('native'), 'Save or send instead');
});

test('each error row’s line', () => {
  assert.equal(failureLine('ended', 'Cole'), 'This link can’t take answers any more. Send them to Cole as a file instead.');
  assert.equal(failureLine('ended', undefined), 'This link can’t take answers any more. Send them to your friend as a file instead.');
  assert.equal(failureLine('too-big', 'Cole'), 'These are too big to send through the link. Untick a long recording, or send them as a file.');
  assert.equal(failureLine('retry', 'Cole'), 'Couldn’t send. Check your connection, then try again.');
});

test('markSentThrough’s rows: the Margins as stored, each marked once, a deleted one left out', () => {
  const a = margin('a', { starred: true } as Partial<Margin>);
  const b = margin('b', { sentThrough: 'link1' });
  const marked = withSentThrough(['a', 'b', 'gone', 'a'], 'link1', [a, b]);
  assert.deepEqual(marked.map((m) => [m.id, m.sentThrough]), [['a', 'link1']]);
  assert.equal((marked[0] as Margin & { starred?: boolean }).starred, true, 'built from the stored Margin, so nothing else is lost');
  // Through another link, it is marked again with that link.
  assert.deepEqual(withSentThrough(['b'], 'link2', [b]).map((m) => m.sentThrough), ['link2']);
});

test('a rewritten Margin keeps the stored sentThrough, as sharedAs does', () => {
  const stored = margin('a', { sentThrough: 'link1' });
  const rewrite = margin('a', { text: 'the words arrived' });
  assert.equal(keepingSentThrough(rewrite, stored).sentThrough, 'link1');
  assert.equal(keepingSentThrough(rewrite, stored).text, 'the words arrived');
  assert.equal(keepingSentThrough(rewrite, undefined), rewrite);
  assert.equal(keepingSentThrough(rewrite, margin('a')), rewrite);
  const newer = margin('a', { sentThrough: 'link2' });
  assert.equal(keepingSentThrough(newer, stored).sentThrough, 'link2');
});

test('sent rows start unticked; a later Margin starts ticked; everything sent says so', () => {
  const sent = margin('s', { sentThrough: 'link1' });
  const fresh = margin('f');
  assert.equal(isSent(sent), true);
  assert.equal(isSent(fresh), false);
  assert.equal(isSent(margin('e', { sentThrough: '' })), false);
  assert.deepEqual([...withoutSent(new Set(['s', 'f']), [sent, fresh])], ['f']);
  assert.equal(everythingSent([sent, fresh]), false);
  assert.equal(everythingSent([sent]), true);
  assert.equal(everythingSent([]), false);
  assert.deepEqual(forgetTicks({ s: true, f: false, x: true }, ['s', 'x']), { f: false });
});

test('through a link go only Margins that answer nothing or answer a Margin from that link’s packet (#4675)', () => {
  const here = 'a'.repeat(64);
  const there = 'b'.repeat(64);
  const own = margin('own');
  const toHere = margin('r1', { replyToId: `packet:${here}:interjection-1` });
  const toThere = margin('r2', { replyToId: `packet:${there}:interjection-1` });
  const toLocal = margin('r3', { replyToId: 'local-margin-id' });
  assert.equal(sendsThroughLink(own, here), true);
  assert.equal(sendsThroughLink(toHere, here), true);
  assert.equal(sendsThroughLink(toThere, here), false, 'the phone drops the whole answer for a parent in another package');
  assert.equal(sendsThroughLink(toLocal, here), true, 'a parent no packet names writes no conversation part');
  assert.equal(sendsThroughLink(margin('r4', { replyToId: `packet:${here.toUpperCase()}:x` }), here), true, 'not a packet id, so no conversation part');
  const split = splitForLink([own, toThere, toHere, toLocal], here);
  assert.deepEqual(split.through.map((m) => m.id), ['own', 'r1', 'r3']);
  assert.deepEqual(split.fileOnly.map((m) => m.id), ['r2']);
});
