import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ShareLinkError } from './logic/share-link.ts';
import { messageForFailure, messageForOpened, messageForOpenedSettled, playCheckHandler, reportPlayCheck, type PlayCheckMessage } from './play-check.ts';
import { feedFixture } from '../sources/fixtures.ts';
import { READ_REFUSED, type CheckReadReply, type CheckReadRequest } from './play-check-reads.ts';

const margin = { id: 'm', episodeId: 'e', atSeconds: 5, createdAt: '2026-11-17T10:00:00Z', text: 'x', author: 'Cole' };
const episode = (e: object) => ({ title: 'T', ...e }) as never;

const hostWith = (postMessage: (m: PlayCheckMessage) => void) => ({ webkit: { messageHandlers: { smPlayCheck: { postMessage } } } });

test('without the app’s handler there is no probe, however the page looks', () => {
  assert.equal(playCheckHandler({}), undefined);
  assert.equal(playCheckHandler({ webkit: {} }), undefined);
  assert.equal(playCheckHandler({ webkit: { messageHandlers: {} } }), undefined);
  assert.equal(playCheckHandler({ webkit: { messageHandlers: { smPlayCheck: {} } } }), undefined);
  assert.equal(playCheckHandler(null), undefined);
  assert.equal(playCheckHandler({ location: { search: '?smPlayCheck=1', hash: '#smPlayCheck' } }), undefined);
});

test('with the handler, a message reaches it as posted; without, nothing happens', () => {
  const seen: PlayCheckMessage[] = [];
  reportPlayCheck({ type: 'started' }, hostWith((m) => seen.push(m)));
  assert.deepEqual(seen, [{ type: 'started' }]);
  assert.doesNotThrow(() => reportPlayCheck({ type: 'started' }, {}));
});

test('a web view that refuses a message does not break the page', () => {
  assert.doesNotThrow(() =>
    reportPlayCheck(
      { type: 'started' },
      hostWith(() => {
        throw new Error('web view gone');
      }),
    ),
  );
});

test('an opened packet says what the arrival page would show', () => {
  const read = (e: object, margins: object[], percentMargins: object[] = []) => ({ episode: episode(e), margins: margins as never, percentMargins: percentMargins as never });
  assert.deepEqual(messageForOpened(read({ audioUrl: 'https://example.com/a.mp3' }, [margin])), { type: 'verdict', verdict: 'plays' });
  assert.deepEqual(messageForOpened(read({ pageUrl: 'https://example.com/essay' }, [])), { type: 'verdict', verdict: 'cannot', reason: 'article' });
  assert.deepEqual(messageForOpened(read({}, [margin])), { type: 'verdict', verdict: 'cannot', reason: 'no-episode-audio' });
  // A Substack post's voice is settled only by reading the publisher, which the check does not do: it says so, and never "plays".
  assert.deepEqual(messageForOpened(read({ pageUrl: 'https://thezvi.substack.com/p/x' }, [margin])), { type: 'verdict', verdict: 'unverified', why: 'post-voice' });
});

test('a link that did not open says why, and only a link that is broken or off is a problem with the link', () => {
  const fail = (reason: ConstructorParameters<typeof ShareLinkError>[1]) => messageForFailure(new ShareLinkError('x', reason));
  assert.deepEqual(fail('damaged'), { type: 'failed', reason: 'link-broken' });
  assert.deepEqual(fail('expired'), { type: 'failed', reason: 'link-broken' });
  assert.deepEqual(fail('off'), { type: 'failed', reason: 'links-off' });
  assert.deepEqual(fail('offline'), { type: 'failed', reason: 'offline' });
  assert.deepEqual(fail('server'), { type: 'failed', reason: 'server' });
  assert.deepEqual(fail('other'), { type: 'failed', reason: 'server' });
  // A packet that opened as bytes but can't be read.
  assert.deepEqual(messageForFailure(new Error('bad packet')), { type: 'failed', reason: 'link-broken' });
});

// The settled check (#4454, PR 1b): the app answers each read, and the page never reads anything itself.
const POST = 'https://captured.example/p/voiceover';
const PAID = 'https://captured.example/p/paid-post';
const canPlay = (type: string) => (type.startsWith('audio/mpeg') || type.startsWith('audio/mp4') ? 'maybe' : '');

