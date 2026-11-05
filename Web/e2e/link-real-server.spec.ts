// What #2168 asks an agent to prove, against the REAL link server (research/B4/server built with `go build`, started
// with `-links-web-url`) and the production-built web app (dist-e2e), not the stub: the friend's happy path in laptop
// and Pixel emulation, the failure table (one plain sentence each), and the privacy network log. Only the episode's
// address (example.com) and the relay origin (relay.test, which this spec answers from the real server) are rewritten.
// Silent: the config's --mute-audio and VITE_E2E_SILENT. Needs `go` on the PATH. Not covered, and left to the owner:
// a real Android browser, iPhone Safari, hearing it, and a link made on a phone build.
import { execFileSync, spawn, type ChildProcess } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { devices, expect, test, type Browser, type BrowserContext, type Page } from '@playwright/test';
import { keyFromFragment, sealPart, PART } from '../src/packet/share-link.ts';
import { seconds, serveAudio, serveFixtures } from './fixtures.ts';

const repo = fileURLToPath(new URL('../../', import.meta.url));
const SERVER_PORT = Number(process.env.SM_LINK_REAL_PORT ?? 8899);
const SERVER = `http://127.0.0.1:${SERVER_PORT}`;
const WEB = `http://127.0.0.1:${Number(process.env.SM_E2E_PORT ?? 4173)}`;
const RELAY = 'https://relay.test';
const vector = JSON.parse(readFileSync(join(repo, 'research/B4/contracts/fixtures/share-link-sealing-vector.json'), 'utf8'));
const KEY: string = vector.keyFragment;
const WRONG_KEY = `${KEY.slice(0, -2)}${KEY.endsWith('AA') ? 'BA' : 'AA'}`;
const EPISODE = 'Episode 1 (example episode)';

let work = '';
let binary = '';
let server: ChildProcess | undefined;
let id = '';
let goneId = '';

test.beforeEach(async ({}, info) => {
  test.skip(info.project.name !== 'phone', 'Opens its own laptop and Pixel contexts.');
});

async function seal(): Promise<FormData> {
  const key = keyFromFragment(KEY) as Uint8Array;
  const preview = { schema: 'spokenmargins.link-preview.v1', source: { title: EPISODE }, margins: [{ text: 'A Margin.' }] };
  const packet = new Uint8Array(readFileSync(join(repo, 'Contracts/fixtures/web-packets/web-voice.spokenmargins')));
  const form = new FormData();
  form.append('preview', new Blob([await sealPart(new TextEncoder().encode(JSON.stringify(preview)), PART.preview, key)]), 'preview');
  form.append('packet', new Blob([await sealPart(packet, PART.packet, key)]), 'packet');
  return form;
}

async function make(): Promise<string> {
  const made = await fetch(`${SERVER}/api/v1/links`, { method: 'POST', body: await seal() });
  if (made.status !== 201) throw new Error(`seeding a link answered ${made.status}`);
  return ((await made.json()).path as string).replace('/l/', '');
}

test.beforeAll(async () => {
  work = mkdtempSync(join(tmpdir(), 'sm-link-real-'));
  binary = join(work, 'smserver');
  execFileSync('go', ['build', '-o', binary, './cmd/smserver'], { cwd: join(repo, 'research/B4/server'), stdio: 'inherit' });
  execFileSync(binary, ['switch', '-public', join(work, 'public'), 'links', 'on'], { stdio: 'inherit' });
  server = spawn(
    binary,
    ['serve', '-listen', `127.0.0.1:${SERVER_PORT}`, '-state', join(work, 'state'), '-public', join(work, 'public'),
      '-links-install-url', 'https://testflight.apple.com/join/EXAMPLE', '-links-web-url', WEB],
    { stdio: 'inherit' },
  );
  for (let tries = 0; ; tries += 1) {
    try {
      if ((await fetch(`${SERVER}/api/v1/health`)).ok) break;
    } catch {
      if (tries > 100) throw new Error('the link server did not start');
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  id = await make();
  goneId = await make();
  execFileSync(binary, ['takedown', '-state', join(work, 'state'), goneId], { stdio: 'inherit' });
});

test.afterAll(() => {
  server?.kill();
  if (work) rmSync(work, { recursive: true, force: true });
});

interface Seen {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: string | null;
}

/** Every request the context makes (pages and pop-ups), with all headers the browser sent. */
function record(context: BrowserContext): { all: () => Promise<Seen[]> } {
  const pending: Promise<Seen>[] = [];
  context.on('request', (request) => {
    pending.push(request.allHeaders().then((headers) => ({ url: request.url(), method: request.method(), headers, body: request.postData() })));
  });
  return { all: () => Promise.all(pending) };
}

async function wire(context: BrowserContext, page: Page): Promise<void> {
  await serveFixtures(page);
  await serveAudio(page, 'https://example.com/podcast/**');
  // The host the app is served from adds `<base href="/">` at `/l/<id>`, as the production host does.
  await context.route(
    (url) => url.origin === WEB && /^\/l\/[^/]+\/?$/.test(url.pathname),
    async (route) => {
      const home = await route.fetch({ url: `${WEB}/` });
      await route.fulfill({ response: home, body: (await home.text()).replace('<head>', '<head>\n    <base href="/" />') });
    },
  );
  // relay.test is the real server.
  await context.route(`${RELAY}/**`, async (route) => {
    const url = new URL(route.request().url());
    const answer = await route.fetch({ url: `${SERVER}${url.pathname}${url.search}` });
    await route.fulfill({ response: answer, headers: { ...answer.headers(), 'access-control-allow-origin': '*' } });
  });
}

const shapes: Array<[string, (browser: Browser) => Promise<BrowserContext>]> = [
  ['laptop', (browser) => browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'block' })],
  ['Pixel 7 (Android user agent)', (browser) => browser.newContext({ ...devices['Pixel 7'], serviceWorkers: 'block' })],
];

