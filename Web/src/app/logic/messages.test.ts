import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PacketError } from '../../packet/errors.ts';
import { NotAacError } from '../../packet/m4a.ts';
import { RecordingUnavailableError } from '../../packet/record.ts';
import { FeedParseError } from '../../sources/feed.ts';
import { NeedsRelayConsent, PaidPostNoVoice, PostPageReadRefused, ReadHttpError, ReadTooLarge, RelayNotConfigured, RelayUnreachable } from '../../sources/read.ts';
import { SearchError } from '../../sources/search.ts';
import { MESSAGES, plainError } from './messages.ts';

test('feed failures read as what happened and what to do, never a status code', () => {
  const rows: Array<[unknown, string]> = [
    [new ReadHttpError(404, 'direct'), MESSAGES.feedGone],
    [new ReadHttpError(410, 'direct'), MESSAGES.feedGone],
    [new ReadHttpError(403, 'direct'), MESSAGES.feedRefused],
    [new ReadHttpError(401, 'direct'), MESSAGES.feedRefused],
    [new ReadHttpError(500, 'direct'), MESSAGES.feedSiteError],
    [new ReadHttpError(502, 'relay'), MESSAGES.relayFailed],
    [new ReadHttpError(429, 'relay'), MESSAGES.relayLimit],
    [new ReadHttpError(503, 'relay'), MESSAGES.relayBusy],
    [new ReadHttpError(503, 'relay', 'busy'), MESSAGES.relayBusy],
    // A switched-off relay is not a busy one: "try again in a minute" would send the listener round in circles.
    [new ReadHttpError(503, 'relay', 'disabled'), MESSAGES.relayOff],
    [new RelayUnreachable(), MESSAGES.relayUnreachable],
    [new PaidPostNoVoice('https://a.example/p/x'), MESSAGES.paidPost],
    [new ReadHttpError(403, 'relay'), MESSAGES.relayOff],
    [new ReadHttpError(404, 'relay'), MESSAGES.relayOff],
    [new FeedParseError('Not an RSS 2.0 feed: no <rss><channel> found.'), MESSAGES.notAFeed],
    [new ReadTooLarge(4), MESSAGES.tooLarge],
    [new RelayNotConfigured(), MESSAGES.noRelay],
    [new PostPageReadRefused('https://a.example/p/x'), MESSAGES.postNeedsTap],
    [new SearchError('Podcast search failed with status 500.'), MESSAGES.searchFailed],
    [new TypeError('Failed to fetch'), MESSAGES.offline],
    [new TypeError('Load failed'), MESSAGES.offline],
  ];
  for (const [error, want] of rows) {
    const got = plainError(error);
    assert.equal(got, want, String(error));
    assert.doesNotMatch(got, /status \d|<rss>|RSS 2\.0/);
  }
});

test('an unreachable relay says so, and says “offline” only when the browser is offline', () => {
  // The common case: the site answered but doesn't allow browser reads, and the relay is down or not deployed.
  // Telling an online listener to check their connection sends them the wrong way.
  const original = Object.getOwnPropertyDescriptor(globalThis, 'navigator');
  const setOnline = (onLine: boolean) => Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { onLine } });
  try {
    setOnline(true);
    assert.equal(plainError(new RelayUnreachable()), MESSAGES.relayUnreachable);
    assert.doesNotMatch(MESSAGES.relayUnreachable, /online|connection/i);
    setOnline(false);
    assert.equal(plainError(new RelayUnreachable()), MESSAGES.offline);
  } finally {
    if (original) Object.defineProperty(globalThis, 'navigator', original);
  }
});

test('packet and recording errors keep their own plain words', () => {
  const packet = new PacketError('notAPacket', 'file name x.txt has the wrong extension');
  assert.equal(plainError(packet), packet.message);
  assert.match(plainError(packet), /isn't a Spoken Margins file/);
  assert.doesNotMatch(plainError(packet), /extension/, 'the technical detail stays out');
  assert.equal(plainError(new RecordingUnavailableError()), new RecordingUnavailableError().message);
  assert.equal(plainError(new NotAacError('opus')), MESSAGES.notAac);
});

test('browser microphone errors are about the microphone only when recording', () => {
  const dom = (name: string) => new DOMException('raw browser text', name);
  assert.equal(plainError(dom('NotAllowedError'), 'microphone'), MESSAGES.micBlocked);
  assert.equal(plainError(dom('SecurityError'), 'microphone'), MESSAGES.micBlocked);
  assert.equal(plainError(dom('NotFoundError'), 'microphone'), MESSAGES.micMissing);
  assert.equal(plainError(dom('OverconstrainedError'), 'microphone'), MESSAGES.micMissing);
  assert.equal(plainError(dom('NotReadableError'), 'microphone'), MESSAGES.micBusy);
  assert.equal(plainError(dom('NotFoundError')), 'raw browser text', 'an IndexedDB NotFoundError is not a missing microphone');
});

test('anything else falls back to its message', () => {
  assert.equal(plainError(new Error('Something specific.')), 'Something specific.');
  assert.equal(plainError('text'), 'text');
  assert.equal(plainError(new NeedsRelayConsent('https://a.example/feed')), new NeedsRelayConsent('https://a.example/feed').message);
});
