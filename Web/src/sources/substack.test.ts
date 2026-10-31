import assert from 'node:assert/strict';
import { test } from 'node:test';
import { feedFixture } from './fixtures.ts';
import { findSubstackVoice, isSubstackPostUrl, samePage } from './substack.ts';

function page(post: Record<string, unknown>): string {
  const json = JSON.stringify({ post });
  return `<script>window._preloads = JSON.parse(${JSON.stringify(json)});</script>`;
}

const completedTts = (postId = 1) => ({
  post_id: postId,
  type: 'tts',
  status: 'completed',
  audio_url: 'https://r.example/tts.mp3',
});

test('author voiceover page: the voiceover, with its duration', () => {
  const voice = findSubstackVoice(feedFixture('substack-voiceover-page.html'));
  assert.deepEqual(voice, {
    origin: 'substack-voiceover',
    audioUrl: 'https://recordings.example/voiceover.mp3',
    durationSeconds: 752.8751,
    canonicalUrl: 'https://captured.example/p/voiceover',
  });
});

test('generated-voice-only page: Substack automatic voice, no duration', () => {
  const voice = findSubstackVoice(feedFixture('substack-generated-voice-only-page.html'));
  assert.equal(voice?.origin, 'substack-generated-voice');
  assert.equal(voice?.audioUrl, 'https://recordings.example/tts/en-US-AlloyTurboMultilingualNeural.mp3');
  assert.equal(voice?.durationSeconds, undefined);
});

test('JSON script tag page (Oct 2026 shape): the automatic voice is found without running the page script', () => {
  const voice = findSubstackVoice(feedFixture('substack-preloads-json-generated-voice-page.html'));
  assert.equal(voice?.origin, 'substack-generated-voice');
  assert.ok(voice?.audioUrl.endsWith('en-US-OnyxTurboMultilingualNeural.mp3'));
  assert.equal(voice?.canonicalUrl, 'https://thezvi.substack.com/p/leaked-anthropic-draft-ai-regulatory');
});

test('both present: the publisher voiceover wins, though the automatic voice is listed too', () => {
  const voice = findSubstackVoice(feedFixture('substack-voiceover-and-generated-voice-page.html'));
  assert.equal(voice?.origin, 'substack-voiceover');
  assert.equal(voice?.audioUrl, 'https://api.recordings.example/api/v1/audio/upload/11111111-2222-3333-4444-555555555555/src');
  assert.equal(voice?.durationSeconds, 1136.3788);
});

test('paid post: has_voiceover is true but the voice is paywalled, so none', () => {
  assert.equal(findSubstackVoice(feedFixture('substack-paid-post-page.html')), null);
});

test('finalUrl: a voice belongs only to its own post (query, trailing slash and host case ignored)', () => {
  const html = feedFixture('substack-voiceover-page.html');
  assert.ok(findSubstackVoice(html, { finalUrl: 'https://CAPTURED.example/p/voiceover/?utm_source=x#top' }));
  assert.equal(findSubstackVoice(html, { finalUrl: 'https://captured.example/p/another-post' }), null);
  assert.equal(findSubstackVoice(html, { finalUrl: 'http://captured.example/p/voiceover' }), null, 'scheme must match');
  assert.equal(findSubstackVoice(html, { finalUrl: 'not a url' }), null);
});