for (const [shape, open] of shapes) {
  test(`${shape}: a sealed link through the real server hands over to the web app, plays, and a Margin comes up at its moment; the network log is clean`, async ({ browser }) => {
    const context = await open(browser);
    const log = record(context);
    const page = await context.newPage();
    await wire(context, page);

    await page.goto(`${SERVER}/l/${id}#${KEY}`);
    const arrival = page.getByTestId('arrival');
    await expect(arrival.getByText('From Web fixture')).toBeVisible();
    // location.replace: the web app's origin, no server page left in the history, and no key left in the address.
    expect(new URL(page.url()).origin).toBe(WEB);
    // Back does not return to the server page: location.replace left it out of the history.
    await page.goBack().catch(() => undefined);
    expect(page.url().startsWith(SERVER)).toBe(false);
    await page.goto(`${SERVER}/l/${id}#${KEY}`);
    await expect(arrival.getByText('From Web fixture')).toBeVisible();
    expect(page.url()).not.toContain(KEY.slice(0, 12));
    expect(await page.evaluate(() => document.referrer)).not.toContain(KEY.slice(0, 12));
    // No listener action yet: no publisher or feed host has been asked for anything, and the audio is paused.
    const before = (await log.all()).map((r) => new URL(r.url).host);
    expect(before.filter((host) => host === 'example.com' || host === 'feeds.test')).toEqual([]);
    expect(await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.paused)).toBe(true);

    await arrival.getByRole('button', { name: 'Play' }).click();
    const playing = page.getByRole('dialog', { name: EPISODE });
    await expect(playing).toBeVisible();
    await expect.poll(() => page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentTime), { timeout: 10_000 }).toBeGreaterThan(0.3);
    // Move the clock to just short of the written Margin (0:30) and let it run through: the Margin comes up by itself.
    await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => {
      a.currentTime = 28.5;
    });
    const arrived = playing.getByTestId('arrived-margin');
    await expect(arrived).toContainText('Web fixture wrote this', { timeout: 15_000 });
    await expect(arrived).toContainText('1 of 2');
    await expect(arrived).toContainText('A written Margin at half a minute.');
    expect(seconds((await page.getByTestId('elapsed').textContent()) ?? '0:00')).toBeGreaterThanOrEqual(29);

    // The network log. Hosts: the link server, the app, relay.test (answered from the real server) and the episode.
    const seen = await log.all();
    for (const r of seen) {
      const where = `${r.method} ${r.url.replace(KEY, '<key>')}`;
      expect(r.method, where).toBe('GET');
      expect(r.body, where).toBeNull();
      for (const probe of [KEY, KEY.slice(0, 12), encodeURIComponent(KEY.slice(0, 12))]) {
        expect(r.url, where).not.toContain(probe);
        for (const [name, value] of Object.entries(r.headers)) expect(`${name}: ${value}`, where).not.toContain(probe);
      }
    }
    const hosts = new Set(seen.map((r) => new URL(r.url).host));
    expect([...hosts].sort()).toEqual([new URL(SERVER).host, new URL(WEB).host, 'example.com', 'relay.test'].sort());
    // The episode is fetched only after Play, and only its enclosure; the link server is asked for the sealed packet only.
    const episode = seen.filter((r) => new URL(r.url).host === 'example.com');
    expect(episode.length).toBeGreaterThan(0);
    for (const r of episode) expect(new URL(r.url).pathname).toMatch(/^\/podcast\//);
    const asked = seen.filter((r) => r.url.startsWith(`${RELAY}/`)).map((r) => new URL(r.url).pathname);
    expect([...new Set(asked)]).toEqual([`/l/${id}/packet`]);
    await context.close();
  });
}

