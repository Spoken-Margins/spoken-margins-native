import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ShareLinkError } from './logic/share-link.ts';
import { messageForFailure, messageForOpened, messageForOpenedSettled, playCheckHandler, reportPlayCheck, type PlayCheckMessage } from './play-check.ts';
import { PaidPostNoVoice } from '../sources/read.ts';
import { feedFixture } from '../sources/fixtures.ts';
import type { CheckReadReply, CheckReadRequest } from './play-check-reads.ts';

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
  assert.ok(new PaidPostNoVoice(PAID));
});

test('an episode\'s own audio is read once, at its start, and its answer is the verdict', async () => {
  const run = async (reply: CheckReadReply | Error) => messageForOpenedSettled(episodeWithAudio, appReads({}, reply).host, canPlay);
  assert.deepEqual(await run({ status: 206, contentType: 'audio/mpeg' }), { type: 'verdict', verdict: 'plays' });
  assert.deepEqual(await run({ status: 403, contentType: 'text/html' }), { type: 'verdict', verdict: 'cannot', reason: 'audio-refused' });
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