function appReads(pages: Record<string, CheckReadReply | Error>, audio: CheckReadReply | Error) {
  const asked: CheckReadRequest[] = [];
  const host = {
    webkit: {
      messageHandlers: {
        smPlayCheck: { postMessage: () => undefined },
        smPlayCheckRead: {
          postMessage: async (request: CheckReadRequest) => {
            asked.push(request);
            const reply = request.kind === 'page' ? pages[request.url] : audio;
            if (reply instanceof Error || reply === undefined) throw reply ?? new Error('no such page');
            return reply;
          },
        },
      },
    },
  };
  return { host, asked };
}
const post = (pageUrl: string) => ({ episode: episode({ pageUrl }), margins: [margin] as never, percentMargins: [] as never });
const episodeWithAudio = { episode: episode({ audioUrl: 'https://cdn.example/ep.mp3' }), margins: [margin] as never, percentMargins: [] as never };

test('a Substack post with a voice whose audio plays is `plays`, after one page read and one audio read through the app', async () => {
  const voicePage = feedFixture('substack-voiceover-page.html').toString();
  const { host, asked } = appReads({ [POST]: { status: 200, url: POST, body: voicePage } }, { status: 206, contentType: 'audio/mpeg' });
  assert.deepEqual(await messageForOpenedSettled(post(POST), host, canPlay), { type: 'verdict', verdict: 'plays' });
  assert.equal(asked.length, 2);
  assert.deepEqual(asked[0], { kind: 'page', url: POST });
  assert.equal(asked[1].kind, 'audio-start');
});

test('the #4433 case: a post whose page offers no voice says so before the friend meets it', async () => {
  const url = 'https://captured.example/p/failed';
  const post7 = { type: 'newsletter', audience: 'everyone', id: 7, canonical_url: url, audio_items: [{ post_id: 7, type: 'tts', status: 'failed', audio_url: null }] };
  const html = `<script>window._preloads = JSON.parse(${JSON.stringify(JSON.stringify({ post: post7 }))});</script>`;
  const { host, asked } = appReads({ [url]: { status: 200, url, body: html } }, { status: 200 });
  assert.deepEqual(await messageForOpenedSettled(post(url), host, canPlay), { type: 'verdict', verdict: 'cannot', reason: 'no-post-voice' });
  assert.equal(asked.length, 1, 'no audio to read');
});

test('a paid post says it is for paid subscribers', async () => {
  const { host } = appReads({ [PAID]: { status: 200, url: PAID, body: feedFixture('substack-paid-post-page.html').toString() } }, { status: 200 });
  assert.deepEqual(await messageForOpenedSettled(post(PAID), host, canPlay), { type: 'verdict', verdict: 'cannot', reason: 'paid-post' });
});

test('an episode\'s own audio is read once, at its start, and its answer is the verdict', async () => {
  const run = async (reply: CheckReadReply | Error) => messageForOpenedSettled(episodeWithAudio, appReads({}, reply).host, canPlay);
  assert.deepEqual(await run({ status: 206, contentType: 'audio/mpeg' }), { type: 'verdict', verdict: 'plays' });
  assert.deepEqual(await run({ status: 404, contentType: 'text/html' }), { type: 'verdict', verdict: 'cannot', reason: 'audio-refused' });
  assert.deepEqual(await run({ status: 403, contentType: 'text/html' }), { type: 'failed', reason: 'server' }, 'a host may refuse the app and serve a browser');
  assert.deepEqual(await run({ status: 200, contentType: 'text/html' }), { type: 'verdict', verdict: 'cannot', reason: 'audio-refused' });
  assert.deepEqual(await run({ status: 200, contentType: 'audio/x-ms-wma' }), { type: 'verdict', verdict: 'cannot', reason: 'audio-format' });
  assert.deepEqual(await run({ status: 503 }), { type: 'failed', reason: 'server' });
  assert.deepEqual(await run(new Error('offline')), { type: 'failed', reason: 'server' });
});

test('a packet with nothing to play is decided without any read', async () => {
  const { host, asked } = appReads({}, { status: 200 });
  const article = { episode: episode({ pageUrl: 'https://example.com/essay' }), margins: [] as never, percentMargins: [] as never };
  assert.deepEqual(await messageForOpenedSettled(article, host, canPlay), { type: 'verdict', verdict: 'cannot', reason: 'article' });
  assert.deepEqual(asked, []);
});

test('a failed page read is "couldn\'t check", never a warning about the post', async () => {
  const { host } = appReads({ [POST]: new Error('timed out') }, { status: 200 });
  assert.deepEqual(await messageForOpenedSettled(post(POST), host, canPlay), { type: 'failed', reason: 'server' });
  const missing = appReads({ [POST]: { status: 404 } }, { status: 200 });
  assert.deepEqual(await messageForOpenedSettled(post(POST), missing.host, canPlay), { type: 'failed', reason: 'server' });
});

