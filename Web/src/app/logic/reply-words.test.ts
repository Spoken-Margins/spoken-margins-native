import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  excerpt, NOT_A_REPLY, replyName, replyPossessive, replyMarginName, replyTo, replyingCaption, rowLine, senderNameOrNone, STOP_REPLYING,
} from './reply-words.ts';

// #4107 B1: the app's MarginReplyWords rows (MarginReplyWordsTests.swift), in the web's words and typography.
const stand = 'Voice Margin at 1:45 in “More Perfect: Cruel and Unusual”, recorded 9 Nov 2026';
const q = (words: string) => `“${words}”`;

test('the caption for every combination of name and words', () => {
  const rows: Array<{ label: string | undefined; text: string; seconds: number | undefined; caption: string }> = [
    { label: 'Sam', text: 'The author never says why.', seconds: 105, caption: `Replying to Sam: ${q('The author never says why.')}` },
    { label: 'Sam', text: stand, seconds: 105, caption: 'Replying to Sam’s Margin at 1:45' },
    { label: 'Sam', text: '', seconds: 105, caption: 'Replying to Sam’s Margin at 1:45' },
    { label: 'Sam', text: stand, seconds: undefined, caption: 'Replying to Sam’s Margin' },
    { label: undefined, text: stand, seconds: 105, caption: 'Replying to your friend’s Margin at 1:45' },
    { label: '', text: stand, seconds: 105, caption: 'Replying to your friend’s Margin at 1:45' },
    { label: 'Someone', text: stand, seconds: 105, caption: 'Replying to your friend’s Margin at 1:45' },
    { label: 'Your friend', text: stand, seconds: 105, caption: 'Replying to your friend’s Margin at 1:45' },
    { label: 'Someone', text: 'Why not?', seconds: 105, caption: `Replying to your friend: ${q('Why not?')}` },
    { label: 'someone', text: 'Why not?', seconds: undefined, caption: `Replying to your friend: ${q('Why not?')}` },
    { label: 'Unsigned sender', text: 'Why not?', seconds: undefined, caption: `Replying to your friend: ${q('Why not?')}` },
    { label: 'Sam', text: stand, seconds: 3725, caption: 'Replying to Sam’s Margin at 1:02:05' },
    { label: 'Sam', text: stand, seconds: 0, caption: 'Replying to Sam’s Margin at 0:00' },
    { label: 'Sam', text: stand, seconds: -5, caption: 'Replying to Sam’s Margin' },
    { label: 'Sam', text: stand, seconds: Number.NaN, caption: 'Replying to Sam’s Margin' },
  ];
  for (const row of rows) assert.equal(replyingCaption(row.label, row.text, row.seconds), row.caption, JSON.stringify(row));
});

test('neighbouring texts never nest quotes or show the stand-in', () => {
  const rows: Array<[string, string]> = [
    ['He said “no” twice.', `Replying to Sam: ${q('He said ‘no’ twice.')}`],
    ['He said "no" twice.', `Replying to Sam: ${q("He said 'no' twice.")}`],
    ['  two\n\nlines\t here  ', `Replying to Sam: ${q('two lines here')}`],
    ['Voice Margin at 1:45 is where she turns.', `Replying to Sam: ${q('Voice Margin at 1:45 is where she turns.')}`],
    ['voice margin at 1:45', `Replying to Sam: ${q('voice margin at 1:45')}`],
    ['Voice Margin at 1:45 in “A”, recorded 9 Nov 2026 and more', `Replying to Sam: ${q('Voice Margin at 1:45 in ‘A’, recorded 9 Nov 2026 and more')}`],
    ['Été 😀 café', `Replying to Sam: ${q('Été 😀 café')}`],
    ['​﻿  ', 'Replying to Sam’s Margin at 1:45'],
  ];
  for (const [text, expected] of rows) {
    const caption = replyingCaption('Sam', text, 105);
    assert.equal(caption, expected, text);
    assert.ok(!caption.includes('““') && !caption.includes('””'));
  }
});