test('awkward pages', async (t) => {
  await t.test('not a post page, empty, or malformed JSON', () => {
    assert.equal(findSubstackVoice(''), null);
    assert.equal(findSubstackVoice('<html><body>hello</body></html>'), null);
    assert.equal(findSubstackVoice('<script>window._preloads = JSON.parse("{not json");</script>'), null);
    assert.equal(findSubstackVoice('<script type="application/json" id="preloads-json">{oops</script>'), null);
    assert.equal(findSubstackVoice('<script>window._preloads = JSON.parse("[1,2]");</script>'), null);
  });

  await t.test('a podcast-type post gives nothing', () => {
    assert.equal(
      findSubstackVoice(page({ type: 'podcast', id: 1, canonical_url: 'https://x.example/p/a', has_voiceover: true, audio_items: [{ post_id: 1, type: 'voiceover', status: 'completed', audio_url: 'https://r.example/a.mp3' }] })),
      null,
    );
  });

  await t.test('a voiceover still processing gives nothing, and does not fall to a missing automatic voice', () => {
    const html = page({ type: 'newsletter', id: 1, canonical_url: 'https://x.example/p/a', has_voiceover: true, audio_items: [{ post_id: 1, type: 'voiceover', status: 'processing', audio_url: null }] });
    assert.equal(findSubstackVoice(html), null);
  });

  await t.test('voiceover recorded but has_voiceover is false: not trusted as a voiceover, automatic voice used instead', () => {
    const html = page({
      type: 'newsletter', id: 1, canonical_url: 'https://x.example/p/a', has_voiceover: false,
      audio_items: [{ post_id: 1, type: 'voiceover', status: 'completed', audio_url: 'https://r.example/v.mp3' }, completedTts()],
    });
    assert.equal(findSubstackVoice(html)?.origin, 'substack-generated-voice');
  });

  await t.test('an audio item that belongs to another post is skipped', () => {
    const html = page({ type: 'newsletter', id: 1, canonical_url: 'https://x.example/p/a', has_voiceover: false, audio_items: [completedTts(2)] });
    assert.equal(findSubstackVoice(html), null);
  });

  await t.test('a post id that is a string is not trusted', () => {
    const html = page({ type: 'newsletter', id: '1', canonical_url: 'https://x.example/p/a', audio_items: [completedTts(1)] });
    assert.equal(findSubstackVoice(html), null);
  });

  await t.test('audio over http, or not a URL, is refused', () => {
    for (const audio_url of ['http://r.example/a.mp3', 'javascript:alert(1)', 'nope', '']) {
      const html = page({ type: 'newsletter', id: 1, canonical_url: 'https://x.example/p/a', audio_items: [{ post_id: 1, type: 'tts', status: 'completed', audio_url }] });
      assert.equal(findSubstackVoice(html), null, audio_url);
    }
  });

  await t.test('a bad duration is dropped but the voice stays', () => {
    for (const duration of [-1, 'long', null]) {
      const html = page({ type: 'newsletter', id: 1, canonical_url: 'https://x.example/p/a', has_voiceover: true, audio_items: [{ post_id: 1, type: 'voiceover', status: 'completed', audio_url: 'https://r.example/a.mp3', duration }] });
      const voice = findSubstackVoice(html);
      assert.equal(voice?.origin, 'substack-voiceover');
      assert.equal(voice?.durationSeconds, undefined, String(duration));
    }
  });

  await t.test('the JSON tag with single-quoted or unquoted id, and a decoy script before it', () => {
    const json = JSON.stringify({ post: { type: 'newsletter', id: 1, canonical_url: 'https://x.example/p/a', audio_items: [completedTts()] } });
    for (const idAttr of ["id='preloads-json'", 'id=preloads-json']) {
      const html = `<script>var a = 1;</script><script type="application/json" ${idAttr}>${json}</script>`;
      assert.equal(findSubstackVoice(html)?.origin, 'substack-generated-voice', idAttr);
    }
    const decoy = `<script type="application/json" id="preloads-json-other">{"post":{}}</script>`;
    assert.equal(findSubstackVoice(decoy), null);
  });

  await t.test('script text is never executed', () => {
    const marker = '__sm_ran__';
    const html = `<script>globalThis.${marker} = true; window._preloads = JSON.parse("{\\"post\\":{}}");</script>`;
    findSubstackVoice(html);
    assert.equal((globalThis as Record<string, unknown>)[marker], undefined);
  });
});

test('samePage', () => {
  assert.ok(samePage('https://a.example/p/x', 'https://A.example/p/x/'));
  assert.ok(samePage('https://a.example/p/x?r=1', 'https://a.example/p/x#frag'));
  assert.ok(!samePage('https://a.example/p/x', 'https://a.example/p/y'));
  assert.ok(!samePage('https://a.example/p/x', 'https://b.example/p/x'));
  assert.ok(!samePage('nope', 'nope'));
});

test('isSubstackPostUrl: post pages yes, feeds and home pages no', () => {
  const yes = [
    'https://thezvi.substack.com/p/some-post',
    'https://thezvi.substack.com/p/some-post/',
    'https://www.platformer.news/p/some-post',
    'https://open.substack.com/pub/thezvi/p/some-post',
    'https://substack.com/@x/p/abc',
  ];
  const no = [
    'https://thezvi.substack.com/feed',
    'https://thezvi.substack.com/',
    'https://www.platformer.news/rss',
    'https://example.com/podcast/p/episode/extra/segments',
    'http://thezvi.substack.com/p/some-post',
    'not a url',
    'https://example.com/p/',
  ];
  for (const url of yes) assert.equal(isSubstackPostUrl(url), true, url);
  for (const url of no) assert.equal(isSubstackPostUrl(url), false, url);
});
