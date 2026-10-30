import assert from 'node:assert/strict';
import { test } from 'node:test';
import { FeedParseError, parseDuration, parseFeed, parsePubDate } from './feed.ts';
import { feedFixture } from './fixtures.ts';

const FEED = 'https://example.com/feed.xml';

function wrap(items: string, channelExtra = ''): string {
  return `<?xml version="1.0"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>T</title>${channelExtra}${items}</channel></rss>`;
}

function item(inner: string): string {
  return `<item>${inner}</item>`;
}

const audio = '<enclosure url="https://m.example.com/a.mp3" type="audio/mpeg"/>';

test('enclosure-only-episodes.rss: keeps the three playable items, drops the show note and the video trailer', () => {
  const { show, episodes, truncated } = parseFeed(feedFixture('enclosure-only-episodes.rss'), { feedUrl: FEED, followedAt: 'T0' });
  assert.equal(show.kind, 'podcast');
  assert.equal(show.title, 'Spoken Margins Test Show');
  assert.equal(show.siteUrl, 'https://example.com/show');
  assert.equal(show.feedUrl, FEED);
  assert.equal(truncated, false);
  assert.deepEqual(
    episodes.map((e) => e.guid),
    ['sm-test-show-ep3', undefined, 'sm-test-show-ep1'],
  );
  const [ep3, ep2, ep1] = episodes;
  assert.equal(ep3?.audioUrl, 'https://media.example.com/show/ep3.mp3');
  assert.equal(ep3?.audioOrigin, 'podcast-enclosure');
  assert.equal(ep3?.durationSeconds, 21 * 60 + 4);
  assert.equal(ep3?.publishedAt, '2026-09-26T10:00:00.000Z');
  assert.equal(ep3?.pageUrl, undefined);
  assert.ok(ep2?.audioUrl?.endsWith('Zx81kq0P2mNw7rT4yB6vC9dF3hJ5lA1s'), 'the query string of the enclosure survives');
  assert.equal(ep1?.pageUrl, 'https://example.com/show/episode-1');
  assert.ok(episodes.every((e) => e.showId === show.id));
  assert.equal(new Set(episodes.map((e) => e.id)).size, episodes.length, 'episode ids are unique');
});

test('substack-publisher-audio.rss: a Substack feed, with the image enclosure not taken for audio', () => {
  const { show, episodes } = parseFeed(feedFixture('substack-publisher-audio.rss'), { feedUrl: 'https://captured.example/feed' });
  assert.equal(show.kind, 'substack');
  assert.equal(show.title, 'Captured publication');
  assert.equal(episodes.length, 2);
  assert.equal(episodes[0]?.title, 'The harbor in winter');
  assert.equal(episodes[0]?.pageUrl, 'https://captured.example/p/voiceover');
  assert.equal(episodes[0]?.guid, 'https://captured.example/p/voiceover');
  assert.equal(episodes[0]?.audioUrl, undefined, 'its voice is found from the post page, on a tap');
  assert.equal(episodes[0]?.publishedAt, '2026-03-02T03:16:27.000Z');
});

test('substack-zvi-generated-voice.rss: CDATA title, the show author, a Substack feed with one post', () => {
  const { show, episodes } = parseFeed(feedFixture('substack-zvi-generated-voice.rss'), { feedUrl: 'https://thezvi.substack.com/feed' });
  assert.equal(show.kind, 'substack');
  assert.equal(show.title, "Don't Worry About the Vase");
  assert.equal(show.author, 'Zvi Mowshowitz');
  assert.equal(show.siteUrl, 'https://thezvi.substack.com/');
  assert.equal(show.artworkUrl?.startsWith('https://substackcdn.com/'), true);
  assert.equal(episodes.length, 1);
  assert.equal(episodes[0]?.title, 'Leaked Anthropic Draft AI Regulatory Bill Is Unacceptable and Troubling');
  assert.equal(episodes[0]?.audioUrl, undefined);
});

test('substack-transcript-podcast.rss: a podcast on a Substack-style feed keeps its real audio enclosure', () => {
  const { show, episodes } = parseFeed(feedFixture('substack-transcript-podcast.rss'), { feedUrl: 'https://www.persuasion.community/feed' });
  assert.equal(show.kind, 'podcast');
  assert.equal(episodes.length, 1);
  assert.equal(episodes[0]?.audioUrl, 'https://podcast.example/episode.mp3');
  assert.equal(episodes[0]?.audioOrigin, 'podcast-enclosure');
});