test('without the read handler nothing is read: a post is `unverified` and an episode `plays` as before', async () => {
  assert.deepEqual(await messageForOpenedSettled(post(POST), {}, canPlay), { type: 'verdict', verdict: 'unverified', why: 'post-voice' });
  assert.deepEqual(await messageForOpenedSettled(episodeWithAudio, {}, canPlay), { type: 'verdict', verdict: 'plays' });
});

const preloadsPage = (post: object) => `<script>window._preloads = JSON.parse(${JSON.stringify(JSON.stringify({ post }))});</script>`;

test('a page that is not this post\'s data can\'t say the post has no voice', async () => {
  const url = 'https://captured.example/p/failed';
  const failed = { type: 'newsletter', audience: 'everyone', id: 7, canonical_url: url, audio_items: [{ post_id: 7, type: 'tts', status: 'failed', audio_url: null }] };
  const unclear = { type: 'verdict', verdict: 'unverified', why: 'post-voice' };
  const run = async (reply: CheckReadReply) => messageForOpenedSettled(post(url), appReads({ [url]: reply }, { status: 200 }).host, canPlay);
  // A bot-check page, an empty answer and a changed layout have no post data.
  assert.deepEqual(await run({ status: 200, url, body: '<html>Just a moment...</html>' }), unclear);
  assert.deepEqual(await run({ status: 204 }), unclear);
  assert.deepEqual(await run({ status: 200, url, body: '<script>window._preloads = JSON.parse("{}");</script>' }), unclear);
  // Another post's data, or an app that reports no final address while the page's own address differs.
  assert.deepEqual(await run({ status: 200, url, body: preloadsPage({ ...failed, canonical_url: 'https://captured.example/p/other' }) }), unclear);
  const elsewhere = 'https://open.substack.com/pub/x/p/failed';
  const moved = appReads({ [elsewhere]: { status: 200, body: preloadsPage(failed) } }, { status: 200 });
  assert.deepEqual(await messageForOpenedSettled(post(elsewhere), moved.host, canPlay), unclear);
  // The same page with its own address is the clear case.
  assert.deepEqual(await run({ status: 200, url, body: preloadsPage(failed) }), { type: 'verdict', verdict: 'cannot', reason: 'no-post-voice' });
});

test('only a Substack post\'s page is read, and only with both of the app\'s handlers', async () => {
  const other = appReads({}, { status: 200 });
  const essay = post('https://example.com/essay');
  // #4767: a page that is not a Substack post has no voice a browser could find, so it is a plain "can't play", not "couldn't tell".
  assert.deepEqual(await messageForOpenedSettled(essay, other.host, canPlay), { type: 'verdict', verdict: 'cannot', reason: 'no-episode-audio' });
  assert.deepEqual(other.asked, [], 'a page that is not a Substack post is never read');
  // #4783: an Apple Podcasts episode page is looked up (the tests below). Without the app's handlers nothing is read, so it
  // says "couldn't tell", never "can't play" for an episode the friend will be able to hear.
  const apple = post('https://podcasts.apple.com/us/podcast/people-parks-and-policy-with-rffs-margaret-walls/id1445582279?i=1000427709574');
  assert.deepEqual(await messageForOpenedSettled(apple, {}, canPlay), { type: 'verdict', verdict: 'unverified', why: 'post-voice' });
  // An Apple show page with no episode id has nothing to look up: a plain "can't play".
  const show = post('https://podcasts.apple.com/us/podcast/people-parks-and-policy/id1445582279');
  assert.deepEqual(await messageForOpenedSettled(show, other.host, canPlay), { type: 'verdict', verdict: 'cannot', reason: 'no-episode-audio' });
  const spotify = post('https://open.spotify.com/episode/4rOoJ6Egrf8K2IrywzwOMk');
  assert.deepEqual(await messageForOpenedSettled(spotify, other.host, canPlay), { type: 'verdict', verdict: 'cannot', reason: 'no-episode-audio' });
  assert.deepEqual(other.asked, []);
  const readOnly = appReads({ [POST]: { status: 200, url: POST, body: feedFixture('substack-voiceover-page.html').toString() } }, { status: 206, contentType: 'audio/mpeg' });
  delete (readOnly.host.webkit.messageHandlers as { smPlayCheck?: unknown }).smPlayCheck;
  assert.deepEqual(await messageForOpenedSettled(post(POST), readOnly.host, canPlay), { type: 'verdict', verdict: 'unverified', why: 'post-voice' });
  assert.deepEqual(readOnly.asked, [], 'with no probe handler nobody would hear a verdict, so nothing is read');
});

