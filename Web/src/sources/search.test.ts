import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFixture } from './fixtures.ts';
import { SearchError, searchPodcasts, showFromItunesResult } from './search.ts';

function slug(query: string): string {
  return query.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
}

function normalize(text: string): string {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status });
}

test('asks the iTunes Search API for podcasts, with the term encoded', async () => {
  const urls: string[] = [];
  await searchPodcasts('  rock & roll/2  ', {
    fetch: async (url) => {
      urls.push(url);
      return json({ results: [] });
    },
  });
  assert.equal(urls.length, 1);
  const url = new URL(urls[0] as string);
  assert.equal(url.origin + url.pathname, 'https://itunes.apple.com/search');
  assert.equal(url.searchParams.get('media'), 'podcast');
  assert.equal(url.searchParams.get('term'), 'rock & roll/2');
});

test('an empty term asks nothing', async () => {
  const result = await searchPodcasts('   ', {
    fetch: async () => {
      throw new Error('should not be called');
    },
  });
  assert.deepEqual(result, []);
});

test('serial.json maps to Shows with feed, author, artwork and iTunes id', async () => {
  const body = readFixture('podcast-search/itunes-responses/serial.json');
  const shows = await searchPodcasts('serial', { fetch: async () => new Response(body) });
  assert.equal(shows.length, 15);
  const first = shows[0];
  assert.equal(first?.title, 'Serial');
  assert.equal(first?.kind, 'podcast');
  assert.equal(first?.feedUrl, 'https://feeds.simplecast.com/PpzWFGhg');
  assert.equal(first?.author, 'Serial Productions & The New York Times');
  assert.equal(first?.itunesId, 917918570);
  assert.equal(first?.id, 'itunes:917918570');
  assert.ok(first?.artworkUrl?.includes('600x600'));
  assert.equal(new Set(shows.map((s) => s.id)).size, shows.length);
});

test('the expected show comes first for at least 45 of the 50 recorded queries (the fixture list\'s own bar)', async () => {
  const list = JSON.parse(readFixture('podcast-search/test-names.json')) as {
    names: Array<{ query: string; expectedTitle: string }>;
  };
  assert.equal(list.names.length, 50);
  let hits = 0;
  for (const { query, expectedTitle } of list.names) {
    const body = readFixture(`podcast-search/itunes-responses/${slug(query)}.json`);
    const shows = await searchPodcasts(query, { fetch: async () => new Response(body) });
    assert.ok(shows.length > 0, `${query}: some results`);
    if (normalize(shows[0]?.title ?? '').startsWith(normalize(expectedTitle))) hits += 1;
  }
  assert.ok(hits >= 45, `only ${hits} of 50 put the expected show first`);
});

test('every recorded response maps without throwing, and every Show has a feed and a title', async () => {
  const list = JSON.parse(readFixture('podcast-search/test-names.json')) as { names: Array<{ query: string }> };
  for (const { query } of list.names) {
    const body = readFixture(`podcast-search/itunes-responses/${slug(query)}.json`);
    for (const show of await searchPodcasts(query, { fetch: async () => new Response(body) })) {
      assert.ok(show.title && /^https?:\/\//.test(show.feedUrl), `${query}: ${show.title}`);
    }
  }
});

test('awkward results: no feed, not a podcast, odd URLs, duplicates, missing fields', async () => {
  const shows = await searchPodcasts('x', {
    fetch: async () =>
      json({
        results: [
          { kind: 'podcast', collectionId: 1, collectionName: 'Good', feedUrl: 'https://a.example/feed' },
          { kind: 'podcast', collectionId: 2, collectionName: 'No feed' },
          { kind: 'podcast', collectionId: 3, collectionName: 'Bad feed', feedUrl: 'javascript:alert(1)' },
          { kind: 'song', collectionId: 4, collectionName: 'A song', feedUrl: 'https://s.example/feed' },
          { kind: 'podcast', collectionId: 1, collectionName: 'Good again', feedUrl: 'https://a.example/feed' },
          { kind: 'podcast', collectionId: 5, trackName: 'Track name only', feedUrl: 'http://b.example/feed' },
          { kind: 'podcast', collectionId: 6, collectionName: '   ', feedUrl: 'https://c.example/feed' },
          { collectionId: 7, collectionName: 'No kind field', feedUrl: 'https://d.example/feed' },
          null,
          'junk',
          { kind: 'podcast', collectionName: 'No id', feedUrl: 'https://e.example/feed' },
        ],
      }),
  });
  assert.deepEqual(
    shows.map((s) => s.title),
    ['Good', 'Track name only', 'No kind field', 'No id'],
  );
  assert.equal(shows[3]?.id, 'feed:https://e.example/feed');
  assert.equal(shows[3]?.itunesId, undefined);
});

test('failures are reported, not swallowed', async () => {
  await assert.rejects(searchPodcasts('x', { fetch: async () => json({}, 503) }), SearchError);
  await assert.rejects(searchPodcasts('x', { fetch: async () => new Response('<html>') }), SearchError);
  assert.deepEqual(await searchPodcasts('x', { fetch: async () => json({ results: 'nope' }) }), []);
  assert.deepEqual(await searchPodcasts('x', { fetch: async () => json(null) }), []);
});

test('showFromItunesResult leaves followedAt empty, since a search hit is not followed', () => {
  const show = showFromItunesResult({ kind: 'podcast', collectionId: 9, collectionName: 'N', feedUrl: 'https://n.example/f' });
  assert.equal(show?.followedAt, '');
});