test('the failure table: each cause is one plain sentence, with no raw error and nothing to play', async ({ browser }) => {
  const context = await shapes[1][1](browser);
  const page = await context.newPage();
  await wire(context, page);
  const failed = page.getByTestId('arrival-failed');
  const expectFailure = async (name: string, headline: string) => {
    await expect(failed.getByRole('heading'), name).toContainText(headline);
    await expect(page.getByText(/not_found|disabled|\{"error"|undefined/), name).toHaveCount(0);
    await expect(failed.getByRole('button'), name).toHaveCount(0);
  };

  // Wrong key, cut-off key, no key: through the real server page, they hand over and the web app says so.
  for (const [name, hash] of [['wrong key', `#${WRONG_KEY}`], ['cut-off key', `#${KEY.slice(0, 20)}`], ['no key', '']] as const) {
    await page.goto(`${SERVER}/l/${id}${hash}`);
    await expectFailure(name, 'This link is cut off.');
  }
  // Removed after the fact (410 from the real server): its own page says so in the same words an unknown link gets.
  await page.goto(`${SERVER}/l/${goneId}#${KEY}`);
  await expect(page.locator('body')).toContainText("This link isn't available");
  expect(new URL(page.url()).origin).toBe(SERVER);
  // The web app reached directly, with the real 410 and the real 404 behind it.
  for (const [name, link] of [['removed (410)', goneId], ['unknown (404)', '0'.repeat(32)]] as const) {
    await page.goto(`${WEB}/l/${link}#${KEY}`);
    await expectFailure(name, 'This link has expired.');
  }
  // Links switched off on the real server (503), then back on.
  const sw = (state: string) => execFileSync(binary, ['switch', '-public', join(work, 'public'), 'links', state], { stdio: 'inherit' });
  sw('off');
  try {
    await page.goto(`${WEB}/l/${id}#${KEY}`);
    await expectFailure('links switched off', 'Links are switched off for now.');
    // What the real server's own page says meanwhile, recorded in the report (no assertion: the words are the server's).
    await page.goto(`${SERVER}/l/${id}#${KEY}`);
    test.info().annotations.push({ type: 'server page while links are off', description: (await page.locator('body').innerText()).slice(0, 200) });
  } finally {
    sw('on');
  }
  // A server fault (500) and no connection, simulated at the network boundary: the real server cannot be made to fail so.
  await context.route(`${RELAY}/l/*/packet`, (route) => route.fulfill({ status: 500, body: 'boom' }));
  await page.goto(`${WEB}/l/${id}#${KEY}`);
  await expectFailure('server error (500)', 'The server had a problem.');
  await context.unroute(`${RELAY}/l/*/packet`);
  await context.route(`${RELAY}/l/*/packet`, (route) => route.abort('internetdisconnected'));
  await page.goto(`${WEB}/l/${id}#${KEY}`);
  await expectFailure('offline', 'You’re offline.');
  await context.close();
});

test('an enclosure that fails to load: one sentence and the Margins still play (real server link)', async ({ browser }) => {
  const context = await shapes[0][1](browser);
  const page = await context.newPage();
  await wire(context, page);
  await page.route('https://example.com/podcast/**', (route) => route.fulfill({ status: 404, body: 'Not found', headers: { 'content-type': 'text/html' } }));
  await page.goto(`${SERVER}/l/${id}#${KEY}`);
  await page.getByTestId('arrival').getByRole('button', { name: 'Play' }).click();
  const cue = page.getByRole('dialog', { name: EPISODE }).getByTestId('margin-cue');
  await expect(cue).toContainText('This episode can’t play here, but you can still hear Web fixture’s Margins.');
  // (The one-toast rule is link-arrival.spec.ts's #3356 test, which fails on this branch: see the report.)
  await context.close();
});

test('?report stays on the real server page with the form open, no key asked for and no failure sentence', async ({ browser }) => {
  const context = await shapes[0][1](browser);
  const log = record(context);
  const page = await context.newPage();
  await page.goto(`${SERVER}/l/${id}?report`);
  await expect(page.locator('details#report')).toHaveAttribute('open', '');
  await expect(page.locator('#status')).toHaveText('');
  expect(new URL(page.url()).origin).toBe(SERVER);
  // Reporting needs no key, so the key-free page asks the server for nothing but its own page.
  expect((await log.all()).map((r) => new URL(r.url).pathname).filter((p) => /\/(packet|preview)$/.test(p))).toEqual([]);
  await context.close();
});