test('a long excerpt is cut at 90 characters with an ellipsis, never mid-character, never after a space', () => {
  const exactly = 'a'.repeat(90);
  assert.equal(excerpt(exactly), exactly, '90 characters is kept whole');
  assert.equal(excerpt(`${exactly}b`), `${exactly}…`);
  assert.equal(excerpt('word '.repeat(60)), `${'word '.repeat(17)}word…`, 'no space before the ellipsis');
  assert.equal(excerpt('😀'.repeat(100)), `${'😀'.repeat(90)}…`, 'cut at a whole character');
  assert.equal(excerpt('👨‍👩‍👧'.repeat(100)), `${'👨‍👩‍👧'.repeat(90)}…`, 'a joined emoji is one character');
  assert.equal(excerpt(' \n\t '), undefined);
  assert.equal(excerpt(''), undefined);
  assert.equal(excerpt('​﻿ '), undefined, 'invisible characters are no words');
});

test('names and possessives for named and nameless senders', () => {
  assert.equal(replyName('Sam'), 'Sam');
  assert.equal(replyName('  Sam  '), 'Sam');
  assert.equal(replyPossessive('Sam'), 'Sam’s');
  assert.equal(replyTo('Sam'), 'Reply to Sam');
  for (const label of [undefined, '', ' ', 'Someone', ' someone ', 'SOMEONE', 'Unsigned sender', 'Imported collection', 'Your friend', 'your  FRIEND', 'Yoür friend']) {
    assert.equal(senderNameOrNone(label), undefined, String(label));
    assert.equal(replyName(label), 'your friend', String(label));
    assert.equal(replyPossessive(label), 'your friend’s', String(label));
    assert.equal(replyTo(label), 'Reply to your friend', String(label));
  }
  assert.equal(replyName('Someone Else'), 'Someone Else', 'a name that starts with the stand-in is a name');
  assert.equal(senderNameOrNone('<b>x</b>'), '<b>x</b>', 'a name is only ever text');
});

test('the ends of the stop-replying control are plain words', () => {
  assert.equal(STOP_REPLYING, 'Stop replying');
  assert.equal(NOT_A_REPLY, 'Not a reply');
});

test('the line on an own Margin: a reply, a stopped reply, a reply whose parent is gone, and one that never was', () => {
  const parent = { author: 'Cole', atSeconds: 105 };
  assert.equal(rowLine({}, undefined), undefined);
  assert.equal(rowLine({ replyToId: 'p' }, parent), 'Reply to Cole’s Margin at 1:45');
  assert.equal(rowLine({ replyToId: 'p' }, { author: undefined, atSeconds: 3725 }), 'Reply to your friend’s Margin at 1:02:05');
  assert.equal(rowLine({ replyToId: 'p' }, { author: 'Someone', atSeconds: 5 }), 'Reply to your friend’s Margin at 0:05');
  assert.equal(rowLine({ replyToId: 'p' }, undefined), 'Reply to a Margin that isn’t here');
  assert.equal(rowLine({ formerReplyToId: 'p' }, parent), 'Not a reply');
  assert.equal(rowLine({ formerReplyToId: 'p' }, undefined), 'Not a reply');
});

test('replyMarginName: the spoken name of a Reply button and the line on a saved reply (#4107, B5)', () => {
  assert.equal(replyMarginName({ author: 'Cole', atSeconds: 105 }), 'Reply to Cole’s Margin at 1:45');
  assert.equal(replyMarginName({ author: undefined, atSeconds: 3725 }), 'Reply to your friend’s Margin at 1:02:05');
  assert.equal(replyMarginName({ author: 'Unsigned sender', atSeconds: 0 }), 'Reply to your friend’s Margin at 0:00');
  assert.equal(replyMarginName({ author: 'Cole', atSeconds: -1 }), 'Reply to Cole’s Margin');
});
