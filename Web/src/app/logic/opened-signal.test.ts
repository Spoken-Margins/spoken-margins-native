import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PART, keyFromFragment } from '../../packet/share-link.ts';
import { sealPart } from '../../cli/link-sealing.ts';
import { readSettings, DEFAULT_SETTINGS } from '../store/schema.ts';
import {
  dontTellLabel,
  inSenderCheck,
  mayOffer,
  openedNotice,
  openedSignaller,
  openedToken,
  postOpened,
  toldNotNotice,
  withSignalled,
  type OpenedGate,
} from './opened-signal.ts';
import { openSharedPacketWithExpiry } from './share-link.ts';

const repo = new URL('../../../../', import.meta.url);
const vector = JSON.parse(readFileSync(new URL('research/B4/contracts/fixtures/share-link-opened-token.json', repo), 'utf8'));
const ID = vector.linkID as string;
const gate = (over: Partial<OpenedGate> = {}): OpenedGate => ({ offered: true, receiptsOn: true, signalled: {}, id: ID, probe: false, ...over });

test('the token matches the shared vector the app and the server use', async () => {
  const key = keyFromFragment(`#${vector.keyFragment}`);
  assert.ok(key);
  assert.equal(await openedToken(key, ID), vector.tokenHex);
  assert.equal(await openedToken(key, vector.otherLinkID), vector.otherTokenHex);
});

test('the notice is offered only for a server that keeps marks, with the switch on, once, outside the play check', () => {
  assert.equal(mayOffer(gate()), true);
  assert.equal(mayOffer(gate({ offered: false })), false, 'no header, no notice');
  assert.equal(mayOffer(gate({ receiptsOn: false })), false, 'switch off');
  assert.equal(mayOffer(gate({ signalled: { [ID]: '2026-11-24T00:00:00.000Z' } })), false, 'this browser already told it');
  assert.equal(mayOffer(gate({ probe: true })), false, "the sender's hidden play check");
});

test("the sender's play check is recognised by its message handler", () => {
  assert.equal(inSenderCheck({ webkit: { messageHandlers: { smPlayCheck: { postMessage() {} } } } }), true);
  assert.equal(inSenderCheck({}), false);
});

function ports(over: Partial<OpenedGate> = {}, results: boolean[] = [true]) {
  const posts: string[] = [];
  const remembered: string[] = [];
  let current = gate(over);
  const send = openedSignaller({
    gate: () => current,
    token: async () => vector.tokenHex,
    post: async (token) => {
      posts.push(token);
      return results.shift() ?? true;
    },
    remember: async (id) => {
      remembered.push(id);
      current = { ...current, signalled: { ...current.signalled, [id]: 'now' } };
    },
  });
  return { send, posts, remembered, set: (next: Partial<OpenedGate>) => (current = { ...current, ...next }) };
}

test('switch off: the network is never called', async () => {
  const { send, posts } = ports({ receiptsOn: false });
  await send();
  await send();
  assert.deepEqual(posts, []);
});

test('no header, a stored id or the play check: nothing is sent', async () => {
  for (const over of [{ offered: false }, { signalled: { [ID]: 'x' } }, { probe: true }]) {
    const { send, posts } = ports(over);
    await send();
    assert.deepEqual(posts, [], JSON.stringify(over));
  }
});

test('two start taps send one POST, and the link is remembered', async () => {
  const { send, posts, remembered } = ports();
  await Promise.all([send(), send()]);
  await send();
  assert.deepEqual(posts, [vector.tokenHex]);
  assert.deepEqual(remembered, [ID]);
});

test('offline at the start tap: not remembered, and the next start control tries again', async () => {
  const { send, posts, remembered } = ports({}, [false, true]);
  await send();
  assert.deepEqual(remembered, []);
  await send();
  assert.equal(posts.length, 2);
  assert.deepEqual(remembered, [ID]);
});

