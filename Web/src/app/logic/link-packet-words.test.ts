import { test } from 'node:test';
import assert from 'node:assert/strict';
import { LISTENING_MAP_DETAIL, PACKET_MESSAGES, PacketError, type PacketOutcome } from '../../packet/errors.ts';
import { ShareLinkError } from './share-link.ts';
import { ARRIVAL_WORDS } from './arrival.ts';
import { LINK_LISTENING_MAP_WORDS, LINK_PACKET_WORDS, linkPacketWords } from './link-packet-words.ts';

const OUTCOMES = Object.keys(PACKET_MESSAGES) as PacketOutcome[];

test('every reader outcome has link words of its own, and the table names no outcome the reader lacks', () => {
  assert.deepEqual(Object.keys(LINK_PACKET_WORDS).sort(), [...OUTCOMES].sort());
  for (const outcome of OUTCOMES) {
    const words = linkPacketWords(new PacketError(outcome, 'detail'));
    assert.equal(words, LINK_PACKET_WORDS[outcome], outcome);
    assert.ok(words && words.trim().length > 0, outcome);
  }
});

test('a newer packet in a link says it is a version gap and gives a step that can work (#5266)', () => {
  const words = linkPacketWords(new PacketError('needsNewerApp', 'required capability future.feature'));
  assert.ok(words);
  assert.match(words, /newer Spoken Margins/);
  assert.match(words, /Open your friend’s link again, so this page loads its newest version/);
  assert.match(words, /open the link in the Spoken Margins app on iPhone/);
  assert.doesNotMatch(words, /damaged/i);
  assert.doesNotMatch(words, /send it again/i);
  // The Library's sentence tells a browser to update an app it doesn't have.
  assert.doesNotMatch(words, /Update the app/);
  assert.notEqual(words, ARRIVAL_WORDS.unreadable);
});

test('only a damaged packet says damaged or send it again; the version outcomes never do', () => {
  for (const outcome of OUTCOMES) {
    const words = LINK_PACKET_WORDS[outcome];
    const blames = /damaged|send it again/i.test(words);
    if (outcome === 'damaged' || outcome === 'cannotShare') assert.ok(blames, outcome);
    else assert.ok(!blames, `${outcome}: ${words}`);
  }
});

test('the first sentence of each is a heading that stands on its own', () => {
  for (const outcome of OUTCOMES) {
    const words = LINK_PACKET_WORDS[outcome];
    const at = words.indexOf('. ');
    assert.ok(at > 0, `${outcome} has a heading and a step`);
    assert.ok(words.slice(at + 2).trim().length > 0, outcome);
  }
});

test('a Listening Map link points to the iPhone app, not to a reload', () => {
  const words = linkPacketWords(new PacketError('needsNewerApp', LISTENING_MAP_DETAIL, 'reader sentence'));
  assert.equal(words, LINK_LISTENING_MAP_WORDS);
  assert.match(words, /Listening Map/);
  assert.doesNotMatch(words, /newest version/);
});

test('errors that are not reader refusals are left to the page', () => {
  assert.equal(linkPacketWords(new ShareLinkError('x', 'expired')), undefined);
  assert.equal(linkPacketWords(new Error('boom')), undefined);
  assert.equal(linkPacketWords(undefined), undefined);
  assert.equal(linkPacketWords('needsNewerApp'), undefined);
});
