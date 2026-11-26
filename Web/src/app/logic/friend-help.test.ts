import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { FRIEND_HELP_URL, friendHelpForFailure, friendHelpHref, type FriendHelpTopic } from './friend-help.ts';
import type { ShareLinkFailure } from './share-link.ts';

test('the help link opens the friends page, at a question when the card raises one', () => {
  assert.equal(friendHelpHref(), 'https://spokenmargins.com/friends/');
  assert.equal(friendHelpHref('cant-hear'), 'https://spokenmargins.com/friends/#cant-hear');
  assert.equal(friendHelpHref('wont-open'), `${FRIEND_HELP_URL}#wont-open`);
});

test('every failed link but an offline one offers the will-not-open question', () => {
  const rows: [ShareLinkFailure, FriendHelpTopic | null][] = [
    ['damaged', 'wont-open'],
    ['expired', 'wont-open'],
    ['server', 'wont-open'],
    ['off', 'wont-open'],
    ['other', 'wont-open'],
    ['offline', null],
  ];
  for (const [reason, topic] of rows) assert.equal(friendHelpForFailure(reason), topic, reason);
});

test('each topic the web links to is a question on the site page', () => {
  const page = readFileSync(new URL('../../../../Site/friends/index.html', import.meta.url), 'utf8');
  for (const topic of ['wont-open', 'cant-hear'] satisfies FriendHelpTopic[]) {
    assert.match(page, new RegExp(`<h2 id="${topic}">`), topic);
  }
});
