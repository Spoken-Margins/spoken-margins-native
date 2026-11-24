import { test } from 'node:test';
import assert from 'node:assert/strict';
import { looksPrivateFeedLink, relayOnFirstRead, settingsAfterAnswer, whenBlocked, type RelaySettings } from './relay-consent.ts';

const NOT_ASKED: RelaySettings = { relayAllowed: false, relayAsked: false };
const ON: RelaySettings = { relayAllowed: true, relayAsked: true };
const OFF: RelaySettings = { relayAllowed: false, relayAsked: true };

test('a paid show’s RSS link, or one with a token in it, looks private; a public feed does not', () => {
  const rows: Array<[string, boolean]> = [
    ['https://www.patreon.com/rss/fixture?auth=TOKEN', true],
    ['https://WWW.PATREON.COM/rss/fixture', true],
    ['  https://www.patreon.com/rss/fixture?auth=abc  ', true],
    ['https://feeds.supercast.com/episodes/abc.rss', true],
    ['https://example.supportingcast.fm/feed.rss', true],
    ['https://feeds.example.com/private/show.rss', true],
    ['https://feeds.example.com/show.rss?token=x', true],
    ['https://feeds.example.com/show.rss?Access_Key=x', true],
    ['https://feeds.example.com/a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8.rss', true],
    ['https://user:pass@feeds.example.com/show.rss', true],
    ['https://feeds.example.com/show.rss', false],
    ['https://feeds.megaphone.fm/hardfork', false],
    ['https://name.substack.com/feed', false],
    // A lookalike host is not Patreon.
    ['https://notpatreon.com/rss/show', false],
    ['https://feeds.example.com/patreon-news.rss', false],
    // Not an http(s) link at all: nothing to send anywhere.
    ['', false],
    ['Hard Fork', false],
    ['ftp://www.patreon.com/rss/x', false],
  ];
  for (const [url, want] of rows) assert.equal(looksPrivateFeedLink(url), want, url);
});

test('a private-looking link never goes through the server on the first read, even with the server on', () => {
  assert.equal(relayOnFirstRead(ON, false), true);
  assert.equal(relayOnFirstRead(ON, true), false);
  assert.equal(relayOnFirstRead(NOT_ASKED, false), false);
  assert.equal(relayOnFirstRead(NOT_ASKED, true), false);
  assert.equal(relayOnFirstRead(OFF, true), false);
});

test('a blocked read asks unless the listener switched the server off', () => {
  assert.equal(whenBlocked(NOT_ASKED), 'ask');
  // With the server on, only a private link reaches here, and it is asked about by name.
  assert.equal(whenBlocked(ON), 'ask');
  assert.equal(whenBlocked(OFF), 'off');
});

test('the first answer is remembered; an answer about one private link leaves a server that was on alone', () => {
  assert.deepEqual(settingsAfterAnswer(NOT_ASKED, true), { relayAsked: true, relayAllowed: true });
  assert.deepEqual(settingsAfterAnswer(NOT_ASKED, false), { relayAsked: true, relayAllowed: false });
  assert.deepEqual(settingsAfterAnswer(ON, false), {});
  assert.deepEqual(settingsAfterAnswer(ON, true), {});
  // On but never asked (switched on in Settings before any pop-up): the same.
  assert.deepEqual(settingsAfterAnswer({ relayAllowed: true, relayAsked: false }, false), {});
});