test('durations: seconds, mm:ss, h:mm:ss, fractions, and nothing for junk', () => {
  const table: Array<[string | undefined, number | undefined]> = [
    ['3723', 3723],
    ['3723.5', 3723.5],
    ['62:03', 62 * 60 + 3],
    ['1:02:03', 3723],
    ['01:02:03', 3723],
    ['00:21:04.500', 21 * 60 + 4.5],
    [' 45 ', 45],
    ['0', 0],
    ['', undefined],
    [undefined, undefined],
    ['abc', undefined],
    ['1:2:3:4', undefined],
    ['-30', undefined],
    ['1.5:30', undefined],
    ['1:', undefined],
    [':30', undefined],
    ['1h 2m', undefined],
  ];
  for (const [input, expected] of table) assert.equal(parseDuration(input), expected, `duration ${JSON.stringify(input)}`);
});

test('pubDate: RFC 822 with a zone offset becomes UTC ISO; junk becomes nothing', () => {
  assert.equal(parsePubDate('Fri, 26 Sep 2026 10:00:00 +0200'), '2026-09-26T08:00:00.000Z');
  assert.equal(parsePubDate('not a date'), undefined);
  assert.equal(parsePubDate(''), undefined);
});

test('awkward feed inputs', async (t) => {
  const first = (xml: string, options = {}) => parseFeed(xml, { feedUrl: FEED, ...options });

  await t.test('CDATA keeps markup characters literally', () => {
    const { episodes } = first(wrap(item(`<title><![CDATA[Fish & <chips> "now"]]></title>${audio}`)));
    assert.equal(episodes[0]?.title, 'Fish & <chips> "now"');
  });

  await t.test('entities in text and in attribute values are decoded', () => {
    const { episodes } = first(
      wrap(item(`<title>Q&amp;A &#8212; &#x2603; &lt;live&gt;</title><enclosure url="https://m.example.com/a.mp3?x=1&amp;y=2" type="audio/mpeg"/>`)),
    );
    assert.equal(episodes[0]?.title, 'Q&A — ☃ <live>');
    assert.equal(episodes[0]?.audioUrl, 'https://m.example.com/a.mp3?x=1&y=2');
  });

  await t.test('an unknown entity and a bare ampersand stay as written', () => {
    const { episodes } = first(wrap(item(`<title>Tom &amp Jerry &nbsp; &zzz;</title>${audio}`)));
    assert.equal(episodes[0]?.title, 'Tom &amp Jerry &nbsp; &zzz;');
  });

  await t.test('missing guid: the id falls back to the audio URL and guid stays unset', () => {
    const { episodes } = first(wrap(item(`<title>No guid</title>${audio}`)));
    assert.equal(episodes[0]?.guid, undefined);
    assert.ok(episodes[0]?.id.endsWith('#https://m.example.com/a.mp3'));
  });

  await t.test('a blank guid counts as missing', () => {
    const { episodes } = first(wrap(item(`<title>Blank</title><guid>   </guid>${audio}`)));
    assert.equal(episodes[0]?.guid, undefined);
  });

  await t.test('guid text is trimmed', () => {
    const { episodes } = first(wrap(item(`<title>x</title><guid isPermaLink="false">\n  abc-123 \n</guid>${audio}`)));
    assert.equal(episodes[0]?.guid, 'abc-123');
  });

  await t.test('itunes:duration forms read through the whole parser', () => {
    const { episodes } = first(
      wrap(
        [
          item(`<title>a</title>${audio}<itunes:duration>1:02:03</itunes:duration>`),
          item(`<title>b</title>${audio}<itunes:duration>62:03</itunes:duration>`),
          item(`<title>c</title>${audio}<itunes:duration>3723</itunes:duration>`),
          item(`<title>d</title>${audio}<itunes:duration>soon</itunes:duration>`),
        ].join(''),
      ),
    );
    assert.deepEqual(
      episodes.map((e) => e.durationSeconds),
      [3723, 3723, 3723, undefined],
    );
  });

  await t.test('a relative link resolves against the feed URL; a root-relative one too', () => {
    const { show, episodes } = first(
      wrap(
        [item(`<title>a</title><link>/shows/a</link>${audio}`), item(`<title>b</title><link>b.html</link>${audio}`)].join(''),
        '<link>/about</link>',
      ),
    );
    assert.equal(episodes[0]?.pageUrl, 'https://example.com/shows/a');
    assert.equal(episodes[1]?.pageUrl, 'https://example.com/b.html');
    assert.equal(show.siteUrl, 'https://example.com/about');
  });

  await t.test('a link that is not http(s) is dropped, never kept', () => {
    const { episodes } = first(wrap(item(`<title>a</title><link>javascript:alert(1)</link>${audio}`)));
    assert.equal(episodes[0]?.pageUrl, undefined);
  });

  await t.test('an enclosure that is not http(s) is not audio', () => {
    const { episodes } = first(wrap(item('<title>a</title><enclosure url="file:///etc/passwd" type="audio/mpeg"/>')));
    assert.deepEqual(episodes, []);
  });

  await t.test('an untyped enclosure counts as audio only with an audio extension', () => {
    const { episodes } = first(
      wrap(
        [
          item('<title>a</title><enclosure url="https://m.example.com/a.m4a"/>'),
          item('<title>b</title><enclosure url="https://m.example.com/page"/>'),
        ].join(''),
      ),
    );
    assert.deepEqual(
      episodes.map((e) => e.title),
      ['a'],
    );
  });

  await t.test('an empty channel is a show with no episodes', () => {
    const { show, episodes, truncated } = first(wrap(''));
    assert.equal(show.title, 'T');
    assert.deepEqual(episodes, []);
    assert.equal(truncated, false);
  });

  await t.test('a channel without a title takes the host name', () => {
    const { show } = first('<rss><channel></channel></rss>');
    assert.equal(show.title, 'example.com');
  });

  await t.test('a feed with an XML declaration, a comment, a DOCTYPE and a BOM still parses', () => {
    const xml = `﻿<?xml version="1.0"?><!-- hi --><!DOCTYPE rss [<!ENTITY x "&x;&x;&x;">]><rss><channel><title>Safe &x;</title>${item(`<title>a</title>${audio}`)}</channel></rss>`;
    const { show, episodes } = first(xml);
    assert.equal(show.title, 'Safe &x;', 'a declared entity is never expanded');
    assert.equal(episodes.length, 1);
  });

  await t.test('itunes:image href is the artwork, resolved against the feed', () => {
    const { show } = first(wrap('', '<itunes:image href="/art.jpg"/>'));
    assert.equal(show.artworkUrl, 'https://example.com/art.jpg');
  });

  await t.test('the channel title is not taken from the nested image title', () => {
    const xml = '<rss><channel><image><title>Logo</title><url>https://example.com/l.png</url></image><title>Real</title></channel></rss>';
    const { show } = first(xml);
    assert.equal(show.title, 'Real');
    assert.equal(show.artworkUrl, 'https://example.com/l.png');
  });

  await t.test('atom:link is not mistaken for the channel link', () => {
    const { show } = first(wrap('', '<atom:link href="https://example.com/feed" rel="self"/><link>https://example.com/home</link>'));
    assert.equal(show.siteUrl, 'https://example.com/home');
  });

  await t.test('a truncated document gives the items read so far', () => {
    const xml = wrap(item(`<title>a</title>${audio}`) + '<item><title>cut off').replace('</channel></rss>', '');
    const { episodes } = first(xml);
    assert.equal(episodes.length, 1);
  });

  await t.test('a stray close tag and unclosed tags do not lose the items after them', () => {
    const xml = wrap(`</bogus>${item(`<title>a</title>${audio}<br>`)}${item(`<title>b</title>${audio}`)}`);
    const { episodes } = first(xml);
    assert.deepEqual(
      episodes.map((e) => e.title),
      ['a', 'b'],
    );
  });

  await t.test('HTML or Atom is not a feed', () => {
    assert.throws(() => first('<html><body>Not found</body></html>'), FeedParseError);
    assert.throws(() => first('<feed xmlns="http://www.w3.org/2005/Atom"><title>x</title></feed>'), FeedParseError);
    assert.throws(() => first(''), FeedParseError);
  });

  await t.test('a huge feed stops at the cap and says so', () => {
    const items = Array.from({ length: 5000 }, (_, i) => item(`<title>Ep ${i}</title><guid>g${i}</guid>${audio}`)).join('');
    const { episodes, truncated } = first(wrap(items), { maxItems: 100 });
    assert.equal(episodes.length, 100);
    assert.equal(truncated, true);
    assert.equal(episodes[0]?.title, 'Ep 0');
    assert.equal(episodes[99]?.title, 'Ep 99');
  });

  await t.test('a feed exactly at the cap is not truncated', () => {
    const items = Array.from({ length: 10 }, (_, i) => item(`<title>Ep ${i}</title>${audio}`)).join('');
    const { episodes, truncated } = first(wrap(items), { maxItems: 10 });
    assert.equal(episodes.length, 10);
    assert.equal(truncated, false);
  });

  await t.test('the default cap is applied without being asked', () => {
    const items = Array.from({ length: 600 }, (_, i) => item(`<title>Ep ${i}</title>${audio}`)).join('');
    const { episodes, truncated } = first(wrap(items));
    assert.equal(episodes.length, 500);
    assert.equal(truncated, true);
  });

  await t.test('deeply nested junk does not overflow the stack', () => {
    const xml = wrap('<a>'.repeat(50000) + item(`<title>x</title>${audio}`));
    assert.doesNotThrow(() => first(xml));
  });
});
