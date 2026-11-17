import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ShareLinkError } from './logic/share-link.ts';
import { messageForFailure, messageForOpened, playCheckHandler, reportPlayCheck, type PlayCheckMessage } from './play-check.ts';

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