// An Apple Podcasts episode with no audio address (#4783, the owner's yes on 2026-11-23): the check makes the friend's page's
// own lookup through the app (Apple's lookup, then the show's feed), so the sender's line and the friend's card agree.
const APPLE_PAGE = 'https://podcasts.apple.com/us/podcast/people-parks-and-policy-with-rffs-margaret-walls/id1445582279?i=1000427709574';
const LOOKUP = 'https://itunes.apple.com/lookup?id=1445582279&entity=podcastEpisode&limit=200';
const FEED = 'https://feeds.soundcloud.com/users/soundcloud:users:1/sounds.rss';
const TITLE = 'People, Parks, and Policy with RFF\u2019s Margaret Walls';
const ENCLOSURE = 'https://feeds.soundcloud.com/stream/559432260-resourcesradio-people-parks-and-policy-with-rffs-margaret-walls.mp3';
const appleEpisode = { episode: episode({ title: TITLE, pageUrl: APPLE_PAGE }), margins: [margin] as never, percentMargins: [] as never };
const showRow = (feedUrl = FEED) => ({ wrapperType: 'track', kind: 'podcast', collectionId: 1445582279, feedUrl });
const listed = { wrapperType: 'podcastEpisode', trackId: 1000427709574, episodeUrl: ENCLOSURE };
const otherEpisode = { wrapperType: 'podcastEpisode', trackId: 1000427709000, episodeUrl: 'https://example.com/other.mp3' };
const rss = (...titles: string[]) =>
  `<?xml version="1.0"?><rss version="2.0"><channel><title>Resources Radio</title>${titles
    .map((t, i) => `<item><title>${t}</title><guid>g${i}</guid><enclosure type="audio/mpeg" url="${i === titles.length - 1 ? ENCLOSURE : `https://example.com/${i}.mp3`}" length="1"/></item>`)
    .join('')}</channel></rss>`;
const UNCLEAR = { type: 'verdict', verdict: 'unverified', why: 'post-voice' };
const NO_AUDIO = { type: 'verdict', verdict: 'cannot', reason: 'no-episode-audio' };

/** The app's reads, answered by kind; `refuse` lists kinds the app won't read (an older build refuses kinds it predates). */
function appleReads(answers: { lookup?: CheckReadReply | Error; feed?: CheckReadReply | Error; audio?: CheckReadReply | Error }, refuse: string[] = []) {
  const asked: CheckReadRequest[] = [];
  const host = {
    webkit: {
      messageHandlers: {
        smPlayCheck: { postMessage: () => undefined },
        smPlayCheckRead: {
          postMessage: async (request: CheckReadRequest) => {
            asked.push(request);
            if (refuse.includes(request.kind)) throw new Error(READ_REFUSED);
            const reply = request.kind === 'apple-lookup' ? answers.lookup : request.kind === 'feed' ? answers.feed : request.kind === 'audio-start' ? answers.audio : undefined;
            if (reply instanceof Error || reply === undefined) throw reply ?? new Error(`no answer for ${request.kind}`);
            return reply;
          },
        },
      },
    },
  };
  return { host, asked };
}
const json = (results: object[]): CheckReadReply => ({ status: 200, url: LOOKUP, body: JSON.stringify({ resultCount: results.length, results }) });
const AUDIO_OK: CheckReadReply = { status: 206, contentType: 'audio/mpeg' };

test('an Apple episode Apple lists plays: one lookup and one audio start, through the app, no feed read', async () => {
  const { host, asked } = appleReads({ lookup: json([showRow(), listed]), audio: AUDIO_OK });
  assert.deepEqual(await messageForOpenedSettled(appleEpisode, host, canPlay), { type: 'verdict', verdict: 'plays' });
  assert.deepEqual(asked, [{ kind: 'apple-lookup', url: LOOKUP }, { kind: 'audio-start', url: ENCLOSURE }]);
});

test('the owner\'s 2019 episode: Apple doesn\'t list it, the show\'s feed has it by its exact title, and it plays', async () => {
  const { host, asked } = appleReads({ lookup: json([showRow(), otherEpisode]), feed: { status: 200, url: FEED, body: rss('Newest', TITLE) }, audio: AUDIO_OK });
  assert.deepEqual(await messageForOpenedSettled(appleEpisode, host, canPlay), { type: 'verdict', verdict: 'plays' });
  assert.deepEqual(asked, [{ kind: 'apple-lookup', url: LOOKUP }, { kind: 'feed', url: FEED }, { kind: 'audio-start', url: ENCLOSURE }]);
});

