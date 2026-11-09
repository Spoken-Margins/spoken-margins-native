import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SUGGESTED_SHOWS, suggestionsToShow } from './suggestions.ts';

test('the starter list is the owner’s four, in order (2026-11-06, #3610)', () => {
  assert.deepEqual(
    SUGGESTED_SHOWS.map((s) => [s.title, s.feedUrl]),
    [
      ['Dwarkesh Podcast', 'https://dwarkesh.com/feed'],
      ['Lenny’s Newsletter', 'https://lennysnewsletter.com/feed'],
      ['Letters from an American', 'https://heathercoxrichardson.substack.com/feed'],
      ['The Pragmatic Engineer', 'https://newsletter.pragmaticengineer.com/feed'],
    ],
  );
});

test('every suggestion is an https feed with no artwork, so showing the list contacts no publisher', () => {
  const feeds = new Set<string>();
  for (const show of SUGGESTED_SHOWS) {
    assert.equal(new URL(show.feedUrl).protocol, 'https:', show.title);
    assert.ok(show.title.trim() && show.about.trim(), show.title);
    assert.equal('artworkUrl' in show, false, `${show.title} must not carry artwork`);
    assert.equal(feeds.has(show.feedUrl), false, `${show.title} is listed twice`);
    feeds.add(show.feedUrl);
  }
});

test('a followed suggestion leaves the list, whichever way its address is spelled', () => {
  const all = SUGGESTED_SHOWS.map((s) => s.title);
  assert.deepEqual(suggestionsToShow([]).map((s) => s.title), all);
  // Neighbouring spellings: the redirect target, trailing slash, host case, scheme, a lookalike on another host.
  for (const followed of [
    'https://dwarkesh.com/feed',
    'https://www.dwarkesh.com/feed',
    'https://www.dwarkesh.com/feed/',
    'HTTPS://DWARKESH.COM/feed',
    'http://dwarkesh.com/feed',
  ]) {
    assert.deepEqual(suggestionsToShow([followed]).map((s) => s.title), all.slice(1), followed);
  }
  for (const other of ['https://dwarkesh.com/feed.xml', 'https://dwarkesh.net/feed', 'https://dwarkesh.com/', '', 'not a url']) {
    assert.deepEqual(suggestionsToShow([other]).map((s) => s.title), all, other);
  }
  assert.deepEqual(suggestionsToShow(SUGGESTED_SHOWS.map((s) => s.feedUrl)), []);
});
