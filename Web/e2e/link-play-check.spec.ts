// The sender's background check (#4454, slice 1): the iPhone app loads a share link in a hidden web view that has a
// `smPlayCheck` message handler, and the page answers "would this play?" with one message, without playing anything.
// Here a stub handler stands in for the app's, against the local link stub (e2e/link-stub-server.ts).
//
// The check must read nothing but the packet: no POST or PUT, no relay, no report page, no publisher, no audio, no
// stored data. Without the handler (every friend's browser) the page is the page it always was.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { expect, test, type Page, type Request } from '@playwright/test';
import { feedFixture, serveFixtures } from './fixtures.ts';

const STUB = 'http://127.0.0.1:4174';
const vector = JSON.parse(
  readFileSync(fileURLToPath(new URL('../../research/B4/contracts/fixtures/share-link-sealing-vector.json', import.meta.url)), 'utf8'),
);
const KEY: string = vector.keyFragment;

test.use({ baseURL: `${STUB}/` });

test.beforeEach(async ({}, info) => {
  test.skip(info.project.name !== 'phone', 'The link stub is one server; this runs once, at a phone size.');
});

/** What the stub `smPlayCheckRead` handler answers (the app's reads, PR 1b): pages by address, and the audio's start. */
interface Reads {
  pages: Record<string, { status: number; url?: string; body?: string }>;
  audio: { status: number; contentType?: string } | 'reject';
}

interface Probe {
  /** What the page asked the app to read, in order. */
  asked: () => Promise<{ kind: string; url: string }[]>;
  messages: () => Promise<unknown[]>;
  /** Writes to the stores that hold a listener's things: shows, episodes, Margins, places. A fresh store also records its own schema version (one `settings` row) when it first opens; that is the store, not the item. */
  idbWrites: () => Promise<string[]>;
  requests: Request[];
}

/** Gives the page the handler the app injects, records what it is sent, and counts every request and IndexedDB write. */
async function asHiddenCheck(page: Page, withHandler = true, reads?: Reads): Promise<Probe> {
  const requests: Request[] = [];
  page.on('request', (request) => requests.push(request));
  await page.addInitScript(
    ({ withHandler: install, reads: readsConfig }) => {
      const w = window as unknown as Record<string, unknown>;
      w.__sent = [];
      w.__asked = [];
      w.__idbWrites = [];
      if (install && readsConfig) {
        const handlers = (w.webkit ??= { messageHandlers: {} }) as { messageHandlers: Record<string, unknown> };
        handlers.messageHandlers.smPlayCheckRead = {
          postMessage: async (request: { kind: string; url: string }) => {
            (w.__asked as unknown[]).push(JSON.parse(JSON.stringify(request)));
            if (request.kind === 'page') {
              const page = readsConfig.pages[request.url];
              if (!page) throw new Error('no such page');
              return page;
            }
            if (readsConfig.audio === 'reject') throw new Error('offline');
            return readsConfig.audio;
          },
        };
      }
      if (install) {
        const webkit = (w.webkit ??= { messageHandlers: {} }) as { messageHandlers: Record<string, unknown> };
        webkit.messageHandlers.smPlayCheck = { postMessage: (m: unknown) => (w.__sent as unknown[]).push(JSON.parse(JSON.stringify(m))) };
      }
      for (const method of ['put', 'add', 'delete', 'clear'] as const) {
        const original = IDBObjectStore.prototype[method] as (...args: unknown[]) => IDBRequest;
        (IDBObjectStore.prototype as unknown as Record<string, unknown>)[method] = function (this: IDBObjectStore, ...args: unknown[]) {
          (w.__idbWrites as string[]).push(`${this.name}.${method}`);
          return original.apply(this, args);
        };
      }
    },
    { withHandler, reads },
  );
  return {
    asked: () => page.evaluate(() => (window as unknown as { __asked: { kind: string; url: string }[] }).__asked),
    messages: () => page.evaluate(() => (window as unknown as { __sent: unknown[] }).__sent),
    idbWrites: () => page.evaluate(() => (window as unknown as { __idbWrites: string[] }).__idbWrites.filter((w) => !w.startsWith('settings.'))),
    requests,
  };
}