test('an Apple episode with no audio to find says what the friend\'s card says, never a guess between two titles', async () => {
  const run = async (answers: Parameters<typeof appleReads>[0]) => messageForOpenedSettled(appleEpisode, appleReads(answers).host, canPlay);
  // Apple lists it with no audio address, and the feed holds no item with its title.
  assert.deepEqual(await run({ lookup: json([showRow(), { ...listed, episodeUrl: undefined }]), feed: { status: 200, url: FEED, body: rss('Newest', 'Another episode') } }), NO_AUDIO);
  // Two feed items with the same title: ambiguous, so not played (the friend's page refuses it the same way).
  assert.deepEqual(await run({ lookup: json([showRow(), otherEpisode]), feed: { status: 200, url: FEED, body: rss(TITLE, TITLE) } }), NO_AUDIO);
  // Apple names no feed for the show, or answers with no results.
  assert.deepEqual(await run({ lookup: json([{ wrapperType: 'track', kind: 'podcast' }, otherEpisode]) }), NO_AUDIO);
  assert.deepEqual(await run({ lookup: { status: 200, url: LOOKUP, body: '{"resultCount":0,"results":[]}' } }), NO_AUDIO);
  // A feed address that is not a feed.
  assert.deepEqual(await run({ lookup: json([showRow(), otherEpisode]), feed: { status: 200, url: FEED, body: 'just text, not a feed' } }), NO_AUDIO);
});

test('a found Apple episode whose audio a browser can\'t use says why', async () => {
  const run = async (audio: CheckReadReply) => messageForOpenedSettled(appleEpisode, appleReads({ lookup: json([showRow(), listed]), audio }).host, canPlay);
  assert.deepEqual(await run({ status: 404, contentType: 'text/html' }), { type: 'verdict', verdict: 'cannot', reason: 'audio-refused' });
  assert.deepEqual(await run({ status: 200, contentType: 'audio/x-ms-wma' }), { type: 'verdict', verdict: 'cannot', reason: 'audio-format' });
  assert.deepEqual(await run({ status: 503 }), { type: 'failed', reason: 'server' });
});

test('a lookup or feed read that fails is "couldn\'t check", never a warning', async () => {
  const run = async (answers: Parameters<typeof appleReads>[0]) => messageForOpenedSettled(appleEpisode, appleReads(answers).host, canPlay);
  const FAILED = { type: 'failed', reason: 'server' };
  assert.deepEqual(await run({ lookup: new Error('offline') }), FAILED);
  assert.deepEqual(await run({ lookup: { status: 503, url: LOOKUP, body: '' } }), FAILED);
  assert.deepEqual(await run({ lookup: { status: 200, url: LOOKUP, body: '<html>not json</html>' } }), FAILED);
  assert.deepEqual(await run({ lookup: json([showRow(), otherEpisode]), feed: new Error('The read failed.') }), FAILED);
  assert.deepEqual(await run({ lookup: json([showRow(), otherEpisode]), feed: { status: 500, url: FEED, body: '' } }), FAILED);
});

test('a feed over the size cap says what the friend\'s browser says, which stops at the same size: no audio to find', async () => {
  const { host } = appleReads({ lookup: json([showRow(), otherEpisode]), feed: { status: 200, url: FEED, tooLarge: true } });
  assert.deepEqual(await messageForOpenedSettled(appleEpisode, host, canPlay), NO_AUDIO);
});

test('an app that predates these reads refuses them, and the check says "couldn\'t tell" as before', async () => {
  const old = appleReads({ lookup: json([showRow(), listed]), audio: AUDIO_OK }, ['apple-lookup', 'feed']);
  assert.deepEqual(await messageForOpenedSettled(appleEpisode, old.host, canPlay), UNCLEAR);
  assert.deepEqual(old.asked.map((r) => r.kind), ['apple-lookup']);
  // A feed read the app refuses (it names a feed Apple's answer didn't) is the same "couldn't tell".
  const feedRefused = appleReads({ lookup: json([showRow(), otherEpisode]) }, ['feed']);
  assert.deepEqual(await messageForOpenedSettled(appleEpisode, feedRefused.host, canPlay), UNCLEAR);
});

test('a feed Apple names as http:// is asked of the app as https://, and its title still matches', async () => {
  const httpFeed = 'http://feeds.soundcloud.com/users/soundcloud:users:1/sounds.rss';
  const { host, asked } = appleReads({ lookup: json([showRow(httpFeed), otherEpisode]), feed: { status: 200, url: FEED, body: rss(TITLE) }, audio: AUDIO_OK });
  assert.deepEqual(await messageForOpenedSettled(appleEpisode, host, canPlay), { type: 'verdict', verdict: 'plays' });
  assert.deepEqual(asked[1], { kind: 'feed', url: FEED });
});
