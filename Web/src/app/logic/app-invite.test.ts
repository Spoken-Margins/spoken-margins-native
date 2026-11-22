import assert from 'node:assert/strict';
import { test } from 'node:test';

import { APP_INVITE_KEY, APP_INVITE_WORDS, inviteAfterShare, markInviteSeen, type InviteStorage } from './app-invite.ts';
import { GET_APP_LINK } from './arrival.ts';

const memory = (): InviteStorage & { items: Map<string, string> } => {
  const items = new Map<string, string>();
  return { items, getItem: (k) => items.get(k) ?? null, setItem: (k, v) => { items.set(k, v); } };
};
const reply = { wasReply: true, outcome: 'shared', inApp: false } as const;

test('#4671: the first reply sent through the share sheet shows the invitation, and marks it seen', () => {
  const s = memory();
  assert.equal(inviteAfterShare(s, reply), true);
  assert.equal(s.items.has(APP_INVITE_KEY), true);
});

test('#4671: a reply saved as a file counts as sent', () => {
  assert.equal(inviteAfterShare(memory(), { ...reply, outcome: 'saved' }), true);
});

test('#4671: a closed or refused share sheet shows nothing and leaves it unseen', () => {
  for (const outcome of ['cancelled', 'refused'] as const) {
    const s = memory();
    assert.equal(inviteAfterShare(s, { ...reply, outcome }), false, outcome);
    assert.equal(s.items.has(APP_INVITE_KEY), false, outcome);
  }
});

test('#4671: sharing one’s own Margins with no friend’s Margin to answer is not a reply', () => {
  const s = memory();
  assert.equal(inviteAfterShare(s, { ...reply, wasReply: false }), false);
  assert.equal(s.items.has(APP_INVITE_KEY), false);
});

test('#4671: inside the iPhone app’s web view it never shows', () => {
  assert.equal(inviteAfterShare(memory(), { ...reply, inApp: true }), false);
});

test('#4671: once shown, a second reply in the same browser shows nothing', () => {
  const s = memory();
  assert.equal(inviteAfterShare(s, reply), true);
  assert.equal(inviteAfterShare(s, reply), false);
});

test('#4671: after dismissal it does not come back', () => {
  const s = memory();
  markInviteSeen(s);
  assert.equal(inviteAfterShare(s, reply), false);
});

test('#4671: with storage blocked (no storage, or one that throws) it still shows, and nothing throws', () => {
  assert.equal(inviteAfterShare(undefined, reply), true);
  const throwing: InviteStorage = { getItem: () => { throw new Error('blocked'); }, setItem: () => { throw new Error('blocked'); } };
  assert.equal(inviteAfterShare(throwing, reply), true);
  assert.doesNotThrow(() => markInviteSeen(throwing));
});

test('#4671: the words say what the app adds, to tap the link again, and one file per item; the button goes to the join guide', () => {
  assert.match(APP_INVITE_WORDS.adds, /app/);
  assert.match(APP_INVITE_WORDS.tapAgain, /tap your friend’s link again/);
  assert.match(APP_INVITE_WORDS.moveMargins, /one file per item/i);
  assert.equal(APP_INVITE_WORDS.button.href, GET_APP_LINK.href);
});