/** Everything the check may touch besides the page's own files: the sealed packet, from the link server. */
function assertReadOnlyPacketLoad(probe: Probe, id: string) {
  for (const request of probe.requests) {
    const url = new URL(request.url());
    expect(request.method(), `${request.method()} ${request.url()}`).toBe('GET');
    expect(url.pathname, 'no relay').not.toContain('/api/v1/relay');
    expect(url.search, 'no report page').not.toContain('report');
    expect(url.origin === STUB, `only the link server and the app's own host: ${request.url()}`).toBe(true);
  }
  const sealed = probe.requests.filter((r) => /\/l\/[^/]+\/(packet|preview)$/.test(new URL(r.url()).pathname)).map((r) => new URL(r.url()).pathname);
  expect(sealed).toEqual([`/l/${id}/packet`]);
}

async function check(page: Page, id: string, reads?: Reads): Promise<Probe> {
  await serveFixtures(page);
  const probe = await asHiddenCheck(page, true, reads);
  await page.goto(`${STUB}/l/${id}#${KEY}`);
  await expect.poll(async () => (await probe.messages()).length, { timeout: 15_000 }).toBeGreaterThanOrEqual(2);
  return probe;
}

test('a podcast link with its own audio says it plays, after saying the check started; nothing is played, stored or sent', async ({ page }) => {
  const probe = await check(page, 'vectorvoice01');
  expect(await probe.messages()).toEqual([{ type: 'started' }, { type: 'verdict', verdict: 'plays' }]);
  assertReadOnlyPacketLoad(probe, 'vectorvoice01');
  expect(await probe.idbWrites()).toEqual([]);
  // The player was never touched: no audio source, nothing playing.
  const audio = page.getByTestId('audio');
  expect(await audio.evaluate((a: HTMLAudioElement) => a.paused)).toBe(true);
  expect(await audio.evaluate((a: HTMLAudioElement) => a.getAttribute('src') ?? '')).toBe('');
  await expect(page.locator('.now-playing')).toHaveCount(0);
});

test('a Substack post is reported unverified, because settling it takes a publisher read the check does not make', async ({ page }) => {
  const publisher: string[] = [];
  await page.route('https://thezvi.substack.com/**', (route) => {
    publisher.push(route.request().url());
    return route.abort();
  });
  const probe = await check(page, 'vectorpost01');
  expect(await probe.messages()).toEqual([{ type: 'started' }, { type: 'verdict', verdict: 'unverified', why: 'post-voice' }]);
  assertReadOnlyPacketLoad(probe, 'vectorpost01');
  expect(publisher).toEqual([]);
  expect(await probe.idbWrites()).toEqual([]);
});

test('an article on an ordinary site is the `article` verdict, and the card says the same thing', async ({ page }) => {
  const probe = await check(page, 'vectorarticle1');
  expect(await probe.messages()).toEqual([{ type: 'started' }, { type: 'verdict', verdict: 'cannot', reason: 'article' }]);
  await expect(page.getByTestId('arrival').getByText('which the browser can’t play yet')).toBeVisible();
  assertReadOnlyPacketLoad(probe, 'vectorarticle1');
  expect(await probe.idbWrites()).toEqual([]);
});

test('an expired link and a link switched off say so, as a problem with the link and not with the sender’s phone', async ({ page }) => {
  const gone = await check(page, 'expired00001');
  expect(await gone.messages()).toEqual([{ type: 'started' }, { type: 'failed', reason: 'link-broken' }]);
  const off = await check(await page.context().newPage(), 'switchedoff1');
  expect(await off.messages()).toEqual([{ type: 'started' }, { type: 'failed', reason: 'links-off' }]);
});

test('a cut-off link says it is broken', async ({ page }) => {
  await serveFixtures(page);
  const probe = await asHiddenCheck(page);
  await page.goto(`${STUB}/l/vectorvoice01#cut-off`);
  await expect.poll(async () => (await probe.messages()).length, { timeout: 15_000 }).toBeGreaterThanOrEqual(2);
  expect(await probe.messages()).toEqual([{ type: 'started' }, { type: 'failed', reason: 'link-broken' }]);
});