test("Don't tell turns the switch off before the first tap, so nothing leaves", async () => {
  const { send, posts, set } = ports();
  set({ receiptsOn: false });
  await send();
  assert.deepEqual(posts, []);
});

test('the request is a no-cors simple POST with no credentials and exactly the token as its body', async () => {
  const seen: { url: string; init: RequestInit }[] = [];
  const fake = (async (url: string, init: RequestInit) => {
    seen.push({ url, init });
    return new Response(null, { status: 204 });
  }) as unknown as typeof fetch;
  assert.equal(await postOpened('https://spokenmargins.com', ID, vector.tokenHex, fake), true);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].url, `https://spokenmargins.com/l/${ID}/opened`);
  assert.equal(seen[0].init.method, 'POST');
  assert.equal(seen[0].init.mode, 'no-cors');
  assert.equal(seen[0].init.credentials, 'omit');
  assert.equal(seen[0].init.keepalive, true);
  assert.equal(seen[0].init.body, vector.tokenHex);
  assert.equal(seen[0].init.headers, undefined, 'no extra header, so no preflight');
  const offline = (async () => {
    throw new TypeError('Failed to fetch');
  }) as unknown as typeof fetch;
  assert.equal(await postOpened('https://spokenmargins.com', ID, vector.tokenHex, offline), false);
});

test('the signalled set drops entries past 31 days', () => {
  const now = new Date('2026-11-24T12:00:00Z');
  const next = withSignalled({ old: '2026-10-20T00:00:00.000Z', recent: '2026-11-20T00:00:00.000Z', junk: 'not a date' }, ID, now);
  assert.deepEqual(Object.keys(next).sort(), [ID, 'recent'].sort());
  assert.equal(next[ID], now.toISOString());
});

test('the words name the sender, or say your friend and them', () => {
  assert.equal(openedNotice('Ana'), 'When you open these Margins, Ana can see that you did.');
  assert.equal(dontTellLabel('Ana'), 'Don’t tell Ana');
  assert.equal(toldNotNotice('Ana'), 'Ana won’t be told. Change this in Settings.');
  assert.equal(openedNotice('your friend'), 'When you open these Margins, your friend can see that you did.');
  assert.equal(dontTellLabel('your friend'), 'Don’t tell them');
  assert.equal(toldNotNotice('your friend'), 'Your friend won’t be told. Change this in Settings.');
});

test('the switch is on by default, and the stored set reads back only as strings', () => {
  assert.equal(DEFAULT_SETTINGS.openedReceipts, true);
  assert.deepEqual(readSettings([]).openedSignalled, {});
  assert.equal(readSettings([{ key: 'openedReceipts', value: false }]).openedReceipts, false);
  assert.deepEqual(readSettings([{ key: 'openedSignalled', value: { [ID]: '2026-11-24' } }]).openedSignalled, { [ID]: '2026-11-24' });
  assert.deepEqual(readSettings([{ key: 'openedSignalled', value: { [ID]: 3 } }]).openedSignalled, {});
  assert.deepEqual(readSettings([{ key: 'openedSignalled', value: ['x'] }]).openedSignalled, {});
});

test('the packet fetch reads X-SM-Link-Opened', async () => {
  const sealingVector = JSON.parse(readFileSync(new URL('research/B4/contracts/fixtures/share-link-sealing-vector.json', repo), 'utf8'));
  const key = keyFromFragment(`#${sealingVector.keyFragment}`);
  assert.ok(key);
  const sealed = await sealPart(new Uint8Array([80, 75, 3, 4]), PART.packet, key);
  for (const [headers, expected] of [[{ 'X-SM-Link-Opened': '1' }, true], [{}, false], [{ 'X-SM-Link-Opened': '0' }, false]] as const) {
    const fake = (async () => new Response(sealed as BodyInit, { status: 200, headers })) as unknown as typeof fetch;
    const result = await openSharedPacketWithExpiry({ origin: 'https://spokenmargins.com', id: ID, key }, fake);
    assert.equal(result.offersOpened, expected, JSON.stringify(headers));
  }
});
