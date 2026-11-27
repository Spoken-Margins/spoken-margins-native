import assert from 'node:assert/strict';
import { test } from 'node:test';

import { sealPart } from '../../cli/link-sealing.ts';
import { PART } from '../../packet/share-link.ts';
import type { Margin } from '../../shared/model.ts';
import {
  INTRO_FETCH_CEILING_MS, fetchIntroMark, isIntroPreview, keepingFromIntro, linkShareFetch, openIntroMark, withFromIntro,
} from './intro-link.ts';
import type { ReplyBox } from './reply-box.ts';

const base = { schema: 'spokenmargins.link-preview.v1', source: { title: 'T' }, margins: [{ text: 'x' }] };

test('#4784 only answers "none" marks an introduction link; anything else is no mark', () => {
  const rows: [string, unknown, boolean][] = [
    ['the mark', { ...base, answers: 'none' }, true],
    ['no field: a conversation link', base, false],
    ['a later build\'s value', { ...base, answers: 'box' }, false],
    ['case differs', { ...base, answers: 'None' }, false],
    ['padded', { ...base, answers: ' none' }, false],
    ['a boolean', { ...base, answers: true }, false],
    ['an array', { ...base, answers: ['none'] }, false],
    ['null field', { ...base, answers: null }, false],
    ['empty string', { ...base, answers: '' }, false],
    ['null preview', null, false],
    ['undefined preview (fetch failed or slow)', undefined, false],
    ['a string', 'none', false],
    ['an array preview', ['none'], false],
  ];
  for (const [label, preview, expected] of rows) assert.equal(isIntroPreview(preview), expected, label);
});

// #4784 slice 2: reading the mark from a link's sealed preview, and marking the link's Margins.

const key = new Uint8Array(32).fill(7);
const link = { origin: 'https://links.example', id: 'introvoice01', key };
const sealed = async (preview: unknown): Promise<Uint8Array> =>
  sealPart(new TextEncoder().encode(JSON.stringify(preview)), PART.preview, key);
function server(status: number, body: BodyInit | null) {
  const asked: { url: string; init: RequestInit | undefined }[] = [];
  const fetchImpl = (async (url: string | URL | Request, init?: RequestInit) => {
    asked.push({ url: String(url), init });
    return new Response(body, { status });
  }) as typeof fetch;
  return { asked, fetchImpl };
}

test('#4784 openIntroMark reads the mark only from a preview that opens under the link key', async () => {
  assert.equal(await openIntroMark(await sealed({ ...base, answers: 'none' }), key), true);
  assert.equal(await openIntroMark(await sealed(base), key), false);
  assert.equal(await openIntroMark(await sealed({ ...base, answers: 'box' }), key), false);
  assert.equal(await openIntroMark(await sealed({ ...base, answers: 'none' }), new Uint8Array(32).fill(8)), false, 'another key');
  assert.equal(await openIntroMark(await sealPart(new TextEncoder().encode('{"answers":"none"}'), PART.packet, key), key), false, 'the packet part');
  assert.equal(await openIntroMark(await sealPart(new TextEncoder().encode('not json'), PART.preview, key), key), false);
  assert.equal(await openIntroMark(new Uint8Array(40), key), false);
});

test('#4784 fetchIntroMark asks the link’s own preview route with no credentials and never sends the key', async () => {
  const { asked, fetchImpl } = server(200, (await sealed({ ...base, answers: 'none' })) as BodyInit);
  assert.equal(await fetchIntroMark(link, fetchImpl), true);
  assert.equal(asked.length, 1);
  assert.equal(asked[0].url, 'https://links.example/l/introvoice01/preview');
  assert.equal(asked[0].init?.credentials, 'omit');
  assert.equal(asked[0].init?.referrerPolicy, 'no-referrer');
  assert.equal(await fetchIntroMark(link, server(200, (await sealed(base)) as BodyInit).fetchImpl), false, 'a conversation link');
});

test('#4784 a preview fetch that fails or is slow counts as no mark, and the slow one is aborted', async () => {
  for (const status of [404, 410, 503, 500]) assert.equal(await fetchIntroMark(link, server(status, '{}').fetchImpl), false, String(status));
  const offline = (async () => {
    throw new TypeError('Failed to fetch');
  }) as typeof fetch;
  assert.equal(await fetchIntroMark(link, offline), false);
  assert.equal(INTRO_FETCH_CEILING_MS, 5_000);
  let aborted = false;
  const hanging = ((_url: string, init?: RequestInit) =>
    new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener('abort', () => {
        aborted = true;
        reject(new DOMException('aborted', 'AbortError'));
      });
    })) as unknown as typeof fetch;
  assert.equal(await fetchIntroMark(link, hanging, 20), false);
  assert.equal(aborted, true);
});

const m = (id: string, extra: Partial<Margin> = {}): Margin =>
  ({ id, episodeId: 'e', atSeconds: 1, text: id, createdAt: '2026-11-27T00:00:00Z', ...extra }) as Margin;

test('#4784 withFromIntro marks only the friend’s stored Margins, once each', () => {
  const stored = [m('f1', { author: 'Cole' }), m('f2', { author: 'Cole', fromIntro: true }), m('own'), m('own2', { author: '' })];
  const out = withFromIntro(['f1', 'f1', 'f2', 'own', 'own2', 'gone'], stored);
  assert.deepEqual(out.map((x) => [x.id, x.fromIntro]), [['f1', true]]);
  assert.equal(stored[0].fromIntro, undefined, 'the stored copy is not changed in place');
});

test('#4784 a rewrite keeps a stored introduction mark, and never adds one to the listener’s own Margin', () => {
  const friend = m('f1', { author: 'Cole' });
  assert.equal(keepingFromIntro(friend, { ...friend, fromIntro: true }).fromIntro, true);
  assert.equal(keepingFromIntro(friend, friend).fromIntro, undefined);
  assert.equal(keepingFromIntro(friend, undefined).fromIntro, undefined);
  assert.equal(keepingFromIntro(m('own'), { ...m('own'), fromIntro: true }).fromIntro, undefined);
});

test('#4784 an introduction mark wins over a reply part: the Margins are marked first and no box is offered', async () => {
  const box = { linkId: 'x' } as unknown as ReplyBox;
  const order: string[] = [];
  const mark = async () => {
    order.push('marked');
  };
  assert.equal(await linkShareFetch(Promise.resolve(box), Promise.resolve(true), mark), undefined);
  assert.deepEqual(order, ['marked']);

  order.length = 0;
  assert.equal(await linkShareFetch(Promise.resolve(box), Promise.resolve(false), mark), box, 'a conversation link keeps its box');
  assert.equal(await linkShareFetch(Promise.resolve(undefined), Promise.resolve(false), mark), undefined);
  assert.deepEqual(order, [], 'a conversation link marks nothing');

  const failing = async () => {
    throw new Error('not kept');
  };
  const warn = console.warn;
  console.warn = () => {};
  try {
    assert.equal(await linkShareFetch(Promise.resolve(box), Promise.resolve(true), failing), undefined, 'a mark not kept still offers no box');
    assert.equal(await linkShareFetch(Promise.reject(new Error('x')), Promise.reject(new Error('y')), mark), undefined, 'two failed fetches: today’s section');
  } finally {
    console.warn = warn;
  }
});