test('without the app’s handler the page is the page a friend sees, and a link cannot turn the check on', async ({ page }) => {
  await serveFixtures(page);
  const probe = await asHiddenCheck(page, false);
  // A query or fragment naming the check is not a switch: the link is refused as a damaged link, nothing is posted.
  await page.goto(`${STUB}/l/vectorvoice01?smPlayCheck=1#${KEY}`);
  await expect(page.getByTestId('arrival-failed')).toBeVisible();
  expect(await probe.messages()).toEqual([]);
  await page.goto(`${STUB}/l/vectorvoice01#${KEY}`);
  await expect(page.getByTestId('arrival').getByRole('button', { name: 'Play' })).toBeVisible();
  expect(await probe.messages()).toEqual([]);
});

// PR 1b: with the app's read handler the check settles what only the publisher can say, through the app, once. The page's
// own network never touches the publisher, the audio host or the relay.
const POST = 'https://thezvi.substack.com/p/leaked-anthropic-draft-ai-regulatory';
const PODCAST_AUDIO = 'https://example.com/podcast/episode-1.mp3';

/** A browser request to a publisher or an audio host would mean the page read it itself, which it must never do. */
function assertPageNeverReadThePublisher(probe: Probe) {
  for (const request of probe.requests) {
    const url = new URL(request.url());
    expect(url.hostname === '127.0.0.1', `the page itself reached only the link server: ${request.url()}`).toBe(true);
  }
}

test('a Substack post whose voice is there and whose audio plays is `plays`, with one page read and one audio read through the app', async ({ page }) => {
  const reads: Reads = {
    pages: { [POST]: { status: 200, url: POST, body: feedFixture('substack-preloads-json-generated-voice-page.html').toString() } },
    audio: { status: 206, contentType: 'audio/wav' },
  };
  const probe = await check(page, 'vectorpost01', reads);
  await expect.poll(async () => (await probe.messages()).length).toBeGreaterThanOrEqual(2);
  expect(await probe.messages()).toEqual([{ type: 'started' }, { type: 'verdict', verdict: 'plays' }]);
  const asked = await probe.asked();
  expect(asked.map((a) => a.kind)).toEqual(['page', 'audio-start']);
  expect(asked[0].url).toBe(POST);
  expect(asked[1].url).toContain('substack-video.s3.amazonaws.com');
  assertPageNeverReadThePublisher(probe);
  assertReadOnlyPacketLoad(probe, 'vectorpost01');
  expect(await probe.idbWrites()).toEqual([]);
});

test('the #4433 case: a post whose page offers no voice is `no-post-voice` before the friend meets it', async ({ page }) => {
  const noVoice = `<script>window._preloads = JSON.parse(${JSON.stringify(JSON.stringify({ post: { type: 'newsletter', audience: 'everyone', id: 7, canonical_url: POST, audio_items: [{ post_id: 7, type: 'tts', status: 'failed', audio_url: null }] } }))});</script>`;
  const probe = await check(page, 'vectorpost01', { pages: { [POST]: { status: 200, url: POST, body: noVoice } }, audio: { status: 200 } });
  await expect.poll(async () => (await probe.messages()).length).toBeGreaterThanOrEqual(2);
  expect(await probe.messages()).toEqual([{ type: 'started' }, { type: 'verdict', verdict: 'cannot', reason: 'no-post-voice' }]);
  expect((await probe.asked()).map((a) => a.kind)).toEqual(['page']);
  assertPageNeverReadThePublisher(probe);
});

test('a podcast episode whose audio the server turns away is `audio-refused`; a page that fails to read is "couldn\'t check", never a warning', async ({ page }) => {
  const refused = await check(page, 'vectorvoice01', { pages: {}, audio: { status: 404, contentType: 'text/html' } });
  await expect.poll(async () => (await refused.messages()).length).toBeGreaterThanOrEqual(2);
  expect(await refused.messages()).toEqual([{ type: 'started' }, { type: 'verdict', verdict: 'cannot', reason: 'audio-refused' }]);
  expect(await refused.asked()).toEqual([{ kind: 'audio-start', url: PODCAST_AUDIO }]);
  assertPageNeverReadThePublisher(refused);

  const down = await check(await page.context().newPage(), 'vectorvoice01', { pages: {}, audio: 'reject' });
  await expect.poll(async () => (await down.messages()).length).toBeGreaterThanOrEqual(2);
  expect(await down.messages()).toEqual([{ type: 'started' }, { type: 'failed', reason: 'server' }]);
});
